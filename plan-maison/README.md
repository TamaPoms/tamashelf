# Plan de maison

Petite appli autonome (un seul fichier `index.html`, aucune dépendance à installer)
pour dessiner les niveaux d'une maison et y placer ses meubles.

- **Niveaux** : rez-de-chaussée, étage, combles… avec le niveau du dessous en
  pointillés pour aligner l'escalier.
- **Pièces de toutes formes** : rectangle, en L, en T, en U, ou forme libre en
  déplaçant les coins (ronds) et en ajoutant des coins (+ au milieu d'un mur) ;
  la longueur de chaque mur se règle dans le panneau.
- **Éléments** : pièces, escaliers (nombre de marches, sens de montée), portes (simples ou doubles, pour un placard),
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

## Vue 3D

Le bouton **3D** construit la maison en volume à partir du plan :

- **Vue d'ensemble** : maquette qu'on fait tourner (niveau affiché et ceux du dessous).
  Un clic sur un meuble affiche sa photo et ses dimensions ; un double-clic sur le sol
  y dépose le promeneur.
- **Se promener** : à hauteur d'yeux. `Z Q S D` (ou `W A S D`) et les flèches pour marcher,
  `Maj` pour courir, glisser pour regarder. Sur téléphone : pouce gauche pour avancer,
  glisser à droite pour regarder. Les murs arrêtent le promeneur, les portes laissent passer,
  et les escaliers mènent au niveau du dessus.

Les murs sont générés autour de chaque pièce ; une porte ou une fenêtre posée sur un mur
y découpe une ouverture. La photo d'un meuble est plaquée sur sa face avant (le trait épais
sur le plan). La 3D utilise three.js, chargé depuis un CDN à la première ouverture.
