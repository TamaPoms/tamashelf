"""
nautiljon_db.py — Accès à la "vraie base" Nautiljon (le fichier SQLite produit par
scrapersql.py / scrapersql_linux.py) via l'API JSON de app.py (port 5555), qui est
désormais le SEUL process autorisé à ouvrir nautiljon_mangas.db en lecture/écriture.

Pourquoi ce changement (2026-09) : ce module ouvrait auparavant le fichier .db en
direct (sqlite3.connect), exactement comme app.py et scrapersql.py -- plusieurs process
(potentiellement sur plusieurs PC via le lecteur réseau) écrivant/lisant le même fichier
SQLite en même temps, sans coordination. C'est ce qui a provoqué une corruption réelle de
la base ("database disk image is malformed"). La correction : centraliser tout accès
DIRECT au fichier dans app.py, et faire de ce module un simple CLIENT HTTP de app.py pour
tout ce qui touche la base (recherche/matching, détails d'une série). scrapersql.py garde
pour l'instant son accès direct (protégé par la répartition par hash entre PC, donc pas
de risque de collision) -- ce n'est pas encore dans le périmètre de cette centralisation.

La création manuelle de série/édition/volume absente de nautiljon.com se fait désormais
directement depuis l'admin de app.py (tamajon.py) -- ce module n'a plus besoin d'écrire
dans la base, seulement d'y lire (recherche + détails), donc plus aucun identifiant admin
n'est nécessaire côté TamaShelf (les deux routes utilisées sont volontairement publiques).

Ce module continue de reproduire EXACTEMENT la forme JSON que l'ancien accès direct (et,
avant lui, l'ancienne API HTTP séparée) renvoyait (mêmes clés : title, cover_url,
synopsis, editions_json avec volumes[].cover_full/cover_mini/number, etc.) afin que tout
le code déjà écrit côté backend (main.py), frontend React (App.jsx) et appli Flutter
continue de fonctionner SANS modification -- seule la SOURCE des données change (appel
HTTP à app.py au lieu d'un accès direct au fichier).

Les images (couvertures) passent aussi par app.py désormais (2026-09, suite) : la route
/api/nautiljon/img/<chemin> de main.py ne lit plus le fichier sur disque, elle le
récupère en HTTP chez app.py (route publique /<chemin> de app.py, qui lit le disque
partagé de son côté). TamaShelf n'a donc plus besoin d'aucun accès disque au dossier
Nautiljon ni de connaître son chemin -- seul APP_PY_URL est nécessaire, ce qui permet à
TamaShelf de tourner sur n'importe quelle machine du réseau (voire ailleurs), tant qu'il
peut joindre app.py.
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Optional

# ═══════════════════════════════════════════
#  Config
# ═══════════════════════════════════════════

# app.py est maintenant le seul process qui ouvre nautiljon_mangas.db -- ce module lui
# parle en HTTP plutôt que d'ouvrir le fichier. Les seules routes utilisées ici
# (/api/recherche, /api/serie/details) sont volontairement SANS authentification côté
# app.py (mêmes infos que la fiche publique /serie) : TamaShelf n'a donc plus besoin
# d'identifiants admin pour fonctionner.
APP_PY_URL = os.getenv("APP_PY_URL", "http://localhost:5555").rstrip("/")
APP_PY_TIMEOUT = float(os.getenv("APP_PY_TIMEOUT", "20"))

# Préfixe de la route (ajoutée dans main.py) qui sert les images -- voir _image_url()
# plus bas. main.py va chercher l'image chez app.py (APP_PY_URL + chemin) plutôt que sur
# disque : TamaShelf n'a donc plus besoin d'un accès disque au dossier Nautiljon, ni de
# connaître son chemin (NAUTILJON_DB a été retiré).
IMAGE_ROUTE_PREFIX = "/api/nautiljon/img"


# ═══════════════════════════════════════════
#  Client HTTP vers app.py
# ═══════════════════════════════════════════

def _app_py_get(chemin: str, params: Optional[dict] = None) -> Optional[dict]:
    """GET vers app.py (routes publiques, sans authentification -- voir plus haut).
    Renvoie None (plutôt que de lever) si app.py est injoignable ou répond une erreur
    réseau -- les fonctions de lecture (search_local, manga_auto...) dégradent alors
    proprement (résultats vides), exactement comme quand le fichier .db était absent
    avec l'ancien accès direct."""
    query = ""
    if params:
        propre = {k: v for k, v in params.items() if v is not None}
        query = "?" + urllib.parse.urlencode(propre)
    req = urllib.request.Request(f"{APP_PY_URL}{chemin}{query}")
    try:
        with urllib.request.urlopen(req, timeout=APP_PY_TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, ConnectionError):
        return None
    except (ValueError, json.JSONDecodeError):
        return None


def is_available() -> bool:
    """app.py est joignable ET la table 'series' existe dans sa base -- remplace l'ancien
    check direct sur le fichier (NAUTILJON_DB.is_file() + PRAGMA table_info)."""
    data = _app_py_get("/api/health")
    return bool(data and data.get("ok") and data.get("table_series"))


# ═══════════════════════════════════════════
#  Aide — décodage des infos_brutes / listes (inchangé, ne dépend pas de la source)
# ═══════════════════════════════════════════

def _image_url(chemin_relatif) -> str:
    """Convertit un chemin relatif renvoyé par app.py (ex: '/mangas/image/xxx.jpg', déjà
    avec le slash de tête -- convention app.py) en URL absolue servie par main.py.
    Chaîne vide si rien n'est fourni."""
    chemin = (chemin_relatif or "").strip()
    if not chemin:
        return ""
    if not chemin.startswith("/"):
        chemin = "/" + chemin
    return f"{IMAGE_ROUTE_PREFIX}{chemin}"


def _infos_brutes(row: dict) -> dict:
    brut = row.get("infos_brutes") or ""
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
    """'a, b, c' -> ['a','b','c']."""
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
#  Lecture — recherche / liste (matching)
# ═══════════════════════════════════════════

def _ligne_vers_item(row: dict) -> dict:
    cover = ""
    if row.get("image_jpg"):
        cover = _image_url(row["image_jpg"])
    elif row.get("image"):
        cover = _image_url(row["image"])
    synopsis = row.get("synopsis") or ""
    return {
        "url": row.get("url"),
        "title": row.get("titre"),
        "titre": row.get("titre"),
        "cover_url": cover,
        "image_url": cover,
        "synopsis": synopsis[:200],
    }


def search_local(q: str = "", limit: int = 48, offset: int = 0) -> dict:
    """Recherche dans la base (via app.py) par titre/synopsis. Renvoie la même forme
    {results, rows, total} qu'avant -- {} vide si app.py est injoignable."""
    data = _app_py_get("/api/recherche", {"q": q, "limit": limit, "offset": offset})
    if not data:
        return {"results": [], "rows": [], "total": 0}
    items = [_ligne_vers_item(r) for r in (data.get("rows") or [])]
    return {"results": items, "rows": items, "total": data.get("total", 0)}


def list_series(limit: int = 48, offset: int = 0, search: Optional[str] = None) -> dict:
    """Équivalent de l'ancien endpoint /list (avec filtre 'search' optionnel)."""
    return search_local(search or "", limit=limit, offset=offset)


# ═══════════════════════════════════════════
#  Lecture — détails complets d'une série (équivalent /manga_auto + /manga_editions)
# ═══════════════════════════════════════════

def _volume_vers_dict(row: dict) -> dict:
    numero = row.get("numero") or ""
    titre = row.get("titre") or ""
    cover_full = _image_url(row["image_jpg"]) if row.get("image_jpg") else ""
    cover_mini = _image_url(row["image_mini_jpg"]) if row.get("image_mini_jpg") else (cover_full or "")
    synopsis = row.get("synopsis") or ""
    return {
        "id": row.get("id"),
        "volume_id": row.get("id"),
        # Alias multiples pour rester compatible avec toutes les lectures existantes
        # côté frontend (App.jsx lit tantôt .number, tantôt .volume_number/.numero).
        "number": numero,
        "numero": numero,
        "volume_number": numero,
        "title": titre,
        "titre": titre,
        "synopsis": synopsis,
        "url": row.get("url") or "",
        "cover_full": cover_full,
        "cover_mini": cover_mini,
        "cover_url": cover_full,
        "categorie_volume": row.get("categorie_volume") or "",
        "is_available": True,
    }


def _editions_depuis_reponse(editions_brutes: list) -> list:
    editions = []
    for ed in editions_brutes or []:
        volumes = [_volume_vers_dict(v) for v in (ed.get("volumes") or [])]
        nom = ed.get("nom") or ""
        editions.append({
            "id": ed.get("id"),
            "name": nom,
            "nom": nom,
            "label": nom,
            "statut": ed.get("statut") or "",
            "volumes": volumes,
        })
    return editions


def manga_auto(url: str) -> Optional[dict]:
    """Détails complets d'une série par son URL nautiljon (via app.py). Renvoie None si la
    série n'est pas en base, ou si app.py est injoignable."""
    if not url:
        return None
    data = _app_py_get("/api/serie/details", {"url": url})
    if not data or not data.get("serie"):
        return None
    row = data["serie"]
    infos = _infos_brutes(row)

    cover_url = ""
    if row.get("image_jpg"):
        cover_url = _image_url(row["image_jpg"])
    elif row.get("image"):
        cover_url = _image_url(row["image"])

    editions = _editions_depuis_reponse(data.get("editions"))

    genres = _liste_depuis(_pick(infos, "Genre", "Genres"))
    themes = _liste_depuis(_pick(infos, "Thème", "Thèmes", "Theme", "Themes"))

    details = {
        "title": row.get("titre"),
        "url": url,
        "cover_url": cover_url,
        "image_url": cover_url,
        "main_cover_json": {"has_cover": bool(cover_url), "cover_full": cover_url, "cover_mini": cover_url},
        "synopsis": row.get("synopsis") or "",
        "description": row.get("synopsis") or "",
        "type": row.get("type") or _pick(infos, "Type") or "",
        "status": _pick(infos, "Statut") or "",
        "country": row.get("origine") or _pick(infos, "Origine") or "",
        "author": _pick(infos, "Auteur", "Auteurs") or "",
        "artist": _pick(infos, "Dessinateur", "Dessinateurs") or "",
        "publisher": _pick(infos, "Éditeur VF", "Éditeurs VF", "Éditeur VO", "Éditeurs VO") or "",
        "magazine": _pick(infos, "Prépublié dans") or "",
        "year": row.get("annee_vf") or row.get("annee_vo") or _pick(infos, "Année VF", "Année VO") or "",
        "volumes_count": row.get("nb_volumes_vf") or row.get("nb_volumes_vo") or _pick(infos, "Nb volumes VF", "Nb volumes VO") or "",
        "age_conseille": row.get("age_conseille") or _pick(infos, "Âge conseillé") or "",
        "alt_title": row.get("titre_original") or _pick(infos, "Titre original") or "",
        "japanese_title": row.get("titre_original") or _pick(infos, "Titre original") or "",
        "genres": genres,
        "themes": themes,
        "editions_json": editions,
        "raw_infos_json": infos,
        "has_details": True,
        "scraped": True,
        "source": "local_db",
    }
    return details


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

