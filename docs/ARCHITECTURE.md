# CastFlow — architecture Flutter

## Vue d'ensemble

CastFlow partage désormais son UI, son protocole et son moteur de transfert entre
Windows et Android grâce à Flutter/Dart.

```text
┌──────────────────────────┐               ┌──────────────────────────┐
│ Windows Flutter          │               │ Android Flutter          │
├──────────────────────────┤               ├──────────────────────────┤
│ UI adaptative            │               │ UI + scanner QR          │
│ CastFlowServer           │◄──── LAN ────►│ CastFlowClient           │
│ HTTP + WebSocket + UDP   │               │ HTTP + WebSocket + UDP   │
│ stockage Téléchargements │               │ stockage application     │
└──────────────────────────┘               └──────────────────────────┘
```

Windows joue normalement le rôle d'hôte. Android se connecte par QR, découverte UDP ou
adresse IP. Le code réseau n'est néanmoins pas lié à l'UI et peut évoluer vers d'autres
combinaisons d'appareils.

## Modules

| Module | Responsabilité |
|---|---|
| `app/` | cycle de vie, orchestration, sélection et progression |
| `core/` | modèles, états, ports et limites |
| `network/castflow_server.dart` | serveur HTTP/WS, sessions, réception et offres |
| `network/castflow_client.dart` | handshake, upload/download repris |
| `network/discovery_service.dart` | annonces et découverte UDP |
| `protocol/` | enveloppes JSON et URL `castflow://` |
| `security/` | HMAC, identifiants, FNV-1a et noms sûrs |
| `storage/` | identité stable et préférences |
| `ui/` | écrans adaptatifs Windows/Android |

## Flux mobile vers Windows

1. Le client ouvre le WebSocket et envoie `HELLO`.
2. L'hôte renvoie un nonce dans `HELLO_ACK`.
3. Si nécessaire, Android prouve le PIN avec HMAC-SHA256.
4. Android calcule le hash de chaque fichier puis envoie `TRANSFER_REQUEST`.
5. Windows demande une acceptation explicite.
6. Après `TRANSFER_ACCEPT`, le client interroge `HEAD /upload/...`.
7. `File.openRead(offset)` envoie uniquement la partie manquante.
8. Windows vérifie taille et FNV-1a avant le renommage final.

## Flux Windows vers mobile

1. Windows calcule les empreintes avant de publier l'offre.
2. `OFFER` est envoyé sans jetons dans le WebSocket.
3. Android relit `/offer/:id` avec son jeton de session.
4. Chaque téléchargement exige le jeton de session et un jeton de fichier.
5. Une réponse `Range` permet de reprendre un `.cfpart` mobile.
6. Android vérifie le hash en streaming avant publication.

## Défenses en place

- preuve PIN HMAC-SHA256 et comparaison constante ;
- session aléatoire après authentification ;
- jeton aléatoire par fichier, TTL de 10 minutes et consommation après succès ;
- aucune confiance automatique fondée sur une simple fingerprint ;
- `/offer`, `/download` et `/cancel` protégés par session ;
- taille maximale des messages et manifestes ;
- limite du nombre de fichiers et de la taille déclarée ;
- identifiants stricts et assainissement des noms Windows ;
- plage HTTP validée et collision de noms réservée dans le processus ;
- hash FNV-1a 64 vérifié en streaming sur les deux plateformes.

## Limites actuelles

- HTTP et WebSocket restent en clair sur le LAN ;
- le serveur Windows écoute toutes les interfaces IPv4 ;
- la découverte broadcast peut être bloquée par certains routeurs/Android ;
- les clés de signature de production ne sont pas fournies ;
- pas encore de Wi-Fi Direct natif ni de TLS épinglé.

## Packaging

- Windows : `flutter build windows --release`, puis Inno Setup ;
- Android : `flutter build apk --release` ;
- GitHub Actions valide les 24 tests avant de publier les artefacts.
