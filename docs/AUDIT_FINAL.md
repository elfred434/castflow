# Audit final CastFlow

**Date :** 14 août 2026  
**Révision auditée :** `33963fd` (`main`), puis correctifs locaux décrits ci-dessous  
**Périmètre :** serveur desktop, client mobile, tests, builds, packaging Electron/Android et GitHub Actions.

## 1. Verdict

Le cœur de transfert est cohérent et les **37 tests automatisés passent**. Le build
TypeScript partagé, le build Vite, Expo Doctor et la génération native Android passent
également. Le packaging Electron en répertoire fonctionne sous Linux et pour la cible
Windows `win-unpacked`.

Le projet est prêt à faire exécuter le nouveau workflow CI qui produit les `.exe` et
l'APK. Il n'est toutefois **pas encore prêt pour une publication publique de production**
sans traiter au minimum la signature des binaires, la dette Expo/React Native et les
faiblesses de sécurité réseau détaillées plus bas.

## 2. Résultats vérifiés

| Contrôle | Résultat |
|---|---|
| `npm ci` à la racine | OK |
| `npm test` | **37/37 tests OK** sous Node 22.23.2 et 24.19.0 : core 13, e2e 9, hash 9, receive 6 |
| Analyse syntaxique | 25 fichiers valides, 0 erreur |
| Cohérence du protocole | 6/6 contrôles OK |
| Configuration mobile | 9/9 contrôles OK |
| Configuration packaging | 9/9 contrôles OK |
| `npm run build:shared` | OK |
| `npm run build:desktop` | OK, bundle principal 176,14 kB (55,96 kB gzip) |
| `npx expo install --check` | OK |
| `npx expo-doctor` | **17/17 contrôles OK** |
| `expo prebuild --platform android` | OK ; `usesCleartextTraffic=true` bien généré |
| `electron-builder --dir` | OK avec electron-builder 26.15.3 |
| `electron-builder --win --dir` | OK, `win-unpacked/castflow.exe` généré |
| `npm audit --omit=dev` à la racine | 0 vulnérabilité de production |
| `npm audit --omit=dev` mobile | **31 alertes** : 1 critique, 18 hautes, 11 modérées, 1 basse |

Le build NSIS complet lancé depuis ce conteneur Linux atteint la création de
l'installateur puis s'arrête faute de `wine`. C'est une limite de l'environnement local,
pas de la configuration cible : le workflow exécute ce build sur `windows-latest`.
L'APK Gradle complet n'a pas été compilé localement, car le sandbox ne fournit pas le SDK
Android/JDK 17 ; sa configuration et le `prebuild` ont été validés. Les deux jobs doivent
donc encore être confirmés par un premier run GitHub Actions.

## 3. Correctifs apportés pendant l'audit

1. Ajout de `apps/desktop/build/icon.png` (1024 × 1024), qui bloquait initialement
   `npm test` et le packaging.
2. Mise à niveau d'`electron-builder` de 25.1.8 vers **26.15.3**. La 25.1.8 échouait
   dans ce monorepo npm avec `app-builder ENOENT`; la 26.15.3 détecte correctement la
   racine du workspace et package l'application.
3. Ajout d'un lockfile mobile dédié (`apps/mobile/package-lock.json`) pour rendre le job
   Android reproductible.
4. Correction de la configuration Expo Android : le champ invalide
   `android.usesCleartextTraffic` passe maintenant par `expo-build-properties`.
5. Alignement d'`expo-image-picker` et ajout d'`expo-system-ui`; Expo Doctor passe à
   17/17.
6. Extension du CI existant : `check:packaging`, `test:hash` et `test:receive` sont
   désormais exécutés. Auparavant, le job de test n'exécutait que 22 des 37 tests.
7. Mise à jour des versions d'actions GitHub et des comptes de tests dans les workflows
   et le README.

## 4. Nouveau workflow de packaging

Le fichier `.github/workflows/package.yml` :

- se déclenche manuellement ou sur un tag `v*` ;
- rejoue les 37 tests et les deux builds de contrôle ;
- construit sous Windows l'installateur NSIS et l'exécutable portable ;
- installe Node 20, Java 17 et Android SDK 34 pour le mobile ;
- exécute Expo Prebuild puis `./gradlew assembleRelease` ;
- vérifie la présence des fichiers, calcule leur SHA-256 et teste la structure ZIP de
  l'APK ;
- publie séparément les artefacts `castflow-windows-*` et `castflow-android-*` pendant
  30 jours.

## 5. Points faibles restants

### Priorité haute

#### 5.1 Transport local non chiffré

HTTP et WebSocket sont en clair, le PIN est inclus dans le QR et l'empreinte annoncée
n'est pas réellement épinglée. Un appareil présent sur le LAN peut observer ou modifier
le trafic. La documentation mentionne TLS auto-signé, mais il n'est pas implémenté.

**Action recommandée :** TLS local avec certificat par appareil, épinglage de
l'empreinte issue du QR et suppression du PIN de l'URL une fois un canal authentifié
établi.

#### 5.2 Modèle de confiance usurpable

Après une authentification PIN réussie, le serveur fait confiance à une simple chaîne
`fingerprint` fournie par le client. Un autre client peut déclarer la même valeur et
sauter le PIN tant que le processus desktop reste ouvert. Il n'y a aucune preuve de
possession de clé.

**Action recommandée :** identité asymétrique persistée et challenge signé. En attendant,
désactiver le contournement du PIN par `fingerprint`.

#### 5.3 API de transfert insuffisamment protégée

- `GET /offer/:transferId` renvoie les jetons sans authentification HTTP ;
- `POST /cancel/:transferId` ne demande aucun jeton ;
- les offres et jetons sont diffusés à tous les clients WebSocket authentifiés ;
- `tokenTtlMs` est déclaré mais jamais appliqué ; les jetons ne sont ni expirés ni
  réellement à usage unique.

**Action recommandée :** jeton de session obligatoire sur toutes les routes, destinataire
explicite de l'offre, expiration effective et révocation après transfert.

#### 5.4 Reprise native mobile incorrecte

Les tests e2e injectent `readBody(file, offset)` et valident donc une vraie tranche du
fichier. En production, `expo-file-system.createUploadTask` renvoie le fichier entier,
même quand l'en-tête `X-Offset` est non nul. Après une coupure, le serveur risque alors
de recevoir `offset + taille complète` et de répondre `413 TOO_LARGE`.

**Action recommandée :** envoyer un fichier temporaire tronqué à partir de l'offset, ou
implémenter un upload par chunks natifs. Ajouter un test sur appareil Android réel.

#### 5.5 Dette de dépendances mobile

Expo SDK 51 / React Native 0.74 est ancien. L'audit npm mobile remonte 31 alertes, dont
une critique dans `tar` et de nombreuses alertes hautes dans la chaîne Expo/Metro/CLI.
Une partie concerne l'outillage de build plutôt que le code embarqué, mais cela reste un
risque de supply chain pour la CI.

**Action recommandée :** migration progressive vers un SDK Expo maintenu, en suivant
les versions recommandées par `expo install`, puis nouvel audit et tests sur appareil.

#### 5.6 Binaires non signés pour la production

Les `.exe` n'ont pas de certificat Authenticode. Le projet Android généré signe la
release avec la clé debug Expo/React Native. L'APK est installable mais impropre à une
publication Play Store ou à des mises à jour durables.

**Action recommandée :** secrets GitHub pour certificat Windows et keystore Android,
signature dans la CI, protection des environnements de release et rotation documentée.

### Priorité moyenne

1. **Absence de quotas :** pas de limite forte sur le nombre de fichiers, la taille du
   manifeste, le nombre de transferts ou le payload WebSocket. Un pair authentifié peut
   épuiser mémoire ou disque.
2. **Validation `Range` incomplète :** les bornes invalides ou hors fichier ne produisent
   pas proprement `416 Range Not Satisfiable`.
3. **Collision concurrente :** `uniquePath()` effectue un test puis un renommage non
   atomique. Deux fichiers simultanés portant le même nom peuvent entrer en course.
4. **Hash mobile sortant absent :** l'UI mobile ne calcule pas `f.hash` avant l'envoi ;
   l'intégrité mobile → desktop reste donc facultative malgré la documentation.
5. **Hash reçu peu scalable :** Android relit tout le fichier en base64 pour vérifier
   FNV-1a, ce qui peut doubler ou tripler la mémoire sur les gros fichiers.
6. **Serveur sur toutes les interfaces :** les services écoutent `0.0.0.0`, contrairement
   à l'affirmation « interface locale uniquement ». La portée dépend donc du pare-feu et
   du routage de la machine.
7. **Sessions non nettoyées :** transferts, jetons et fichiers `.cfpart` n'ont pas de
   politique d'expiration/nettoyage robuste.
8. **Découverte mobile absente :** le client React Native ne fait pas de broadcast UDP ;
   QR et saisie IP fonctionnent, mais la découverte automatique annoncée n'est pas
   disponible côté mobile.
9. **Persistance partielle :** réglages desktop et liste des appareils de confiance ne
   survivent pas au redémarrage, contrairement à certaines formulations de la
   documentation.

### Couverture de tests encore manquante

- démarrage réel de l'application Electron packagée ;
- rendu/interactions React desktop et React Native ;
- API natives Android sur appareil ou émulateur (caméra, upload repris, stockage) ;
- installation et lancement des `.exe`/`.apk` produits ;
- tests de charge, disque plein, très gros manifestes et plages HTTP invalides ;
- tests de sécurité MITM, rejeu de jeton et usurpation de fingerprint.

## 6. Ordre de traitement conseillé

1. Exécuter manuellement le nouveau workflow et installer les deux artefacts sur Windows
   et Android.
2. Corriger la reprise native mobile et ajouter un test Android instrumenté.
3. Fermer les routes HTTP, appliquer TTL/révocation et cibler les offres par pair.
4. Migrer Expo/React Native et résorber les 31 alertes mobiles.
5. Ajouter TLS + identité cryptographique réelle.
6. Configurer les signatures de production et faire publier les artefacts signés par le
   workflow de release.
