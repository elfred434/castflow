// Empreintes de fichiers pour vérifier l'intégrité après transfert.
const fs = require('node:fs');
const crypto = require('node:crypto');

/**
 * Hash rapide, non cryptographique, compatible entre Node et JS pur (mobile).
 * FNV-1a 64 bits en arithmétique 32 bits (pas de BigInt : bien plus rapide
 * et identique sur toutes les plateformes).
 *
 * Format de sortie : "fnv1a64:<16 caractères hex>"
 */
function fnv1a64Init() {
  return { h1: 0xcbf29ce4, h0: 0x84222325 }; // offset basis, 32 bits haut/bas
}

// prime FNV-1a 64 bits = 0x100000001b3, soit 41 bits :
// mot bas = 0x1b3, mot haut = 0x100 (et non 1 — source classique d'erreur).
const P_LOW = 0x1b3;
const P_HIGH = 0x100;
const TWO32 = 4294967296; // 2^32

function fnv1a64Update(state, bytes) {
  let { h1, h0 } = state;
  for (let i = 0; i < bytes.length; i++) {
    // XOR sur l'octet de poids faible
    h0 = (h0 ^ bytes[i]) >>> 0;

    // h = h0 + h1·2³²  et  prime = P_LOW + P_HIGH·2³²
    // (h·prime) mod 2⁶⁴ = h0·P_LOW + (h1·P_LOW + h0·P_HIGH + retenue)·2³²
    //
    // Majorant du mot haut : 2³²·(0x1b3 + 0x100) + 435 ≈ 2,97·10¹²,
    // très en dessous de 2⁵³ : l'arithmétique double reste exacte.
    // On n'utilise pas `>>>` ici, qui tronquerait à 32 bits et perdrait
    // la retenue.
    const low = h0 * P_LOW;
    const carry = Math.floor(low / TWO32);
    const high = h1 * P_LOW + h0 * P_HIGH + carry;

    h0 = low % TWO32;
    h1 = high % TWO32;
  }
  state.h1 = h1 >>> 0;
  state.h0 = h0 >>> 0;
  return state;
}

function fnv1a64Digest(state) {
  const hi = (state.h1 >>> 0).toString(16).padStart(8, '0');
  const lo = (state.h0 >>> 0).toString(16).padStart(8, '0');
  return `fnv1a64:${hi}${lo}`;
}

/** Hash d'un Buffer en une passe. */
function hashBuffer(buf) {
  return fnv1a64Digest(fnv1a64Update(fnv1a64Init(), buf));
}

/** Hash d'un fichier en streaming (mémoire constante). */
function hashFile(filePath) {
  return new Promise((resolve, reject) => {
    const state = fnv1a64Init();
    const stream = fs.createReadStream(filePath, { highWaterMark: 1024 * 1024 });
    stream.on('data', (chunk) => fnv1a64Update(state, chunk));
    stream.on('end', () => resolve(fnv1a64Digest(state)));
    stream.on('error', reject);
  });
}

/** Variante cryptographique, pour l'empreinte d'un certificat par exemple. */
function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', (c) => h.update(c));
    stream.on('end', () => resolve(`sha256:${h.digest('hex')}`));
    stream.on('error', reject);
  });
}

/** Compare deux empreintes ; tolère l'absence d'empreinte côté émetteur. */
function hashMatches(expected, actual) {
  if (!expected) return true; // l'émetteur n'a pas fourni de hash
  return String(expected).toLowerCase() === String(actual).toLowerCase();
}

module.exports = {
  fnv1a64Init, fnv1a64Update, fnv1a64Digest,
  hashBuffer, hashFile, sha256File, hashMatches,
};
