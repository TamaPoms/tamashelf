"""
komga_client.py — Client HTTP pour un serveur Komga externe (https://komga.org/,
bibliothèque manga/comics auto-hébergée), pour proposer ses séries en lecture au sein de
TamaShelf sans dupliquer les fichiers ni les ré-héberger. Portage direct de
kavita_client.py (voir ce fichier pour le principe général) pour Komga -- auth plus
simple ici : une clé API dans le header X-API-Key suffit sur chaque requête, pas
d'échange préalable contre un jeton JWT (voir openapi.json de Komga,
securitySchemes.apiKey = header X-API-Key). Les identifiants Komga (séries, livres,
bibliothèques) sont des chaînes (UUID), contrairement à Kavita (entiers).

Un seul serveur Komga est configuré pour toute l'instance TamaShelf (admin uniquement,
voir /api/admin/config) -- pas un serveur par utilisateur.

Endpoints utilisés (confirmés dans l'OpenAPI officiel de Komga) :
    GET   /api/v1/libraries                                -> LibraryDto[]
    POST  /api/v1/series/list?page=&size=                  -> Page<SeriesDto>
    GET   /api/v1/series/{id}                               -> SeriesDto
    POST  /api/v1/books/list?page=&size=                    -> Page<BookDto>
    PATCH /api/v1/series/{id}/metadata                      -> (patch partiel)
    PATCH /api/v1/books/{id}/metadata                       -> (patch partiel)
    PATCH /api/v1/books/{id}/read-progress                  -> (page courante)
    GET   /api/v1/series/{id}/thumbnail                     -> bytes image
    GET   /api/v1/books/{id}/thumbnail                      -> bytes image
    GET   /api/v1/books/{id}/pages/{page}?zero_based=true   -> bytes image
"""
from typing import Optional

import httpx


class KomgaError(Exception):
    pass


class KomgaClient:
    def __init__(self, server_url: str, api_key: str):
        self.server_url = server_url.rstrip("/")
        self.api_key = api_key

    @property
    def _headers(self) -> dict:
        return {"X-API-Key": self.api_key}

    async def _request(self, method: str, path: str, **kwargs) -> httpx.Response:
        headers = {**self._headers, **kwargs.pop("headers", {})}
        async with httpx.AsyncClient() as client:
            try:
                resp = await client.request(method, f"{self.server_url}{path}", headers=headers, timeout=30, **kwargs)
            except httpx.RequestError as e:
                raise KomgaError(f"Serveur Komga injoignable : {e}") from e
            if resp.status_code == 401 or resp.status_code == 403:
                raise KomgaError("Clé API Komga invalide ou refusée.")
            if resp.status_code >= 400:
                raise KomgaError(f"Erreur Komga {resp.status_code} sur {path}")
            return resp

    async def libraries(self) -> list[dict]:
        resp = await self._request("GET", "/api/v1/libraries")
        return resp.json()

    async def series_in_library(self, library_id: str, page_size: int = 500) -> list[dict]:
        body = {"condition": {"libraryId": {"operator": "is", "value": library_id}}}
        all_series: list[dict] = []
        page = 0
        while True:
            resp = await self._request("POST", "/api/v1/series/list", params={"page": page, "size": page_size}, json=body)
            data = resp.json()
            content = data.get("content") or []
            all_series.extend(content)
            if data.get("last") or not content:
                break
            page += 1
            if page > 100:  # garde-fou anti-boucle-infinie
                break
        return all_series

    async def series_detail(self, series_id: str) -> dict:
        resp = await self._request("GET", f"/api/v1/series/{series_id}")
        return resp.json()

    async def series_metadata_update(self, series_id: str, patch: dict) -> None:
        await self._request("PATCH", f"/api/v1/series/{series_id}/metadata", json=patch)

    async def books_in_series(self, series_id: str, page_size: int = 500) -> list[dict]:
        body = {"condition": {"seriesId": {"operator": "is", "value": series_id}}}
        all_books: list[dict] = []
        page = 0
        while True:
            resp = await self._request("POST", "/api/v1/books/list", params={"page": page, "size": page_size}, json=body)
            data = resp.json()
            content = data.get("content") or []
            all_books.extend(content)
            if data.get("last") or not content:
                break
            page += 1
            if page > 100:
                break
        all_books.sort(key=lambda b: (b.get("number") or 0))
        return all_books

    async def book_metadata_update(self, book_id: str, patch: dict) -> None:
        await self._request("PATCH", f"/api/v1/books/{book_id}/metadata", json=patch)

    async def push_progress(self, book_id: str, page: int) -> None:
        await self._request("PATCH", f"/api/v1/books/{book_id}/read-progress", json={"page": page})

    async def page_bytes(self, book_id: str, page: int) -> tuple[bytes, str]:
        resp = await self._request("GET", f"/api/v1/books/{book_id}/pages/{page}", params={"zero_based": "true"})
        return resp.content, resp.headers.get("content-type", "image/jpeg")

    async def series_cover_bytes(self, series_id: str) -> tuple[bytes, str]:
        resp = await self._request("GET", f"/api/v1/series/{series_id}/thumbnail")
        return resp.content, resp.headers.get("content-type", "image/jpeg")

    async def book_cover_bytes(self, book_id: str) -> tuple[bytes, str]:
        resp = await self._request("GET", f"/api/v1/books/{book_id}/thumbnail")
        return resp.content, resp.headers.get("content-type", "image/jpeg")


_client_cache: dict[tuple[str, str], KomgaClient] = {}


def get_komga_client(server_url: str, api_key: str) -> KomgaClient:
    key = (server_url, api_key)
    client = _client_cache.get(key)
    if client is None:
        _client_cache.clear()
        client = KomgaClient(server_url, api_key)
        _client_cache[key] = client
    return client


def komga_series_title(series: dict) -> str:
    meta_title = ((series.get("metadata") or {}).get("title") or "").strip()
    return meta_title or (series.get("name") or "")


def komga_book_label(book: dict) -> str:
    meta_title = ((book.get("metadata") or {}).get("title") or "").strip()
    if meta_title:
        return meta_title
    number = book.get("number")
    return f"Livre {number}" if number is not None else (book.get("name") or "?")
