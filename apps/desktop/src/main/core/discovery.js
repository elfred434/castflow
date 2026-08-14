// Découverte des appareils par broadcast UDP.
const dgram = require('node:dgram');
const { EventEmitter } = require('node:events');
const { PROTOCOL_VERSION, DEFAULT_PORTS, DISCOVERY } = require('./protocol');
const { broadcastAddresses } = require('./device');

class Discovery extends EventEmitter {
  /**
   * @param {object} opts
   * @param {object} opts.device      identité locale
   * @param {number} opts.httpPort
   * @param {number} opts.wsPort
   * @param {boolean} opts.requiresPin
   * @param {number} [opts.port]      port UDP
   */
  constructor(opts) {
    super();
    this.opts = { port: DEFAULT_PORTS.discovery, ...opts };
    this.socket = null;
    this.timer = null;
    this.sweeper = null;
    /** @type {Map<string, any>} */
    this.devices = new Map();
  }

  start() {
    if (this.socket) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
      this.socket = sock;

      sock.on('error', (err) => {
        this.emit('error', err);
        reject(err);
      });

      sock.on('message', (buf, rinfo) => this._onMessage(buf, rinfo));

      sock.bind(this.opts.port, () => {
        try {
          sock.setBroadcast(true);
        } catch { /* certains environnements l'interdisent */ }
        this.announce('DISCOVER');
        this.timer = setInterval(() => this.announce('ANNOUNCE'), DISCOVERY.announceIntervalMs);
        this.sweeper = setInterval(() => this._sweep(), 2000);
        this.emit('started', this.opts.port);
        resolve();
      });
    });
  }

  _packet(type) {
    return JSON.stringify({
      v: PROTOCOL_VERSION,
      type,
      device: this.opts.device,
      http: this.opts.httpPort,
      ws: this.opts.wsPort,
      secure: false,
      requiresPin: !!this.opts.requiresPin,
      t: Date.now(),
    });
  }

  announce(type = 'ANNOUNCE') {
    if (!this.socket) return;
    const buf = Buffer.from(this._packet(type));
    for (const addr of broadcastAddresses()) {
      this.socket.send(buf, 0, buf.length, this.opts.port, addr, () => {});
    }
  }

  _reply(rinfo) {
    if (!this.socket) return;
    const buf = Buffer.from(this._packet('ANNOUNCE'));
    this.socket.send(buf, 0, buf.length, rinfo.port, rinfo.address, () => {});
  }

  _onMessage(buf, rinfo) {
    let msg;
    try { msg = JSON.parse(buf.toString('utf8')); } catch { return; }
    if (!msg || msg.v !== PROTOCOL_VERSION || !msg.device?.id) return;
    if (msg.device.id === this.opts.device.id) return; // soi-même

    if (msg.type === 'BYE') {
      if (this.devices.delete(msg.device.id)) {
        this.emit('lost', msg.device.id);
        this.emit('devices', this.list());
      }
      return;
    }

    const known = this.devices.get(msg.device.id);
    const entry = {
      ...msg.device,
      host: rinfo.address,
      httpPort: msg.http ?? DEFAULT_PORTS.http,
      wsPort: msg.ws ?? DEFAULT_PORTS.ws,
      secure: !!msg.secure,
      requiresPin: !!msg.requiresPin,
      lastSeen: Date.now(),
      source: 'udp',
    };
    this.devices.set(entry.id, entry);

    if (!known) {
      this.emit('found', entry);
      this.emit('devices', this.list());
    }

    // On répond aux DISCOVER pour accélérer l'appairage.
    if (msg.type === 'DISCOVER') this._reply(rinfo);
  }

  _sweep() {
    const now = Date.now();
    let changed = false;
    for (const [id, d] of this.devices) {
      if (now - d.lastSeen > DISCOVERY.deviceTtlMs) {
        this.devices.delete(id);
        this.emit('lost', id);
        changed = true;
      }
    }
    if (changed) this.emit('devices', this.list());
  }

  list() {
    return [...this.devices.values()].sort((a, b) => a.name.localeCompare(b.name));
  }

  refresh() {
    this.announce('DISCOVER');
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    if (this.sweeper) clearInterval(this.sweeper);
    this.timer = this.sweeper = null;
    if (this.socket) {
      try {
        const buf = Buffer.from(this._packet('BYE'));
        for (const addr of broadcastAddresses()) {
          this.socket.send(buf, 0, buf.length, this.opts.port, addr, () => {});
        }
      } catch { /* ignore */ }
      try { this.socket.close(); } catch { /* ignore */ }
      this.socket = null;
    }
    this.devices.clear();
  }
}

module.exports = { Discovery };
