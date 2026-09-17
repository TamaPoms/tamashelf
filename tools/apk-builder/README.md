# TamaShelf — Outil de build APK

Outil graphique (Windows) qui construit l'appli Android TamaShelf à partir de
l'archive `tamashelf-flutter.tar.gz`, sans rien avoir à extraire ou configurer
à la main.

## Utilisation

1. **Double-clique sur `lancer.bat`.**
   - Si Python n'est pas installé, le script te guide vers
     https://www.python.org/downloads/ (coche bien l'option d'installation
     "tcl/tk", cochée par défaut).
2. Dans la fenêtre qui s'ouvre, clique sur **"Choisir tamashelf-flutter.tar.gz..."**
   et sélectionne le fichier archive tel qu'il t'a été fourni (pas besoin de
   l'extraire toi-même — l'outil s'en charge).
3. Clique sur **"Vérifier l'environnement"** pour t'assurer que Flutter et
   Android SDK sont bien installés et détectés (voir "Prérequis" ci-dessous).
4. Vérifie/modifie le numéro de **version** (format obligatoire `X.Y.Z`, par
   exemple `1.2.0` — utiliser une date sous la forme `2026.09.02` fonctionne
   aussi, mais **pas** `20260902` qui n'a qu'un seul nombre).
5. Clique sur **"Construire l'APK"**. Ça peut prendre plusieurs minutes la
   première fois (téléchargement de dépendances Flutter).
6. Une fois le build terminé, renseigne un **jeton d'accès personnel GitHub**
   (voir "Créer un jeton GitHub" ci-dessous) et clique sur **"Publier le
   dernier APK construit"** : l'outil crée une release GitHub taguée
   `vX.Y.Z` sur le dépôt indiqué et y attache le fichier `tamashelf.apk`.
   Comme c'est la release la plus récente, elle devient automatiquement la
   "latest" — le site (lien "App Android") et l'appli Android elle-même (qui
   vérifie au démarrage s'il existe une version plus récente) la proposeront
   alors au téléchargement, sans rien avoir à déployer sur le serveur
   TamaShelf.

## Créer un jeton GitHub

1. Va sur https://github.com/settings/tokens?type=beta ("Fine-grained tokens").
2. **Generate new token**, donne-lui un nom, une expiration.
3. **Repository access** → "Only select repositories" → choisis `tamashelf`.
4. **Permissions** → **Repository permissions** → **Contents** → **Read and
   write** (c'est ce qui autorise la création de releases et l'upload
   d'assets).
5. Génère le jeton et colle-le dans le champ "Jeton d'accès GitHub" de
   l'outil — il n'est **jamais** sauvegardé sur le disque, il faut le
   recoller à chaque lancement de l'outil (seul le nom du dépôt est
   mémorisé, pour te faire gagner du temps la prochaine fois).

## Ce que fait exactement l'outil (transparence)

- Il extrait l'archive `.tar.gz` que tu lui donnes dans un dossier de travail
  à lui (`projet_extrait/`, à côté de l'outil) — ce dossier est vidé et
  recréé à chaque fois que tu choisis une nouvelle archive.
- Il ne touche à rien d'autre sur ton ordinateur.
- Il modifie uniquement la ligne `version:` du fichier `pubspec.yaml` du
  projet extrait.
- Il lance les commandes standard `flutter pub get` et
  `flutter build apk --release` (les mêmes que tu lancerais toi-même en ligne
  de commande).
- La publication crée (ou réutilise si elle existe déjà) une release GitHub
  taguée `v<version>` sur le dépôt indiqué, et y attache `tamashelf.apk` (en
  remplaçant l'ancien fichier du même nom s'il y en avait un) via l'API
  REST de GitHub, en HTTPS, avec le jeton fourni.
- Ton jeton GitHub n'est **jamais** sauvegardé sur le disque (seul le nom du
  dépôt owner/repo est mémorisé, pour te faire gagner du temps la prochaine
  fois).

## Prérequis

- **Flutter SDK** installé et dans le PATH (https://flutter.dev) — c'est ce
  qui fournit la commande `flutter`.
- **Android SDK** (installé automatiquement avec Android Studio).
- **Python 3** avec Tkinter (coché par défaut à l'installation sur Windows).
- Pour la publication : un jeton d'accès GitHub avec accès en écriture au
  dépôt (voir "Créer un jeton GitHub" ci-dessus). Pas nécessaire pour
  juste construire l'APK localement.

Le bouton "Vérifier l'environnement" lance `flutter doctor`, qui te dira
précisément ce qu'il manque si quelque chose ne va pas.

## Compiler l'outil en .exe (optionnel)

Si tu préfères un simple exécutable `.exe` plutôt que devoir passer par
Python, lance `build_exe.bat` — il installe PyInstaller et produit
`dist\TamaShelfApkBuilder.exe`, un fichier unique que tu peux ensuite
déplacer où tu veux.

## Dépannage

- **"La commande 'flutter' est introuvable"** → Flutter n'est pas installé,
  ou pas dans le PATH. Réinstalle-le en suivant https://flutter.dev/docs/get-started/install
  et redémarre l'ordinateur (ou au moins la session) après l'installation.
- **"Aucun projet Flutter trouvé dans l'archive"** → vérifie que tu as bien
  choisi le fichier `tamashelf-flutter.tar.gz` fourni (pas un autre fichier),
  et qu'il n'est pas corrompu.
- **Erreur "Invalid version number" pendant le build** → le numéro de version
  n'est pas au format `X.Y.Z`. L'outil bloque normalement ce cas avant même
  de lancer le build ; si tu vois quand même cette erreur, vérifie le champ
  "Version".
