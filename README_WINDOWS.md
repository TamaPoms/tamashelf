# TamaShelf sur Windows

> Complément à `README.md` (qui documente le déploiement Raspberry Pi/Linux) --
> ce fichier explique comment lancer TamaShelf directement sur un PC Windows.

Le code (backend FastAPI + frontend React) n'a rien de spécifique à Linux : ça
tourne sur Windows sans modification. Deux façons de faire, du plus simple au
plus manuel.

## Option 1 — Docker Desktop (recommandé)

### Prérequis
- Windows 10/11 avec **Docker Desktop** installé (https://www.docker.com/products/docker-desktop/),
  avec le backend **WSL2** activé (proposé automatiquement à l'installation).
- Un éditeur de texte pour modifier `.env` (Bloc-notes suffit).

### Installation
```powershell
# 1. Récupérer le projet (PowerShell, ou Git Bash si tu préfères)
git clone https://github.com/TamaPoms/tamashelf.git
cd tamashelf

# 2. Créer ta config locale à partir du modèle (jamais commitée dans git)
copy .env.example .env
notepad .env
```

Dans `.env`, remplace les valeurs d'exemple par tes vrais chemins **Windows** et
l'adresse de ton `app.py`/`tamajon.py` (voir plus bas) :
```
DISQUE_1=C:\Mangas
DISQUE_2=D:\AutresMangas
APP_PY_URL=http://192.168.1.XXX:5555
```
(Un seul disque ? Mets la même valeur pour `DISQUE_1` et `DISQUE_2`, ou laisse
`DISQUE_2` pointer vers un dossier vide -- les deux lignes doivent juste être
présentes, `docker-compose.yml` en a besoin.)

```powershell
# 3. Build et lancer
docker compose up -d --build

# 4. Accéder à http://localhost:9999
```

Pour arrêter : `docker compose down`. Pour mettre à jour après un `git pull`,
relance `docker compose up -d --build` (voir `README.md` pour la marche à
suivre complète en cas de conflit git sur `docker-compose.yml`).

## Option 2 — Sans Docker, directement sur Windows

### Prérequis
- **Python 3.11+** (https://www.python.org/downloads/, cocher "Add python.exe to PATH" à l'installation)
- **Node.js 20+** (https://nodejs.org/)

### Installation
```powershell
git clone https://github.com/TamaPoms/tamashelf.git
cd tamashelf

# Backend
cd backend
pip install -r requirements.txt

# Variables d'environnement pour cette session PowerShell (à refaire à chaque
# ouverture d'un nouveau terminal, ou à mettre dans un script .ps1/.bat)
$env:TAMASHELF_DATA = ".\data"
$env:TAMASHELF_STATIC = "..\frontend\dist"
$env:APP_PY_URL = "http://192.168.1.XXX:5555"

# Frontend
cd ..\frontend
npm install
npm run build

# Lancer le serveur
cd ..\backend
uvicorn main:app --host 0.0.0.0 --port 9999
```

Accéder ensuite à http://localhost:9999.

## Important : `app.py` / `tamajon.py` reste un composant à part

TamaShelf ne touche jamais directement le fichier `nautiljon_mangas.db`, ni
même le dossier qui le contient -- il passe toujours par l'API de `app.py`
(aussi appelé `tamajon.py`), le seul processus autorisé à ouvrir cette base,
aussi bien pour chercher les infos d'une série que pour récupérer ses
jaquettes. Comme TamaShelf n'a donc besoin d'aucun accès disque à ce dossier
(juste de joindre `app.py` sur le réseau), il peut tourner sur n'importe
quelle machine -- Windows ou non, même si elle ne partage aucun disque avec
celle qui fait tourner `tamajon.py`. Que TamaShelf tourne sur Windows ou non,
il faut donc juste que `tamajon.py` tourne **quelque part** (même machine
Windows, ou une autre machine du réseau local) et que `APP_PY_URL` dans `.env`
pointe vers son adresse.

`tamajon.py` lui-même tourne aussi bien sur Windows que sur Linux (c'est du
Python pur), mais il exige désormais que tu définisses **toi-même** ses
identifiants admin via deux variables d'environnement avant de le lancer --
il refuse de démarrer sinon (plus d'identifiants codés en dur par défaut) :
```powershell
$env:TAMAJON_ADMIN_USER = "tonNom"
$env:TAMAJON_ADMIN_PASS = "tonMotDePasse"
python tamajon.py
```

## Premier lancement

Identique à la version Linux (voir `README.md` § "Premier lancement") :
ouvrir `http://localhost:9999`, créer le compte admin, indiquer le chemin des
CBZ, puis lancer le matching automatique depuis l'admin.

## Limitation connue : conversion CBR → CBZ

Cette fonctionnalité (convertir un vieux `.cbr` en `.cbz`) appelle en coulisses
deux outils en ligne de commande, `7z` et `zip`, absents de Windows par
défaut :
- Installe **7-Zip** (https://www.7-zip.org/) puis pointe dessus :
  `$env:SEVEN_Z_BIN = "C:\Program Files\7-Zip\7z.exe"`
- `zip` n'a pas d'équivalent officiel sur Windows -- sans lui, la conversion
  CBR→CBZ échoue avec un message d'erreur clair (rien d'autre n'est affecté :
  parcourir/lire les `.cbz` déjà au bon format fonctionne normalement, sans
  dépendre d'aucun outil externe).

Si tu n'as pas de fichiers `.cbr` à convertir, tu peux ignorer cette section.
