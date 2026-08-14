# CastFlow Protocol v1

Trois canaux : **UDP** (découverte), **WebSocket** (contrôle), **HTTP** (données).
Tous les payloads sont en JSON UTF-8. Les tailles sont en octets.

---

## 1. Découverte — UDP `54545`

### 1.1 `ANNOUNCE` (broadcast, toutes les 2 s, et en réponse à `DISCOVER`)

```json
{
  "v": 1,
  "type": "ANNOUNCE",
  "device": {
    "id": "b3f1c2a4-...",
    "name": "PC de Elfred",
    "platform": "windows",
    "kind": "desktop",
    "fingerprint": "a1b2c3d4e5f6"
  },
  "http": 53317,
  "ws": 53318,
  "secure": false,
  "requiresPin": true,
  "t": 1755100000000
}
```

### 1.2 `DISCOVER` (broadcast au démarrage / au pull-to-refresh)

```json
{ "v": 1, "type": "DISCOVER", "device": { "...": "..." } }
```

### 1.3 `BYE` (à la fermeture)

```json
{ "v": 1, "type": "BYE", "device": { "id": "..." } }
```

Un appareil non revu depuis **6 s** est retiré de la liste.

---

## 2. Appairage

### 2.1 Charge utile du QR

URL `castflow://` scannable, également valide en texte brut :

```
castflow://connect?host=192.168.43.1&http=53317&ws=53318&id=<deviceId>&name=<urlenc>&pin=482913&fp=<sha256-8>
```

Variante « hotspot » (le PC se connecte d'abord au Wi-Fi du téléphone) :

```
WIFI:S:CastFlow-4821;T:WPA;P:castflow123;;castflow://connect?host=192.168.43.1&...
```

### 2.2 Preuve du PIN

- L'hôte génère un `nonce` (16 octets, base64) envoyé dans `HELLO_ACK`.
- Le client répond `AUTH` avec `proof = base64(HMAC_SHA256(key = pin, msg = nonce + deviceId))`.
- 3 échecs → l'IP est bloquée 60 s.
- Si l'appareil est déjà « de confiance » (fingerprint mémorisée), le PIN est sauté.

---

## 3. Contrôle — WebSocket `53318`

Enveloppe commune :

```json
{ "v": 1, "type": "...", "id": "<uuid msg>", "ts": 1755100000000, "data": { } }
```

Les réponses reprennent `"re": "<id du message d'origine>"`.

### 3.1 Table des messages

| Type | Sens | data |
|---|---|---|
| `HELLO` | client → hôte | `{ device }` |
| `HELLO_ACK` | hôte → client | `{ device, nonce, requiresPin, trusted }` |
| `AUTH` | client → hôte | `{ proof }` |
| `AUTH_OK` | hôte → client | `{ sessionToken }` |
| `AUTH_FAIL` | hôte → client | `{ reason, attemptsLeft }` |
| `TRANSFER_REQUEST` | envoyeur → receveur | `{ transferId, files: FileMeta[], totalSize }` |
| `TRANSFER_ACCEPT` | receveur → envoyeur | `{ transferId, tokens: { [fileId]: string } }` |
| `TRANSFER_REJECT` | receveur → envoyeur | `{ transferId, reason }` |
| `PROGRESS` | receveur → envoyeur | `{ transferId, fileId, received, total, bps }` |
| `FILE_DONE` | receveur → envoyeur | `{ transferId, fileId, hashOk }` |
| `TRANSFER_COMPLETE` | receveur → envoyeur | `{ transferId, files, durationMs }` |
| `TRANSFER_CANCEL` | les deux | `{ transferId, reason }` |
| `PING` / `PONG` | les deux | `{}` — keepalive 15 s |
| `ERROR` | les deux | `{ code, message }` |
| `RTC_OFFER` / `RTC_ANSWER` / `RTC_ICE` | les deux | `{ transferId, sdp \| candidate }` |

### 3.2 `FileMeta`

```json
{
  "id": "f_01",
  "name": "video.mp4",
  "size": 734003200,
  "mime": "video/mp4",
  "relPath": "Films/2026/video.mp4",
  "hash": "xxh64:9a3f...",
  "modifiedAt": 1755000000000
}
```

`relPath` permet d'envoyer une arborescence de dossiers.

---

## 4. Données — HTTP `53317`

Toutes les routes de transfert exigent l'en-tête `X-CastFlow-Token`.

| Méthode | Route | Rôle |
|---|---|---|
| `GET` | `/info` | Infos de l'appareil (JSON de `ANNOUNCE`), utilisé par la saisie IP manuelle |
| `HEAD` | `/upload/:transferId/:fileId` | Renvoie `X-Received-Bytes` pour la reprise |
| `POST` | `/upload/:transferId/:fileId` | Corps = flux binaire brut. Headers : `X-Offset`, `Content-Length` |
| `GET` | `/download/:transferId/:fileId` | Supporte `Range` |
| `POST` | `/cancel/:transferId` | Annule côté serveur |

### 4.1 Codes d'erreur

| Code HTTP | `code` | Sens |
|---|---|---|
| 401 | `NO_TOKEN` / `BAD_TOKEN` | Token absent ou invalide |
| 403 | `NOT_ACCEPTED` | Transfert non accepté par l'utilisateur |
| 404 | `UNKNOWN_FILE` | fileId inconnu dans ce transfert |
| 409 | `OFFSET_MISMATCH` | `X-Offset` ≠ octets déjà reçus |
| 413 | `TOO_LARGE` | Dépasse la taille annoncée |
| 507 | `NO_SPACE` | Espace disque insuffisant |

### 4.2 Reprise

```
HEAD /upload/t_1/f_01      → 200, X-Received-Bytes: 12582912
POST /upload/t_1/f_01      → X-Offset: 12582912, corps = reste du fichier
```

Le serveur ouvre le fichier en `r+` et écrit à partir de l'offset. Fichier temporaire
`<name>.cfpart`, renommé à la complétion et après validation du hash.

---

## 5. Machine à états d'un transfert

```
IDLE ──request──► PENDING ──accept──► TRANSFERRING ──all files done──► COMPLETED
                     │                     │
                   reject                cancel / erreur
                     ▼                     ▼
                 REJECTED               FAILED / CANCELLED
                                           │
                                        resume ──► TRANSFERRING
```

---

## 6. Versionnement

Le champ `v` est incrémenté à chaque rupture de compatibilité. Un hôte refuse une
connexion dont le `v` est supérieur au sien avec `ERROR { code: "VERSION_MISMATCH" }`.
