# Scan Cleaner

Petit outil local (Flask) qui retire automatiquement l'arrière-plan photographié
autour des pages scannées à la main (bureau, table, poussière, reliure visible)
et ne garde que la page.

## Principe

Pour chaque image, l'outil cherche le plus grand rectangle clair (la page)
dans la photo, le redresse par transformation de perspective (corrige aussi
une prise de vue légèrement de travers) puis le recadre. Si aucune zone
fiable n'est détectée, l'image d'origine est renvoyée inchangée plutôt que de
risquer un recadrage aberrant.

## Installation

```bash
cd tools/scan_cleaner
python3 -m venv venv        # optionnel mais recommandé
source venv/bin/activate    # Windows : venv\Scripts\activate
pip install -r requirements.txt
```

## Lancement

```bash
python app.py
```

Le serveur écoute par défaut sur toutes les interfaces réseau (`0.0.0.0`), donc
accessible depuis n'importe quel appareil de ton réseau local, pas seulement
depuis la machine qui l'exécute :

- Sur la machine qui exécute le serveur : http://127.0.0.1:5050
- Depuis un autre appareil du même réseau : http://IP_DE_LA_MACHINE:5050
  (trouve l'IP avec `hostname -I` ou `ip a` sur la machine qui exécute `app.py`)

Aucune authentification n'est mise en place : n'expose ce port qu'à un réseau
local de confiance, jamais directement sur Internet. Pour restreindre l'accès
à la seule machine locale, relance avec `SCAN_CLEANER_HOST=127.0.0.1 python app.py`.

## Utilisation

1. Glisser-déposer un ou plusieurs fichiers `.cbz` et/ou des images
   (`.jpg`, `.png`, `.webp`, `.bmp`).
2. Cliquer sur **Nettoyer**. Un aperçu avant/après s'affiche pour toutes les
   pages traitées (un onglet par `.cbz` si plusieurs sont déposés).
3. Si une page est mal détectée, cliquer sur **Corriger manuellement** sous
   sa vignette : trace un rectangle approximatif autour de la page à garder
   sur la photo d'origine, puis valide. Pas besoin d'être précis — le
   rectangle sert juste à écarter le fond, la détection automatique affine
   ensuite à l'intérieur si elle trouve un contour net.
4. Cliquer sur **Télécharger le résultat (.zip)** : le zip contient, pour
   chaque `.cbz` fourni, une version `*_clean.cbz` avec les pages nettoyées,
   et pour chaque image fournie, sa version `*_clean.jpg`.

### Traitement 100% automatique

Coche **Traitement 100% automatique** avant de cliquer sur **Nettoyer** si
chacune de tes photos contient toujours 2 emplacements de page (ton flux de
prise de vue habituel — même quand un côté n'est qu'une couverture noire) :
chaque photo est recadrée puis systématiquement découpée en 2, sans que tu
aies à cliquer quoi que ce soit page par page.

Quand une photo ne se découpe pas automatiquement, elle est marquée
**⚠️ à vérifier** (bordure orange) plutôt que traitée à l'aveugle : c'est en
général le signe qu'une moitié (souvent une couverture sombre) n'a pas été
détectée. Ne traite que ces pages-là avec **Corriger manuellement** puis
**Couper les pages en 2…**, pas besoin de relire tout le volume.

Limite connue de la détection couleur seule : une couverture sombre posée
sur un bureau lui-même sombre et peu coloré — les deux se ressemblent trop
pour être distingués par la couleur. Voir la section SAM ci-dessous pour
combler ce trou sur une machine avec GPU.

### Secours par IA (SAM), sur une machine avec GPU

Sur une machine avec une carte graphique NVIDIA (ex. le PC qui héberge
scan_cleaner lui-même), tu peux activer SAM comme secours automatique :
quand une photo ne donne pas un aspect de double page en couleur, SAM est
retenté avant d'abandonner et de marquer la page ⚠️ — il segmente par
forme/contour, pas par couleur, donc réussit souvent là où l'heuristique
couleur échoue (couverture sombre sur bureau sombre).

```bash
pip install sam2   # ou : pip install "git+https://github.com/facebookresearch/sam2.git"

export SCAN_CLEANER_SAM=sam2
export SCAN_CLEANER_SAM_MODEL=facebook/sam2.1-hiera-large   # défaut si omis
python app.py
```

Le bandeau sous la case "Traitement 100% automatique" indique si SAM est
actif. Sans ces variables d'environnement (ou sans GPU/`sam2` installé),
scan_cleaner continue de fonctionner exactement comme avant — SAM est
entièrement optionnel.

Pour utiliser SAM 1 à la place (package `segment-anything`, plus ancien) :

```bash
export SCAN_CLEANER_SAM=sam1
export SCAN_CLEANER_SAM_MODEL=vit_h
export SCAN_CLEANER_SAM_CHECKPOINT=/chemin/vers/sam_vit_h_4b8939.pth
```

### Découper les doubles pages

Si le CBZ contient des photos de double page (livre ouvert), clique sur
**Couper les pages en 2…** au lieu de télécharger directement :

1. Pour chaque page à séparer, clique 2 points le long de la reliure (un en
   haut, un en bas — pas besoin d'être exactement dessus), puis **Diviser en
   2**. La page devient deux pages (droite / gauche), affichées à la place
   de l'originale. Les pages qu'on ne touche pas restent inchangées.
2. Choisis le **sens de lecture** (japonais = droite à gauche par défaut,
   ou occidental = gauche à droite) : il détermine l'ordre final entre
   chaque paire droite/gauche issue d'une découpe.
3. Clique **Terminer et télécharger** : toutes les pages du `.cbz` sont
   renumérotées dans l'ordre final (`0001.jpg`, `0002.jpg`, ...) pour que
   n'importe quel lecteur les affiche dans le bon ordre, puis le zip se
   télécharge.

## Utilisation en ligne de commande (sans UI)

Le cœur du traitement (`cleaner.py`) est indépendant de Flask et réutilisable :

```python
from cleaner import clean_image_bytes

with open("page.jpg", "rb") as f:
    data = f.read()

cleaned_bytes, method, confidence = clean_image_bytes(data)
with open("page_clean.jpg", "wb") as f:
    f.write(cleaned_bytes)
```

## Limites connues

- Fonctionne mieux quand la page est clairement plus claire que le fond
  (bureau en bois, tissu ou surface sombre). Un fond blanc/très clair sous
  la page peut faire échouer la détection.
- Une double page (livre ouvert) est traitée comme un seul bloc : la
  reliure au centre reste visible, ce qui est normal.
