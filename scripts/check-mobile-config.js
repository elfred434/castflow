#!/usr/bin/env node
/**
 * Valide la configuration de l'app mobile sans installer React Native.
 * Ces réglages sont invisibles au runtime en dev mais cassent l'app en production.
 */
const path = require('node:path');
const assert = require('node:assert');

const ROOT = path.resolve(__dirname, '..');
const app = require(path.join(ROOT, 'apps/mobile/app.json')).expo;
const pkg = require(path.join(ROOT, 'apps/mobile/package.json'));

const checks = [];
const check = (name, fn) => checks.push([name, fn]);

check('identifiants de publication présents', () => {
  assert.ok(app.android?.package, 'expo.android.package manquant');
  assert.ok(app.ios?.bundleIdentifier, 'expo.ios.bundleIdentifier manquant');
});

check('schéma castflow:// déclaré (nécessaire au QR code)', () => {
  assert.equal(app.scheme, 'castflow', `scheme attendu "castflow", trouvé "${app.scheme}"`);
});

check('permissions Android requises', () => {
  const needed = ['INTERNET', 'ACCESS_NETWORK_STATE', 'ACCESS_WIFI_STATE', 'CAMERA'];
  const got = app.android?.permissions ?? [];
  const missing = needed.filter((p) => !got.includes(p));
  assert.equal(missing.length, 0, `permissions manquantes : ${missing.join(', ')}`);
});

check('HTTP en clair autorisé sur le réseau local', () => {
  // Sans cela, Android 9+ bloque les requêtes http:// vers le PC.
  assert.equal(app.android?.usesCleartextTraffic, true, 'android.usesCleartextTraffic doit être true');
  const ats = app.ios?.infoPlist?.NSAppTransportSecurity;
  assert.ok(ats?.NSAllowsLocalNetworking, 'iOS : NSAllowsLocalNetworking requis');
  assert.ok(app.ios?.infoPlist?.NSLocalNetworkUsageDescription, 'iOS : NSLocalNetworkUsageDescription requis');
});

check('dépendances critiques du transfert présentes', () => {
  const needed = [
    'expo-file-system',    // upload en streaming avec progression
    'expo-camera',         // scan du QR
    'expo-document-picker',
    'expo-image-picker',
    'expo-network',        // affichage de l'IP locale
    '@react-native-async-storage/async-storage', // identité + historique
  ];
  const missing = needed.filter((d) => !pkg.dependencies?.[d]);
  assert.equal(missing.length, 0, `dépendances manquantes : ${missing.join(', ')}`);
});

check('icônes et écran de démarrage présents', () => {
  const fs = require('node:fs');
  for (const rel of ['assets/icon.png', 'assets/adaptive-icon.png', 'assets/splash.png']) {
    assert.ok(fs.existsSync(path.join(ROOT, 'apps/mobile', rel)), `${rel} manquant`);
  }
  assert.ok(app.icon, 'expo.icon non déclaré');
  assert.ok(app.android?.adaptiveIcon?.foregroundImage, 'icône adaptative Android manquante');
});

check('versions de publication définies', () => {
  assert.ok(Number.isInteger(app.android?.versionCode), 'android.versionCode requis pour publier');
  assert.ok(app.ios?.buildNumber, 'ios.buildNumber requis pour publier');
});

check('profils de build EAS disponibles', () => {
  const eas = require(path.join(ROOT, 'apps/mobile/eas.json'));
  for (const profile of ['development', 'preview', 'production']) {
    assert.ok(eas.build?.[profile], `profil EAS « ${profile} » manquant`);
  }
  assert.equal(eas.build.preview.android.buildType, 'apk', 'le profil preview doit produire un APK');
});

check('point d\'entrée cohérent', () => {
  assert.equal(pkg.main, 'index.js', 'le point d\'entrée doit être index.js');
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
console.log(`\nConfiguration mobile : ${app.name} v${app.version} — ${pass} OK, ${fail} en échec`);
process.exit(fail ? 1 : 0);
