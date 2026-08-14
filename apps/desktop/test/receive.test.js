/**
 * Sens desktop → mobile : le PC propose des fichiers, le vrai client mobile
 * les découvre, les télécharge et vérifie leur intégrité.
 */
const assert = require('node:assert');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const WS = require('ws');
global.WebSocket = WS;

const { CastFlowServer } = require('../src/main/core/server');
const { hashFile } = require('../src/main/core/hash');

const tests = [];
const test = (n, f) => tests.push([n, f]);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const mobile = { id: 'pixel', name: 'Pixel 7', platform: 'android', kind: 'mobile' };

async function makeServer() {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'cf-recv-'));
  const server = new CastFlowServer({
    device: { id: 'pc', name: 'PC Elfred', platform: 'linux', kind: 'desktop' },
    downloadDir: dir, pin: null, autoAccept: true,
  });
  const ports = await server.start(54600 + Math.floor(Math.random() * 150), 54800 + Math.floor(Math.random() * 150));
  return { server, dir, ports };
}

(async () => {
  const { CastFlowClient, hashBytes, uid } = await import('../../mobile/src/client.js');

  test('GET /offer liste les fichiers proposés', async () => {
    const { server, dir, ports } = await makeServer();
    const p1 = path.join(dir, 'a.bin');
    const p2 = path.join(dir, 'b.txt');
    await fsp.writeFile(p1, crypto.randomBytes(1000));
    await fsp.writeFile(p2, 'bonjour');

    const offer = server.offerFiles([
      { id: 'o1', name: 'a.bin', size: 1000, mime: 'application/octet-stream', path: p1 },
      { id: 'o2', name: 'b.txt', size: 7, mime: 'text/plain', path: p2 },
    ]);

    const client = new CastFlowClient(mobile, {});
    await client.connect({ host: '127.0.0.1', httpPort: ports.httpPort, wsPort: ports.wsPort });

    const listed = await client.listOffer(offer.transferId);
    assert.equal(listed.files.length, 2);
    assert.equal(listed.totalSize, 1007);
    assert.ok(listed.files[0].token, 'jeton fourni');
    client.disconnect();
    await server.stop();
  });

  test('le mobile reçoit une offre par WebSocket', async () => {
    const { server, dir, ports } = await makeServer();
    const src = path.join(dir, 'photo.jpg');
    await fsp.writeFile(src, crypto.randomBytes(5000));

    const client = new CastFlowClient(mobile, {});
    await client.connect({ host: '127.0.0.1', httpPort: ports.httpPort, wsPort: ports.wsPort });

    const received = new Promise((resolve) => client.on('OFFER', resolve));
    server.offerFiles([{ id: 'o1', name: 'photo.jpg', size: 5000, mime: 'image/jpeg', path: src }]);

    const data = await Promise.race([received, wait(3000).then(() => null)]);
    assert.ok(data, 'message OFFER reçu');
    assert.equal(data.files[0].name, 'photo.jpg');
    client.disconnect();
    await server.stop();
  });

  test('téléchargement complet et intègre', async () => {
    const { server, dir, ports } = await makeServer();
    const payload = crypto.randomBytes(600 * 1024);
    const src = path.join(dir, 'film.mp4');
    await fsp.writeFile(src, payload);

    const offer = server.offerFiles([
      { id: 'o1', name: 'film.mp4', size: payload.length, mime: 'video/mp4', path: src },
    ]);
    await wait(150); // laisse le hash se calculer

    const client = new CastFlowClient(mobile, {});
    await client.connect({ host: '127.0.0.1', httpPort: ports.httpPort, wsPort: ports.wsPort });

    const listed = await client.listOffer(offer.transferId);
    assert.ok(listed.files[0].hash, 'empreinte calculée côté PC');

    let progress = null;
    const [buf] = await client.receiveFiles(offer.transferId, listed.files, {
      onProgress: (p) => { progress = p; },
    });

    assert.equal(buf.length, payload.length);
    assert.ok(Buffer.from(buf).equals(payload), 'contenu identique');
    assert.equal(hashBytes(buf), await hashFile(src), 'empreintes mobile et desktop identiques');
    assert.ok(progress, 'progression rapportée');

    client.disconnect();
    await server.stop();
  });

  test('téléchargement de plusieurs fichiers', async () => {
    const { server, dir, ports } = await makeServer();
    const files = [];
    for (let i = 0; i < 4; i++) {
      const payload = crypto.randomBytes(80 * 1024);
      const p = path.join(dir, `doc${i}.pdf`);
      await fsp.writeFile(p, payload);
      files.push({ id: `o${i}`, name: `doc${i}.pdf`, size: payload.length, mime: 'application/pdf', path: p, payload });
    }
    const offer = server.offerFiles(files.map(({ payload, ...f }) => f));
    await wait(200);

    const client = new CastFlowClient(mobile, {});
    await client.connect({ host: '127.0.0.1', httpPort: ports.httpPort, wsPort: ports.wsPort });
    const listed = await client.listOffer(offer.transferId);
    const bufs = await client.receiveFiles(offer.transferId, listed.files);

    assert.equal(bufs.length, 4);
    bufs.forEach((b, i) => {
      assert.ok(Buffer.from(b).equals(files[i].payload), `doc${i}.pdf intact`);
    });
    client.disconnect();
    await server.stop();
  });

  test('empreinte falsifiée : le mobile refuse le fichier', async () => {
    const { server, dir, ports } = await makeServer();
    const src = path.join(dir, 'suspect.bin');
    await fsp.writeFile(src, crypto.randomBytes(10 * 1024));
    const offer = server.offerFiles([
      { id: 'o1', name: 'suspect.bin', size: 10 * 1024, mime: 'application/octet-stream', path: src },
    ]);
    await wait(150);

    const client = new CastFlowClient(mobile, {});
    await client.connect({ host: '127.0.0.1', httpPort: ports.httpPort, wsPort: ports.wsPort });
    const listed = await client.listOffer(offer.transferId);

    // On simule une empreinte qui ne correspond pas au contenu reçu.
    const falsifie = { ...listed.files[0], hash: 'fnv1a64:0000000000000000' };
    await assert.rejects(
      () => client.downloadOne(offer.transferId, falsifie),
      /Intégrité invalide/,
    );
    client.disconnect();
    await server.stop();
  });

  test('jeton invalide : téléchargement refusé', async () => {
    const { server, dir, ports } = await makeServer();
    const src = path.join(dir, 'prive.txt');
    await fsp.writeFile(src, 'secret');
    const offer = server.offerFiles([
      { id: 'o1', name: 'prive.txt', size: 6, mime: 'text/plain', path: src },
    ]);

    const client = new CastFlowClient(mobile, {});
    await client.connect({ host: '127.0.0.1', httpPort: ports.httpPort, wsPort: ports.wsPort });
    await assert.rejects(
      () => client.downloadOne(offer.transferId, { id: 'o1', name: 'prive.txt', size: 6, token: 'faux' }),
      /401/,
    );
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
