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

from fastapi.testclient import TestClient
from main import app, get_db_ctx, hash_password, verify_password

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

class TestZChangePassword:
    def test_wrong_old(self):
        assert client.post("/api/change-password", json={"old_password": "wrong", "new_password": "x"}, headers=auth()).status_code in (400, 403)

    def test_change(self):
        global _token
        assert client.post("/api/change-password", json={"old_password": "test1234", "new_password": "newpass456"}, headers=auth()).status_code == 200
        _token = None
        resp = client.post("/api/login", json={"username": "admin", "password": "newpass456"})
        assert resp.status_code == 200
