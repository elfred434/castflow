# CastFlow ⚡

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)

Transfert de fichiers **local, rapide et hors-ligne** entre un ordinateur et un téléphone —
à la manière de Xender / LocalSend.

- **Desktop** : Electron + React (Windows, macOS, Linux)
- **Mobile** : React Native (Expo, Android & iOS)
- **Transport** : Wi-Fi local ou point d'accès mobile, en pair-à-pair — aucune donnée ne passe par internet
- **Appairage** : QR code, code PIN, découverte automatique UDP, ou saisie manuelle de l'IP

---

## Démarrage rapide

```bash
npm install                # à la racine (workspaces)

npm run dev:desktop        # lance Electron + Vite
npm run dev:mobile         # lance Expo (scannez avec Expo Go)
```

Pour l'app mobile, les modules natifs (caméra, fichiers) nécessitent un build de développement :

```bash
cd apps/mobile
npx expo prebuild
npx expo run:android
```

### Utilisation

1. Sur le PC : ouvrez CastFlow → onglet **Recevoir**. Un QR code et un PIN s'affichent.
2. Sur le téléphone : **Scanner le QR code** (ou saisir l'adresse `192.168.x.x:53317`).
3. Choisissez photos/vidéos/documents, appuyez sur **Envoyer**.
4. Le PC demande confirmation, puis les fichiers arrivent dans `Téléchargements/CastFlow`.

Sans routeur Wi-Fi : activez le **point d'accès mobile** du téléphone, connectez-y le PC,
et l'adresse passera en `192.168.43.x`.

---

## Tests

```bash
npm test          # tout : syntaxe + protocole + config mobile + 22 tests
npm run ci        # identique au workflow CI (tests + builds)
```

Ou individuellement :

```bash
npm run check:syntax     # syntaxe de tout le JS/JSX, desktop et mobile
npm run check:protocol   # cohérence du protocole entre les 3 paquets
npm run check:mobile     # permissions et config Expo
npm run test:core        # 13 tests — serveur, sécurité, reprise, découverte UDP
npm run test:e2e         #  9 tests — le vrai client mobile ↔ le vrai serveur desktop
```

Couverture : handshake, PIN/HMAC, transfert multi-fichiers, reprise après coupure,
téléchargement avec `Range`, refus/acceptation, traversée de chemin, collision de noms,
découverte UDP entre deux instances, équivalence HMAC JS ↔ natif.

## Intégration continue

**GitHub Actions** — le workflow `.github/workflows/ci.yml` se déclenche à chaque push
et sur chaque pull request vers `main`, `master` ou `develop`.

| Job | Étape | Rôle |
|---|---|---|
| `verify` | `check:syntax` | Parse tout le JS/JSX, y compris le mobile non installé en CI |
| `verify` | `check:protocol` | Bloque toute divergence de ports, version ou messages entre desktop et mobile |
| `verify` | `check:mobile` | Valide permissions Android/iOS et configuration Expo |
| `verify` | `build:shared` | Compile le paquet TypeScript partagé |
| `test` | `test:core` | 13 tests d'intégration du serveur — sur Node 20 **et** 22 |
| `test` | `test:e2e` | 9 tests bout-en-bout mobile ↔ desktop — sur Node 20 **et** 22 |
| `build` | `build:desktop` | Build Vite, publié en artefact téléchargeable (7 jours) |

Le job `build` attend que `verify` et `test` réussissent (`needs`), et un nouveau push
annule automatiquement le run précédent encore en cours (`concurrency`).

Le job `check:protocol` est le garde-fou le plus utile du projet : si quelqu'un change un port
ou un type de message d'un seul côté, le workflow échoue au lieu de laisser passer des
transferts silencieusement cassés.

Le test de découverte UDP se met automatiquement en pause si le runner interdit le broadcast,
pour éviter les échecs intermittents.

### Publier une version

Le workflow `.github/workflows/release.yml` se déclenche sur un tag `v*` :

```bash
git tag v0.1.0
git push origin v0.1.0
```

Il rejoue toute la suite de tests, construit l'interface, puis crée une release GitHub
avec l'archive `.zip` et des notes de version générées automatiquement.

---

## Architecture

```
castflow/
├── docs/
│   ├── ARCHITECTURE.md       Vue d'ensemble, modes réseau, sécurité, roadmap
│   └── PROTOCOL.md           Spécification des messages UDP / WS / HTTP
├── packages/shared/          Types & protocole TypeScript partagés
└── apps/
    ├── desktop/
    │   ├── src/main/core/    device · protocol · discovery · server
    │   ├── src/preload/      Pont IPC sécurisé
    │   ├── src/renderer/     UI React (App, ui, mock)
    │   └── test/             Tests d'intégration et e2e
    └── mobile/
        ├── App.js            UI React Native complète
        └── src/client.js     Client réseau : WS, HMAC, upload avec reprise
```

### Les trois canaux

| Port | Protocole | Rôle |
|---|---|---|
| `53317` | HTTP | Upload / download des fichiers, reprise via `Range` et `X-Offset` |
| `53318` | WebSocket | Handshake, authentification, progression, signalisation WebRTC |
| `54545` | UDP | Découverte par broadcast (annonce toutes les 2 s) |

### Sécurité

- Aucun transfert sans **acceptation explicite** (ou appareil marqué de confiance)
- **PIN à 6 chiffres** prouvé par `HMAC-SHA256(pin, nonce + deviceId)` — jamais transmis en clair
- **Token aléatoire par fichier**, à usage unique, expirant après 10 min
- Noms de fichiers **assainis** (pas de traversée de chemin, pas de noms réservés Windows)
- Écoute sur le réseau local uniquement, jamais exposé au WAN

---

## État d'avancement

- [x] Architecture et spécification du protocole
- [x] Serveur desktop : HTTP + WebSocket + découverte UDP
- [x] Sécurité : PIN/HMAC, tokens, assainissement
- [x] Reprise de transfert à l'octet près
- [x] UI desktop complète (appareils, envoi, réception, historique, réglages)
- [x] Client réseau mobile + UI React Native (scanner QR, PIN, sélection, progression)
- [x] Tests d'intégration et bout-en-bout (22 au total)
- [ ] Wi-Fi Direct natif (Android `WifiP2pManager`)
- [ ] WebRTC DataChannel (signalisation déjà en place)
- [ ] TLS auto-signé avec épinglage d'empreinte
- [ ] Packaging : `.exe` / `.dmg` / `.AppImage` / `.apk`

Voir [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) pour la roadmap détaillée.
