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
tout ce qui touche la base (recherche/matching, détails d'une série, création d'une
série/édition/volume). scrapersql.py garde pour l'instant son accès direct (protégé par
la répartition par hash entre PC, donc pas de risque de collision) -- ce n'est pas encore
dans le périmètre de cette centralisation.

Ce module continue de reproduire EXACTEMENT la forme JSON que l'ancien accès direct (et,
avant lui, l'ancienne API HTTP séparée) renvoyait (mêmes clés : title, cover_url,
synopsis, editions_json avec volumes[].cover_full/cover_mini/number, etc.) afin que tout
le code déjà écrit côté backend (main.py), frontend React (App.jsx) et appli Flutter
continue de fonctionner SANS modification -- seule la SOURCE des données change (appel
HTTP à app.py au lieu d'un accès direct au fichier).

Les URLs d'images restent des chemins locaux servis par /api/nautiljon/img/<chemin> (lu
directement sur le disque partagé par main.py -- ça, ce n'est PAS de l'accès SQLite, donc
aucun risque de corruption, pas besoin de le faire passer par app.py non plus).
"""
import base64
import json
import os
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Optional

# ═══════════════════════════════════════════
#  Config
# ═══════════════════════════════════════════

# app.py est maintenant le seul process qui ouvre nautiljon_mangas.db -- ce module lui
# parle en HTTP plutôt que d'ouvrir le fichier. Identifiants : même compte que
# l'interface web de app.py (check_auth), à définir via ces variables d'env si le
# mot de passe par défaut ('mika'/'1234') a été changé côté app.py.
APP_PY_URL = os.getenv("APP_PY_URL", "http://localhost:5555").rstrip("/")
APP_PY_USER = os.getenv("APP_PY_USER", "mika")
APP_PY_PASS = os.getenv("APP_PY_PASS", "1234")
APP_PY_TIMEOUT = float(os.getenv("APP_PY_TIMEOUT", "20"))

# Toujours nécessaire : chemin du fichier .db (même mount que app.py) pour en déduire le
# dossier des images -- la lecture d'images se fait directement sur disque, pas via l'API.
NAUTILJON_DB = Path(os.getenv("NAUTILJON_DB", "/mnt/14To/nautiljon/nautiljon_mangas.db"))

# Préfixe de la route (ajoutée dans main.py) qui sert les images locales déjà
# téléchargées par scrapersql.py -- voir _image_url() plus bas.
IMAGE_ROUTE_PREFIX = "/api/nautiljon/img"


def nautiljon_dir() -> Path:
    """Dossier contenant le .db -- racine des chemins d'images relatifs stockés en base
    (ex: colonne image_jpg = '/mangas/image/xxx.jpg' -> fichier réel à
    <nautiljon_dir()>/mangas/image/xxx.jpg)."""
    return NAUTILJON_DB.parent


# ═══════════════════════════════════════════
#  Client HTTP vers app.py
# ═══════════════════════════════════════════

def _auth_header() -> str:
    jeton = base64.b64encode(f"{APP_PY_USER}:{APP_PY_PASS}".encode("utf-8")).decode("ascii")
    return f"Basic {jeton}"


def _app_py_get(chemin: str, params: Optional[dict] = None) -> Optional[dict]:
    """GET vers app.py. Renvoie None (plutôt que de lever) si app.py est injoignable ou
    répond une erreur réseau -- les fonctions de lecture (search_local, manga_auto...)
    dégradent alors proprement (résultats vides), exactement comme quand le fichier .db
    était absent avec l'ancien accès direct."""
    query = ""
    if params:
        propre = {k: v for k, v in params.items() if v is not None}
        query = "?" + urllib.parse.urlencode(propre)
    req = urllib.request.Request(f"{APP_PY_URL}{chemin}{query}", headers={"Authorization": _auth_header()})
    try:
        with urllib.request.urlopen(req, timeout=APP_PY_TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, ConnectionError):
        return None
    except (ValueError, json.JSONDecodeError):
        return None


def _multipart_encode(champs: list, fichiers: list) -> tuple:
    """champs: liste de (nom, valeur str) -- peut contenir des doublons de nom (ex.
    vol_numero répété une fois par ligne de volume, comme le ferait un vrai <form> HTML).
    fichiers: liste de (nom, nom_fichier, contenu_bytes) -- nom_fichier='' et
    contenu_bytes=b'' pour une ligne sans image (app.py, comme avant, traite alors ce
    champ comme vide). Renvoie (corps_bytes, content_type)."""
    boundary = "----tamashelf-" + uuid.uuid4().hex
    morceaux = []
    for nom, valeur in champs:
        morceaux.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{nom}"\r\n\r\n'.encode("utf-8")
            + str(valeur if valeur is not None else "").encode("utf-8")
            + b"\r\n"
        )
    for nom, nom_fichier, contenu in fichiers:
        contenu = contenu or b""
        morceaux.append(
            (
                f'--{boundary}\r\nContent-Disposition: form-data; name="{nom}"; '
                f'filename="{nom_fichier or ""}"\r\nContent-Type: application/octet-stream\r\n\r\n'
            ).encode("utf-8")
            + contenu
            + b"\r\n"
        )
    morceaux.append(f"--{boundary}--\r\n".encode("utf-8"))
    corps = b"".join(morceaux)
    return corps, f"multipart/form-data; boundary={boundary}"


def _app_py_post(chemin: str, champs: list, fichiers: Optional[list] = None) -> Optional[dict]:
    """POST multipart vers app.py (fonctionne aussi bien pour un simple formulaire sans
    fichier -- Flask lit request.form pareil que ce soit multipart ou urlencoded). Renvoie
    None si app.py est injoignable (les fonctions d'écriture transforment alors ça en
    ValueError, voir plus bas -- jamais d'exception réseau qui remonte telle quelle)."""
    corps, content_type = _multipart_encode(champs, fichiers or [])
    req = urllib.request.Request(
        f"{APP_PY_URL}{chemin}",
        data=corps,
        method="POST",
        headers={"Authorization": _auth_header(), "Content-Type": content_type},
    )
    try:
        with urllib.request.urlopen(req, timeout=APP_PY_TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        # app.py renvoie {"ok": false, "error": "..."} avec un code 400/404/500 -- le
        # corps de la réponse d'erreur reste exploitable normalement.
        try:
            return json.loads(e.read().decode("utf-8"))
        except (ValueError, json.JSONDecodeError):
            return {"ok": False, "error": f"Erreur HTTP {e.code} de app.py."}
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


# ═══════════════════════════════════════════
#  Écriture (admin) — créer une série / édition / volume à la main
#  Tout passe maintenant par app.py (/api/serie, /api/serie/edition, /api/serie/volume) --
#  ce module ne fait plus qu'encoder la requête HTTP et transformer une réponse
#  {"ok": false, "error": ...} (ou une panne réseau) en ValueError, exactement comme avant
#  (main.py attrape déjà ValueError pour ces trois fonctions).
# ═══════════════════════════════════════════

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
    """Crée une série manuellement (+ 1 édition + ses volumes éventuels) via app.py.
    'volumes' est une liste de dicts {numero, titre, synopsis, image_bytes}. Renvoie
    {url, edition_id, nb_volumes}."""
    titre = (titre or "").strip()
    if not titre:
        raise ValueError("Le titre est obligatoire.")

    champs = [
        ("titre", titre), ("synopsis", synopsis or ""), ("type", type_serie or ""),
        ("statut_vo", statut_vo or ""), ("statut_vf", statut_vf or ""),
        ("edition_nom", edition_nom or "Édition Standard"),
        ("genres", ", ".join(genres or [])), ("themes", ", ".join(themes or [])),
        ("editeurs", ", ".join(editeurs or [])), ("auteurs", ", ".join(auteurs or [])),
        ("scenaristes", ", ".join(scenaristes or [])), ("dessinateurs", ", ".join(dessinateurs or [])),
    ]
    fichiers = [("image", "cover.jpg" if image_bytes else "", image_bytes or b"")]
    for vol in (volumes or []):
        champs.append(("vol_numero", vol.get("numero") or ""))
        champs.append(("vol_titre", vol.get("titre") or ""))
        champs.append(("vol_synopsis", vol.get("synopsis") or ""))
        vb = vol.get("image_bytes")
        fichiers.append(("vol_image", "vol.jpg" if vb else "", vb or b""))

    data = _app_py_post("/api/serie", champs, fichiers)
    if data is None:
        raise ValueError(f"app.py injoignable ({APP_PY_URL}) -- impossible de créer la série.")
    if not data.get("ok"):
        raise ValueError(data.get("error") or "Erreur inconnue lors de la création de la série.")
    return {"url": data["url"], "edition_id": data["edition_id"], "nb_volumes": data.get("nb_volumes", 0)}


def ajouter_edition(url_serie: str, nom: str, statut: str = "") -> int:
    """Ajoute une nouvelle édition à une série EXISTANTE (ex: 'Édition Deluxe' en plus de
    l'édition standard), via app.py."""
    nom = (nom or "").strip()
    if not nom:
        raise ValueError("Le nom de l'édition est obligatoire.")
    data = _app_py_post("/api/serie/edition", [
        ("serie_url", url_serie or ""), ("nom", nom), ("statut", statut or ""),
    ])
    if data is None:
        raise ValueError(f"app.py injoignable ({APP_PY_URL}) -- impossible d'ajouter l'édition.")
    if not data.get("ok"):
        raise ValueError(data.get("error") or "Erreur inconnue lors de l'ajout de l'édition.")
    return data["edition_id"]


def ajouter_volume(edition_id: int, numero: str = "", titre: str = "", synopsis: str = "",
                    url_vol: str = "", image_bytes: Optional[bytes] = None) -> int:
    """Ajoute UN volume à une édition existante, via app.py."""
    numero = (numero or "").strip()
    titre = (titre or "").strip()
    if not numero and not titre:
        raise ValueError("Indique au moins un numéro ou un titre pour le volume.")

    champs = [
        ("edition_id", str(edition_id)), ("numero", numero), ("titre", titre),
        ("synopsis", synopsis or ""), ("url", url_vol or ""),
    ]
    fichiers = [("image", "vol.jpg" if image_bytes else "", image_bytes or b"")]
    data = _app_py_post("/api/serie/volume", champs, fichiers)
    if data is None:
        raise ValueError(f"app.py injoignable ({APP_PY_URL}) -- impossible d'ajouter le volume.")
    if not data.get("ok"):
        raise ValueError(data.get("error") or "Erreur inconnue lors de l'ajout du volume.")
    return data["volume_id"]
