#!/usr/bin/env node
/**
 * Garde-fou CI : le desktop (CJS), le mobile (ESM) et le paquet partagé (TS)
 * doivent rester d'accord sur les ports, la version et les types de messages.
 * Une divergence casse silencieusement les transferts — ici elle casse le build.
 */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert');

const ROOT = path.resolve(__dirname, '..');
const desktop = require(path.join(ROOT, 'apps/desktop/src/main/core/protocol.js'));
const sharedSrc = fs.readFileSync(path.join(ROOT, 'packages/shared/src/index.ts'), 'utf8');
const mobileSrc = fs.readFileSync(path.join(ROOT, 'apps/mobile/src/client.js'), 'utf8');

const checks = [];
const check = (name, fn) => checks.push([name, fn]);

const num = (src, key) => {
  const m = new RegExp(`${key}\\s*:\\s*(\\d+)`).exec(src);
  return m ? Number(m[1]) : null;
};

check('version de protocole identique partout', () => {
  const shared = num(sharedSrc, 'PROTOCOL_VERSION = 1') !== null
    ? 1
    : Number(/PROTOCOL_VERSION\s*=\s*(\d+)/.exec(sharedSrc)?.[1]);
  const mobile = Number(/PROTOCOL_VERSION\s*=\s*(\d+)/.exec(mobileSrc)?.[1]);
  assert.equal(desktop.PROTOCOL_VERSION, shared, `desktop ${desktop.PROTOCOL_VERSION} ≠ shared ${shared}`);
  assert.equal(desktop.PROTOCOL_VERSION, mobile, `desktop ${desktop.PROTOCOL_VERSION} ≠ mobile ${mobile}`);
});

check('ports par défaut identiques partout', () => {
  for (const key of ['http', 'ws', 'discovery']) {
    const s = num(sharedSrc, key);
    const m = num(mobileSrc, key);
    assert.equal(desktop.DEFAULT_PORTS[key], s, `port ${key} : desktop ${desktop.DEFAULT_PORTS[key]} ≠ shared ${s}`);
    assert.equal(desktop.DEFAULT_PORTS[key], m, `port ${key} : desktop ${desktop.DEFAULT_PORTS[key]} ≠ mobile ${m}`);
  }
});

check('les types de messages du serveur sont déclarés dans shared', () => {
  const serverSrc = fs.readFileSync(path.join(ROOT, 'apps/desktop/src/main/core/server.js'), 'utf8');
  const declared = new Set(
    [...sharedSrc.matchAll(/^\s*\|\s*'([A-Z_]+)'/gm)].map((m) => m[1]),
  );
  const used = new Set([
    ...[...serverSrc.matchAll(/envelope\('([A-Z_]+)'/g)].map((m) => m[1]),
    ...[...serverSrc.matchAll(/case '([A-Z_]+)'/g)].map((m) => m[1]),
  ]);
  const missing = [...used].filter((t) => !declared.has(t));
  assert.equal(missing.length, 0, `types absents de packages/shared : ${missing.join(', ')}`);
});

check('les en-têtes HTTP du mobile correspondent à ceux du serveur', () => {
  const serverSrc = fs.readFileSync(path.join(ROOT, 'apps/desktop/src/main/core/server.js'), 'utf8');
  assert.ok(serverSrc.includes("'x-castflow-token'"), 'le serveur lit X-CastFlow-Token');
  assert.ok(serverSrc.includes("'x-offset'"), 'le serveur lit X-Offset');
  assert.ok(mobileSrc.includes("'X-CastFlow-Token'"), 'le mobile envoie X-CastFlow-Token');
  assert.ok(mobileSrc.includes("'X-Offset'"), 'le mobile envoie X-Offset');
  assert.ok(serverSrc.includes('X-Received-Bytes'), 'le serveur expose X-Received-Bytes');
  assert.ok(mobileSrc.includes('X-Received-Bytes'), 'le mobile lit X-Received-Bytes pour la reprise');
});

check('les routes utilisées par le mobile existent côté serveur', () => {
  const serverSrc = fs.readFileSync(path.join(ROOT, 'apps/desktop/src/main/core/server.js'), 'utf8');
  for (const route of ['upload', 'download', 'info', 'cancel']) {
    assert.ok(
      new RegExp(`seg\\[0\\] === '${route}'`).test(serverSrc),
      `route /${route} absente du serveur`,
    );
  }
  assert.ok(/\/upload\/\$\{transferId\}/.test(mobileSrc), 'le mobile appelle /upload');
  assert.ok(/\/info/.test(mobileSrc), 'le mobile appelle /info');
});

check('le protocole documenté couvre les ports réels', () => {
  const doc = fs.readFileSync(path.join(ROOT, 'docs/PROTOCOL.md'), 'utf8');
  for (const [key, port] of Object.entries(desktop.DEFAULT_PORTS)) {
    assert.ok(doc.includes(String(port)), `port ${key} (${port}) non documenté dans PROTOCOL.md`);
  }
});

let pass = 0;
let fail = 0;
for (const [name, fn] of checks) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
    pass++;
  } catch (e) {
    console.log(`  ✗ ${name}\n      ${e.message}`);
    fail++;
  }
}
console.log(`\n${pass} vérification(s) OK, ${fail} en échec`);
process.exit(fail ? 1 : 0);
