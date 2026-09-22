# Passation et rapports — CastFlow

Ce document est le journal permanent du projet. Tout bug, incident, limitation, résultat de test, décision importante et vérification impossible doit y être ajouté.

Dernière mise à jour : 22 septembre 2026.

## 1. État courant

- Projet : CastFlow.
- Dépôt : `https://github.com/elfred434/castflow.git`.
- Branche de développement : `feature/remote-control-lan`.
- Base fonctionnelle : application Flutter de transfert local Windows/Android.
- Nouvelle cible : contrôle distant bidirectionnel Windows ↔ Android sur réseau local.
- Distribution Android retenue : APK privée.
- Mode de reconnexion retenu : session approuvée persistante dans les limites imposées par Android.
- Dernier commit de fondation observé : `37b773a feat(remote): definir le protocole de controle LAN`.

## 2. Règles applicables

Les règles obligatoires sont définies dans `docs/REGLES_DE_TRAVAIL.md` :

1. ne jamais supposer ;
2. toujours s'assurer et vérifier.

## 3. Registre des problèmes, bugs et limitations

### CF-001 — Flutter et Dart indisponibles dans les environnements de travail

- Statut : ouvert.
- Gravité : bloquant pour la validation locale.
- Vérification : les commandes `flutter` et `dart` ne sont présentes ni dans le `PATH` du terminal Windows contrôlé ni dans le sandbox au 22 septembre 2026.
- Impact : impossibilité d'exécuter localement `flutter analyze`, `flutter test` et les builds.
- Contournement actuel : écrire des tests et les faire exécuter par la CI GitHub.
- Condition de fermeture : installation vérifiée du SDK attendu ou exécution réussie de la CI.

### CF-002 — Dépendances JavaScript suivies par Git

- Statut : ouvert.
- Gravité : moyenne.
- Vérification : 5 048 chemins sous `node_modules/` sont suivis par Git ; le dépôt suit 5 152 fichiers avant l'ajout des fondations de contrôle.
- Impact : dépôt inutilement volumineux, diffs bruyants et avertissements Git.
- Observation : aucun `package.json` racine n'est présent dans la version Flutter actuelle.
- Action proposée, non encore exécutée : vérifier l'absence de dépendance à l'ancien projet, ajouter `node_modules/` aux exclusions et retirer ces fichiers de l'index dans un commit isolé.

### CF-003 — Résidus des anciennes applications Electron/Expo

- Statut : ouvert.
- Gravité : faible à moyenne.
- Vérification : 31 fichiers suivis existent sous `apps/`, principalement dans `apps/desktop/node_modules/.vite` et `apps/mobile/.expo`.
- Impact : confusion sur l'architecture canonique, désormais Flutter.
- Action proposée, non encore exécutée : confirmer qu'aucun workflow ou script ne les utilise, puis les retirer dans le même lot de nettoyage que CF-002.

### CF-004 — Fichiers du pont présents mais non suivis

- Statut : accepté.
- Gravité : information.
- Fichiers : `arena-bridge.py`, `Demarrer-Pont.ps1`, `Tester-Pont.ps1`.
- Vérification : ils apparaissent comme non suivis dans le terminal Windows mais ne sont pas présents dans le clone Git du sandbox.
- Décision : ne pas les inclure dans les commits applicatifs.

### CF-005 — Transport de contrôle actuel non chiffré

- Statut : ouvert.
- Gravité : critique avant activation du contrôle distant.
- Vérification : le protocole actuel utilise HTTP et WebSocket en clair ; Android déclare `android:usesCleartextTraffic="true"`.
- Impact : un contrôle distant persistant ne doit pas transmettre secrets, images ou entrées sur ce canal sans protection supplémentaire.
- Décision : ne pas activer l'injection distante avant identité cryptographique, transport local sécurisé, épinglage et preuve de reconnexion.

### CF-006 — Limites Android lorsque l'écran est éteint ou verrouillé

- Statut : contrainte plateforme.
- Gravité : fonctionnelle.
- Faits à respecter :
  - MediaProjection exige un consentement système initial ;
  - une capture peut être suspendue ou noire lorsque l'écran physique est éteint ;
  - `FLAG_SECURE` empêche la capture de certaines applications ;
  - CastFlow ne doit jamais contourner PIN, schéma ou biométrie ;
  - un réveil à distance ne constitue pas un déverrouillage.
- Conséquence produit : la session approuvée évite une confirmation CastFlow répétée lorsque les services restent actifs, mais ne neutralise aucune protection Android.

### CF-007 — Fichiers applicatifs très volumineux

- Statut : ouvert.
- Gravité : maintenabilité.
- Vérification : `home_shell.dart` contient 974 lignes et `castflow_server.dart` 934 lignes dans l'état observé.
- Impact : évolution du contrôle distant plus risquée si les nouvelles responsabilités y sont ajoutées directement.
- Décision : créer des modules `remote/` et des adaptateurs dédiés au lieu d'ajouter toute la logique à ces fichiers.

### CF-008 — Tests de contrôle ajoutés mais non exécutés localement

- Statut : à vérifier.
- Gravité : moyenne.
- Fichier : `test/control_protocol_test.dart`.
- Cause : CF-001.
- Condition de fermeture : CI réussie ou installation locale vérifiée de Flutter.

### CF-009 — Affichage de caractères altérés dans certains retours PowerShell

- Statut : circonscrit.
- Gravité : faible.
- Observation : certains retours du pont affichent des caractères français incorrectement.
- Vérification : `README.md` et les fichiers `docs/*.md` du clone sandbox sont identifiés comme textes UTF-8.
- Conclusion vérifiée : l'altération observée concerne le chemin d'affichage PowerShell/pont ; aucune corruption des fichiers contrôlés n'a été démontrée.

### CF-010 — Coffre sécurisé pour les secrets de confiance non implémenté

- Statut : ouvert.
- Gravité : critique avant persistance d'un appareil approuvé.
- Vérification : `SettingsRepository` utilise actuellement `SharedPreferences` et aucun coffre natif n'est déclaré dans `pubspec.yaml`.
- Impact : le secret d'appairage ne doit pas être persisté tant qu'un stockage protégé Windows/Android n'est pas intégré et vérifié.
- Mesure actuelle : le protocole de preuve manipule le secret uniquement en mémoire et documente explicitement l'interdiction de SharedPreferences.

## 4. Décisions d'architecture

### DA-001 — Séparation transfert et contrôle

Le droit de transférer un fichier ne donne jamais automatiquement le droit de voir un écran ou d'injecter des entrées.

### DA-002 — Protocole de contrôle dédié

Les messages de négociation restent dans les enveloppes CastFlow. Les images utiliseront un canal binaire dédié. Les événements d'entrée utilisent des coordonnées normalisées et sont validés avant exécution.

### DA-003 — Adaptateurs natifs

- Windows : capture Windows Graphics Capture/Desktop Duplication et injection `SendInput`.
- Android : MediaProjection et AccessibilityService.
- La couche Flutter orchestre les sessions mais ne prétend pas remplacer les API natives.

### DA-004 — Première cible vidéo

Le premier MVP vise au maximum 1280×720 et 15 images/s en JPEG adaptatif. Cette cible devra être mesurée sur appareils réels avant toute conclusion sur les performances.

## 5. Journal des validations

| Date | Vérification | Résultat |
|---|---|---|
| 2026-09-22 | Lecture de README, architecture, protocole et sources principales | Réussie |
| 2026-09-22 | État Git et historique | Branche `feature/remote-control-lan` vérifiée |
| 2026-09-22 | Présence Flutter/Dart terminal Windows | Absents du PATH |
| 2026-09-22 | Présence Flutter/Dart sandbox | Absents du PATH |
| 2026-09-22 | Encodage des documents dans le sandbox | UTF-8 vérifié |
| 2026-09-22 | Publication et récupération du commit `37b773a` | Réussies |
| 2026-09-22 | Exécution des nouveaux tests Flutter | Impossible, CF-001 |
| 2026-09-22 | Dépendance cryptographique existante | `crypto 3.0.7` vérifiée dans `pubspec.lock` |
| 2026-09-22 | Stockage sécurisé existant | Aucun coffre natif trouvé ; CF-010 ouvert |

## 6. Travail réalisé pour le contrôle distant

Commit observé : `37b773a feat(remote): definir le protocole de controle LAN`.

Ajouts :

- `docs/REMOTE_CONTROL.md` ;
- `lib/remote/control_protocol.dart` ;
- `test/control_protocol_test.dart`.

Le protocole couvre les capacités, états, demandes de session et événements d'entrée validés. Il ne capture pas encore d'écran et n'injecte encore aucune entrée native.

Travail en cours dans le lot suivant :

- secret d'appairage aléatoire de 256 bits ;
- challenge limité à 30 secondes ;
- preuve HMAC-SHA256 liée aux deux appareils ;
- comparaison constante ;
- consommation unique du challenge, y compris après une tentative invalide ;
- tests de validité, expiration, rejeu et substitution d'identité.

## 7. Prochaines étapes vérifiables

1. Ajouter et tester la preuve cryptographique de reconnexion d'un appareil approuvé.
2. Définir une interface de stockage sécurisé sans placer de secret dans SharedPreferences.
3. Intégrer la négociation des capacités au client et au serveur existants.
4. Faire exécuter la suite Flutter par CI.
5. Ne commencer les adaptateurs natifs qu'après validation du transport de confiance.

## 8. Modèle pour les prochaines entrées

```text
### CF-XXX — Titre

- Statut : ouvert | en cours | résolu | accepté | à vérifier.
- Gravité : information | faible | moyenne | haute | critique.
- Contexte :
- Reproduction ou commande exécutée :
- Résultat exact :
- Cause vérifiée :
- Correction :
- Validation :
- Commit :
```
