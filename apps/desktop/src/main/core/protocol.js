// Miroir CommonJS de packages/shared (le main process Electron n'est pas bundlé).
const crypto = require('node:crypto');

const PROTOCOL_VERSION = 1;

const DEFAULT_PORTS = { http: 53317, ws: 53318, discovery: 54545 };

const DISCOVERY = {
  announceIntervalMs: 2000,
  deviceTtlMs: 6000,
};

const LIMITS = {
  maxParallelUploads: 3,
  progressThrottleMs: 200,
  tokenTtlMs: 10 * 60 * 1000,
  pingIntervalMs: 15000,
  maxPinAttempts: 3,
  pinLockoutMs: 60000,
};

function uid(prefix = '') {
  const s = crypto.randomBytes(8).toString('hex');
  return prefix ? `${prefix}_${s}` : s;
}

function envelope(type, data, re) {
  return { v: PROTOCOL_VERSION, type, id: uid('m'), ts: Date.now(), re, data };
}

function parseEnvelope(raw) {
  try {
    const msg = JSON.parse(raw);
    if (!msg || typeof msg.type !== 'string') return null;
    return msg;
  } catch {
    return null;
  }
}

function generatePin() {
  return String(crypto.randomInt(100000, 1000000));
}

function pinProof(pin, nonce, deviceId) {
  return crypto.createHmac('sha256', pin).update(nonce + deviceId).digest('base64');
}

function buildConnectUrl({ host, httpPort, wsPort, device, pin }) {
  const p = new URLSearchParams({
    host,
    http: String(httpPort),
    ws: String(wsPort),
    id: device.id,
    name: device.name,
    kind: device.kind,
    platform: device.platform,
  });
  if (pin) p.set('pin', pin);
  if (device.fingerprint) p.set('fp', device.fingerprint);
  return `castflow://connect?${p.toString()}`;
}

function guessMime(name) {
  const ext = String(name).split('.').pop()?.toLowerCase() ?? '';
  const map = {
    jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif',
    webp: 'image/webp', svg: 'image/svg+xml',
    mp4: 'video/mp4', mkv: 'video/x-matroska', mov: 'video/quicktime',
    mp3: 'audio/mpeg', wav: 'audio/wav', flac: 'audio/flac', m4a: 'audio/mp4',
    pdf: 'application/pdf', zip: 'application/zip',
    apk: 'application/vnd.android.package-archive',
    txt: 'text/plain', md: 'text/markdown', json: 'application/json',
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  };
  return map[ext] ?? 'application/octet-stream';
}

function formatBytes(n) {
  if (n < 1024) return `${n} o`;
  const units = ['Ko', 'Mo', 'Go', 'To'];
  let i = -1; let v = n;
  do { v /= 1024; i++; } while (v >= 1024 && i < units.length - 1);
  return `${v.toFixed(v < 10 ? 1 : 0)} ${units[i]}`;
}

module.exports = {
  PROTOCOL_VERSION, DEFAULT_PORTS, DISCOVERY, LIMITS,
  uid, envelope, parseEnvelope, generatePin, pinProof,
  buildConnectUrl, guessMime, formatBytes,
};
