# CastFlow ⚡

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)

Application Flutter de transfert de fichiers **local, rapide et hors-ligne** entre
Windows et Android, inspirée de Xender et LocalSend.

- **Stack unique** : Flutter 3.47 / Dart 3.13
- **Transport** : HTTP streaming, WebSocket de contrôle et découverte UDP
- **Appairage** : QR, PIN HMAC-SHA256, découverte locale ou IP manuelle
- **Livrables** : installateur Windows `.exe` et APK Android `.apk`

## Démarrage

```bash
flutter pub get
flutter run -d windows       # Windows
flutter run -d <android-id>  # téléphone ou émulateur Android
```

### Utilisation

1. Sur Windows, ouvrez **Connexion** : CastFlow affiche un QR et un PIN.
2. Sur Android, scannez le QR ou saisissez `192.168.x.x:53317`.
3. Choisissez les fichiers puis appuyez sur **Envoyer maintenant**.
4. Le destinataire accepte la demande. Les fichiers arrivent dans
   `Téléchargements/CastFlow`.

Le transfert ne nécessite aucun serveur internet. Un point d'accès mobile peut remplacer
le routeur Wi-Fi.

## Qualité

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test --reporter expanded
```

La suite contient **24 tests** unitaires, widgets et d'intégration réseau :

- HMAC PIN compatible et comparaison constante ;
- vecteurs officiels FNV-1a 64 et hash en streaming ;
- QR et enveloppes CastFlow v1 ;
- handshake avec et sans PIN ;
- transfert Android → Windows avec hash et progression ;
- acceptation manuelle ;
- offre et téléchargement Windows → Android ;
- protection de `/offer` et validation des plages HTTP.

## Builds

```bash
flutter build windows --release
flutter build apk --release
```

Le workflow `.github/workflows/package.yml`, lancé manuellement ou sur un tag `v*` :

1. exécute formatage, analyse et 24 tests ;
2. construit Windows et crée `CastFlow-Setup-<version>.exe` avec Inno Setup ;
3. construit l'APK avec Java 17 et Android SDK 36 ;
4. calcule les SHA-256 et conserve les artefacts pendant 30 jours ;
5. sur un tag, crée une GitHub Release avec le `.exe`, l'APK et `SHA256SUMS.txt`.

### Signature Android

Sans secret, la CI produit un APK interne signé avec la clé debug. Pour une signature de
production, configurer :

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

La signature Authenticode Windows reste à ajouter avant une distribution publique.

## Architecture

```text
castflow/
├── lib/
│   ├── app/                 orchestration et état global
│   ├── core/                modèles, limites et formatage
│   ├── network/             serveur, client et découverte UDP
│   ├── protocol/            enveloppes et QR CastFlow v1
│   ├── security/            PIN, jetons, FNV-1a et assainissement
│   ├── storage/             identité et réglages persistés
│   └── ui/                  interface adaptative Windows/Android
├── android/                 projet natif Android
├── windows/                 runner Windows Flutter
├── installer/               script Inno Setup
├── assets/                  icône
└── test/                    tests unitaires, widgets et réseau
```

### Ports

| Port | Protocole | Rôle |
|---|---|---|
| `53317` | HTTP | Upload/download et reprise `X-Offset`/`Range` |
| `53318` | WebSocket | Handshake, PIN, demandes et offres |
| `54545` | UDP | Découverte locale |

### Sécurité déjà intégrée

- preuve PIN HMAC-SHA256 et comparaison constante ;
- session obligatoire pour `/offer`, `/download` et `/cancel` ;
- jetons par fichier expirant après 10 minutes et consommés après succès ;
- hash sortant systématique avant transfert ;
- limites sur les messages, manifestes, fichiers et identifiants ;
- noms de fichiers assainis et plages HTTP invalides rejetées ;
- aucune confiance automatique fondée sur une fingerprint déclarative.

## État

- [x] Application Flutter unique Windows + Android
- [x] UI adaptative et scanner QR Android
- [x] Serveur HTTP/WebSocket et découverte UDP
- [x] Transfert bidirectionnel en streaming
- [x] Reprise réelle par offset et intégrité FNV-1a 64
- [x] 24 tests Flutter
- [x] Workflow `.exe` + `.apk` + GitHub Release
- [ ] Validation manuelle sur PC Windows et plusieurs versions Android
- [ ] Signature Authenticode Windows
- [ ] TLS local avec épinglage d'empreinte
- [ ] Wi-Fi Direct natif Android

Voir `docs/ARCHITECTURE.md` et `docs/PROTOCOL.md`.
