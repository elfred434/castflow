/**
 * Test bout-en-bout : le VRAI client mobile (apps/mobile/src/client.js)
 * parle au VRAI serveur desktop. Valide que les deux moitiés s'accordent.
 */
const assert = require('node:assert');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

// Le client mobile est en ESM : on le charge via import().
const WS = require('ws');
global.WebSocket = WS; // RN fournit WebSocket globalement

const { CastFlowServer } = require('../src/main/core/server');
const { pinProof: nodePinProof } = require('../src/main/core/protocol');

const tests = [];
const test = (n, f) => tests.push([n, f]);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function makeServer(over = {}) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'cf-e2e-'));
  const server = new CastFlowServer({
    device: { id: 'desk', name: 'PC Elfred', platform: 'linux', kind: 'desktop', fingerprint: 'ff00aa' },
    downloadDir: dir,
    pin: null,
    autoAccept: true,
    ...over,
  });
  const ports = await server.start(53700 + Math.floor(Math.random() * 200), 53950 + Math.floor(Math.random() * 40));
  return { server, dir, ports };
}

const mobileDevice = { id: 'pixel-7', name: 'Pixel 7', platform: 'android', kind: 'mobile', fingerprint: 'bb11cc' };

/** deps pour le client : lit un fichier local et renvoie un Buffer. */
const deps = {
  readBody: async (file, offset) => {
    const buf = await fsp.readFile(file.uri);
    return buf.subarray(offset);
  },
};

(async () => {
  const { CastFlowClient, pinProof, parseConnectUrl, hmacSha256Base64, formatBytes } =
    await import('../../mobile/src/client.js');

  test('HMAC JS du mobile == HMAC natif de Node', () => {
    const a = pinProof('482913', 'nonce-abc==', 'pixel-7');
    const b = nodePinProof('482913', 'nonce-abc==', 'pixel-7');
    assert.equal(a, b, 'les preuves PIN doivent être identiques');
    assert.equal(
      hmacSha256Base64('key', 'The quick brown fox jumps over the lazy dog'),
      crypto.createHmac('sha256', 'key').update('The quick brown fox jumps over the lazy dog').digest('base64'),
    );
  });

  test('parseConnectUrl lit le QR généré par le desktop', () => {
    const { buildConnectUrl } = require('../src/main/core/protocol');
    const url = buildConnectUrl({
      host: '192.168.43.1', httpPort: 53317, wsPort: 53318,
      device: { id: 'desk', name: 'PC de Elfred', kind: 'desktop', platform: 'windows', fingerprint: 'ff00aa' },
      pin: '482913',
    });
    const parsed = parseConnectUrl(url);
    assert.equal(parsed.host, '192.168.43.1');
    assert.equal(parsed.name, 'PC de Elfred');
    assert.equal(parsed.httpPort, 53317);
    assert.equal(parsed.pin, '482913');
    assert.equal(parsed.requiresPin, true);
    // Tolère le préfixe Wi-Fi du mode hotspot.
    const combo = `WIFI:S:CastFlow-42;T:WPA;P:secret123;;${url}`;
    assert.equal(parseConnectUrl(combo).host, '192.168.43.1');
  });

  test('probe() découvre un hôte par son IP', async () => {
    const { server, ports } = await makeServer();
    const found = await CastFlowClient.probe('127.0.0.1', ports.httpPort);
    assert.ok(found, 'hôte trouvé');
    assert.equal(found.name, 'PC Elfred');
    assert.equal(found.wsPort, ports.wsPort);
    const missing = await CastFlowClient.probe('127.0.0.1', 1, 500);
    assert.equal(missing, null, 'hôte injoignable → null');
    await server.stop();
  });

  test('mobile → desktop : envoi de 3 fichiers', async () => {
    const { server, dir, ports } = await makeServer();
    const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'cf-src-'));

    const files = [];
    for (let i = 0; i < 3; i++) {
      const p = path.join(tmp, `media${i}.jpg`);
      const payload = crypto.randomBytes(400 * 1024);
      await fsp.writeFile(p, payload);
      files.push({ id: `f${i}`, name: `media${i}.jpg`, size: payload.length, mime: 'image/jpeg', uri: p, payload });
    }

    const client = new CastFlowClient(mobileDevice, deps);
    await client.connect({ host: '127.0.0.1', httpPort: ports.httpPort, wsPort: ports.wsPort });

    let lastProgress = null;
    const transferId = await client.sendFiles(files, { onProgress: (p) => { lastProgress = p; } });
    assert.ok(transferId);
    await wait(250);

    for (const f of files) {
      const written = await fsp.readFile(path.join(dir, f.name));
      assert.ok(written.equals(f.payload), `${f.name} identique à l'original`);
    }
    assert.ok(lastProgress, 'progression rapportée');
    console.log(`    (${formatBytes(lastProgress.totalSize)} transférés)`);

    client.disconnect();
    await server.stop();
  });

  test('mobile → desktop avec PIN correct', async () => {
    const { server, dir, ports } = await makeServer({ pin: '135790' });
    const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'cf-src-'));
    const p = path.join(tmp, 'secret.pdf');
    const payload = crypto.randomBytes(120 * 1024);
    await fsp.writeFile(p, payload);

    const client = new CastFlowClient(mobileDevice, deps);
    const ack = await client.connect({ host: '127.0.0.1', httpPort: ports.httpPort, wsPort: ports.wsPort });
    assert.equal(ack.requiresPin, true);
    assert.equal(client.authed, false);

    const bad = await client.authenticate('000000');
    assert.equal(bad.ok, false, 'mauvais PIN rejeté');

    const good = await client.authenticate('135790');
    assert.equal(good.ok, true, 'bon PIN accepté');
    assert.equal(client.authed, true);

    await client.sendFiles([{ id: 'f1', name: 'secret.pdf', size: payload.length, mime: 'application/pdf', uri: p }]);
    await wait(200);
    const written = await fsp.readFile(path.join(dir, 'secret.pdf'));
    assert.ok(written.equals(payload));

    client.disconnect();
    await server.stop();
  });

  test('refus côté desktop → erreur REJECTED côté mobile', async () => {
    const { server, ports } = await makeServer({ autoAccept: false });
    server.on('incoming-request', ({ reject }) => setTimeout(() => reject('Occupé'), 60));
    const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'cf-src-'));
    const p = path.join(tmp, 'x.txt');
    await fsp.writeFile(p, 'hello');

    const client = new CastFlowClient(mobileDevice, deps);
    await client.connect({ host: '127.0.0.1', httpPort: ports.httpPort, wsPort: ports.wsPort });

    await assert.rejects(
      () => client.sendFiles([{ id: 'f1', name: 'x.txt', size: 5, mime: 'text/plain', uri: p }]),
      (e) => e.code === 'REJECTED' && /Occupé/.test(e.message),
    );
    client.disconnect();
    await server.stop();
  });

  test('acceptation manuelle depuis l\'UI desktop', async () => {
    const { server, dir, ports } = await makeServer({ autoAccept: false });
    let seen = null;
    server.on('incoming-request', ({ transfer, accept }) => {
      seen = transfer;
      setTimeout(accept, 80); // l'utilisateur clique "Accepter"
    });

    const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'cf-src-'));
    const p = path.join(tmp, 'rapport.docx');
    const payload = crypto.randomBytes(80 * 1024);
    await fsp.writeFile(p, payload);

    const client = new CastFlowClient(mobileDevice, deps);
    await client.connect({ host: '127.0.0.1', httpPort: ports.httpPort, wsPort: ports.wsPort });
    await client.sendFiles([{ id: 'f1', name: 'rapport.docx', size: payload.length, mime: 'application/msword', uri: p }]);
    await wait(200);

    assert.ok(seen, 'l\'UI a reçu la demande');
    assert.equal(seen.peer.name, 'Pixel 7');
    assert.equal(seen.files[0].name, 'rapport.docx');
    const written = await fsp.readFile(path.join(dir, 'rapport.docx'));
    assert.ok(written.equals(payload));

    client.disconnect();
    await server.stop();
  });

  test('desktop → mobile : téléchargement des fichiers offerts', async () => {
    const { server, dir, ports } = await makeServer();
    const src = path.join(dir, 'film.mp4');
    const payload = crypto.randomBytes(700 * 1024);
    await fsp.writeFile(src, payload);

    const offer = server.offerFiles([
      { id: 'd1', name: 'film.mp4', size: payload.length, mime: 'video/mp4', path: src },
    ]);

    const res = await fetch(`http://127.0.0.1:${ports.httpPort}${offer.files[0].url}`, {
      headers: { 'X-CastFlow-Token': offer.files[0].token },
    });
    assert.equal(res.status, 200);
    const got = Buffer.from(await res.arrayBuffer());
    assert.ok(got.equals(payload), 'le mobile récupère le fichier intact');
    await server.stop();
  });

  test('reprise : le mobile relance un upload interrompu', async () => {
    const { server, dir, ports } = await makeServer();
    const tmp = await fsp.mkdtemp(path.join(os.tmpdir(), 'cf-src-'));
    const p = path.join(tmp, 'gros.bin');
    const payload = crypto.randomBytes(900 * 1024);
    await fsp.writeFile(p, payload);

    const client = new CastFlowClient(mobileDevice, deps);
    await client.connect({ host: '127.0.0.1', httpPort: ports.httpPort, wsPort: ports.wsPort });

    const file = { id: 'f1', name: 'gros.bin', size: payload.length, mime: 'application/octet-stream', uri: p };
    const res = await client.request(
      (await import('../../mobile/src/client.js')).envelope('TRANSFER_REQUEST', {
        transferId: 'tr1', files: [{ id: file.id, name: file.name, size: file.size, mime: file.mime }], totalSize: file.size,
      }),
    );
    const token = res.data.tokens.f1;

    // Première tentative avortée.
    const ctrl = new AbortController();
    const partial = fetch(`http://127.0.0.1:${ports.httpPort}/upload/tr1/f1`, {
      method: 'POST',
      headers: { 'X-CastFlow-Token': token, 'X-Offset': '0' },
      body: payload.subarray(0, 400 * 1024),
      signal: ctrl.signal,
      duplex: 'half',
    }).catch(() => null);
    await wait(100);
    ctrl.abort();
    await partial;
    await wait(120);

    // Le client reprend automatiquement (uploadOne fait le HEAD).
    await client.uploadOne('tr1', file, token, () => {});
    await wait(200);

    const written = await fsp.readFile(path.join(dir, 'gros.bin'));
    assert.equal(written.length, payload.length);
    assert.ok(written.equals(payload), 'fichier intact après reprise');

    client.disconnect();
    await server.stop();
  });

  let pass = 0; let fail = 0;
  for (const [name, fn] of tests) {
    try { await fn(); console.log(`  ✓ ${name}`); pass++; }
    catch (e) { console.log(`  ✗ ${name}\n      ${e.message}`); fail++; }
  }
  console.log(`\n${pass} réussis, ${fail} échoués`);
  process.exit(fail ? 1 : 0);
})();
