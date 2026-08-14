/**
 * Vérifie l'empreinte FNV-1a 64 et la détection réelle de corruption.
 * Avant ce module, le serveur renvoyait « hashOk: true » sans rien vérifier.
 */
const assert = require('node:assert');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const WS = require('ws');
global.WebSocket = WS;

const { hashBuffer, hashFile, hashMatches } = require('../src/main/core/hash');
const { CastFlowServer } = require('../src/main/core/server');
const { envelope, parseEnvelope } = require('../src/main/core/protocol');

const tests = [];
const test = (n, f) => tests.push([n, f]);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

/** Référence indépendante, en BigInt. */
function fnvRef(buf) {
  let h = 0xcbf29ce484222325n;
  const P = 0x100000001b3n;
  const M = (1n << 64n) - 1n;
  for (const b of buf) { h ^= BigInt(b); h = (h * P) & M; }
  return `fnv1a64:${h.toString(16).padStart(16, '0')}`;
}

test('vecteurs officiels FNV-1a 64', () => {
  assert.equal(hashBuffer(Buffer.from('')), 'fnv1a64:cbf29ce484222325');
  assert.equal(hashBuffer(Buffer.from('a')), 'fnv1a64:af63dc4c8601ec8c');
  assert.equal(hashBuffer(Buffer.from('foobar')), 'fnv1a64:85944171f73967e8');
});

test('conforme à une référence BigInt sur données aléatoires', () => {
  for (const size of [1, 17, 1024, 65536, 300000]) {
    const buf = crypto.randomBytes(size);
    assert.equal(hashBuffer(buf), fnvRef(buf), `taille ${size}`);
  }
});

test('hashFile en streaming == hashBuffer en une passe', async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'cf-hash-'));
  const buf = crypto.randomBytes(3 * 1024 * 1024 + 12345); // franchit les blocs
  const p = path.join(dir, 'gros.bin');
  await fsp.writeFile(p, buf);
  assert.equal(await hashFile(p), hashBuffer(buf));
});

test('un seul octet modifié change l\'empreinte', () => {
  const a = crypto.randomBytes(50000);
  const b = Buffer.from(a);
  b[25000] ^= 0x01;
  assert.notEqual(hashBuffer(a), hashBuffer(b));
});

test('hashMatches tolère l\'absence d\'empreinte', () => {
  assert.equal(hashMatches(null, 'fnv1a64:abc'), true, 'pas de hash attendu → accepté');
  assert.equal(hashMatches('fnv1a64:ABC', 'fnv1a64:abc'), true, 'insensible à la casse');
  assert.equal(hashMatches('fnv1a64:abc', 'fnv1a64:def'), false);
});

/* ---------------- intégration : corruption détectée ---------------- */

class Peer {
  constructor(url) { this.url = url; this.h = new Map(); }
  connect() {
    return new Promise((res, rej) => {
      this.ws = new WS(this.url);
      this.ws.on('open', res);
      this.ws.on('error', rej);
      this.ws.on('message', (raw) => {
        const m = parseEnvelope(String(raw));
        if (!m) return;
        const cb = this.h.get(m.re);
        if (cb) { this.h.delete(m.re); cb(m); }
        const t = this.h.get(`on:${m.type}`);
        if (t) t(m);
      });
    });
  }
  on(type, cb) { this.h.set(`on:${type}`, cb); }
  req(msg, timeout = 8000) {
    return new Promise((res, rej) => {
      const timer = setTimeout(() => rej(new Error('timeout ' + msg.type)), timeout);
      this.h.set(msg.id, (m) => { clearTimeout(timer); res(m); });
      this.ws.send(JSON.stringify(msg));
    });
  }
  close() { this.ws?.close(); }
}

async function makeServer() {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'cf-hdl-'));
  const server = new CastFlowServer({
    device: { id: 'd', name: 'PC', platform: 'linux', kind: 'desktop' },
    downloadDir: dir, pin: null, autoAccept: true,
  });
  const ports = await server.start(54100 + Math.floor(Math.random() * 200), 54350 + Math.floor(Math.random() * 200));
  return { server, dir, ports };
}

async function send(port, tid, fid, token, body) {
  return fetch(`http://127.0.0.1:${port}/upload/${tid}/${fid}`, {
    method: 'POST',
    headers: { 'X-CastFlow-Token': token, 'X-Offset': '0' },
    body,
    duplex: 'half',
  });
}

test('fichier corrompu en transit : rejeté, pas écrit sur le disque', async () => {
  const { server, dir, ports } = await makeServer();
  const p = new Peer(`ws://127.0.0.1:${ports.wsPort}`);
  await p.connect();
  await p.req(envelope('HELLO', { device: { id: 'm', name: 'Tel', platform: 'android', kind: 'mobile' } }));

  const original = crypto.randomBytes(200 * 1024);
  const corrompu = Buffer.from(original);
  corrompu[1000] ^= 0xff; // un octet altéré, comme une coupure réseau silencieuse

  let fileDone = null;
  p.on('FILE_DONE', (m) => { fileDone = m.data; });

  const acc = await p.req(envelope('TRANSFER_REQUEST', {
    transferId: 'tc', totalSize: original.length,
    files: [{ id: 'f1', name: 'photo.jpg', size: original.length, mime: 'image/jpeg', hash: hashBuffer(original) }],
  }));

  const res = await send(ports.httpPort, 'tc', 'f1', acc.data.tokens.f1, corrompu);
  await wait(200);

  assert.equal(res.status, 422, 'le serveur refuse le fichier');
  assert.equal((await res.json()).code, 'HASH_MISMATCH');
  assert.equal(fileDone?.hashOk, false, 'le pair est informé de l\'échec');

  const restants = await fsp.readdir(dir);
  assert.ok(!restants.includes('photo.jpg'), 'fichier corrompu non livré');
  assert.ok(!restants.some((f) => f.endsWith('.cfpart')), 'fichier temporaire nettoyé');

  p.close();
  await server.stop();
});

test('fichier intact : accepté et empreinte enregistrée', async () => {
  const { server, dir, ports } = await makeServer();
  const p = new Peer(`ws://127.0.0.1:${ports.wsPort}`);
  await p.connect();
  await p.req(envelope('HELLO', { device: { id: 'm', name: 'Tel', platform: 'android', kind: 'mobile' } }));

  const data = crypto.randomBytes(150 * 1024);
  const h = hashBuffer(data);
  let fileDone = null;
  p.on('FILE_DONE', (m) => { fileDone = m.data; });

  const acc = await p.req(envelope('TRANSFER_REQUEST', {
    transferId: 'tk', totalSize: data.length,
    files: [{ id: 'f1', name: 'doc.pdf', size: data.length, mime: 'application/pdf', hash: h }],
  }));

  const res = await send(ports.httpPort, 'tk', 'f1', acc.data.tokens.f1, data);
  await wait(200);

  assert.equal(res.status, 200);
  assert.equal(fileDone?.hashOk, true);
  const written = await fsp.readFile(path.join(dir, 'doc.pdf'));
  assert.ok(written.equals(data));

  const t = server.listTransfers().find((x) => x.id === 'tk');
  assert.equal(t.files[0].hash, h, 'empreinte conservée');
  assert.equal(t.files[0].hashOk, true);

  p.close();
  await server.stop();
});

test('sans empreinte fournie, le transfert reste accepté', async () => {
  const { server, dir, ports } = await makeServer();
  const p = new Peer(`ws://127.0.0.1:${ports.wsPort}`);
  await p.connect();
  await p.req(envelope('HELLO', { device: { id: 'm', name: 'Tel', platform: 'android', kind: 'mobile' } }));

  const data = crypto.randomBytes(20 * 1024);
  const acc = await p.req(envelope('TRANSFER_REQUEST', {
    transferId: 'tn', totalSize: data.length,
    files: [{ id: 'f1', name: 'sans-hash.bin', size: data.length }], // pas de hash
  }));
  const res = await send(ports.httpPort, 'tn', 'f1', acc.data.tokens.f1, data);
  await wait(200);
  assert.equal(res.status, 200);
  assert.ok((await fsp.readFile(path.join(dir, 'sans-hash.bin'))).equals(data));
  p.close();
  await server.stop();
});

test('empreintes desktop et mobile identiques (bytes et base64)', async () => {
  const { hashBytes, hashBase64 } = await import('../../mobile/src/client.js');
  for (const size of [0, 1, 7, 1000, 65537, 250000]) {
    const buf = crypto.randomBytes(size);
    const d = hashBuffer(buf);
    assert.equal(hashBytes(buf), d, `bytes, taille ${size}`);
    assert.equal(hashBase64(buf.toString('base64')), d, `base64, taille ${size}`);
  }
});

(async () => {
  let pass = 0; let fail = 0;
  for (const [name, fn] of tests) {
    try { await fn(); console.log(`  ✓ ${name}`); pass++; }
    catch (e) { console.log(`  ✗ ${name}\n      ${e.message}`); fail++; }
  }
  console.log(`\n${pass} réussis, ${fail} échoués`);
  process.exit(fail ? 1 : 0);
})();
