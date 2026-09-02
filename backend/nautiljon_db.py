"""
nautiljon_db.py — Accès DIRECT (lecture + écriture admin) à la "vraie base" Nautiljon
(le fichier SQLite produit par scrapersql.py / scrapersql_linux.py, le même que celui
ouvert par app.py et db_viewer.py), en remplacement de l'ancienne API HTTP séparée
(NAUTILJON_API, ex: http://192.168.1.172:8000) que main.py appelait auparavant.

Pourquoi ce module plutôt que de réécrire tous les appelants de main.py :
Ce module reproduit EXACTEMENT la forme JSON que l'ancienne API renvoyait (mêmes clés :
title, cover_url, synopsis, editions_json avec volumes[].cover_full/cover_mini/number,
etc. -- voir le docstring historique de nautiljon_manga() dans main.py) afin que tout le
code déjà écrit côté backend (parsing de _fetch_and_store_details, auto-matching...),
côté frontend React (App.jsx) et côté appli Flutter continue de fonctionner SANS
modification -- seule la SOURCE des données change (fichier local au lieu d'un appel
réseau vers un service séparé).

Différences volontaires avec l'ancienne API :
- Les URLs d'images ne pointent plus vers nautiljon.com mais vers les fichiers DÉJÀ
  téléchargés localement par scrapersql.py (colonnes image_jpg/image_mini_jpg), servis
  par la route /api/nautiljon/img/<chemin> ajoutée dans main.py.
- Pas de scraping "à la volée" : si une série n'est pas encore en base (pas encore
  scrapée par scrapersql.py), elle est simplement absente des résultats -- il n'y a plus
  de secours web live dans ce conteneur (c'est le sens de "ne garder que l'accès à la
  base").
"""
import json
import os
import re
import sqlite3
import unicodedata
from pathlib import Path
from typing import Optional

try:
    from PIL import Image
except Exception:  # pragma: no cover
    Image = None

# ═══════════════════════════════════════════
#  Config
# ═══════════════════════════════════════════

# Même convention que DB_FILE dans app.py / VRAIE_BASE dans scrapersql.py.
NAUTILJON_DB = Path(os.getenv("NAUTILJON_DB", "/mnt/14To/nautiljon/nautiljon_mangas.db"))

# Préfixe de la route (ajoutée dans main.py) qui sert les images locales déjà
# téléchargées par scrapersql.py -- voir _image_url() plus bas.
IMAGE_ROUTE_PREFIX = "/api/nautiljon/img"


def is_available() -> bool:
    """Le fichier existe et a bien la table 'series' -- utilisé par /api/nautiljon/health
    (remplace l'ancien ping réseau, ici un simple check local, donc quasi instantané)."""
    if not NAUTILJON_DB.is_file():
        return False
    try:
        conn = _connect()
        try:
            row = conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='series'"
            ).fetchone()
            return row is not None
        finally:
            conn.close()
    except sqlite3.DatabaseError:
        return False


def nautiljon_dir() -> Path:
    """Dossier contenant le .db -- racine des chemins d'images relatifs stockés en base
    (ex: colonne image_jpg = '/mangas/image/xxx.jpg' -> fichier réel à
    <nautiljon_dir()>/mangas/image/xxx.jpg), même convention que MANGAS_DIR dans app.py."""
    return NAUTILJON_DB.parent


def _connect() -> sqlite3.Connection:
    """Même tolérance UTF-8 que get_db_connection() dans app.py/db_viewer.py -- certaines
    lignes ont des octets invalides dans infos_brutes (pages mal décodées pendant le
    scraping). timeout généreux car ce fichier est aussi écrit par scrapersql.py,
    potentiellement en même temps depuis un autre PC/processus."""
    conn = sqlite3.connect(str(NAUTILJON_DB), timeout=30.0)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    conn.row_factory = sqlite3.Row
    return conn


def _colonnes(conn: sqlite3.Connection, table: str) -> set:
    try:
        return {r["name"] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()}
    except sqlite3.DatabaseError:
        return set()


def _get(row, cle, defaut=""):
    """Accès défensif à une colonne qui peut ne pas exister sur une base pas encore
    migrée (ex: 'titre_original' ajoutée par _assurer_schema_vraie_base_a_jour() côté
    scrapersql.py) -- évite un KeyError/IndexError sqlite3.Row."""
    try:
        v = row[cle]
        return v if v is not None else defaut
    except (IndexError, KeyError):
        return defaut


def _image_url(chemin_relatif) -> str:
    """Convertit un chemin relatif stocké en base (ex: '/mangas/image/xxx.jpg', déjà avec
    le slash de tête -- convention app.py) en URL absolue servie par main.py. Chaîne vide
    si rien n'est stocké."""
    chemin = (chemin_relatif or "").strip()
    if not chemin:
        return ""
    if not chemin.startswith("/"):
        chemin = "/" + chemin
    return f"{IMAGE_ROUTE_PREFIX}{chemin}"


def _infos_brutes(row) -> dict:
    brut = _get(row, "infos_brutes", "")
    if not brut:
        return {}
    try:
        d = json.loads(brut)
        return d if isinstance(d, dict) else {}
    except (ValueError, TypeError):
        return {}


def _pick(infos: dict, *cles):
    for c in cles:
        v = infos.get(c)
        if v:
            return v
    return None


def _liste_depuis(valeur):
    """'a, b, c' -> ['a','b','c'] (même découpage que _parser_liste dans app.py)."""
    if not valeur:
        return []
    vus, out = set(), []
    for v in str(valeur).replace(";", ",").split(","):
        v = v.strip()
        if v and v.lower() not in vus:
            vus.add(v.lower())
            out.append(v)
    return out


# ═══════════════════════════════════════════
#  Lecture — recherche / liste
# ═══════════════════════════════════════════

def _ligne_vers_item(row, colonnes_series: set) -> dict:
    cover = ""
    if "image_jpg" in colonnes_series and row["image_jpg"]:
        cover = _image_url(row["image_jpg"])
    elif "image" in colonnes_series and row["image"]:
        cover = _image_url(row["image"])
    synopsis = _get(row, "synopsis", "")
    return {
        "url": row["url"],
        "title": row["titre"],
        "titre": row["titre"],
        "cover_url": cover,
        "image_url": cover,
        "synopsis": (synopsis or "")[:200],
    }


def search_local(q: str = "", limit: int = 48, offset: int = 0) -> dict:
    """Recherche dans la base locale par titre/synopsis -- remplace l'ancien endpoint
    /search_local de l'API distante. Renvoie la même forme {results, rows, total}."""
    conn = _connect()
    try:
        colonnes = _colonnes(conn, "series")
        if not colonnes:
            return {"results": [], "rows": [], "total": 0}

        q = (q or "").strip()
        where, params = "", []
        if q:
            clauses = ["titre LIKE ?"]
            params.append(f"%{q}%")
            if "synopsis" in colonnes:
                clauses.append("synopsis LIKE ?")
                params.append(f"%{q}%")
            where = "WHERE " + " OR ".join(clauses)

        total = conn.execute(f"SELECT COUNT(*) FROM series {where}", params).fetchone()[0]
        rows = conn.execute(
            f"SELECT * FROM series {where} ORDER BY titre COLLATE NOCASE LIMIT ? OFFSET ?",
            params + [limit, offset],
        ).fetchall()
        items = [_ligne_vers_item(r, colonnes) for r in rows]
        return {"results": items, "rows": items, "total": total}
    finally:
        conn.close()


def list_series(limit: int = 48, offset: int = 0, search: Optional[str] = None) -> dict:
    """Équivalent de l'ancien endpoint /list (avec filtre 'search' optionnel)."""
    return search_local(search or "", limit=limit, offset=offset)


# ═══════════════════════════════════════════
#  Lecture — détails complets d'une série (équivalent /manga_auto + /manga_editions)
# ═══════════════════════════════════════════

def _volume_vers_dict(row, colonnes_vol: set) -> dict:
    numero = row["numero"] or ""
    titre = row["titre"] or ""
    cover_full = _image_url(row["image_jpg"]) if "image_jpg" in colonnes_vol else ""
    cover_mini = ""
    if "image_mini_jpg" in colonnes_vol and row["image_mini_jpg"]:
        cover_mini = _image_url(row["image_mini_jpg"])
    elif cover_full:
        cover_mini = cover_full
    synopsis = _get(row, "synopsis", "") if "synopsis" in colonnes_vol else ""
    return {
        "id": row["id"],
        "volume_id": row["id"],
        # Alias multiples pour rester compatible avec toutes les lectures existantes
        # côté frontend (App.jsx lit tantôt .number, tantôt .volume_number/.numero).
        "number": numero,
        "numero": numero,
        "volume_number": numero,
        "title": titre,
        "titre": titre,
        "synopsis": synopsis or "",
        "url": _get(row, "url", ""),
        "cover_full": cover_full,
        "cover_mini": cover_mini,
        "cover_url": cover_full,
        "categorie_volume": _get(row, "categorie_volume", ""),
        "is_available": True,
    }


def _editions_pour_serie(conn: sqlite3.Connection, url_serie: str) -> list:
    tables = {r["name"] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    ).fetchall()}
    if "serie_editions_details" not in tables or "serie_volumes" not in tables:
        return []

    colonnes_vol = _colonnes(conn, "serie_volumes")
    editions = []
    for ed_row in conn.execute(
        "SELECT * FROM serie_editions_details WHERE serie_url = ?", (url_serie,)
    ).fetchall():
        vol_rows = conn.execute(
            "SELECT * FROM serie_volumes WHERE edition_id = ? ORDER BY CAST(numero AS REAL), numero",
            (ed_row["id"],),
        ).fetchall()
        volumes = [_volume_vers_dict(v, colonnes_vol) for v in vol_rows]
        nom = ed_row["nom"] or ""
        editions.append({
            "id": ed_row["id"],
            "name": nom,
            "nom": nom,
            "label": nom,
            "statut": _get(ed_row, "statut", ""),
            "volumes": volumes,
        })
    return editions


def manga_auto(url: str) -> Optional[dict]:
    """Détails complets d'une série par son URL nautiljon -- équivalent de l'ancien
    GET {api}/manga_auto?url=... . Renvoie None si la série n'est pas en base locale
    (plus de secours "scraper à la volée" -- voir docstring du module)."""
    if not url:
        return None
    conn = _connect()
    try:
        colonnes = _colonnes(conn, "series")
        if not colonnes:
            return None
        row = conn.execute("SELECT * FROM series WHERE url = ?", (url,)).fetchone()
        if not row:
            return None

        infos = _infos_brutes(row)

        cover_url = ""
        if "image_jpg" in colonnes and row["image_jpg"]:
            cover_url = _image_url(row["image_jpg"])
        elif "image" in colonnes and row["image"]:
            cover_url = _image_url(row["image"])

        editions = _editions_pour_serie(conn, url)

        genres = _liste_depuis(_pick(infos, "Genre", "Genres"))
        themes = _liste_depuis(_pick(infos, "Thème", "Thèmes", "Theme", "Themes"))

        details = {
            "title": row["titre"],
            "url": url,
            "cover_url": cover_url,
            "image_url": cover_url,
            "main_cover_json": {"has_cover": bool(cover_url), "cover_full": cover_url, "cover_mini": cover_url},
            "synopsis": _get(row, "synopsis", ""),
            "description": _get(row, "synopsis", ""),
            "type": _get(row, "type", "") or _pick(infos, "Type") or "",
            "status": _pick(infos, "Statut") or "",
            "country": _get(row, "origine", "") or _pick(infos, "Origine") or "",
            "author": _pick(infos, "Auteur", "Auteurs") or "",
            "artist": _pick(infos, "Dessinateur", "Dessinateurs") or "",
            "publisher": _pick(infos, "Éditeur VF", "Éditeurs VF", "Éditeur VO", "Éditeurs VO") or "",
            "magazine": _pick(infos, "Prépublié dans") or "",
            "year": _get(row, "annee_vf", "") or _get(row, "annee_vo", "") or _pick(infos, "Année VF", "Année VO") or "",
            "volumes_count": _get(row, "nb_volumes_vf", "") or _get(row, "nb_volumes_vo", "") or _pick(infos, "Nb volumes VF", "Nb volumes VO") or "",
            "age_conseille": _get(row, "age_conseille", "") or _pick(infos, "Âge conseillé") or "",
            "alt_title": _get(row, "titre_original", "") or _pick(infos, "Titre original") or "",
            "japanese_title": _get(row, "titre_original", "") or _pick(infos, "Titre original") or "",
            "genres": genres,
            "themes": themes,
            "editions_json": editions,
            "raw_infos_json": infos,
            "has_details": True,
            "scraped": True,
            "source": "local_db",
        }
        return details
    finally:
        conn.close()


def manga_editions(url: str) -> Optional[dict]:
    """Équivalent de l'ancien GET {api}/manga_editions?url=... -- {editions, summary}."""
    details = manga_auto(url)
    if not details:
        return None
    editions = details.get("editions_json") or []
    total_vols = sum(len(ed.get("volumes", [])) for ed in editions)
    total_dispo = sum(1 for ed in editions for v in ed.get("volumes", []) if v.get("is_available", True))
    return {
        "editions": editions,
        "summary": {
            "total_editions": len(editions),
            "total_volumes": total_vols,
            "total_available": total_dispo,
            "total_upcoming": total_vols - total_dispo,
        },
    }


# ═══════════════════════════════════════════
#  Écriture (admin) — créer une série / édition / volume à la main
#  (même logique que nouvelle_serie()/nouveau_volume() dans app.py, adaptée à
#  FastAPI : bytes d'image déjà lus plutôt qu'un FileStorage Flask)
# ═══════════════════════════════════════════

def _slugifier(texte: str) -> str:
    texte = (texte or "").lower().strip()
    texte = unicodedata.normalize("NFKD", texte).encode("ascii", "ignore").decode("ascii")
    texte = re.sub(r"[^a-z0-9]+", "-", texte).strip("-")
    return texte or "sans-titre"


def _extraire_numero_volume(texte: str) -> str:
    if not texte:
        return texte or ""
    m = re.search(r"\d+(?:[.,]\d+)?", str(texte))
    return m.group(0).replace(",", ".") if m else str(texte).strip()


def _generer_url_locale(titre: str, conn: sqlite3.Connection) -> str:
    """Même convention que _generer_url_locale() dans app.py : une URL fictive mais
    unique, au même format que les vraies URLs scrapées, préfixée 'manuel-' pour
    signaler que ce n'est pas une vraie page nautiljon.com."""
    slug = _slugifier(titre)
    url = f"https://www.nautiljon.com/mangas/manuel-{slug}.html"
    compteur = 2
    while conn.execute("SELECT 1 FROM series WHERE url = ?", (url,)).fetchone():
        url = f"https://www.nautiljon.com/mangas/manuel-{slug}-{compteur}.html"
        compteur += 1
    return url


def _get_or_create_lexique(conn: sqlite3.Connection, table: str, nom: str) -> int:
    nom = nom.strip()
    conn.execute(f"INSERT OR IGNORE INTO {table} (nom) VALUES (?)", (nom,))
    return conn.execute(f"SELECT id FROM {table} WHERE nom = ?", (nom,)).fetchone()[0]


def sauver_image(donnees: bytes, dossier: Path, nom_base: str, largeur_max: Optional[int] = None) -> str:
    """Sauvegarde en .jpg des bytes d'image déjà lus (UploadFile.read() côté FastAPI) --
    équivalent de _sauver_image_uploadee() dans app.py mais à partir de bytes bruts
    plutôt que d'un FileStorage Flask. Renvoie le nom du fichier créé, ou '' si rien à
    sauvegarder / image illisible / Pillow indisponible."""
    if not donnees or Image is None:
        return ""
    try:
        dossier.mkdir(parents=True, exist_ok=True)
        import io as _io
        img = Image.open(_io.BytesIO(donnees)).convert("RGB")
        if largeur_max and img.width > largeur_max:
            ratio = largeur_max / img.width
            img = img.resize((largeur_max, max(1, int(img.height * ratio))))
        nom_fichier = f"{nom_base}.jpg"
        img.save(dossier / nom_fichier, "JPEG", quality=90)
        return nom_fichier
    except Exception:
        return ""


def creer_serie(
    titre: str,
    synopsis: str = "",
    type_serie: str = "",
    statut_vo: str = "",
    statut_vf: str = "",
    edition_nom: str = "Édition Standard",
    genres=None,
    themes=None,
    editeurs=None,
    auteurs=None,
    scenaristes=None,
    dessinateurs=None,
    image_bytes: Optional[bytes] = None,
    volumes: Optional[list] = None,
) -> dict:
    """Crée une série manuellement (+ 1 édition + ses volumes éventuels), directement
    dans la vraie base -- même flux que nouvelle_serie() dans app.py. 'volumes' est une
    liste de dicts {numero, titre, synopsis, image_bytes}. Renvoie
    {url, edition_id, nb_volumes}."""
    titre = (titre or "").strip()
    if not titre:
        raise ValueError("Le titre est obligatoire.")

    genres = genres or []
    themes = themes or []
    editeurs = editeurs or []
    auteurs_par_role = {
        "Auteur": auteurs or [],
        "Scénariste": scenaristes or [],
        "Dessinateur": dessinateurs or [],
    }

    conn = _connect()
    try:
        url_serie = _generer_url_locale(titre, conn)
        slug = _slugifier(titre)

        image_jpg, image_mini_jpg = "", ""
        if image_bytes:
            nom = sauver_image(image_bytes, nautiljon_dir() / "mangas" / "image", slug)
            if nom:
                image_jpg = f"/mangas/image/{nom}"
                nom_mini = sauver_image(image_bytes, nautiljon_dir() / "mangas" / "image_mini", slug, largeur_max=300)
                if nom_mini:
                    image_mini_jpg = f"/mangas/image_mini/{nom_mini}"

        infos = {}
        if type_serie: infos["Type"] = type_serie
        if statut_vo: infos["Nb volumes VO"] = statut_vo
        if statut_vf: infos["Nb volumes VF"] = statut_vf
        if genres: infos["Genres"] = ", ".join(genres)
        if themes: infos["Thèmes"] = ", ".join(themes)
        if editeurs: infos["Éditeur VF"] = ", ".join(editeurs)
        for role, noms in auteurs_par_role.items():
            if noms: infos[role] = ", ".join(noms)
        infos_json = json.dumps(infos, ensure_ascii=False)

        colonnes = _colonnes(conn, "series")
        champs = ["url", "titre", "synopsis", "image", "image_mini", "type",
                  "statut_vo", "statut_vf", "infos_brutes", "image_jpg", "image_mini_jpg"]
        valeurs = [url_serie, titre, synopsis, "", "", type_serie, statut_vo, statut_vf,
                   infos_json, image_jpg, image_mini_jpg]
        placeholders = ", ".join("?" * len(champs))
        conn.execute(f"INSERT INTO series ({', '.join(champs)}) VALUES ({placeholders})", valeurs)

        # Lexiques (genres/thèmes/éditeurs/auteurs) — additifs, best-effort : si ces
        # tables n'existent pas encore sur cette base (schéma pas encore migré), on
        # n'échoue pas la création de la série pour autant.
        try:
            for nom in genres:
                gid = _get_or_create_lexique(conn, "genres", nom)
                conn.execute("INSERT OR IGNORE INTO serie_genres (serie_url, genre_id) VALUES (?, ?)", (url_serie, gid))
            for nom in themes:
                tid = _get_or_create_lexique(conn, "themes", nom)
                conn.execute("INSERT OR IGNORE INTO serie_themes (serie_url, theme_id) VALUES (?, ?)", (url_serie, tid))
            for nom in editeurs:
                eid = _get_or_create_lexique(conn, "editeurs", nom)
                conn.execute("INSERT OR IGNORE INTO serie_editeurs (serie_url, editeur_id, pays) VALUES (?, ?, ?)", (url_serie, eid, "VF"))
            for role, noms in auteurs_par_role.items():
                for nom in noms:
                    aid = _get_or_create_lexique(conn, "auteurs", nom)
                    conn.execute("INSERT OR IGNORE INTO serie_auteurs (serie_url, auteur_id, role) VALUES (?, ?, ?)", (url_serie, aid, role))
        except sqlite3.DatabaseError:
            pass

        edition_nom = (edition_nom or "").strip() or "Édition Standard"
        conn.execute("INSERT INTO serie_editions_details (serie_url, nom, statut) VALUES (?, ?, ?)",
                     (url_serie, edition_nom, ""))
        edition_id = conn.execute(
            "SELECT id FROM serie_editions_details WHERE serie_url = ? AND nom = ?",
            (url_serie, edition_nom),
        ).fetchone()[0]

        nb_volumes = 0
        for vol in (volumes or []):
            numero = _extraire_numero_volume((vol.get("numero") or "").strip())
            titre_vol = (vol.get("titre") or "").strip()
            if not numero and not titre_vol:
                continue
            _inserer_volume(conn, edition_id, slug, numero, titre_vol,
                             (vol.get("synopsis") or "").strip(), "", vol.get("image_bytes"))
            nb_volumes += 1

        conn.commit()
        return {"url": url_serie, "edition_id": edition_id, "nb_volumes": nb_volumes}
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _inserer_volume(conn, edition_id, slug_serie, numero, titre_vol, synopsis_vol, url_vol, image_bytes) -> Optional[int]:
    vol_img_jpg, vol_img_mini_jpg = "", ""
    if image_bytes:
        nom_base = f"{slug_serie}-vol-{_slugifier(numero or titre_vol or 'x')}"
        nom = sauver_image(image_bytes, nautiljon_dir() / "manga_volumes" / "image", nom_base)
        if nom:
            vol_img_jpg = f"/manga_volumes/image/{nom}"
            nom_mini = sauver_image(image_bytes, nautiljon_dir() / "manga_volumes" / "image_mini", nom_base, largeur_max=300)
            if nom_mini:
                vol_img_mini_jpg = f"/manga_volumes/image_mini/{nom_mini}"

    colonnes = _colonnes(conn, "serie_volumes")
    champs = ["edition_id", "numero", "titre", "image", "image_mini", "url", "image_jpg", "image_mini_jpg"]
    valeurs = [edition_id, numero, titre_vol, "", "", url_vol, vol_img_jpg, vol_img_mini_jpg]
    if "synopsis" in colonnes:
        champs.append("synopsis")
        valeurs.append(synopsis_vol)
    placeholders = ", ".join("?" * len(champs))
    try:
        cur = conn.execute(f"INSERT INTO serie_volumes ({', '.join(champs)}) VALUES ({placeholders})", valeurs)
        return cur.lastrowid
    except sqlite3.IntegrityError:
        # Même numéro/titre déjà présent dans cette édition (contrainte UNIQUE) — on
        # ignore le doublon plutôt que de faire échouer toute l'opération, comme
        # nouvelle_serie() dans app.py.
        return None


def ajouter_edition(url_serie: str, nom: str, statut: str = "") -> int:
    """Ajoute une nouvelle édition à une série EXISTANTE (ex: 'Édition Deluxe' en plus de
    l'édition standard)."""
    nom = (nom or "").strip()
    if not nom:
        raise ValueError("Le nom de l'édition est obligatoire.")
    conn = _connect()
    try:
        serie = conn.execute("SELECT 1 FROM series WHERE url = ?", (url_serie,)).fetchone()
        if not serie:
            raise ValueError("Série introuvable.")
        conn.execute(
            "INSERT INTO serie_editions_details (serie_url, nom, statut) VALUES (?, ?, ?)",
            (url_serie, nom, statut or ""),
        )
        edition_id = conn.execute(
            "SELECT id FROM serie_editions_details WHERE serie_url = ? AND nom = ?",
            (url_serie, nom),
        ).fetchone()[0]
        conn.commit()
        return edition_id
    except sqlite3.IntegrityError:
        conn.rollback()
        raise ValueError("Une édition avec ce nom existe déjà pour cette série.")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def ajouter_volume(edition_id: int, numero: str = "", titre: str = "", synopsis: str = "",
                    url_vol: str = "", image_bytes: Optional[bytes] = None) -> int:
    """Ajoute UN volume à une édition existante -- même flux que nouveau_volume() dans
    app.py."""
    numero = _extraire_numero_volume((numero or "").strip())
    titre = (titre or "").strip()
    if not numero and not titre:
        raise ValueError("Indique au moins un numéro ou un titre pour le volume.")

    conn = _connect()
    try:
        edition = conn.execute(
            "SELECT * FROM serie_editions_details WHERE id = ?", (edition_id,)
        ).fetchone()
        if not edition:
            raise ValueError("Édition introuvable.")
        serie = conn.execute(
            "SELECT titre FROM series WHERE url = ?", (edition["serie_url"],)
        ).fetchone()
        slug = _slugifier(serie["titre"] if serie else edition["serie_url"])

        vol_id = _inserer_volume(conn, edition_id, slug, numero, titre, synopsis, url_vol, image_bytes)
        if vol_id is None:
            conn.rollback()
            raise ValueError("Un volume avec ce numéro et ce titre existe déjà dans cette édition.")
        conn.commit()
        return vol_id
    except ValueError:
        raise
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
