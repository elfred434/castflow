#!/usr/bin/env node
/**
 * Valide la configuration de packaging desktop sans lancer electron-builder
 * (qui télécharge ~200 Mo). Ces réglages ne cassent qu'au moment de la
 * release : autant les vérifier à chaque commit.
 */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert');

const ROOT = path.resolve(__dirname, '..');
const pkg = require(path.join(ROOT, 'apps/desktop/package.json'));
const b = pkg.build ?? {};

const checks = [];
const check = (name, fn) => checks.push([name, fn]);

check('identité de l\'application définie', () => {
  assert.ok(b.appId, 'build.appId manquant');
  assert.ok(b.productName, 'build.productName manquant');
  assert.match(b.appId, /^[a-z0-9.]+$/, 'appId doit être en minuscules, style com.exemple.app');
});

check('point d\'entrée Electron valide', () => {
  const main = b.extraMetadata?.main ?? pkg.main;
  assert.ok(main, 'champ main absent');
  assert.ok(
    fs.existsSync(path.join(ROOT, 'apps/desktop', main)),
    `le point d'entrée ${main} n'existe pas`,
  );
});

check('les fichiers embarqués couvrent le nécessaire', () => {
  const files = b.files ?? [];
  const joined = files.join(' ');
  for (const needed of ['src/main', 'src/preload', 'dist']) {
    assert.ok(joined.includes(needed), `« ${needed} » absent de build.files`);
  }
  assert.ok(joined.includes('!test'), 'les tests ne devraient pas être embarqués');
});

check('cibles des trois plateformes déclarées', () => {
  assert.ok(b.linux?.target?.length, 'aucune cible Linux');
  assert.ok(b.win?.target?.length, 'aucune cible Windows');
  assert.ok(b.mac?.target?.length, 'aucune cible macOS');
  const linux = JSON.stringify(b.linux.target);
  assert.ok(linux.includes('AppImage'), 'AppImage attendu pour Linux');
});

check('icône présente et exploitable', () => {
  const icon = path.join(ROOT, 'apps/desktop/build/icon.png');
  assert.ok(fs.existsSync(icon), 'apps/desktop/build/icon.png manquant');
  // electron-builder exige au moins 512x512 : on lit l'en-tête PNG.
  const buf = fs.readFileSync(icon);
  assert.equal(buf.toString('hex', 1, 4), '504e47', 'ce n\'est pas un PNG');
  const width = buf.readUInt32BE(16);
  const height = buf.readUInt32BE(20);
  assert.ok(width >= 512 && height >= 512, `icône trop petite : ${width}x${height}`);
  assert.equal(width, height, 'l\'icône doit être carrée');
});

check('version d\'Electron figée pour des builds reproductibles', () => {
  assert.ok(b.electronVersion, 'build.electronVersion absent : electron-builder échouera en CI');
  assert.match(b.electronVersion, /^\d+\.\d+\.\d+$/, 'la version doit être exacte, sans ^ ni ~');
});

check('scripts de packaging disponibles', () => {
  for (const s of ['pack:linux', 'pack:win', 'pack:mac']) {
    assert.ok(pkg.scripts?.[s], `script ${s} manquant`);
  }
});

check('les sorties de build ne sont pas versionnées', () => {
  const ignore = fs.readFileSync(path.join(ROOT, '.gitignore'), 'utf8');
  assert.ok(/^dist\/$/m.test(ignore), 'dist/ doit être dans .gitignore');
  assert.ok(/^release\/$/m.test(ignore), 'release/ doit rester ignoré (ancien emplacement)');
  assert.ok(!/^build\/$/m.test(ignore), 'la règle build/ masquerait apps/desktop/build/icon.png');
});

check('le packaging écrit sous dist/ (exclu des sauvegardes)', () => {
  const out = b.directories?.output ?? '';
  assert.ok(
    out.includes('dist/'),
    `la sortie « ${out} » doit être sous dist/ : les installateurs pèsent ~100 Mo `
    + 'et ne doivent jamais atterrir dans un dossier sauvegardé',
  );
});

let pass = 0;
let fail = 0;
for (const [name, fn] of checks) {
  try { fn(); console.log(`  ✓ ${name}`); pass++; }
  catch (e) { console.log(`  ✗ ${name}\n      ${e.message}`); fail++; }
}
console.log(`\nPackaging : ${pass} OK, ${fail} en échec`);
process.exit(fail ? 1 : 0);
