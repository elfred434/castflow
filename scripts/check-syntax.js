#!/usr/bin/env node
/**
 * Vérification syntaxique de tous les fichiers JS/JSX du dépôt.
 * Utile en CI pour valider le code mobile sans installer Expo ni React Native.
 */
const fs = require('node:fs');
const path = require('node:path');
const { parse } = require('@babel/parser');

const ROOT = path.resolve(__dirname, '..');
const SKIP = new Set(['node_modules', '.git', 'dist', 'build', 'out', '.expo', 'coverage', 'release']);

function walk(dir, acc = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP.has(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, acc);
    else if (/\.(jsx?|mjs|cjs)$/.test(entry.name)) acc.push(full);
  }
  return acc;
}

const files = walk(ROOT);
let failed = 0;

for (const file of files) {
  const rel = path.relative(ROOT, file);
  const code = fs.readFileSync(file, 'utf8');
  // Les fichiers CommonJS du main Electron ne sont pas des modules ESM.
  const isCjs = /\.cjs$/.test(file) || /^\s*(const|let|var)\s+.*=\s*require\(/m.test(code);
  try {
    parse(code, {
      sourceType: isCjs ? 'script' : 'module',
      allowReturnOutsideFunction: true,
      plugins: ['jsx', 'classProperties', 'optionalChaining', 'nullishCoalescingOperator', 'topLevelAwait'],
    });
    console.log(`  ✓ ${rel}`);
  } catch (e) {
    console.log(`  ✗ ${rel}\n      ${e.message}`);
    failed++;
  }
}

console.log(`\n${files.length - failed} fichier(s) valides, ${failed} en erreur`);
process.exit(failed ? 1 : 0);
