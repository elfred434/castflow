# CastFlow Protocol v1 — implémentation Flutter

Tous les messages de contrôle sont JSON UTF-8. Les fichiers sont transférés comme flux
binaires bruts.

## Ports

| Port | Protocole | Rôle |
|---|---|---|
| `53317` | HTTP | informations, upload, download, reprise et annulation |
| `53318` | WebSocket | handshake, PIN, demandes, offres et progression |
| `54545` | UDP | découverte locale |

Si un port hôte est occupé, CastFlow essaie les 20 ports suivants et annonce le port
réel dans le QR et les paquets UDP.

## Découverte UDP

Annonce :

```json
{
  "v": 1,
  "type": "ANNOUNCE",
  "device": {
    "id": "dev_...",
    "name": "PC de Marie",
    "platform": "windows",
    "kind": "desktop",
    "fingerprint": "..."
  },
  "http": 53317,
  "ws": 53318,
  "secure": false,
  "requiresPin": true,
  "t": 1786700000000
}
```

Types supportés : `ANNOUNCE`, `DISCOVER` et `BYE`. Un appareil non revu après 7 secondes
est retiré.

## QR

```text
castflow://connect?host=192.168.1.20&http=53317&ws=53318&id=dev_...&name=PC&kind=desktop&platform=windows&pin=482913&fp=...
```

Le PIN présent dans le QR sert à l'appairage immédiat. Le transport reste actuellement
en clair sur le LAN ; TLS épinglé est prévu.

## Enveloppe WebSocket

```json
{
  "v": 1,
  "type": "HELLO",
  "id": "m_...",
  "ts": 1786700000000,
  "re": "m_origine_optionnel",
  "data": {}
}
```

Messages :

| Type | Rôle |
|---|---|
| `HELLO` / `HELLO_ACK` | échange des identités, nonce et besoin de PIN |
| `AUTH` / `AUTH_OK` / `AUTH_FAIL` | preuve du PIN et création de session |
| `TRANSFER_REQUEST` | manifest de fichiers mobile → Windows |
| `TRANSFER_ACCEPT` / `TRANSFER_REJECT` | décision et jetons par fichier |
| `OFFER` | annonce Windows → Android, sans jetons sensibles |
| `TRANSFER_COMPLETE` | fin du transfert |
| `TRANSFER_CANCEL` | annulation |
| `PING` / `PONG` | contrôle de présence |
| `ERROR` | erreur de protocole |

### Appairage

1. L'hôte crée un nonce aléatoire et le renvoie dans `HELLO_ACK`.
2. Le client calcule
   `base64(HMAC-SHA256(key=pin, message=nonce + deviceId))`.
3. L'hôte utilise une comparaison constante.
4. Après trois échecs, l'adresse est bloquée une minute.
5. Une authentification réussie crée un `sessionToken` aléatoire.

La fingerprint déclarée ne permet jamais de sauter le PIN.

## Manifest de fichier

```json
{
  "id": "f_01",
  "name": "video.mp4",
  "size": 734003200,
  "mime": "video/mp4",
  "hash": "fnv1a64:9a3f000000000000"
}
```

Le client calcule le hash avant d'envoyer la demande. Le serveur vérifie le flux complet
avant le renommage final.

## HTTP

### En-têtes

- `X-CastFlow-Session` : session issue du handshake ;
- `X-CastFlow-Token` : jeton propre au fichier ;
- `X-Offset` : premier octet du corps d'upload ;
- `X-Received-Bytes` : offset retourné par `HEAD` ;
- `Range` / `Content-Range` : reprise d'un téléchargement.

Les jetons de fichiers expirent après 10 minutes et sont consommés après un transfert
intégral réussi.

| Méthode | Route | Protection |
|---|---|---|
| `GET` | `/info` | publique sur le LAN |
| `HEAD` | `/upload/:transferId/:fileId` | jeton fichier |
| `POST` | `/upload/:transferId/:fileId` | jeton fichier |
| `GET` | `/offer/:transferId` | session |
| `GET` | `/download/:transferId/:fileId` | session + jeton fichier |
| `POST` | `/cancel/:transferId` | session |

### Reprise d'upload

```text
HEAD /upload/t_1/f_01
X-CastFlow-Token: file_...

→ X-Received-Bytes: 12582912
```

Le client envoie ensuite `File.openRead(12582912)` avec `X-Offset: 12582912`. Il n'envoie
pas une nouvelle fois le début du fichier.

### Codes principaux

| HTTP | Code | Signification |
|---|---|---|
| 400 | `INCOMPLETE` / `BAD_MANIFEST` | requête incomplète ou invalide |
| 401 | `NO_TOKEN` / `BAD_TOKEN` / `EXPIRED_TOKEN` | jeton absent/invalide |
| 401 | `AUTH_REQUIRED` | session absente |
| 403 | `NOT_ACCEPTED` | transfert non accepté |
| 404 | `UNKNOWN_FILE` | transfert, offre ou fichier inconnu |
| 409 | `OFFSET_MISMATCH` | offset différent de l'état serveur |
| 413 | `TOO_LARGE` | taille déclarée dépassée |
| 416 | `BAD_RANGE` | plage de téléchargement invalide |
| 422 | `HASH_MISMATCH` | intégrité incorrecte |

## Limites

- 500 fichiers maximum par transfert ;
- manifest/WebSocket limité à 1 Mio ;
- taille déclarée maximale de 1 Tio par fichier ;
- identifiants limités à `[A-Za-z0-9_-]` sur 100 caractères ;
- noms assainis et limités à 200 caractères.
