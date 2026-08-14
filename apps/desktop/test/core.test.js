// Test d'intégration du cœur CastFlow : simule un mobile qui envoie des fichiers.
const assert = require('node:assert');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const WebSocket = require('ws');

const { CastFlowServer } = require('../src/main/core/server');
const { Discovery } = require('../src/main/core/discovery');
const { envelope, parseEnvelope, pinProof } = require('../src/main/core/protocol');

const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

/** Client WS minimal simulant l'app mobile. */
class MobileClient {
  constructor(url, device) {
    this.url = url;
    this.device = device;
    this.handlers = new Map();
  }
  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url);
      this.ws.on('open', resolve);
      this.ws.on('error', reject);
      this.ws.on('message', (raw) => {
        const msg = parseEnvelope(String(raw));
        if (!msg) return;
        const key = msg.re ?? msg.type;
        const h = this.handlers.get(key);
        if (h) { this.handlers.delete(key); h(msg); }
        const t = this.handlers.get(`on:${msg.type}`);
        if (t) t(msg);
      });
    });
  }
  on(type, cb) { this.handlers.set(`on:${type}`, cb); }
  request(msg, timeout = 5000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`timeout ${msg.type}`)), timeout);
      this.handlers.set(msg.id, (m) => { clearTimeout(timer); resolve(m); });
      this.ws.send(JSON.stringify(msg));
    });
  }
  close() { this.ws?.close(); }
}

async function upload(port, transferId, file, token, buffer, offset = 0) {
  const res = await fetch(`http://127.0.0.1:${port}/upload/${transferId}/${file.id}`, {
    method: 'POST',
    headers: {
      'X-CastFlow-Token': token,
      'X-Offset': String(offset),
      'Content-Length': String(buffer.length - offset),
    },
    body: buffer.subarray(offset),
    duplex: 'half',
  });
  return res;
}

async function makeServer(overrides = {}) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'castflow-'));
  const server = new CastFlowServer({
    device: { id: 'desktop-1', name: 'PC Test', platform: 'linux', kind: 'desktop', fingerprint: 'abc123' },
    downloadDir: dir,
    pin: null,
    autoAccept: true,
    ...overrides,
  });
  const ports = await server.start(0 || 53400 + Math.floor(Math.random() * 100), 53600 + Math.floor(Math.random() * 100));
  return { server, dir, ports };
}

/* ------------------------------------------------------------------ */

test('GET /info expose l\'identité et les ports', async () => {
  const { server, ports } = await makeServer();
  const info = await (await fetch(`http://127.0.0.1:${ports.httpPort}/info`)).json();
  assert.equal(info.device.name, 'PC Test');
  assert.equal(info.http, ports.httpPort);
  assert.equal(info.requiresPin, false);
  await server.stop();
});

test('handshake HELLO → HELLO_ACK', async () => {
  const { server, ports } = await makeServer();
  const m = new MobileClient(`ws://127.0.0.1:${ports.wsPort}`, { id: 'mob-1', name: 'Pixel', platform: 'android', kind: 'mobile' });
  await m.connect();
  const ack = await m.request(envelope('HELLO', { device: m.device }));
  assert.equal(ack.type, 'HELLO_ACK');
  assert.equal(ack.data.device.id, 'desktop-1');
  assert.ok(ack.data.nonce);
  m.close();
  await server.stop();
});

test('transfert complet d\'un fichier avec progression', async () => {
  const { server, dir, ports } = await makeServer();
  const m = new MobileClient(`ws://127.0.0.1:${ports.wsPort}`, { id: 'mob-1', name: 'Pixel', platform: 'android', kind: 'mobile' });
  await m.connect();
  await m.request(envelope('HELLO', { device: m.device }));

  const payload = crypto.randomBytes(3 * 1024 * 1024); // 3 Mo
  const file = { id: 'f1', name: 'photo.jpg', size: payload.length, mime: 'image/jpeg' };

  let progressSeen = 0;
  m.on('PROGRESS', () => progressSeen++);
  let completed = null;
  m.on('TRANSFER_COMPLETE', (msg) => { completed = msg.data; });

  const accept = await m.request(envelope('TRANSFER_REQUEST', {
    transferId: 't1', files: [file], totalSize: file.size,
  }));
  assert.equal(accept.type, 'TRANSFER_ACCEPT');
  const token = accept.data.tokens.f1;
  assert.ok(token);

  const res = await upload(ports.httpPort, 't1', file, token, payload);
  assert.equal(res.status, 200);
  await wait(150);

  const written = await fsp.readFile(path.join(dir, 'photo.jpg'));
  assert.equal(written.length, payload.length);
  assert.ok(written.equals(payload), 'contenu identique');
  assert.ok(completed, 'TRANSFER_COMPLETE reçu');
  console.log(`    (${progressSeen} événements de progression)`);

  m.close();
  await server.stop();
});

test('token invalide → 401', async () => {
  const { server, ports } = await makeServer();
  const m = new MobileClient(`ws://127.0.0.1:${ports.wsPort}`, { id: 'mob-1', name: 'Pixel', platform: 'android', kind: 'mobile' });
  await m.connect();
  await m.request(envelope('HELLO', { device: m.device }));
  const file = { id: 'f1', name: 'a.txt', size: 4, mime: 'text/plain' };
  await m.request(envelope('TRANSFER_REQUEST', { transferId: 't2', files: [file], totalSize: 4 }));
  const res = await upload(ports.httpPort, 't2', file, 'mauvais-token', Buffer.from('abcd'));
  assert.equal(res.status, 401);
  assert.equal((await res.json()).code, 'BAD_TOKEN');
  m.close();
  await server.stop();
});

test('reprise après coupure (HEAD + X-Offset)', async () => {
  const { server, dir, ports } = await makeServer();
  const m = new MobileClient(`ws://127.0.0.1:${ports.wsPort}`, { id: 'mob-1', name: 'Pixel', platform: 'android', kind: 'mobile' });
  await m.connect();
  await m.request(envelope('HELLO', { device: m.device }));

  const payload = crypto.randomBytes(512 * 1024);
  const file = { id: 'f1', name: 'video.mp4', size: payload.length, mime: 'video/mp4' };
  const accept = await m.request(envelope('TRANSFER_REQUEST', { transferId: 't3', files: [file], totalSize: file.size }));
  const token = accept.data.tokens.f1;

  // Envoi partiel puis abandon.
  const half = payload.length / 2;
  const ctrl = new AbortController();
  const partial = fetch(`http://127.0.0.1:${ports.httpPort}/upload/t3/f1`, {
    method: 'POST',
    headers: { 'X-CastFlow-Token': token, 'X-Offset': '0' },
    body: payload.subarray(0, half),
    signal: ctrl.signal,
    duplex: 'half',
  }).catch(() => null);
  await wait(120);
  ctrl.abort();
  await partial;
  await wait(120);

  const head = await fetch(`http://127.0.0.1:${ports.httpPort}/upload/t3/f1`, {
    method: 'HEAD', headers: { 'X-CastFlow-Token': token },
  });
  const received = Number(head.headers.get('X-Received-Bytes'));
  assert.ok(received >= 0, 'octets déjà reçus exposés');

  const res = await upload(ports.httpPort, 't3', file, token, payload, received);
  assert.equal(res.status, 200);
  await wait(150);

  const written = await fsp.readFile(path.join(dir, 'video.mp4'));
  assert.equal(written.length, payload.length);
  assert.ok(written.equals(payload), 'fichier reconstitué intact après reprise');
  console.log(`    (repris à ${received} octets)`);

  m.close();
  await server.stop();
});

test('PIN : mauvais code refusé, bon code accepté', async () => {
  const { server, ports } = await makeServer({ pin: '482913', autoAccept: true });
  const m = new MobileClient(`ws://127.0.0.1:${ports.wsPort}`, { id: 'mob-2', name: 'Pixel', platform: 'android', kind: 'mobile' });
  await m.connect();
  const ack = await m.request(envelope('HELLO', { device: m.device }));
  assert.equal(ack.data.requiresPin, true);

  const bad = await m.request(envelope('AUTH', { proof: pinProof('000000', ack.data.nonce, m.device.id) }));
  assert.equal(bad.type, 'AUTH_FAIL');

  const ok = await m.request(envelope('AUTH', { proof: pinProof('482913', ack.data.nonce, m.device.id) }));
  assert.equal(ok.type, 'AUTH_OK');
  assert.ok(ok.data.sessionToken);
  m.close();
  await server.stop();
});

test('transfert refusé sans authentification', async () => {
  const { server, ports } = await makeServer({ pin: '111111' });
  const m = new MobileClient(`ws://127.0.0.1:${ports.wsPort}`, { id: 'mob-3', name: 'Pixel', platform: 'android', kind: 'mobile' });
  await m.connect();
  await m.request(envelope('HELLO', { device: m.device }));
  const err = await m.request(envelope('TRANSFER_REQUEST', {
    transferId: 't4', files: [{ id: 'f1', name: 'x.txt', size: 1 }], totalSize: 1,
  }));
  assert.equal(err.type, 'ERROR');
  assert.equal(err.data.code, 'AUTH_REQUIRED');
  m.close();
  await server.stop();
});

test('refus manuel → TRANSFER_REJECT', async () => {
  const { server, ports } = await makeServer({ autoAccept: false });
  server.on('incoming-request', ({ reject }) => reject('Pas maintenant'));
  const m = new MobileClient(`ws://127.0.0.1:${ports.wsPort}`, { id: 'mob-4', name: 'Pixel', platform: 'android', kind: 'mobile' });
  await m.connect();
  await m.request(envelope('HELLO', { device: m.device }));
  const rep = await m.request(envelope('TRANSFER_REQUEST', {
    transferId: 't5', files: [{ id: 'f1', name: 'x.txt', size: 1 }], totalSize: 1,
  }));
  assert.equal(rep.type, 'TRANSFER_REJECT');
  assert.equal(rep.data.reason, 'Pas maintenant');
  m.close();
  await server.stop();
});

test('multi-fichiers : 5 fichiers en parallèle', async () => {
  const { server, dir, ports } = await makeServer();
  const m = new MobileClient(`ws://127.0.0.1:${ports.wsPort}`, { id: 'mob-5', name: 'Pixel', platform: 'android', kind: 'mobile' });
  await m.connect();
  await m.request(envelope('HELLO', { device: m.device }));

  const files = Array.from({ length: 5 }, (_, i) => ({
    id: `f${i}`, name: `doc${i}.bin`, size: 200 * 1024, mime: 'application/octet-stream',
    payload: crypto.randomBytes(200 * 1024),
  }));
  const accept = await m.request(envelope('TRANSFER_REQUEST', {
    transferId: 't6',
    files: files.map(({ payload, ...f }) => f),
    totalSize: files.reduce((s, f) => s + f.size, 0),
  }));

  await Promise.all(files.map((f) => upload(ports.httpPort, 't6', f, accept.data.tokens[f.id], f.payload)));
  await wait(200);

  for (const f of files) {
    const w = await fsp.readFile(path.join(dir, f.name));
    assert.ok(w.equals(f.payload), `${f.name} intact`);
  }
  const t = server.listTransfers().find((x) => x.id === 't6');
  assert.equal(t.state, 'completed');
  m.close();
  await server.stop();
});

test('download desktop → mobile avec Range', async () => {
  const { server, dir, ports } = await makeServer();
  const src = path.join(dir, 'source.bin');
  const payload = crypto.randomBytes(300 * 1024);
  await fsp.writeFile(src, payload);

  const offer = server.offerFiles([{ id: 'd1', name: 'source.bin', size: payload.length, mime: 'application/octet-stream', path: src }]);
  const token = offer.files[0].token;

  const full = await fetch(`http://127.0.0.1:${ports.httpPort}/download/${offer.transferId}/d1`, {
    headers: { 'X-CastFlow-Token': token },
  });
  assert.equal(full.status, 200);
  const got = Buffer.from(await full.arrayBuffer());
  assert.ok(got.equals(payload), 'téléchargement intégral correct');

  const part = await fetch(`http://127.0.0.1:${ports.httpPort}/download/${offer.transferId}/d1`, {
    headers: { 'X-CastFlow-Token': token, Range: 'bytes=0-1023' },
  });
  assert.equal(part.status, 206);
  assert.equal(Buffer.from(await part.arrayBuffer()).length, 1024);

  await server.stop();
});

test('noms de fichiers dangereux neutralisés', async () => {
  const { server, dir, ports } = await makeServer();
  const m = new MobileClient(`ws://127.0.0.1:${ports.wsPort}`, { id: 'mob-6', name: 'Pixel', platform: 'android', kind: 'mobile' });
  await m.connect();
  await m.request(envelope('HELLO', { device: m.device }));
  const file = { id: 'f1', name: '../../../etc/passwd', size: 5, mime: 'text/plain' };
  const accept = await m.request(envelope('TRANSFER_REQUEST', { transferId: 't7', files: [file], totalSize: 5 }));
  await upload(ports.httpPort, 't7', file, accept.data.tokens.f1, Buffer.from('hello'));
  await wait(150);
  const entries = await fsp.readdir(dir);
  assert.ok(!entries.some((e) => e.includes('..')), 'aucune traversée de chemin');
  console.log(`    (écrit sous "${entries[0]}")`);
  m.close();
  await server.stop();
});

test('collision de nom → suffixe (1)', async () => {
  const { server, dir, ports } = await makeServer();
  await fsp.writeFile(path.join(dir, 'note.txt'), 'déjà là');
  const m = new MobileClient(`ws://127.0.0.1:${ports.wsPort}`, { id: 'mob-7', name: 'Pixel', platform: 'android', kind: 'mobile' });
  await m.connect();
  await m.request(envelope('HELLO', { device: m.device }));
  const file = { id: 'f1', name: 'note.txt', size: 3, mime: 'text/plain' };
  const accept = await m.request(envelope('TRANSFER_REQUEST', { transferId: 't8', files: [file], totalSize: 3 }));
  await upload(ports.httpPort, 't8', file, accept.data.tokens.f1, Buffer.from('abc'));
  await wait(150);
  assert.ok(fs.existsSync(path.join(dir, 'note (1).txt')), 'fichier renommé');
  m.close();
  await server.stop();
});

test('découverte UDP : deux appareils se voient', async () => {
  const a = new Discovery({
    device: { id: 'dev-a', name: 'PC A', platform: 'linux', kind: 'desktop' },
    httpPort: 53317, wsPort: 53318, port: 54547,
  });
  const b = new Discovery({
    device: { id: 'dev-b', name: 'Tel B', platform: 'android', kind: 'mobile' },
    httpPort: 53319, wsPort: 53320, port: 54547,
  });
  await a.start();
  await b.start();
  b.refresh();
  await wait(2500);
  const seenByA = a.list().map((d) => d.id);
  const seenByB = b.list().map((d) => d.id);
  a.stop(); b.stop();
  assert.ok(seenByA.includes('dev-b'), `A voit B (${seenByA})`);
  assert.ok(seenByB.includes('dev-a'), `B voit A (${seenByB})`);
});

/* ------------------------------------------------------------------ */

(async () => {
  let pass = 0; let fail = 0;
  for (const [name, fn] of tests) {
    try {
      await fn();
      console.log(`  ✓ ${name}`);
      pass++;
    } catch (e) {
      console.log(`  ✗ ${name}\n      ${e.message}`);
      fail++;
    }
  }
  console.log(`\n${pass} réussis, ${fail} échoués`);
  process.exit(fail ? 1 : 0);
})();
