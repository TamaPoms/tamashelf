/**
 * offlineStore.js — Téléchargement hors-ligne des chapitres Kavita / livres Komga côté
 * web, dans IndexedDB (contrairement à l'appli mobile, qui écrit sur le système de
 * fichiers -- voir kavita_download_service.dart/komga_download_service.dart -- un
 * navigateur n'a que le stockage local du domaine). Deux object stores :
 *   - "manifest" : une entrée par item téléchargé (série/tome, nombre de pages, cover)
 *   - "pages"    : les pages elles-mêmes, en Blob, clé "<key>::<index>"
 * Les URLs de lecture (rPg dans App.jsx) deviennent alors des blob: object URLs plutôt
 * que des requêtes réseau vers /api/kavita/read ou /api/komga/read -- la lecture d'un
 * item téléchargé ne dépend donc plus du serveur Kavita/Komga (ni même du backend
 * TamaShelf, une fois les blobs en local).
 */

const DB_NAME = "tamashelf-offline";
const DB_VERSION = 1;

let _dbPromise = null;
function openDb() {
  if (_dbPromise) return _dbPromise;
  _dbPromise = new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains("manifest")) db.createObjectStore("manifest", { keyPath: "key" });
      if (!db.objectStoreNames.contains("pages")) db.createObjectStore("pages");
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return _dbPromise;
}

// Clé stable pour un item téléchargé : une par chapitre Kavita / livre Komga.
export function offlineKey(source, itemId) {
  return `${source}:${itemId}`;
}

export async function listDownloads() {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const req = db.transaction(["manifest"], "readonly").objectStore("manifest").getAll();
    req.onsuccess = () => resolve((req.result || []).sort((a, b) => (b.downloadedAt || 0) - (a.downloadedAt || 0)));
    req.onerror = () => reject(req.error);
  });
}

export async function getDownload(key) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const req = db.transaction(["manifest"], "readonly").objectStore("manifest").get(key);
    req.onsuccess = () => resolve(req.result || null);
    req.onerror = () => reject(req.error);
  });
}

export async function deleteDownload(key) {
  const db = await openDb();
  const entry = await getDownload(key);
  return new Promise((resolve, reject) => {
    const t = db.transaction(["manifest", "pages"], "readwrite");
    t.objectStore("manifest").delete(key);
    if (entry) {
      for (let i = 0; i < entry.totalPages; i++) t.objectStore("pages").delete(`${key}::${i}`);
    }
    t.oncomplete = () => resolve();
    t.onerror = () => reject(t.error);
  });
}

// Télécharge toutes les pages (+ la cover si fournie) d'un chapitre/livre et les
// mémorise dans IndexedDB. `onProgress(done, total)` est appelé après chaque page --
// permet d'afficher une progression sans bloquer l'UI (fetch séquentiel, volontairement
// : en parallèle on risquerait de saturer Kavita/Komga sur une longue série).
export async function downloadItem({ key, source, seriesId, seriesName, itemId, itemLabel, pageUrls, coverUrl, onProgress }) {
  const db = await openDb();
  const totalPages = pageUrls.length;
  for (let i = 0; i < totalPages; i++) {
    const resp = await fetch(pageUrls[i]);
    if (!resp.ok) throw new Error(`Page ${i + 1} : HTTP ${resp.status}`);
    const blob = await resp.blob();
    await new Promise((resolve, reject) => {
      const t = db.transaction(["pages"], "readwrite");
      t.objectStore("pages").put(blob, `${key}::${i}`);
      t.oncomplete = resolve;
      t.onerror = () => reject(t.error);
    });
    onProgress && onProgress(i + 1, totalPages);
  }
  let cover = null;
  if (coverUrl) {
    try { const r = await fetch(coverUrl); if (r.ok) cover = await r.blob(); } catch { /* pas bloquant */ }
  }
  await new Promise((resolve, reject) => {
    const t = db.transaction(["manifest"], "readwrite");
    t.objectStore("manifest").put({ key, source, seriesId, seriesName, itemId, itemLabel, totalPages, cover, downloadedAt: Date.now() });
    t.oncomplete = resolve;
    t.onerror = () => reject(t.error);
  });
}

// Reconstruit les URLs de lecture (blob: object URLs) d'un item déjà téléchargé --
// null si le téléchargement est absent ou incomplet (jamais retourner une lecture
// partielle sans le signaler à l'appelant, qui retombera alors sur le réseau).
export async function getOfflinePages(key) {
  const entry = await getDownload(key);
  if (!entry || !entry.totalPages) return null;
  const db = await openDb();
  const urls = [];
  for (let i = 0; i < entry.totalPages; i++) {
    const blob = await new Promise((resolve, reject) => {
      const req = db.transaction(["pages"], "readonly").objectStore("pages").get(`${key}::${i}`);
      req.onsuccess = () => resolve(req.result || null);
      req.onerror = () => reject(req.error);
    });
    if (!blob) return null;
    urls.push(URL.createObjectURL(blob));
  }
  return urls;
}

export function offlineCoverUrl(entry) {
  return entry?.cover ? URL.createObjectURL(entry.cover) : "";
}
