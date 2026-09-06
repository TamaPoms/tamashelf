# TamaShelf — Bibliothèque manga auto-hébergée

> Alternative Kavita légère pour CBZ avec métadonnées Nautiljon.
> Tourne sur Raspberry Pi, accessible depuis n'importe quel appareil.
> Les métadonnées (recherche, détails, jaquettes) viennent de l'API HTTP
> publique de `app.py`/`tamajon.py` (voir `backend/nautiljon_db.py`), le seul
> processus autorisé à ouvrir `nautiljon_mangas.db`. TamaShelf n'a donc besoin
> d'aucun accès disque à ce fichier ni au dossier qui le contient, seulement de
> pouvoir joindre `app.py` sur le réseau (`APP_PY_URL`).

## Architecture

```
tamashelf/
├── backend/
│   ├── main.py          ← FastAPI + SQLite
│   ├── nautiljon_db.py  ← Client HTTP vers l'API publique de app.py (métadonnées + images)
│   └── requirements.txt
├── frontend/
│   ├── src/
│   │   ├── main.jsx     ← Entry point React
│   │   ├── App.jsx      ← App principale
│   │   ├── api.js       ← Client API
│   │   └── index.css    ← Styles
│   ├── index.html
│   ├── vite.config.js
│   └── package.json
├── Dockerfile           ← Multi-stage build
├── docker-compose.yml   ← Déploiement
└── README.md
```

## Déploiement sur Raspberry Pi

### Prérequis
- Raspberry Pi 3/4/5 avec Raspberry Pi OS
- Docker + Docker Compose installés

### Installation Docker (si pas déjà fait)
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Redémarrer la session
```

### Déployer TamaShelf
```bash
# 1. Cloner/copier le projet sur le Pi
scp -r tamashelf/ pi@<IP_DU_PI>:~/tamashelf/

# 2. Sur le Pi
cd ~/tamashelf

# 3. Créer ta config locale à partir du modèle (jamais commitée dans git, voir
#    .env.example / .gitignore) : chemins réels de tes disques + IP de app.py
cp .env.example .env
nano .env

# 4. Build et lancer
docker compose up -d --build

# 5. Accéder à http://<IP_DU_PI>:9999
```

### Sans Docker (directement sur le Pi)
```bash
# Backend
cd backend
pip install -r requirements.txt
export TAMASHELF_DATA=./data
export TAMASHELF_STATIC=../frontend/dist
export APP_PY_URL=http://192.168.1.XXX:5555

# Frontend
cd ../frontend
npm install
npm run build

# Lancer
cd ../backend
uvicorn main:app --host 0.0.0.0 --port 9999
```

## Premier lancement

1. Ouvrir `http://<IP_DU_PI>:9999`
2. **Setup**: créer le compte admin + indiquer le chemin CBZ
3. Se connecter avec le compte admin
4. **Admin → Configuration**: vérifier que la base Nautiljon est bien détectée (via `app.py`, adresse `APP_PY_URL`) et le chemin CBZ
5. **Admin → Utilisateurs**: créer des comptes pour les autres utilisateurs
6. **Admin → Matching auto**: lancer le matching CBZ ↔ Nautiljon

Pour les séries absentes de nautiljon.com, elles se créent/complètent désormais
directement dans l'admin de `app.py`/`tamajon.py` (TamaShelf ne fait plus que
lire ces données, il ne les modifie plus).

## Fonctionnalités

### Système d'authentification
- **Admin**: gère tout (utilisateurs, config, matching)
- **Utilisateur**: lit, parcourt la bibliothèque, progression sauvegardée

### Permissions par utilisateur
| Permission | Description |
|---|---|
| Lecture seule | Peut lire mais pas modifier les associations CBZ |
| Téléchargement CBZ | Bouton de téléchargement sur les volumes |
| Changer mot de passe | Peut modifier son propre mot de passe |

### Lecteur CBZ intégré
- Navigation clavier (←→, Espace, Escape)
- Zoom (+/-/0)
- Miniatures cliquables
- Sauvegarde automatique de la progression

### Matching CBZ ↔ Nautiljon
1. **Automatique** (admin): match tous les mangas par titre
2. **Suggestion**: à l'ouverture d'un manga, propose le nom de dossier
3. **Confirmation**: l'utilisateur accepte ou cherche manuellement
4. **Saisie directe**: taper le nom du dossier CBZ

### Base de données
- SQLite (léger, parfait pour RPi, pas de serveur DB séparé) pour les comptes,
  permissions, associations CBZ et progression de TamaShelf lui-même
- Métadonnées Nautiljon (recherche, détails, jaquettes) lues en lecture seule
  via l'API HTTP publique de `app.py`/`tamajon.py` (voir `backend/nautiljon_db.py`)
  — TamaShelf n'ouvre jamais `nautiljon_mangas.db` ni le dossier qui le
  contient
- Progression par utilisateur
- Sessions avec tokens (30 jours)

## Accès depuis l'extérieur

### Avec Tailscale (recommandé)
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# Accéder via l'IP Tailscale depuis n'importe où
```

### Avec un reverse proxy (Caddy)
```
tamashelf.mondomaine.fr {
    reverse_proxy localhost:9999
}
```

## API Endpoints

| Méthode | Route | Description |
|---|---|---|
| GET | `/api/setup-status` | Vérifie si le setup est fait |
| POST | `/api/setup` | Setup initial (admin) |
| POST | `/api/login` | Connexion |
| GET | `/api/me` | Utilisateur courant |
| GET | `/api/admin/users` | Liste utilisateurs (admin) |
| POST | `/api/admin/users` | Créer utilisateur (admin) |
| PUT | `/api/admin/config` | Modifier config (admin) |
| POST | `/api/admin/auto-match` | Matching auto (admin) |
| GET | `/api/nautiljon/list` | Liste mangas (via l'API de app.py) |
| GET | `/api/nautiljon/manga` | Détails + éditions (via l'API de app.py) |
| GET | `/api/nautiljon/img/{path}` | Sert les jaquettes en proxy depuis app.py |
| GET | `/api/progress` | Progression lecture |
| POST | `/api/progress` | Sauver progression |
| GET | `/api/matches` | Associations CBZ |
| GET | `/api/cbz/read/{path}` | Lire une page CBZ |
| GET | `/api/cbz/download/{path}` | Télécharger un CBZ |

## Application Android

Une app Android native (Flutter) existe déjà, voir `../flutter/` — lecteur
hors-ligne qui se connecte à cette même API REST (authentification par token
Bearer, `/api/cbz/read/`, progression synchronisée via `/api/progress`).

L'APK se télécharge uniquement via les [GitHub Releases](https://github.com/TamaPoms/tamashelf/releases/latest)
du projet (lien affiché dans TamaShelf, section "App Android") — il n'y a plus
d'upload/téléchargement de l'APK depuis le site lui-même. Pour publier une
nouvelle version : créer une release sur GitHub avec un fichier joint nommé
exactement `tamashelf.apk` (le lien utilisé est l'URL stable
`.../releases/latest/download/tamashelf.apk`, qui ne change jamais tant que ce
nom de fichier reste identique d'une release à l'autre).
