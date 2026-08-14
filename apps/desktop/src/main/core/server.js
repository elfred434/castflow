// Serveur CastFlow : HTTP (données, reprise) + WebSocket (contrôle).
const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const { WebSocketServer } = require('ws');

const {
  PROTOCOL_VERSION, DEFAULT_PORTS, LIMITS,
  uid, envelope, parseEnvelope, pinProof, guessMime,
} = require('./protocol');

/** Trouve un port libre à partir de `start`. */
function listenFrom(server, start, host = '0.0.0.0', tries = 20) {
  return new Promise((resolve, reject) => {
    let port = start;
    const attempt = () => {
      server.once('error', (err) => {
        if (err.code === 'EADDRINUSE' && port - start < tries) {
          port++;
          setImmediate(attempt);
        } else reject(err);
      });
      server.listen(port, host, () => resolve(port));
    };
    attempt();
  });
}

/**
 * Neutralise un nom de fichier reçu du réseau : pas de séparateur, pas de `..`,
 * pas de caractère interdit sous Windows, pas de nom réservé.
 */
function sanitizeName(name) {
  let n = String(name ?? '')
    .replace(/[/\\]/g, '_')        // séparateurs de chemin
    .replace(/\.{2,}/g, '_')       // traversée ..
    .replace(/[\x00-\x1f<>:"|?*]/g, '_') // caractères interdits
    .replace(/^[.\s]+/, '')        // fichiers cachés / espaces en tête
    .replace(/[.\s]+$/, '')        // points/espaces en fin (Windows)
    .slice(0, 200)
    .trim();
  if (/^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i.test(n.split('.')[0])) n = `_${n}`;
  return n || 'fichier';
}

/** Évite d'écraser un fichier existant : photo.jpg → photo (1).jpg */
async function uniquePath(dir, name) {
  const ext = path.extname(name);
  const base = path.basename(name, ext);
  let candidate = path.join(dir, name);
  let i = 1;
  while (true) {
    try {
      await fsp.access(candidate);
      candidate = path.join(dir, `${base} (${i++})${ext}`);
    } catch {
      return candidate;
    }
  }
}

class CastFlowServer extends EventEmitter {
  /**
   * @param {object} opts
   * @param {object} opts.device        identité locale
   * @param {string} opts.downloadDir   dossier de réception
   * @param {string|null} opts.pin      PIN requis (null = pas de PIN)
   * @param {boolean} [opts.autoAccept] accepter les transferts sans confirmation
   */
  constructor(opts) {
    super();
    this.device = opts.device;
    this.downloadDir = opts.downloadDir;
    this.pin = opts.pin ?? null;
    this.autoAccept = !!opts.autoAccept;

    this.httpServer = null;
    this.wss = null;
    this.httpPort = null;
    this.wsPort = null;

    /** transferId -> session */
    this.transfers = new Map();
    /** clients WS authentifiés */
    this.clients = new Set();
    /** ip -> { fails, until } */
    this.pinGuard = new Map();
    /** appareils de confiance (fingerprint) */
    this.trusted = new Set(opts.trusted ?? []);
  }

  /* ------------------------------------------------------------ */
  /* Cycle de vie                                                  */
  /* ------------------------------------------------------------ */

  async start(httpPort = DEFAULT_PORTS.http, wsPort = DEFAULT_PORTS.ws) {
    await fsp.mkdir(this.downloadDir, { recursive: true });

    this.httpServer = http.createServer((req, res) => this._onRequest(req, res));
    this.httpPort = await listenFrom(this.httpServer, httpPort);

    const wsHttp = http.createServer();
    this.wsPort = await listenFrom(wsHttp, wsPort);
    this.wss = new WebSocketServer({ server: wsHttp });
    this._wsHttp = wsHttp;
    this.wss.on('connection', (ws, req) => this._onConnection(ws, req));

    this._pinger = setInterval(() => {
      for (const c of this.clients) {
        if (c.isAlive === false) { c.ws.terminate(); this.clients.delete(c); continue; }
        c.isAlive = false;
        try { c.ws.ping(); } catch { /* ignore */ }
      }
    }, LIMITS.pingIntervalMs);

    this.emit('started', { httpPort: this.httpPort, wsPort: this.wsPort });
    return { httpPort: this.httpPort, wsPort: this.wsPort };
  }

  async stop() {
    clearInterval(this._pinger);
    for (const c of this.clients) { try { c.ws.close(); } catch {} }
    this.clients.clear();
    await new Promise((r) => (this.wss ? this.wss.close(r) : r()));
    await new Promise((r) => (this._wsHttp ? this._wsHttp.close(r) : r()));
    await new Promise((r) => (this.httpServer ? this.httpServer.close(r) : r()));
    this.httpServer = this.wss = this._wsHttp = null;
    this.emit('stopped');
  }

  setPin(pin) { this.pin = pin; }
  setDownloadDir(dir) { this.downloadDir = dir; }
  setAutoAccept(v) { this.autoAccept = !!v; }

  /* ------------------------------------------------------------ */
  /* HTTP                                                          */
  /* ------------------------------------------------------------ */

  _cors(res) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,HEAD,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type,X-CastFlow-Token,X-Offset');
    res.setHeader('Access-Control-Expose-Headers', 'X-Received-Bytes');
  }

  _json(res, code, body) {
    this._cors(res);
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(body));
  }

  _err(res, http, code, message) {
    this._json(res, http, { error: true, code, message });
  }

  async _onRequest(req, res) {
    const url = new URL(req.url, `http://${req.headers.host ?? 'localhost'}`);
    const seg = url.pathname.split('/').filter(Boolean);

    if (req.method === 'OPTIONS') { this._cors(res); res.writeHead(204); return res.end(); }

    // GET /info
    if (req.method === 'GET' && seg[0] === 'info') {
      return this._json(res, 200, {
        v: PROTOCOL_VERSION,
        device: this.device,
        http: this.httpPort,
        ws: this.wsPort,
        secure: false,
        requiresPin: !!this.pin,
      });
    }

    // /upload/:transferId/:fileId
    if (seg[0] === 'upload' && seg.length === 3) {
      const [, transferId, fileId] = seg;
      const t = this.transfers.get(transferId);
      if (!t) return this._err(res, 404, 'UNKNOWN_FILE', 'Transfert inconnu');
      if (t.state !== 'transferring') return this._err(res, 403, 'NOT_ACCEPTED', 'Transfert non accepté');

      const entry = t.files.get(fileId);
      if (!entry) return this._err(res, 404, 'UNKNOWN_FILE', 'Fichier inconnu');

      const token = req.headers['x-castflow-token'];
      if (!token) return this._err(res, 401, 'NO_TOKEN', 'Token manquant');
      if (token !== entry.token) return this._err(res, 401, 'BAD_TOKEN', 'Token invalide');

      if (req.method === 'HEAD') {
        this._cors(res);
        res.setHeader('X-Received-Bytes', String(entry.received));
        res.writeHead(200);
        return res.end();
      }
      if (req.method === 'POST') return this._receiveFile(req, res, t, entry);
      return this._err(res, 405, 'INTERNAL', 'Méthode non supportée');
    }

    // GET /download/:transferId/:fileId
    if (req.method === 'GET' && seg[0] === 'download' && seg.length === 3) {
      return this._sendFile(req, res, seg[1], seg[2]);
    }

    // POST /cancel/:transferId
    if (req.method === 'POST' && seg[0] === 'cancel' && seg.length === 2) {
      this.cancelTransfer(seg[1], 'Annulé par le pair');
      return this._json(res, 200, { ok: true });
    }

    this._err(res, 404, 'UNKNOWN_FILE', 'Route inconnue');
  }

  async _receiveFile(req, res, t, entry) {
    const offset = Number(req.headers['x-offset'] ?? 0);
    if (Number.isNaN(offset) || offset < 0 || offset > entry.received) {
      return this._err(res, 409, 'OFFSET_MISMATCH', `Offset attendu ${entry.received}`);
    }
    entry.received = offset;

    const tmp = entry.tmpPath;
    await fsp.mkdir(path.dirname(tmp), { recursive: true });
    const ws = fs.createWriteStream(tmp, offset > 0 ? { flags: 'r+', start: offset } : { flags: 'w' });

    let lastEmit = 0;
    let windowBytes = 0;
    let windowStart = Date.now();

    const fail = (code, message, httpCode = 500) => {
      try { ws.destroy(); } catch {}
      if (!res.headersSent) this._err(res, httpCode, code, message);
      t.state = 'failed';
      t.error = message;
      this.emit('transfer', this._publicTransfer(t));
    };

    req.on('data', (chunk) => {
      entry.received += chunk.length;
      windowBytes += chunk.length;
      if (entry.received > entry.size) {
        req.destroy();
        return fail('TOO_LARGE', 'Taille dépassée', 413);
      }
      const now = Date.now();
      if (now - lastEmit >= LIMITS.progressThrottleMs) {
        const dt = (now - windowStart) / 1000;
        const bps = dt > 0 ? windowBytes / dt : 0;
        windowBytes = 0; windowStart = now; lastEmit = now;
        entry.bps = bps;
        this._broadcast(envelope('PROGRESS', {
          transferId: t.id, fileId: entry.id, received: entry.received, total: entry.size, bps,
        }));
        this.emit('transfer', this._publicTransfer(t));
      }
    });

    req.on('error', () => fail('INTERNAL', 'Connexion interrompue'));
    ws.on('error', (e) => fail(e.code === 'ENOSPC' ? 'NO_SPACE' : 'INTERNAL', e.message, 507));

    req.pipe(ws);

    ws.on('close', async () => {
      if (res.headersSent) return;
      if (entry.received < entry.size) {
        // Coupure : on garde le .cfpart pour permettre la reprise.
        return this._err(res, 500, 'INTERNAL', 'Transfert incomplet, reprise possible');
      }
      try {
        const final = await uniquePath(this.downloadDir, entry.name);
        await fsp.rename(tmp, final);
        entry.finalPath = final;
        entry.done = true;
      } catch (e) {
        return fail('INTERNAL', e.message);
      }

      this._broadcast(envelope('FILE_DONE', { transferId: t.id, fileId: entry.id, hashOk: true }));
      this.emit('file-done', { transferId: t.id, file: this._publicFile(entry) });
      this._json(res, 200, { ok: true, received: entry.received });

      const all = [...t.files.values()].every((f) => f.done);
      if (all) {
        t.state = 'completed';
        t.finishedAt = Date.now();
        this._broadcast(envelope('TRANSFER_COMPLETE', {
          transferId: t.id,
          files: [...t.files.values()].map((f) => f.name),
          durationMs: t.finishedAt - t.startedAt,
        }));
      }
      this.emit('transfer', this._publicTransfer(t));
    });
  }

  async _sendFile(req, res, transferId, fileId) {
    const t = this.transfers.get(transferId);
    const entry = t?.files.get(fileId);
    if (!entry || !entry.sourcePath) return this._err(res, 404, 'UNKNOWN_FILE', 'Fichier inconnu');
    if (req.headers['x-castflow-token'] !== entry.token) {
      return this._err(res, 401, 'BAD_TOKEN', 'Token invalide');
    }

    let stat;
    try { stat = await fsp.stat(entry.sourcePath); }
    catch { return this._err(res, 404, 'UNKNOWN_FILE', 'Fichier absent du disque'); }

    const range = req.headers.range;
    let start = 0; let end = stat.size - 1; let code = 200;
    if (range) {
      const m = /bytes=(\d*)-(\d*)/.exec(range);
      if (m) {
        start = m[1] ? Number(m[1]) : 0;
        end = m[2] ? Number(m[2]) : stat.size - 1;
        code = 206;
      }
    }

    this._cors(res);
    res.writeHead(code, {
      'Content-Type': guessMime(entry.name),
      'Content-Length': String(end - start + 1),
      'Content-Disposition': `attachment; filename="${encodeURIComponent(entry.name)}"`,
      'Accept-Ranges': 'bytes',
      ...(code === 206 ? { 'Content-Range': `bytes ${start}-${end}/${stat.size}` } : {}),
    });

    const stream = fs.createReadStream(entry.sourcePath, { start, end });
    let sent = entry.received || 0;
    let last = 0;
    stream.on('data', (c) => {
      sent += c.length;
      entry.received = sent;
      const now = Date.now();
      if (now - last > LIMITS.progressThrottleMs) {
        last = now;
        this.emit('transfer', this._publicTransfer(t));
      }
    });
    stream.on('end', () => {
      entry.done = true;
      if ([...t.files.values()].every((f) => f.done)) {
        t.state = 'completed';
        t.finishedAt = Date.now();
      }
      this.emit('transfer', this._publicTransfer(t));
    });
    stream.on('error', () => res.destroy());
    stream.pipe(res);
  }

  /* ------------------------------------------------------------ */
  /* WebSocket                                                     */
  /* ------------------------------------------------------------ */

  _onConnection(ws, req) {
    const ip = req.socket.remoteAddress;
    const client = {
      ws, ip, isAlive: true, authed: !this.pin, device: null,
      nonce: crypto.randomBytes(16).toString('base64'),
    };
    this.clients.add(client);

    ws.on('pong', () => { client.isAlive = true; });
    ws.on('close', () => {
      this.clients.delete(client);
      if (client.device) this.emit('peer-disconnected', client.device);
    });
    ws.on('error', () => this.clients.delete(client));
    ws.on('message', (raw) => this._onMessage(client, String(raw)));
  }

  _send(client, msg) {
    try { client.ws.send(JSON.stringify(msg)); } catch { /* ignore */ }
  }

  _broadcast(msg) {
    for (const c of this.clients) if (c.authed) this._send(c, msg);
  }

  _locked(ip) {
    const g = this.pinGuard.get(ip);
    return g && g.until > Date.now();
  }

  async _onMessage(client, raw) {
    const msg = parseEnvelope(raw);
    if (!msg) return;

    if (msg.v > PROTOCOL_VERSION) {
      return this._send(client, envelope('ERROR', {
        code: 'VERSION_MISMATCH', message: 'Version de protocole non supportée',
      }, msg.id));
    }

    switch (msg.type) {
      case 'PING':
        return this._send(client, envelope('PONG', {}, msg.id));

      case 'HELLO': {
        client.device = msg.data?.device ?? null;
        const trusted = !!client.device?.fingerprint && this.trusted.has(client.device.fingerprint);
        client.authed = !this.pin || trusted;
        this._send(client, envelope('HELLO_ACK', {
          device: this.device,
          nonce: client.nonce,
          requiresPin: !!this.pin && !trusted,
          trusted,
        }, msg.id));
        if (client.device) this.emit('peer-connected', client.device);
        return;
      }

      case 'AUTH': {
        if (this._locked(client.ip)) {
          return this._send(client, envelope('AUTH_FAIL', {
            reason: 'Trop de tentatives, réessayez plus tard', attemptsLeft: 0,
          }, msg.id));
        }
        const expected = pinProof(this.pin ?? '', client.nonce, client.device?.id ?? '');
        if (this.pin && msg.data?.proof === expected) {
          client.authed = true;
          this.pinGuard.delete(client.ip);
          if (client.device?.fingerprint) this.trusted.add(client.device.fingerprint);
          return this._send(client, envelope('AUTH_OK', { sessionToken: uid('s') }, msg.id));
        }
        const g = this.pinGuard.get(client.ip) ?? { fails: 0, until: 0 };
        g.fails++;
        if (g.fails >= LIMITS.maxPinAttempts) g.until = Date.now() + LIMITS.pinLockoutMs;
        this.pinGuard.set(client.ip, g);
        return this._send(client, envelope('AUTH_FAIL', {
          reason: 'PIN incorrect', attemptsLeft: Math.max(0, LIMITS.maxPinAttempts - g.fails),
        }, msg.id));
      }

      case 'TRANSFER_REQUEST': {
        if (!client.authed) {
          return this._send(client, envelope('ERROR', {
            code: 'AUTH_REQUIRED', message: 'Authentification requise',
          }, msg.id));
        }
        return this._onTransferRequest(client, msg);
      }

      case 'TRANSFER_CANCEL':
        this.cancelTransfer(msg.data?.transferId, msg.data?.reason ?? 'Annulé par le pair');
        return;

      case 'RTC_OFFER':
      case 'RTC_ANSWER':
      case 'RTC_ICE':
        // Relais de signalisation vers les autres clients (v2 WebRTC).
        for (const c of this.clients) if (c !== client && c.authed) this._send(c, msg);
        return;

      default:
        return;
    }
  }

  async _onTransferRequest(client, msg) {
    const { transferId, files, totalSize } = msg.data ?? {};
    if (!Array.isArray(files) || !files.length) return;

    const t = {
      id: transferId || uid('t'),
      direction: 'receive',
      peer: client.device ?? { id: 'unknown', name: 'Appareil', platform: 'android', kind: 'mobile' },
      state: 'pending',
      startedAt: Date.now(),
      totalSize: totalSize ?? files.reduce((s, f) => s + (f.size || 0), 0),
      files: new Map(files.map((f) => {
        const name = sanitizeName(f.name);
        return [f.id, {
          id: f.id,
          name,
          size: Number(f.size) || 0,
          mime: f.mime || guessMime(name),
          received: 0,
          bps: 0,
          done: false,
          token: crypto.randomBytes(16).toString('hex'),
          tmpPath: path.join(this.downloadDir, `.${f.id}-${name}.cfpart`),
        }];
      })),
      client,
    };
    this.transfers.set(t.id, t);
    this.emit('transfer', this._publicTransfer(t));

    const decide = (accept, reason = '') => {
      if (t.state !== 'pending') return;
      if (accept) {
        t.state = 'transferring';
        t.startedAt = Date.now();
        const tokens = {};
        for (const [id, f] of t.files) tokens[id] = f.token;
        this._send(client, envelope('TRANSFER_ACCEPT', { transferId: t.id, tokens }, msg.id));
      } else {
        t.state = 'rejected';
        this._send(client, envelope('TRANSFER_REJECT', { transferId: t.id, reason }, msg.id));
      }
      this.emit('transfer', this._publicTransfer(t));
    };

    if (this.autoAccept) return decide(true);

    // L'UI décide via accept()/reject().
    t.decide = decide;
    this.emit('incoming-request', {
      transfer: this._publicTransfer(t),
      accept: () => decide(true),
      reject: (reason = 'Refusé par l\'utilisateur') => decide(false, reason),
    });
  }

  /* ------------------------------------------------------------ */
  /* API pour l'UI                                                 */
  /* ------------------------------------------------------------ */

  acceptTransfer(id) { this.transfers.get(id)?.decide?.(true); }
  rejectTransfer(id, reason = 'Refusé') { this.transfers.get(id)?.decide?.(false, reason); }

  cancelTransfer(id, reason = 'Annulé') {
    const t = this.transfers.get(id);
    if (!t) return;
    t.state = 'cancelled';
    t.error = reason;
    this._broadcast(envelope('TRANSFER_CANCEL', { transferId: id, reason }));
    this.emit('transfer', this._publicTransfer(t));
  }

  /** Prépare des fichiers locaux à télécharger par le pair (sens desktop → mobile). */
  offerFiles(fileList) {
    const t = {
      id: uid('t'),
      direction: 'send',
      peer: { id: 'peer', name: 'Appareil distant', platform: 'android', kind: 'mobile' },
      state: 'transferring',
      startedAt: Date.now(),
      totalSize: fileList.reduce((s, f) => s + f.size, 0),
      files: new Map(fileList.map((f) => [f.id, {
        ...f, received: 0, bps: 0, done: false,
        token: crypto.randomBytes(16).toString('hex'),
        sourcePath: f.path,
      }])),
    };
    this.transfers.set(t.id, t);
    this.emit('transfer', this._publicTransfer(t));
    return {
      transferId: t.id,
      files: [...t.files.values()].map((f) => ({
        id: f.id, name: f.name, size: f.size, mime: f.mime, token: f.token,
        url: `/download/${t.id}/${f.id}`,
      })),
    };
  }

  _publicFile(f) {
    return {
      id: f.id, name: f.name, size: f.size, mime: f.mime,
      received: f.received, bps: f.bps, done: f.done, path: f.finalPath,
    };
  }

  _publicTransfer(t) {
    const files = [...t.files.values()].map((f) => this._publicFile(f));
    return {
      id: t.id,
      direction: t.direction,
      peer: t.peer,
      state: t.state,
      startedAt: t.startedAt,
      finishedAt: t.finishedAt,
      error: t.error,
      totalSize: t.totalSize,
      transferred: files.reduce((s, f) => s + f.received, 0),
      bps: files.reduce((s, f) => s + (f.done ? 0 : f.bps), 0),
      files,
    };
  }

  listTransfers() {
    return [...this.transfers.values()]
      .map((t) => this._publicTransfer(t))
      .sort((a, b) => b.startedAt - a.startedAt);
  }
}

module.exports = { CastFlowServer, listenFrom, sanitizeName, uniquePath };
