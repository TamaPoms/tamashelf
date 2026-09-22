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
