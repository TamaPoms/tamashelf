"""
Tests backend TamaShelf — pytest
Run: cd backend && pip install pytest httpx && pytest tests/ -v
"""
import os
import sys
import tempfile

_tmp = tempfile.mkdtemp()
os.environ["TAMASHELF_DATA"] = _tmp
os.environ["TAMASHELF_STATIC"] = "/nonexistent"
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

import sqlite3
from fastapi.testclient import TestClient
import main
from main import app, get_db_ctx, hash_password, verify_password, migrate_db

client = TestClient(app)
_token = None

def get_token():
    global _token
    if _token:
        return _token
    resp = client.post("/api/setup", json={
        "username": "admin", "password": "test1234", "cbz_path": "/tmp/cbz",
    })
    if resp.status_code == 200:
        _token = resp.json()["token"]
        return _token
    resp = client.post("/api/login", json={"username": "admin", "password": "test1234"})
    if resp.status_code == 200:
        _token = resp.json()["token"]
        return _token
    resp = client.post("/api/login", json={"username": "admin", "password": "newpass456"})
    if resp.status_code == 200:
        _token = resp.json()["token"]
        return _token
    raise RuntimeError(f"Cannot auth")

def auth():
    return {"Authorization": f"Bearer {get_token()}"}

def _ensure_manga(mid=1):
    with get_db_ctx() as db:
        # Ensure a library exists
        lib = db.execute("SELECT id FROM libraries LIMIT 1").fetchone()
        lib_id = lib["id"] if lib else 1
        db.execute("INSERT OR IGNORE INTO manga_library (id, cbz_folder, title, match_status, library_id) VALUES (?, ?, ?, 'matched', ?)",
                   (mid, f"test-folder-{mid}", f"Test Manga {mid}", lib_id))
        db.commit()

class TestPasswordHashing:
    def test_hash_verify(self):
        h = hash_password("hello123")
        assert verify_password("hello123", h)
        assert not verify_password("wrong", h)

    def test_legacy_pbkdf2(self):
        import hashlib, secrets
        salt = secrets.token_hex(16)
        h = hashlib.pbkdf2_hmac("sha256", "leg".encode(), salt.encode(), 100000)
        assert verify_password("leg", f"{salt}:{h.hex()}")

class TestAuth:
    def test_setup_status(self):
        assert client.get("/api/setup-status").status_code == 200

    def test_login(self):
        get_token()
        resp = client.post("/api/login", json={"username": "admin", "password": "test1234"})
        assert resp.status_code == 200

    def test_login_wrong(self):
        assert client.post("/api/login", json={"username": "admin", "password": "wrong"}).status_code in (401, 400)

    def test_me(self):
        resp = client.get("/api/me", headers=auth())
        assert resp.status_code == 200
        assert resp.json()["username"] == "admin"

    def test_unauthorized(self):
        assert client.get("/api/me").status_code == 401

class TestProgress:
    def test_save_and_get(self):
        assert client.post("/api/progress", json={
            "manga_url": "prog-test", "volume_id": "v1.cbz",
            "current_page": 5, "total_pages": 100, "title": "Test",
        }, headers=auth()).status_code == 200
        resp = client.get("/api/progress", headers=auth())
        assert resp.status_code == 200
        assert any(p["manga_url"] == "prog-test" for p in resp.json())

    def test_delete(self):
        client.post("/api/progress", json={
            "manga_url": "del-test", "volume_id": "v1.cbz",
            "current_page": 1, "total_pages": 10, "title": "D",
        }, headers=auth())
        assert client.delete("/api/progress?manga_url=del-test&volume_id=v1.cbz", headers=auth()).status_code == 200

class TestRatings:
    def test_crud(self):
        _ensure_manga(10)
        assert client.put("/api/ratings/10?rating=4", headers=auth()).status_code == 200
        resp = client.get("/api/ratings", headers=auth())
        assert resp.status_code == 200
        assert resp.json().get("10") == 4
        assert client.delete("/api/ratings/10", headers=auth()).status_code == 200

class TestNotes:
    def test_save_get(self):
        _ensure_manga(20)
        assert client.post("/api/notes/20/save", json={"note": "Super"}, headers=auth()).status_code == 200
        assert client.get("/api/notes", headers=auth()).status_code == 200

class TestCollections:
    def test_crud(self):
        resp = client.post("/api/collections", json={"name": "Favs", "color": "#f43f5e", "icon": "S"}, headers=auth())
        assert resp.status_code == 200
        cid = resp.json()["id"]
        assert any(c["name"] == "Favs" for c in client.get("/api/collections", headers=auth()).json())
        assert client.delete(f"/api/collections/{cid}", headers=auth()).status_code == 200

class TestStats:
    def test_get(self):
        resp = client.get("/api/stats", headers=auth())
        assert resp.status_code == 200
        d = resp.json()
        # Accept either format (old summary or new detailed)
        assert "total_pages" in d or "users" in d

    def test_log(self):
        assert client.post("/api/stats/log-activity", json={"pages": 10, "volumes": 0, "seconds": 300}, headers=auth()).status_code == 200

class TestHomepage:
    def test_get(self):
        resp = client.get("/api/homepage", headers=auth())
        assert resp.status_code == 200
        assert "recent" in resp.json()

class TestLibrary:
    def test_get(self):
        resp = client.get("/api/library", headers=auth())
        assert resp.status_code == 200
        assert "items" in resp.json()

    def test_pagination(self):
        resp = client.get("/api/library?limit=5&offset=0", headers=auth())
        assert resp.status_code == 200
        assert "has_more" in resp.json()

class TestOPDS:
    def test_root(self):
        resp = client.get("/opds", headers=auth())
        assert resp.status_code == 200
        assert "<feed" in resp.text

    def test_all(self):
        assert "<feed" in client.get("/opds/all", headers=auth()).text

    def test_manga_404(self):
        assert client.get("/opds/manga/99999", headers=auth()).status_code == 404

    def test_manga_ok(self):
        _ensure_manga(40)
        resp = client.get("/opds/manga/40", headers=auth())
        assert resp.status_code == 200

class TestActivity:
    def test_get(self):
        resp = client.get("/api/activity", headers=auth())
        assert resp.status_code == 200
        assert isinstance(resp.json(), list)

class TestNotifications:
    def test_get(self):
        resp = client.get("/api/notifications", headers=auth())
        assert resp.status_code == 200
        assert isinstance(resp.json(), list)

class TestFullTextSearch:
    def test_empty(self):
        resp = client.get("/api/search?q=", headers=auth())
        assert resp.status_code == 200
        assert resp.json()["results"] == []

    def test_search_title(self):
        _ensure_manga(50)
        resp = client.get("/api/search?q=Test", headers=auth())
        assert resp.status_code == 200
        assert resp.json()["total"] > 0

    def test_no_results(self):
        resp = client.get("/api/search?q=xyznonexistent999", headers=auth())
        assert resp.status_code == 200
        assert resp.json()["total"] == 0

class TestImportExport:
    def test_export(self):
        resp = client.get("/api/lists/export", headers=auth())
        assert resp.status_code == 200
        data = resp.json()
        assert "version" in data
        assert "lists" in data
        assert "ratings" in data
        assert "collections" in data

    def test_import(self):
        resp = client.post("/api/lists/import", json={
            "lists": [{"list_name": "to_read", "manga_url": "import-test", "volume_id": "", "item_type": "manga", "title": "Imported"}],
            "progress": [],
            "ratings": {},
            "notes": {},
            "collections": [{"name": "Imported Col", "color": "#ff0000", "icon": "X", "manga_ids": []}],
        }, headers=auth())
        assert resp.status_code == 200
        imported = resp.json()["imported"]
        assert imported["lists"] >= 1
        assert imported["collections"] >= 1

    def test_roundtrip(self):
        # Export then re-import should work
        exp = client.get("/api/lists/export", headers=auth()).json()
        resp = client.post("/api/lists/import", json=exp, headers=auth())
        assert resp.status_code == 200

class TestScanNestedEditions:
    """Structure mixte : un dossier manga avec des tomes "en vrac" (édition
    standard) ET des sous-dossiers d'édition contenant eux-mêmes des tomes
    (ex: Dragon Ball/T01.cbz + Dragon Ball/Dragon Ball - Perfect Edition/T01.cbz).
    Avant le fix, le dossier parent qualifiait à lui seul comme "manga profondeur
    1" (il a des .cbz en vrac) et ses sous-dossiers n'étaient donc jamais
    explorés -> les éditions imbriquées restaient invisibles."""

    def _make_structure(self):
        base = tempfile.mkdtemp()
        root = os.path.join(base, "Dragon Ball")
        os.makedirs(root)
        for i in (1, 2):
            with open(os.path.join(root, f"Dragon Ball T{i:02d}.cbz"), "wb") as f:
                f.write(b"PK\x03\x04")  # en-tete zip minimal, suffisant pour le scan (pas l'ouverture)
        edition = os.path.join(root, "Dragon Ball - Perfect Edition")
        os.makedirs(edition)
        for i in (1, 2):
            with open(os.path.join(edition, f"Dragon Ball - Perfect Edition T{i:02d}.cbz"), "wb") as f:
                f.write(b"PK\x03\x04")
        return base

    def test_nested_edition_is_scanned(self):
        base = self._make_structure()
        resp = client.post("/api/admin/libraries", json={"name": "DBTest", "cbz_path": base, "is_public": False}, headers=auth())
        assert resp.status_code == 200
        lib_id = resp.json()["id"]

        resp = client.post(f"/api/admin/scan-folders?library_id={lib_id}", headers=auth())
        assert resp.status_code == 200

        with get_db_ctx() as db:
            rows = db.execute("SELECT cbz_folder FROM manga_library WHERE library_id = ?", (lib_id,)).fetchall()
            folders = {r["cbz_folder"] for r in rows}

        # Le dossier standard ET l'édition imbriquée doivent chacun avoir leur
        # propre entrée manga_library, pas seulement le dossier racine.
        assert "Dragon Ball" in folders
        assert "Dragon Ball/Dragon Ball - Perfect Edition" in folders


class TestRebuildLibraryIndex:
    """rebuild-index doit : 1) nettoyer les tomes/fiches périmés (dossier disparu du
    disque), 2) garder intact le matching Nautiljon déjà fait des mangas dont le dossier
    existe toujours, 3) redécouvrir les dossiers réellement présents (dont les éditions
    imbriquées)."""

    def test_rebuild(self):
        base = tempfile.mkdtemp()
        keep = os.path.join(base, "One Piece")
        os.makedirs(keep)
        with open(os.path.join(keep, "One Piece T01.cbz"), "wb") as f:
            f.write(b"PK\x03\x04")

        resp = client.post("/api/admin/libraries", json={"name": "RebuildTest", "cbz_path": base, "is_public": False}, headers=auth())
        lib_id = resp.json()["id"]

        # Fiche "fantôme" : dossier qui n'existe plus du tout sur le disque -- simule un
        # renommage/déplacement/suppression survenu depuis le dernier scan.
        with get_db_ctx() as db:
            db.execute(
                "INSERT INTO manga_library (cbz_folder, title, match_status, library_id, nautiljon_url) "
                "VALUES (?, ?, 'matched', ?, ?)",
                ("Dossier Disparu", "Dossier Disparu", lib_id, "https://example.com/disparu")
            )
            db.commit()

        # Scan initial + on simule un matching déjà fait sur "One Piece" (doit survivre au
        # rebuild) et un tome à un chemin périmé qui doit disparaître (fichier renommé).
        client.post(f"/api/admin/scan-folders?library_id={lib_id}", headers=auth())
        with get_db_ctx() as db:
            db.execute("UPDATE manga_library SET match_status = 'matched', nautiljon_url = 'https://example.com/op', synopsis = 'Un trésor...' WHERE cbz_folder = 'One Piece' AND library_id = ?", (lib_id,))
            db.execute(
                "INSERT INTO manga_volumes (cbz_folder, library_id, filename, filepath, volume_num, source) "
                "VALUES ('One Piece', ?, 'One Piece T99-perime.cbz', 'One Piece/One Piece T99-perime.cbz', 99, 'archive')",
                (lib_id,)
            )
            db.commit()

        resp = client.post(f"/api/admin/libraries/{lib_id}/rebuild-index", headers=auth())
        assert resp.status_code == 200
        data = resp.json()
        assert data["removed_stale"] == 1  # "Dossier Disparu"

        with get_db_ctx() as db:
            folders = {r["cbz_folder"] for r in db.execute("SELECT cbz_folder FROM manga_library WHERE library_id = ?", (lib_id,)).fetchall()}
            assert "Dossier Disparu" not in folders
            op = db.execute("SELECT match_status, nautiljon_url, synopsis FROM manga_library WHERE cbz_folder = 'One Piece' AND library_id = ?", (lib_id,)).fetchone()
            assert op["match_status"] == "matched"  # matching Nautiljon conservé
            assert op["synopsis"] == "Un trésor..."
            vols = {r["filename"] for r in db.execute("SELECT filename FROM manga_volumes WHERE cbz_folder = 'One Piece' AND library_id = ?", (lib_id,)).fetchall()}
            assert "One Piece T99-perime.cbz" not in vols  # tome périmé nettoyé
            assert "One Piece T01.cbz" in vols  # vrai fichier réindexé


class TestCrossLibrarySameFolderName:
    """Deux bibliothèques différentes peuvent chacune avoir un dossier du même nom (ex:
    "Dragon Ball" dans 2 bibliothèques) -- elles doivent obtenir chacune leur propre fiche
    manga_library (jamais fusionnées/écrasées), grâce à UNIQUE(cbz_folder, library_id)."""

    def test_two_libraries_same_folder_name(self):
        base_a = tempfile.mkdtemp()
        base_b = tempfile.mkdtemp()
        for base in (base_a, base_b):
            root = os.path.join(base, "Dragon Ball")
            os.makedirs(root)
            with open(os.path.join(root, "Dragon Ball T01.cbz"), "wb") as f:
                f.write(b"PK\x03\x04")

        lib_a = client.post("/api/admin/libraries", json={"name": "LibA", "cbz_path": base_a, "is_public": False}, headers=auth()).json()["id"]
        lib_b = client.post("/api/admin/libraries", json={"name": "LibB", "cbz_path": base_b, "is_public": False}, headers=auth()).json()["id"]

        client.post(f"/api/admin/scan-folders?library_id={lib_a}", headers=auth())
        client.post(f"/api/admin/scan-folders?library_id={lib_b}", headers=auth())

        with get_db_ctx() as db:
            rows = db.execute("SELECT id, library_id FROM manga_library WHERE cbz_folder = 'Dragon Ball' AND library_id IN (?, ?)", (lib_a, lib_b)).fetchall()
            lib_ids = {r["library_id"] for r in rows}
            assert lib_ids == {lib_a, lib_b}  # chaque bibliothèque a bien sa propre fiche
            assert len(rows) == 2

            vols_a = db.execute("SELECT COUNT(*) as c FROM manga_volumes WHERE cbz_folder = 'Dragon Ball' AND library_id = ?", (lib_a,)).fetchone()["c"]
            vols_b = db.execute("SELECT COUNT(*) as c FROM manga_volumes WHERE cbz_folder = 'Dragon Ball' AND library_id = ?", (lib_b,)).fetchone()["c"]
            assert vols_a == 1
            assert vols_b == 1

        # La liste principale (toutes bibliothèques confondues) ne doit PAS fusionner les
        # deux -- elle doit renvoyer les 2 fiches séparément.
        listing = client.get("/api/library", headers=auth()).json()
        dragon_ball_items = [it for it in listing["items"] if it["cbz_folder"] == "Dragon Ball" and it["library_id"] in (lib_a, lib_b)]
        assert len(dragon_ball_items) == 2


class TestMigrateManualLibraryUnique:
    """migrate_db() doit faire évoluer une base à l'ancien schéma (cbz_folder UNIQUE seul,
    sans library_id dans la contrainte) vers UNIQUE(cbz_folder, library_id), sans perdre de
    données ni changer les ids (référencés ailleurs par valeur : ratings, notes...)."""

    def test_migration_upgrades_old_schema(self):
        scratch_dir = tempfile.mkdtemp()
        scratch_db = os.path.join(scratch_dir, "legacy.db")

        # Construit une base minimale à l'ANCIEN schéma (avant migration).
        conn = sqlite3.connect(scratch_db)
        conn.executescript("""
            CREATE TABLE manga_library (
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
                synced_at REAL NOT NULL DEFAULT (unixepoch()),
                library_id INTEGER
            );
            CREATE TABLE libraries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                cbz_path TEXT NOT NULL DEFAULT '',
                is_public INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE reading_progress (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL,
                manga_url TEXT NOT NULL,
                volume_id TEXT NOT NULL DEFAULT '',
                current_page INTEGER NOT NULL DEFAULT 0,
                total_pages INTEGER NOT NULL DEFAULT 0,
                title TEXT,
                last_read REAL NOT NULL DEFAULT 0,
                UNIQUE(user_id, manga_url, volume_id)
            );
            CREATE TABLE manga_volumes (
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
                scanned_at REAL NOT NULL DEFAULT (unixepoch())
            );
        """)
        conn.execute("INSERT INTO libraries (id, name, cbz_path) VALUES (1, 'Principale', '/tmp/x')")
        conn.execute("INSERT INTO manga_library (id, cbz_folder, title, match_status, library_id) VALUES (42, 'One Piece', 'One Piece', 'matched', 1)")
        conn.commit()
        conn.close()

        original_db_path = main.DB_PATH
        try:
            main.DB_PATH = scratch_db
            migrate_db()

            conn = sqlite3.connect(scratch_db)
            conn.row_factory = sqlite3.Row
            row = conn.execute("SELECT id, cbz_folder, title, library_id FROM manga_library WHERE cbz_folder = 'One Piece'").fetchone()
            assert row is not None
            assert row["id"] == 42  # id préservé (référencé par ratings/notes/collections)
            assert row["library_id"] == 1

            # La contrainte doit maintenant être composite, pas seulement sur cbz_folder.
            has_composite_unique = False
            for idx in conn.execute("PRAGMA index_list(manga_library)").fetchall():
                if idx["unique"]:
                    cols = {r["name"] for r in conn.execute(f"PRAGMA index_info('{idx['name']}')").fetchall()}
                    if cols == {"cbz_folder", "library_id"}:
                        has_composite_unique = True
            assert has_composite_unique

            # Un second manga du même nom de dossier dans une AUTRE bibliothèque doit
            # maintenant être accepté (c'était impossible avec l'ancien schéma).
            conn.execute("INSERT INTO libraries (id, name, cbz_path) VALUES (2, 'Secondaire', '/tmp/y')")
            conn.execute("INSERT INTO manga_library (cbz_folder, title, match_status, library_id) VALUES ('One Piece', 'One Piece', 'unmatched', 2)")
            conn.commit()
            count = conn.execute("SELECT COUNT(*) as c FROM manga_library WHERE cbz_folder = 'One Piece'").fetchone()["c"]
            assert count == 2
            conn.close()
        finally:
            main.DB_PATH = original_db_path


class TestZChangePassword:
    def test_wrong_old(self):
        assert client.post("/api/change-password", json={"old_password": "wrong", "new_password": "x"}, headers=auth()).status_code in (400, 403)

    def test_change(self):
        global _token
        assert client.post("/api/change-password", json={"old_password": "test1234", "new_password": "newpass456"}, headers=auth()).status_code == 200
        _token = None
        resp = client.post("/api/login", json={"username": "admin", "password": "newpass456"})
        assert resp.status_code == 200
