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

Puis ouvrir http://127.0.0.1:5050 dans un navigateur.

## Utilisation

1. Glisser-déposer un ou plusieurs fichiers `.cbz` et/ou des images
   (`.jpg`, `.png`, `.webp`, `.bmp`).
2. Cliquer sur **Nettoyer**. Un aperçu avant/après s'affiche pour les
   premières pages traitées.
3. Cliquer sur **Télécharger le résultat (.zip)** : le zip contient, pour
   chaque `.cbz` fourni, une version `*_clean.cbz` avec les pages nettoyées,
   et pour chaque image fournie, sa version `*_clean.jpg`.

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
