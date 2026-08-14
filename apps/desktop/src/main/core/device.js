// Identité de l'appareil : persistée sur disque, stable entre les lancements.
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function detectPlatform() {
  switch (process.platform) {
    case 'win32': return 'windows';
    case 'darwin': return 'macos';
    default: return 'linux';
  }
}

function loadIdentity(dataDir) {
  const file = path.join(dataDir, 'identity.json');
  try {
    const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (saved.id) return saved;
  } catch { /* première exécution */ }

  const identity = {
    id: crypto.randomUUID(),
    name: os.hostname() || 'CastFlow Desktop',
    platform: detectPlatform(),
    kind: 'desktop',
    fingerprint: crypto.randomBytes(6).toString('hex'),
  };
  fs.mkdirSync(dataDir, { recursive: true });
  fs.writeFileSync(file, JSON.stringify(identity, null, 2));
  return identity;
}

function saveIdentity(dataDir, identity) {
  fs.mkdirSync(dataDir, { recursive: true });
  fs.writeFileSync(path.join(dataDir, 'identity.json'), JSON.stringify(identity, null, 2));
}

/** Adresses IPv4 locales, hotspot en premier (192.168.43.x côté Android). */
function localAddresses() {
  const out = [];
  for (const [iface, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs ?? []) {
      if (a.family === 'IPv4' && !a.internal) {
        out.push({ iface, address: a.address, netmask: a.netmask, cidr: a.cidr });
      }
    }
  }
  const score = (a) => {
    if (a.address.startsWith('192.168.43.')) return 0; // hotspot Android
    if (a.address.startsWith('192.168.')) return 1;
    if (a.address.startsWith('10.')) return 2;
    if (a.address.startsWith('172.')) return 3;
    return 4;
  };
  return out.sort((x, y) => score(x) - score(y));
}

function primaryAddress() {
  return localAddresses()[0]?.address ?? '127.0.0.1';
}

/** Adresses de broadcast de chaque interface, pour le discovery UDP. */
function broadcastAddresses() {
  const out = new Set(['255.255.255.255']);
  for (const a of localAddresses()) {
    const ip = a.address.split('.').map(Number);
    const mask = (a.netmask || '255.255.255.0').split('.').map(Number);
    out.add(ip.map((o, i) => (o & mask[i]) | (~mask[i] & 255)).join('.'));
  }
  return [...out];
}

module.exports = {
  detectPlatform, loadIdentity, saveIdentity,
  localAddresses, primaryAddress, broadcastAddresses,
};
