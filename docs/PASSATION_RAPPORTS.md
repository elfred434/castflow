# Passation et rapports — CastFlow

Ce document est le journal permanent du projet. Tout bug, incident, limitation, résultat de test, décision importante et vérification impossible doit y être ajouté.

Dernière mise à jour : 23 septembre 2026.

## 1. État courant

- Projet : CastFlow.
- Dépôt : `https://github.com/elfred434/castflow.git`.
- Branche de développement : `feature/remote-control-lan`.
- Base fonctionnelle : application Flutter de transfert local Windows/Android.
- Nouvelle cible : contrôle distant bidirectionnel Windows ↔ Android sur réseau local.
- Distribution Android retenue : APK privée.
- Mode de reconnexion retenu : session approuvée persistante dans les limites imposées par Android.
- Dernier commit officiel vérifié : `ff2857c feat(windows): ajouter les adaptateurs natifs de contrôle`.
- CI GitHub Actions du commit : exécution `35843047193`, analyse/tests Linux et compilation Windows release réussis.

## 2. Règles applicables

Les règles obligatoires sont définies dans `docs/REGLES_DE_TRAVAIL.md` :

1. ne jamais supposer ;
2. toujours s'assurer et vérifier.

## 3. Registre des problèmes, bugs et limitations

### CF-001 — Flutter initialement indisponible dans les environnements de travail

- Statut : résolu dans le sandbox ; à vérifier sur Windows.
- Gravité initiale : bloquante pour l'analyse Flutter et les tests locaux.
- Vérification initiale : les commandes `flutter` et `dart` n'étaient présentes ni dans le `PATH` du terminal Windows contrôlé ni dans le sandbox au 22 septembre 2026.
- Correction vérifiée : Flutter officiel 3.47.0 / Dart 3.13.0 a été installé et vérifié dans le cache du sandbox ; formatage, analyse et tests y sont exécutables.
- Limite restante : Flutter dans le terminal Windows n’a pas été revérifié et reste « à vérifier » ; les builds Windows/Android physiques ne sont pas couverts par les tests sandbox.

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

### CF-005 — Sécurisation du transport de contrôle

- Statut : résolu pour le WebSocket de contrôle ; chiffrement des données de fichiers encore ouvert sous CF-019.
- Gravité initiale : critique avant activation du contrôle distant.
- Correction vérifiée : le serveur actif utilise `HttpServer.bindSecure`, le client sélectionne `wss`, refuse une empreinte TLS erronée et épingle l’empreinte approuvée lors des reconnexions.
- Propagation vérifiée : `/info`, la découverte LAN et le QR annoncent désormais l’état sécurisé réel.
- Validation : handshake WSS réussi avec la bonne empreinte et rejeté avec une empreinte falsifiée ; tests d’intégration réussis.
- Décision maintenue : aucune injection distante ne doit être activée hors de ce canal WSS authentifié.

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

### CF-008 — Tests de contrôle ajoutés mais initialement non exécutés localement

- Statut : résolu.
- Gravité initiale : moyenne.
- Correction : installation vérifiée de Flutter 3.47.0 dans le cache du sandbox.
- Validation : les tests du protocole, des sessions, du transport TLS et de la confiance font partie des 60 tests locaux réussis ; la CI du lot précédent était également verte.

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

- Statut : résolu.
- Gravité : moyenne.
- Vérification : l'exécution `35793492768` a installé Flutter et les dépendances, puis a échoué à l'étape `dart format`; analyse et tests ont été ignorés.
- Diagnostic vérifié : Dart 3.13.0 a identifié uniquement `lib/remote/control_protocol.dart` comme non formaté.
- Correction : fichier réécrit par `dart format`; un second contrôle retourne zéro fichier à modifier.
- Validation : l'exécution CI `35794668297` a réussi formatage, analyse et tests.

### CF-013 — Trois violations du lint sur les accolades

- Statut : résolu.
- Gravité : faible.
- Vérification : `flutter analyze` avec Flutter 3.47.0 a signalé trois occurrences de `curly_braces_in_flow_control_structures` dans `lib/remote/control_protocol.dart`.
- Correction : ajout d'accolades autour des trois blocs conditionnels.
- Validation : `flutter analyze` local et CI réussis.

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

### CF-016 — État Git du sandbox restauré sur une ancienne base entre deux tours

- Statut : résolu pour le lot courant, prévention requise à chaque reprise.
- Gravité : haute pour la production de patches.
- Vérification : le pointeur local du sandbox était revenu à `3494b9e` alors que GitHub était à `f1bf812`; les fichiers récents apparaissaient donc comme modifications non validées.
- Cause observée : la configuration Git distante du sandbox n'est pas persistée entre tous les tours et les répertoires exclus des snapshots peuvent disparaître.
- Correction : sauvegarde uniquement du nouveau lot TLS, recréation de `origin`, `fetch`, `reset --hard origin/feature/remote-control-lan`, puis réapplication du seul lot courant.
- Règle préventive : vérifier `git rev-parse HEAD` contre GitHub et recréer `origin` au début de chaque reprise avant toute modification.

### CF-017 — Échecs intermédiaires pendant l’intégration confiance/WSS

- Statut : résolu.
- Gravité : faible, sans publication.
- Première validation : l’analyse a trouvé deux erreurs de compilation (`TrustedPeerStore?` non promu et appel de `keys` sur un `Set`) ; les tests ne pouvaient donc pas compiler ce lot.
- Incident d’édition : deux remplacements parallèles visant le même fichier ont laissé un fragment `ge;` en fin de `castflow_server.dart` et perdu l’un des remplacements.
- Correction : réparations séquentielles, reformatage, nouvelle analyse et nouvelle exécution des tests.
- Validation finale : analyse sans problème et 60/60 tests réussis.
- Prévention : ne plus paralléliser des écritures distinctes sur un même fichier.

### CF-018 — Authentification de la toute première découverte

- Statut : ouvert.
- Gravité : haute sur un LAN hostile.
- Vérification : l’épinglage protège les connexions suivantes avec l’empreinte mémorisée ; le QR transporte également l’empreinte du certificat.
- Limite : une empreinte reçue pour la première fois par découverte LAN n’est pas authentifiée indépendamment. La découverte seule reste de type TOFU et ne doit pas être présentée comme résistante à un attaquant actif présent dès le premier appairage.
- Mesure actuelle : PIN et approbation locale explicite ; privilégier le QR affiché physiquement pour la première connexion.
- Suite requise : définir et valider une cérémonie de premier appairage vérifiable avant distribution.

### CF-019 — Corps des transferts de fichiers encore transportés en HTTP clair

- Statut : ouvert.
- Gravité : haute pour la confidentialité des fichiers.
- Vérification : le contrôle et l’échange du secret utilisent WSS, mais les routes `/upload`, `/download`, `/offer` et `/cancel` restent sur le serveur HTTP historique avec jetons et session.
- Impact : l’intégrité et l’autorisation existantes sont conservées, mais le contenu des fichiers n’est pas chiffré sur le LAN.
- Décision : ne pas confondre la sécurisation du canal de contrôle avec celle du contenu des fichiers ; migrer ou chiffrer ces routes dans un lot dédié sans casser le transfert existant.

### CF-020 — Appairage persistant non encore activable sans adaptateur de contrôle

- Statut : limitation temporaire volontaire.
- Gravité : fonctionnelle.
- Vérification : le protocole d’appairage explicite, le stockage bilatéral du secret et la reconnexion HMAC sont testés en intégration avec des capacités injectées.
- Comportement de production : CastFlow n’annonce volontairement aucune capacité native tant que les adaptateurs Windows/Android n’existent pas ; le bouton d’approbation n’est donc affiché que lorsqu’un pair annonce réellement des capacités.
- Décision : ne pas annoncer de fausses capacités uniquement pour rendre l’interface active.

### CF-021 — Incidents de transfert/publication du patch WSS

- Statut : résolu.
- Gravité : faible, sans perte de code.
- Premier échec : l’appel direct `./arena.sh put` a retourné « Permission denied », le script n’étant pas exécutable dans le sandbox restauré.
- Correction : invocation explicite avec `bash ./arena.sh` ; le patch de 52 056 octets a été transféré et son SHA-256 a été vérifié identique sur Windows.
- Second échec : une commande PowerShell contenant `$LASTEXITCODE` et des accents graves a été interprétée prématurément par Bash, produisant une erreur de syntaxe avant toute application du patch.
- Correction : nouvelle commande avec `$?` échappé ; `git am` et `git push` ont réussi.
- Résultat vérifié : commit officiel `de251e9`, seuls les trois fichiers locaux du pont restent non suivis sur Windows.

### CF-022 — SDK Flutter du sandbox supprimé à la restauration

- Statut : contourné, récurrence possible.
- Gravité : moyenne pour la validation locale.
- Vérification : après une nouvelle restauration du sandbox sur l’ancien pointeur `3494b9e`, le répertoire Flutter sous `.cache` avait disparu ; les commandes `dart` et `flutter` ont échoué avec « command not found ».
- Vérification Windows : `where flutter`, `where cmake` et `where cl` n’ont trouvé aucun outil dans le `PATH` du terminal contrôlé.
- Correction : nouvelle récupération de l’archive officielle Flutter 3.47.0, SHA-256 `26cd99d3d94b1367e6b50535a18aeef0282c10a535bbe3ec493534dcdab75296` vérifié avant extraction.
- Validation après restauration : Flutter 3.47.0 / Dart 3.13.0, analyse sans problème et 65/65 tests réussis.

### CF-023 — Adaptateur Windows natif

- Statut : compilation vérifiée ; exécution physique à vérifier.
- Gravité restante : haute avant activation de bout en bout.
- Travail réalisé : canal Flutter/C++ dédié, capture BGRA bornée du bureau virtuel avec GDI, et injection souris/clavier/texte avec `SendInput`.
- Validation Dart : contrat, dimensions et taille BGRA, rejet d’une trame tronquée et validation des entrées couverts par cinq tests réussis.
- Validation Windows : le job GitHub Actions `windows-latest` a exécuté `flutter build windows --release` avec succès dans l’exécution `35843047193`.
- Validation manquante : capture et injection réelles sur le PC Windows physique, les outils Flutter/CMake/MSVC n’étant pas disponibles dans le `PATH` du terminal contrôlé.
- Mesure : aucune capacité native n’est encore annoncée au réseau avant intégration de la barrière de session et du transport d’images.
- Limites connues : GDI est un premier chemin de capture synchrone, pas encore le pipeline Windows Graphics Capture/Desktop Duplication prévu; `SendInput` reste soumis à UIPI et ne peut pas contrôler une application d’intégrité supérieure ni l’écran UAC.

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
| 2026-09-22 | Machine d'état des sessions de contrôle | Analyse 0 problème, tests 53/53 réussis |
| 2026-09-22 | CI GitHub Actions `35794668297` | Formatage, analyse et tests réussis |
| 2026-09-22 | Identité TLS et épinglage | Analyse 0 problème, tests 57/57 réussis |
| 2026-09-22 | Première validation intégration confiance/WSS | Échec de compilation : 2 erreurs Dart ; CF-017 |
| 2026-09-22 | Validation intermédiaire ciblée | Analyse 0 problème, 12/12 tests d’intégration réussis |
| 2026-09-22 | Canal WSS de production et empreinte erronée | Connexion correcte acceptée, mauvaise empreinte rejetée |
| 2026-09-22 | Appairage explicite et reconnexion HMAC sans nouveau PIN | Test d’intégration réussi |
| 2026-09-22 | Validation finale du lot local | Formatage stable, analyse 0 problème, 60/60 tests réussis |
| 2026-09-22 | Patch WSS appliqué et poussé depuis Windows | Commit officiel `de251e9` |
| 2026-09-22 | CI GitHub Actions `35796517545` | Réussie sur `de251e9` |
| 2026-09-22 | CI GitHub Actions `35796652054` | Réussie sur `f3132e4` |
| 2026-09-23 | Première tentative de validation de l’adaptateur Windows | Échec avant compilation : SDK Flutter du cache absent ; CF-022 |
| 2026-09-23 | SDK Flutter 3.47.0 restauré | Archive officielle et SHA-256 vérifiés |
| 2026-09-23 | Contrat Dart de l’adaptateur Windows | Analyse 0 problème, 5/5 tests ciblés puis 65/65 tests complets réussis |
| 2026-09-23 | Première compilation du C++ Windows | Réussie en release dans la CI `35843047193` |
| 2026-09-23 | CI Linux du lot adaptateur Windows | Formatage, analyse et 65/65 tests réussis |

## 6. Travail réalisé pour le contrôle distant

Commit observé : `37b773a feat(remote): definir le protocole de controle LAN`.

Ajouts :

- `docs/REMOTE_CONTROL.md` ;
- `lib/remote/control_protocol.dart` ;
- `test/control_protocol_test.dart`.

Le protocole couvre les capacités, états, demandes de session et événements d'entrée validés. Il ne capture pas encore d'écran et n'injecte encore aucune entrée native.

Fondations de confiance maintenant reliées au handshake dans le lot local :

- secret d'appairage aléatoire de 256 bits transmis uniquement après authentification sur WSS ;
- approbation locale explicite avec capacités limitées à celles réellement annoncées par l’hôte ;
- stockage du même secret dans le coffre de chaque pair ;
- challenge limité à 30 secondes ;
- preuve HMAC-SHA256 liée aux deux appareils ;
- comparaison constante et consommation unique du challenge ;
- reconnexion validée sans nouveau PIN ;
- refus d’un retour en WebSocket clair pour un pair déjà approuvé.

Ajouts suivants validés :

- coffre sécurisé Android/Windows derrière une interface testable ;
- création, lecture, classement, mise à jour et révocation des appareils approuvés ;
- négociation bidirectionnelle des capacités de contrôle pendant le handshake ;
- rafraîchissement authentifié des capacités distantes ;
- aucun contrôle natif annoncé par défaut tant qu'aucun adaptateur n'est actif ;
- machine d'état imposant approbation locale, transitions valides et session unique ;
- rejet des événements d'entrée rejoués, négatifs ou désordonnés ;
- expiration automatique des demandes sans décision après 30 secondes ;
- identité TLS RSA 2048 générée hors thread principal ;
- certificat et clé privée persistés dans le coffre sécurisé ;
- empreinte SHA-256 recalculée et vérifiée au chargement ;
- contexte serveur TLS et connexion cliente avec épinglage testés.

## 7. Prochaines étapes vérifiables

1. Publier ce lot WSS/appairage après application du patch et validation sur Windows.
2. Ajouter la révocation et une rotation sûre des secrets/certificats depuis l’interface utilisateur.
3. Définir puis valider la cérémonie de première association contre un attaquant LAN actif (CF-018).
4. Chiffrer les corps de fichiers sans régression du transfert existant (CF-019).
5. Implémenter les adaptateurs Windows de capture et d’entrée, puis annoncer uniquement leurs capacités réellement actives.
6. Relier la machine d’état de contrôle déjà testée aux adaptateurs et aux écrans de contrôle.
7. Tester le coffre, WSS et la reconnexion sur appareils Windows et Android physiques.

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
