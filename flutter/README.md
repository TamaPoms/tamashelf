# TamaShelf Flutter App

Application mobile hors-ligne pour TamaShelf.

## Architecture

```
flutter/
├── lib/
│   ├── main.dart              # Point d'entrée
│   ├── app_state.dart         # État global (Provider)
│   ├── theme.dart             # Thème Manga Sépia
│   ├── models/
│   │   └── manga.dart         # Modèles: Manga, Volume, ReadingProgress
│   ├── screens/
│   │   ├── setup_screen.dart  # Config serveur + login
│   │   ├── home_screen.dart   # Bibliothèque + grille + recherche
│   │   ├── manga_detail_screen.dart  # Détails manga + tomes
│   │   ├── downloads_screen.dart     # Fichiers téléchargés
│   │   └── reader_screen.dart # Lecteur CBZ (paged/webtoon)
│   └── services/
│       ├── db_service.dart    # SQLite local + sync serveur
│       └── download_service.dart  # Téléchargement + extraction CBZ
└── pubspec.yaml
```

## Fonctionnement hors-ligne

1. **Premier lancement** → Connexion au serveur → Télécharge la BDD SQLite
2. **Bibliothèque** → Affichée depuis la BDD locale (covers en blob)
3. **Lecture** → Télécharge le CBZ → Extraction locale → Lecture hors-ligne
4. **Fin de lecture** → Propose de supprimer le fichier
5. **Mise à jour** → Bouton sync pour mettre à jour la BDD

## Contrôles de lecture

| Action | Effet |
|--------|-------|
| Tap au centre | Affiche/masque les options |
| Tap côté gauche | Page précédente |
| Tap côté droit | Page suivante |
| Swipe gauche | Page suivante |
| Swipe droite | Page précédente |
| Volume - | Page suivante / scroll webtoon |
| Volume + | Page précédente / scroll webtoon |
| Bouton ←→ | Inverser le sens (manga RTL) |
| Slider bas | Navigation rapide |

## Build

### Prérequis
- Flutter SDK 3.16+ (https://flutter.dev)
- Android Studio ou VS Code
- Android SDK

### Instructions

```bash
cd flutter

# Installer les dépendances
flutter pub get

# Lancer sur un device connecté
flutter run

# Build APK release
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

### Configuration Android

Le fichier `android/app/src/main/res/xml/network_security_config.xml` autorise
les connexions HTTP (cleartext) vers le serveur TamaShelf local.

Note technique : l'identité Android de l'appli (applicationId/namespace
`fr.mangashelf.mangashelf`, le dossier de package Kotlin correspondant, et
l'EventChannel `fr.mangashelf/volume_keys`) est volontairement restée
inchangée malgré le renommage MangaShelf → TamaShelf, pour qu'Android
continue de reconnaître les mises à jour comme la même appli -- la renommer
ferait perdre aux utilisateurs déjà installés leurs mangas téléchargés et
leur progression de lecture (stockés dans un dossier propre à l'app, retrouvé
via son applicationId).

Ajouter dans `android/app/src/main/AndroidManifest.xml` dans `<application>` :
```xml
android:networkSecurityConfig="@xml/network_security_config"
android:usesCleartextTraffic="true"
```

Et les permissions :
```xml
<uses-permission android:name="android.permission.INTERNET" />
```

## API serveur utilisée

| Endpoint | Usage |
|----------|-------|
| `POST /api/login` | Authentification |
| `GET /api/export/db` | Télécharge la BDD SQLite complète |
| `GET /api/cbz/download/{path}` | Télécharge un CBZ |

La BDD contient tout le nécessaire : métadonnées, covers (blob), liste des tomes,
nombre de pages. Aucune autre requête API n'est nécessaire pour naviguer.
