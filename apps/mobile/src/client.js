/**
 * Client CastFlow pour React Native.
 * Parle au serveur desktop : handshake WS, PIN, puis upload HTTP avec reprise.
 */

export const PROTOCOL_VERSION = 1;
export const DEFAULT_PORTS = { http: 53317, ws: 53318, discovery: 54545 };

let counter = 0;
export function uid(prefix = '') {
  counter++;
  const s = `${Date.now().toString(36)}${counter.toString(36)}${Math.random().toString(36).slice(2, 6)}`;
  return prefix ? `${prefix}_${s}` : s;
}

export function envelope(type, data, re) {
  return { v: PROTOCOL_VERSION, type, id: uid('m'), ts: Date.now(), re, data };
}

/* ------------------------------------------------------------------ */
/* HMAC-SHA256 pur JS (évite une dépendance native pour la preuve PIN) */
/* ------------------------------------------------------------------ */

const K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

function sha256Bytes(bytes) {
  const H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const l = bytes.length;
  const withPad = new Uint8Array((((l + 8) >> 6) + 1) << 6);
  withPad.set(bytes);
  withPad[l] = 0x80;
  const bitLen = l * 8;
  const dv = new DataView(withPad.buffer);
  dv.setUint32(withPad.length - 4, bitLen >>> 0, false);
  dv.setUint32(withPad.length - 8, Math.floor(bitLen / 4294967296), false);

  const w = new Uint32Array(64);
  for (let i = 0; i < withPad.length; i += 64) {
    for (let j = 0; j < 16; j++) w[j] = dv.getUint32(i + j * 4, false);
    for (let j = 16; j < 64; j++) {
      const a = w[j - 15]; const b = w[j - 2];
      const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3);
      const s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10);
      w[j] = (w[j - 16] + s0 + w[j - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = H;
    for (let j = 0; j < 64; j++) {
      const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
      const ch = (e & f) ^ (~e & g);
      const t1 = (h + S1 + ch + K[j] + w[j]) >>> 0;
      const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0;
      d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
    H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0; H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
  }
  const out = new Uint8Array(32);
  const odv = new DataView(out.buffer);
  H.forEach((v, i) => odv.setUint32(i * 4, v, false));
  return out;
}

function utf8(str) {
  const out = [];
  for (let i = 0; i < str.length; i++) {
    let c = str.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c >= 0xd800 && c < 0xdc00) {
      c = 0x10000 + ((c & 0x3ff) << 10) + (str.charCodeAt(++i) & 0x3ff);
      out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    } else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return new Uint8Array(out);
}

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function toBase64(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i]; const b1 = bytes[i + 1]; const b2 = bytes[i + 2];
    out += B64[b0 >> 2];
    out += B64[((b0 & 3) << 4) | ((b1 ?? 0) >> 4)];
    out += b1 === undefined ? '=' : B64[((b1 & 15) << 2) | ((b2 ?? 0) >> 6)];
    out += b2 === undefined ? '=' : B64[b2 & 63];
  }
  return out;
}

/** HMAC-SHA256(clé, message) encodé en base64 — compatible Node `createHmac`. */
export function hmacSha256Base64(key, message) {
  let k = utf8(key);
  if (k.length > 64) k = sha256Bytes(k);
  const pad = new Uint8Array(64);
  pad.set(k);
  const inner = new Uint8Array(64);
  const outer = new Uint8Array(64);
  for (let i = 0; i < 64; i++) { inner[i] = pad[i] ^ 0x36; outer[i] = pad[i] ^ 0x5c; }
  const msg = utf8(message);
  const i1 = new Uint8Array(64 + msg.length);
  i1.set(inner); i1.set(msg, 64);
  const h1 = sha256Bytes(i1);
  const o1 = new Uint8Array(96);
  o1.set(outer); o1.set(h1, 64);
  return toBase64(sha256Bytes(o1));
}

export const pinProof = (pin, nonce, deviceId) => hmacSha256Base64(pin, nonce + deviceId);

/* ------------------------------------------------------------------ */
/* Parsing du QR / URL de connexion                                    */
/* ------------------------------------------------------------------ */

export function parseConnectUrl(raw) {
  const idx = String(raw).indexOf('castflow://');
  if (idx === -1) return null;
  const q = raw.slice(idx).split('?')[1];
  if (!q) return null;
  const params = {};
  for (const pair of q.split('&')) {
    const [k, v = ''] = pair.split('=');
    params[decodeURIComponent(k)] = decodeURIComponent(v.replace(/\+/g, ' '));
  }
  if (!params.host) return null;
  return {
    id: params.id ?? params.host,
    name: params.name ?? params.host,
    platform: params.platform ?? 'windows',
    kind: params.kind ?? 'desktop',
    fingerprint: params.fp,
    host: params.host,
    httpPort: Number(params.http ?? DEFAULT_PORTS.http),
    wsPort: Number(params.ws ?? DEFAULT_PORTS.ws),
    pin: params.pin,
    requiresPin: !!params.pin,
    source: 'qr',
  };
}

export function parseWifiPayload(raw) {
  const m = /WIFI:S:([^;]*);(?:T:([^;]*);)?(?:P:([^;]*);)?/.exec(String(raw));
  return m ? { ssid: m[1], password: m[3] ?? '' } : null;
}

/* ------------------------------------------------------------------ */
/* Formatage                                                           */
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* Empreinte FNV-1a 64 — identique bit à bit à celle du desktop        */
/* ------------------------------------------------------------------ */

const P_LOW = 0x1b3;
const P_HIGH = 0x100; // le prime fait 41 bits : mot haut = 0x100, pas 1
const TWO32 = 4294967296;

export function fnv1a64Init() {
  return { h1: 0xcbf29ce4, h0: 0x84222325 };
}

export function fnv1a64Update(state, bytes) {
  let { h1, h0 } = state;
  for (let i = 0; i < bytes.length; i++) {
    h0 = (h0 ^ bytes[i]) >>> 0;
    const low = h0 * P_LOW;
    const carry = Math.floor(low / TWO32);
    const high = h1 * P_LOW + h0 * P_HIGH + carry;
    h0 = low % TWO32;
    h1 = high % TWO32;
  }
  state.h1 = h1 >>> 0;
  state.h0 = h0 >>> 0;
  return state;
}

export function fnv1a64Digest(state) {
  const hi = (state.h1 >>> 0).toString(16).padStart(8, '0');
  const lo = (state.h0 >>> 0).toString(16).padStart(8, '0');
  return `fnv1a64:${hi}${lo}`;
}

/** Empreinte d'un Uint8Array/Buffer. */
export function hashBytes(bytes) {
  return fnv1a64Digest(fnv1a64Update(fnv1a64Init(), bytes));
}

/** Empreinte d'une chaîne base64 (format renvoyé par expo-file-system). */
export function hashBase64(b64) {
  const state = fnv1a64Init();
  const lookup = {};
  for (let i = 0; i < B64.length; i++) lookup[B64[i]] = i;
  const clean = b64.replace(/[^A-Za-z0-9+/]/g, '');
  const chunk = new Uint8Array(3);
  for (let i = 0; i < clean.length; i += 4) {
    const n0 = lookup[clean[i]] ?? 0;
    const n1 = lookup[clean[i + 1]] ?? 0;
    const n2 = lookup[clean[i + 2]];
    const n3 = lookup[clean[i + 3]];
    chunk[0] = (n0 << 2) | (n1 >> 4);
    let len = 1;
    if (n2 !== undefined) { chunk[1] = ((n1 & 15) << 4) | (n2 >> 2); len = 2; }
    if (n3 !== undefined) { chunk[2] = ((n2 & 3) << 6) | n3; len = 3; }
    fnv1a64Update(state, chunk.subarray(0, len));
  }
  return fnv1a64Digest(state);
}

export function hashMatches(expected, actual) {
  if (!expected) return true;
  return String(expected).toLowerCase() === String(actual).toLowerCase();
}

export function formatBytes(n) {
  if (!n) return '0 o';
  if (n < 1024) return `${Math.round(n)} o`;
  const units = ['Ko', 'Mo', 'Go', 'To'];
  let i = -1; let v = n;
  do { v /= 1024; i++; } while (v >= 1024 && i < units.length - 1);
  return `${v.toFixed(v < 10 ? 1 : 0)} ${units[i]}`;
}

export const formatSpeed = (bps) => `${formatBytes(bps)}/s`;

export function formatEta(remaining, bps) {
  if (!bps || bps <= 0) return '—';
  const s = Math.round(remaining / bps);
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${m % 60} min`;
}

export function guessMime(name = '') {
  const ext = String(name).split('.').pop().toLowerCase();
  const map = {
    jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp',
    heic: 'image/heic', mp4: 'video/mp4', mkv: 'video/x-matroska', mov: 'video/quicktime',
    mp3: 'audio/mpeg', wav: 'audio/wav', m4a: 'audio/mp4', ogg: 'audio/ogg',
    pdf: 'application/pdf', zip: 'application/zip',
    apk: 'application/vnd.android.package-archive',
    txt: 'text/plain', docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  };
  return map[ext] ?? 'application/octet-stream';
}

export function category(mime = '', name = '') {
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return 'audio';
  if (mime.includes('android.package') || /\.apk$/i.test(name)) return 'app';
  if (/zip|rar|7z|tar/.test(mime)) return 'archive';
  if (/pdf|word|excel|text|presentation|sheet|document/.test(mime)) return 'document';
  return 'other';
}

/* ------------------------------------------------------------------ */
/* CastFlowClient                                                      */
/* ------------------------------------------------------------------ */

export class CastFlowClient {
  /**
   * @param {object} device identité du mobile
   * @param {object} deps   { uploadFile } injecté (expo-file-system en prod, fetch en test)
   */
  constructor(device, deps = {}) {
    this.device = device;
    this.deps = deps;
    this.ws = null;
    this.peer = null;
    this.pending = new Map();
    this.listeners = {};
    this.authed = false;
    this.nonce = null;
  }

  on(event, cb) {
    (this.listeners[event] ??= []).push(cb);
    return () => { this.listeners[event] = this.listeners[event].filter((f) => f !== cb); };
  }

  emit(event, payload) {
    (this.listeners[event] ?? []).forEach((cb) => cb(payload));
  }

  get httpBase() {
    return `http://${this.peer.host}:${this.peer.httpPort}`;
  }

  /** Vérifie qu'un hôte répond, sans WebSocket (saisie IP manuelle). */
  static async probe(host, port = DEFAULT_PORTS.http, timeout = 3000) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeout);
    try {
      const res = await fetch(`http://${host}:${port}/info`, { signal: ctrl.signal });
      if (!res.ok) return null;
      const info = await res.json();
      return {
        ...info.device,
        host,
        httpPort: info.http ?? port,
        wsPort: info.ws ?? DEFAULT_PORTS.ws,
        requiresPin: !!info.requiresPin,
        source: 'manual',
      };
    } catch {
      return null;
    } finally {
      clearTimeout(timer);
    }
  }

  connect(peer, timeout = 8000) {
    this.peer = peer;
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://${peer.host}:${peer.wsPort}`);
      this.ws = ws;
      const timer = setTimeout(() => { ws.close(); reject(new Error('Délai de connexion dépassé')); }, timeout);

      ws.onopen = async () => {
        clearTimeout(timer);
        try {
          const ack = await this.request(envelope('HELLO', { device: this.device }));
          this.nonce = ack.data.nonce;
          this.authed = !ack.data.requiresPin;
          this.emit('connected', { peer, requiresPin: ack.data.requiresPin, trusted: ack.data.trusted });
          resolve(ack.data);
        } catch (e) { reject(e); }
      };

      ws.onmessage = (evt) => this._onMessage(evt.data);
      ws.onerror = () => { clearTimeout(timer); reject(new Error('Connexion impossible')); };
      ws.onclose = () => { this.authed = false; this.emit('disconnected'); };
    });
  }

  _onMessage(raw) {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (!msg?.type) return;

    if (msg.re && this.pending.has(msg.re)) {
      const { resolve, timer } = this.pending.get(msg.re);
      clearTimeout(timer);
      this.pending.delete(msg.re);
      resolve(msg);
    }
    this.emit(msg.type, msg.data);
    this.emit('message', msg);
  }

  request(msg, timeout = 30000) {
    return new Promise((resolve, reject) => {
      if (!this.ws || this.ws.readyState !== 1) return reject(new Error('Non connecté'));
      const timer = setTimeout(() => {
        this.pending.delete(msg.id);
        reject(new Error(`Pas de réponse (${msg.type})`));
      }, timeout);
      this.pending.set(msg.id, { resolve, reject, timer });
      this.ws.send(JSON.stringify(msg));
    });
  }

  send(msg) {
    if (this.ws?.readyState === 1) this.ws.send(JSON.stringify(msg));
  }

  /** Prouve la connaissance du PIN. */
  async authenticate(pin) {
    const proof = pinProof(pin, this.nonce, this.device.id);
    const res = await this.request(envelope('AUTH', { proof }));
    if (res.type === 'AUTH_OK') {
      this.authed = true;
      this.emit('authenticated', res.data);
      return { ok: true, token: res.data.sessionToken };
    }
    return { ok: false, reason: res.data?.reason, attemptsLeft: res.data?.attemptsLeft };
  }

  /**
   * Envoie une liste de fichiers. `files` : { id, name, size, mime, uri }
   * Retourne le transferId ; la progression passe par les événements.
   */
  async sendFiles(files, { onProgress, parallel = 2 } = {}) {
    const transferId = uid('t');
    const totalSize = files.reduce((s, f) => s + (f.size || 0), 0);

    const res = await this.request(envelope('TRANSFER_REQUEST', {
      transferId,
      files: files.map((f) => ({
        id: f.id,
        name: f.name,
        size: f.size,
        mime: f.mime || guessMime(f.name),
        // Empreinte facultative : si elle est fournie, le receveur rejette
        // tout fichier corrompu en transit.
        ...(f.hash ? { hash: f.hash } : {}),
      })),
      totalSize,
    }), 120000); // l'utilisateur distant doit accepter

    if (res.type === 'TRANSFER_REJECT') {
      const err = new Error(res.data?.reason || 'Transfert refusé');
      err.code = 'REJECTED';
      throw err;
    }
    if (res.type !== 'TRANSFER_ACCEPT') {
      throw new Error(res.data?.message || 'Réponse inattendue');
    }

    const tokens = res.data.tokens;
    const queue = [...files];
    const started = Date.now();
    let sentTotal = 0;

    const worker = async () => {
      while (queue.length) {
        const f = queue.shift();
        await this.uploadOne(transferId, f, tokens[f.id], (sent) => {
          onProgress?.({
            transferId, fileId: f.id, fileSent: sent, fileSize: f.size,
            totalSent: sentTotal + sent, totalSize,
            bps: (sentTotal + sent) / Math.max(0.001, (Date.now() - started) / 1000),
          });
        });
        sentTotal += f.size;
      }
    };

    await Promise.all(Array.from({ length: Math.min(parallel, files.length) }, worker));
    return transferId;
  }

  /** Upload d'un fichier, avec reprise automatique via HEAD. */
  async uploadOne(transferId, file, token, onProgress) {
    const url = `${this.httpBase}/upload/${transferId}/${file.id}`;

    let offset = 0;
    try {
      const head = await fetch(url, { method: 'HEAD', headers: { 'X-CastFlow-Token': token } });
      if (head.ok) offset = Number(head.headers.get('X-Received-Bytes') || 0);
    } catch { /* on repart de zéro */ }

    if (this.deps.uploadFile) {
      // Production : expo-file-system, streaming natif + progression.
      return this.deps.uploadFile({ url, uri: file.uri, token, offset, onProgress, size: file.size });
    }

    // Fallback / tests : upload en une requête.
    const body = await this.deps.readBody(file, offset);
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'X-CastFlow-Token': token, 'X-Offset': String(offset) },
      body,
    });
    if (!res.ok) {
      const info = await res.json().catch(() => ({}));
      throw new Error(info.message || `Échec de l'envoi (${res.status})`);
    }
    onProgress?.(file.size);
    return res;
  }

  /* ---------------------------------------------------------------- */
  /* Réception : le PC propose des fichiers, le mobile les télécharge  */
  /* ---------------------------------------------------------------- */

  /**
   * Liste les fichiers qu'un transfert entrant met à disposition.
   * Le desktop annonce l'offre via le message OFFER sur le WebSocket.
   */
  async listOffer(transferId) {
    const res = await fetch(`${this.httpBase}/offer/${transferId}`);
    if (!res.ok) throw new Error(`Offre introuvable (${res.status})`);
    return res.json();
  }

  /**
   * Télécharge un fichier offert vers le stockage local.
   * `deps.downloadFile` est fourni par l'app (expo-file-system) ; en test on
   * retombe sur fetch + écriture par le harnais.
   */
  async downloadOne(transferId, file, { onProgress, targetDir } = {}) {
    const url = `${this.httpBase}/download/${transferId}/${file.id}`;
    if (this.deps.downloadFile) {
      return this.deps.downloadFile({
        url, file, token: file.token, targetDir, onProgress,
      });
    }
    const res = await fetch(url, { headers: { 'X-CastFlow-Token': file.token } });
    if (!res.ok) throw new Error(`Téléchargement échoué (${res.status})`);
    const buf = new Uint8Array(await res.arrayBuffer());
    onProgress?.(buf.length);
    if (file.hash && !hashMatches(file.hash, hashBytes(buf))) {
      throw new Error(`Intégrité invalide pour ${file.name}`);
    }
    return buf;
  }

  /** Télécharge toute une offre, séquentiellement pour ménager la mémoire. */
  async receiveFiles(transferId, files, { onProgress, targetDir } = {}) {
    const totalSize = files.reduce((s, f) => s + (f.size || 0), 0);
    const started = Date.now();
    let doneBytes = 0;
    const results = [];

    for (const f of files) {
      const r = await this.downloadOne(transferId, f, {
        targetDir,
        onProgress: (received) => onProgress?.({
          transferId, fileId: f.id, fileReceived: received, fileSize: f.size,
          totalReceived: doneBytes + received, totalSize,
          bps: (doneBytes + received) / Math.max(0.001, (Date.now() - started) / 1000),
        }),
      });
      doneBytes += f.size || 0;
      results.push(r);
    }
    return results;
  }

  cancel(transferId) {
    this.send(envelope('TRANSFER_CANCEL', { transferId, reason: 'Annulé sur le mobile' }));
  }

  disconnect() {
    try { this.ws?.close(); } catch { /* ignore */ }
    this.ws = null;
    this.authed = false;
  }
}
