"""
TamaShelf — Backend FastAPI + SQLite
Déployable sur Raspberry Pi, accessible depuis le réseau local ou via tunnel.
"""

import os
import re
import time
import hashlib
import secrets
import sqlite3
import shutil
import zipfile
import io
import json
import unicodedata
import subprocess
import tempfile
import shutil
from pathlib import Path
from typing import Optional
from contextlib import contextmanager

from fastapi import FastAPI, Depends, HTTPException, Query, Response, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import httpx

import nautiljon_db

# Optional (used for cover thumbnails). Added to requirements.
try:
    from PIL import Image
except Exception:  # pragma: no cover
    Image = None

# ═══════════════════════════════════════════
#  Config
# ═══════════════════════════════════════════

DATA_DIR = Path(os.getenv("TAMASHELF_DATA", os.getenv("MANGASHELF_DATA", "/data")))
DATA_DIR.mkdir(parents=True, exist_ok=True)
# Nom de fichier volontairement inchangé (mangashelf.db) : c'est la base existante de
# l'utilisateur (comptes, bibliothèque, progression de lecture) — la renommer ferait
# perdre l'accès à ces données au prochain démarrage du conteneur.
DB_PATH = DATA_DIR / "mangashelf.db"
STATIC_DIR = Path(os.getenv("TAMASHELF_STATIC", os.getenv("MANGASHELF_STATIC", "/app/static")))

# Cache local des jaquettes Nautiljon récupérées via app.py (voir la route
# /api/nautiljon/img plus bas) -- persiste dans TAMASHELF_DATA comme le reste, donc
# survit aux redéploiements. But : n'appeler app.py qu'une fois par image.
IMG_CACHE_DIR = DATA_DIR / "nautiljon_img_cache"
IMG_CACHE_DIR.mkdir(parents=True, exist_ok=True)

# Accès à la vraie base Nautiljon (recherche, détails, images) via l'API HTTP publique
# de app.py — voir nautiljon_db.py (APP_PY_URL). TamaShelf n'ouvre plus jamais
# nautiljon_mangas.db ni le dossier qui le contient directement : aucun accès disque à
# ce dossier n'est nécessaire, juste pouvoir joindre app.py sur le réseau.

# Outils externes (pour CBR -> CBZ)
SEVEN_Z_BIN = os.getenv("SEVEN_Z_BIN", "7z")
ZIP_BIN = os.getenv("ZIP_BIN", "zip")

app = FastAPI(title="TamaShelf", version="2.2")

# CORS: configurable via env, defaults to permissive for local dev
_cors_origins = os.getenv("TAMASHELF_CORS_ORIGINS", os.getenv("MANGASHELF_CORS_ORIGINS", "*"))
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in _cors_origins.split(",")] if _cors_origins != "*" else ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ═══════════════════════════════════════════
#  Database
# ═══════════════════════════════════════════


def _db_connection():
    """FastAPI dependency: yields a DB connection and auto-closes it."""
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
    finally:
        conn.close()


@contextmanager
def get_db_ctx():
    """Context manager for safe DB access: `with get_db_ctx() as db:`"""
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
    finally:
        conn.close()


def get_db():
    """Legacy: returns a raw connection. Prefer get_db_ctx() for new code."""
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def _strip_accents(text: str) -> str:
    return ''.join(ch for ch in unicodedata.normalize("NFD", text or "") if unicodedata.category(ch) != "Mn")

def _normalize_match_key(text: str) -> str:
    t = _strip_accents((text or '').lower().strip())
    # Déplace les articles finaux de type "Titre (Le)" -> "le titre"
    m = re.match(r"^(.*?)\s*\((le|la|les|the|l['’]?|un|une|des)\)\s*$", t, flags=re.IGNORECASE)
    if m:
        base = (m.group(1) or '').strip()
        art = (m.group(2) or '').strip()
        t = (art + ' ' + base).strip()
    t = t.replace("l'", 'l ').replace('’', ' ')
    t = re.sub(r'[^a-z0-9]+', ' ', t)
    return re.sub(r'\s+', ' ', t).strip()



def _match_query_variants(text: str) -> list[str]:
    """Retourne des variantes utiles pour la recherche (article fin/debut)."""
    raw = (text or '').strip()
    if not raw:
        return []
    variants = []
    def add(v):
        v = (v or '').strip()
        if v and v not in variants:
            variants.append(v)
    add(raw)

    # Variantes de ponctuation fréquentes (aident la recherche API)
    # ex: "Agenda - Attraction !" <-> "Agenda : Attraction !"
    if " - " in raw:
        add(raw.replace(" - ", " : "))
    if " : " in raw:
        add(raw.replace(" : ", " - "))

    # Titre (Le/La/Les/The/L') -> Le Titre
    m = re.match(r"^(.*?)\s*\((le|la|les|the|l['’]?|un|une|des)\)\s*$", raw, flags=re.IGNORECASE)
    if m:
        base = (m.group(1) or '').strip()
        art = (m.group(2) or '').strip()
        if art.lower().startswith(("l'", "l’")):
            add(f"{art}{base}")
            add(f"L'{base}")
            add(f"L’{base}")
        else:
            add(f"{art} {base}")

        # Combiner aussi avec la variante ponctuation sur le titre déplacé
        if " - " in base:
            b2 = base.replace(" - ", " : ")
            if art.lower().startswith(("l'", "l’")):
                add(f"{art}{b2}")
                add(f"L'{b2}")
                add(f"L’{b2}")
            else:
                add(f"{art} {b2}")
        if " : " in base:
            b2 = base.replace(" : ", " - ")
            if art.lower().startswith(("l'", "l’")):
                add(f"{art}{b2}")
                add(f"L'{b2}")
                add(f"L’{b2}")
            else:
                add(f"{art} {b2}")
    return variants


_EDITION_SUFFIXES = [
    " - edition", " - édition", " edition", " édition",
    " - version", " - deluxe", " - perfect", " - ultimate", " - collector",
]


def _strip_edition_suffix(name: str) -> str:
    """Retire un suffixe d'édition connu (ex: '20th Century Boys - Perfect Edition' ->
    '20th Century Boys') pour retrouver le titre de la série tel qu'il apparaît sur
    Nautiljon, indépendamment de l'édition physique choisie sur le disque. Même liste de
    suffixes que detect_duplicates (voir plus bas), pour rester cohérent."""
    n = (name or "").strip()
    low = n.lower()
    best = -1
    for sep in _EDITION_SUFFIXES:
        idx = low.find(sep)
        if idx > 0 and (best == -1 or idx < best):
            best = idx
    return n[:best].strip() if best > 0 else n


def _copytree_merge(src: Path, dst: Path) -> list[str]:
    """Copy a folder into another, merging contents.

    Compatible with older Python versions (avoids shutil.copytree(dirs_exist_ok=...)).
    Returns list of relative file paths copied.
    """
    copied: list[str] = []
    src = Path(src)
    dst = Path(dst)
    if not src.exists() or not src.is_dir():
        raise FileNotFoundError(str(src))
    dst.mkdir(parents=True, exist_ok=True)

    for root, dirs, files in os.walk(src):
        rel_root = Path(root).relative_to(src)
        (dst / rel_root).mkdir(parents=True, exist_ok=True)
        for d in dirs:
            (dst / rel_root / d).mkdir(parents=True, exist_ok=True)
        for f in files:
            s = Path(root) / f
            r = rel_root / f
            t = dst / r
            # Fast skip if same size+mtime
            try:
                if t.exists():
                    ss = s.stat()
                    ts = t.stat()
                    if ss.st_size == ts.st_size and int(ss.st_mtime) == int(ts.st_mtime):
                        continue
            except Exception:
                pass
            t.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(s), str(t))
            copied.append(str(r))
    return copied

def init_db():
    db = get_db()
    db.executescript("""
    CREATE TABLE IF NOT EXISTS config (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'user',
        perm_read_only INTEGER NOT NULL DEFAULT 0,
        perm_can_download INTEGER NOT NULL DEFAULT 0,
        perm_can_change_password INTEGER NOT NULL DEFAULT 1,
        created_at REAL NOT NULL DEFAULT (unixepoch())
    );

    CREATE TABLE IF NOT EXISTS sessions (
        token TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL,
        created_at REAL NOT NULL DEFAULT (unixepoch()),
        expires_at REAL NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS reading_progress (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        manga_url TEXT NOT NULL,
        volume_id TEXT NOT NULL DEFAULT '',
        current_page INTEGER NOT NULL DEFAULT 0,
        total_pages INTEGER NOT NULL DEFAULT 0,
        title TEXT,
        last_read REAL NOT NULL DEFAULT (unixepoch()),
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
        UNIQUE(user_id, manga_url, volume_id)
    );


    CREATE TABLE IF NOT EXISTS user_list_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        list_name TEXT NOT NULL,
        manga_url TEXT NOT NULL,
        volume_id TEXT NOT NULL DEFAULT '',
        item_type TEXT NOT NULL DEFAULT 'volume',
        title TEXT DEFAULT '',
        auto_added INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL DEFAULT (unixepoch()),
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
        UNIQUE(user_id, list_name, manga_url, volume_id, item_type)
    );

    CREATE TABLE IF NOT EXISTS matches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        manga_url TEXT UNIQUE NOT NULL,
        cbz_folder TEXT NOT NULL,
        matched_by TEXT,
        created_at REAL NOT NULL DEFAULT (unixepoch())
    );

    CREATE TABLE IF NOT EXISTS manga_cache (
        url TEXT PRIMARY KEY,
        title TEXT,
        cover_url TEXT,
        details_json TEXT,
        editions_json TEXT,
        cached_at REAL NOT NULL DEFAULT (unixepoch())
    );

    CREATE TABLE IF NOT EXISTS manga_library (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cbz_folder TEXT UNIQUE NOT NULL,
        nautiljon_url TEXT DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        cover_url TEXT DEFAULT '',
        cover_blob BLOB,
        synopsis TEXT DEFAULT '',
        metadata_json TEXT DEFAULT '{}',
        editions_json TEXT DEFAULT '[]',
        match_status TEXT NOT NULL DEFAULT 'unmatched',
        match_candidates_json TEXT DEFAULT '[]',
        synced_at REAL NOT NULL DEFAULT (unixepoch())
    );

    CREATE TABLE IF NOT EXISTS libraries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        cbz_path TEXT NOT NULL DEFAULT '',
        is_public INTEGER NOT NULL DEFAULT 1,
        created_at REAL NOT NULL DEFAULT (unixepoch())
    );

    CREATE TABLE IF NOT EXISTS library_access (
        library_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        PRIMARY KEY (library_id, user_id),
        FOREIGN KEY (library_id) REFERENCES libraries(id) ON DELETE CASCADE,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS manga_volumes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cbz_folder TEXT NOT NULL,
        library_id INTEGER NOT NULL,
        filename TEXT NOT NULL,
        filepath TEXT NOT NULL,
        volume_num INTEGER,
        volume_type TEXT,
        volume_display TEXT,
        source TEXT NOT NULL DEFAULT 'archive',
        file_size INTEGER NOT NULL DEFAULT 0,
        total_pages INTEGER NOT NULL DEFAULT 0,
        thumbnail_blob BLOB,
        chapters_json TEXT DEFAULT '[]',
        scanned_at REAL NOT NULL DEFAULT (unixepoch()),
        UNIQUE(cbz_folder, library_id, filename)
    );

    CREATE INDEX IF NOT EXISTS idx_volumes_folder ON manga_volumes(cbz_folder);
    CREATE INDEX IF NOT EXISTS idx_volumes_lib ON manga_volumes(library_id);

    CREATE INDEX IF NOT EXISTS idx_progress_user ON reading_progress(user_id);
    CREATE INDEX IF NOT EXISTS idx_progress_manga ON reading_progress(manga_url);
    CREATE INDEX IF NOT EXISTS idx_user_list_items_user ON user_list_items(user_id, list_name);
    CREATE INDEX IF NOT EXISTS idx_user_list_items_manga ON user_list_items(manga_url);
    CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions(token);
    CREATE INDEX IF NOT EXISTS idx_cache_url ON manga_cache(url);
    CREATE INDEX IF NOT EXISTS idx_library_folder ON manga_library(cbz_folder);
    CREATE INDEX IF NOT EXISTS idx_library_title ON manga_library(title COLLATE NOCASE);

    -- Ratings (1-5 stars per user per manga)
    CREATE TABLE IF NOT EXISTS user_ratings (
        user_id INTEGER NOT NULL,
        manga_id INTEGER NOT NULL,
        rating INTEGER NOT NULL CHECK(rating BETWEEN 1 AND 5),
        created_at REAL NOT NULL DEFAULT (unixepoch()),
        PRIMARY KEY (user_id, manga_id)
    );

    -- Personal notes/comments
    CREATE TABLE IF NOT EXISTS user_notes (
        user_id INTEGER NOT NULL,
        manga_id INTEGER NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        updated_at REAL NOT NULL DEFAULT (unixepoch()),
        PRIMARY KEY (user_id, manga_id)
    );

    -- Custom collections
    CREATE TABLE IF NOT EXISTS user_collections (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        description TEXT DEFAULT '',
        color TEXT DEFAULT '#6366f1',
        icon TEXT DEFAULT '📚',
        created_at REAL NOT NULL DEFAULT (unixepoch())
    );

    -- Collection items
    CREATE TABLE IF NOT EXISTS user_collection_items (
        collection_id INTEGER NOT NULL,
        manga_id INTEGER NOT NULL,
        added_at REAL NOT NULL DEFAULT (unixepoch()),
        PRIMARY KEY (collection_id, manga_id),
        FOREIGN KEY (collection_id) REFERENCES user_collections(id) ON DELETE CASCADE
    );

    -- Reading stats (aggregated daily)
    CREATE TABLE IF NOT EXISTS reading_stats (
        user_id INTEGER NOT NULL,
        date TEXT NOT NULL,
        pages_read INTEGER NOT NULL DEFAULT 0,
        volumes_read INTEGER NOT NULL DEFAULT 0,
        time_seconds INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (user_id, date)
    );

    CREATE INDEX IF NOT EXISTS idx_ratings_user ON user_ratings(user_id);
    CREATE INDEX IF NOT EXISTS idx_notes_user ON user_notes(user_id);
    CREATE INDEX IF NOT EXISTS idx_collections_user ON user_collections(user_id);
    CREATE INDEX IF NOT EXISTS idx_stats_user ON reading_stats(user_id, date);
    """)
    db.commit()
    db.close()

def migrate_db():
    db = get_db()
    cols = [row[1] for row in db.execute("PRAGMA table_info(manga_library)").fetchall()]
    if "library_id" not in cols:
        db.execute("ALTER TABLE manga_library ADD COLUMN library_id INTEGER DEFAULT NULL")
        db.commit()

    lib_count = db.execute("SELECT COUNT(*) as c FROM libraries").fetchone()["c"]
    if lib_count == 0:
        cbz_path = get_config_val(db, "cbz_path", "")
        db.execute(
            "INSERT INTO libraries (name, cbz_path, is_public) VALUES ('Bibliothèque principale', ?, 1)",
            (cbz_path,)
        )
        db.commit()

    # Nettoyage garanti des entrées au format obsolète (vol-N, sans extension CBZ)
    db.execute("""
        DELETE FROM reading_progress
        WHERE volume_id LIKE 'vol-%'
           OR (volume_id != '' AND volume_id NOT LIKE '%.cbz'
               AND volume_id NOT LIKE '%.cbr' AND volume_id NOT LIKE '%.zip')
    """)
    db.commit()

    # Migration: changer UNIQUE(user_id, manga_url) → UNIQUE(user_id, manga_url, volume_id)
    needs_progress_migration = True
    try:
        for idx in db.execute("PRAGMA index_list(reading_progress)").fetchall():
            if idx["unique"]:
                cols = [r["name"] for r in db.execute(f"PRAGMA index_info('{idx['name']}')").fetchall()]
                if "volume_id" in cols and "manga_url" in cols:
                    needs_progress_migration = False
                    break
    except Exception:
        pass

    if needs_progress_migration:
        try:
            db.execute("DROP TABLE IF EXISTS reading_progress_new")
            db.execute("""
                CREATE TABLE reading_progress_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id INTEGER NOT NULL,
                    manga_url TEXT NOT NULL,
                    volume_id TEXT NOT NULL DEFAULT '',
                    current_page INTEGER NOT NULL DEFAULT 0,
                    total_pages INTEGER NOT NULL DEFAULT 0,
                    title TEXT,
                    last_read REAL NOT NULL DEFAULT 0,
                    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
                    UNIQUE(user_id, manga_url, volume_id)
                )
            """)
            db.execute("""
                INSERT OR IGNORE INTO reading_progress_new
                    (id, user_id, manga_url, volume_id, current_page, total_pages, title, last_read)
                SELECT id, user_id, manga_url,
                    COALESCE(volume_id, ''),
                    current_page, total_pages, title,
                    COALESCE(last_read, 0)
                FROM reading_progress
                WHERE volume_id LIKE '%.cbz' OR volume_id LIKE '%.cbr' OR volume_id LIKE '%.zip'
            """)
            db.execute("DROP TABLE reading_progress")
            db.execute("ALTER TABLE reading_progress_new RENAME TO reading_progress")
            db.execute("CREATE INDEX IF NOT EXISTS idx_progress_user ON reading_progress(user_id)")
            db.commit()
        except Exception as e:
            try: db.rollback()
            except Exception: pass

    default_lib = db.execute("SELECT id FROM libraries ORDER BY id LIMIT 1").fetchone()
    if default_lib:
        db.execute(
            "UPDATE manga_library SET library_id = ? WHERE library_id IS NULL",
            (default_lib["id"],)
        )
        db.commit()

    # Migration: ajouter cover_blob à manga_library
    ml_cols = [row[1] for row in db.execute("PRAGMA table_info(manga_library)").fetchall()]
    if "cover_blob" not in ml_cols:
        db.execute("ALTER TABLE manga_library ADD COLUMN cover_blob BLOB")
        db.commit()

    # Migration: ajouter thumbnail_blob et total_pages à manga_volumes
    try:
        mv_cols = [row[1] for row in db.execute("PRAGMA table_info(manga_volumes)").fetchall()]
        if "thumbnail_blob" not in mv_cols:
            db.execute("ALTER TABLE manga_volumes ADD COLUMN thumbnail_blob BLOB")
            db.commit()
        if "total_pages" not in mv_cols:
            db.execute("ALTER TABLE manga_volumes ADD COLUMN total_pages INTEGER NOT NULL DEFAULT 0")
            db.commit()
    except:
        pass  # Table might not exist yet

    db.close()

init_db()

# Ensure default volume keywords exist in config
def _init_default_keywords():
    db = get_db()
    defaults = {
        "tome_keywords": "Tome,T,Vol,Volume",
        "chapter_keywords": "Chapitre,Chapter,Ch,Ep,Episode",
        "oneshot_keywords": "OS,One Shot,One-Shot,Oneshot",
    }
    for key, default in defaults.items():
        existing = db.execute("SELECT value FROM config WHERE key = ?", (key,)).fetchone()
        if not existing:
            db.execute("INSERT INTO config (key, value) VALUES (?, ?)", (key, default))
    db.commit()
    db.close()

_init_default_keywords()

# ═══════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════

# Optional: argon2 for stronger password hashing
try:
    from argon2 import PasswordHasher as _Argon2Hasher
    from argon2.exceptions import VerifyMismatchError as _Argon2Mismatch
    _argon2 = _Argon2Hasher()
except ImportError:
    _argon2 = None


def hash_password(password: str) -> str:
    """Hash with argon2 if available, else PBKDF2 fallback."""
    if _argon2:
        return "argon2:" + _argon2.hash(password)
    salt = secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 100000)
    return f"{salt}:{h.hex()}"

def verify_password(password: str, stored: str) -> bool:
    """Verify password — supports both argon2 and legacy PBKDF2 hashes."""
    try:
        if stored.startswith("argon2:"):
            if not _argon2:
                return False
            try:
                return _argon2.verify(stored[7:], password)
            except _Argon2Mismatch:
                return False
        # Legacy PBKDF2
        salt, h = stored.split(":")
        check = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 100000)
        return check.hex() == h
    except Exception:
        return False

def create_session(db, user_id: int) -> str:
    token = secrets.token_urlsafe(48)
    expires = time.time() + 30 * 24 * 3600  # 30 jours
    db.execute("INSERT INTO sessions (token, user_id, expires_at) VALUES (?, ?, ?)",
               (token, user_id, expires))
    # Nettoyage des sessions expirées
    db.execute("DELETE FROM sessions WHERE expires_at < ?", (time.time(),))
    db.commit()
    return token

def get_config_val(db, key: str, default: str = "") -> str:
    row = db.execute("SELECT value FROM config WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default

def set_config_val(db, key: str, value: str):
    db.execute("INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)", (key, value))
    db.commit()

def get_cbz_path(db) -> str:
    return get_config_val(db, "cbz_path", "")

def get_user_library_ids(db, user_id: int, role: str) -> list:
    if role == "admin":
        rows = db.execute("SELECT id FROM libraries").fetchall()
        return [r["id"] for r in rows]
    rows = db.execute("""
        SELECT id FROM libraries WHERE is_public = 1
        UNION
        SELECT library_id AS id FROM library_access WHERE user_id = ?
    """, (user_id,)).fetchall()
    return [r["id"] for r in rows]

def get_library_cbz_path_for_folder(db, folder: str) -> str:
    """Cherche dans quelle bibliothèque ce dossier existe.
    
    Parcourt TOUTES les bibliothèques (pas seulement celle liée dans manga_library).
    """
    # 1) Chercher le dossier sur disque dans toutes les bibliothèques
    all_libs = db.execute("SELECT id, cbz_path FROM libraries ORDER BY id ASC").fetchall()
    for lib in all_libs:
        if lib["cbz_path"]:
            p = Path(lib["cbz_path"]) / folder
            if p.exists() and p.is_dir():
                return lib["cbz_path"]
    # 2) Fallback : via manga_library.library_id
    row = db.execute("""
        SELECT l.cbz_path FROM manga_library ml
        JOIN libraries l ON ml.library_id = l.id
        WHERE ml.cbz_folder = ?
        ORDER BY l.id ASC
    """, (folder,)).fetchone()
    if row and row["cbz_path"]:
        return row["cbz_path"]
    return get_cbz_path(db)

def get_library_cbz_path_for_filepath(db, filepath: str) -> str:
    """Cherche dans quelle bibliothèque le fichier CBZ existe réellement.
    
    Parcourt TOUTES les bibliothèques pour trouver le fichier exact.
    """
    parts = Path(filepath).parts
    if len(parts) < 2:
        return get_library_cbz_path_for_folder(db, parts[0] if parts else "")
    folder, filename = "/".join(parts[:-1]), parts[-1]
    # Chercher dans TOUTES les bibliothèques
    all_libs = db.execute("SELECT id, cbz_path FROM libraries ORDER BY id ASC").fetchall()
    for lib in all_libs:
        if lib["cbz_path"] and (Path(lib["cbz_path"]) / folder / filename).exists():
            return lib["cbz_path"]
    # Fallback
    return get_library_cbz_path_for_folder(db, parts[0] if parts else "")

def folder_from_filepath(filepath: str) -> str:
    """Retourne le dossier manga depuis un chemin de fichier.
    
    'Manga/T01.cbz' → 'Manga'
    'Genre/Manga/T01.cbz' → 'Genre/Manga'
    """
    parts = Path(filepath).parts
    if len(parts) >= 2:
        return str(Path(*parts[:-1]))
    return parts[0] if parts else ""

migrate_db()

# ═══════════════════════════════════════════
#  Auth dependency
# ═══════════════════════════════════════════

def get_current_user(request: Request):
    # Try Bearer token first
    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    # Then cookie
    if not token:
        token = request.cookies.get("session_token", "")
    # Then query param (for img src, downloads etc)
    if not token:
        token = request.query_params.get("token", "")
    if not token:
        raise HTTPException(401, "Non authentifié")
    
    with get_db_ctx() as db:
        row = db.execute("""
            SELECT u.id, u.username, u.role, u.perm_read_only, u.perm_can_download, u.perm_can_change_password
            FROM sessions s JOIN users u ON s.user_id = u.id
            WHERE s.token = ? AND s.expires_at > ?
        """, (token, time.time())).fetchone()

    if not row:
        raise HTTPException(401, "Session expirée")

    return {
        "id": row["id"],
        "username": row["username"],
        "role": row["role"],
        "perms": {
            "readOnly": bool(row["perm_read_only"]),
            "canDownload": bool(row["perm_can_download"]),
            "canChangePassword": bool(row["perm_can_change_password"]),
        }
    }

def require_admin(user=Depends(get_current_user)):
    if user["role"] != "admin":
        raise HTTPException(403, "Accès admin requis")
    return user

# ═══════════════════════════════════════════
#  Models
# ═══════════════════════════════════════════

class SetupRequest(BaseModel):
    username: str
    password: str
    cbz_path: str = ""

class LoginRequest(BaseModel):
    username: str
    password: str

class CreateUserRequest(BaseModel):
    username: str
    password: str
    role: str = "user"
    perm_read_only: bool = False
    perm_can_download: bool = False
    perm_can_change_password: bool = True

class UpdateUserRequest(BaseModel):
    username: Optional[str] = None
    password: Optional[str] = None
    role: Optional[str] = None
    perm_read_only: Optional[bool] = None
    perm_can_download: Optional[bool] = None
    perm_can_change_password: Optional[bool] = None

class ChangePasswordRequest(BaseModel):
    old_password: str
    new_password: str

class ConfigUpdateRequest(BaseModel):
    cbz_path: Optional[str] = None
    tome_keywords: Optional[str] = None
    chapter_keywords: Optional[str] = None
    oneshot_keywords: Optional[str] = None

class SaveProgressRequest(BaseModel):
    manga_url: str
    volume_id: str = ""
    current_page: int = 0
    total_pages: int = 0
    title: str = ""

class UserListItemRequest(BaseModel):
    list_name: str
    manga_url: str
    volume_id: str = ""
    item_type: str = ""
    title: str = ""
    auto_added: bool = False

class MatchRequest(BaseModel):
    manga_url: str
    cbz_folder: str

class LibraryCreateRequest(BaseModel):
    name: str
    cbz_path: str = ""
    is_public: bool = True

class LibraryUpdateRequest(BaseModel):
    name: Optional[str] = None
    cbz_path: Optional[str] = None
    is_public: Optional[bool] = None

class LibraryAccessRequest(BaseModel):
    user_ids: list[int]

class CopyFolderRequest(BaseModel):
    folder: str
    # Optional destination folder name (when folder names differ between libraries)
    dst_folder: Optional[str] = None
    from_lib: int
    to_lib: int

class CopyFileRequest(BaseModel):
    folder: str
    filename: str
    from_lib: int
    to_lib: int

# ═══════════════════════════════════════════
#  Routes: Setup & Auth
# ═══════════════════════════════════════════

@app.get("/api/setup-status")
def setup_status():
    with get_db_ctx() as db:
        count = db.execute("SELECT COUNT(*) as c FROM users WHERE role = 'admin'").fetchone()["c"]
        return {"setup_done": count > 0}

@app.post("/api/setup")
def setup(req: SetupRequest):
    with get_db_ctx() as db:
        count = db.execute("SELECT COUNT(*) as c FROM users WHERE role = 'admin'").fetchone()["c"]
        if count > 0:
            raise HTTPException(400, "Setup déjà effectué")
    
        if len(req.password) < 4:
            raise HTTPException(400, "Mot de passe trop court (min 4)")

        db.execute(
            "INSERT INTO users (username, password_hash, role, perm_can_download, perm_can_change_password) VALUES (?, ?, 'admin', 1, 1)",
            (req.username.strip(), hash_password(req.password))
        )
        if req.cbz_path.strip():
            set_config_val(db, "cbz_path", req.cbz_path.strip())
    
        user = db.execute("SELECT id FROM users WHERE username = ?", (req.username.strip(),)).fetchone()
        token = create_session(db, user["id"])

        return {"token": token, "username": req.username.strip(), "role": "admin"}

@app.post("/api/login")
def login(req: LoginRequest):
    with get_db_ctx() as db:
        user = db.execute("SELECT * FROM users WHERE username = ?", (req.username.strip(),)).fetchone()
        if not user or not verify_password(req.password, user["password_hash"]):
            raise HTTPException(401, "Identifiants incorrects")
    
        token = create_session(db, user["id"])

        return {
            "token": token,
            "username": user["username"],
            "role": user["role"],
            "perms": {
                "readOnly": bool(user["perm_read_only"]),
                "canDownload": bool(user["perm_can_download"]),
                "canChangePassword": bool(user["perm_can_change_password"]),
            }
        }

@app.post("/api/logout")
def logout(request: Request):
    token = request.headers.get("Authorization", "").replace("Bearer ", "")
    if token:
        with get_db_ctx() as db:
            db.execute("DELETE FROM sessions WHERE token = ?", (token,))
            db.commit()
    return {"ok": True}

@app.get("/api/me")
def me(user=Depends(get_current_user)):
    return user

# ═══════════════════════════════════════════
#  Routes: Admin — Users
# ═══════════════════════════════════════════

@app.get("/api/admin/users")
def list_users(admin=Depends(require_admin)):
    with get_db_ctx() as db:
        rows = db.execute("SELECT id, username, role, perm_read_only, perm_can_download, perm_can_change_password, created_at FROM users ORDER BY id").fetchall()
        return [dict(r) for r in rows]

@app.post("/api/admin/users")
def create_user(req: CreateUserRequest, admin=Depends(require_admin)):
    if len(req.password) < 4:
        raise HTTPException(400, "Mot de passe trop court")
    with get_db_ctx() as db:
        existing = db.execute("SELECT id FROM users WHERE username = ?", (req.username.strip(),)).fetchone()
        if existing:
            raise HTTPException(400, "Ce nom existe déjà")
    
        db.execute(
            "INSERT INTO users (username, password_hash, role, perm_read_only, perm_can_download, perm_can_change_password) VALUES (?, ?, ?, ?, ?, ?)",
            (req.username.strip(), hash_password(req.password), req.role, int(req.perm_read_only), int(req.perm_can_download), int(req.perm_can_change_password))
        )
        db.commit()
        user_id = db.execute("SELECT id FROM users WHERE username = ?", (req.username.strip(),)).fetchone()["id"]
        return {"id": user_id, "username": req.username.strip()}

@app.put("/api/admin/users/{user_id}")
def update_user(user_id: int, req: UpdateUserRequest, admin=Depends(require_admin)):
    with get_db_ctx() as db:
        user = db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
        if not user:
            raise HTTPException(404, "Utilisateur introuvable")
    
        updates = []
        params = []
        if req.username is not None:
            dup = db.execute("SELECT id FROM users WHERE username = ? AND id != ?", (req.username.strip(), user_id)).fetchone()
            if dup:
                raise HTTPException(400, "Ce nom existe déjà")
            updates.append("username = ?")
            params.append(req.username.strip())
        if req.password is not None and req.password:
            if len(req.password) < 4:
                raise HTTPException(400, "Mot de passe trop court")
            updates.append("password_hash = ?")
            params.append(hash_password(req.password))
        if req.role is not None:
            updates.append("role = ?")
            params.append(req.role)
        if req.perm_read_only is not None:
            updates.append("perm_read_only = ?")
            params.append(int(req.perm_read_only))
        if req.perm_can_download is not None:
            updates.append("perm_can_download = ?")
            params.append(int(req.perm_can_download))
        if req.perm_can_change_password is not None:
            updates.append("perm_can_change_password = ?")
            params.append(int(req.perm_can_change_password))
    
        if updates:
            params.append(user_id)
            db.execute(f"UPDATE users SET {', '.join(updates)} WHERE id = ?", params)
            db.commit()
        return {"ok": True}

@app.delete("/api/admin/users/{user_id}")
def delete_user(user_id: int, admin=Depends(require_admin)):
    if admin["id"] == user_id:
        raise HTTPException(400, "Impossible de supprimer votre propre compte")
    with get_db_ctx() as db:
        db.execute("DELETE FROM users WHERE id = ?", (user_id,))
        db.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
        db.execute("DELETE FROM reading_progress WHERE user_id = ?", (user_id,))
        db.commit()
        return {"ok": True}

    # ═══════════════════════════════════════════
    #  Routes: Admin — Config
    # ═══════════════════════════════════════════

@app.get("/api/admin/config")
def get_config(admin=Depends(require_admin)):
    with get_db_ctx() as db:
        result = {
            "nautiljon_db_available": nautiljon_db.is_available(),
            "nautiljon_db_path": nautiljon_db.APP_PY_URL,
            "cbz_path": get_cbz_path(db),
            "tome_keywords": get_config_val(db, "tome_keywords", "Tome,T,Vol,Volume"),
            "chapter_keywords": get_config_val(db, "chapter_keywords", "Chapitre,Chapter,Ch,Ep,Episode"),
            "oneshot_keywords": get_config_val(db, "oneshot_keywords", "OS,One Shot,One-Shot,Oneshot"),
        }
        return result

@app.put("/api/admin/config")
def update_config(req: ConfigUpdateRequest, admin=Depends(require_admin)):
    with get_db_ctx() as db:
        if req.cbz_path is not None:
            set_config_val(db, "cbz_path", req.cbz_path.strip())
        if hasattr(req, 'tome_keywords') and req.tome_keywords is not None:
            set_config_val(db, "tome_keywords", req.tome_keywords.strip())
        if hasattr(req, 'chapter_keywords') and req.chapter_keywords is not None:
            set_config_val(db, "chapter_keywords", req.chapter_keywords.strip())
        if hasattr(req, 'oneshot_keywords') and req.oneshot_keywords is not None:
            set_config_val(db, "oneshot_keywords", req.oneshot_keywords.strip())
        # Invalidate keyword cache
        _kw_cache["tome"] = None
        _kw_cache["ts"] = 0
        return {"ok": True}

    # ═══════════════════════════════════════════
    #  Routes: Libraries
    # ═══════════════════════════════════════════

@app.get("/api/libraries")
def list_libraries(user=Depends(get_current_user)):
    with get_db_ctx() as db:
        lib_ids = get_user_library_ids(db, user["id"], user["role"])
        if not lib_ids:
            return []
        placeholders = ",".join("?" * len(lib_ids))
        rows = db.execute(
            f"SELECT id, name, cbz_path, is_public, created_at FROM libraries WHERE id IN ({placeholders}) ORDER BY id",
            lib_ids
        ).fetchall()
        return [dict(r) for r in rows]

@app.get("/api/admin/libraries")
def admin_list_libraries(admin=Depends(require_admin)):
    with get_db_ctx() as db:
        rows = db.execute("SELECT id, name, cbz_path, is_public, created_at FROM libraries ORDER BY id").fetchall()
        result = []
        for r in rows:
            lib = dict(r)
            access_rows = db.execute("SELECT user_id FROM library_access WHERE library_id = ?", (r["id"],)).fetchall()
            lib["user_ids"] = [a["user_id"] for a in access_rows]
            lib["manga_count"] = db.execute("SELECT COUNT(*) as c FROM manga_library WHERE library_id = ?", (r["id"],)).fetchone()["c"]
            result.append(lib)
        return result

@app.post("/api/admin/libraries")
def create_library(req: LibraryCreateRequest, admin=Depends(require_admin)):
    with get_db_ctx() as db:
        db.execute(
            "INSERT INTO libraries (name, cbz_path, is_public) VALUES (?, ?, ?)",
            (req.name.strip(), req.cbz_path.strip(), int(req.is_public))
        )
        db.commit()
        lib_id = db.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
        return {"id": lib_id, "name": req.name.strip()}

@app.put("/api/admin/libraries/{lib_id}")
def update_library(lib_id: int, req: LibraryUpdateRequest, admin=Depends(require_admin)):
    with get_db_ctx() as db:
        row = db.execute("SELECT id FROM libraries WHERE id = ?", (lib_id,)).fetchone()
        if not row:
            raise HTTPException(404, "Bibliothèque introuvable")
        updates = []
        params = []
        if req.name is not None:
            updates.append("name = ?")
            params.append(req.name.strip())
        if req.cbz_path is not None:
            updates.append("cbz_path = ?")
            params.append(req.cbz_path.strip())
        if req.is_public is not None:
            updates.append("is_public = ?")
            params.append(int(req.is_public))
        if updates:
            params.append(lib_id)
            db.execute(f"UPDATE libraries SET {', '.join(updates)} WHERE id = ?", params)
            db.commit()
        return {"ok": True}

@app.delete("/api/admin/libraries/{lib_id}")
def delete_library(lib_id: int, admin=Depends(require_admin)):
    with get_db_ctx() as db:
        count = db.execute("SELECT COUNT(*) as c FROM libraries").fetchone()["c"]
        if count <= 1:
            raise HTTPException(400, "Impossible de supprimer la dernière bibliothèque")
    
        # Récupérer les mangas de cette bibliothèque
        orphan_mangas = db.execute(
            "SELECT id, cbz_folder FROM manga_library WHERE library_id = ?", (lib_id,)
        ).fetchall()
    
        # Récupérer les autres bibliothèques
        other_libs = db.execute(
            "SELECT id, cbz_path FROM libraries WHERE id != ? ORDER BY id ASC", (lib_id,)
        ).fetchall()
    
        # Pour chaque manga orphelin, chercher s'il existe dans une autre bibliothèque
        reassigned = 0
        deleted = 0
        for manga in orphan_mangas:
            found_lib = None
            for lib in other_libs:
                if lib["cbz_path"]:
                    p = Path(lib["cbz_path"]) / manga["cbz_folder"]
                    if p.exists() and p.is_dir():
                        found_lib = lib["id"]
                        break
        
            if found_lib:
                # Réassigner à une autre bibliothèque
                db.execute("UPDATE manga_library SET library_id = ? WHERE id = ?", (found_lib, manga["id"]))
                reassigned += 1
            else:
                # Aucune autre bibliothèque n'a ce dossier → supprimer
                db.execute("DELETE FROM manga_library WHERE id = ?", (manga["id"],))
                deleted += 1
    
        db.execute("DELETE FROM libraries WHERE id = ?", (lib_id,))
        db.execute("DELETE FROM library_access WHERE library_id = ?", (lib_id,))
        db.commit()
        return {"ok": True, "reassigned": reassigned, "deleted": deleted}

@app.post("/api/admin/libraries/{lib_id}/reset-match")
def reset_library_match(lib_id: int, admin=Depends(require_admin)):
    """Efface les données de matching (Nautiljon) de tous les mangas d'une bibliothèque
    pour pouvoir relancer le matching à neuf -- garde les mangas eux-mêmes (cbz_folder,
    volumes) et le titre affiché (utile en attendant le rematch), remet juste
    match_status à 'unmatched' et vide tout ce qui vient de Nautiljon."""
    with get_db_ctx() as db:
        lib = db.execute("SELECT id, name FROM libraries WHERE id = ?", (lib_id,)).fetchone()
        if not lib:
            raise HTTPException(404, "Bibliothèque introuvable")

        folders = [r["cbz_folder"] for r in db.execute(
            "SELECT cbz_folder FROM manga_library WHERE library_id = ?", (lib_id,)
        ).fetchall()]

        db.execute("""
            UPDATE manga_library
            SET nautiljon_url = '', cover_url = '', cover_blob = NULL, synopsis = '',
                metadata_json = '{}', editions_json = '[]', match_status = 'unmatched',
                match_candidates_json = '[]'
            WHERE library_id = ?
        """, (lib_id,))

        if folders:
            placeholders = ",".join("?" for _ in folders)
            db.execute(f"DELETE FROM matches WHERE cbz_folder IN ({placeholders})", folders)

        db.commit()
        return {"ok": True, "reset": len(folders)}

@app.get("/api/admin/libraries/{lib_id}/access")
def get_library_access(lib_id: int, admin=Depends(require_admin)):
    with get_db_ctx() as db:
        rows = db.execute("SELECT user_id FROM library_access WHERE library_id = ?", (lib_id,)).fetchall()
        return {"user_ids": [r["user_id"] for r in rows]}

@app.put("/api/admin/libraries/{lib_id}/access")
def set_library_access(lib_id: int, req: LibraryAccessRequest, admin=Depends(require_admin)):
    with get_db_ctx() as db:
        row = db.execute("SELECT id FROM libraries WHERE id = ?", (lib_id,)).fetchone()
        if not row:
            raise HTTPException(404, "Bibliothèque introuvable")
        db.execute("DELETE FROM library_access WHERE library_id = ?", (lib_id,))
        for uid in req.user_ids:
            db.execute("INSERT OR IGNORE INTO library_access (library_id, user_id) VALUES (?, ?)", (lib_id, uid))
        db.commit()
        return {"ok": True}

@app.get("/api/admin/libraries/compare")
def compare_libraries(lib_a: int, lib_b: int, admin=Depends(require_admin)):
    with get_db_ctx() as db:
        lib_a_row = db.execute("SELECT id, name, cbz_path FROM libraries WHERE id = ?", (lib_a,)).fetchone()
        lib_b_row = db.execute("SELECT id, name, cbz_path FROM libraries WHERE id = ?", (lib_b,)).fetchone()
        if not lib_a_row or not lib_b_row:
            raise HTTPException(404, "Bibliothèque introuvable")

        rows_a = db.execute(
            "SELECT cbz_folder, nautiljon_url, title, cover_url, match_status FROM manga_library WHERE library_id = ?",
            (lib_a,)
        ).fetchall()
        rows_b = db.execute(
            "SELECT cbz_folder, nautiljon_url, title, cover_url, match_status FROM manga_library WHERE library_id = ?",
            (lib_b,)
        ).fetchall()

        # ── Pairing strategy ──────────────────────────────────────────────
        # Folder names often differ between libraries. We align manga:
        #   1) by nautiljon_url when available (stable key)
        #   2) else by normalized title (same logic as matching)
        # Fallback keeps them separate.

        a_items = [dict(r) for r in rows_a]
        b_items = [dict(r) for r in rows_b]

        b_by_url: dict[str, dict] = {}
        b_by_norm: dict[str, list[dict]] = {}
        for r in b_items:
            url = (r.get("nautiljon_url") or "").strip()
            if url:
                b_by_url[url] = r
            norm = _normalize_match_key(r.get("title") or r.get("cbz_folder") or "")
            b_by_norm.setdefault(norm, []).append(r)

        used_b_folders: set[str] = set()

        def _pick_b_for_a(a: dict) -> Optional[dict]:
            url = (a.get("nautiljon_url") or "").strip()
            if url and url in b_by_url:
                b = b_by_url[url]
                if b.get("cbz_folder") not in used_b_folders:
                    return b
            norm = _normalize_match_key(a.get("title") or a.get("cbz_folder") or "")
            for b in b_by_norm.get(norm, []):
                if b.get("cbz_folder") not in used_b_folders:
                    return b
            return None

        cbz_exts = {".cbz", ".cbr", ".zip"}

        def scan_entries(base_path: str, folder: str) -> list[dict]:
            """Retourne la liste des tomes/chapitres d'un dossier, avec normalisation.

            La comparaison se fait sur une clé dérivée du nom (ex: tome:1, chapter:12).
            Si on ne peut pas parser un numéro, on retombe sur le nom de fichier (case-insensitive).
            """
            if not base_path:
                return []
            p = Path(base_path) / folder
            if not p.exists() or not p.is_dir():
                return []
            out: list[dict] = []
            for f in p.iterdir():
                if not (f.is_file() and f.suffix.lower() in cbz_exts):
                    continue
                info = _parse_cbz_info(f.stem, folder_name=folder)
                vtype = info.get("type")
                num = info.get("num")
                disp = info.get("display") or f.name
                key = f"{vtype}:{num}" if vtype and num is not None else f"file:{f.name.lower()}"
                out.append({
                    "name": f.name,
                    "key": key,
                    "volume": num,
                    "volume_type": vtype,
                    "display": disp,
                })

            def _sort_key(e: dict):
                t = e.get("volume_type")
                rank = 0 if t == "oneshot" else 1 if t == "tome" else 2 if t == "chapter" else 3
                v = e.get("volume")
                return (rank, v if isinstance(v, int) else 9999, e.get("name", ""))
            return sorted(out, key=_sort_key)

        # New, UI-friendly "rows" list:
        # - ordered: those missing in B first (includes "not present"), then those fully identical, then items only in B
        rows = []

        # First: every manga from A (source)
        for a in sorted(a_items, key=lambda r: (r.get("title") or r.get("cbz_folder") or "").lower()):
            folder_a = a.get("cbz_folder")
            b = _pick_b_for_a(a)
            folder_b = b.get("cbz_folder") if b else None
            if folder_b:
                used_b_folders.add(folder_b)

            entries_a = scan_entries(lib_a_row["cbz_path"], folder_a)
            entries_b = scan_entries(lib_b_row["cbz_path"], folder_b) if folder_b else []

            set_a = {e["key"] for e in entries_a}
            set_b = {e["key"] for e in entries_b}

            missing_keys_in_b = set_a - set_b
            missing_keys_in_a = set_b - set_a

            missing_in_b = [e["display"] for e in entries_a if e["key"] in missing_keys_in_b]
            missing_in_a = [e["display"] for e in entries_b if e["key"] in missing_keys_in_a]

            same = bool(folder_b) and (not missing_in_b) and (not missing_in_a)

            rows.append({
                "key": (a.get("nautiljon_url") or _normalize_match_key(a.get("title") or folder_a or "") or folder_a),
                "a": {
                    "exists": True,
                    "folder": folder_a,
                    "title": a.get("title") or folder_a,
                    "cover_url": a.get("cover_url", ""),
                    "entries": entries_a,
                },
                "b": {
                    "exists": bool(folder_b),
                    "folder": folder_b or "",
                    "title": (b.get("title") if b else "") or "",
                    "cover_url": (b.get("cover_url") if b else "") or "",
                    "entries": entries_b,
                },
                "diff": {
                    "missing_in_b": missing_in_b,
                    "missing_in_a": missing_in_a,
                    "same": same,
                    "can_transfer_a_to_b": bool(missing_in_b) or (not folder_b),
                },
            })

        # Then: items only in B (destination-only), for visibility
        for b in sorted([r for r in b_items if r.get("cbz_folder") not in used_b_folders],
                        key=lambda r: (r.get("title") or r.get("cbz_folder") or "").lower()):
            folder = b.get("cbz_folder")
            entries_b = scan_entries(lib_b_row["cbz_path"], folder)
            rows.append({
                "key": (b.get("nautiljon_url") or _normalize_match_key(b.get("title") or folder or "") or folder),
                "a": {"exists": False, "title": "", "cover_url": "", "entries": []},
                "b": {
                    "exists": True,
                    "folder": folder,
                    "title": b.get("title") or folder,
                    "cover_url": b.get("cover_url", ""),
                    "entries": entries_b,
                },
                "diff": {"missing_in_b": [], "missing_in_a": [], "same": True, "can_transfer_a_to_b": False},
            })

        # Sort: prioritize "needs transfer" first, then alpha
        def sort_key(r):
            needs = 0 if r["diff"].get("can_transfer_a_to_b") else 1
            return (needs, (r.get("a", {}).get("title") or r.get("b", {}).get("title") or r.get("key") or "").lower())
        rows.sort(key=sort_key)

        return {
            "lib_a": {"id": lib_a_row["id"], "name": lib_a_row["name"], "cbz_path": lib_a_row["cbz_path"]},
            "lib_b": {"id": lib_b_row["id"], "name": lib_b_row["name"], "cbz_path": lib_b_row["cbz_path"]},
            "rows": rows,
        }

@app.post("/api/admin/libraries/copy-file")
def copy_file_between_libs(req: CopyFileRequest, admin=Depends(require_admin)):
    with get_db_ctx() as db:
        src_lib = db.execute("SELECT id, cbz_path FROM libraries WHERE id = ?", (req.from_lib,)).fetchone()
        dst_lib = db.execute("SELECT id, cbz_path FROM libraries WHERE id = ?", (req.to_lib,)).fetchone()
        if not src_lib or not dst_lib:
            raise HTTPException(404, "Bibliothèque introuvable")
        if not dst_lib["cbz_path"]:
            raise HTTPException(400, "La bibliothèque de destination n'a pas de chemin configuré")

        safe_folder   = Path(req.folder).name
        safe_filename = Path(req.filename).name

        src_file = Path(src_lib["cbz_path"]) / safe_folder / safe_filename
        dst_dir  = Path(dst_lib["cbz_path"]) / safe_folder
        dst_file = dst_dir / safe_filename

        if not src_file.exists():
            raise HTTPException(404, f"Fichier source introuvable: {src_file}")

        try:
            dst_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(src_file), str(dst_file))
        except Exception as e:
            raise HTTPException(500, f"Erreur lors de la copie: {e}")

        return {"ok": True, "filename": safe_filename, "dst": str(dst_file)}

@app.post("/api/admin/libraries/copy-folder")
def copy_folder_between_libs(req: CopyFolderRequest, admin=Depends(require_admin)):
    with get_db_ctx() as db:
        src_lib = db.execute("SELECT id, cbz_path FROM libraries WHERE id = ?", (req.from_lib,)).fetchone()
        dst_lib = db.execute("SELECT id, cbz_path FROM libraries WHERE id = ?", (req.to_lib,)).fetchone()
        if not src_lib or not dst_lib:
            raise HTTPException(404, "Bibliothèque introuvable")

        if not src_lib["cbz_path"]:
            raise HTTPException(400, "La bibliothèque source n'a pas de chemin configuré")
        if not dst_lib["cbz_path"]:
            raise HTTPException(400, "La bibliothèque de destination n'a pas de chemin configuré")

        safe_folder = Path(req.folder).name
        src_path = Path(src_lib["cbz_path"]) / safe_folder
        dst_path = Path(dst_lib["cbz_path"]) / safe_folder

        if not src_path.exists():
            raise HTTPException(404, f"Dossier source introuvable: {src_path}")
        if not dst_lib["cbz_path"]:
            raise HTTPException(400, "La bibliothèque de destination n'a pas de chemin configuré")

        try:
            _copytree_merge(src_path, dst_path)
        except Exception as e:
            raise HTTPException(500, f"Erreur lors de la copie: {e}")

        src_manga = db.execute(
            "SELECT * FROM manga_library WHERE cbz_folder = ? AND library_id = ?", (safe_folder, req.from_lib)
        ).fetchone()

        existing_dst = db.execute(
            "SELECT id FROM manga_library WHERE cbz_folder = ? AND library_id = ?", (safe_folder, req.to_lib)
        ).fetchone()

        if not existing_dst:
            if src_manga:
                db.execute("""
                    INSERT INTO manga_library
                    (cbz_folder, nautiljon_url, title, cover_url, synopsis, metadata_json, editions_json, match_status, library_id, synced_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    safe_folder,
                    src_manga["nautiljon_url"], src_manga["title"], src_manga["cover_url"],
                    src_manga["synopsis"], src_manga["metadata_json"], src_manga["editions_json"], src_manga["match_status"],
                    req.to_lib, time.time()
                ))
            else:
                db.execute(
                    "INSERT INTO manga_library (cbz_folder, title, match_status, library_id, synced_at) VALUES (?, ?, 'unmatched', ?, ?)",
                    (safe_folder, safe_folder, req.to_lib, time.time())
                )
        db.commit()
        return {"ok": True, "folder": safe_folder, "dst_path": str(dst_path)}


@app.post("/api/admin/libraries/transfer-manga")
def transfer_manga(req: CopyFolderRequest, admin=Depends(require_admin)):
    """Transfer a manga from one library to another.

    - If the manga folder doesn't exist in destination: copy the whole folder.
    - If it exists: copy only missing CBZ/CBR/ZIP files.
    Also ensures DB entry exists in destination (copies metadata from source entry when available).
    """
    with get_db_ctx() as db:
        src_lib = db.execute("SELECT id, cbz_path FROM libraries WHERE id = ?", (req.from_lib,)).fetchone()
        dst_lib = db.execute("SELECT id, cbz_path FROM libraries WHERE id = ?", (req.to_lib,)).fetchone()
        if not src_lib or not dst_lib:
            raise HTTPException(404, "Bibliothèque introuvable")
        if not src_lib["cbz_path"]:
            raise HTTPException(400, "La bibliothèque source n'a pas de chemin configuré")
        if not dst_lib["cbz_path"]:
            raise HTTPException(400, "La bibliothèque de destination n'a pas de chemin configuré")

        safe_src_folder = Path(req.folder).name
        safe_dst_folder = Path((req.dst_folder or req.folder)).name
        src_path = Path(src_lib["cbz_path"]) / safe_src_folder
        dst_path = Path(dst_lib["cbz_path"]) / safe_dst_folder
        if not src_path.exists() or not src_path.is_dir():
            raise HTTPException(404, f"Dossier source introuvable: {src_path}")

        cbz_exts = {".cbz", ".cbr", ".zip"}
        copied_files: list[str] = []
        mode = "diff"

        try:
            if not dst_path.exists():
                mode = "folder"
                copied_files = _copytree_merge(src_path, dst_path)
            else:
                # copy only missing tomes/chapitres (comparaison normalisée)
                dst_path.mkdir(parents=True, exist_ok=True)

                def _entry_key(p: Path) -> str:
                    info = _parse_cbz_info(p.stem, folder_name=p.parent.name)
                    vtype = info.get("type")
                    num = info.get("num")
                    return f"{vtype}:{num}" if vtype and num is not None else f"file:{p.name.lower()}"

                src_files = [p for p in src_path.iterdir() if p.is_file() and p.suffix.lower() in cbz_exts]
                dst_keys = {_entry_key(p) for p in dst_path.iterdir() if p.is_file() and p.suffix.lower() in cbz_exts}

                # On copie 1 fichier par "clé" manquante (tome:01, chapter:12, etc.)
                seen_keys: set[str] = set()
                for p in src_files:
                    k = _entry_key(p)
                    if k in seen_keys:
                        continue
                    seen_keys.add(k)
                    if k in dst_keys:
                        continue
                    shutil.copy2(str(p), str(dst_path / p.name))
                    copied_files.append(p.name)
        except Exception as e:
            raise HTTPException(500, f"Erreur lors du transfert: {e}")

        # Sync DB entry
        src_manga = db.execute(
            "SELECT * FROM manga_library WHERE cbz_folder = ? AND library_id = ?", (safe_src_folder, req.from_lib)
        ).fetchone()
        existing_dst = db.execute(
            "SELECT id FROM manga_library WHERE cbz_folder = ? AND library_id = ?", (safe_dst_folder, req.to_lib)
        ).fetchone()
        if not existing_dst:
            if src_manga:
                db.execute("""
                    INSERT INTO manga_library
                    (cbz_folder, nautiljon_url, title, cover_url, synopsis, metadata_json, editions_json, match_status, library_id, synced_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    safe_dst_folder,
                    src_manga["nautiljon_url"], src_manga["title"], src_manga["cover_url"],
                    src_manga["synopsis"], src_manga["metadata_json"], src_manga["editions_json"],
                    src_manga["match_status"],
                    req.to_lib, time.time()
                ))
            else:
                db.execute(
                    "INSERT INTO manga_library (cbz_folder, title, match_status, library_id, synced_at) VALUES (?, ?, 'unmatched', ?, ?)",
                    (safe_dst_folder, safe_dst_folder, req.to_lib, time.time())
                )
        db.commit()

        return {
            "ok": True,
            "folder": safe_src_folder,
            "dst_folder": safe_dst_folder,
            "mode": mode,
            "copied": copied_files,
            "dst_path": str(dst_path),
        }

    # ═══════════════════════════════════════════
    #  Routes: Profile
    # ═══════════════════════════════════════════

@app.post("/api/change-password")
def change_password(req: ChangePasswordRequest, user=Depends(get_current_user)):
    if not user["perms"]["canChangePassword"]:
        raise HTTPException(403, "Changement de mot de passe non autorisé")
    if len(req.new_password) < 4:
        raise HTTPException(400, "Nouveau mot de passe trop court")
    
    with get_db_ctx() as db:
        u = db.execute("SELECT password_hash FROM users WHERE id = ?", (user["id"],)).fetchone()
        if not verify_password(req.old_password, u["password_hash"]):
            raise HTTPException(400, "Ancien mot de passe incorrect")
    
        db.execute("UPDATE users SET password_hash = ? WHERE id = ?", (hash_password(req.new_password), user["id"]))
        db.commit()
        return {"ok": True}

    # ═══════════════════════════════════════════
    #  Routes: Nautiljon — via l'API HTTP publique de app.py (nautiljon_db.py)
    # ═══════════════════════════════════════════

@app.get("/api/nautiljon/health")
async def nautiljon_health(user=Depends(get_current_user)):
    if nautiljon_db.is_available():
        return {"status": "online", "db_path": nautiljon_db.APP_PY_URL}
    return {"status": "offline", "error": f"app.py injoignable ou base absente : {nautiljon_db.APP_PY_URL}"}

@app.get("/api/nautiljon/list")
async def nautiljon_list(
    limit: int = 48, offset: int = 0,
    user=Depends(get_current_user)
):
    return nautiljon_db.list_series(limit=limit, offset=offset)


@app.get("/api/library")
async def get_library(
    library_id: Optional[int] = None,
    limit: Optional[int] = None,
    offset: int = 0,
    search: Optional[str] = None,
    letter: Optional[str] = None,
    user=Depends(get_current_user),
):
    """Renvoie la bibliothèque locale. Supporte la pagination (limit/offset) et le filtre par recherche/lettre."""
    with get_db_ctx() as db:
        accessible_ids = get_user_library_ids(db, user["id"], user["role"])

        if library_id is not None:
            if library_id not in accessible_ids:
                raise HTTPException(403, "Accès refusé à cette bibliothèque")
            filter_ids = [library_id]
        else:
            filter_ids = accessible_ids

        if not filter_ids:
            return {"items": [], "total": 0, "alpha_index": {}, "unmatched": 0, "pending": 0}

        count = db.execute("SELECT COUNT(*) as c FROM manga_library").fetchone()["c"]
        if count == 0:
            # Auto-scan on first access
            try:
                await do_scan_cbz_folders()
            except Exception:
                pass
            accessible_ids = get_user_library_ids(db, user["id"], user["role"])
            filter_ids = [library_id] if library_id else accessible_ids

        placeholders = ",".join("?" * len(filter_ids))

        # Build WHERE clause
        where_parts = [f"library_id IN ({placeholders})"]
        args = list(filter_ids)

        if search:
            where_parts.append("(title LIKE ? OR cbz_folder LIKE ?)")
            args.extend([f"%{search}%", f"%{search}%"])

        if letter:
            if letter == "#":
                where_parts.append("UPPER(SUBSTR(title,1,1)) NOT BETWEEN 'A' AND 'Z'")
            else:
                where_parts.append("UPPER(SUBSTR(title,1,1)) = ?")
                args.append(letter.upper())

        where_clause = " AND ".join(where_parts)

        # Get total count (before pagination)
        total = db.execute(
            f"SELECT COUNT(DISTINCT cbz_folder) as c FROM manga_library WHERE {where_clause}", args
        ).fetchone()["c"]

        # Alpha index (always computed on full set, ignoring pagination)
        alpha_rows = db.execute(
            f"SELECT UPPER(SUBSTR(title,1,1)) as letter, COUNT(DISTINCT cbz_folder) as cnt "
            f"FROM manga_library WHERE {where_clause} GROUP BY letter",
            args
        ).fetchall()
        alpha_index = {}
        for ar in alpha_rows:
            k = ar["letter"] if ar["letter"] and ar["letter"].isalpha() else "#"
            alpha_index[k] = alpha_index.get(k, 0) + ar["cnt"]

        # Status counts (full set)
        status_rows = db.execute(
            f"SELECT match_status, COUNT(DISTINCT cbz_folder) as cnt FROM manga_library WHERE {where_clause} GROUP BY match_status",
            args
        ).fetchall()
        unmatched = 0
        pending = 0
        for sr in status_rows:
            if sr["match_status"] == "unmatched":
                unmatched = sr["cnt"]
            elif sr["match_status"] == "pending":
                pending = sr["cnt"]

        # Main query with optional pagination
        order = "ORDER BY library_id ASC, title COLLATE NOCASE"
        limit_clause = ""
        if limit is not None and limit > 0:
            limit_clause = f" LIMIT {int(limit)} OFFSET {int(offset)}"

        rows = db.execute(
            f"SELECT id, cbz_folder, nautiljon_url, title, cover_url, synopsis, metadata_json, match_status, library_id "
            f"FROM manga_library WHERE {where_clause} {order}{limit_clause}",
            args
        ).fetchall()

        # Pre-compute volume types
        vol_types = {}
        try:
            vt_rows = db.execute("SELECT cbz_folder, volume_type FROM manga_volumes WHERE volume_type IS NOT NULL").fetchall()
            for vr in vt_rows:
                vol_types.setdefault(vr["cbz_folder"], set()).add(vr["volume_type"])
        except Exception:
            pass

    # Build response (outside DB context)
    items = []
    seen_folders = set()
    for r in rows:
        if library_id is None and r["cbz_folder"] in seen_folders:
            continue
        seen_folders.add(r["cbz_folder"])
        try:
            meta = json.loads(r["metadata_json"] or "{}")
        except Exception:
            meta = {}
        folder_types = vol_types.get(r["cbz_folder"], set())
        is_oneshot = "oneshot" in folder_types
        if not is_oneshot:
            type_str = str(meta.get("Type", "") or "").lower()
            if "one shot" in type_str or "one-shot" in type_str or "oneshot" in type_str:
                is_oneshot = True

        items.append({
            "id": r["id"],
            "cbz_folder": r["cbz_folder"],
            "nautiljon_url": r["nautiljon_url"] or "",
            "title": r["title"],
            "cover_url": r["cover_url"] or "",
            "synopsis": (r["synopsis"] or "")[:100],
            "match_status": r["match_status"],
            "metadata_json": meta,
            "library_id": r["library_id"],
            "has_tomes": "tome" in folder_types,
            "has_chapters": "chapter" in folder_types,
            "has_oneshots": "oneshot" in folder_types,
            "is_oneshot": is_oneshot,
        })

    return {
        "items": items,
        "total": total,
        "alpha_index": alpha_index,
        "unmatched": unmatched,
        "pending": pending,
        "limit": limit,
        "offset": offset,
        "has_more": (offset + len(items)) < total if limit else False,
    }


@app.get("/api/library/{manga_id}")
async def get_library_manga(manga_id: int, user=Depends(get_current_user)):
    """Renvoie les détails complets d'un manga de la bibliothèque."""
    with get_db_ctx() as db:
        row = db.execute("""
            SELECT id, cbz_folder, nautiljon_url, title, cover_url, synopsis,
                   metadata_json, editions_json, match_status, match_candidates_json,
                   library_id, synced_at,
                   CASE WHEN cover_blob IS NOT NULL THEN 1 ELSE 0 END as has_cover
            FROM manga_library WHERE id = ?
        """, (manga_id,)).fetchone()
        if not row:
            raise HTTPException(404, "Manga introuvable")
    
        result = dict(row)
        try: result["metadata_json"] = json.loads(result["metadata_json"] or "{}")
        except: result["metadata_json"] = {}
        try: result["editions_json"] = json.loads(result["editions_json"] or "[]")
        except: result["editions_json"] = []
        try: result["match_candidates_json"] = json.loads(result["match_candidates_json"] or "[]")
        except: result["match_candidates_json"] = []
    
        return result


async def do_scan_cbz_folders(library_id: Optional[int] = None):
    """Scanne les dossiers CBZ et insere dans manga_library.

    Cherche recursivement les dossiers contenant des .cbz/.cbr/.zip ou
    des sous-dossiers chapitre (format 'y x z', ex: 1x5).
    
    Gere les structures :
      - base/Manga/T01.cbz               (profondeur 1)
      - base/Genre/Manga/T01.cbz         (profondeur 2)
      - base/Manga/1x5/images...         (dossiers chapitres)

    cbz_folder stocke le chemin relatif depuis la base : "Manga" ou "Genre/Manga"
    """
    with get_db_ctx() as db:

        if library_id is not None:
            lib_row = db.execute("SELECT id, cbz_path FROM libraries WHERE id = ?", (library_id,)).fetchone()
            if not lib_row:
                return 0
            libs = [{"id": lib_row["id"], "cbz_path": lib_row["cbz_path"]}]
        else:
            lib_rows = db.execute("SELECT id, cbz_path FROM libraries").fetchall()
            libs = [{"id": r["id"], "cbz_path": r["cbz_path"]} for r in lib_rows]
            if not libs:
                base = get_cbz_path(db)
                if not base:
                    return 0
                default_lib = db.execute("SELECT id FROM libraries ORDER BY id LIMIT 1").fetchone()
                if default_lib:
                    libs = [{"id": default_lib["id"], "cbz_path": base}]


        cbz_exts = {".cbz", ".cbr", ".zip"}

        def _is_manga_dir(d: Path) -> Optional[str]:
            """Verifie si un dossier contient des CBZ ou des chapitres images.
            Retourne le type: 'cbz', 'images', 'mixed', ou None."""
            if not d.is_dir():
                return None
            has_cbz = False
            has_img_ch = False
            for item in d.iterdir():
                if item.is_file() and item.suffix.lower() in cbz_exts:
                    has_cbz = True
                elif item.is_dir() and _parse_images_chapter_dirname(item.name):
                    has_img_ch = True
                if has_cbz and has_img_ch:
                    break
            if has_cbz and has_img_ch:
                return "mixed"
            if has_cbz:
                return "cbz"
            if has_img_ch:
                return "images"
            return None

        count = 0
        for lib in libs:
            base = lib["cbz_path"]
            lib_id_val = lib["id"]
            if not base:
                continue
            base_path = Path(base)
            if not base_path.exists():
                continue

            # Scan recursif: profondeur 1 et 2
            manga_dirs = []  # [(relative_path, source_type)]

            for d in sorted(base_path.iterdir()):
                if not d.is_dir() or d.name.startswith("."):
                    continue
            
                src = _is_manga_dir(d)
                if src:
                    # Profondeur 1: base/Manga/T01.cbz
                    manga_dirs.append((d.name, src))
                else:
                    # Profondeur 2: base/Genre/Manga/T01.cbz
                    try:
                        for sub in sorted(d.iterdir()):
                            if not sub.is_dir() or sub.name.startswith("."):
                                continue
                            sub_src = _is_manga_dir(sub)
                            if sub_src:
                                rel = f"{d.name}/{sub.name}"
                                manga_dirs.append((rel, sub_src))
                    except PermissionError:
                        pass

            db2 = get_db()
            for (rel_path, source_type) in manga_dirs:
                # Le titre affiche = le dernier segment du chemin
                display_title = Path(rel_path).name

                existing = db2.execute(
                    "SELECT id, library_id FROM manga_library WHERE cbz_folder = ?",
                    (rel_path,),
                ).fetchone()

                if not existing:
                    meta = {"source": source_type}
                    db2.execute(
                        "INSERT INTO manga_library (cbz_folder, title, match_status, library_id, synced_at, metadata_json) "
                        "VALUES (?, ?, 'unmatched', ?, ?, ?)",
                        (rel_path, display_title, lib_id_val, time.time(), json.dumps(meta, ensure_ascii=False))
                    )
                    count += 1
                else:
                    # Verifier que la bibliotheque liee existe encore
                    old_lib = db2.execute("SELECT id FROM libraries WHERE id = ?", (existing["library_id"],)).fetchone()
                    if not old_lib:
                        db2.execute("UPDATE manga_library SET library_id = ? WHERE id = ?", (lib_id_val, existing["id"]))
                        count += 1

            db2.commit()
            db2.close()
        return count


def _scan_volumes_for_library(lib_id: int, cbz_path: str):
    """Scanne tous les tomes/chapitres d'une bibliothèque et les stocke dans manga_volumes.
    
    Stocke: filepath, volume_num, total_pages, file_size, chapters
    Extrait: cover_blob du manga (depuis le T01 uniquement)
    NE stocke PAS: thumbnail_blob de chaque tome (trop lourd, servi à la volée)
    """
    # Invalidate keyword cache to pick up any config changes
    _kw_cache["tome"] = None
    _kw_cache["ts"] = 0
    base_path = Path(cbz_path)
    if not base_path.exists():
        return 0
    
    cbz_exts = {".cbz", ".cbr", ".zip"}
    img_exts = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}
    with get_db_ctx() as db:
    
        all_mangas = db.execute("SELECT id, cbz_folder FROM manga_library").fetchall()
    
        count = 0
        for manga_row in all_mangas:
            manga_id = manga_row["id"]
            folder = manga_row["cbz_folder"]
            target = base_path / folder
            if not target.exists() or not target.is_dir():
                continue
        
            first_vol_path = None  # Pour extraire la cover manga du T01
            first_vol_num = 9999
        
            for f in target.iterdir():
                # ── Archives (.cbz, .cbr, .zip) ──
                if f.is_file() and f.suffix.lower() in cbz_exts:
                    info = _parse_cbz_info(f.stem, folder_name=folder)
                    if info["type"] == "oneshot":
                        print(f"[Scan] ONESHOT detected: {f.name} in {folder}")
                    filepath = str(Path(folder) / f.name).replace("\\", "/")
                    existing = db.execute(
                        "SELECT id, total_pages FROM manga_volumes WHERE cbz_folder = ? AND library_id = ? AND filename = ?",
                        (folder, lib_id, f.name)
                    ).fetchone()
                
                    if not existing:
                        pages = _count_pages_cbz(f)
                        db.execute(
                            "INSERT INTO manga_volumes (cbz_folder, library_id, filename, filepath, volume_num, volume_type, volume_display, source, file_size, total_pages, scanned_at) "
                            "VALUES (?, ?, ?, ?, ?, ?, ?, 'archive', ?, ?, ?)",
                            (folder, lib_id, f.name, filepath, info["num"], info["type"], info["display"], f.stat().st_size, pages, time.time())
                        )
                        count += 1
                    else:
                        # Always update volume_type/display in case keywords changed
                        db.execute(
                            "UPDATE manga_volumes SET volume_num = ?, volume_type = ?, volume_display = ? WHERE id = ?",
                            (info["num"], info["type"], info["display"], existing["id"])
                        )
                        if not existing["total_pages"]:
                            pages = _count_pages_cbz(f)
                            db.execute("UPDATE manga_volumes SET total_pages = ? WHERE id = ?", (pages, existing["id"]))
                
                    # Retenir le T01 pour la cover manga
                    vol_n = info["num"] or 9999
                    if vol_n < first_vol_num:
                        first_vol_num = vol_n
                        first_vol_path = f
            
                # ── Dossiers chapitres images ──
                elif f.is_dir() and not f.name.startswith("."):
                    ch_info = _parse_images_chapter_dirname(f.name)
                    if not ch_info:
                        continue
                    v = ch_info["tome"]
                    ch = ch_info["chapter"]
                    vol_name = f"Tome {v:02d} (images)"
                    filepath = f"imgvol:{folder}:{v}"
                
                    ch_pages = len([p for p in f.iterdir() if p.is_file() and p.suffix.lower() in img_exts])
                
                    existing = db.execute(
                        "SELECT id, chapters_json, total_pages FROM manga_volumes WHERE cbz_folder = ? AND library_id = ? AND filepath = ?",
                        (folder, lib_id, filepath)
                    ).fetchone()
                
                    if not existing:
                        db.execute(
                            "INSERT INTO manga_volumes (cbz_folder, library_id, filename, filepath, volume_num, volume_type, volume_display, source, file_size, total_pages, chapters_json, scanned_at) "
                            "VALUES (?, ?, ?, ?, ?, 'tome', ?, 'images', 0, ?, ?, ?)",
                            (folder, lib_id, vol_name, filepath, v, f"Tome {v:02d}", ch_pages, json.dumps([ch]), time.time())
                        )
                        count += 1
                    
                        if v < first_vol_num and ch == 1:
                            first_vol_num = v
                            first_vol_path = f  # dossier images
                    else:
                        try:
                            chapters = json.loads(existing["chapters_json"] or "[]")
                        except:
                            chapters = []
                        if ch not in chapters:
                            chapters.append(ch)
                            chapters.sort()
                        new_total = (existing["total_pages"] or 0) + ch_pages
                        db.execute(
                            "UPDATE manga_volumes SET chapters_json = ?, total_pages = ? WHERE id = ?",
                            (json.dumps(chapters), new_total, existing["id"])
                        )
        
            # Extraire et stocker la cover manga (depuis le T01) si pas déjà faite
            if first_vol_path:
                has_cover = db.execute("SELECT cover_blob FROM manga_library WHERE id = ? AND cover_blob IS NOT NULL", (manga_id,)).fetchone()
                if not has_cover or not has_cover["cover_blob"]:
                    raw_img = None
                    if first_vol_path.is_file():
                        raw_img = _extract_first_image_from_cbz(first_vol_path)
                    elif first_vol_path.is_dir():
                        raw_img = _extract_first_image_from_imgdir(first_vol_path)
                    if raw_img:
                        cover = _make_thumbnail_bytes(raw_img, HOME_COVER_WIDTH, HOME_COVER_HEIGHT)
                        if cover:
                            db.execute("UPDATE manga_library SET cover_blob = ? WHERE id = ?", (cover, manga_id))
    
        db.commit()
        return count


@app.post("/api/admin/scan-folders")
async def admin_scan_folders(library_id: Optional[int] = None, admin=Depends(require_admin)):
    """Scanne les dossiers CBZ, ajoute les nouveaux, et indexe les tomes."""
    count = await do_scan_cbz_folders(library_id)
    
    # Scanner les volumes de toutes les bibliothèques
    with get_db_ctx() as db:
        if library_id is not None:
            libs = db.execute("SELECT id, cbz_path FROM libraries WHERE id = ?", (library_id,)).fetchall()
        else:
            libs = db.execute("SELECT id, cbz_path FROM libraries").fetchall()
    
        vol_count = 0
        for lib in libs:
            if lib["cbz_path"]:
                vol_count += _scan_volumes_for_library(lib["id"], lib["cbz_path"])
    
        return {"added": count, "volumes_indexed": vol_count}


@app.post("/api/admin/rescan-types")
def admin_rescan_types(admin=Depends(require_admin)):
    """Re-parse tous les volume_type/display sans re-scanner les fichiers.
    Rapide : ne touche que les métadonnées de parsing (tome/chapitre/oneshot).
    """
    # Invalidate keyword cache
    _kw_cache["tome"] = None
    _kw_cache["ts"] = 0

    with get_db_ctx() as db:
        rows = db.execute(
            "SELECT v.id, v.filename, v.cbz_folder FROM manga_volumes v"
        ).fetchall()

        updated = 0
        for r in rows:
            info = _parse_cbz_info(r["filename"].rsplit(".", 1)[0] if "." in r["filename"] else r["filename"],
                                   folder_name=r["cbz_folder"])
            db.execute(
                "UPDATE manga_volumes SET volume_num = ?, volume_type = ?, volume_display = ? WHERE id = ?",
                (info["num"], info["type"], info["display"], r["id"])
            )
            updated += 1

        db.commit()
        print(f"[Rescan-types] Updated {updated} volumes")
        return {"updated": updated}


@app.get("/api/admin/detect-duplicates")
def detect_duplicates(admin=Depends(require_admin)):
    """Détecte les dossiers qui sont probablement le même manga (éditions différentes).
    Ex: 'Breaker (The)' et 'Breaker (The) - Edition ultimate'
    """
    import difflib
    with get_db_ctx() as db:
        rows = db.execute("SELECT id, cbz_folder, title, match_status, nautiljon_url FROM manga_library ORDER BY cbz_folder").fetchall()

        def normalize(name):
            """Normalize folder name for comparison."""
            n = name.lower().strip()
            # Remove edition/version suffixes
            for sep in [" - edition", " - édition", " edition", " édition", " - version", " - deluxe", " - perfect", " - ultimate", " - collector"]:
                if sep in n:
                    n = n[:n.index(sep)]
            # Remove parenthetical info
            n = re.sub(r'\([^)]*\)', '', n).strip()
            # Remove extra whitespace
            n = re.sub(r'\s+', ' ', n).strip()
            return n

        # Group by normalized name
        groups = {}
        for r in rows:
            key = normalize(r["cbz_folder"])
            if key not in groups:
                groups[key] = []
            groups[key].append(dict(r))

        # Return only groups with 2+ entries
        duplicates = []
        for key, items in groups.items():
            if len(items) >= 2:
                # Find the "main" one (matched, or most tomes)
                duplicates.append({
                    "key": key,
                    "items": items,
                    "count": len(items),
                })

        duplicates.sort(key=lambda d: d["key"])
        return {"duplicates": duplicates, "total": len(duplicates)}


@app.post("/api/admin/merge-mangas")
def merge_mangas(keep_id: int, merge_ids: str, admin=Depends(require_admin)):
    """Fusionne des mangas : déplace les volumes des merge_ids vers keep_id et supprime les merge_ids.
    merge_ids: comma-separated list of IDs to merge into keep_id.
    """
    with get_db_ctx() as db:
        keep = db.execute("SELECT * FROM manga_library WHERE id = ?", (keep_id,)).fetchone()
        if not keep:
            raise HTTPException(404, "Manga principal introuvable")

        ids = [int(x.strip()) for x in merge_ids.split(",") if x.strip().isdigit()]
        merged_count = 0

        for mid in ids:
            if mid == keep_id:
                continue
            source = db.execute("SELECT * FROM manga_library WHERE id = ?", (mid,)).fetchone()
            if not source:
                continue

            # Move volumes from source to keep
            db.execute(
                "UPDATE manga_volumes SET cbz_folder = ? WHERE cbz_folder = ?",
                (keep["cbz_folder"], source["cbz_folder"])
            )

            # Delete the source manga entry
            db.execute("DELETE FROM manga_library WHERE id = ?", (mid,))
            merged_count += 1

        db.commit()
        return {"ok": True, "merged": merged_count}


@app.post("/api/admin/auto-match")
async def auto_match(admin=Depends(require_admin)):
    """Matching auto : pour chaque manga 'unmatched', cherche sur Nautiljon.
    
    - Match 100% exact sur le titre → statut 'matched', métadonnées enregistrées
    - Pas exact → statut 'pending' avec les candidats, à valider manuellement
    """
    with get_db_ctx() as db:
        base = get_cbz_path(db)

        # 'pending' = recherche précédente n'ayant RIEN trouvé (candidats vides, voir plus
        # bas) : on les retente à chaque auto-match, comme les 'unmatched', puisqu'un
        # échec passé peut simplement venir d'une requête de recherche mal construite
        # (corrigée depuis) plutôt que d'une série absente de Nautiljon.
        unmatched = db.execute("""
            SELECT id, cbz_folder, title FROM manga_library
            WHERE match_status IN ('unmatched', 'pending')
        """).fetchall()

        if not nautiljon_db.is_available():
            return {"error": f"Base Nautiljon injoignable via {nautiljon_db.APP_PY_URL}"}

        auto_matched = 0
        not_found = 0
        errors = 0
        pending = 0

        for row in unmatched:
            manga_id = row["id"]
            folder = row["cbz_folder"]
            # Le titre (dernier segment du chemin, ex: "20th Century Boys - Perfect
            # Edition") -- PAS le chemin complet (folder), qui contient un "/" pour les
            # mangas rangés dans un sous-dossier (édition, genre...) et donnerait une
            # requête de recherche absurde ("Genre/Manga") ne matchant jamais rien.
            titre_base = (row["title"] or Path(folder).name or folder).strip()

            try:
                results = []
                queries = _match_query_variants(titre_base)
                # Variante sans suffixe d'édition (ex: "20th Century Boys - Perfect
                # Edition" -> "20th Century Boys") : Nautiljon référence la série une
                # seule fois, les éditions physiques sur le disque n'ont pas forcément de
                # fiche à leur propre nom.
                titre_sans_edition = _strip_edition_suffix(titre_base)
                if titre_sans_edition and titre_sans_edition != titre_base:
                    for q in _match_query_variants(titre_sans_edition):
                        if q not in queries:
                            queries.append(q)
                folder_keys = {k for k in (_normalize_match_key(v) for v in queries) if k}

                def _append_unique(rows):
                    for item in (rows or []):
                        key = (item.get("url") or "").strip() or (item.get("title") or "").strip().lower()
                        if not key:
                            continue
                        if any((((r.get("url") or "").strip() or (r.get("title") or "").strip().lower()) == key) for r in results):
                            continue
                        results.append(item)

                exact_match = None
                for q in queries:
                    query_results = nautiljon_db.search_local(q, limit=8, offset=0).get("results") or []
                    _append_unique(query_results)

                    # Vérifier un match exact après chaque variante de requête
                    for res in query_results:
                        res_title = _normalize_match_key(res.get("title") or "")
                        if res_title in folder_keys:
                            exact_match = res
                            break
                    if exact_match:
                        break

                if not results:
                    # Rien trouvé du tout
                    db2 = get_db()
                    db2.execute("UPDATE manga_library SET match_status = 'pending', match_candidates_json = '[]' WHERE id = ?", (manga_id,))
                    db2.commit()
                    db2.close()
                    pending += 1
                    continue

                # Chercher un match 100% exact (case-insensitive, strip)
                if not exact_match:
                    for res in results:
                        res_title = _normalize_match_key(res.get("title") or "")
                        if res_title in folder_keys:
                            exact_match = res
                            break

                if exact_match:
                    # Match 100% → fetch les détails et enregistrer
                    nautiljon_url = exact_match.get("url", "")
                    _store_details(manga_id, nautiljon_url, exact_match.get("title", folder))
                    auto_matched += 1
                else:
                    # Pas exact → reste unmatched, l'admin cherchera manuellement
                    not_found += 1

            except Exception as e:
                errors += 1

        # Générer les covers CBZ
        covers = 0
        db3 = get_db()
        all_folders = db3.execute("SELECT cbz_folder FROM manga_library").fetchall()
        all_libs = db3.execute("SELECT id, cbz_path FROM libraries ORDER BY id ASC").fetchall()
        db3.close()
        for row in all_folders:
            folder = row["cbz_folder"]
            safe = _safe_filename(folder)
            if any((COVERS_DIR / f"{safe}{ext}").exists() for ext in (".jpg", ".png", ".webp")):
                continue
            # Trouver le base path
            folder_base = None
            for lib in all_libs:
                if lib["cbz_path"] and (Path(lib["cbz_path"]) / folder).exists():
                    folder_base = lib["cbz_path"]
                    break
            if not folder_base:
                folder_base = base
            if folder_base and _extract_folder_cover(folder_base, folder):
                covers += 1

        return {"auto_matched": auto_matched, "not_found": not_found, "errors": errors, "covers": covers}


def _store_details(manga_id, nautiljon_url, title):
    """Récupère les détails Nautiljon (accès direct à la vraie base, voir
    nautiljon_db.manga_auto) et les stocke dans manga_library. Renvoie True si une fiche
    a bien été trouvée et enregistrée, False si cette série n'est pas (encore) dans la
    base locale."""
    details = nautiljon_db.manga_auto(nautiljon_url)
    if not details:
        return False

    cover_url = details.get("cover_url") or details.get("image_url") or ""
    raw_infos = details.get("raw_infos_json") or {}
    synopsis = details.get("synopsis") or details.get("description") or ""
    editions = details.get("editions_json") or []

    with get_db_ctx() as db:
        db.execute("""
            UPDATE manga_library SET
                nautiljon_url = ?, title = ?, cover_url = ?, synopsis = ?,
                metadata_json = ?, editions_json = ?,
                match_status = 'matched', match_candidates_json = '[]', synced_at = ?
            WHERE id = ?
        """, (
            nautiljon_url,
            details.get("title") or title,
            cover_url,
            synopsis,
            json.dumps(raw_infos if raw_infos else details, ensure_ascii=False),
            json.dumps(editions if isinstance(editions, list) else [], ensure_ascii=False),
            time.time(),
            manga_id
        ))
        db.commit()
    return True


@app.post("/api/admin/validate-match/{manga_id}")
async def validate_match(manga_id: int, nautiljon_url: str, admin=Depends(require_admin)):
    """Valide manuellement un match : récupère les détails et enregistre."""
    with get_db_ctx() as db:
        row = db.execute("SELECT * FROM manga_library WHERE id = ?", (manga_id,)).fetchone()
        if not row:
            raise HTTPException(404, "Manga introuvable")

    trouve = _store_details(manga_id, nautiljon_url, row["title"])
    if not trouve:
        raise HTTPException(404, "Cette série n'est pas dans la base Nautiljon locale.")
    return {"ok": True}


@app.post("/api/admin/reset-match/{manga_id}")
async def reset_match(manga_id: int, admin=Depends(require_admin)):
    """Remet un manga en status unmatched pour pouvoir le re-matcher."""
    with get_db_ctx() as db:
        row = db.execute("SELECT * FROM manga_library WHERE id = ?", (manga_id,)).fetchone()
        if not row:
            raise HTTPException(404)
        db.execute("""
            UPDATE manga_library SET 
                nautiljon_url = '', cover_url = '', synopsis = '',
                metadata_json = '{}', editions_json = '[]',
                match_status = 'unmatched', match_candidates_json = '[]'
            WHERE id = ?
        """, (manga_id,))
        db.commit()
        return {"ok": True}


@app.post("/api/admin/create-manual/{manga_id}")
async def create_manual_entry(manga_id: int, admin=Depends(require_admin)):
    """Crée une fiche manuelle pour un manga sans résultat Nautiljon.
    
    Body JSON: { title, synopsis, metadata_json }
    """
    from starlette.requests import Request
    with get_db_ctx() as db:
        row = db.execute("SELECT * FROM manga_library WHERE id = ?", (manga_id,)).fetchone()
        if not row:
            raise HTTPException(404, "Manga introuvable")
        return {"ok": True, "id": manga_id}


@app.put("/api/admin/manga/{manga_id}")
async def update_manga_manual(manga_id: int, request: Request, admin=Depends(require_admin)):
    """Met à jour manuellement les métadonnées d'un manga."""
    body = await request.json()
    
    with get_db_ctx() as db:
        row = db.execute("SELECT * FROM manga_library WHERE id = ?", (manga_id,)).fetchone()
        if not row:
            raise HTTPException(404)
    
        updates = []
        params = []
        for field in ["title", "synopsis", "cover_url", "nautiljon_url"]:
            if field in body:
                updates.append(f"{field} = ?")
                params.append(body[field])
        if "metadata_json" in body:
            updates.append("metadata_json = ?")
            params.append(json.dumps(body["metadata_json"], ensure_ascii=False) if isinstance(body["metadata_json"], dict) else body["metadata_json"])
    
        if updates:
            updates.append("match_status = 'manual'")
            updates.append("synced_at = ?")
            params.append(time.time())
            params.append(manga_id)
            db.execute(f"UPDATE manga_library SET {', '.join(updates)} WHERE id = ?", params)
            db.commit()
        return {"ok": True}


    # ═══════════════════════════════════════════
    #  Replace CBZ cover with Nautiljon edition cover
    # ═══════════════════════════════════════════

@app.post("/api/admin/replace-cbz-cover")
async def replace_cbz_cover(
    cbz_path: str,       # ex: "D.N.Angel/D.N.Angel T01 (blabla).cbz"
    cover_url: str,       # URL Nautiljon de la cover
    admin=Depends(require_admin)
):
    """Remplace la première image d'un CBZ par une cover téléchargée depuis Nautiljon.
    
    Ça permet de :
    1. Choisir l'édition (FR, JP, US) dont on veut la cover
    2. Cliquer sur un volume → sa cover remplace la 1ère image du CBZ
    3. Si c'est le T01, la cover d'accueil change aussi
    """
    with get_db_ctx() as db:
        folder = folder_from_filepath(cbz_path)
        base = get_library_cbz_path_for_folder(db, folder) if folder else get_cbz_path(db)

        if not base:
            raise HTTPException(400, "Chemin CBZ non configuré")

        full_path = Path(base) / cbz_path
        if not full_path.exists():
            raise HTTPException(404, f"CBZ introuvable: {cbz_path}")
    
        # 1. Récupérer la cover : soit une image Nautiljon (URL de la forme
        # /api/nautiljon/img/...), qu'on va chercher en HTTP chez app.py -- soit, pour
        # compatibilité avec une URL externe collée à la main, un téléchargement HTTP
        # classique. Les deux cas se résument à un simple GET HTTP.
        if cover_url.startswith(nautiljon_db.IMAGE_ROUTE_PREFIX):
            relatif = cover_url[len(nautiljon_db.IMAGE_ROUTE_PREFIX):].lstrip("/")
            fetch_url = f"{nautiljon_db.APP_PY_URL}/{relatif}"
        else:
            fetch_url = cover_url
        try:
            async with httpx.AsyncClient(timeout=30) as client:
                r = await client.get(fetch_url)
                r.raise_for_status()
                cover_data = r.content
                cover_ext = Path(fetch_url.split("?")[0]).suffix.lower() or ".jpg"
                if cover_ext not in (".jpg", ".jpeg", ".png", ".webp"):
                    cover_ext = ".jpg"
        except Exception as e:
            raise HTTPException(400, f"Impossible de télécharger la cover: {e}")
    
        # 2. Modifier le CBZ (zip)
        try:
            # NB: on évite toute écriture partielle sur le fichier original.
            # On reconstruit l'archive dans un fichier temporaire puis on remplace atomiquement.
            import tempfile, shutil

            temp_path = full_path.with_suffix(".tmp.cbz")

            with zipfile.ZipFile(str(full_path), "r") as zf_in:
                image_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}
                images = sorted([
                    n for n in zf_in.namelist()
                    if Path(n).suffix.lower() in image_exts
                    and not n.startswith("__MACOSX")
                    and not Path(n).name.startswith(".")
                ])
            
                if not images:
                    raise HTTPException(400, "Aucune image dans le CBZ")
            
                first_image = images[0]
                # Garder le même nom mais avec la bonne extension
                new_name = Path(first_image).with_suffix(cover_ext)
                # Si l'extension change, on garde l'ancien nom
                if cover_ext != Path(first_image).suffix.lower():
                    new_name = str(first_image)  # garder le nom original
                else:
                    new_name = str(new_name)
            
                with zipfile.ZipFile(str(temp_path), "w", zipfile.ZIP_DEFLATED) as zf_out:
                    for item in zf_in.namelist():
                        if item == first_image:
                            # Remplacer par la cover téléchargée
                            zf_out.writestr(first_image, cover_data)
                        else:
                            zf_out.writestr(item, zf_in.read(item))
        
            # 3. Remplacer le fichier original
            shutil.move(str(temp_path), str(full_path))
        
            # 4. Invalider le cache cover du dossier
            folder = full_path.parent.name
            safe = _safe_filename(folder)
            for ext in (".jpg", ".png", ".webp"):
                cached = COVERS_DIR / f"{safe}{ext}"
                if cached.exists():
                    cached.unlink()
        
            # 5. Regénérer la cover du dossier si c'est le T01
            vol_num = _parse_volume_number(full_path.stem)
            if vol_num == 1 or vol_num is None:
                _extract_folder_cover(base, folder)
        
            return {"ok": True, "replaced": first_image, "cbz": cbz_path}
        except Exception as e:
            # Nettoyage et message explicite
            try:
                if 'temp_path' in locals() and temp_path.exists():
                    temp_path.unlink()
            except Exception:
                pass
            raise HTTPException(500, f"Erreur lors de la mise à jour du CBZ: {e}")


def _has_bin(cmd: str) -> bool:
    try:
        return shutil.which(cmd) is not None
    except Exception:
        return False


def _convert_cbr_to_cbz(full_cbr_path: Path) -> Path:
    """Convertit un fichier .cbr en .cbz (ZIP) dans le même dossier.

    - Conserve l'arborescence interne.
    - Ne supprime pas le .cbr.
    - Écrase le .cbz uniquement si il n'existe pas déjà.
    """
    if full_cbr_path.suffix.lower() != ".cbr":
        raise ValueError("Le fichier n'est pas un .cbr")

    if not _has_bin(SEVEN_Z_BIN):
        raise HTTPException(500, f"Outil manquant: {SEVEN_Z_BIN} (installe p7zip-full)")
    if not _has_bin(ZIP_BIN):
        raise HTTPException(500, f"Outil manquant: {ZIP_BIN} (installe zip)")

    out_cbz = full_cbr_path.with_suffix(".cbz")
    if out_cbz.exists():
        return out_cbz

    tmpdir = Path(tempfile.mkdtemp(prefix="tamashelf_cbr_"))
    try:
        # Extraction
        p = subprocess.run(
            [SEVEN_Z_BIN, "x", "-y", f"-o{str(tmpdir)}", str(full_cbr_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if p.returncode != 0:
            raise HTTPException(500, f"Conversion CBR→CBZ: extraction 7z échouée: {p.stderr[:300].decode('utf-8','ignore')}")

        # Repack en CBZ
        # -0: store (rapide) ; -q: quiet ; -r: recursive
        p2 = subprocess.run(
            [ZIP_BIN, "-q", "-0", "-r", str(out_cbz), "."],
            cwd=str(tmpdir),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if p2.returncode != 0 or not out_cbz.exists():
            raise HTTPException(500, f"Conversion CBR→CBZ: zip échoué: {p2.stderr[:300].decode('utf-8','ignore')}")

        return out_cbz
    finally:
        try:
            shutil.rmtree(tmpdir, ignore_errors=True)
        except Exception:
            pass


@app.get("/api/admin/cbr-missing-cbz")
def admin_cbr_missing_cbz(user=Depends(require_admin)):
    """Retourne la liste des .cbr présents dans la bibliothèque qui n'ont pas de .cbz homonyme."""
    with get_db_ctx() as db:
        libs = db.execute("SELECT id, cbz_path FROM libraries").fetchall()

        items = []
        can_convert = _has_bin(SEVEN_Z_BIN) and _has_bin(ZIP_BIN)

        for lib in libs:
            base = lib["cbz_path"]
            if not base:
                continue
            basep = Path(base)
            if not basep.exists():
                continue
            for folder in sorted([d for d in basep.iterdir() if d.is_dir()], key=lambda p: p.name.lower()):
                for cbr in sorted([f for f in folder.iterdir() if f.is_file() and f.suffix.lower() == ".cbr"], key=lambda p: p.name.lower()):
                    cbz = cbr.with_suffix(".cbz")
                    if not cbz.exists():
                        rel_cbr = str(cbr.relative_to(basep)).replace('\\', '/')
                        rel_cbz = str(cbz.relative_to(basep)).replace('\\', '/')
                        items.append({
                            "folder": folder.name,
                            "cbr_path": rel_cbr,
                            "expected_cbz_path": rel_cbz,
                            "filename": cbr.name,
                            "library_id": lib["id"],
                        })
        return {"ok": True, "items": items, "can_convert": can_convert}


class ConvertCbrRequest(BaseModel):
    cbr_path: str


@app.post("/api/admin/convert-cbr-to-cbz")
def admin_convert_cbr_to_cbz(req: ConvertCbrRequest, user=Depends(require_admin)):
    """Convertit un .cbr en .cbz dans le même dossier (sans supprimer le .cbr)."""
    with get_db_ctx() as db:
        folder = folder_from_filepath(req.cbr_path or "")
        base = get_library_cbz_path_for_folder(db, folder) if folder else get_cbz_path(db)
        if not base:
            raise HTTPException(400, "Chemin CBZ non configuré")

        full_cbr = (Path(base) / (req.cbr_path or "")).resolve()
        basep = Path(base).resolve()
        if not str(full_cbr).startswith(str(basep)):
            raise HTTPException(400, "Chemin invalide")
        if not full_cbr.exists():
            raise HTTPException(404, f"CBR introuvable: {req.cbr_path}")

        out_cbz = _convert_cbr_to_cbz(full_cbr)
        rel_cbz = str(out_cbz.relative_to(basep)).replace('\\', '/')
        return {"ok": True, "cbz_path": rel_cbz}

@app.get("/api/nautiljon/search")
async def nautiljon_search(
    q: str = "", limit: int = 48, offset: int = 0,
    user=Depends(get_current_user)
):
    """Recherche dans la base Nautiljon locale. Les covers pointent déjà vers les
    images téléchargées localement par scrapersql.py (voir nautiljon_db._image_url) —
    plus besoin d'enrichissement multi-source ni d'appel réseau."""
    return nautiljon_db.search_local(q, limit=limit, offset=offset)


@app.get("/api/nautiljon/search-web")
async def nautiljon_search_web(
    q: str = "", limit: int = 24,
    user=Depends(get_current_user)
):
    """Historiquement une recherche live sur nautiljon.com : ce conteneur n'accède plus
    qu'à la base locale (voir nautiljon_db.py), donc c'est un simple alias de
    /api/nautiljon/search, conservé pour ne pas casser d'éventuels appelants existants
    (l'appli Flutter notamment)."""
    r = nautiljon_db.search_local(q, limit=limit, offset=0)
    return {"results": r["results"], "total": r["total"]}


@app.get("/api/nautiljon/manga")
async def nautiljon_manga(url: str, user=Depends(get_current_user)):
    """Détails complets d'un manga, lus directement dans la vraie base Nautiljon locale
    (voir nautiljon_db.manga_auto/manga_editions). Plus de cache SQLite nécessaire :
    l'accès local est déjà quasi instantané, contrairement à l'ancien appel réseau."""
    details = nautiljon_db.manga_auto(url)
    editions = nautiljon_db.manga_editions(url)
    return {"details": details, "editions": editions, "cached": False}


@app.get("/api/nautiljon/img/{chemin:path}")
async def nautiljon_img(chemin: str):
    """Sert les images (couvertures série/volume). D'abord depuis le cache local
    (IMG_CACHE_DIR, dans TAMASHELF_DATA) si déjà téléchargée -- sinon en proxy HTTP
    depuis app.py (sa route publique /<chemin>, qui lit le fichier sur le disque
    partagé par scrapersql.py), et on la sauve dans le cache pour les prochaines fois.
    TamaShelf n'a donc besoin de joindre app.py qu'une seule fois par image. Volontairement
    sans authentification : les balises <img> ne peuvent pas envoyer d'en-tête
    Authorization, et ce contenu (jaquettes de mangas) est aussi peu sensible que les
    anciens hotlinks directs vers nautiljon.com que ça remplace."""
    chemin_propre = chemin.lstrip("/")
    ext = Path(chemin_propre).suffix.lower().lstrip(".")
    mime = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
            "webp": "image/webp", "gif": "image/gif", "bmp": "image/bmp"}.get(ext, "image/jpeg")

    cache_root = IMG_CACHE_DIR.resolve()
    cache_path = (cache_root / chemin_propre).resolve()
    if cache_root != cache_path and cache_root not in cache_path.parents:
        raise HTTPException(400, "Chemin invalide")

    if cache_path.is_file():
        return FileResponse(str(cache_path), media_type=mime, headers={"Cache-Control": "public, max-age=86400"})

    url = f"{nautiljon_db.APP_PY_URL}/{chemin_propre}"
    try:
        async with httpx.AsyncClient(timeout=nautiljon_db.APP_PY_TIMEOUT) as client:
            r = await client.get(url)
    except (httpx.RequestError, TimeoutError):
        raise HTTPException(502, "app.py injoignable")
    if r.status_code != 200:
        raise HTTPException(404, "Image introuvable")

    try:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_bytes(r.content)
    except OSError:
        pass  # le cache est un bonus -- une écriture ratée n'empêche pas de servir l'image

    return Response(content=r.content, media_type=mime, headers={"Cache-Control": "public, max-age=86400"})


def _normalize_details(raw: dict) -> dict:
    """Normalise les détails d'un manga en un format uniforme.
    
    L'API Nautiljon peut renvoyer les données sous différentes formes.
    Cette fonction cherche les clés connues et construit un objet propre.
    """
    if not raw:
        return {}
    
    def pick(*keys):
        """Retourne la première valeur non-None/non-vide trouvée parmi les clés"""
        for k in keys:
            v = raw.get(k)
            if v is not None and v != "" and v != []:
                return v
        return None
    
    # Chercher dans les sous-objets si les données sont imbriquées
    # Certaines API renvoient {manga: {title: ...}} ou {details: {title: ...}}
    nested = raw
    for sub_key in ("manga", "details", "data", "result"):
        if isinstance(raw.get(sub_key), dict):
            nested = raw[sub_key]
            break
    
    def pick_nested(*keys):
        for k in keys:
            v = nested.get(k) or raw.get(k)
            if v is not None and v != "" and v != []:
                return v
        return None
    
    # Construire l'objet normalisé
    details = {}
    
    # Titre
    details["title"] = pick_nested("title", "titre", "name")
    details["alt_title"] = pick_nested("alt_title", "alternative_title", "title_en", "english_title")
    details["japanese_title"] = pick_nested("japanese_title", "title_ja", "titre_japonais", "original_title")
    
    # Images
    details["cover_url"] = pick_nested("cover_url", "image_url", "cover", "image", "thumbnail", "poster")
    details["image_url"] = pick_nested("image_url", "cover_url", "image")
    
    # Texte
    details["synopsis"] = pick_nested("synopsis", "description", "summary", "resume", "résumé")
    
    # Métadonnées
    details["author"] = pick_nested("author", "auteur", "author_name", "mangaka")
    details["artist"] = pick_nested("artist", "dessinateur", "illustrator", "drawer")
    details["type"] = pick_nested("type", "manga_type", "category")
    details["status"] = pick_nested("status", "statut", "state", "publication_status")
    details["country"] = pick_nested("country", "pays", "origin")
    details["publisher"] = pick_nested("publisher", "editeur", "éditeur", "editor")
    details["magazine"] = pick_nested("magazine", "magazine_name", "serialization")
    details["year"] = pick_nested("year", "année", "annee", "start_year", "date")
    details["volumes_count"] = pick_nested("volumes_count", "nb_volumes", "volumes", "total_volumes", "nb_tomes", "tomes")
    details["score"] = pick_nested("score", "note", "rating", "average_score")
    
    # Genres/Thèmes — peut être string, liste, ou comma-separated
    genres = pick_nested("genres", "genre", "themes", "tags", "categories")
    if isinstance(genres, str):
        genres = [g.strip() for g in genres.replace(";", ",").split(",") if g.strip()]
    elif not isinstance(genres, list):
        genres = []
    details["genres"] = genres
    
    # Nettoyer les None
    details = {k: v for k, v in details.items() if v is not None}
    
    # Garder aussi toutes les clés originales non-standard pour le JSON brut
    details["_raw_keys"] = list(raw.keys())
    
    return details

# ═══════════════════════════════════════════
#  Reading / Lists helpers
# ═══════════════════════════════════════════

def _normalize_list_name(name: str) -> str:
    v = str(name or '').strip().lower()
    if v not in {'read', 'to_read'}:
        raise HTTPException(400, "Liste invalide")
    return v


def _guess_item_type(volume_id: str, item_type: str = '') -> str:
    explicit = str(item_type or '').strip().lower()
    if explicit in {'manga', 'tome', 'chapter', 'oneshot'}:
        return explicit
    vol = str(volume_id or '').lower()
    if not vol:
        return 'manga'
    if vol.startswith('imgvol:'):
        return 'tome'
    if 'oneshot' in vol or 'one-shot' in vol or '/os' in vol or '_os' in vol:
        return 'oneshot'
    if 'chap' in vol or 'chapter' in vol:
        return 'chapter'
    return 'tome'


def _upsert_user_list_item(db, user_id: int, list_name: str, manga_url: str, volume_id: str = '', item_type: str = '', title: str = '', auto_added: bool = False):
    list_name = _normalize_list_name(list_name)
    item_type = _guess_item_type(volume_id, item_type)
    volume_id = str(volume_id or '')
    title = str(title or '').strip()
    try:
        db.execute("""
            INSERT INTO user_list_items (user_id, list_name, manga_url, volume_id, item_type, title, auto_added, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, list_name, manga_url, volume_id, item_type) DO UPDATE SET
                title=excluded.title,
                auto_added=CASE WHEN excluded.auto_added = 1 THEN 1 ELSE user_list_items.auto_added END,
                created_at=CASE WHEN excluded.auto_added = 1 THEN excluded.created_at ELSE user_list_items.created_at END
        """, (user_id, list_name, str(manga_url or ''), volume_id, item_type, title, int(bool(auto_added)), time.time()))
    except Exception:
        db.execute("""
            INSERT OR REPLACE INTO user_list_items (user_id, list_name, manga_url, volume_id, item_type, title, auto_added, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (user_id, list_name, str(manga_url or ''), volume_id, item_type, title, int(bool(auto_added)), time.time()))
    return {"ok": True, "list_name": list_name, "manga_url": manga_url, "volume_id": volume_id, "item_type": item_type}

# ═══════════════════════════════════════════
#  Routes: Reading Progress
# ═══════════════════════════════════════════

@app.get("/api/progress")
def get_progress(user=Depends(get_current_user)):
    with get_db_ctx() as db:
        rows = db.execute(
            "SELECT manga_url, volume_id, current_page, total_pages, title, last_read FROM reading_progress WHERE user_id = ? ORDER BY last_read DESC",
            (user["id"],)
        ).fetchall()
        return [dict(r) for r in rows]

@app.post("/api/progress")
def save_progress(req: SaveProgressRequest, user=Depends(get_current_user)):
    with get_db_ctx() as db:
        try:
            db.execute("""
                INSERT INTO reading_progress (user_id, manga_url, volume_id, current_page, total_pages, title, last_read)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, manga_url, volume_id) DO UPDATE SET
                    current_page=excluded.current_page,
                    total_pages=excluded.total_pages, title=excluded.title, last_read=excluded.last_read
            """, (user["id"], req.manga_url, req.volume_id, req.current_page, req.total_pages, req.title, time.time()))
        except Exception:
            db.execute("""
                INSERT OR REPLACE INTO reading_progress (user_id, manga_url, volume_id, current_page, total_pages, title, last_read)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, (user["id"], req.manga_url, req.volume_id, req.current_page, req.total_pages, req.title, time.time()))

        if req.total_pages > 0 and req.current_page >= max(req.total_pages - 1, 0) and str(req.volume_id or '').strip():
            _upsert_user_list_item(
                db,
                user_id=user["id"],
                list_name="read",
                manga_url=req.manga_url,
                volume_id=req.volume_id,
                item_type=_guess_item_type(req.volume_id),
                title=req.title,
                auto_added=True,
            )
            db.execute(
                "DELETE FROM user_list_items WHERE user_id = ? AND list_name = 'to_read' AND manga_url = ? AND volume_id = ?",
                (user["id"], req.manga_url, str(req.volume_id))
            )

        db.commit()
        return {"ok": True}


@app.delete("/api/progress")
def delete_progress(manga_url: str, volume_id: Optional[str] = None, user=Depends(get_current_user)):
    """Supprime une entrée de lecture en cours (pour l'utilisateur courant).

    - manga_url: clé du manga (chez nous, c'est le cbz_folder)
    - volume_id: identifiant du tome (optionnel). Si absent, supprime toutes les entrées du manga.
    """
    with get_db_ctx() as db:
        if volume_id is None or str(volume_id) == "":
            db.execute(
                "DELETE FROM reading_progress WHERE user_id = ? AND manga_url = ?",
                (user["id"], manga_url)
            )
        else:
            db.execute(
                "DELETE FROM reading_progress WHERE user_id = ? AND manga_url = ? AND volume_id = ?",
                (user["id"], manga_url, str(volume_id))
            )
        db.commit()
        return {"ok": True}

@app.get("/api/lists")
def get_user_lists(user=Depends(get_current_user)):
    with get_db_ctx() as db:
        rows = db.execute(
            "SELECT list_name, manga_url, volume_id, item_type, title, auto_added, created_at FROM user_list_items WHERE user_id = ? ORDER BY created_at DESC",
            (user["id"],)
        ).fetchall()
        data = {"read": [], "to_read": []}
        for row in rows:
            item = dict(row)
            data.setdefault(item["list_name"], []).append(item)
        return data

@app.post("/api/lists")
def add_user_list_item(req: UserListItemRequest, user=Depends(get_current_user)):
    with get_db_ctx() as db:
        res = _upsert_user_list_item(
            db,
            user_id=user["id"],
            list_name=req.list_name,
            manga_url=req.manga_url,
            volume_id=req.volume_id,
            item_type=req.item_type,
            title=req.title,
            auto_added=req.auto_added,
        )
        if res["list_name"] == "read" and res["volume_id"]:
            db.execute(
                "DELETE FROM user_list_items WHERE user_id = ? AND list_name = 'to_read' AND manga_url = ? AND volume_id = ?",
                (user["id"], req.manga_url, str(req.volume_id or ''))
            )
        db.commit()
        return res

@app.delete("/api/lists")
def delete_user_list_item(list_name: str, manga_url: str, volume_id: Optional[str] = None, item_type: Optional[str] = None, user=Depends(get_current_user)):
    with get_db_ctx() as db:
        list_name = _normalize_list_name(list_name)
        volume_id = str(volume_id or '')
        item_type = _guess_item_type(volume_id, item_type or '')
        db.execute(
            "DELETE FROM user_list_items WHERE user_id = ? AND list_name = ? AND manga_url = ? AND volume_id = ? AND item_type = ?",
            (user["id"], list_name, manga_url, volume_id, item_type)
        )
        db.commit()
        return {"ok": True}

    # ═══════════════════════════════════════════
    #  Routes: CBZ Matching
    # ═══════════════════════════════════════════

@app.get("/api/matches")
def get_matches(user=Depends(get_current_user)):
    with get_db_ctx() as db:
        rows = db.execute("SELECT manga_url, cbz_folder, matched_by, created_at FROM matches ORDER BY created_at DESC").fetchall()
        return [dict(r) for r in rows]

@app.post("/api/matches")
def create_match(req: MatchRequest, user=Depends(get_current_user)):
    if user["perms"]["readOnly"]:
        raise HTTPException(403, "Lecture seule")
    with get_db_ctx() as db:
        db.execute(
            "INSERT OR REPLACE INTO matches (manga_url, cbz_folder, matched_by, created_at) VALUES (?, ?, ?, ?)",
            (req.manga_url, req.cbz_folder, user["username"], time.time())
        )
        db.commit()
        return {"ok": True}

@app.delete("/api/matches/{manga_url:path}")
def delete_match(manga_url: str, user=Depends(get_current_user)):
    if user["perms"]["readOnly"]:
        raise HTTPException(403, "Lecture seule")
    with get_db_ctx() as db:
        db.execute("DELETE FROM matches WHERE manga_url = ?", (manga_url,))
        db.commit()
        return {"ok": True}

    # ═══════════════════════════════════════════
    #  Routes: CBZ File Serving
    # ═══════════════════════════════════════════

@app.get("/api/cbz/list/{folder:path}")
def list_cbz_files(folder: str, user=Depends(get_current_user)):
    """Liste les tomes d'un manga — lecture depuis la BDD (instantané).
    
    Fusionne les tomes de toutes les bibliothèques accessibles.
    Si rien en BDD, fallback sur scan disque.
    """
    with get_db_ctx() as db:
        user_lib_ids = get_user_library_ids(db, user["id"], user["role"])
    
        if not user_lib_ids:
            # Fallback: toutes les bibliothèques
            user_lib_ids = [r["id"] for r in db.execute("SELECT id FROM libraries").fetchall()]
    
        if not user_lib_ids:
            raise HTTPException(400, "Aucune bibliothèque")
    
        placeholders = ",".join("?" * len(user_lib_ids))
        rows = db.execute(
            f"""SELECT id, filename, filepath, volume_num, volume_type, volume_display, 
                       source, file_size, total_pages, chapters_json, library_id,
                       CASE WHEN thumbnail_blob IS NOT NULL THEN 1 ELSE 0 END as has_thumb
                FROM manga_volumes 
                WHERE cbz_folder = ? AND library_id IN ({placeholders})
                ORDER BY volume_type ASC, volume_num ASC, filename ASC""",
            [folder] + user_lib_ids
        ).fetchall()
    
        if not rows:
            # Pas encore indexé → scan disque en temps réel (ancien comportement)
            return _list_cbz_files_disk(folder, user)
    
        # Dédupliquer : même tome dans plusieurs bibliothèques → prendre le premier
        # Pour archives: dédupliquer par (volume_type, volume_num) ou filename si pas de numéro
        # Pour images: dédupliquer par volume_num, fusionner les chapitres
        files_map = {}   # clé de dédup → entry
        img_vols = {}    # volume_num → entry
        seen_img_chapters = {}  # volume_num → set(chapitres déjà vus)
    
        for r in rows:
            if r["source"] == "images":
                v = r["volume_num"] or 0
                try:
                    chapters = json.loads(r["chapters_json"] or "[]")
                except:
                    chapters = []
            
                if v not in img_vols:
                    seen_img_chapters[v] = set(chapters)
                    img_vols[v] = {
                        "id": r["id"],
                        "name": r["filename"],
                        "size": 0,
                        "path": r["filepath"],
                        "volume": v,
                        "volume_type": "tome",
                        "volume_display": r["volume_display"] or f"Tome {v:02d}",
                        "source": "images",
                        "total_pages": r["total_pages"] or 0,
                        "has_thumbnail": bool(r["has_thumb"]),
                        "chapters": chapters,
                        "lib_id": r["library_id"],
                    }
                else:
                    # Fusionner seulement les chapitres NOUVEAUX (pas déjà vus)
                    new_chapters = [ch for ch in chapters if ch not in seen_img_chapters[v]]
                    if new_chapters:
                        for ch in new_chapters:
                            seen_img_chapters[v].add(ch)
                            img_vols[v]["chapters"].append(ch)
                        img_vols[v]["chapters"].sort()
                        img_vols[v]["total_pages"] += (r["total_pages"] or 0)
            else:
                # Dédupliquer par (volume_type, volume_num) ou par filename
                vtype = r["volume_type"]
                vnum = r["volume_num"]
                if vtype and vnum is not None:
                    dedup_key = f"{vtype}:{vnum}"
                else:
                    dedup_key = f"file:{r['filename']}"
            
                if dedup_key not in files_map:
                    files_map[dedup_key] = {
                        "id": r["id"],
                        "name": r["filename"],
                        "size": r["file_size"],
                        "path": r["filepath"],
                        "volume": r["volume_num"],
                        "volume_type": r["volume_type"],
                        "volume_display": r["volume_display"],
                        "source": "archive",
                        "total_pages": r["total_pages"] or 0,
                        "has_thumbnail": bool(r["has_thumb"]),
                        "lib_id": r["library_id"],
                    }
    
        def _sort_key(x):
            t = x.get("volume_type")
            rank = 0 if t == "oneshot" else 1 if t == "tome" else 2 if t == "chapter" else 3
            return (rank, x.get("volume") or 9999, x.get("name", ""))
    
        merged = list(files_map.values()) + list(img_vols.values())
        files = sorted(merged, key=_sort_key)
        return {"folder": folder, "files": files, "total": len(files)}


def _list_cbz_files_disk(folder: str, user: dict):
    """Fallback: scan disque quand les volumes ne sont pas encore indexés."""
    with get_db_ctx() as db:
        user_lib_ids = get_user_library_ids(db, user["id"], user["role"])
        if not user_lib_ids:
            user_lib_ids = [r["id"] for r in db.execute("SELECT id FROM libraries").fetchall()]
    
        placeholders = ",".join("?" * len(user_lib_ids))
        lib_rows = db.execute(
            f"SELECT id as lib_id, cbz_path FROM libraries WHERE id IN ({placeholders})",
            user_lib_ids
        ).fetchall()
        fallback_base = get_cbz_path(db)

        sources = [(r["cbz_path"], r["lib_id"]) for r in lib_rows if r["cbz_path"]]
        if not sources and fallback_base:
            sources = [(fallback_base, None)]
        if not sources:
            return {"folder": folder, "files": [], "total": 0}

        files_map = {}
        img_vols: dict[int, dict] = {}
        for (base, lib_id) in sources:
            base_path = Path(base)
            if not base_path.exists():
                continue
            target = base_path / folder
            if not target.exists() or not target.is_dir():
                folder_name = Path(folder).name.lower()
                found = False
                for d in base_path.iterdir():
                    if d.is_dir() and (d.name.lower() == folder_name or folder_name in d.name.lower()):
                        target = d
                        found = True
                        break
                if not found:
                    continue
            for f in target.iterdir():
                if f.is_file() and f.suffix.lower() in (".cbz", ".cbr", ".zip"):
                    fname = f.name
                    if fname not in files_map:
                        info = _parse_cbz_info(f.stem, folder_name=folder)
                        files_map[fname] = {
                            "name": fname, "size": f.stat().st_size,
                            "path": str(Path(folder) / fname).replace("\\", "/"),
                            "volume": info["num"], "volume_type": info["type"],
                            "volume_display": info["display"], "source": "archive", "lib_id": lib_id,
                        }
                elif f.is_dir() and not f.name.startswith("."):
                    info = _parse_images_chapter_dirname(f.name)
                    if not info:
                        continue
                    v, ch = int(info["tome"]), int(info["chapter"])
                    if v not in img_vols:
                        img_vols[v] = {
                            "name": f"Tome {v:02d} (images)", "size": 0,
                            "path": f"imgvol:{folder}:{v}", "volume": v,
                            "volume_type": "tome", "volume_display": f"Tome {v:02d}",
                            "source": "images", "chapters": [], "lib_id": lib_id,
                        }
                    if ch not in img_vols[v]["chapters"]:
                        img_vols[v]["chapters"].append(ch)

        for obj in img_vols.values():
            obj["chapters"].sort()

        def _sort_key(x):
            t = x.get("volume_type")
            rank = 0 if t == "oneshot" else 1 if t == "tome" else 2 if t == "chapter" else 3
            return (rank, x.get("volume") or 9999, x.get("name", ""))
        merged = list(files_map.values()) + list(img_vols.values())
        files = sorted(merged, key=_sort_key)
        return {"folder": folder, "files": files, "total": len(files)}


def _get_volume_keywords():
    """Get configurable keywords from DB, with defaults."""
    DEFAULT_TOME = "Tome,T,Vol,Volume"
    DEFAULT_CHAPTER = "Chapitre,Chapter,Ch,Ep,Episode"
    DEFAULT_ONESHOT = "OS,One Shot,One-Shot,Oneshot"
    try:
        with get_db_ctx() as db:
            tome_kw = get_config_val(db, "tome_keywords", DEFAULT_TOME) or DEFAULT_TOME
            chapter_kw = get_config_val(db, "chapter_keywords", DEFAULT_CHAPTER) or DEFAULT_CHAPTER
            oneshot_kw = get_config_val(db, "oneshot_keywords", DEFAULT_ONESHOT) or DEFAULT_ONESHOT
    except:
        tome_kw = DEFAULT_TOME
        chapter_kw = DEFAULT_CHAPTER
        oneshot_kw = DEFAULT_ONESHOT
    return (
        [k.strip() for k in tome_kw.split(",") if k.strip()],
        [k.strip() for k in chapter_kw.split(",") if k.strip()],
        [k.strip() for k in oneshot_kw.split(",") if k.strip()],
    )

# Cache keywords to avoid DB hits on every file
_kw_cache = {"tome": None, "chapter": None, "oneshot": None, "ts": 0}

def _get_cached_keywords():
    import time as _time
    now = _time.time()
    if _kw_cache["tome"] is None or now - _kw_cache["ts"] > 60:
        t, c, o = _get_volume_keywords()
        _kw_cache["tome"] = t
        _kw_cache["chapter"] = c
        _kw_cache["oneshot"] = o
        _kw_cache["ts"] = now
    return _kw_cache["tome"], _kw_cache["chapter"], _kw_cache["oneshot"]

def _parse_cbz_info(filename: str, folder_name: str = "") -> dict:
    """Extrait le numéro et le type (tome/chapitre/oneshot) d'un nom de fichier CBZ.

    Retourne : {"num": int|None, "type": "tome"|"chapter"|"oneshot"|None, "display": str|None}

    One-shots sont détectés EN PRIORITÉ — cherche dans le nom du fichier ET le nom du dossier.
    Ex: dossier "MonManga - OS [Scan]" avec fichier "MonManga T01.cbz" → oneshot
    """
    name = filename.strip()
    tome_kw, chapter_kw, oneshot_kw = _get_cached_keywords()

    # ── One-shots (PRIORITÉ) — cherche dans fichier ET dossier ──
    sorted_os = sorted(oneshot_kw, key=len, reverse=True)
    for text in [name, folder_name]:
        if not text:
            continue
        for kw in sorted_os:
            if kw == "OS":
                m = re.search(r'\bOS\b', text)
            else:
                m = re.search(r'\b' + re.escape(kw) + r'\b', text, re.IGNORECASE)
            if m:
                return {"num": 1, "type": "oneshot", "display": "One-Shot"}

    # ── Chapitres (mots longs d'abord) ──
    sorted_ch = sorted(chapter_kw, key=len, reverse=True)
    for kw in sorted_ch:
        pattern = r'\b' + re.escape(kw) + r'\.?\s*0*(\d{1,4})\b'
        m = re.search(pattern, name, re.IGNORECASE)
        if m:
            n = int(m.group(1))
            return {"num": n, "type": "chapter", "display": f"Chapitre n°{n}"}

    # ── Tomes (mots longs d'abord) ──
    sorted_t = sorted(tome_kw, key=len, reverse=True)
    for kw in sorted_t:
        pattern = r'\b' + re.escape(kw) + r'\.?\s*0*(\d{1,3})\b'
        m = re.search(pattern, name, re.IGNORECASE)
        if m:
            n = int(m.group(1))
            return {"num": n, "type": "tome", "display": f"Tome {n:02d}"}

    return {"num": None, "type": None, "display": None}


def _parse_images_chapter_dirname(dirname: str) -> Optional[dict]:
    """Parse a chapter folder name containing a 'TxC' pattern (tome x chapitre).

    Supported formats:
      - '1x5'                        → tome 1, chapitre 5
      - '01x005'                     → tome 1, chapitre 5
      - '37 seconds - 01x001'        → tome 1, chapitre 1
      - 'Apotheosis - 02x015'        → tome 2, chapitre 15
      - 'Manga Name - 1 x 5'        → tome 1, chapitre 5

    Returns {"tome": int, "chapter": int} or None.
    """
    name = (dirname or "").strip()
    # Chercher un pattern NxM n'importe où dans le nom
    m = re.search(r'0*(\d{1,3})\s*[xX]\s*0*(\d{1,4})', name)
    if not m:
        return None
    try:
        return {"tome": int(m.group(1)), "chapter": int(m.group(2))}
    except Exception:
        return None


def _natural_sort_key(s: str):
    """Natural sort key for filenames (1.jpg < 10.jpg)."""
    parts = re.split(r"(\d+)", s or "")
    key = []
    for p in parts:
        if p.isdigit():
            key.append(int(p))
        else:
            key.append(p.lower())
    return key


def _iter_image_pages_for_volume(base_path: Path, folder: str, volume: int) -> list[dict]:
    """Return ordered pages for an 'images folders' volume.

    Pages are assembled from chapter folders named like 'y x z' => tome y, chapitre z.
    Returns list of {"chapter": int, "rel": str, "full": Path}.
    """
    folder_path = (base_path / folder)
    if not folder_path.exists() or not folder_path.is_dir():
        return []

    image_exts = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}
    chapters: list[tuple[int, Path]] = []
    for d in folder_path.iterdir():
        if not d.is_dir() or d.name.startswith("."):
            continue
        info = _parse_images_chapter_dirname(d.name)
        if not info:
            continue
        if info["tome"] != int(volume):
            continue
        chapters.append((info["chapter"], d))

    chapters.sort(key=lambda x: x[0])
    pages: list[dict] = []
    for ch_num, ch_dir in chapters:
        imgs = [p for p in ch_dir.iterdir() if p.is_file() and p.suffix.lower() in image_exts and not p.name.startswith(".")]
        imgs.sort(key=lambda p: _natural_sort_key(p.name))
        for img in imgs:
            rel = (Path(folder) / ch_dir.name / img.name).as_posix()
            pages.append({"chapter": ch_num, "rel": rel, "full": img})
    return pages


def _parse_volume_number(filename: str) -> Optional[int]:
    """Compat wrapper — retourne uniquement le numéro."""
    return _parse_cbz_info(filename)["num"]

@app.get("/api/cbz/browse")
def browse_cbz_folders(user=Depends(get_current_user)):
    """Liste tous les dossiers manga dans le répertoire CBZ racine"""
    with get_db_ctx() as db:
        base = get_cbz_path(db)
    
        if not base:
            return {"folders": [], "error": "Chemin CBZ non configuré"}
    
        base_path = Path(base)
        if not base_path.exists():
            return {"folders": [], "error": f"Chemin introuvable: {base}"}
    
        folders = []
        for d in sorted(base_path.iterdir()):
            if d.is_dir() and not d.name.startswith("."):
                cbz_count = len([f for f in d.iterdir() if f.is_file() and f.suffix.lower() in (".cbz", ".cbr", ".zip")])
                img_ch_count = len([sd for sd in d.iterdir() if sd.is_dir() and _parse_images_chapter_dirname(sd.name)])
                if cbz_count > 0 or img_ch_count > 0:
                    folders.append({
                        "name": d.name,
                        "cbz_count": cbz_count,
                        "img_chapters": img_ch_count,
                    })
    
        return {"folders": folders, "total": len(folders), "base_path": base}


    # ── Cover cache pour l'accueil ──

COVERS_DIR = DATA_DIR / "covers"
COVERS_DIR.mkdir(parents=True, exist_ok=True)

# Taille des covers pour l'accueil (en px).
HOME_COVER_WIDTH = int(os.getenv("TAMASHELF_HOME_COVER_WIDTH", os.getenv("MANGASHELF_HOME_COVER_WIDTH", "320")))
HOME_COVER_HEIGHT = int(os.getenv("TAMASHELF_HOME_COVER_HEIGHT", os.getenv("MANGASHELF_HOME_COVER_HEIGHT", str(int(HOME_COVER_WIDTH * 3 / 2)))))
HOME_COVER_FORMAT = os.getenv("TAMASHELF_HOME_COVER_FORMAT", os.getenv("MANGASHELF_HOME_COVER_FORMAT", "webp")).lower()

THUMB_WIDTH = 200
THUMB_HEIGHT = 280


def _make_thumbnail_bytes(img_bytes: bytes, width: int = THUMB_WIDTH, height: int = THUMB_HEIGHT) -> Optional[bytes]:
    """Crée une miniature webp à partir de bytes d'image. Retourne les bytes webp ou None."""
    if not Image:
        return None
    try:
        with Image.open(io.BytesIO(img_bytes)) as im:
            im = im.convert("RGB")
            # Crop centré au ratio width/height
            target_ratio = width / height
            img_ratio = im.width / im.height
            if img_ratio > target_ratio:
                new_w = int(im.height * target_ratio)
                left = (im.width - new_w) // 2
                im = im.crop((left, 0, left + new_w, im.height))
            elif img_ratio < target_ratio:
                new_h = int(im.width / target_ratio)
                im = im.crop((0, 0, im.width, new_h))
            im = im.resize((width, height), Image.LANCZOS)
            buf = io.BytesIO()
            im.save(buf, format="WEBP", quality=75)
            return buf.getvalue()
    except:
        return None


def _extract_first_image_from_cbz(cbz_path: Path) -> Optional[bytes]:
    """Extrait la première image d'un fichier CBZ. Retourne les bytes ou None."""
    img_exts = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}
    try:
        with zipfile.ZipFile(str(cbz_path), "r") as zf:
            names = sorted([n for n in zf.namelist() if Path(n).suffix.lower() in img_exts and not Path(n).name.startswith(".")])
            if names:
                return zf.read(names[0])
    except:
        pass
    return None


def _extract_first_image_from_imgdir(dir_path: Path) -> Optional[bytes]:
    """Extrait la première image d'un dossier d'images. Retourne les bytes ou None."""
    img_exts = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}
    try:
        images = sorted([f for f in dir_path.iterdir() if f.is_file() and f.suffix.lower() in img_exts])
        if images:
            return images[0].read_bytes()
    except:
        pass
    return None


def _count_pages_cbz(cbz_path: Path) -> int:
    """Compte le nombre de pages dans un CBZ."""
    img_exts = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}
    try:
        with zipfile.ZipFile(str(cbz_path), "r") as zf:
            return len([n for n in zf.namelist() if Path(n).suffix.lower() in img_exts and not Path(n).name.startswith(".")])
    except:
        return 0


def _make_home_cover(img_bytes: bytes) -> Optional[tuple[bytes, str]]:
    """Resize + crop une image pour l'affichage d'accueil.

    Retourne (bytes, extension) ou None si Pillow indisponible/erreur.
    """
    if not Image:
        return None

    try:
        with Image.open(io.BytesIO(img_bytes)) as im:
            # Convertir pour éviter les soucis (palette/alpha)
            if im.mode not in ("RGB", "RGBA"):
                im = im.convert("RGBA")

            target_w, target_h = HOME_COVER_WIDTH, HOME_COVER_HEIGHT
            # "cover" fit : scale pour remplir + crop centré
            src_w, src_h = im.size
            if src_w <= 0 or src_h <= 0:
                return None
            scale = max(target_w / src_w, target_h / src_h)
            new_w = max(1, int(src_w * scale))
            new_h = max(1, int(src_h * scale))
            im = im.resize((new_w, new_h), Image.Resampling.LANCZOS)

            left = max(0, (new_w - target_w) // 2)
            top = max(0, (new_h - target_h) // 2)
            im = im.crop((left, top, left + target_w, top + target_h))

            out = io.BytesIO()
            fmt = HOME_COVER_FORMAT
            if fmt == "jpg" or fmt == "jpeg":
                # JPG n'aime pas l'alpha
                if im.mode == "RGBA":
                    bg = Image.new("RGB", im.size, (0, 0, 0))
                    bg.paste(im, mask=im.getchannel("A"))
                    im = bg
                else:
                    im = im.convert("RGB")
                im.save(out, format="JPEG", quality=85, optimize=True, progressive=True)
                return out.getvalue(), ".jpg"
            if fmt == "png":
                im.save(out, format="PNG", optimize=True)
                return out.getvalue(), ".png"

            # default webp
            if im.mode != "RGB":
                im = im.convert("RGB")
            im.save(out, format="WEBP", quality=80, method=6)
            return out.getvalue(), ".webp"
    except Exception:
        return None


def _safe_filename(name: str) -> str:
    """Transforme un nom de dossier en nom de fichier safe"""
    return re.sub(r'[^\w\-. ]', '_', name).strip()[:120]


def _extract_folder_cover(base: str, folder: str) -> Optional[Path]:
    """Extrait la première page du premier CBZ d'un dossier et la cache sur disque.
    
    Retourne le chemin du fichier cache, ou None si échec.
    """
    safe = _safe_filename(folder)
    # Vérifier si déjà en cache (on préfère webp, et on migre auto les anciens caches)
    preferred_exts = (".webp", ".jpg", ".png")
    for ext in preferred_exts:
        cached = COVERS_DIR / f"{safe}{ext}"
        if cached.exists() and cached.stat().st_size > 0:
            # Si ce n'est pas au format/à la taille attendue, on tente de régénérer.
            if Image:
                needs_regen = (ext != ".webp")
                if not needs_regen and ext == ".webp":
                    try:
                        with Image.open(str(cached)) as im:
                            needs_regen = (im.size != (HOME_COVER_WIDTH, HOME_COVER_HEIGHT))
                    except Exception:
                        needs_regen = True

                if needs_regen:
                    made = _make_home_cover(cached.read_bytes())
                    if made:
                        new_bytes, new_ext = made
                        out_path = COVERS_DIR / f"{safe}{new_ext}"
                        out_path.write_bytes(new_bytes)
                        # Nettoyer l'ancien cache si différent
                        if out_path != cached:
                            try:
                                cached.unlink()
                            except Exception:
                                pass
                        return out_path
            return cached
    
    base_path = Path(base)
    target = base_path / folder
    
    if not target.exists() or not target.is_dir():
        # Fuzzy match
        for d in base_path.iterdir():
            if d.is_dir() and d.name.lower() == folder.lower():
                target = d
                break
        else:
            return None
    
    # Trouver le premier archive lisible (CBZ/ZIP en priorité, puis CBR)
    def _ext_rank(p: Path) -> int:
        ext = p.suffix.lower()
        if ext in (".cbz", ".zip"):
            return 0
        if ext == ".cbr":
            return 1
        return 9

    cbz_files = sorted(
        [f for f in target.iterdir() if f.suffix.lower() in (".cbz", ".cbr", ".zip")],
        key=lambda f: (_ext_rank(f), _parse_volume_number(f.stem) or 999, f.name)
    )
    if not cbz_files:
        # Fallback: try image chapter folders (e.g., 1x5)
        try:
            vols = []
            for d in target.iterdir():
                if d.is_dir() and not d.name.startswith("."):
                    info = _parse_images_chapter_dirname(d.name)
                    if info:
                        vols.append((info["tome"], info["chapter"], d))
            if not vols:
                return None
            vols.sort(key=lambda x: (x[0], x[1], x[2].name))
            first_dir = vols[0][2]
            image_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}
            imgs = [p for p in first_dir.iterdir() if p.is_file() and p.suffix.lower() in image_exts and not p.name.startswith(".")]
            if not imgs:
                return None
            imgs.sort(key=lambda p: _natural_sort_key(p.name))
            img_data = imgs[0].read_bytes()
            made = _make_home_cover(img_data)
            if made:
                out_bytes, out_ext = made
                out_path = COVERS_DIR / f"{safe}{out_ext}"
                out_path.write_bytes(out_bytes)
                return out_path
            ext = imgs[0].suffix.lower()
            if ext == ".jpeg":
                ext = ".jpg"
            out_path = COVERS_DIR / f"{safe}{ext}"
            out_path.write_bytes(img_data)
            return out_path
        except Exception:
            return None
    
    # Extraire la première image
    try:
        # La cover cache est basée sur CBZ/ZIP ; si le premier est CBR et qu'aucun
        # CBZ n'existe, on ne casse pas l'accueil (cover vide).
        if cbz_files[0].suffix.lower() == ".cbr":
            return None

        with zipfile.ZipFile(str(cbz_files[0]), "r") as zf:
            image_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}
            images = sorted([
                n for n in zf.namelist()
                if Path(n).suffix.lower() in image_exts
                and not n.startswith("__MACOSX")
                and not Path(n).name.startswith(".")
            ])
            if not images:
                return None
            
            img_data = zf.read(images[0])

            # Resize/crop pour l'accueil (si possible)
            made = _make_home_cover(img_data)
            if made:
                out_bytes, out_ext = made
                out_path = COVERS_DIR / f"{safe}{out_ext}"
                out_path.write_bytes(out_bytes)
                return out_path

            # Fallback : cache brut
            ext = Path(images[0]).suffix.lower()
            if ext == ".jpeg":
                ext = ".jpg"
            out_path = COVERS_DIR / f"{safe}{ext}"
            out_path.write_bytes(img_data)
            return out_path
    except:
        return None


@app.get("/api/cbz/folder-cover/{folder:path}")
def folder_cover(folder: str, user=Depends(get_current_user)):
    """Renvoie la cover d'un manga — depuis la BDD (instantané) ou disque (fallback)."""
    with get_db_ctx() as db:
        # 1) Essayer depuis la BDD
        row = db.execute("SELECT cover_blob FROM manga_library WHERE cbz_folder = ?", (folder,)).fetchone()
        if row and row["cover_blob"]:
            return Response(
                content=row["cover_blob"],
                media_type="image/webp",
                headers={"Cache-Control": "public, max-age=604800"}
            )
    
        # 2) Fallback: extraire depuis le disque
        base = get_library_cbz_path_for_folder(db, folder)

        if not base:
            raise HTTPException(400, "Chemin CBZ non configuré")

        cover_path = _extract_folder_cover(base, folder)
        if not cover_path or not cover_path.exists():
            raise HTTPException(404, "Pas de cover")

        ext = cover_path.suffix.lower()
        media_types = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
                       ".webp": "image/webp", ".gif": "image/gif", ".bmp": "image/bmp"}

        return Response(
            content=cover_path.read_bytes(),
            media_type=media_types.get(ext, "image/jpeg"),
            headers={"Cache-Control": "public, max-age=604800"}
        )


@app.get("/api/cbz/volume-thumbnail/{volume_id:int}")
def volume_thumbnail(volume_id: int, user=Depends(get_current_user)):
    """Renvoie la miniature d'un tome — extraite à la volée, cache en BDD."""
    with get_db_ctx() as db:
        row = db.execute(
            "SELECT id, thumbnail_blob, cbz_folder, filepath, source, library_id FROM manga_volumes WHERE id = ?",
            (volume_id,)
        ).fetchone()
        if not row:
            raise HTTPException(404)
    
        # Si déjà en cache
        if row["thumbnail_blob"]:
            return Response(content=row["thumbnail_blob"], media_type="image/webp",
                            headers={"Cache-Control": "public, max-age=604800"})
    
        # Extraire à la volée
        raw_img = None
        if row["source"] == "archive":
            base = get_library_cbz_path_for_filepath(db, row["filepath"])
            cbz_path = Path(base) / row["filepath"]
            if cbz_path.exists():
                raw_img = _extract_first_image_from_cbz(cbz_path)
        elif row["source"] == "images":
            # imgvol:folder:volume → trouver le premier chapitre
            parts = row["filepath"].split(":")
            if len(parts) >= 3:
                folder, vol = parts[1], int(parts[2])
                base = get_library_cbz_path_for_folder(db, folder)
                folder_path = Path(base) / folder
                if folder_path.exists():
                    for d in folder_path.iterdir():
                        if d.is_dir():
                            info = _parse_images_chapter_dirname(d.name)
                            if info and info["tome"] == vol:
                                raw_img = _extract_first_image_from_imgdir(d)
                                break
    
    
        if raw_img:
            thumb = _make_thumbnail_bytes(raw_img)
            if thumb:
                # Cache en BDD pour la prochaine fois
                db2 = get_db()
                db2.execute("UPDATE manga_volumes SET thumbnail_blob = ? WHERE id = ?", (thumb, volume_id))
                db2.commit()
                db2.close()
                return Response(content=thumb, media_type="image/webp",
                                headers={"Cache-Control": "public, max-age=604800"})
    
        raise HTTPException(404, "Pas de miniature")


@app.post("/api/admin/generate-covers")
def generate_covers(admin=Depends(require_admin)):
    """Génère les covers de tous les dossiers CBZ."""
    with get_db_ctx() as db:
        folders = db.execute("SELECT cbz_folder FROM manga_library").fetchall()
        all_libs = db.execute("SELECT id, cbz_path FROM libraries ORDER BY id ASC").fetchall()

        generated = 0
        skipped = 0
        errors = 0

        for row in folders:
            folder = row["cbz_folder"]
            safe = _safe_filename(folder)
            already = any((COVERS_DIR / f"{safe}{ext}").exists() for ext in (".jpg", ".png", ".webp"))
            if already:
                skipped += 1
                continue
            # Trouver le base path dans n'importe quelle bibliothèque
            base = None
            for lib in all_libs:
                if lib["cbz_path"] and (Path(lib["cbz_path"]) / folder).exists():
                    base = lib["cbz_path"]
                    break
            if not base:
                errors += 1
                continue
            result = _extract_folder_cover(base, folder)
            if result:
                generated += 1
            else:
                errors += 1

        return {"generated": generated, "skipped": skipped, "errors": errors, "total": len(folders)}


@app.get("/api/cbz/thumbnail/{filepath:path}")
def cbz_thumbnail(filepath: str, user=Depends(get_current_user)):
    """Renvoie la première image d'un CBZ comme miniature."""
    with get_db_ctx() as db:
        base = get_library_cbz_path_for_filepath(db, filepath)

        if not base:
            raise HTTPException(400, "Chemin CBZ non configuré")

        cbz_path = Path(base) / filepath
        if not cbz_path.exists():
            raise HTTPException(404, "Fichier CBZ introuvable")

        try:
            with zipfile.ZipFile(str(cbz_path), "r") as zf:
                image_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}
                images = sorted([
                    n for n in zf.namelist()
                    if Path(n).suffix.lower() in image_exts and not n.startswith("__MACOSX") and not Path(n).name.startswith(".")
                ])
                if not images:
                    raise HTTPException(404, "Aucune image dans le CBZ")
                img_data = zf.read(images[0])
                ext = Path(images[0]).suffix.lower()
                media_types = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
                              ".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp"}
                return Response(
                    content=img_data,
                    media_type=media_types.get(ext, "image/jpeg"),
                    headers={"Cache-Control": "public, max-age=86400"}
                )
        except zipfile.BadZipFile:
            raise HTTPException(400, "Fichier CBZ corrompu")


@app.get("/api/cbz/read/{filepath:path}")
def read_cbz(filepath: str, page: int = 0, user=Depends(get_current_user)):
    """Extrait une page d'un CBZ et la renvoie comme image"""
    with get_db_ctx() as db:
        base = get_library_cbz_path_for_filepath(db, filepath)

        if not base:
            raise HTTPException(400, "Chemin CBZ non configuré")

        cbz_path = Path(base) / filepath
        if not cbz_path.exists():
            raise HTTPException(404, "Fichier CBZ introuvable")

        try:
            with zipfile.ZipFile(str(cbz_path), "r") as zf:
                image_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}
                images = sorted([
                    n for n in zf.namelist()
                    if Path(n).suffix.lower() in image_exts and not n.startswith("__MACOSX")
                ])
                if page < 0 or page >= len(images):
                    raise HTTPException(400, f"Page {page} invalide (0-{len(images)-1})")
                img_data = zf.read(images[page])
                ext = Path(images[page]).suffix.lower()
                media_types = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp"}
                return Response(content=img_data, media_type=media_types.get(ext, "image/jpeg"), headers={"Cache-Control": "public, max-age=86400"})
        except zipfile.BadZipFile:
            raise HTTPException(400, "Fichier CBZ corrompu")

@app.get("/api/cbz/info/{filepath:path}")
def cbz_info(filepath: str, user=Depends(get_current_user)):
    """Infos sur un CBZ (nombre de pages, etc.)"""
    with get_db_ctx() as db:
        base = get_library_cbz_path_for_filepath(db, filepath)

        if not base:
            raise HTTPException(400, "Chemin CBZ non configuré")

        cbz_path = Path(base) / filepath
        if not cbz_path.exists():
            raise HTTPException(404, "Fichier CBZ introuvable")

        try:
            with zipfile.ZipFile(str(cbz_path), "r") as zf:
                image_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}
                images = sorted([n for n in zf.namelist() if Path(n).suffix.lower() in image_exts and not n.startswith("__MACOSX")])
                return {"filepath": filepath, "total_pages": len(images), "filename": cbz_path.name}
        except zipfile.BadZipFile:
            raise HTTPException(400, "Fichier CBZ corrompu")


def _find_base_for_imgvol(db, folder: str, volume: int) -> Optional[str]:
    """Find the library base path where an image-volume exists."""
    # Search ALL libraries, not just the one in manga_library
    all_libs = db.execute("SELECT id, cbz_path FROM libraries ORDER BY id ASC").fetchall()
    for lib in all_libs:
        base = lib["cbz_path"]
        if not base:
            continue
        base_path = Path(base)
        if not base_path.exists():
            continue
        folder_path = base_path / folder
        if not folder_path.exists() or not folder_path.is_dir():
            continue
        for d in folder_path.iterdir():
            info = _parse_images_chapter_dirname(d.name) if d.is_dir() else None
            if info and info["tome"] == int(volume):
                return base
    # Fallback to default base
    return get_cbz_path(db) or None


@app.get("/api/imgvol/info/{folder:path}")
def imgvol_info(folder: str, volume: int = Query(..., ge=0), user=Depends(get_current_user)):
    """Infos sur un "tome" constitué de dossiers d'images (chapitres 1x5)."""
    with get_db_ctx() as db:
        base = _find_base_for_imgvol(db, folder, volume)
        if not base:
            raise HTTPException(400, "Chemin CBZ non configuré")
        pages = _iter_image_pages_for_volume(Path(base), folder, volume)
        return {"folder": folder, "volume": volume, "total_pages": len(pages)}


@app.get("/api/imgvol/page/{folder:path}")
def imgvol_page(folder: str, volume: int = Query(..., ge=0), page: int = Query(0, ge=0), user=Depends(get_current_user)):
    """Renvoie une page image d'un tome "images folders"."""
    with get_db_ctx() as db:
        base = _find_base_for_imgvol(db, folder, volume)
        if not base:
            raise HTTPException(400, "Chemin CBZ non configuré")
        base_path = Path(base)
        # Security: ensure within base
        full_folder = (base_path / folder).resolve()
        if not str(full_folder).startswith(str(base_path.resolve())):
            raise HTTPException(403, "Accès refusé")

        pages = _iter_image_pages_for_volume(base_path, folder, volume)
        if not pages:
            raise HTTPException(404, "Aucune image")
        if page < 0 or page >= len(pages):
            raise HTTPException(400, f"Page {page} invalide (0-{len(pages)-1})")
        img_path: Path = pages[page]["full"]
        # Extra security: ensure file is inside base
        full_img = img_path.resolve()
        if not str(full_img).startswith(str(full_folder)):
            raise HTTPException(403, "Accès refusé")
        if not full_img.exists() or not full_img.is_file():
            raise HTTPException(404, "Image introuvable")
        ext = full_img.suffix.lower().lstrip(".")
        mime = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
                "webp": "image/webp", "gif": "image/gif", "bmp": "image/bmp"}.get(ext, "image/jpeg")
        return FileResponse(str(full_img), media_type=mime, headers={"Cache-Control": "public, max-age=3600"})

@app.get("/api/cbz/page/{filepath:path}")
def get_cbz_page(filepath: str, page: int = 0, user=Depends(get_current_user)):
    """Renvoie une page spécifique d'un CBZ en image (pour les thumbnails 'En cours')."""
    with get_db_ctx() as db:
        base = get_library_cbz_path_for_filepath(db, filepath)
        if not base:
            raise HTTPException(404, "Bibliothèque introuvable")
        full = (Path(base) / filepath).resolve()
        if not str(full).startswith(str(Path(base).resolve())):
            raise HTTPException(403, "Accès refusé")
        if not full.exists():
            raise HTTPException(404, "Fichier introuvable")
        try:
            import zipfile, io
            with zipfile.ZipFile(full, "r") as z:
                imgs = sorted([n for n in z.namelist() if n.lower().endswith(
                    (".jpg", ".jpeg", ".png", ".webp", ".gif"))])
                if not imgs:
                    raise HTTPException(404, "Aucune image")
                idx = max(0, min(page, len(imgs) - 1))
                data = z.read(imgs[idx])
            ext = imgs[idx].rsplit(".", 1)[-1].lower()
            mime = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
                    "webp": "image/webp", "gif": "image/gif"}.get(ext, "image/jpeg")
            return Response(content=data, media_type=mime, headers={"Cache-Control": "public, max-age=3600"})
        except zipfile.BadZipFile:
            raise HTTPException(400, "Archive corrompue")


@app.get("/api/cbz/download/{filepath:path}")
def download_cbz(filepath: str, user=Depends(get_current_user)):
    """Télécharge un CBZ entier"""
    if not user["perms"]["canDownload"]:
        raise HTTPException(403, "Téléchargement non autorisé")

    with get_db_ctx() as db:
        base = get_library_cbz_path_for_filepath(db, filepath)

        if not base:
            raise HTTPException(400, "Chemin CBZ non configuré")

        cbz_path = Path(base) / filepath
        if not cbz_path.exists():
            raise HTTPException(404, "Fichier introuvable")

        return FileResponse(str(cbz_path), media_type="application/zip", filename=cbz_path.name)

    # ═══════════════════════════════════════════
    #  Stats
    # ═══════════════════════════════════════════

@app.get("/api/health")
def health_check():
    """Endpoint de santé — pas d'auth requise."""
    return {"status": "ok", "app": "TamaShelf"}


@app.get("/api/stats")
def stats(user=Depends(get_current_user)):
    with get_db_ctx() as db:
        user_count = db.execute("SELECT COUNT(*) as c FROM users").fetchone()["c"]
        match_count = db.execute("SELECT COUNT(*) as c FROM matches").fetchone()["c"]
        cache_count = db.execute("SELECT COUNT(*) as c FROM manga_cache").fetchone()["c"]
        progress_count = db.execute("SELECT COUNT(*) as c FROM reading_progress WHERE user_id = ?", (user["id"],)).fetchone()["c"]
        return {
            "users": user_count,
            "matches": match_count,
            "cached_mangas": cache_count,
            "your_reading": progress_count,
        }


@app.get("/api/debug/manga-raw")
async def debug_manga_raw(url: str, admin=Depends(require_admin)):
    """Debug: affiche la réponse brute générée par l'accès direct à la base Nautiljon
    pour un manga (nautiljon_db.py). Utile pour voir les clés exactes renvoyées.
    Appeler: /api/debug/manga-raw?url=https://www.nautiljon.com/mangas/xxx.html
    """
    return {
        "db_path": nautiljon_db.APP_PY_URL,
        "db_available": nautiljon_db.is_available(),
        "manga_auto": nautiljon_db.manga_auto(url),
        "manga_editions": nautiljon_db.manga_editions(url),
    }

    # ═══════════════════════════════════════════
    #  Themes
    # ═══════════════════════════════════════════

THEMES_DIR = DATA_DIR / "themes"
THEMES_DIR.mkdir(parents=True, exist_ok=True)

BUILTIN_THEMES = [
    {
        "id": "dark-default", "name": "Sombre (Défaut)", "builtin": True,
        "colors": {
            "d": "#070810", "bg": "#0c0d16", "c1": "#121420", "c2": "#181b28",
            "c3": "#1e2133", "inp": "#0a0b13", "brd": "#232740", "brf": "#6366f1",
            "t1": "#e2e4ef", "t2": "#8588a6", "t3": "#4a4d68",
            "ac": "#6366f1", "acl": "#818cf8",
            "grn": "#34d399", "amb": "#fbbf24", "ros": "#fb7185", "cyn": "#22d3ee"
        }
    },
    {
        "id": "dark-red", "name": "Sombre Rouge", "builtin": True,
        "colors": {
            "d": "#100808", "bg": "#160b0b", "c1": "#200e0e", "c2": "#281212",
            "c3": "#301616", "inp": "#0d0606", "brd": "#3d1515", "brf": "#ef4444",
            "t1": "#f0e4e4", "t2": "#a08080", "t3": "#604040",
            "ac": "#ef4444", "acl": "#f87171",
            "grn": "#34d399", "amb": "#fbbf24", "ros": "#fb7185", "cyn": "#22d3ee"
        }
    },
    {
        "id": "dark-green", "name": "Sombre Vert", "builtin": True,
        "colors": {
            "d": "#051208", "bg": "#07160a", "c1": "#0d1f10", "c2": "#112614",
            "c3": "#152e18", "inp": "#04100a", "brd": "#1a3d20", "brf": "#22c55e",
            "t1": "#e0f0e4", "t2": "#80a888", "t3": "#3d6045",
            "ac": "#22c55e", "acl": "#4ade80",
            "grn": "#34d399", "amb": "#fbbf24", "ros": "#fb7185", "cyn": "#22d3ee"
        }
    },
    {
        "id": "dark-orange", "name": "Sombre Orange", "builtin": True,
        "colors": {
            "d": "#100a04", "bg": "#160e06", "c1": "#1e140a", "c2": "#261a0e",
            "c3": "#2e2012", "inp": "#0e0902", "brd": "#3d2a10", "brf": "#f97316",
            "t1": "#f0e8d8", "t2": "#a09070", "t3": "#6a5a40",
            "ac": "#f97316", "acl": "#fb923c",
            "grn": "#34d399", "amb": "#fbbf24", "ros": "#fb7185", "cyn": "#22d3ee"
        }
    },
    {
        "id": "light", "name": "Clair", "builtin": True,
        "colors": {
            "d": "#f0f2f8", "bg": "#ffffff", "c1": "#f4f6fb", "c2": "#e8ecf5",
            "c3": "#dce2ef", "inp": "#f8f9fc", "brd": "#c8d0e8", "brf": "#6366f1",
            "t1": "#1a1d2e", "t2": "#4a4f6a", "t3": "#8890a8",
            "ac": "#6366f1", "acl": "#818cf8",
            "grn": "#16a34a", "amb": "#d97706", "ros": "#e11d48", "cyn": "#0891b2"
        }
    },
    {
        "id": "manga-ink", "name": "🖊️ Manga Ink", "builtin": True,
        "colors": {
            "d": "#f5f0e8", "bg": "#faf6ee", "c1": "#f0ebe0", "c2": "#e8e0d2",
            "c3": "#ddd4c4", "inp": "#f8f4ec", "brd": "#c8b898", "brf": "#2a2a2a",
            "t1": "#1a1a1a", "t2": "#555544", "t3": "#888870",
            "ac": "#e63946", "acl": "#ff6b6b",
            "grn": "#2d6a4f", "amb": "#e9c46a", "ros": "#e63946", "cyn": "#457b9d",
            "bgImage": "url(\"data:image/svg+xml,%3Csvg width='60' height='60' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence baseFrequency='.65' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='.03'/%3E%3Cline x1='0' y1='60' x2='60' y2='60' stroke='%23c8b898' stroke-width='.3'/%3E%3Cline x1='60' y1='0' x2='60' y2='60' stroke='%23c8b898' stroke-width='.3'/%3E%3C/svg%3E\")",
            "fontFamily": "'Noto Sans JP', 'Lexend', sans-serif"
        }
    },
    {
        "id": "manga-dark", "name": "🌙 Manga Dark", "builtin": True,
        "colors": {
            "d": "#0f0f0f", "bg": "#141414", "c1": "#1c1c1c", "c2": "#222222",
            "c3": "#2a2a2a", "inp": "#111111", "brd": "#333333", "brf": "#ff4757",
            "t1": "#f0e8d8", "t2": "#a09880", "t3": "#605840",
            "ac": "#ff4757", "acl": "#ff6b81",
            "grn": "#2ed573", "amb": "#ffa502", "ros": "#ff4757", "cyn": "#70a1ff",
            "bgImage": "url(\"data:image/svg+xml,%3Csvg width='40' height='40' xmlns='http://www.w3.org/2000/svg'%3E%3Crect width='40' height='40' fill='none'/%3E%3Ccircle cx='20' cy='20' r='.5' fill='%23ffffff' opacity='.04'/%3E%3Ccircle cx='0' cy='0' r='.5' fill='%23ffffff' opacity='.03'/%3E%3Ccircle cx='40' cy='0' r='.5' fill='%23ffffff' opacity='.03'/%3E%3Ccircle cx='0' cy='40' r='.5' fill='%23ffffff' opacity='.03'/%3E%3Ccircle cx='40' cy='40' r='.5' fill='%23ffffff' opacity='.03'/%3E%3C/svg%3E\")",
            "fontFamily": "'Noto Sans JP', 'Lexend', sans-serif"
        }
    },
    {
        "id": "manga-sepia", "name": "📜 Manga Sépia", "builtin": True,
        "colors": {
            "d": "#2c1e10", "bg": "#362414", "c1": "#3e2a18", "c2": "#48321e",
            "c3": "#523a24", "inp": "#281a0e", "brd": "#5a4028", "brf": "#d4a574",
            "t1": "#f0dcc0", "t2": "#b89870", "t3": "#7a6040",
            "ac": "#d4a574", "acl": "#e8c090",
            "grn": "#6bbd5c", "amb": "#e8b04a", "ros": "#d45a4a", "cyn": "#5a9aba",
            "bgImage": "url(\"data:image/svg+xml,%3Csvg width='100' height='100' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='p'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.8' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23p)' opacity='.05'/%3E%3C/svg%3E\")",
            "fontFamily": "'Noto Sans JP', 'Lexend', sans-serif"
        }
    },
]

def _init_builtin_themes():
    for t in BUILTIN_THEMES:
        p = THEMES_DIR / f"{t['id']}.json"
        if not p.exists():
            p.write_text(json.dumps(t, ensure_ascii=False, indent=2), encoding="utf-8")

_init_builtin_themes()


class ThemeModel(BaseModel):
    id: str
    name: str
    colors: dict


@app.get("/api/themes")
async def list_themes(user=Depends(get_current_user)):
    themes = []
    for p in sorted(THEMES_DIR.glob("*.json")):
        try:
            themes.append(json.loads(p.read_text(encoding="utf-8")))
        except Exception:
            pass
    return themes


@app.post("/api/admin/themes")
async def save_theme(data: ThemeModel, user=Depends(require_admin)):
    if not re.match(r'^[a-z0-9-]{1,40}$', data.id):
        raise HTTPException(400, "ID invalide (a-z, 0-9, tirets, max 40 chars)")
    path = THEMES_DIR / f"{data.id}.json"
    if path.exists():
        existing = json.loads(path.read_text(encoding="utf-8"))
        if existing.get("builtin"):
            raise HTTPException(400, "Impossible de modifier un thème intégré")
    theme = {"id": data.id, "name": data.name, "builtin": False, "colors": data.colors}
    path.write_text(json.dumps(theme, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"ok": True}


@app.delete("/api/admin/themes/{theme_id}")
async def delete_theme(theme_id: str, user=Depends(require_admin)):
    path = THEMES_DIR / f"{theme_id}.json"
    if not path.exists():
        raise HTTPException(404, "Thème introuvable")
    if json.loads(path.read_text(encoding="utf-8")).get("builtin"):
        raise HTTPException(400, "Impossible de supprimer un thème intégré")
    path.unlink()
    return {"ok": True}


@app.get("/api/user/theme")
async def get_user_theme(user=Depends(get_current_user)):
    with get_db_ctx() as db:
        theme_id = get_config_val(db, f"theme_{user['id']}", "dark-default")
        path = THEMES_DIR / f"{theme_id}.json"
        if not path.exists():
            path = THEMES_DIR / "dark-default.json"
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
        return BUILTIN_THEMES[0]


@app.put("/api/user/theme")
async def set_user_theme(data: dict, user=Depends(get_current_user)):
    theme_id = str(data.get("theme_id", "dark-default"))
    with get_db_ctx() as db:
        set_config_val(db, f"theme_{user['id']}", theme_id)
        return {"ok": True}


    # ═══════════════════════════════════════════
    #  Export BDD pour Android
    # ═══════════════════════════════════════════

@app.get("/api/export/db")
def export_db(user=Depends(get_current_user)):
    """Exporte la BDD complète (avec covers/thumbnails) pour sync Android.
    
    Retourne un fichier SQLite prêt à l'emploi.
    """
    import shutil
    # Réutilise DB_PATH (le fichier réel, volontairement toujours nommé mangashelf.db --
    # voir le commentaire à sa définition) plutôt qu'un chemin reconstruit à la main, pour
    # ne jamais risquer que les deux divergent.
    db_path = DB_PATH
    if not db_path.exists():
        raise HTTPException(404, "Base de données introuvable")

    # Copie temporaire pour éviter les locks
    export_path = DATA_DIR / "tamashelf-export.db"
    shutil.copy2(str(db_path), str(export_path))

    # Nom de fichier renvoyé au client volontairement inchangé (mangashelf.db) : c'est le
    # nom réel de la base exportée (voir DB_PATH), et l'appli Flutter l'écrit de toute
    # façon sous son propre nom local (voir _dbPath dans db_service.dart) sans se fier à
    # ce header -- mais autant rester cohérent avec l'identité réelle du fichier.
    return FileResponse(
        str(export_path),
        media_type="application/x-sqlite3",
        filename="mangashelf.db",
        headers={"Cache-Control": "no-cache"}
    )


@app.get("/api/export/catalog")
def export_catalog(user=Depends(get_current_user)):
    """Exporte le catalogue complet en JSON (métadonnées, sans images).
    
    Pour Android: sync légère des métadonnées, les images sont téléchargées ensuite.
    """
    with get_db_ctx() as db:
        mangas = db.execute("""
            SELECT id, cbz_folder, nautiljon_url, title, cover_url, synopsis,
                   metadata_json, editions_json, match_status
            FROM manga_library ORDER BY title COLLATE NOCASE
        """).fetchall()
    
        volumes = db.execute("""
            SELECT id, cbz_folder, library_id, filename, filepath,
                   volume_num, volume_type, volume_display, source,
                   file_size, total_pages, chapters_json
            FROM manga_volumes ORDER BY cbz_folder, volume_num
        """).fetchall()
    
        progress = db.execute("""
            SELECT user_id, manga_url, volume_id, current_page, total_pages, last_read
            FROM reading_progress WHERE user_id = ?
        """, (user["id"],)).fetchall()
    
    
        return {
            "mangas": [dict(r) for r in mangas],
            "volumes": [dict(r) for r in volumes],
            "progress": [dict(r) for r in progress],
            "exported_at": time.time()
        }

    # ═══════════════════════════════════════════
    #  Serve Frontend (static files)
    # ═══════════════════════════════════════════

    # ── Ratings ──

@app.get("/api/ratings")
def get_ratings(user=Depends(get_current_user)):
    with get_db_ctx() as db:
        rows = db.execute("SELECT manga_id, rating FROM user_ratings WHERE user_id = ?", (user["id"],)).fetchall()
        return {r["manga_id"]: r["rating"] for r in rows}

@app.put("/api/ratings/{manga_id}")
def set_rating(manga_id: int, rating: int, user=Depends(get_current_user)):
    with get_db_ctx() as db:
        if rating < 1 or rating > 5:
            raise HTTPException(400, "Rating must be 1-5")
        db.execute("INSERT OR REPLACE INTO user_ratings (user_id, manga_id, rating, created_at) VALUES (?, ?, ?, ?)",
                   (user["id"], manga_id, rating, time.time()))
        db.commit()
        return {"ok": True}

@app.delete("/api/ratings/{manga_id}")
def delete_rating(manga_id: int, user=Depends(get_current_user)):
    with get_db_ctx() as db:
        db.execute("DELETE FROM user_ratings WHERE user_id = ? AND manga_id = ?", (user["id"], manga_id))
        db.commit()
        return {"ok": True}

    # ── Notes ──

@app.get("/api/notes")
def get_notes(user=Depends(get_current_user)):
    with get_db_ctx() as db:
        rows = db.execute("SELECT manga_id, note, updated_at FROM user_notes WHERE user_id = ?", (user["id"],)).fetchall()
        return {r["manga_id"]: {"note": r["note"], "updated_at": r["updated_at"]} for r in rows}

@app.put("/api/notes/{manga_id}")
def set_note(manga_id: int, user=Depends(get_current_user)):
    import json as _json
    body = None
    # Read body manually since it's a simple text
    return {"ok": True}

@app.post("/api/notes/{manga_id}")
def save_note(manga_id: int, user=Depends(get_current_user)):
    """Save a note. Body: {"note": "text"}"""
    # Legacy stub — use POST /api/notes/{manga_id}/save instead
    return {"ok": True}

# ── Collections ──

class CollectionCreate(BaseModel):
    name: str
    description: str = ""
    color: str = "#6366f1"
    icon: str = "📚"

class CollectionItemAdd(BaseModel):
    manga_id: int

class NoteBody(BaseModel):
    note: str = ""

@app.post("/api/notes/{manga_id}/save")
def save_note_v2(manga_id: int, body: NoteBody, user=Depends(get_current_user)):
    with get_db_ctx() as db:
        db.execute("INSERT OR REPLACE INTO user_notes (user_id, manga_id, note, updated_at) VALUES (?, ?, ?, ?)",
                   (user["id"], manga_id, body.note, time.time()))
        db.commit()
        return {"ok": True}

@app.get("/api/collections")
def get_collections(user=Depends(get_current_user)):
    with get_db_ctx() as db:
        cols = db.execute("SELECT * FROM user_collections WHERE user_id = ? ORDER BY created_at DESC", (user["id"],)).fetchall()
        result = []
        for c in cols:
            items = db.execute("SELECT manga_id FROM user_collection_items WHERE collection_id = ?", (c["id"],)).fetchall()
            result.append({**dict(c), "manga_ids": [i["manga_id"] for i in items], "count": len(items)})
        return result

@app.post("/api/collections")
def create_collection(body: CollectionCreate, user=Depends(get_current_user)):
    with get_db_ctx() as db:
        db.execute("INSERT INTO user_collections (user_id, name, description, color, icon) VALUES (?, ?, ?, ?, ?)",
                   (user["id"], body.name, body.description, body.color, body.icon))
        db.commit()
        cid = db.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
        return {"ok": True, "id": cid}

@app.delete("/api/collections/{collection_id}")
def delete_collection(collection_id: int, user=Depends(get_current_user)):
    with get_db_ctx() as db:
        db.execute("DELETE FROM user_collections WHERE id = ? AND user_id = ?", (collection_id, user["id"]))
        db.execute("DELETE FROM user_collection_items WHERE collection_id = ?", (collection_id,))
        db.commit()
        return {"ok": True}

@app.post("/api/collections/{collection_id}/add")
def add_to_collection(collection_id: int, body: CollectionItemAdd, user=Depends(get_current_user)):
    with get_db_ctx() as db:
        # Verify ownership
        col = db.execute("SELECT id FROM user_collections WHERE id = ? AND user_id = ?", (collection_id, user["id"])).fetchone()
        if not col:
            raise HTTPException(404)
        db.execute("INSERT OR IGNORE INTO user_collection_items (collection_id, manga_id) VALUES (?, ?)",
                   (collection_id, body.manga_id))
        db.commit()
        return {"ok": True}

@app.delete("/api/collections/{collection_id}/remove/{manga_id}")
def remove_from_collection(collection_id: int, manga_id: int, user=Depends(get_current_user)):
    with get_db_ctx() as db:
        db.execute("DELETE FROM user_collection_items WHERE collection_id = ? AND manga_id = ?", (collection_id, manga_id))
        db.commit()
        return {"ok": True}

    # ── Reading Stats ──

@app.post("/api/stats/log")
def log_reading_stat(user=Depends(get_current_user)):
    """Log reading activity. Body: {"pages": int, "volumes": int, "seconds": int}"""
    return {"ok": True}

class StatLog(BaseModel):
    pages: int = 0
    volumes: int = 0
    seconds: int = 0

@app.post("/api/stats/log-activity")
def log_activity(body: StatLog, user=Depends(get_current_user)):
    with get_db_ctx() as db:
        today = time.strftime("%Y-%m-%d")
        existing = db.execute("SELECT * FROM reading_stats WHERE user_id = ? AND date = ?", (user["id"], today)).fetchone()
        if existing:
            db.execute("UPDATE reading_stats SET pages_read = pages_read + ?, volumes_read = volumes_read + ?, time_seconds = time_seconds + ? WHERE user_id = ? AND date = ?",
                       (body.pages, body.volumes, body.seconds, user["id"], today))
        else:
            db.execute("INSERT INTO reading_stats (user_id, date, pages_read, volumes_read, time_seconds) VALUES (?, ?, ?, ?, ?)",
                       (user["id"], today, body.pages, body.volumes, body.seconds))
        db.commit()
        return {"ok": True}

@app.get("/api/stats")
def get_stats(user=Depends(get_current_user)):
    with get_db_ctx() as db:
        totals = db.execute("""
            SELECT COALESCE(SUM(pages_read), 0) as total_pages,
                   COALESCE(SUM(volumes_read), 0) as total_volumes,
                   COALESCE(SUM(time_seconds), 0) as total_seconds,
                   COUNT(DISTINCT date) as active_days
            FROM reading_stats WHERE user_id = ?
        """, (user["id"],)).fetchone()

        daily = db.execute("""
            SELECT date, pages_read, volumes_read, time_seconds
            FROM reading_stats WHERE user_id = ? AND date >= date('now', '-30 days')
            ORDER BY date
        """, (user["id"],)).fetchall()

        genre_counts = {}
        rated = db.execute("""
            SELECT m.metadata_json FROM user_ratings r
            JOIN manga_library m ON m.id = r.manga_id
            WHERE r.user_id = ?
        """, (user["id"],)).fetchall()
        for row in rated:
            try:
                meta = json.loads(row["metadata_json"] or "{}")
                for g in str(meta.get("Genres", "")).split(" - "):
                    g = g.strip()
                    if g:
                        genre_counts[g] = genre_counts.get(g, 0) + 1
            except:
                pass

        progress = db.execute("""
            SELECT COUNT(*) as in_progress FROM reading_progress
            WHERE user_id = ? AND current_page > 0 AND current_page < total_pages - 1
        """, (user["id"],)).fetchone()

    return {
        "total_pages": totals["total_pages"],
        "total_volumes": totals["total_volumes"],
        "total_seconds": totals["total_seconds"],
        "active_days": totals["active_days"],
        "daily": [dict(d) for d in daily],
        "top_genres": sorted(genre_counts.items(), key=lambda x: -x[1])[:10],
        "in_progress": progress["in_progress"],
    }

# ── Homepage ──

@app.get("/api/homepage")
def get_homepage(user=Depends(get_current_user)):
    with get_db_ctx() as db:
        recent = db.execute("""
            SELECT id, cbz_folder, title, cover_url, match_status
            FROM manga_library ORDER BY synced_at DESC LIMIT 12
        """).fetchall()

        progress = db.execute("""
            SELECT manga_url, volume_id, current_page, total_pages, title, last_read
            FROM reading_progress WHERE user_id = ? AND current_page > 0
            ORDER BY last_read DESC LIMIT 10
        """, (user["id"],)).fetchall()

        top_rated = db.execute("""
            SELECT m.id, m.cbz_folder, m.title, m.cover_url, r.rating
            FROM user_ratings r JOIN manga_library m ON m.id = r.manga_id
            WHERE r.user_id = ? ORDER BY r.rating DESC, r.created_at DESC LIMIT 10
        """, (user["id"],)).fetchall()

        genre_counts = {}
        for row in top_rated:
            try:
                meta_row = db.execute("SELECT metadata_json FROM manga_library WHERE id = ?", (row["id"],)).fetchone()
                if meta_row:
                    meta = json.loads(meta_row["metadata_json"] or "{}")
                    for g in str(meta.get("Genres", "")).split(" - "):
                        g = g.strip()
                        if g:
                            genre_counts[g] = genre_counts.get(g, 0) + 1
            except:
                pass

        rated_ids = {r["id"] for r in top_rated}
        recommendations = []
        if genre_counts:
            top_genre = max(genre_counts, key=genre_counts.get)
            recs = db.execute("""
                SELECT id, cbz_folder, title, cover_url, metadata_json
                FROM manga_library WHERE metadata_json LIKE ? AND match_status = 'matched'
                ORDER BY RANDOM() LIMIT 20
            """, (f"%{top_genre}%",)).fetchall()
            for r in recs:
                if r["id"] not in rated_ids and len(recommendations) < 8:
                    recommendations.append(dict(r))

    return {
        "recent": [dict(r) for r in recent],
        "progress": [dict(r) for r in progress],
        "top_rated": [dict(r) for r in top_rated],
        "recommendations": recommendations,
        "top_genre": max(genre_counts, key=genre_counts.get) if genre_counts else None,
    }


# ═══════════════════════════════════════════
#  Activity Feed (what other users are reading)
# ═══════════════════════════════════════════

@app.get("/api/activity")
def get_activity(user=Depends(get_current_user)):
    """Recent reading activity across all users (anonymised by default)."""
    with get_db_ctx() as db:
        rows = db.execute("""
            SELECT u.username, rp.manga_url, rp.volume_id, rp.current_page, rp.total_pages, rp.title, rp.last_read
            FROM reading_progress rp
            JOIN users u ON u.id = rp.user_id
            WHERE rp.current_page > 0 AND rp.last_read > ?
            ORDER BY rp.last_read DESC LIMIT 30
        """, (time.time() - 7 * 86400,)).fetchall()
    return [dict(r) for r in rows]


# ═══════════════════════════════════════════
#  Notifications (new volumes in followed series)
# ═══════════════════════════════════════════

@app.get("/api/notifications")
def get_notifications(user=Depends(get_current_user)):
    """New volumes added to series the user has read or bookmarked."""
    with get_db_ctx() as db:
        # Find folders the user has interacted with
        followed = db.execute("""
            SELECT DISTINCT manga_url FROM reading_progress WHERE user_id = ?
            UNION
            SELECT DISTINCT manga_url FROM user_list_items WHERE user_id = ?
        """, (user["id"], user["id"])).fetchall()
        followed_folders = {r["manga_url"] for r in followed}

        if not followed_folders:
            return []

        # Find recently scanned volumes in those folders
        ph = ",".join("?" * len(followed_folders))
        new_vols = db.execute(f"""
            SELECT v.cbz_folder, v.filename, v.volume_display, v.volume_num, v.scanned_at,
                   m.title as manga_title
            FROM manga_volumes v
            JOIN manga_library m ON m.cbz_folder = v.cbz_folder
            WHERE v.cbz_folder IN ({ph})
              AND v.scanned_at > ?
            ORDER BY v.scanned_at DESC LIMIT 20
        """, [*followed_folders, time.time() - 30 * 86400]).fetchall()

    return [dict(r) for r in new_vols]


# ═══════════════════════════════════════════
#  Full-text search (metadata + synopsis)
# ═══════════════════════════════════════════

@app.get("/api/search")
def fulltext_search(q: str = "", user=Depends(get_current_user)):
    """Search mangas by title, synopsis, author, genre, etc."""
    if not q.strip():
        return {"results": []}
    query = q.strip()
    with get_db_ctx() as db:
        accessible_ids = get_user_library_ids(db, user["id"], user["role"])
        if not accessible_ids:
            return {"results": []}
        ph = ",".join("?" * len(accessible_ids))
        rows = db.execute(f"""
            SELECT id, cbz_folder, title, cover_url, synopsis, metadata_json, match_status
            FROM manga_library
            WHERE library_id IN ({ph})
              AND (title LIKE ? OR cbz_folder LIKE ? OR synopsis LIKE ? OR metadata_json LIKE ?)
            ORDER BY
              CASE WHEN title LIKE ? THEN 0
                   WHEN metadata_json LIKE ? THEN 1
                   ELSE 2 END,
              title COLLATE NOCASE
            LIMIT 50
        """, [*accessible_ids, f"%{query}%", f"%{query}%", f"%{query}%", f"%{query}%",
              f"%{query}%", f"%{query}%"]).fetchall()

    results = []
    for r in rows:
        try:
            meta = json.loads(r["metadata_json"] or "{}")
        except Exception:
            meta = {}
        # Find which field matched
        match_field = "title"
        if query.lower() not in (r["title"] or "").lower():
            if query.lower() in (r["synopsis"] or "").lower():
                match_field = "synopsis"
            else:
                for k, v in meta.items():
                    if query.lower() in str(v).lower():
                        match_field = k
                        break
        results.append({
            "id": r["id"],
            "cbz_folder": r["cbz_folder"],
            "title": r["title"],
            "cover_url": r["cover_url"] or "",
            "match_field": match_field,
            "synopsis_excerpt": (r["synopsis"] or "")[:150],
            "match_status": r["match_status"],
        })
    return {"results": results, "total": len(results)}


# ═══════════════════════════════════════════
#  Import / Export reading lists
# ═══════════════════════════════════════════

@app.get("/api/lists/export")
def export_lists(user=Depends(get_current_user)):
    """Export all user lists as JSON."""
    with get_db_ctx() as db:
        items = db.execute("""
            SELECT list_name, manga_url, volume_id, item_type, title, auto_added, created_at
            FROM user_list_items WHERE user_id = ? ORDER BY list_name, created_at
        """, (user["id"],)).fetchall()
        progress = db.execute("""
            SELECT manga_url, volume_id, current_page, total_pages, title, last_read
            FROM reading_progress WHERE user_id = ? ORDER BY last_read DESC
        """, (user["id"],)).fetchall()
        ratings = db.execute("SELECT manga_id, rating FROM user_ratings WHERE user_id = ?", (user["id"],)).fetchall()
        notes = db.execute("SELECT manga_id, note FROM user_notes WHERE user_id = ?", (user["id"],)).fetchall()
        collections = db.execute("SELECT id, name, description, color, icon FROM user_collections WHERE user_id = ?", (user["id"],)).fetchall()
        col_items = {}
        for c in collections:
            ci = db.execute("SELECT manga_id FROM user_collection_items WHERE collection_id = ?", (c["id"],)).fetchall()
            col_items[c["id"]] = [r["manga_id"] for r in ci]

    return {
        "version": 1,
        "exported_at": time.time(),
        "username": user["username"],
        "lists": [dict(r) for r in items],
        "progress": [dict(r) for r in progress],
        "ratings": {str(r["manga_id"]): r["rating"] for r in ratings},
        "notes": {str(r["manga_id"]): r["note"] for r in notes},
        "collections": [{**dict(c), "manga_ids": col_items.get(c["id"], [])} for c in collections],
    }


class ImportData(BaseModel):
    lists: list = []
    progress: list = []
    ratings: dict = {}
    notes: dict = {}
    collections: list = []

@app.post("/api/lists/import")
def import_lists(data: ImportData, user=Depends(get_current_user)):
    """Import lists, progress, ratings, notes, collections from JSON."""
    imported = {"lists": 0, "progress": 0, "ratings": 0, "notes": 0, "collections": 0}
    with get_db_ctx() as db:
        for item in data.lists:
            try:
                db.execute("""
                    INSERT OR IGNORE INTO user_list_items (user_id, list_name, manga_url, volume_id, item_type, title, auto_added)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, (user["id"], item.get("list_name", ""), item.get("manga_url", ""),
                      item.get("volume_id", ""), item.get("item_type", ""), item.get("title", ""),
                      1 if item.get("auto_added") else 0))
                imported["lists"] += 1
            except Exception:
                pass

        for p in data.progress:
            try:
                db.execute("""
                    INSERT OR REPLACE INTO reading_progress (user_id, manga_url, volume_id, current_page, total_pages, title, last_read)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, (user["id"], p.get("manga_url", ""), p.get("volume_id", ""),
                      p.get("current_page", 0), p.get("total_pages", 0), p.get("title", ""),
                      p.get("last_read", time.time())))
                imported["progress"] += 1
            except Exception:
                pass

        for mid, rating in data.ratings.items():
            try:
                db.execute("INSERT OR REPLACE INTO user_ratings (user_id, manga_id, rating, created_at) VALUES (?, ?, ?, ?)",
                           (user["id"], int(mid), int(rating), time.time()))
                imported["ratings"] += 1
            except Exception:
                pass

        for mid, note in data.notes.items():
            try:
                db.execute("INSERT OR REPLACE INTO user_notes (user_id, manga_id, note, updated_at) VALUES (?, ?, ?, ?)",
                           (user["id"], int(mid), str(note), time.time()))
                imported["notes"] += 1
            except Exception:
                pass

        for col in data.collections:
            try:
                db.execute("INSERT INTO user_collections (user_id, name, description, color, icon) VALUES (?, ?, ?, ?, ?)",
                           (user["id"], col.get("name", ""), col.get("description", ""),
                            col.get("color", "#6366f1"), col.get("icon", "📚")))
                cid = db.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
                for mid in col.get("manga_ids", []):
                    db.execute("INSERT OR IGNORE INTO user_collection_items (collection_id, manga_id) VALUES (?, ?)", (cid, int(mid)))
                imported["collections"] += 1
            except Exception:
                pass

        db.commit()
    return {"ok": True, "imported": imported}


# ═══════════════════════════════════════════
#  OPDS Catalog (compatible Tachiyomi, Panels, Chunky, etc.)
# ═══════════════════════════════════════════

_OPDS_NS = 'xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog"'
_OPDS_MIME = "application/atom+xml;profile=opds-catalog;kind=acquisition"

def _opds_entry_xml(manga_id, title, cbz_folder, synopsis="", updated=""):
    """Build a single OPDS entry XML string."""
    safe_title = (title or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    safe_syn = (synopsis or "")[:300].replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    updated_tag = f"<updated>{updated}</updated>" if updated else ""
    return f"""<entry>
  <title>{safe_title}</title>
  <id>urn:tamashelf:{manga_id}</id>
  {updated_tag}
  <content type="text">{safe_syn}</content>
  <link rel="http://opds-spec.org/image" href="/api/cbz/folder-cover/{cbz_folder}" type="image/jpeg"/>
  <link rel="http://opds-spec.org/image/thumbnail" href="/api/cbz/folder-cover/{cbz_folder}" type="image/jpeg"/>
  <link rel="subsection" href="/opds/manga/{manga_id}" type="{_OPDS_MIME}"/>
</entry>"""


@app.get("/opds")
@app.get("/opds/")
def opds_root(user=Depends(get_current_user)):
    """OPDS root catalog."""
    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<feed {_OPDS_NS}>
  <id>urn:tamashelf:root</id>
  <title>TamaShelf</title>
  <updated>{time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}</updated>
  <author><name>TamaShelf</name></author>
  <link rel="self" href="/opds" type="{_OPDS_MIME}"/>
  <link rel="start" href="/opds" type="{_OPDS_MIME}"/>
  <entry>
    <title>Tous les mangas</title>
    <id>urn:tamashelf:all</id>
    <link rel="subsection" href="/opds/all" type="{_OPDS_MIME}"/>
    <content type="text">Parcourir toute la bibliothèque</content>
  </entry>
</feed>"""
    return Response(content=xml, media_type=_OPDS_MIME)


@app.get("/opds/all")
def opds_all(user=Depends(get_current_user)):
    """OPDS: list all mangas."""
    with get_db_ctx() as db:
        accessible_ids = get_user_library_ids(db, user["id"], user["role"])
        if not accessible_ids:
            rows = []
        else:
            ph = ",".join("?" * len(accessible_ids))
            rows = db.execute(
                f"SELECT id, cbz_folder, title, synopsis FROM manga_library WHERE library_id IN ({ph}) ORDER BY title COLLATE NOCASE",
                accessible_ids
            ).fetchall()

    entries = "\n".join(_opds_entry_xml(r["id"], r["title"], r["cbz_folder"], r["synopsis"]) for r in rows)
    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<feed {_OPDS_NS}>
  <id>urn:tamashelf:all</id>
  <title>Tous les mangas</title>
  <updated>{time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}</updated>
  <link rel="self" href="/opds/all" type="{_OPDS_MIME}"/>
  <link rel="start" href="/opds" type="{_OPDS_MIME}"/>
  {entries}
</feed>"""
    return Response(content=xml, media_type=_OPDS_MIME)


@app.get("/opds/manga/{manga_id}")
def opds_manga(manga_id: int, user=Depends(get_current_user)):
    """OPDS: list volumes of a manga for download."""
    with get_db_ctx() as db:
        manga = db.execute("SELECT id, cbz_folder, title, synopsis FROM manga_library WHERE id = ?", (manga_id,)).fetchone()
        if not manga:
            raise HTTPException(404)
        volumes = db.execute(
            "SELECT id, filename, filepath, volume_num, volume_display, file_size, total_pages FROM manga_volumes WHERE cbz_folder = ? ORDER BY volume_num ASC, filename ASC",
            (manga["cbz_folder"],)
        ).fetchall()

    safe_title = (manga["title"] or "").replace("&", "&amp;").replace("<", "&lt;")
    vol_entries = []
    for v in volumes:
        vname = (v["volume_display"] or v["filename"] or f"Vol {v['volume_num']}").replace("&", "&amp;").replace("<", "&lt;")
        size = v["file_size"] or 0
        vol_entries.append(f"""<entry>
  <title>{vname}</title>
  <id>urn:tamashelf:vol:{v['id']}</id>
  <content type="text">{v['total_pages']} pages</content>
  <link rel="http://opds-spec.org/image/thumbnail" href="/api/cbz/thumbnail/{v['filepath']}" type="image/jpeg"/>
  <link rel="http://opds-spec.org/acquisition" href="/api/cbz/download/{v['filepath']}" type="application/x-cbz" length="{size}"/>
</entry>""")

    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<feed {_OPDS_NS}>
  <id>urn:tamashelf:manga:{manga_id}</id>
  <title>{safe_title}</title>
  <updated>{time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}</updated>
  <link rel="self" href="/opds/manga/{manga_id}" type="{_OPDS_MIME}"/>
  <link rel="start" href="/opds" type="{_OPDS_MIME}"/>
  <link rel="up" href="/opds/all" type="{_OPDS_MIME}"/>
  {chr(10).join(vol_entries)}
</feed>"""
    return Response(content=xml, media_type=_OPDS_MIME)


# ═══════════════════════════════════════════
#  Serve Frontend (static files)
# ═══════════════════════════════════════════

if STATIC_DIR.exists():
    app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")
