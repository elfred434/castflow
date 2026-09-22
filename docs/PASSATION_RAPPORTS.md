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

### CF-001 — Flutter indisponible dans les environnements de travail

- Statut : partiellement contourné.
- Gravité : bloquant pour l'analyse Flutter et les builds locaux.
- Vérification initiale : les commandes `flutter` et `dart` n'étaient présentes ni dans le `PATH` du terminal Windows contrôlé ni dans le sandbox au 22 septembre 2026.
- Action vérifiée : le SDK Dart autonome 3.13.0 a été téléchargé dans le cache non versionné du sandbox ; `dart format` peut maintenant y être exécuté.
- Limite restante : Flutter reste absent du terminal Windows et du sandbox ; `flutter analyze`, `flutter test` et les builds restent confiés à la CI.
- Condition de fermeture : installation vérifiée de Flutter ou environnement local équivalent à la CI.

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

### CF-010 — Coffre sécurisé pour les secrets de confiance

- Statut : implémenté, validation native sur appareils à effectuer.
- Gravité initiale : critique avant persistance d'un appareil approuvé.
- Vérification initiale : `SettingsRepository` utilisait `SharedPreferences` et aucun coffre natif n'était déclaré.
- Correction : ajout de `flutter_secure_storage 11.2.0`, d'une abstraction testable et de `TrustedPeerStore`; les secrets ne passent pas par `SharedPreferences`.
- Validation locale : résolution des dépendances, génération du plugin Windows, analyse sans erreur et sept tests de stockage réussis.
- Limite restante : voir CF-015 pour la validation physique des coffres Android et Windows.

### CF-011 — La CI ne se déclenchait pas sur la branche de développement

- Statut : résolu.
- Gravité : haute dans un environnement sans SDK Flutter local.
- Vérification initiale : l'API GitHub Actions a retourné zéro exécution pour `feature/remote-control-lan` après publication ; `.github/workflows/ci.yml` limitait les push à `main`, `master` et `develop`.
- Correction : déclencher le workflow CI sur toutes les branches poussées tout en conservant les branches cibles des pull requests.
- Validation : l'exécution GitHub Actions `35793492768` a bien été déclenchée sur la branche.

### CF-012 — Échec CI au contrôle de formatage

- Statut : corrigé localement, nouvelle CI en attente.
- Gravité : moyenne.
- Vérification : l'exécution `35793492768` a installé Flutter et les dépendances, puis a échoué à l'étape `dart format`; analyse et tests ont été ignorés.
- Diagnostic vérifié : Dart 3.13.0 a identifié uniquement `lib/remote/control_protocol.dart` comme non formaté.
- Correction : fichier réécrit par `dart format`; un second contrôle retourne zéro fichier à modifier.
- Condition de fermeture : nouvelle CI complète réussie.

### CF-013 — Trois violations du lint sur les accolades

- Statut : corrigé localement, validation complète en cours.
- Gravité : faible.
- Vérification : `flutter analyze` avec Flutter 3.47.0 a signalé trois occurrences de `curly_braces_in_flow_control_structures` dans `lib/remote/control_protocol.dart`.
- Correction : ajout d'accolades autour des trois blocs conditionnels.
- Condition de fermeture : `flutter analyze` et la CI doivent réussir.

### CF-014 — Dépendances plus récentes disponibles

- Statut : à étudier séparément.
- Gravité : information.
- Vérification : `flutter pub get` avec Flutter 3.47.0 signale 34 paquets ayant une version plus récente incompatible avec les contraintes actuelles.
- Décision : ne pas mettre à jour en bloc sans audit de compatibilité ; ce constat n'empêche pas la validation de la version verrouillée actuelle.

### CF-015 — Coffres natifs non testés sur appareils physiques

- Statut : à vérifier.
- Gravité : haute avant distribution.
- Vérification acquise : la version officielle `flutter_secure_storage 11.2.0` annonce Android et Windows, exige Dart ≥ 3.8 et Flutter ≥ 3.19; le projet respecte ces versions et Android minSdk 23.
- Vérification manquante : aucune écriture/lecture réelle n'a encore été exécutée dans Android Keystore ni Windows Credential Manager sur les appareils cibles.
- Mesure : l'interface est testée avec un coffre mémoire; ne pas déclarer la persistance native validée avant essais physiques.

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
| 2026-09-22 | CI `35793492768` | Échec au formatage ; analyse et tests ignorés |
| 2026-09-22 | Formatage avec Dart 3.13.0 | 21 fichiers contrôlés, `control_protocol.dart` corrigé, puis 0 changement restant |
| 2026-09-22 | SDK Flutter sandbox | Archive officielle Flutter 3.47.0, SHA-256 vérifié |
| 2026-09-22 | Analyse Flutter après corrections | 0 problème |
| 2026-09-22 | Tests avant coffre sécurisé | 37/37 réussis |
| 2026-09-22 | Tests après coffre sécurisé | 44/44 réussis |
| 2026-09-22 | Formatage après coffre sécurisé | 23 fichiers, 0 changement restant |
| 2026-09-22 | Négociation des capacités client/serveur | Analyse 0 problème, tests 45/45 réussis |

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

Ajouts suivants validés :

- coffre sécurisé Android/Windows derrière une interface testable ;
- création, lecture, classement, mise à jour et révocation des appareils approuvés ;
- négociation bidirectionnelle des capacités de contrôle pendant le handshake ;
- rafraîchissement authentifié des capacités distantes ;
- aucun contrôle natif annoncé par défaut tant qu'aucun adaptateur n'est actif.

## 7. Prochaines étapes vérifiables

1. Relier le challenge de confiance et le coffre au handshake client/serveur.
2. Ajouter révocation et rotation depuis l'interface utilisateur.
3. Sécuriser le transport local et vérifier l'épinglage avant toute injection distante.
4. Implémenter la machine d'état demande/acceptation/arrêt d'une session de contrôle.
5. Commencer l'adaptateur Windows uniquement après validation des étapes précédentes.
6. Tester le coffre sur appareils Windows et Android physiques.

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
