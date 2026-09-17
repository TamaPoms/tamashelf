"""
kavita_client.py — Client HTTP pour un serveur Kavita externe
(https://www.kavitareader.com/, bibliothèque manga/comics auto-hébergée),
pour proposer ses séries en lecture au sein de TamaShelf sans dupliquer les
fichiers ni les ré-héberger.

Un seul serveur Kavita est configuré pour toute l'instance TamaShelf (admin
uniquement, voir /api/admin/config) -- pas un serveur par utilisateur.

Auth (voir l'OpenAPI officiel de Kavita, .../openapi.json) : on échange la
clé API (générée dans Kavita, Compte -> Clés API) contre un jeton JWT via
    POST /api/Plugin/authenticate?apiKey=...&pluginName=...
qui répond un UserDto dont le champ "token" est le JWT à utiliser en
"Authorization: Bearer <token>" pour tous les appels suivants. Le jeton
expire après quelques heures : on le mémorise et on ré-authentifie
automatiquement sur un 401.

Endpoints utilisés (confirmés dans l'OpenAPI, pas juste la doc générale) :
    GET  /api/Library/user-libraries                    -> LibraryDto[]
    POST /api/Series/v2?PageNumber=&PageSize=            -> SeriesDto[]
    GET  /api/Series/{seriesId}                          -> SeriesDto
    GET  /api/Series/volumes?seriesId=                   -> VolumeDto[] (avec chapters[])
    GET  /api/Reader/image?chapterId=&page=              -> bytes image
    GET  /api/Image/series-cover?seriesId=                -> bytes image
"""
import base64
import json
import time
from typing import Optional

import httpx

PLUGIN_NAME = "TamaShelf"
TOKEN_TTL_SAFETY_MARGIN = 300  # ré-authentifie 5 min avant l'expiration estimée
TOKEN_ASSUMED_LIFETIME = 3 * 3600  # Kavita ne renvoie pas l'expiration ; on estime 3h

# SeriesFilterField.Libraries et FilterComparison.Equal (voir openapi.json,
# schémas SeriesFilterField / FilterComparison).
_FILTER_FIELD_LIBRARIES = 19
_FILTER_COMPARISON_EQUAL = 0


class KavitaError(Exception):
    pass


def _jwt_user_id(token: str) -> Optional[int]:
    """Le champ "id" renvoyé par /api/Plugin/authenticate reste à 0 en
    pratique (API "pas encore complètement finalisée" selon Kavita) -- le
    vrai id utilisateur se trouve dans la claim "nameid" du JWT lui-même.
    On ne vérifie pas la signature : le token vient d'être reçu du serveur
    auquel on vient de s'authentifier, sur une connexion qu'on contrôle."""
    try:
        payload_b64 = token.split(".")[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload_b64))
        return int(claims["nameid"])
    except Exception:
        return None


class KavitaClient:
    """Un client par (server_url, api_key) ; le jeton JWT est mémorisé sur
    l'instance, donc mieux vaut réutiliser la même instance entre appels
    plutôt que d'en recréer une à chaque requête (voir get_kavita_client)."""

    def __init__(self, server_url: str, api_key: str):
        self.server_url = server_url.rstrip("/")
        self.api_key = api_key
        self._token: Optional[str] = None
        self._token_expires_at: float = 0
        self._user_id: Optional[int] = None

    async def _authenticate(self, client: httpx.AsyncClient) -> str:
        try:
            resp = await client.post(
                f"{self.server_url}/api/Plugin/authenticate",
                params={"apiKey": self.api_key, "pluginName": PLUGIN_NAME},
                timeout=15,
            )
        except httpx.RequestError as e:
            raise KavitaError(f"Serveur Kavita injoignable : {e}") from e
        if resp.status_code == 401 or resp.status_code == 403:
            raise KavitaError("Clé API Kavita invalide ou refusée.")
        if resp.status_code != 200:
            raise KavitaError(f"Échec de l'authentification Kavita (HTTP {resp.status_code}).")
        data = resp.json()
        token = data.get("token")
        if not token:
            raise KavitaError("Réponse d'authentification Kavita invalide (pas de jeton).")
        self._token = token
        self._user_id = data.get("id") or _jwt_user_id(token)
        self._token_expires_at = time.time() + TOKEN_ASSUMED_LIFETIME - TOKEN_TTL_SAFETY_MARGIN
        return token

    async def _auth_headers(self, client: httpx.AsyncClient, force_refresh: bool = False) -> dict:
        if force_refresh or not self._token or time.time() >= self._token_expires_at:
            await self._authenticate(client)
        return {"Authorization": f"Bearer {self._token}"}

    async def _request(self, method: str, path: str, **kwargs) -> httpx.Response:
        async with httpx.AsyncClient() as client:
            headers = await self._auth_headers(client)
            try:
                resp = await client.request(method, f"{self.server_url}{path}", headers=headers, timeout=30, **kwargs)
            except httpx.RequestError as e:
                raise KavitaError(f"Serveur Kavita injoignable : {e}") from e
            if resp.status_code == 401:
                # Jeton probablement expiré plus tôt que prévu : une seule
                # tentative de ré-authentification avant d'abandonner.
                headers = await self._auth_headers(client, force_refresh=True)
                try:
                    resp = await client.request(method, f"{self.server_url}{path}", headers=headers, timeout=30, **kwargs)
                except httpx.RequestError as e:
                    raise KavitaError(f"Serveur Kavita injoignable : {e}") from e
            if resp.status_code >= 400:
                raise KavitaError(f"Erreur Kavita {resp.status_code} sur {path}")
            return resp

    async def libraries(self) -> list[dict]:
        # userId est un paramètre requis côté serveur (int non-nullable) même
        # si l'OpenAPI ne le marque pas "required" -- sans lui, Kavita répond
        # 400. On s'assure d'être authentifié (et donc de connaître
        # self._user_id, rempli par _authenticate) avant de construire la
        # requête.
        if self._user_id is None:
            async with httpx.AsyncClient() as client:
                await self._auth_headers(client)
        params = {"userId": self._user_id} if self._user_id is not None else {}
        resp = await self._request("GET", "/api/Library/user-libraries", params=params)
        return resp.json()

    async def series_in_library(self, library_id: int, page_size: int = 500) -> list[dict]:
        # Corps déduit du schéma OpenAPI de SeriesFilterV2Dto (pas d'accès à
        # un serveur Kavita réel pour le vérifier en conditions réelles) :
        # `statements` filtre par bibliothèque (SeriesFilterField.Libraries
        # = 19, FilterComparison.Equal = 0) ; `sortOptions` est omis
        # volontairement (non requis dans le schéma). Si Kavita répond une
        # erreur 400/422 ici, c'est le premier endroit à corriger -- le
        # format exact du corps est la partie la moins certaine de ce
        # client, tout le reste (auth, volumes, pages, cover) a été rejoué
        # contre un faux serveur reproduisant les réponses de l'OpenAPI.
        body = {
            "statements": [
                {"comparison": _FILTER_COMPARISON_EQUAL, "field": _FILTER_FIELD_LIBRARIES, "value": str(library_id)}
            ],
            "combination": 1,  # And (sans effet ici, une seule condition)
        }
        resp = await self._request(
            "POST", "/api/Series/v2",
            params={"PageNumber": 1, "PageSize": page_size},
            json=body,
        )
        return resp.json()

    async def series_detail(self, series_id: int) -> dict:
        resp = await self._request("GET", f"/api/Series/{series_id}")
        return resp.json()

    async def volumes(self, series_id: int) -> list[dict]:
        resp = await self._request("GET", "/api/Series/volumes", params={"seriesId": series_id})
        return resp.json()

    async def chapter_info(self, chapter_id: int) -> dict:
        """Total de pages + titre/série -- suffit à reconstruire l'état du
        lecteur (rPg, titre) à partir d'un seul chapterId, ex. pour reprendre
        une lecture sans avoir à re-parcourir la série entière."""
        resp = await self._request("GET", "/api/Reader/chapter-info", params={"chapterId": chapter_id})
        return resp.json()

    async def page_bytes(self, chapter_id: int, page: int) -> tuple[bytes, str]:
        resp = await self._request("GET", "/api/Reader/image", params={"chapterId": chapter_id, "page": page})
        return resp.content, resp.headers.get("content-type", "image/jpeg")

    async def series_cover_bytes(self, series_id: int) -> tuple[bytes, str]:
        resp = await self._request("GET", "/api/Image/series-cover", params={"seriesId": series_id})
        return resp.content, resp.headers.get("content-type", "image/jpeg")


_client_cache: dict[tuple[str, str], KavitaClient] = {}


def get_kavita_client(server_url: str, api_key: str) -> KavitaClient:
    """Réutilise un client (donc son jeton déjà authentifié) tant que
    l'URL/clé configurées ne changent pas."""
    key = (server_url, api_key)
    client = _client_cache.get(key)
    if client is None:
        # Config changée ou premier appel : on repart d'un client propre et
        # on vide le cache pour ne pas accumuler d'anciens clients inutiles.
        _client_cache.clear()
        client = KavitaClient(server_url, api_key)
        _client_cache[key] = client
    return client
