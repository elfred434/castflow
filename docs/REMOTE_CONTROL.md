# CastFlow Remote Control — architecture LAN

## Objectif

Ajouter au transfert de fichiers existant un contrôle distant bidirectionnel :

- Android affiche et contrôle Windows ;
- Windows affiche et contrôle Android ;
- fonctionnement sur le même réseau local, sans cloud ;
- APK Android distribuée en privé ;
- reconnexion d'un appareil déjà approuvé tant que les autorisations système restent valides.

Le transfert de fichiers et le contrôle distant restent deux capacités séparées. Un appareil autorisé à recevoir des fichiers n'obtient pas automatiquement le droit de capturer un écran ou d'injecter des entrées.

## Limites Android non contournables

- La première capture d'écran exige le dialogue système `MediaProjection`.
- L'autorisation de contrôle exige l'activation manuelle d'un `AccessibilityService`.
- Une session MediaProjection n'est pas une autorisation permanente après redémarrage ou arrêt forcé.
- Lorsque l'écran physique est réellement éteint, Android peut suspendre ou noircir la capture selon le constructeur.
- CastFlow peut demander le réveil de l'appareil, mais ne contourne jamais le PIN, le schéma, la biométrie ni l'écran verrouillé sécurisé.
- Les applications utilisant `FLAG_SECURE` restent noires dans la capture.

Une « session approuvée persistante » signifie donc : pas de nouvelle confirmation CastFlow pour le PC approuvé, mais respect obligatoire des protections Android.

## Architecture

```text
Contrôleur                           Appareil contrôlé
──────────                           ──────────────────
RemoteControlViewer                  ScreenCaptureAdapter
InputTranslator       WebSocket      InputInjectionAdapter
SessionController  <──────────────>  ControlSessionHost
                    TLS épinglé
```

### Couche Dart partagée

- négociation des capacités ;
- demande, acceptation, pause et arrêt de session ;
- validation des événements d'entrée ;
- contrôle du débit et mesure de latence ;
- rendu des images et transformation des coordonnées ;
- registre des appareils approuvés.

### Adaptateur Windows natif

- capture d'écran : Windows Graphics Capture, avec repli Desktop Duplication ;
- injection : `SendInput` pour souris et clavier ;
- écran et fenêtre sélectionnables ;
- aucune exécution avec élévation implicite ;
- écran UAC non contrôlable sans composant signé et élevé.

### Adaptateur Android natif

- capture : `MediaProjection` dans un service au premier plan ;
- injection : `AccessibilityService.dispatchGesture` et actions globales ;
- saisie de texte via nœud d'accessibilité lorsqu'elle est permise ;
- réveil : wake lock temporaire, sans contournement du verrouillage ;
- notification persistante pendant toute capture ou prise de contrôle.

## Protocole de contrôle

Les messages de contrôle utilisent l'enveloppe JSON CastFlow existante :

- `CONTROL_CAPABILITIES`
- `CONTROL_REQUEST`
- `CONTROL_ACCEPT` / `CONTROL_DENY`
- `CONTROL_READY`
- `CONTROL_INPUT`
- `CONTROL_PAUSE` / `CONTROL_RESUME`
- `CONTROL_STOP`
- `CONTROL_ERROR`
- `TRUST_CHALLENGE` / `TRUST_PROOF` / `TRUST_REVOKE`

Les coordonnées de pointeur sont normalisées entre 0 et 1 afin de rester indépendantes de la résolution et de l'orientation.

Les images sont transportées en binaire sur un WebSocket dédié. Le premier MVP utilise JPEG adaptatif, au maximum 1280×720 et 15 images/s. Une migration vers H.264/WebRTC reste possible sans modifier les événements d'entrée.

## Sécurité obligatoire

Le contrôle distant ne doit pas être activé sur le WebSocket HTTP clair actuel.

Avant l'activation des adaptateurs natifs :

1. identité cryptographique persistante par appareil ;
2. appairage explicite par QR/PIN ;
3. transport TLS local avec empreinte épinglée ;
4. secret de confiance stocké via les coffres Windows/Android, jamais dans SharedPreferences ;
5. challenge HMAC unique à chaque reconnexion ;
6. jeton de contrôle distinct du jeton de transfert ;
7. expiration, révocation et journal local des sessions ;
8. indicateur visuel permanent et bouton d'arrêt local prioritaire ;
9. aucun contrôle automatique d'un appareil seulement « découvert » sur UDP.

## Lots d'implémentation

### Lot 1 — fondations

- modèles et validation du protocole de contrôle ;
- capacités par plateforme ;
- états de session ;
- tests de sérialisation et de rejet des entrées invalides.

### Lot 2 — confiance et transport

- identité cryptographique persistante ;
- stockage sécurisé natif ;
- TLS local et épinglage ;
- appairage, révocation et reconnexion approuvée.

### Lot 3 — téléphone vers PC

- capture Windows ;
- affichage sur Android ;
- souris, clavier, texte et raccourcis ;
- adaptation de résolution et débit.

### Lot 4 — PC vers téléphone

- service MediaProjection ;
- service d'accessibilité ;
- affichage Android sur Windows ;
- toucher, gestes, texte et navigation système.

### Lot 5 — robustesse

- reprise de session ;
- rotation et multi-écran ;
- presse-papiers optionnel ;
- tests sur appareils physiques ;
- optimisation H.264 si JPEG est insuffisant.

## Critères du premier MVP

- connexion LAN entre un PC Windows et un téléphone Android ;
- consentement local explicite lors du premier appairage ;
- affichage 720p jusqu'à 15 FPS ;
- latence d'entrée ciblée sous 150 ms sur Wi-Fi local ;
- arrêt immédiat depuis chaque appareil ;
- aucune entrée acceptée sans session active et capacité accordée ;
- reconnexion du PC approuvé sans nouvelle confirmation CastFlow lorsque le service Android est toujours actif ;
- aucune tentative de contourner le verrouillage Android.
