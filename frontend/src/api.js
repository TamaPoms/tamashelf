/**
 * TamaShelf API Client
 * Wraps all HTTP calls to /api/* with auth token management
 */

const TOKEN_KEY = "tamashelf_token";
const TOKEN_KEY_LEGACY = "mangashelf_token"; // ancien nom -- lu en secours pour ne pas déconnecter les sessions déjà ouvertes lors de la mise à jour

export function getToken() {
  return localStorage.getItem(TOKEN_KEY) || localStorage.getItem(TOKEN_KEY_LEGACY) || "";
}

export function setToken(t) {
  if (t) localStorage.setItem(TOKEN_KEY, t);
  else localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(TOKEN_KEY_LEGACY); // migration terminée dès le prochain login/logout
}

async function request(path, opts = {}) {
  const token = getToken();
  const headers = { "Content-Type": "application/json", ...opts.headers };
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await fetch(`/api${path}`, { ...opts, headers });

  if (res.status === 401) {
    setToken(null);
    window.location.reload();
    throw new Error("Session expirée");
  }

  if (!res.ok) {
    const body = await res.json().catch(() => ({ detail: res.statusText }));
    throw new Error(body.detail || body.error || `HTTP ${res.status}`);
  }

  return res.json();
}

// Comme request(), mais pour un envoi multipart/form-data (création manuelle
// série/édition/volume, avec upload d'images) : on ne fixe surtout PAS le
// Content-Type nous-mêmes, le navigateur doit le générer avec sa propre boundary.
async function requestForm(path, formData) {
  const token = getToken();
  const headers = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await fetch(`/api${path}`, { method: "POST", headers, body: formData });

  if (res.status === 401) {
    setToken(null);
    window.location.reload();
    throw new Error("Session expirée");
  }

  if (!res.ok) {
    const body = await res.json().catch(() => ({ detail: res.statusText }));
    throw new Error(body.detail || body.error || `HTTP ${res.status}`);
  }

  return res.json();
}

export const api = {
  // Auth
  setupStatus: () => request("/setup-status", { headers: {} }),
  setup: (data) => request("/setup", { method: "POST", body: JSON.stringify(data), headers: {} }),
  login: (data) => request("/login", { method: "POST", body: JSON.stringify(data), headers: {} }),
  logout: () => request("/logout", { method: "POST" }),
  me: () => request("/me"),
  changePassword: (data) => request("/change-password", { method: "POST", body: JSON.stringify(data) }),

  // Admin
  getUsers: () => request("/admin/users"),
  createUser: (data) => request("/admin/users", { method: "POST", body: JSON.stringify(data) }),
  updateUser: (id, data) => request(`/admin/users/${id}`, { method: "PUT", body: JSON.stringify(data) }),
  deleteUser: (id) => request(`/admin/users/${id}`, { method: "DELETE" }),
  getConfig: () => request("/admin/config"),
  updateConfig: (data) => request("/admin/config", { method: "PUT", body: JSON.stringify(data) }),
  autoMatch: () => request("/admin/auto-match", { method: "POST" }),
  generateCovers: () => request("/admin/generate-covers", { method: "POST" }),
  scanFolders: () => request("/admin/scan-folders", { method: "POST" }),
  rescanTypes: () => request("/admin/rescan-types", { method: "POST" }),
  detectDuplicates: () => request("/admin/detect-duplicates"),
  mergeMangas: (keepId, mergeIds) => request(`/admin/merge-mangas?keep_id=${keepId}&merge_ids=${mergeIds}`, { method: "POST" }),
  validateMatch: (mangaId, nautiljonUrl) => request(`/admin/validate-match/${mangaId}?nautiljon_url=${encodeURIComponent(nautiljonUrl)}`, { method: "POST" }),
  resetMatch: (mangaId) => request(`/admin/reset-match/${mangaId}`, { method: "POST" }),
  updateManga: (mangaId, data) => request(`/admin/manga/${mangaId}`, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) }),
  replaceCbzCover: (cbzPath, coverUrl) => request(`/admin/replace-cbz-cover?cbz_path=${encodeURIComponent(cbzPath)}&cover_url=${encodeURIComponent(coverUrl)}`, { method: "POST" }),
  cbrMissingCbz: () => request("/admin/cbr-missing-cbz"),
  convertCbrToCbz: (cbrPath) => request("/admin/convert-cbr-to-cbz", { method: "POST", body: JSON.stringify({ cbr_path: cbrPath }) }),

  // Library (local DB)
  getLibrary: (library_id, limit, offset) => {
    const params = new URLSearchParams();
    if (library_id != null) params.set("library_id", library_id);
    if (limit != null) params.set("limit", limit);
    if (offset != null) params.set("offset", offset);
    const qs = params.toString();
    return request(`/library${qs ? `?${qs}` : ""}`);
  },
  getLibraryManga: (id) => request(`/library/${id}`),

  // Libraries (multi-library support)
  getLibraries: () => request("/libraries"),
  adminGetLibraries: () => request("/admin/libraries"),
  adminCreateLibrary: (data) => request("/admin/libraries", { method: "POST", body: JSON.stringify(data) }),
  adminUpdateLibrary: (id, data) => request(`/admin/libraries/${id}`, { method: "PUT", body: JSON.stringify(data) }),
  adminDeleteLibrary: (id) => request(`/admin/libraries/${id}`, { method: "DELETE" }),
  adminGetLibraryAccess: (id) => request(`/admin/libraries/${id}/access`),
  adminSetLibraryAccess: (id, userIds) => request(`/admin/libraries/${id}/access`, { method: "PUT", body: JSON.stringify({ user_ids: userIds }) }),
  adminCompareLibraries: (libA, libB) => request(`/admin/libraries/compare?lib_a=${libA}&lib_b=${libB}`),
  adminCopyFolder: (folder, fromLib, toLib) => request("/admin/libraries/copy-folder", { method: "POST", body: JSON.stringify({ folder, from_lib: fromLib, to_lib: toLib }) }),
  adminCopyFile: (folder, filename, fromLib, toLib) => request("/admin/libraries/copy-file", { method: "POST", body: JSON.stringify({ folder, filename, from_lib: fromLib, to_lib: toLib }) }),
  adminTransferManga: (folder, fromLib, toLib, dstFolder = null) => request(
    "/admin/libraries/transfer-manga",
    { method: "POST", body: JSON.stringify({ folder, dst_folder: dstFolder || undefined, from_lib: fromLib, to_lib: toLib }) }
  ),
  
  // Nautiljon (accès direct à la base locale, voir nautiljon_db.py)
  nautiljonHealth: () => request("/nautiljon/health"),
  nautiljonSearch: (q, limit = 48, offset = 0) => request(`/nautiljon/search?q=${encodeURIComponent(q)}&limit=${limit}&offset=${offset}`),
  nautiljonManga: (url) => request(`/nautiljon/manga?url=${encodeURIComponent(url)}`),

  // Nautiljon — création manuelle (admin uniquement)
  createNautiljonSerie: (formData) => requestForm("/admin/nautiljon/serie", formData),
  addNautiljonEdition: (serieUrl, nom, statut = "") => {
    const fd = new FormData();
    fd.set("serie_url", serieUrl);
    fd.set("nom", nom);
    fd.set("statut", statut);
    return requestForm("/admin/nautiljon/edition", fd);
  },
  addNautiljonVolume: (formData) => requestForm("/admin/nautiljon/volume", formData),

  // Appli Android (APK) -- publics (pas d'auth requise) sauf l'upload admin
  apkLatest: () => request("/apk/latest", { headers: {} }),
  apkDownloadUrl: () => "/api/apk/download",
  uploadApk: (formData) => requestForm("/admin/apk", formData),

  // Progress
  getProgress: () => request("/progress"),
  saveProgress: (data) => request("/progress", { method: "POST", body: JSON.stringify(data) }),
  deleteProgress: (manga_url, volume_id = null) => request(`/progress?manga_url=${encodeURIComponent(manga_url)}${volume_id != null ? `&volume_id=${encodeURIComponent(volume_id)}` : ""}`, { method: "DELETE" }),

  // User lists
  getLists: () => request("/lists"),
  addListItem: (data) => request("/lists", { method: "POST", body: JSON.stringify(data) }),
  removeListItem: (list_name, manga_url, volume_id = null, item_type = null) => request(`/lists?list_name=${encodeURIComponent(list_name)}&manga_url=${encodeURIComponent(manga_url)}${volume_id != null ? `&volume_id=${encodeURIComponent(volume_id)}` : ""}${item_type != null ? `&item_type=${encodeURIComponent(item_type)}` : ""}`, { method: "DELETE" }),

  // Matches
  getMatches: () => request("/matches"),
  createMatch: (data) => request("/matches", { method: "POST", body: JSON.stringify(data) }),
  deleteMatch: (url) => request(`/matches/${encodeURIComponent(url)}`, { method: "DELETE" }),

  // CBZ
  cbzList: (folder) => request(`/cbz/list/${folder.split("/").map(encodeURIComponent).join("/")}`),
  cbzBrowse: () => request("/cbz/browse"),
  cbzInfo: (filepath) => request(`/cbz/info/${filepath.split("/").map(encodeURIComponent).join("/")}`),
  cbzFolderCoverUrl: (folder) => {
    const token = getToken();
    return `/api/cbz/folder-cover/${encodeURIComponent(folder)}?token=${encodeURIComponent(token)}`;
  },
  cbzThumbnailUrl: (filepath) => {
    const encoded = filepath.split("/").map(encodeURIComponent).join("/");
    const token = getToken();
    return `/api/cbz/thumbnail/${encoded}?token=${encodeURIComponent(token)}`;
  },
  cbzPageUrl: (filepath, page) => {
    const encoded = filepath.split("/").map(encodeURIComponent).join("/");
    const token = getToken();
    return `/api/cbz/read/${encoded}?page=${page}&token=${encodeURIComponent(token)}`;
  },
  cbzPageThumbUrl: (filepath, page) => {
    const encoded = filepath.split("/").map(encodeURIComponent).join("/");
    const token = getToken();
    return `/api/cbz/page/${encoded}?page=${page}&token=${encodeURIComponent(token)}`;
  },
  cbzDownloadUrl: (filepath) => {
    const encoded = filepath.split("/").map(encodeURIComponent).join("/");
    const token = getToken();
    return `/api/cbz/download/${encoded}?token=${encodeURIComponent(token)}`;
  },

  // "Image folders" volumes (e.g., 1x5 folders)
  imgVolInfo: (folder, volume) => request(`/imgvol/info/${folder.split("/").map(encodeURIComponent).join("/")}?volume=${encodeURIComponent(volume)}`),
  imgVolPageUrl: (folder, volume, page) => {
    const encodedFolder = folder.split("/").map(encodeURIComponent).join("/");
    const token = getToken();
    return `/api/imgvol/page/${encodedFolder}?volume=${encodeURIComponent(volume)}&page=${page}&token=${encodeURIComponent(token)}`;
  },

  // Debug (admin)
  debugMangaRaw: (url) => request(`/debug/manga-raw?url=${encodeURIComponent(url)}`),

  // Stats
  stats: () => request("/stats"),

  // Themes
  getThemes: () => request("/themes"),
  getUserTheme: () => request("/user/theme"),
  setUserTheme: (theme_id) => request("/user/theme", { method: "PUT", body: JSON.stringify({ theme_id }) }),
  saveTheme: (data) => request("/admin/themes", { method: "POST", body: JSON.stringify(data) }),
  deleteTheme: (id) => request(`/admin/themes/${id}`, { method: "DELETE" }),

  // Ratings
  getRatings: () => request("/ratings"),
  setRating: (mangaId, rating) => request(`/ratings/${mangaId}?rating=${rating}`, { method: "PUT" }),
  deleteRating: (mangaId) => request(`/ratings/${mangaId}`, { method: "DELETE" }),

  // Notes
  getNotes: () => request("/notes"),
  saveNote: (mangaId, note) => request(`/notes/${mangaId}/save`, { method: "POST", body: JSON.stringify({ note }) }),

  // Collections
  getCollections: () => request("/collections"),
  createCollection: (data) => request("/collections", { method: "POST", body: JSON.stringify(data) }),
  deleteCollection: (id) => request(`/collections/${id}`, { method: "DELETE" }),
  addToCollection: (collectionId, mangaId) => request(`/collections/${collectionId}/add`, { method: "POST", body: JSON.stringify({ manga_id: mangaId }) }),
  removeFromCollection: (collectionId, mangaId) => request(`/collections/${collectionId}/remove/${mangaId}`, { method: "DELETE" }),

  // Stats
  getStats: () => request("/stats"),
  logActivity: (data) => request("/stats/log-activity", { method: "POST", body: JSON.stringify(data) }),

  // Homepage
  getHomepage: () => request("/homepage"),

  // Activity feed
  getActivity: () => request("/activity"),

  // Notifications
  getNotifications: () => request("/notifications"),

  // Full-text search
  fullSearch: (q) => request(`/search?q=${encodeURIComponent(q)}`),

  // Import/Export
  exportLists: () => request("/lists/export"),
  importLists: (data) => request("/lists/import", { method: "POST", body: JSON.stringify(data) }),
};
