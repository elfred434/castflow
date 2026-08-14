# CastFlow — Architecture

Transfert de fichiers local, hors-ligne, entre un **desktop (Electron + React)** et un
**mobile (React Native / Expo)**. Inspiré de Xender / LocalSend.

---

## 1. Vue d'ensemble

```
┌──────────────────────────┐                     ┌──────────────────────────┐
│   CastFlow Desktop       │                     │   CastFlow Mobile        │
│   Electron + React       │                     │   React Native (Expo)    │
├──────────────────────────┤                     ├──────────────────────────┤
│ Renderer (UI React)      │                     │ UI React Native          │
│    ▲ IPC                 │                     │    ▲                     │
│ Main process (Node)      │                     │ JS runtime               │
│  • HTTP server (fichiers)│◄── Wi-Fi / Hotspot ─►│  • fetch / upload        │
│  • WS server (signaling) │      même sous-réseau│  • WS client             │
│  • UDP discovery         │                     │  • UDP discovery         │
│  • QR / PIN              │                     │  • Scanner QR            │
└──────────────────────────┘                     └──────────────────────────┘
```

Principe : **un des deux appareils devient "hôte"** (il ouvre les serveurs HTTP + WS),
l'autre devient "client". Par défaut le desktop est hôte car il n'a pas de restriction
de batterie ni de port. Le mobile peut aussi être hôte (mode hotspot).

---

## 2. Modes de connexion

| Mode | Description | Quand |
|---|---|---|
| **LAN** | Les deux sont sur le même routeur Wi-Fi | Cas nominal |
| **Hotspot mobile** | Le téléphone crée un point d'accès, le PC s'y connecte | Pas de routeur |
| **Hotspot desktop** | Le PC crée un hotspot (Windows: `netsh wlan start hostednetwork`, Linux: NetworkManager) | PC portable + téléphone |
| **P2P/WebRTC** | DataChannel direct après signalisation locale | Gros fichiers, NAT interne, futur relais internet |

Dans tous les cas la couche applicative est identique : une IP + un port joignables.

### 2.1 Hotspot — limites Android

Android ≥ 8 ne permet plus d'activer le hotspot par programme sans être app système.
Stratégie retenue :

1. On **guide l'utilisateur** vers `Settings.ACTION_WIRELESS_SETTINGS` / le panneau hotspot
   (intent Android), avec un écran d'explication.
2. Une fois le hotspot actif, l'app détecte son interface (`ap0` / `swlan0`, IP typique
   `192.168.43.1`) et démarre le serveur dessus.
3. Le QR encode le SSID + mot de passe (format `WIFI:S:<ssid>;T:WPA;P:<pass>;;` étendu),
   donc le PC peut se connecter au réseau puis à l'app en un seul scan.
4. Wi-Fi Direct (`WifiP2pManager`) est prévu en option v2 : il évite de couper l'accès
   internet mais demande un module natif.

---

## 3. Découverte des appareils

Trois mécanismes cumulés, unifiés dans une même liste d'appareils :

1. **UDP broadcast** — port `54545`, `255.255.255.255` et broadcast du sous-réseau.
   Chaque appareil émet un `ANNOUNCE` toutes les 2 s et répond aux `DISCOVER`.
2. **QR code** — le rôle hôte affiche un QR contenant l'URL de connexion complète.
   Zéro configuration, mode privilégié.
3. **PIN à 6 chiffres** — affiché par l'hôte, saisi par le client. Sert aussi de
   secret d'appairage (voir §6) quand la découverte UDP a déjà trouvé l'IP.
4. **IP manuelle** — champ de secours (`192.168.43.1:53317`).

---

## 4. Ports

| Port | Protocole | Rôle |
|---|---|---|
| `53317` | HTTP | API REST + upload/download des fichiers |
| `53318` | WebSocket | Signalisation, contrôle, progression, WebRTC SDP/ICE |
| `54545` | UDP | Découverte broadcast |

Si un port est occupé, on incrémente jusqu'à trouver un port libre et on le publie
dans l'annonce UDP / le QR.

---

## 5. Flux d'un transfert

```
Client (envoyeur)                          Hôte (receveur)
      │                                          │
      │ 1. WS connect + HELLO                    │
      │─────────────────────────────────────────►│
      │◄──────────── HELLO_ACK (deviceInfo) ─────│
      │                                          │
      │ 2. TRANSFER_REQUEST (manifest: n fichiers, tailles)
      │─────────────────────────────────────────►│  → l'UI demande "Accepter ?"
      │◄──────────── TRANSFER_ACCEPT { sessionId, tokens{fileId:token} }
      │                                          │
      │ 3. POST /upload/:sessionId/:fileId  (streaming, header X-Token)
      │═════════════════════════════════════════►│  écrit sur disque
      │   (n requêtes, parallélisme 3 max)       │
      │◄──────────── PROGRESS (ws, throttlé 200ms)
      │                                          │
      │ 4. TRANSFER_COMPLETE                     │
      │◄─────────────────────────────────────────│
```

Le sens inverse (hôte → client) utilise `GET /download/:sessionId/:fileId`.

**Reprise** : chaque upload accepte `Range` / header `X-Offset`, le receveur répond
sa taille déjà reçue sur `HEAD /upload/:sessionId/:fileId`. Un transfert interrompu
reprend à l'octet près.

**Intégrité** : hash `xxhash64` (ou SHA-256 optionnel) par fichier dans le manifest,
vérifié à la fin côté receveur.

---

## 6. Sécurité

- **Appairage explicite** : aucun transfert sans acceptation manuelle (ou appareil
  marqué "de confiance" — sa clé publique est mémorisée).
- **PIN** : dérivé en secret de session ; le client doit prouver qu'il le connaît
  (`HMAC-SHA256(pin, nonce)`) avant que le serveur n'ouvre une session.
- **Tokens de fichier** : un token aléatoire par fichier, à usage unique, expiration
  10 min. Impossible de deviner une URL d'upload/download.
- **HTTPS local** : certificat auto-signé généré au premier lancement, empreinte
  affichée dans le QR pour épinglage (pinning) côté mobile. En v1 on autorise HTTP
  clair sur le LAN, avec chiffrement applicatif AES-GCM optionnel du flux.
- Liaison **binding sur l'interface locale uniquement**, jamais exposé au WAN.

---

## 7. WebRTC (P2P)

La signalisation passe par le WS local (ou, plus tard, par un serveur cloud pour le
transfert à distance). Une fois le `RTCDataChannel` ouvert, les fichiers sont envoyés
en chunks de 16 Ko avec contrôle de flux via `bufferedAmountLowThreshold`.

Intérêt : identique en local et à distance, traverse le NAT via STUN, pas de serveur
de fichiers à exposer. Coût : dépendance native `react-native-webrtc`.

**Décision v1** : HTTP streaming (simple, rapide, robuste, reprise facile).
**v2** : WebRTC activable, même couche de signalisation, même manifest.

---

## 8. Structure du monorepo

```
castflow/
├── docs/
│   ├── ARCHITECTURE.md      ← ce fichier
│   └── PROTOCOL.md          ← spec des messages
├── packages/
│   └── shared/              ← types, constantes, protocole (TS, partagé)
├── apps/
│   ├── desktop/             ← Electron + React + Vite
│   │   ├── src/main/        ← process Node : serveurs HTTP/WS/UDP
│   │   ├── src/preload/
│   │   └── src/renderer/    ← UI React
│   └── mobile/              ← Expo React Native
└── package.json             ← workspaces npm
```

---

## 9. Roadmap

- **v0.1** — squelette, découverte UDP, QR, transfert HTTP desktop↔mobile, progression.
- **v0.2** — reprise, hash, multi-fichiers, historique, dossiers.
- **v0.3** — hotspot guidé, PIN/HMAC, appareils de confiance, TLS auto-signé.
- **v0.4** — WebRTC DataChannel, transfert desktop↔desktop, mobile↔mobile.
- **v1.0** — packaging (dmg/exe/AppImage, APK), i18n FR/EN, thème clair/sombre.
