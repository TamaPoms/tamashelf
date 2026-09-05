# TamaShelf — Bibliothèque manga auto-hébergée

> Alternative Kavita légère pour CBZ avec métadonnées Nautiljon.
> Tourne sur Raspberry Pi, accessible depuis n'importe quel appareil.
> Les métadonnées viennent d'un accès direct (lecture + écriture admin) à la
> vraie base Nautiljon locale (voir `backend/nautiljon_db.py`) — plus d'API
> HTTP séparée à faire tourner à côté.

## Architecture

```
tamashelf/
├── backend/
│   ├── main.py          ← FastAPI + SQLite
│   ├── nautiljon_db.py  ← Accès direct (lecture/écriture) à la base Nautiljon
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
export NAUTILJON_DB=/mnt/14To/nautiljon/nautiljon_mangas.db

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
4. **Admin → Configuration**: vérifier que la base Nautiljon est bien détectée (chemin `NAUTILJON_DB`) et le chemin CBZ
5. **Admin → Utilisateurs**: créer des comptes pour les autres utilisateurs
6. **Admin → Matching auto**: lancer le matching CBZ ↔ Nautiljon
7. **Admin → Créer série**: pour les séries absentes de nautiljon.com, les créer/compléter à la main (série, éditions, volumes) directement dans la base locale

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
- SQLite (léger, parfait pour RPi, pas de serveur DB séparé)
- Accès direct (lecture + écriture admin) à la vraie base Nautiljon locale,
  produite par le scraper — pas de cache nécessaire, la lecture locale est
  déjà quasi instantanée (voir `backend/nautiljon_db.py`)
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
| GET | `/api/nautiljon/list` | Liste mangas (base locale) |
| GET | `/api/nautiljon/manga` | Détails + éditions (base locale, accès direct) |
| GET | `/api/nautiljon/img/{path}` | Sert les couvertures téléchargées par le scraper |
| POST | `/api/admin/nautiljon/serie` | Créer une série + édition + volumes à la main (admin) |
| POST | `/api/admin/nautiljon/edition` | Ajouter une édition à une série existante (admin) |
| POST | `/api/admin/nautiljon/volume` | Ajouter un volume à une édition existante (admin) |
| GET | `/api/progress` | Progression lecture |
| POST | `/api/progress` | Sauver progression |
| GET | `/api/matches` | Associations CBZ |
| GET | `/api/cbz/read/{path}` | Lire une page CBZ |
| GET | `/api/cbz/download/{path}` | Télécharger un CBZ |

## Application Android

Une app Android native (Flutter) existe déjà, voir `../flutter/` — lecteur
hors-ligne qui se connecte à cette même API REST (authentification par token
Bearer, `/api/cbz/read/`, progression synchronisée via `/api/progress`). Elle
n'a volontairement pas de fonction de création manuelle de série : cette
fonctionnalité admin (`/api/admin/nautiljon/*`) est réservée à l'interface web.
