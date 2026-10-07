# Plan de maison

Petite appli autonome (un seul fichier `index.html`, aucune dépendance à installer)
pour dessiner les niveaux d'une maison et y placer ses meubles.

- **Niveaux** : rez-de-chaussée, étage, combles… avec le niveau du dessous en
  pointillés pour aligner l'escalier.
- **Éléments** : pièces, escaliers (nombre de marches, sens de montée), portes,
  fenêtres, meubles (catalogue de tailles courantes ou meuble libre).
- **Tailles** : largeur, profondeur/longueur, hauteur en cm, réglables au clavier
  dans le panneau ou à la souris/au doigt avec les poignées ; rotation libre
  (aimantée tous les 15°, `Maj` pour la désactiver).
- **Photos** : sur un meuble (ou une pièce), touchez la zone photo, glissez une
  image dessus ou collez-la. La photo s'affiche sur le meuble dans le plan.
- Déplacer une pièce emporte les meubles qui sont dedans (désactivable).
- Annuler / rétablir, export et import du plan en `.json` (photos comprises).

Le plan est enregistré automatiquement dans le navigateur (IndexedDB).
Pour le transférer sur un autre appareil : *Options › Exporter*, puis *Importer*.

Ouvrir `index.html` dans un navigateur suffit. On peut aussi le servir avec
n'importe quel serveur statique, par exemple `python3 -m http.server` dans ce dossier.
