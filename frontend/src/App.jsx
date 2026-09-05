import { useState, useEffect, useCallback, useRef, useMemo } from "react";
import { api, getToken, setToken } from "./api";
import "./index.css";



// L'appli Android est distribuée uniquement via une release GitHub (plus d'upload/
// hébergement côté serveur TamaShelf) -- ce lien pointe toujours vers la dernière
// release tant que l'asset attaché s'appelle "tamashelf.apk".
const APK_DOWNLOAD_URL = "https://github.com/TamaPoms/tamashelf/releases/latest/download/tamashelf.apk";

function isCbzLikePath(path) {
  return /\.(cbz|cbr|zip)$/i.test(String(path || '').trim());
}

// Lien "Télécharger l'appli Android" : public -- utilisable sur l'écran de connexion,
// avant même d'avoir un compte.
function ApkDownloadLink({ compact = false }) {
  if (compact) {
    return <a className="btn btn-s" href={APK_DOWNLOAD_URL} style={{ textDecoration: "none" }}>📱 Appli Android</a>;
  }
  return (
    <div style={{ marginTop: 14, padding: 12, background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--r)", textAlign: "left" }}>
      <div style={{ fontSize: 12, fontWeight: 600, color: "var(--t1)", marginBottom: 4 }}>📱 Appli Android disponible</div>
      <a className="btn btn-p btn-s" href={APK_DOWNLOAD_URL} style={{ textDecoration: "none", display: "inline-block" }}>⬇️ Télécharger le .apk</a>
    </div>
  );
}

function ReadingPreview({ progressItem, size = 60, radius = 8 }) {
  const coverSrc = api.cbzFolderCoverUrl(progressItem?.manga_url || progressItem?.mangaUrl || '');
  const volumeId = String(progressItem?.volume_id || progressItem?.volumeId || '');
  const canPreview = isCbzLikePath(volumeId);
  const thumbs = canPreview ? [0, 1, 2].map(i => api.cbzPageThumbUrl(volumeId, i)) : [];
  return (
    <div style={{ position: 'relative', width: size, height: Math.round(size * 1.42), flexShrink: 0 }}>
      {canPreview ? (
        <>
          <img src={thumbs[2]} alt="" style={{ position: 'absolute', top: 6, left: 6, width: size - 12, height: Math.round((size - 12) * 1.42), objectFit: 'cover', borderRadius: radius - 2, opacity: 0.35, border: '1px solid var(--brd)', background: 'var(--c2)' }} onError={e => { e.currentTarget.style.display = 'none'; }} />
          <img src={thumbs[1]} alt="" style={{ position: 'absolute', top: 3, left: 3, width: size - 6, height: Math.round((size - 6) * 1.42), objectFit: 'cover', borderRadius: radius - 1, opacity: 0.6, border: '1px solid var(--brd)', background: 'var(--c2)' }} onError={e => { e.currentTarget.style.display = 'none'; }} />
          <img src={thumbs[0]} alt="" style={{ position: 'absolute', top: 0, left: 0, width: size, height: Math.round(size * 1.42), objectFit: 'cover', borderRadius: radius, border: '1px solid var(--brd)', background: 'var(--c2)', boxShadow: '0 6px 18px rgba(0,0,0,.18)' }} onError={e => {
            e.currentTarget.style.display = 'none';
            const fb = e.currentTarget.parentElement?.querySelector('.reading-preview-fallback');
            if (fb) fb.style.display = 'block';
          }} />
          <img className="reading-preview-fallback" src={coverSrc} alt="" style={{ display: 'none', width: size, height: Math.round(size * 1.42), objectFit: 'cover', borderRadius: radius, border: '1px solid var(--brd)', background: 'var(--c2)' }} onError={e => { e.currentTarget.style.opacity = '0.3'; e.currentTarget.style.display = 'block'; }} />
        </>
      ) : (
        <img src={coverSrc} alt="" style={{ width: size, height: Math.round(size * 1.42), objectFit: 'cover', borderRadius: radius, border: '1px solid var(--brd)', background: 'var(--c2)' }} onError={e => { e.currentTarget.style.opacity = '0.3'; }} />
      )}
    </div>
  );
}

function normalizeSearchText(s) {
  let t = String(s || '').toLowerCase().trim();
  t = t.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
  const m = t.match(/^(.*?)\s*\((le|la|les|the|l['’]?|un|une|des)\)\s*$/i);
  if (m) t = `${m[2]} ${m[1]}`;
  t = t.replace(/l['’]/g, 'l ');
  t = t.replace(/[^a-z0-9]+/g, ' ').replace(/\s+/g, ' ').trim();
  return t;
}


function nautiljonMiniUrl(raw) {
  const u = String(raw || '').trim();
  if (!u) return u;
  if (!/https?:\/\/www\.nautiljon\.com\//i.test(u)) return u;
  if (!/\/images\/(manga|manga_volumes)\//i.test(u)) return u;
  const qIdx = u.indexOf('?');
  const base = qIdx >= 0 ? u.slice(0, qIdx) : u;
  let q = qIdx >= 0 ? u.slice(qIdx + 1) : '';
  let out = base.replace(/\/(images\/(?:manga|manga_volumes)\/[^?#]+)\/([^\/?#]+)$/i, (m, dir, file) => {
    if (/\/mini$/i.test(dir)) return `/${dir}/${file}`;
    return `/${dir}/mini/${file}`;
  });
  if (q && !q.startsWith('1')) q = `1${q}`;
  return q ? `${out}?${q}` : out;
}

const SEARCH_TAG_KEYS = ["Type", "Types", "Genres", "Thème", "Thèmes", "Auteur", "Scénariste", "Dessinateur"];

const TAG_COLORS = [
  "#FF6B6B", "#FFB347", "#6BCB77", "#4ECDC4", "#45B7D1",
  "#7C4DFF", "#FF6B9D", "#FFA502", "#2ED573", "#5F27CD",
  "#FF4757", "#1E90FF", "#FF6348", "#3742FA", "#2F3542",
];
const tagColor = (tag) => TAG_COLORS[Math.abs([...tag].reduce((h, c) => ((h << 5) - h + c.charCodeAt(0)) | 0, 0)) % TAG_COLORS.length];

const TAG_FILTER_KEYS = ["Type", "Genres", "Thème", "Thèmes", "Statut", "Editeur", "Auteur", "Pays"];

function extractAllTags(mangas) {
  const tags = {};
  TAG_FILTER_KEYS.forEach(k => tags[k] = new Map());
  for (const m of mangas) {
    const meta = m?.metadata_json || {};
    for (const k of TAG_FILTER_KEYS) {
      const v = meta[k];
      if (!v) continue;
      const parts = String(v).split(/\s*[-,]\s*/).filter(Boolean);
      for (const p of parts) {
        const t = p.trim();
        if (t) tags[k].set(t, (tags[k].get(t) || 0) + 1);
      }
    }
  }
  // Sort by count desc, remove empty categories
  const result = {};
  for (const [k, map] of Object.entries(tags)) {
    if (map.size === 0) continue;
    result[k] = [...map.entries()].sort((a, b) => b[1] - a[1]);
  }
  return result;
}

function matchesTagFilters(manga, tagFilters) {
  const meta = manga?.metadata_json || {};
  for (const [cat, selected] of Object.entries(tagFilters)) {
    if (!selected || selected.length === 0) continue;
    const val = normalizeSearchText(String(meta[cat] || ""));
    const match = selected.some(tag => val.includes(normalizeSearchText(tag)));
    if (!match) return false;
  }
  return true;
}

function mangaSearchMatchInfo(m, rawQuery) {
  const q = normalizeSearchText(rawQuery || '');
  if (!q) return { ok: true, source: null };
  const meta = m?.metadata_json || {};
  const titleText = normalizeSearchText([m?.title || '', m?.cbz_folder || ''].join(' '));
  if (titleText.includes(q)) return { ok: true, source: 'title' };
  for (const k of SEARCH_TAG_KEYS) {
    const v = meta?.[k];
    if (!v) continue;
    const parts = String(v).split(/\s*[-,]\s*/).filter(Boolean);
    for (const part of parts) {
      if (normalizeSearchText(part).includes(q)) return { ok: true, source: 'tag', tagKey: k, tagValue: part };
    }
    if (normalizeSearchText(v).includes(q)) return { ok: true, source: 'tag', tagKey: k, tagValue: String(v) };
  }
  return { ok: false, source: null };
}

function mangaSearchHaystack(m) {
  const meta = m?.metadata_json || {};
  const tagVals = SEARCH_TAG_KEYS.map(k => meta[k]).filter(Boolean).join(' ');
  const variantTitles = Array.isArray(m?.grouped_variants) ? m.grouped_variants.map(v => v.title).join(' ') : '';
  return normalizeSearchText([m?.title || '', variantTitles, m?.cbz_folder || '', tagVals].join(' '));
}

function splitEditionTitle(title) {
  const raw = String(title || '').trim();
  if (!raw) return { baseTitle: '', editionLabel: '' };
  const parts = raw.split(/\s+[\-–—]\s+/);
  if (parts.length >= 2) {
    const suffix = parts[parts.length - 1].trim();
    if (/(edition|édition|deluxe|perfect|collector|ultimate|kanzen|prestige|complete|int[eé]grale|version)/i.test(suffix)) {
      return { baseTitle: parts.slice(0, -1).join(' - ').trim(), editionLabel: suffix };
    }
  }
  return { baseTitle: raw, editionLabel: '' };
}

function normalizeEditionLabel(label) {
  if (!label) return '';
  let n = label.trim();
  // Remove "Édition " / "Edition " / "édition " prefix (all case variants)
  n = n.replace(/^[eéÉ]dition\s+/i, '');
  // Normalize to lowercase for comparison
  n = n.trim().toLowerCase();
  return n;
}

function groupLibraryMangas(items) {
  const groups = new Map();
  for (const item of (items || [])) {
    const { baseTitle, editionLabel } = splitEditionTitle(item?.title || '');
    const key = normalizeSearchText(baseTitle || item?.title || item?.cbz_folder || '');
    const current = groups.get(key) || [];
    current.push({ ...item, __base_title: baseTitle || item?.title || '', __edition_label: editionLabel || '' });
    groups.set(key, current);
  }
  return [...groups.values()].map((variants) => {
    // Group variants by normalized edition label, merge cbz_folders
    const labelMap = new Map(); // normalizedLabel -> { variant, cbz_folders: [] }
    for (const v of variants) {
      const normLabel = normalizeEditionLabel(v.__edition_label);
      if (!labelMap.has(normLabel)) {
        labelMap.set(normLabel, { variant: v, cbz_folders: [v.cbz_folder] });
      } else {
        const existing = labelMap.get(normLabel);
        existing.cbz_folders.push(v.cbz_folder);
        // Keep the matched one as primary
        if (v.match_status === 'matched' && existing.variant.match_status !== 'matched') {
          existing.variant = v;
        }
      }
    }

    const dedupedVariants = [...labelMap.values()].map(({ variant, cbz_folders }) => ({
      ...variant,
      __edition_cbz_folders: cbz_folders, // all folders for this edition
    }));

    dedupedVariants.sort((a, b) => {
      const aScore = a.__edition_label ? 1 : 0;
      const bScore = b.__edition_label ? 1 : 0;
      if (aScore !== bScore) return aScore - bScore;
      return String(a.title || '').length - String(b.title || '').length;
    });
    const primary = dedupedVariants[0];
    return {
      ...primary,
      title: primary.__base_title || primary.title,
      grouped_variants: dedupedVariants,
      _all_cbz_folders: variants.map(v => v.cbz_folder),
      has_tomes: variants.some(v => v.has_tomes),
      has_chapters: variants.some(v => v.has_chapters),
      has_oneshots: variants.some(v => v.has_oneshots),
      is_oneshot: variants.some(v => v.is_oneshot),
    };
  }).sort((a, b) => String(a.title || '').localeCompare(String(b.title || ''), 'fr', { sensitivity: 'base' }));
}

export default function App() {
  const [phase, setPhase] = useState("loading");
  const [session, setSession] = useState(null);
  const [toast, setToast] = useState(null);
  const show = useCallback((m) => { setToast(m); setTimeout(() => setToast(null), 3e3); }, []);

  useEffect(() => {
    (async () => {
      try {
        const st = await api.setupStatus();
        if (!st.setup_done) { setPhase("setup"); return; }
        if (getToken()) { const me = await api.me(); setSession(me); setPhase("app"); return; }
      } catch {}
      setPhase("login");
    })();
  }, []);

  const [sf, setSf] = useState({ user: "", pass: "", pass2: "", cbz: "" });
  const [se, setSe] = useState("");
  const doSetup = async () => {
    if (!sf.user.trim() || !sf.pass) { setSe("Champs requis"); return; }
    if (sf.pass !== sf.pass2) { setSe("MDP différents"); return; }
    try {
      const r = await api.setup({ username: sf.user.trim(), password: sf.pass, cbz_path: sf.cbz.trim() });
      setToken(r.token); setSession({ id: 0, username: r.username, role: "admin", perms: { readOnly: false, canDownload: true, canChangePassword: true } }); setPhase("app");
    } catch (e) { setSe(e.message); }
  };
  const [lf, setLf] = useState({ user: "", pass: "" }); const [le, setLe] = useState("");
  const doLogin = async () => { try { const r = await api.login({ username: lf.user.trim(), password: lf.pass }); setToken(r.token); setSession({ id: 0, username: r.username, role: r.role, perms: r.perms }); setPhase("app"); } catch (e) { setLe(e.message); } };
  const doLogout = async () => { try { await api.logout(); } catch {} setToken(null); setSession(null); setPhase("login"); };

  if (phase === "loading") return <div className="screen-center"><div className="loading"><div className="spinner" />Chargement…</div></div>;
  if (phase === "setup") return (
    <div className="screen-center"><div className="screen-bg" /><div className="card">
      <div className="card-logo"><div className="ico">鬼</div>TamaShelf</div><div className="card-sub">Configuration initiale</div>
      <div className="fld"><label>Nom admin</label><input value={sf.user} onChange={e => setSf(f => ({ ...f, user: e.target.value }))} /></div>
      <div className="fld"><label>Mot de passe</label><input type="password" value={sf.pass} onChange={e => setSf(f => ({ ...f, pass: e.target.value }))} /></div>
      <div className="fld"><label>Confirmer</label><input type="password" value={sf.pass2} onChange={e => setSf(f => ({ ...f, pass2: e.target.value }))} /></div>
      <hr style={{ border: "none", borderTop: "1px solid var(--brd)", margin: "14px 0" }} />
      <div className="fld"><label>Chemin CBZ</label><input value={sf.cbz} onChange={e => setSf(f => ({ ...f, cbz: e.target.value }))} placeholder="/media/mangas" /></div>
      <div className="card-err">{se}</div><div className="card-actions"><button className="btn btn-p" style={{ flex: 1 }} onClick={doSetup}>Créer et démarrer</button></div>
    </div></div>
  );
  if (phase === "login") return (
    <div className="screen-center"><div className="screen-bg" /><div className="card">
      <div className="card-logo"><div className="ico">鬼</div>TamaShelf</div><div className="card-sub">Connexion</div>
      <div className="fld"><label>Utilisateur</label><input value={lf.user} onChange={e => setLf(f => ({ ...f, user: e.target.value }))} onKeyDown={e => e.key === "Enter" && doLogin()} autoFocus /></div>
      <div className="fld"><label>Mot de passe</label><input type="password" value={lf.pass} onChange={e => setLf(f => ({ ...f, pass: e.target.value }))} onKeyDown={e => e.key === "Enter" && doLogin()} /></div>
      <div className="card-err">{le}</div><div className="card-actions"><button className="btn btn-p" style={{ flex: 1 }} onClick={doLogin}>Connexion</button></div>
      <ApkDownloadLink />
    </div></div>
  );
  return <MainApp session={session} doLogout={doLogout} show={show} toast={toast} />;
}

function MainApp({ session, doLogout, show, toast }) {
  const isAdmin = session.role === "admin";
  const perms = session.perms || {};
  const [nav, setNav] = useState("home");
  const [apiSt, setApiSt] = useState("loading");
  const [sq, setSq] = useState("");
  const [allMangas, setAllMangas] = useState([]);
  const [alphaIndex, setAlphaIndex] = useState({});
  const [alphaFilter, setAlphaFilter] = useState(null);
  const [allLoading, setAllLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(false);
  const loadMoreRef = useRef(null);
  const PAGE_SIZE = 60;
  const [viewMode, setViewMode] = useState("grid"); // grid, compact, list, coverflow, shelf
  const [tagFilters, setTagFilters] = useState({});
  const [showTagPanel, setShowTagPanel] = useState(false);
  const [contentType, setContentType] = useState(null);
  const [pendingCount, setPendingCount] = useState(0);
  const [progress, setProgress] = useState([]);
  const [userRatings, setUserRatings] = useState({});
  const [userNotes, setUserNotes] = useState({});
  const [readItems, setReadItems] = useState([]);
  const [toReadItems, setToReadItems] = useState([]);
  const [libraries, setLibraries] = useState([]);
  const [activeLibId, setActiveLibId] = useState(null);
  const [themes, setThemes] = useState([]);
  const [currentThemeId, setCurrentThemeId] = useState("dark-default");
  // New features
  const [sortBy, setSortBy] = useState("title"); // title, date, rating, volumes, lastRead
  const [notifications, setNotifications] = useState([]);
  const [showNotifs, setShowNotifs] = useState(false);
  const [activity, setActivity] = useState([]);
  const [showKeyConfig, setShowKeyConfig] = useState(false);
  const [keyConfig, setKeyConfig] = useState(() => {
    try { return JSON.parse(localStorage.getItem("tamashelf_keys") || localStorage.getItem("mangashelf_keys") || "null") || {}; } catch { return {}; }
  });
  const [fullSearchResults, setFullSearchResults] = useState(null);

  const removeProgressItem = useCallback(async (p) => {
    try {
      await api.deleteProgress(p.manga_url, p.volume_id);
      setProgress(prev => prev.filter(x => !(x.manga_url === p.manga_url && String(x.volume_id) === String(p.volume_id))));
      show("Lecture retirée");
    } catch (e) {
      show("Erreur: " + e.message);
    }
  }, [show]);

  const loadLists = useCallback(async () => {
    try {
      const data = await api.getLists();
      setReadItems(Array.isArray(data.read) ? data.read : []);
      setToReadItems(Array.isArray(data.to_read) ? data.to_read : []);
    } catch {
      setReadItems([]);
      setToReadItems([]);
    }
  }, []);

  const listKey = useCallback((listName, mangaUrl, volumeId = '', itemType = '') => `${listName}::${mangaUrl}::${volumeId || ''}::${itemType || ''}`, []);
  const guessItemType = useCallback((volumeId = '', explicitType = '') => {
    if (explicitType) return explicitType;
    const v = String(volumeId || '').toLowerCase();
    if (!v) return 'manga';
    if (v.startsWith('imgvol:')) return 'tome';
    if (v.includes('oneshot') || v.includes('one-shot')) return 'oneshot';
    if (v.includes('chap') || v.includes('chapter')) return 'chapter';
    return 'tome';
  }, []);
  const isInList = useCallback((items, mangaUrl, volumeId = '', itemType = '') => {
    const targetType = guessItemType(volumeId, itemType);
    return items.some(it => String(it.manga_url) === String(mangaUrl) && String(it.volume_id || '') === String(volumeId || '') && String(it.item_type || '') === String(targetType));
  }, [guessItemType]);
  const toggleListItem = useCallback(async ({ listName, mangaUrl, volumeId = '', itemType = '', title = '' }) => {
    const normalizedType = guessItemType(volumeId, itemType);
    const currentItems = listName === 'read' ? readItems : toReadItems;
    const exists = currentItems.some(it => String(it.manga_url) === String(mangaUrl) && String(it.volume_id || '') === String(volumeId || '') && String(it.item_type || '') === String(normalizedType));
    try {
      if (exists) {
        await api.removeListItem(listName, mangaUrl, volumeId || null, normalizedType);
      } else {
        await api.addListItem({ list_name: listName, manga_url: mangaUrl, volume_id: volumeId || '', item_type: normalizedType, title });
      }
      await loadLists();
      show(exists ? 'Retiré' : (listName === 'read' ? 'Ajouté à Lu' : 'Ajouté à À lire'));
    } catch (e) {
      show('Erreur: ' + e.message);
    }
  }, [guessItemType, loadLists, readItems, show, toReadItems]);

  const groupedMangas = useMemo(() => groupLibraryMangas(allMangas), [allMangas]);
  const groupedAlphaIndex = useMemo(() => {
    const out = {};
    for (const m of groupedMangas) {
      const first = (m.title || '?')[0]?.toUpperCase?.() || '#';
      const key = /[A-Z]/.test(first) ? first : '#';
      out[key] = (out[key] || 0) + 1;
    }
    return out;
  }, [groupedMangas]);
  const mangaByFolder = useCallback((folder) => groupedMangas.find(m => m.grouped_variants?.some(v => String(v.cbz_folder) === String(folder))) || allMangas.find(m => String(m.cbz_folder) === String(folder)), [allMangas, groupedMangas]);

  const applyTheme = useCallback((colors) => {
    const root = document.documentElement;
    const map = { d:"--d", bg:"--bg", c1:"--c1", c2:"--c2", c3:"--c3", inp:"--inp",
      brd:"--brd", brf:"--brf", t1:"--t1", t2:"--t2", t3:"--t3",
      ac:"--ac", acl:"--acl", grn:"--grn", amb:"--amb", ros:"--ros", cyn:"--cyn" };
    Object.entries(colors).forEach(([k, v]) => {
      if (map[k]) root.style.setProperty(map[k], v);
      if (k === "ac") root.style.setProperty("--acg", v + "1a");
    });
    // Extended theme properties
    root.style.setProperty("--bg-image", colors.bgImage || "none");
    root.style.setProperty("--card-bg-image", colors.cardBgImage || "none");
    root.style.setProperty("--card-border-style", colors.cardBorderStyle || "solid");
    root.style.setProperty("--card-border-width", colors.cardBorderWidth || "1px");
    root.style.setProperty("--font-family", colors.fontFamily || "'Lexend', 'Noto Sans JP', sans-serif");
    root.style.setProperty("--overlay-opacity", colors.overlayOpacity || "0");
  }, []);

  // Detail
  const [sel, setSel] = useState(null); // manga from library
  const [det, setDet] = useState(null); // full details from /api/library/:id
  const [detL, setDetL] = useState(false);
  const [dtab, setDtab] = useState("info");
  const [expEd, setExpEd] = useState({});
  const [tomes, setTomes] = useState([]);
  const [tomesL, setTomesL] = useState(false);
  const [volFilter, setVolFilter] = useState(null); // null=all, "tome", "chapter"
  const [activeEditionLabel, setActiveEditionLabel] = useState(null); // normalized label or null for all

  // Reader
  const [rdr, setRdr] = useState(false);
  const [rPg, setRPg] = useState([]); const [rP, setRP] = useState(0);
  const [rTitle, setRTitle] = useState(""); const [rUrl, setRUrl] = useState("");
  const [rVol, setRVol] = useState(""); const [rZoom, setRZoom] = useState(1);
  const [rCbz, setRCbz] = useState(null);
  const [rMode, setRMode] = useState("paged"); // paged | webtoon | double
  const [rBarVisible, setRBarVisible] = useState(false);
  const [rRTL, setRRTL] = useState(false); // right-to-left reading
  const [rNextVol, setRNextVol] = useState(null); // {tome, manga} for auto-advance
  const [rShowNextPrompt, setRShowNextPrompt] = useState(false);
  const [rBookmarks, setRBookmarks] = useState([]); // [pageIndex, ...]
  const [rShowThumbs, setRShowThumbs] = useState(false);
  const rScrollRef = useRef(null);
  const rImgRefs = useRef([]);
  const rTouchStart = useRef(null);

  // Admin
  const [users, setUsers] = useState([]);
  const [showUM, setShowUM] = useState(false); const [editU, setEditU] = useState(null);
  const [uf, setUf] = useState({ name: "", pass: "", role: "user", readOnly: false, canDownload: false, canChangePassword: true });
  const [ue, setUe] = useState("");
  const [cfg, setCfg] = useState({ nautiljon_db_available: false, nautiljon_db_path: "", cbz_path: "" });
  const [amLog, setAmLog] = useState([]); const [amRun, setAmRun] = useState(false);
  const [showP, setShowP] = useState(false);
  const [pf, setPf] = useState({ old: "", n1: "", n2: "" }); const [pe, setPe] = useState("");
  const sRef = useRef(null);

  useEffect(() => {
    (async () => {
      try { const h = await api.nautiljonHealth(); setApiSt(h.status); } catch { setApiSt("offline"); }
      try { setProgress(await api.getProgress()); } catch {}
      await loadLists();
      try { const libs = await api.getLibraries(); setLibraries(libs); } catch {}
      try {
        const t = await api.getUserTheme();
        setCurrentThemeId(t.id);
        applyTheme(t.colors);
        const ts = await api.getThemes();
        setThemes(ts);
      } catch {}
      try { setNotifications(await api.getNotifications()); } catch {}
      try { setActivity(await api.getActivity()); } catch {}
    })();
  }, []);

  const loadAll = useCallback(async (libId, reset = true) => {
    const lid = libId !== undefined ? libId : activeLibId;
    if (reset) setAllLoading(true);
    try {
      const d = await api.getLibrary(lid);
      setAllMangas(d.items || []);
      setAlphaIndex(d.alpha_index || {});
      setPendingCount(d.pending || 0);
      setHasMore(d.has_more || false);
    } catch (e) { show("Erreur: " + e.message); }
    finally { setAllLoading(false); }
  }, [show, activeLibId]);

  const loadMore = useCallback(async () => {
    if (loadingMore || !hasMore) return;
    setLoadingMore(true);
    try {
      const d = await api.getLibrary(activeLibId, PAGE_SIZE, allMangas.length);
      if (d.items?.length) {
        setAllMangas(prev => [...prev, ...d.items]);
        setHasMore(d.has_more || false);
      } else {
        setHasMore(false);
      }
    } catch {}
    finally { setLoadingMore(false); }
  }, [loadingMore, hasMore, activeLibId, allMangas.length]);

  // Infinite scroll: observe sentinel at bottom of grid
  useEffect(() => {
    const el = loadMoreRef.current;
    if (!el) return;
    const obs = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) loadMore();
    }, { rootMargin: '200px' });
    obs.observe(el);
    return () => obs.disconnect();
  }, [loadMore]);

  useEffect(() => { loadAll(); api.getRatings().then(setUserRatings).catch(() => {}); api.getNotes().then(setUserNotes).catch(() => {}); }, []); // eslint-disable-line

  const switchLib = (libId) => {
    setActiveLibId(libId);
    setAlphaFilter(null);
    setSq("");
    loadAll(libId);
  };

  const getFiltered = () => {
    let list = groupedMangas;
    if (sq.trim()) { list = list.filter(m => mangaSearchMatchInfo(m, sq).ok); }
    if (alphaFilter) { list = list.filter(m => { const f = (m.title || "?")[0].toUpperCase(); return alphaFilter === "#" ? !f.match(/[A-Z]/) : f === alphaFilter; }); }
    const hasTagF = Object.values(tagFilters).some(v => v && v.length > 0);
    if (hasTagF) { list = list.filter(m => matchesTagFilters(m, tagFilters)); }
    if (contentType === "tome") { list = list.filter(m => m.has_tomes && !m.is_oneshot); }
    if (contentType === "chapter") { list = list.filter(m => m.has_chapters); }
    if (contentType === "oneshot") { list = list.filter(m => m.is_oneshot || m.has_oneshots); }
    if (contentType === "editions") { list = list.filter(m => m.grouped_variants?.length > 1); }
    // Sort
    if (sortBy === "rating") {
      list = [...list].sort((a, b) => (userRatings[b.id] || 0) - (userRatings[a.id] || 0));
    } else if (sortBy === "date") {
      list = [...list].sort((a, b) => (b.id || 0) - (a.id || 0));
    } else if (sortBy === "volumes") {
      list = [...list].sort((a, b) => {
        const va = parseInt(a.metadata_json?.Volumes || "0") || 0;
        const vb = parseInt(b.metadata_json?.Volumes || "0") || 0;
        return vb - va;
      });
    } else if (sortBy === "lastRead") {
      const progMap = {};
      progress.forEach(p => { const t = p.last_read || 0; if (!progMap[p.manga_url] || t > progMap[p.manga_url]) progMap[p.manga_url] = t; });
      list = [...list].sort((a, b) => (progMap[b.cbz_folder] || 0) - (progMap[a.cbz_folder] || 0));
    }
    return list;
  };
  const filtered = getFiltered();
  const allTags = extractAllTags(groupedMangas);
  const activeTagCount = Object.values(tagFilters).reduce((s, v) => s + (v?.length || 0), 0);
  const alphaLetters = ["#", ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("")];

  const toggleTag = (cat, tag) => {
    setTagFilters(prev => {
      const cur = prev[cat] || [];
      const next = cur.includes(tag) ? cur.filter(t => t !== tag) : [...cur, tag];
      return { ...prev, [cat]: next };
    });
  };
  const clearTagFilters = () => { setTagFilters({}); setShowTagPanel(false); };

  // Detail
  const openDet = async (m) => {
    const variants = Array.isArray(m?.grouped_variants) && m.grouped_variants.length ? m.grouped_variants : [m];
    const primary = variants[0];
    setSel({ ...m, grouped_variants: variants }); setDtab("info"); setDet(null); setExpEd({}); setTomes([]); setDetL(true);
    setActiveEditionLabel(null);
    // Auto-set volume filter from library content filter
    setVolFilter(contentType);
    try {
      const d = await api.getLibraryManga(primary.id);
      setDet(d);
    } catch { show("Erreur détails"); }
    finally { setDetL(false); }
    loadTomes(variants);
  };
  const closeDet = () => { setSel(null); setDet(null); setTomes([]); setVolFilter(null); setActiveEditionLabel(null); };

  const loadTomes = async (variants) => {
    setTomesL(true);
    try {
      let arr = Array.isArray(variants) ? variants : [{ cbz_folder: variants, __edition_label: '', __edition_cbz_folders: [variants], title: sel?.title || '' }];
      
      // Expand variants: each variant may have multiple cbz_folders (deduped editions)
      const loadTasks = [];
      for (const variant of arr) {
        const folders = variant.__edition_cbz_folders || [variant.cbz_folder];
        for (const folder of folders) {
          loadTasks.push({ folder, label: variant.__edition_label || '', title: variant.title || sel?.title || '' });
        }
      }

      const chunks = await Promise.all(loadTasks.map(async ({ folder, label, title }) => {
        const d = await api.cbzList(folder);
        const files = (d.files || []).filter(f => !String(f.name || "").toLowerCase().endsWith(".cbr"));
        return files.map(f => ({ ...f, cbz_folder: folder, __edition_label: label, __edition_folder: folder, __edition_title: title }));
      }));
      
      // Deduplicate by (volume_type, volume_num) within same edition label
      const seen = new Set();
      const deduped = [];
      for (const t of chunks.flat()) {
        const edKey = normalizeEditionLabel(t.__edition_label || '');
        const volKey = t.volume_type && t.volume != null ? `${edKey}::${t.volume_type}:${t.volume}` : `${edKey}::file:${t.name}`;
        if (!seen.has(volKey)) {
          seen.add(volKey);
          deduped.push(t);
        }
      }
      setTomes(deduped);
    } catch {
      setTomes([]);
    }
    finally { setTomesL(false); }
  };

  // Progress
  const saveProg = async (mangaId, volId, pg, tot, title) => {
    try { await api.saveProgress({ manga_url: String(mangaId), volume_id: volId, current_page: pg, total_pages: tot, title }); } catch {}
  };

  // Reader
  const closeReader = async () => {
    if (rUrl) await saveProg(rUrl, rVol, rP, rPg.length, rTitle);
    setRdr(false); setRBarVisible(false);
    try { setProgress(await api.getProgress()); } catch {}
    await loadLists();
  };
  const enterFullscreen = () => {
    // Show bar briefly then auto-hide after 2s
    setRBarVisible(true);
    setTimeout(() => setRBarVisible(false), 2000);
  };
  const rdrGo = async (pg) => {
    const step = rMode === 'double' ? 2 : 1;
    let c = Math.max(0, Math.min(pg, rPg.length - 1));
    // At last page → prompt next volume
    if (pg >= rPg.length && rNextVol) {
      setRShowNextPrompt(true);
      return;
    }
    setRP(c);
    if (rUrl) {
      await saveProg(rUrl, rVol, c, rPg.length, rTitle);
      if (c % 5 === 0) try { setProgress(await api.getProgress()); } catch {}
    }
  };

  const rdrNext = () => rdrGo(rP + (rMode === 'double' ? 2 : 1));
  const rdrPrev = () => rdrGo(rP - (rMode === 'double' ? 2 : 1));

  const toggleBookmark = (page) => {
    setRBookmarks(prev => prev.includes(page) ? prev.filter(p => p !== page) : [...prev, page].sort((a, b) => a - b));
  };

  const findNextVolume = (manga, currentTome) => {
    if (!currentTome || !tomes.length) { setRNextVol(null); return; }
    const curNum = currentTome.volume ?? currentTome.volume_num;
    const curType = currentTome.volume_type || 'tome';
    if (curNum == null) { setRNextVol(null); return; }
    const next = tomes.find(t => (t.volume ?? t.volume_num) > curNum && (t.volume_type || 'tome') === curType);
    setRNextVol(next ? { tome: next, manga } : null);
  };

  const openNextVolume = async () => {
    if (!rNextVol) return;
    setRShowNextPrompt(false);
    const { tome, manga } = rNextVol;
    await closeReader();
    setTimeout(() => openCbzVol(manga, tome, 0), 200);
  };
  const openCbzVol = async (manga, tome, startPage = 0) => {
    // Virtual "image folders" volume: tome.path = imgvol:<folder>:<volume>
    if (String(tome?.source || '').toLowerCase() === 'images' || String(tome?.path || '').startsWith('imgvol:')) {
      try {
        const parts = String(tome.path || '').split(':');
        const folder = parts.length >= 3 ? parts.slice(1, -1).join(':') : manga.cbz_folder;
        const volNum = parts.length >= 3 ? Number(parts[parts.length - 1]) : Number(tome.volume || 0);
        const info = await api.imgVolInfo(folder, volNum);
        const pages = Array.from({ length: info.total_pages }, (_, i) => api.imgVolPageUrl(folder, volNum, i));
        setRPg(pages);
        setRTitle(`${manga.title} — ${tome.display || `Tome ${volNum || "?"}`}`);
        setRUrl(manga.cbz_folder);
        // Keep volume_id stable for progress
        setRVol(`imgvol:${folder}:${volNum}`);
        const meta = (det?.metadata_json && typeof det.metadata_json === 'object') ? det.metadata_json : (manga?.metadata_json || {});
        const metaTxt = normalizeSearchText([meta?.Type, meta?.Types, meta?.Format, meta?.ReadingMode, meta?.reading_mode].filter(Boolean).join(' '));
        setRMode(metaTxt.includes('webtoon') ? 'webtoon' : 'paged');
        setRP(Math.max(0, Math.min(startPage, info.total_pages - 1)));
        setRZoom(1);
        setRCbz(null);
        setRdr(true); setRBarVisible(false); enterFullscreen();
      } catch (e) {
        show(`Erreur: ${e.message}`);
      }
      return;
    }
    try {
      const info = await api.cbzInfo(tome.path);
      const pages = Array.from({ length: info.total_pages }, (_, i) => api.cbzPageUrl(tome.path, i));
      setRPg(pages); setRTitle(`${manga.title} — ${tome.display || `Tome ${tome.volume || "?"}`}`);
      setRUrl(manga.cbz_folder); setRVol(tome.path);
      const meta = (det?.metadata_json && typeof det.metadata_json === 'object') ? det.metadata_json : (manga?.metadata_json || {});
      const metaTxt = normalizeSearchText([meta?.Type, meta?.Types, meta?.Format, meta?.ReadingMode, meta?.reading_mode].filter(Boolean).join(' '));
      setRMode(metaTxt.includes('webtoon') ? 'webtoon' : 'paged');
      setRP(Math.max(0, Math.min(startPage, info.total_pages - 1))); setRZoom(1); setRCbz({ filepath: tome.path }); setRdr(true); setRBarVisible(false); setRBookmarks([]); setRShowNextPrompt(false); setRShowThumbs(false); enterFullscreen();
      findNextVolume(manga, tome);
    } catch (e) { show(`Erreur: ${e.message}`); }
  };

  const resumeReading = async (p) => {
    // Resume supports both CBZ and "imgvol:".
    if (String(p.volume_id || '').startsWith('imgvol:')) {
      const parts = String(p.volume_id).split(':');
      const folder = parts.slice(1, -1).join(':');
      const volNum = Number(parts[parts.length - 1]);
      const info = await api.imgVolInfo(folder, volNum);
      const pages = Array.from({ length: info.total_pages }, (_, i) => api.imgVolPageUrl(folder, volNum, i));
      setRPg(pages);
      setRTitle(p.title || p.manga_url);
      setRUrl(p.manga_url);
      setRVol(p.volume_id);
      setRMode('paged');
      setRZoom(1);
      setRP(Math.max(0, Math.min(p.current_page, info.total_pages - 1)));
      setRCbz(null);
      setRdr(true); setRBarVisible(false); enterFullscreen();
      return;
    }
    const pages = Array.from({ length: p.total_pages }, (_, i) => api.cbzPageUrl(p.volume_id, i));
    setRPg(pages);
    setRTitle(p.title || p.manga_url);
    setRUrl(p.manga_url);
    setRVol(p.volume_id);
    setRMode('paged');
    setRZoom(1);
    setRP(Math.max(0, Math.min(p.current_page, p.total_pages - 1)));
    setRCbz({ filepath: p.volume_id });
    setRdr(true); setRBarVisible(false); enterFullscreen();
  };

  useEffect(() => { rImgRefs.current = []; }, [rdr, rMode, rPg.length]);

  const rdrScrollBy = (dy) => {
    const el = rScrollRef.current;
    if (!el) return;
    el.scrollBy({ top: dy, behavior: 'smooth' });
  };

  // Paged: custom keyboard shortcuts
  useEffect(() => {
    if (!rdr) return;
    const kc = { nextPage: "ArrowRight", prevPage: "ArrowLeft", nextPageAlt: " ", toggleBar: "Escape", toggleBookmark: "b", toggleWebtoon: "w", toggleDouble: "d", zoomIn: "+", zoomOut: "-", zoomReset: "0", ...keyConfig };
    const isKey = (e, ...actions) => actions.some(a => e.key === kc[a] || e.key === kc[a]?.toUpperCase?.());
    const h = (e) => {
      if (isKey(e, "toggleBar")) { if (rShowNextPrompt) { setRShowNextPrompt(false); return; } closeReader(); return; }
      if (rMode === 'webtoon') {
        if (isKey(e, "nextPage", "nextPageAlt") || e.key === "PageDown") { e.preventDefault(); rdrScrollBy(Math.round(window.innerHeight * 0.85)); }
        else if (isKey(e, "prevPage") || e.key === "PageUp") { e.preventDefault(); rdrScrollBy(-Math.round(window.innerHeight * 0.85)); }
      } else {
        if (isKey(e, "nextPage", "nextPageAlt")) { e.preventDefault(); rdrNext(); }
        else if (isKey(e, "prevPage")) { e.preventDefault(); rdrPrev(); }
      }
      if (isKey(e, "toggleBookmark")) { toggleBookmark(rP); }
      if (isKey(e, "toggleWebtoon")) { setRMode(m => m === 'webtoon' ? 'paged' : 'webtoon'); }
      if (isKey(e, "toggleDouble")) { setRMode(m => m === 'double' ? 'paged' : 'double'); }
      if (isKey(e, "zoomIn")) { e.preventDefault(); setRZoom(z => Math.min(z + .2, 3)); }
      if (isKey(e, "zoomOut")) { e.preventDefault(); setRZoom(z => Math.max(z - .2, .4)); }
      if (isKey(e, "zoomReset")) { setRZoom(1); }
    };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [rdr, rMode, rP, rPg.length, rShowNextPrompt, keyConfig]);

  // Android WebView: boutons volume (événement custom)
  useEffect(() => {
    if (!rdr) return;
    const h = (e) => {
      const dir = e?.detail?.direction;
      if (!dir) return;
      // vol- = suivant ; vol+ = précédent
      if (rMode === 'webtoon') {
        if (dir === 'next') rdrScrollBy(Math.round(window.innerHeight * 0.85));
        else if (dir === 'prev') rdrScrollBy(-Math.round(window.innerHeight * 0.85));
      } else {
        if (dir === 'next') rdrNext();
        else if (dir === 'prev') rdrPrev();
      }
    };
    window.addEventListener('tamashelf-volume', h);
    return () => window.removeEventListener('tamashelf-volume', h);
  }, [rdr, rMode, rP, rPg.length]);

  // Webtoon: calcule une “page courante” approximative en fonction du scroll
  useEffect(() => {
    if (!rdr || rMode !== 'webtoon') return;
    const el = rScrollRef.current;
    if (!el) return;
    let raf = 0;
    const onScroll = () => {
      if (raf) return;
      raf = requestAnimationFrame(() => {
        raf = 0;
        const refs = rImgRefs.current || [];
        let bestIdx = 0;
        let bestDist = Infinity;
        for (let i = 0; i < refs.length; i++) {
          const img = refs[i];
          if (!img) continue;
          const r = img.getBoundingClientRect();
          const dist = Math.abs(r.top - 80);
          if (dist < bestDist) { bestDist = dist; bestIdx = i; }
        }
        setRP(bestIdx);
      });
    };
    el.addEventListener('scroll', onScroll, { passive: true });
    onScroll();
    return () => { el.removeEventListener('scroll', onScroll); if (raf) cancelAnimationFrame(raf); };
  }, [rdr, rMode, rPg.length]);
  useEffect(() => { const h = (e) => { if (rdr) return; if (e.key === "Escape" && sel) closeDet(); }; window.addEventListener("keydown", h); return () => window.removeEventListener("keydown", h); });

  // Point (tap ou clic) sur la page : centre → afficher/masquer la barre, côtés → page
  // précédente/suivante (mode paginé/double uniquement). Partagé entre le tap tactile
  // (handleTouchEnd) et le clic souris (handleReaderClick) pour un comportement identique
  // sur mobile et sur ordinateur.
  const handleReaderTapZone = (cx, cy) => {
    if (cx > 0.25 && cx < 0.75 && cy > 0.2 && cy < 0.8) {
      setRBarVisible(v => !v);
      return;
    }
    if (rMode === 'paged' || rMode === 'double') {
      if (cx <= 0.25) rdrGo(rRTL ? rP + (rMode === 'double' ? 2 : 1) : rP - (rMode === 'double' ? 2 : 1));
      else if (cx >= 0.75) rdrGo(rRTL ? rP - (rMode === 'double' ? 2 : 1) : rP + (rMode === 'double' ? 2 : 1));
    }
  };

  // Clic souris sur la page (ordinateur) : même zones que le tap tactile ci-dessous.
  const handleReaderClick = (e) => {
    handleReaderTapZone(e.clientX / window.innerWidth, e.clientY / window.innerHeight);
  };

  // Touch gestures: swipe left/right = next/prev, tap center = toggle bar
  const handleTouchStart = (e) => {
    const t = e.touches[0];
    rTouchStart.current = { x: t.clientX, y: t.clientY, time: Date.now() };
  };
  const handleTouchEnd = (e) => {
    if (!rTouchStart.current) return;
    const t = e.changedTouches[0];
    const dx = t.clientX - rTouchStart.current.x;
    const dy = t.clientY - rTouchStart.current.y;
    const dt = Date.now() - rTouchStart.current.time;
    const w = window.innerWidth;
    const h = window.innerHeight;
    rTouchStart.current = null;

    // Tap (short press, small movement) at center → toggle bar
    if (Math.abs(dx) < 20 && Math.abs(dy) < 20 && dt < 300) {
      handleReaderTapZone(t.clientX / w, t.clientY / h);
      return;
    }

    // Swipe horizontal (paged/double mode)
    if ((rMode === 'paged' || rMode === 'double') && Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy) * 1.5) {
      if (dx < 0) rdrNext();
      else rdrPrev();
    }
  };

  // Admin
  const loadUsers = async () => { try { setUsers(await api.getUsers()); } catch {} };
  const loadCfg = async () => { try { setCfg(await api.getConfig()); } catch {} };
  useEffect(() => { if (isAdmin && nav.startsWith("admin")) { loadUsers(); loadCfg(); } }, [nav]);

  const openCreateU = () => { setEditU(null); setUf({ name: "", pass: "", role: "user", readOnly: false, canDownload: false, canChangePassword: true }); setUe(""); setShowUM(true); };
  const openEditU = (u) => { setEditU(u); setUf({ name: u.username, pass: "", role: u.role, readOnly: !!u.perm_read_only, canDownload: !!u.perm_can_download, canChangePassword: u.perm_can_change_password !== 0 }); setUe(""); setShowUM(true); };
  const saveUser = async () => { try { if (editU) await api.updateUser(editU.id, { username: uf.name.trim(), password: uf.pass || undefined, role: uf.role, perm_read_only: uf.readOnly, perm_can_download: uf.canDownload, perm_can_change_password: uf.canChangePassword }); else { if (!uf.name.trim() || !uf.pass) { setUe("Champs requis"); return; } await api.createUser({ username: uf.name.trim(), password: uf.pass, role: uf.role, perm_read_only: uf.readOnly, perm_can_download: uf.canDownload, perm_can_change_password: uf.canChangePassword }); } setShowUM(false); loadUsers(); show(editU ? "Modifié" : "Créé"); } catch (e) { setUe(e.message); } };
  const delUser = async (u) => { try { await api.deleteUser(u.id); loadUsers(); } catch (e) { show(e.message); } };
  const saveCfg = async () => { try { await api.updateConfig(cfg); show("Sauvegardé"); } catch (e) { show(e.message); } };

  const runAutoMatch = async () => {
    setAmRun(true); setAmLog(["🚀 Matching des dossiers CBZ…"]);
    try {
      const r = await api.autoMatch();
      setAmLog(p => [...p, `✅ ${r.auto_matched} matchés, ${r.not_found} non trouvés, ${r.errors} erreurs, ${r.covers} covers`]);
      loadAll(activeLibId);
    } catch (e) { setAmLog(p => [...p, `❌ ${e.message}`]); }
    setAmRun(false);
  };

  const changePw = async () => { if (pf.n1.length < 4) { setPe("Trop court"); return; } if (pf.n1 !== pf.n2) { setPe("Différents"); return; } try { await api.changePassword({ old_password: pf.old, new_password: pf.n1 }); setShowP(false); show("MDP changé"); } catch (e) { setPe(e.message); } };
  const stCls = (s) => { if (!s) return ""; const l = s.toLowerCase(); return l.includes("cours") ? "st-on" : l.includes("termin") ? "st-end" : ""; };

  const statusBadge = (s) => {
    if (s === "matched") return <span className="badge bg">✓</span>;
    if (s === "pending") return <span className="badge ba">?</span>;
    if (s === "manual") return <span className="badge bb">M</span>;
    return <span className="badge" style={{ background: "var(--brd)" }}>—</span>;
  };

  return (
    <>
      <header className="hdr">
        <div className="logo" onClick={() => { setNav("library"); setSq(""); setAlphaFilter(null); }}><div className="logo-i">鬼</div><span>TamaShelf</span></div>
        {nav === "library" && <div className="sbar"><span className="si">🔍</span><input ref={sRef} placeholder="Rechercher… (Entrée = recherche approfondie)" value={sq} onChange={e => { setSq(e.target.value); setAlphaFilter(null); if (!e.target.value.trim()) setFullSearchResults(null); }} onKeyDown={async e => { if (e.key === "Enter" && sq.trim()) { try { setFullSearchResults(await api.fullSearch(sq.trim())); } catch {} } }} /></div>}
        <div className="hr">
          <div className="pill"><div className={`dot ${apiSt === "online" ? "d-on" : "d-off"}`} />{apiSt === "online" ? "API" : "…"}</div>
          <span className="cnt">{allMangas.length} mangas</span>
          {pendingCount > 0 && isAdmin && <span className="badge ba" style={{ cursor: "pointer" }} onClick={() => setNav("admin-match")}>{pendingCount} à valider</span>}
          <div className="user-p" onClick={() => setShowP(true)}><div className={`av ${isAdmin ? "av-admin" : "av-user"}`}>{session.username[0].toUpperCase()}</div><span>{session.username}</span></div>
        </div>
      </header>
      <div className="app-body">
        <nav className="sidebar">
          <div className={`sb-item ${nav === "home" ? "on" : ""}`} onClick={() => setNav("home")}>🏠 <span>Accueil</span></div>
          <div className={`sb-item ${nav === "library" ? "on" : ""}`} onClick={() => setNav("library")}>📚 <span>Bibliothèque</span></div>
          <div className={`sb-item ${nav === "reading" ? "on" : ""}`} onClick={() => { setNav("reading"); api.getProgress().then(setProgress).catch(() => {}); }}>📖 <span>Reprises</span>{progress.filter(p => p.current_page > 0 && p.current_page < (p.total_pages || 1) - 1).length > 0 && <span className="badge ba" style={{ marginLeft: 4, fontSize: 9 }}>{progress.filter(p => p.current_page > 0 && p.current_page < (p.total_pages || 1) - 1).length}</span>}</div>
          <div className={`sb-item ${nav === "to-read" ? "on" : ""}`} onClick={() => { setNav("to-read"); loadLists(); }}>🕒 <span>À lire</span>{toReadItems.length > 0 && <span className="badge ba" style={{ marginLeft: 4, fontSize: 9 }}>{toReadItems.length}</span>}</div>
          <div className={`sb-item ${nav === "read" ? "on" : ""}`} onClick={() => { setNav("read"); loadLists(); }}>✅ <span>Lu</span>{readItems.length > 0 && <span className="badge bg" style={{ marginLeft: 4, fontSize: 9 }}>{readItems.length}</span>}</div>
          <div className={`sb-item ${nav === "collections" ? "on" : ""}`} onClick={() => setNav("collections")}>📂 <span>Collections</span></div>
          <div className={`sb-item ${nav === "stats" ? "on" : ""}`} onClick={() => setNav("stats")}>📊 <span>Stats</span></div>
          <div className={`sb-item ${nav === "activity" ? "on" : ""}`} onClick={() => { setNav("activity"); api.getActivity().then(setActivity).catch(() => {}); }}>👥 <span>Activité</span></div>
          <div className={`sb-item ${nav === "app-android" ? "on" : ""}`} onClick={() => setNav("app-android")}>📱 <span>App Android</span></div>
          {isAdmin && <><div className="sb-sep" /><div className="sb-label">Admin</div>
            <div className={`sb-item ${nav === "admin-users" ? "on" : ""}`} onClick={() => setNav("admin-users")}>👥 <span>Utilisateurs</span></div>
            <div className={`sb-item ${nav === "admin-config" ? "on" : ""}`} onClick={() => setNav("admin-config")}>⚙️ <span>Config</span></div>
            <div className={`sb-item ${nav === "admin-libraries" ? "on" : ""}`} onClick={() => setNav("admin-libraries")}>🗂️ <span>Bibliothèques</span></div>
            <div className={`sb-item ${nav === "admin-match" ? "on" : ""}`} onClick={() => setNav("admin-match")}>🔄 <span>Matching</span>{pendingCount > 0 && <span className="badge ba" style={{ marginLeft: 4, fontSize: 9 }}>{pendingCount}</span>}</div>
            <div className={`sb-item ${nav === "admin-cbz-covers" ? "on" : ""}`} onClick={() => setNav("admin-cbz-covers")}>🖼️ <span>Covers CBZ</span></div>
            <div className={`sb-item ${nav === "admin-duplicates" ? "on" : ""}`} onClick={() => setNav("admin-duplicates")}>🔀 <span>Doublons</span></div>
            <div className={`sb-item ${nav === "admin-themes" ? "on" : ""}`} onClick={() => setNav("admin-themes")}>🎨 <span>Thèmes</span></div>
          </>}
        </nav>
        <div className="main">
          {nav === "reading" && (() => {
            const items = progress.filter(p => p.current_page > 0 && p.current_page < (p.total_pages || 1) - 1);
            return (
              <div>
                <h2 style={{ color: "var(--t1)", marginBottom: 16 }}>Reprises de lecture</h2>
                {!items.length && <p style={{ color: "var(--t3)" }}>Aucune lecture en cours. Lis quelques pages d'un tome et il apparaitra ici.</p>}
                <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(280px, 1fr))", gap: 12 }}>
                  {items.map(p => {
                    const pct = p.total_pages > 0 ? Math.round(p.current_page / p.total_pages * 100) : 0;
                    return (
                      <div key={`${p.manga_url}__${p.volume_id}`} onClick={() => resumeReading(p)}
                        style={{ position: "relative", display: "flex", gap: 12, padding: 12, borderRadius: "var(--r)", background: "var(--c1)", border: "1px solid var(--brd)", cursor: "pointer", transition: "transform .1s" }}
                        onMouseEnter={e => e.currentTarget.style.transform = "scale(1.02)"} onMouseLeave={e => e.currentTarget.style.transform = "scale(1)"}>
                        <button
                          className="xbtn"
                          title="Retirer"
                          onClick={(e) => { e.stopPropagation(); removeProgressItem(p); }}
                          style={{ position: "absolute", top: 8, right: 8 }}
                        >✕</button>
                        <ReadingPreview progressItem={p} size={60} radius={6} />
                        <div style={{ flex: 1, minWidth: 0 }}>
                          <div style={{ fontWeight: 600, color: "var(--t1)", fontSize: 14, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{p.title || p.manga_url}</div>
                          <div style={{ color: "var(--t3)", fontSize: 12, marginTop: 4 }}>Page {p.current_page + 1} / {p.total_pages}</div>
                          <div style={{ height: 6, background: "var(--brd)", borderRadius: 3, marginTop: 8, overflow: "hidden" }}>
                            <div style={{ width: pct + "%", height: "100%", background: "var(--ac)", borderRadius: 3 }} />
                          </div>
                          <div style={{ color: "var(--t3)", fontSize: 11, marginTop: 4 }}>{pct}% lu</div>
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            );
          })()}
          {nav === "to-read" && (() => {
            const items = toReadItems.map(it => ({ ...it, manga: mangaByFolder(it.manga_url) })).sort((a, b) => String(a.title || a.manga?.title || a.manga_url).localeCompare(String(b.title || b.manga?.title || b.manga_url), 'fr', { sensitivity: 'base' }));
            return (
              <div>
                <h2 style={{ color: "var(--t1)", marginBottom: 16 }}>À lire</h2>
                {!items.length && <p style={{ color: "var(--t3)" }}>Aucun élément dans À lire pour le moment.</p>}
                <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(280px, 1fr))", gap: 12 }}>
                  {items.map((it, idx) => (
                    <div key={listKey('to_read', it.manga_url, it.volume_id, it.item_type) || idx} style={{ position: 'relative', display: 'flex', gap: 12, padding: 12, borderRadius: 'var(--r)', background: 'var(--c1)', border: '1px solid var(--brd)' }}>
                      <button className="xbtn" title="Retirer" onClick={() => toggleListItem({ listName: 'to_read', mangaUrl: it.manga_url, volumeId: it.volume_id, itemType: it.item_type, title: it.title })} style={{ position: 'absolute', top: 8, right: 8 }}>✕</button>
                      <img src={api.cbzFolderCoverUrl(it.manga_url)} alt="" style={{ width: 60, height: 85, objectFit: 'cover', borderRadius: 6, flexShrink: 0, background: 'var(--c2)' }} onError={e => { e.target.style.opacity = '0.3'; }} />
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontWeight: 700, color: 'var(--t1)', fontSize: 14 }}>{it.title || it.manga?.title || it.manga_url}</div>
                        <div style={{ color: 'var(--t3)', fontSize: 12, marginTop: 4 }}>{it.item_type === 'manga' ? 'Manga complet' : (it.item_type === 'chapter' ? 'Chapitre' : it.item_type === 'oneshot' ? 'One-shot' : 'Tome')}</div>
                        {it.manga && <div style={{ color: 'var(--t2)', fontSize: 11, marginTop: 6 }}>{it.manga.title}</div>}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            );
          })()}

          {nav === "read" && (() => {
            const items = readItems.map(it => ({ ...it, manga: mangaByFolder(it.manga_url) })).sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
            return (
              <div>
                <h2 style={{ color: "var(--t1)", marginBottom: 16 }}>Lu</h2>
                {!items.length && <p style={{ color: "var(--t3)" }}>Aucun tome, chapitre ou one-shot lu pour le moment.</p>}
                <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(280px, 1fr))", gap: 12 }}>
                  {items.map((it, idx) => (
                    <div key={listKey('read', it.manga_url, it.volume_id, it.item_type) || idx} style={{ position: 'relative', display: 'flex', gap: 12, padding: 12, borderRadius: 'var(--r)', background: 'var(--c1)', border: '1px solid var(--brd)' }}>
                      <button className="xbtn" title="Retirer" onClick={() => toggleListItem({ listName: 'read', mangaUrl: it.manga_url, volumeId: it.volume_id, itemType: it.item_type, title: it.title })} style={{ position: 'absolute', top: 8, right: 8 }}>✕</button>
                      <img src={api.cbzFolderCoverUrl(it.manga_url)} alt="" style={{ width: 60, height: 85, objectFit: 'cover', borderRadius: 6, flexShrink: 0, background: 'var(--c2)' }} onError={e => { e.target.style.opacity = '0.3'; }} />
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontWeight: 700, color: 'var(--t1)', fontSize: 14 }}>{it.title || it.manga?.title || it.manga_url}</div>
                        <div style={{ color: 'var(--grn)', fontSize: 12, marginTop: 4 }}>{it.auto_added ? 'Ajouté automatiquement à 100%' : 'Ajout manuel'}</div>
                        {it.manga && <div style={{ color: 'var(--t2)', fontSize: 11, marginTop: 6 }}>{it.manga.title}</div>}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            );
          })()}

          {/* ══ HOMEPAGE ══ */}
          {nav === "home" && <HomepageView
            onOpenManga={(m) => { setNav("library"); setTimeout(() => openDet(m), 100); }}
            onResumeReading={resumeReading}
            allMangas={groupedMangas}
            show={show}
          />}

          {/* ══ COLLECTIONS ══ */}
          {nav === "collections" && <CollectionsView allMangas={groupedMangas} onOpenManga={(m) => openDet(m)} show={show} />}

          {/* ══ STATS ══ */}
          {nav === "stats" && <StatsView show={show} />}

          {/* ══ ACTIVITY ══ */}
          {nav === "activity" && <>
            <div className="sec-h"><span className="sec-t">👥 Activité récente</span>
              <button className="ib" style={{ marginLeft: "auto" }} onClick={async () => { try { setActivity(await api.getActivity()); show("Actualisé"); } catch {} }}>🔄</button>
            </div>
            {activity.length === 0 ? <div className="empty"><p>Aucune activité récente.</p></div> :
              activity.map((a, i) => (
                <div key={i} className="activity-item">
                  <div className="activity-avatar">{(a.username || "?")[0].toUpperCase()}</div>
                  <div style={{ flex: 1 }}>
                    <span style={{ fontWeight: 600, color: "var(--t1)" }}>{a.username}</span>
                    <span style={{ color: "var(--t3)", marginLeft: 6 }}>lit</span>
                    <span style={{ color: "var(--acl)", marginLeft: 6, fontWeight: 500 }}>{a.title || a.manga_url}</span>
                    {a.total_pages > 0 && <span style={{ color: "var(--t3)", marginLeft: 6 }}>— p.{a.current_page + 1}/{a.total_pages}</span>}
                  </div>
                  <span style={{ color: "var(--t3)", fontSize: 10, whiteSpace: "nowrap" }}>{a.last_read ? new Date(a.last_read * 1000).toLocaleDateString("fr") : ""}</span>
                </div>
              ))
            }
            <div style={{ marginTop: 20 }}>
              <div className="sec-h"><span className="sec-t">📦 Import / Export</span></div>
              <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
                <button className="btn btn-p" onClick={async () => {
                  try {
                    const data = await api.exportLists();
                    const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
                    const url = URL.createObjectURL(blob);
                    const a = document.createElement("a"); a.href = url; a.download = `tamashelf-export-${new Date().toISOString().slice(0,10)}.json`; a.click();
                    URL.revokeObjectURL(url);
                    show("Export téléchargé");
                  } catch (e) { show("Erreur: " + e.message); }
                }}>⬇ Exporter mes données</button>
                <label className="btn" style={{ cursor: "pointer" }}>
                  ⬆ Importer
                  <input type="file" accept=".json" style={{ display: "none" }} onChange={async e => {
                    const file = e.target.files?.[0];
                    if (!file) return;
                    try {
                      const text = await file.text();
                      const data = JSON.parse(text);
                      const r = await api.importLists(data);
                      show(`Importé : ${r.imported?.lists || 0} listes, ${r.imported?.ratings || 0} notes, ${r.imported?.collections || 0} collections`);
                      await loadLists();
                    } catch (e) { show("Erreur import: " + e.message); }
                    e.target.value = "";
                  }} />
                </label>
              </div>
              <p style={{ color: "var(--t3)", fontSize: 10, marginTop: 8 }}>L'export contient : listes Lu/À lire, progression, notes ⭐, commentaires, collections.</p>
            </div>
          </>}

          {/* ══ APP ANDROID ══ */}
          {nav === "app-android" && <AppAndroidView />}

          {nav === "library" && <>
            {libraries.length > 1 && (
              <div style={{ display: "flex", gap: 6, marginBottom: 10, flexWrap: "wrap" }}>
                <button
                  className="btn btn-s"
                  style={{ background: activeLibId == null ? "var(--ac)" : "var(--c2)", color: activeLibId == null ? "#fff" : "var(--t2)", border: "1px solid var(--brd)" }}
                  onClick={() => switchLib(null)}
                >Toutes</button>
                {libraries.map(lib => (
                  <button
                    key={lib.id}
                    className="btn btn-s"
                    style={{ background: activeLibId === lib.id ? "var(--ac)" : "var(--c2)", color: activeLibId === lib.id ? "#fff" : "var(--t2)", border: "1px solid var(--brd)" }}
                    onClick={() => switchLib(lib.id)}
                  >{lib.name}</button>
                ))}
              </div>
            )}
            {allLoading ? <div className="loading"><div className="spinner" />Chargement…</div> : <>
              {(() => {
                const inProgress = progress.filter(p => p.current_page > 0 && p.current_page < p.total_pages - 1);
                if (!inProgress.length) return null;
                return (
                  <div style={{ marginBottom: 16 }}>
                    <div className="sec-h"><span className="sec-t">📖 En cours de lecture</span><span className="cnt">{inProgress.length}</span></div>
                    <div style={{ display: "flex", gap: 10, overflowX: "auto", paddingBottom: 8 }}>
                      {inProgress.map(p => {
                        const pct = p.total_pages > 0 ? Math.round(p.current_page / p.total_pages * 100) : 0;
                        const label = p.title || p.manga_url || "?";
                        return (
                          <div key={`${p.manga_url}__${p.volume_id}`} onClick={() => resumeReading(p)}
                            style={{ minWidth: 90, maxWidth: 90, cursor: "pointer", flexShrink: 0 }}>
                            <div style={{ position: "relative", width: 90, height: 128, borderRadius: "var(--r)", overflow: "visible", background: "transparent", border: "none" }}>
                              <button
                                className="xbtn"
                                title="Retirer"
                                onClick={(e) => { e.stopPropagation(); removeProgressItem(p); }}
                                style={{ position: "absolute", top: 6, right: 6, zIndex: 2 }}
                              >✕</button>
                              <ReadingPreview progressItem={p} size={90} radius={12} />
                              <div style={{ position: "absolute", bottom: 0, left: 0, right: 0, height: 4, background: "var(--brd)" }}>
                                <div style={{ width: pct + "%", height: "100%", background: "var(--ac)", transition: "width .3s" }} />
                              </div>
                            </div>
                            <div style={{ fontSize: 10, color: "var(--t2)", marginTop: 4, textAlign: "center", lineHeight: 1.3 }}
                              title={label}>
                              {label.slice(0, 16)}{label.length > 16 ? "…" : ""}
                            </div>
                            <div style={{ fontSize: 9, color: "var(--t3)", textAlign: "center" }}>
                              p.{p.current_page + 1} / {p.total_pages} · {pct}%
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                );
              })()}
              <div className="sec-h">
                <span className="sec-t">{sq ? `« ${sq} »` : alphaFilter || (libraries.find(l => l.id === activeLibId)?.name || "Bibliothèque")}</span>
                <span className="cnt">{filtered.length}</span>
                {/* Tag filter button */}
                <button className={`ib${showTagPanel ? " on" : ""}`} onClick={() => setShowTagPanel(p => !p)} style={{ marginLeft: 6, position: "relative" }} title="Filtrer par tags">
                  🏷️{activeTagCount > 0 && <span style={{ position: "absolute", top: -2, right: -2, background: "var(--ac)", color: "#fff", borderRadius: "50%", width: 14, height: 14, fontSize: 8, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" }}>{activeTagCount}</span>}
                </button>
                {/* Content type filter */}
                <div className="vm-btns" style={{ marginLeft: 6 }}>
                  <button className={`vm-btn${contentType === null ? " on" : ""}`} onClick={() => setContentType(null)} title="Tout">Tout</button>
                  <button className={`vm-btn${contentType === "tome" ? " on" : ""}`} onClick={() => setContentType("tome")} title="Tomes">T</button>
                  <button className={`vm-btn${contentType === "chapter" ? " on" : ""}`} onClick={() => setContentType("chapter")} title="Chapitres">Ch</button>
                  <button className={`vm-btn${contentType === "oneshot" ? " on" : ""}`} onClick={() => setContentType("oneshot")} title="One-shots">OS</button>
                </div>
                {/* View mode toggle */}
                <div className="vm-btns">
                  <button className={`vm-btn${viewMode === "grid" ? " on" : ""}`} onClick={() => setViewMode("grid")} title="Grille">⊞</button>
                  <button className={`vm-btn${viewMode === "compact" ? " on" : ""}`} onClick={() => setViewMode("compact")} title="Compact">▦</button>
                  <button className={`vm-btn${viewMode === "list" ? " on" : ""}`} onClick={() => setViewMode("list")} title="Liste">☰</button>
                  <button className={`vm-btn${viewMode === "coverflow" ? " on" : ""}`} onClick={() => setViewMode("coverflow")} title="CoverFlow">🎴</button>
                  <button className={`vm-btn${viewMode === "shelf" ? " on" : ""}`} onClick={() => setViewMode("shelf")} title="Étagère">📚</button>
                </div>
                <select value={sortBy} onChange={e => setSortBy(e.target.value)} style={{ padding: "3px 8px", fontSize: 10, background: "var(--c2)", color: "var(--t2)", border: "1px solid var(--brd)", borderRadius: "var(--rs)", cursor: "pointer", marginLeft: 6 }}>
                  <option value="title">A→Z</option>
                  <option value="date">Récents</option>
                  <option value="rating">Notes ⭐</option>
                  <option value="volumes">Tomes</option>
                  <option value="lastRead">Dernière lecture</option>
                </select>
                <div style={{ position: "relative", marginLeft: 6 }}>
                  <button className="ib" onClick={() => setShowNotifs(v => !v)} title="Notifications">🔔</button>
                  {notifications.length > 0 && <span style={{ position: "absolute", top: 2, right: 2, width: 8, height: 8, borderRadius: "50%", background: "var(--ros)" }} />}
                </div>
                <button className="ib" onClick={() => loadAll(activeLibId)} style={{ marginLeft: "auto" }}>🔄</button>
              </div>

              {/* Active tag chips */}
              {activeTagCount > 0 && (
                <div className="active-tags">
                  {Object.entries(tagFilters).map(([cat, tags]) => (tags || []).map(tag => (
                    <span key={`${cat}:${tag}`} className="active-tag" style={{ background: tagColor(tag) }} onClick={() => toggleTag(cat, tag)}>
                      {tag} ✕
                    </span>
                  )))}
                  <span className="active-tag" style={{ background: "var(--c2)", border: "1px solid var(--brd)", color: "var(--t2)", cursor: "pointer" }} onClick={clearTagFilters}>Effacer tout</span>
                </div>
              )}

              {/* Tag filter panel */}
              {showTagPanel && (
                <div className="tag-panel">
                  {Object.entries(allTags).map(([cat, tags]) => (
                    <div key={cat} className="tag-cat">
                      <div className="tag-cat-title">{cat}</div>
                      <div className="tag-chips">
                        {tags.slice(0, 30).map(([tag, count]) => {
                          const isOn = (tagFilters[cat] || []).includes(tag);
                          const col = tagColor(tag);
                          return (
                            <span key={tag} className="tag-chip" onClick={() => toggleTag(cat, tag)}
                              style={{ background: isOn ? col : "transparent", color: isOn ? "#fff" : col, borderColor: isOn ? col : col + "44" }}>
                              {tag} <span style={{ opacity: .6, fontSize: 9 }}>({count})</span>
                            </span>
                          );
                        })}
                      </div>
                    </div>
                  ))}
                </div>
              )}

                {/* Notifications panel */}
                {showNotifs && <div style={{ background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--r)", padding: 14, marginBottom: 12, maxHeight: 260, overflowY: "auto" }}>
                  <div style={{ display: "flex", alignItems: "center", marginBottom: 10 }}>
                    <span style={{ fontSize: 14, fontWeight: 600, color: "var(--t1)" }}>🔔 Nouveaux tomes</span>
                    <button className="ib" style={{ marginLeft: "auto" }} onClick={() => setShowNotifs(false)}>✕</button>
                  </div>
                  {notifications.length === 0 ? <div style={{ color: "var(--t3)", fontSize: 12 }}>Aucune nouveauté récente.</div> :
                    notifications.map((n, i) => (
                      <div key={i} style={{ display: "flex", alignItems: "center", gap: 8, padding: "6px 0", borderBottom: "1px solid var(--brd)", fontSize: 12 }}>
                        <span style={{ color: "var(--ac)" }}>📖</span>
                        <span style={{ color: "var(--t1)", fontWeight: 600 }}>{n.manga_title}</span>
                        <span style={{ color: "var(--t2)" }}>— {n.volume_display || n.filename}</span>
                      </div>
                    ))
                  }
                </div>}

                {/* Full-text search results */}
                {fullSearchResults && <div style={{ background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--r)", padding: 14, marginBottom: 12, maxHeight: 300, overflowY: "auto" }}>
                  <div style={{ display: "flex", alignItems: "center", marginBottom: 10 }}>
                    <span style={{ fontSize: 14, fontWeight: 600, color: "var(--t1)" }}>🔍 Recherche approfondie : {fullSearchResults.total} résultats</span>
                    <button className="ib" style={{ marginLeft: "auto" }} onClick={() => setFullSearchResults(null)}>✕</button>
                  </div>
                  {fullSearchResults.results?.map(r => (
                    <div key={r.id} onClick={() => { const m = groupedMangas.find(x => x.id === r.id); if (m) openDet(m); }} style={{ display: "flex", gap: 8, padding: "6px 0", borderBottom: "1px solid var(--brd)", cursor: "pointer" }}>
                      <img src={api.cbzFolderCoverUrl(r.cbz_folder)} alt="" loading="lazy" style={{ width: 32, height: 45, borderRadius: 4, objectFit: "cover", background: "var(--c2)" }} onError={e => { e.target.style.opacity = ".2"; }} />
                      <div>
                        <div style={{ fontSize: 12, fontWeight: 600, color: "var(--t1)" }}>{r.title}</div>
                        <div style={{ fontSize: 10, color: "var(--t3)" }}>Trouvé dans : {r.match_field}</div>
                        {r.synopsis_excerpt && <div style={{ fontSize: 10, color: "var(--t2)", marginTop: 2 }}>{r.synopsis_excerpt}…</div>}
                      </div>
                    </div>
                  ))}
                </div>}

                {viewMode === "coverflow" ? (
                  <CoverFlowView mangas={filtered} onSelect={openDet} />
                ) : viewMode === "shelf" ? (
                  /* ═══ MODE ÉTAGÈRE ═══ */
                  <div className="shelf-view">
                    {(() => {
                      const perShelf = 6;
                      const shelves = [];
                      for (let i = 0; i < filtered.length; i += perShelf) {
                        shelves.push(filtered.slice(i, i + perShelf));
                      }
                      return shelves.map((shelf, si) => (
                        <div key={si} className="shelf-row">
                          <div className="shelf-books">
                            {shelf.map(m => (
                              <div key={m.id} className="shelf-book" onClick={() => openDet(m)} title={m.title}>
                                <div className="shelf-spine" style={{ background: `hsl(${(m.title || '').charCodeAt(0) * 7 % 360}, 45%, 35%)` }}>
                                  <span className="shelf-spine-text">{m.title}</span>
                                </div>
                                <img src={api.cbzFolderCoverUrl(m.cbz_folder)} alt="" loading="lazy" className="shelf-cover" onError={e => { e.target.style.opacity = "0"; }} />
                              </div>
                            ))}
                          </div>
                          <div className="shelf-wood" />
                        </div>
                      ));
                    })()}
                  </div>
                ) : <>
                <div style={{ display: "flex", gap: 6 }}>
                <div style={{ display: "flex", flexDirection: "column", gap: 1, flexShrink: 0, position: "sticky", top: 0, alignSelf: "flex-start" }}>
                  <button onClick={() => setAlphaFilter(null)} style={{ padding: "3px 6px", fontSize: 9, fontWeight: !alphaFilter ? 700 : 400, background: !alphaFilter ? "var(--ac)" : "var(--c2)", color: !alphaFilter ? "#fff" : "var(--t3)", border: "1px solid var(--brd)", borderRadius: 3, cursor: "pointer" }}>All</button>
                  {alphaLetters.map(l => <button key={l} onClick={() => setAlphaFilter(l === alphaFilter ? null : l)} disabled={!groupedAlphaIndex[l]} style={{ padding: "2px 6px", fontSize: 9, fontWeight: l === alphaFilter ? 700 : 400, background: l === alphaFilter ? "var(--ac)" : "transparent", color: !groupedAlphaIndex[l] ? "var(--brd)" : l === alphaFilter ? "#fff" : "var(--t3)", border: "none", borderRadius: 2, cursor: groupedAlphaIndex[l] ? "pointer" : "default", fontFamily: "monospace", lineHeight: 1.4 }}>{l}</button>)}
                </div>
                <div className={`mg${viewMode === "compact" ? " vm-compact" : viewMode === "list" ? " vm-list" : ""}`} style={{ flex: 1 }}>
                  {filtered.length === 0 ? <div className="empty"><div className="ei">📚</div><p>Aucun manga.</p></div> :
                    filtered.map(m => {
                      const meta = m?.metadata_json || {};
                      const genres = (meta.Genres || "").split(/\s*[-,]\s*/).filter(Boolean).slice(0, 3);
                      return (
                      <div key={m.id} className="mc" onClick={() => openDet(m)}>
                        <div className="mc-match">{statusBadge(m.match_status)}</div>
                        <img
                          className="mc-cov"
                          src={api.cbzFolderCoverUrl(m.cbz_folder)}
                          alt=""
                          loading="lazy"
                          onError={e => {
                            const fb = m.cover_url ? nautiljonMiniUrl(m.cover_url) : '';
                            if (fb && e.target.dataset.fallbackTried !== '1') {
                              e.target.dataset.fallbackTried = '1';
                              e.target.src = fb;
                              return;
                            }
                            e.target.style.display = "none";
                            e.target.nextSibling.style.display = "flex";
                          }}
                        />
                        <div className="mc-ph" style={{ display: "none" }}>
                          <img src={api.cbzFolderCoverUrl(m.cbz_folder)} alt="" loading="lazy" style={{ width: "100%", height: "100%", objectFit: "cover", borderRadius: "var(--r) var(--r) 0 0" }} onError={e => { e.target.style.display = "none"; }} />
                        </div>
                        <div className="mc-info">
                          <div className="mc-tit">{m.title}</div>
                          <div style={{ display: 'flex', gap: 6, marginTop: 6, flexWrap: 'wrap' }} onClick={e => e.stopPropagation()}>
                            <button className={`btn btn-s${isInList(toReadItems, m.cbz_folder, '', 'manga') ? ' btn-p' : ''}`} style={{ fontSize: 9, padding: '2px 6px' }} onClick={() => toggleListItem({ listName: 'to_read', mangaUrl: m.cbz_folder, itemType: 'manga', title: m.title })}>🕒 À lire</button>
                          </div>
                          {sq.trim() && (() => { const mi = mangaSearchMatchInfo(m, sq); return mi.source === "tag" ? <div className="mc-hit">🏷️ {mi.tagKey}</div> : null; })()}
                          {viewMode === "list" && <>
                            <div className="mc-list-sub">{m.cbz_folder}</div>
                            {genres.length > 0 && <div className="mc-list-tags">
                              {genres.map((g, i) => <span key={i} className="genre-badge genre-badge-outline" style={{ color: tagColor(g), borderColor: tagColor(g) + "66", fontSize: 9, padding: "1px 6px" }}>{g}</span>)}
                            </div>}
                          </>}
                        </div>
                      </div>
                    );})}
                </div>
              </div>
              {/* Infinite scroll sentinel */}
              {hasMore && <div ref={loadMoreRef} style={{ display: 'flex', justifyContent: 'center', padding: 20 }}>
                {loadingMore ? <div className="loading"><div className="spinner" /> Chargement…</div> : <div style={{ height: 1 }} />}
              </div>}
            </>}</>}
          </>}

          {nav === "admin-users" && isAdmin && <>
            <div className="sec-h"><span className="sec-t">Utilisateurs</span><button className="btn btn-p btn-s" style={{ marginLeft: "auto" }} onClick={openCreateU}>+ Créer</button></div>
            <table className="adm-table"><thead><tr><th>Nom</th><th>Rôle</th><th>Actions</th></tr></thead><tbody>{users.map(u => <tr key={u.id}><td>{u.username}</td><td><span className={`role-badge ${u.role === "admin" ? "rb-admin" : "rb-user"}`}>{u.role}</span></td><td><div style={{ display: "flex", gap: 4 }}><button className="btn btn-s" onClick={() => openEditU(u)}>Modifier</button>{u.username !== session.username && <button className="btn btn-s btn-d" onClick={() => delUser(u)}>Suppr</button>}</div></td></tr>)}</tbody></table>
          </>}

          {nav === "admin-config" && isAdmin && <>
            <div className="sec-h"><span className="sec-t">Configuration</span></div>
            <div style={{ maxWidth: 480 }}>
              <div className="fld">
                <label>Base Nautiljon</label>
                <div className="hint" style={{ display: "flex", alignItems: "center", gap: 6 }}>
                  <span className={`dot ${cfg.nautiljon_db_available ? "d-on" : "d-off"}`} />
                  {cfg.nautiljon_db_available ? "Connectée" : "Introuvable"} — {cfg.nautiljon_db_path || "chemin non configuré"}
                </div>
              </div>
              <div className="fld"><label>Chemin CBZ</label><input value={cfg.cbz_path} onChange={e => setCfg(c => ({ ...c, cbz_path: e.target.value }))} /></div>

              <div style={{ marginTop: 16, padding: 14, background: "var(--c1)", borderRadius: "var(--r)", border: "1px solid var(--brd)" }}>
                <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 10, color: "var(--t1)" }}>🏷️ Mots-clés de détection</div>
                <div style={{ fontSize: 10, color: "var(--t3)", marginBottom: 10 }}>
                  Séparés par des virgules. Utilisés pour identifier les tomes et chapitres dans les noms de fichiers CBZ.<br/>
                  Exemple: un fichier "Ch.168" sera détecté comme chapitre si "Ch" est dans la liste.
                </div>
                <div className="fld">
                  <label>Mots-clés Tomes</label>
                  <input value={cfg.tome_keywords || ""} onChange={e => setCfg(c => ({ ...c, tome_keywords: e.target.value }))} placeholder="Tome,T,Vol,Volume" />
                  <div className="hint">Actuels : {(cfg.tome_keywords || "Tome,T,Vol,Volume").split(",").map((k, i) => <span key={i} style={{ display: "inline-block", padding: "1px 6px", margin: "2px 2px", background: "rgba(52,211,153,.15)", color: "var(--grn)", borderRadius: 8, fontSize: 10, fontWeight: 600 }}>{k.trim()}</span>)}</div>
                </div>
                <div className="fld">
                  <label>Mots-clés Chapitres</label>
                  <input value={cfg.chapter_keywords || ""} onChange={e => setCfg(c => ({ ...c, chapter_keywords: e.target.value }))} placeholder="Chapitre,Chapter,Ch,Ep,Episode" />
                  <div className="hint">Actuels : {(cfg.chapter_keywords || "Chapitre,Chapter,Ch,Ep,Episode").split(",").map((k, i) => <span key={i} style={{ display: "inline-block", padding: "1px 6px", margin: "2px 2px", background: "rgba(251,191,36,.15)", color: "var(--amb)", borderRadius: 8, fontSize: 10, fontWeight: 600 }}>{k.trim()}</span>)}</div>
                </div>
                <div className="fld">
                  <label>Mots-clés One-shots</label>
                  <input value={cfg.oneshot_keywords || ""} onChange={e => setCfg(c => ({ ...c, oneshot_keywords: e.target.value }))} placeholder="OS,One Shot,One-Shot,Oneshot" />
                  <div className="hint">Actuels : {(cfg.oneshot_keywords || "OS,One Shot,One-Shot,Oneshot").split(",").map((k, i) => <span key={i} style={{ display: "inline-block", padding: "1px 6px", margin: "2px 2px", background: "rgba(251,113,133,.15)", color: "var(--ros)", borderRadius: 8, fontSize: 10, fontWeight: 600 }}>{k.trim()}</span>)}</div>
                  <div className="hint" style={{ marginTop: 2 }}>⚡ "OS" doit être en MAJUSCULES dans le nom du fichier. Les autres sont insensibles à la casse.</div>
                </div>
                <div className="fld">
                  <label>Mots-clés One-Shot</label>
                  <input value={cfg.oneshot_keywords || ""} onChange={e => setCfg(c => ({ ...c, oneshot_keywords: e.target.value }))} placeholder="OS,One Shot,One-Shot,Oneshot" />
                  <div className="hint">Actuels : {(cfg.oneshot_keywords || "OS,One Shot,One-Shot,Oneshot").split(",").map((k, i) => <span key={i} style={{ display: "inline-block", padding: "1px 6px", margin: "2px 2px", background: "rgba(251,113,133,.15)", color: "var(--ros)", borderRadius: 8, fontSize: 10, fontWeight: 600 }}>{k.trim()}</span>)}</div>
                  <div className="hint" style={{ marginTop: 2 }}>⚡ "OS" est sensible à la casse (majuscules uniquement). Les autres sont insensibles.</div>
                </div>
                <div style={{ fontSize: 9, color: "var(--t3)", marginTop: 4 }}>⚠️ Après modification, relancez un scan pour que les changements prennent effet.</div>
              </div>

              <button className="btn btn-p" style={{ marginTop: 16 }} onClick={saveCfg}>Sauvegarder</button>
            </div>
          </>}


          {nav === "admin-cbz-covers" && isAdmin && <AdminCbzCoverManager allMangas={allMangas} show={show} onRefresh={loadAll} />}

          {nav === "admin-duplicates" && isAdmin && <DuplicatesManager show={show} onRefresh={() => loadAll(activeLibId)} />}

          {nav === "admin-libraries" && isAdmin && <AdminLibraryManager show={show} users={users} loadUsers={loadUsers} />}

          {nav === "admin-themes" && isAdmin && <ThemeCreator themes={themes} currentThemeId={currentThemeId} applyTheme={applyTheme} setCurrentThemeId={setCurrentThemeId} setThemes={setThemes} show={show} />}

          {nav === "admin-match" && isAdmin && <>
            <div className="sec-h"><span className="sec-t">Matching & Bibliothèque</span></div>
            <div style={{ display: "flex", gap: 8, marginBottom: 14, flexWrap: "wrap" }}>
              <button className="btn btn-p" onClick={async () => { show("Scan…"); try { const r = await api.scanFolders(); show(`✅ ${r.added} nouveaux dossiers`); loadAll(activeLibId); } catch (e) { show(`❌ ${e.message}`); } }}>📁 Scanner dossiers</button>
              <button className="btn" onClick={async () => { show("Re-parse types…"); try { const r = await api.rescanTypes(); show(`✅ ${r.updated} volumes mis à jour`); loadAll(activeLibId); } catch (e) { show(`❌ ${e.message}`); } }} title="Re-détecte Tome/Chapitre/One-Shot sans re-scanner les fichiers">🏷️ Re-parser types</button>
              <button className="btn btn-p" onClick={runAutoMatch} disabled={amRun}>{amRun ? "En cours…" : "🔄 Matching auto"}</button>
              <button className="btn btn-g" onClick={async () => { show("Covers…"); try { const r = await api.generateCovers(); show(`✅ ${r.generated} covers`); } catch (e) { show(`❌ ${e.message}`); } }}>🖼️ Covers</button>
            </div>
            {amLog.length > 0 && <div style={{ background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--r)", padding: 12, maxHeight: 200, overflowY: "auto", fontFamily: "monospace", fontSize: 11, color: "var(--t2)", marginBottom: 14 }}>{amLog.map((l, i) => <div key={i}>{l}</div>)}</div>}

            {/* Mangas non matchés */}
            {(() => {
              const unmatchedMangas = allMangas.filter(m => m.match_status === "unmatched" || m.match_status === "pending");
              const matchedMangas = allMangas.filter(m => m.match_status === "matched" || m.match_status === "manual");
              return <>
                {unmatchedMangas.length > 0 && <>
                  <h3 style={{ fontSize: 14, color: "var(--t1)", marginBottom: 8 }}>❓ À associer ({unmatchedMangas.length})</h3>
                  {unmatchedMangas.map(m => <UnmatchedCard key={m.id} manga={m} show={show} onDone={loadAll} />)}
                </>}
                {unmatchedMangas.length === 0 && <div className="empty" style={{ padding: 20 }}><p>✅ Tous les mangas sont associés !</p></div>}
                
                {matchedMangas.length > 0 && <>
                  <h3 style={{ fontSize: 14, color: "var(--t1)", marginTop: 16, marginBottom: 8 }}>✅ Associés ({matchedMangas.length})</h3>
                  <div style={{ maxHeight: 300, overflowY: "auto" }}>
                    {matchedMangas.map(m => (
                      <div key={m.id} style={{ padding: "4px 8px", background: "var(--c1)", borderRadius: 4, marginBottom: 2, fontSize: 11, display: "flex", alignItems: "center", gap: 6 }}>
                        <span style={{ flex: 1, color: "var(--t2)" }}>📁 {m.cbz_folder} → {m.title}</span>
                        <button className="btn btn-s" style={{ fontSize: 9, padding: "1px 4px" }} onClick={async () => { try { await api.resetMatch(m.id); show("Reset"); loadAll(activeLibId); } catch (e) { show(e.message); } }}>↩️</button>
                      </div>
                    ))}
                  </div>
                </>}
              </>;
            })()}
          </>}
        </div>
      </div>

      {/* DETAIL */}
      {sel && !rdr && (
        <div className="dp-ov" onClick={e => { if (e.target === e.currentTarget) closeDet(); }}>
          <div className="dp">
            <div className="dp-hero">
              <div className="dp-hero-bg" style={{ backgroundImage: (det?.cover_url || sel.cover_url) ? `url(${nautiljonMiniUrl(det?.cover_url || sel.cover_url)})` : "linear-gradient(135deg,#121428,#261840)" }} />
              <button className="dp-cls" onClick={closeDet}>✕</button>
              <div className="dp-hero-c">
                {(det?.cover_url || sel.cover_url) ? <img className="dp-cov" src={nautiljonMiniUrl(det?.cover_url || sel.cover_url)} alt="" /> : <div className="dp-cov-ph"><img src={api.cbzFolderCoverUrl(sel.cbz_folder)} alt="" style={{ width: "100%", height: "100%", objectFit: "cover", borderRadius: 8 }} onError={e => { e.target.parentElement.textContent = "📖"; }} /></div>}
                <div className="dp-hi">
                  <h1>{det?.title || sel.title}</h1>
                  {det?.metadata_json?.["Titre original"] && <div className="sub">{det.metadata_json["Titre original"]}</div>}
                  <div className="dp-tags">
                    {det?.metadata_json?.Type && <span className="dp-tag genre-badge genre-badge-filled" style={{ background: "var(--ac)" }}>{det.metadata_json.Type}</span>}
                    {(det?.metadata_json?.Genres || "").split(/\s*[-,]\s*/).filter(Boolean).slice(0, 5).map((g, i) => <span key={i} className="dp-tag genre-badge genre-badge-outline" style={{ color: tagColor(g), borderColor: tagColor(g) + "88", cursor: "pointer" }} onClick={() => { closeDet(); setSq(g); }}>{g}</span>)}
                  </div>
                  {det?.nautiljon_url && <a className="nlink" href={det.nautiljon_url.startsWith("http") ? det.nautiljon_url : `https://www.nautiljon.com${det.nautiljon_url}`} target="_blank" rel="noreferrer">🌐 Nautiljon</a>}
                  {sel?.grouped_variants?.length > 1 && <div style={{ display: "flex", gap: 6, marginTop: 8, flexWrap: "wrap" }}>{sel.grouped_variants.map((v, i) => <span key={v.cbz_folder || i} className="genre-badge genre-badge-outline" style={{ fontSize: 10, color: "var(--t2)", borderColor: "var(--brd)" }}>{v.__edition_label || "Édition standard"}</span>)}</div>}
                  <div style={{ display: 'flex', gap: 8, marginTop: 8, flexWrap: 'wrap' }}>
                    <button className={`btn btn-s${isInList(toReadItems, sel.cbz_folder, '', 'manga') ? ' btn-p' : ''}`} onClick={() => toggleListItem({ listName: 'to_read', mangaUrl: sel.cbz_folder, itemType: 'manga', title: det?.title || sel.title })}>🕒 {isInList(toReadItems, sel.cbz_folder, '', 'manga') ? 'Retirer de À lire' : 'Ajouter à À lire'}</button>
                  </div>
                  {/* Rating */}
                  <div style={{ display: 'flex', alignItems: 'center', gap: 4, marginTop: 6 }}>
                    <span style={{ fontSize: 10, color: 'var(--t3)' }}>Note :</span>
                    {[1,2,3,4,5].map(s => (
                      <span key={s} style={{ cursor: 'pointer', fontSize: 18, filter: s <= (userRatings[sel.id] || 0) ? 'none' : 'grayscale(1) opacity(.3)' }}
                        onClick={async () => { try { if (userRatings[sel.id] === s) { await api.deleteRating(sel.id); setUserRatings(r => { const c = {...r}; delete c[sel.id]; return c; }); } else { await api.setRating(sel.id, s); setUserRatings(r => ({...r, [sel.id]: s})); } } catch {} }}>⭐</span>
                    ))}
                  </div>
                  {isAdmin && det?.match_status === "matched" && <button className="btn btn-s" style={{ fontSize: 9, marginTop: 4 }} onClick={async () => { try { await api.resetMatch(sel.id); show("Match réinitialisé"); closeDet(); loadAll(activeLibId); } catch (e) { show(e.message); } }}>↩️ Changer l'association</button>}
                </div>
              </div>
            </div>
            <div className="dp-body">
              {detL ? <div className="loading"><div className="spinner" /></div> : <>
                <div className="dp-tabs">
                  <button className={`dtab ${dtab === "info" ? "on" : ""}`} onClick={() => setDtab("info")}>Infos</button>
                  <button className={`dtab ${dtab === "tomes" ? "on" : ""}`} onClick={() => setDtab("tomes")}>Tomes{tomes.length > 0 ? ` (${tomes.length})` : ""}</button>
                  <button className={`dtab ${dtab === "editions" ? "on" : ""}`} onClick={() => setDtab("editions")}>Éditions</button>
                </div>

                {dtab === "info" && <>
                  {det?.synopsis && <div className="dp-sec"><h3>Synopsis</h3><p className="syn">{det.synopsis}</p></div>}
                  {det?.metadata_json && typeof det.metadata_json === "object" && Object.keys(det.metadata_json).length > 0 ? (
                    <div className="dp-sec"><h3>Métadonnées</h3><div className="mg2">
                      {Object.entries(det.metadata_json).map(([k, v]) => {
                        const isTag = ["Type", "Types", "Genres", "Thème", "Thèmes", "Auteur", "Scénariste", "Dessinateur"].includes(k);
                        const tags = isTag ? String(v).split(/\s*[-,]\s*/).filter(Boolean) : [];
                        return <div key={k} className="mi"><div className="l">{k}</div><div className="v">{isTag && tags.length ? <div style={{ display: "flex", flexWrap: "wrap", gap: 3 }}>{tags.map((t, i) => <span key={i} className="genre-badge genre-badge-outline" style={{ color: tagColor(t), borderColor: tagColor(t) + "55", cursor: "pointer", fontSize: 10 }} onClick={() => { closeDet(); setSq(t); }}>{t}</span>)}</div> : String(v)}</div></div>;
                      })}
                    </div></div>
                  ) : <div className="empty" style={{ padding: 20 }}><p>Pas encore de métadonnées.{isAdmin ? " Lancez le matching auto." : ""}</p></div>}
                </>}

                {dtab === "tomes" && <>
                  {tomesL ? <div className="loading"><div className="spinner" /></div> : tomes.length === 0 ? <div className="empty" style={{ padding: 20 }}><p>Aucun CBZ</p></div> : (() => {
                    const editionVariants = sel?.grouped_variants?.length ? sel.grouped_variants : [{ cbz_folder: sel?.cbz_folder, __edition_label: '', __edition_cbz_folders: [sel?.cbz_folder] }];
                    const hasMultiEditions = editionVariants.length > 1;
                    // Filter by normalized edition label
                    const editionFiltered = activeEditionLabel != null
                      ? tomes.filter(t => normalizeEditionLabel(t.__edition_label || '') === activeEditionLabel)
                      : tomes;
                    const hasTomes = editionFiltered.some(t => t.volume_type === "tome");
                    const hasChapters = editionFiltered.some(t => t.volume_type === "chapter");
                    const hasOneshots = editionFiltered.some(t => t.volume_type === "oneshot");
                    const typeCount = [hasTomes, hasChapters, hasOneshots].filter(Boolean).length;
                    const shown = volFilter ? editionFiltered.filter(t => t.volume_type === volFilter) : editionFiltered;

                    // Render one section of volumes
                    const renderVolumeGrid = (volumeList) => (
                      <div className="vg">{volumeList.map((t, i) => (
                        <div key={`${t.__edition_folder || ''}::${t.path || i}`} className="vc" onClick={() => openCbzVol({ ...sel, cbz_folder: t.cbz_folder || sel.cbz_folder }, t)} title={t.name}>
                          <img
                            className="vcov"
                            src={String(t?.source || '').toLowerCase() === 'images' || String(t?.path || '').startsWith('imgvol:')
                              ? api.imgVolPageUrl(t.cbz_folder || sel.cbz_folder, t.volume || 0, 0)
                              : api.cbzThumbnailUrl(t.path)}
                            alt="" loading="lazy"
                            onError={e => { e.target.style.display = "none"; }}
                          />
                          <div className="vn">{t.volume_display || (t.volume ? `Tome ${t.volume}` : "Sans n°")}</div>
                          {!!t.__edition_label && <div style={{ fontSize: 9, color: 'var(--t3)' }}>{t.__edition_label}</div>}
                          <div style={{ display: 'flex', gap: 4, marginTop: 4, flexWrap: 'wrap' }} onClick={e => e.stopPropagation()}>
                            <button className={`btn btn-s${isInList(readItems, t.cbz_folder || sel.cbz_folder, t.path, t.volume_type) ? ' btn-p' : ''}`} style={{ fontSize: 8, padding: '1px 4px' }} onClick={() => toggleListItem({ listName: 'read', mangaUrl: t.cbz_folder || sel.cbz_folder, volumeId: t.path, itemType: t.volume_type, title: `${sel.title}${t.__edition_label ? ` — ${t.__edition_label}` : ''} — ${t.volume_display || t.name}` })}>✅ Lu</button>
                            <button className={`btn btn-s${isInList(toReadItems, t.cbz_folder || sel.cbz_folder, t.path, t.volume_type) ? ' btn-p' : ''}`} style={{ fontSize: 8, padding: '1px 4px' }} onClick={() => toggleListItem({ listName: 'to_read', mangaUrl: t.cbz_folder || sel.cbz_folder, volumeId: t.path, itemType: t.volume_type, title: `${sel.title}${t.__edition_label ? ` — ${t.__edition_label}` : ''} — ${t.volume_display || t.name}` })}>🕒 À lire</button>
                            {perms.canDownload && !(String(t?.source || '').toLowerCase() === 'images' || String(t?.path || '').startsWith('imgvol:')) && (
                              <a href={api.cbzDownloadUrl(t.path)} className="btn btn-s" style={{ fontSize: 8, padding: "1px 4px" }} download onClick={e => e.stopPropagation()}>⬇</a>
                            )}
                          </div>
                        </div>
                      ))}</div>
                    );

                    return <>
                      {/* Edition filter buttons */}
                      {hasMultiEditions && (
                        <div style={{ display: "flex", gap: 4, marginBottom: 8, flexWrap: "wrap" }}>
                          <button className={`btn btn-s${activeEditionLabel == null ? " btn-p" : ""}`} style={{ fontSize: 10 }} onClick={() => setActiveEditionLabel(null)}>Tout ({tomes.length})</button>
                          {editionVariants.map((v, i) => {
                            const normLabel = normalizeEditionLabel(v.__edition_label);
                            const count = tomes.filter(t => normalizeEditionLabel(t.__edition_label || '') === normLabel).length;
                            return <button key={normLabel || i} className={`btn btn-s${activeEditionLabel === normLabel ? " btn-p" : ""}`} style={{ fontSize: 10 }} onClick={() => setActiveEditionLabel(normLabel)}>{v.__edition_label || "Édition standard"} ({count})</button>;
                          })}
                        </div>
                      )}
                      {/* Type filter */}
                      {typeCount >= 2 && (
                        <div style={{ display: "flex", gap: 4, marginBottom: 8, flexWrap: "wrap" }}>
                          <button className={`btn btn-s${!volFilter ? " btn-p" : ""}`} style={{ fontSize: 10 }} onClick={() => setVolFilter(null)}>Tout ({editionFiltered.length})</button>
                          {hasOneshots && <button className={`btn btn-s${volFilter === "oneshot" ? " btn-p" : ""}`} style={{ fontSize: 10 }} onClick={() => setVolFilter("oneshot")}>One-Shot ({editionFiltered.filter(t => t.volume_type === "oneshot").length})</button>}
                          {hasTomes && <button className={`btn btn-s${volFilter === "tome" ? " btn-p" : ""}`} style={{ fontSize: 10 }} onClick={() => setVolFilter("tome")}>Tomes ({editionFiltered.filter(t => t.volume_type === "tome").length})</button>}
                          {hasChapters && <button className={`btn btn-s${volFilter === "chapter" ? " btn-p" : ""}`} style={{ fontSize: 10 }} onClick={() => setVolFilter("chapter")}>Chapitres ({editionFiltered.filter(t => t.volume_type === "chapter").length})</button>}
                        </div>
                      )}
                      {/* Volumes — grouped by edition when "Tout" is selected and multiple editions */}
                      {activeEditionLabel == null && hasMultiEditions ? (
                        editionVariants.map((v, vi) => {
                          const normLabel = normalizeEditionLabel(v.__edition_label);
                          let edVols = shown.filter(t => normalizeEditionLabel(t.__edition_label || '') === normLabel);
                          if (!edVols.length) return null;
                          return (
                            <div key={v.cbz_folder || vi} style={{ marginBottom: 16 }}>
                              <div style={{ fontSize: 13, fontWeight: 700, color: "var(--t1)", marginBottom: 6, padding: "4px 8px", background: "var(--c2)", borderRadius: 6, borderLeft: "3px solid var(--ac)" }}>
                                {v.__edition_label || "Édition standard"} <span style={{ color: "var(--t3)", fontWeight: 400 }}>({edVols.length})</span>
                              </div>
                              {renderVolumeGrid(edVols)}
                            </div>
                          );
                        })
                      ) : (
                        renderVolumeGrid(shown)
                      )}
                    </>;
                  })()}
                </>}

                {dtab === "editions" && <>
                  {det?.editions_json?.length > 0 ? det.editions_json.map((ed, idx) => (
                    <div key={ed.id || idx} className="edc">
                      <div className="edh" onClick={() => setExpEd(p => ({ ...p, [idx]: !p[idx] }))}><div className="edn">📖 {ed.name || "?"} ({ed.volumes?.length || 0})</div><span style={{ transform: expEd[idx] ? "rotate(90deg)" : "none", transition: "transform .15s", color: "var(--t3)" }}>▸</span></div>
                      {expEd[idx] && ed.volumes?.length > 0 && <div className="vg">{ed.volumes.map((vol, vi) => {
                        const matchedTome = tomes.find(t => t.volume === vol.number);
                        return (
                          <div key={vol.volume_id || vi} className="vc" style={{ cursor: "default" }}>
                            {vol.cover_mini ? <img className="vcov" src={nautiljonMiniUrl(vol.cover_mini)} alt="" loading="lazy" /> : <div className="vcph">V{vol.number}</div>}
                            <div className="vn">{vol.is_available === false ? "⏳ " : ""}Vol. {vol.number}</div>
                            {isAdmin && matchedTome && (vol.cover_full || vol.cover_mini) && <button className="btn btn-s" style={{ marginTop: 2, fontSize: 8, padding: "1px 4px" }} onClick={async () => { show("Remplacement…"); try { await api.replaceCbzCover(matchedTome.path, nautiljonMiniUrl(vol.cover_full || vol.cover_mini)); show("✅ Cover remplacée"); loadTomes(sel.cbz_folder); } catch (e) { show(`❌ ${e.message}`); } }}>🖼️ Utiliser</button>}
                          </div>
                        );
                      })}</div>}
                    </div>
                  )) : <div className="empty" style={{ padding: 20 }}><p>Pas d'éditions.{det?.match_status !== "matched" ? " Associez d'abord ce manga." : ""}</p></div>}
                </>}
              </>}
            </div>
          </div>
        </div>
      )}

      {/* READER */}
      {rdr && <div className="rdr" onTouchStart={handleTouchStart} onTouchEnd={handleTouchEnd}>
        {/* Top bar - slides in/out */}
        <div style={{
          position: 'absolute', top: 0, left: 0, right: 0, zIndex: 20,
          transform: rBarVisible ? 'translateY(0)' : 'translateY(-100%)',
          transition: 'transform .25s ease'
        }}>
          <div className="rdr-bar" style={{ background: 'rgba(0,0,0,.85)', backdropFilter: 'blur(8px)' }}>
            <button className="ib" onClick={closeReader}>✕</button>
            <div className="tit">{rTitle}</div>
            <span className="pg">{rP + 1}{rMode === 'double' && rP + 1 < rPg.length ? `-${rP + 2}` : ''}/{rPg.length}</span>
            <button className="ib" title="Mode webtoon" onClick={() => setRMode(m => m === 'webtoon' ? 'paged' : 'webtoon')} style={{ color: rMode === 'webtoon' ? 'var(--ac)' : undefined }}>{rMode === 'webtoon' ? '📄' : '📜'}</button>
            <button className="ib" title="Double page" onClick={() => setRMode(m => m === 'double' ? 'paged' : 'double')} style={{ color: rMode === 'double' ? 'var(--ac)' : undefined }}>📖</button>
            <button className="ib" title={rRTL ? "Lecture ← (manga)" : "Lecture → (occidental)"} onClick={() => setRRTL(r => !r)}>{rRTL ? '←' : '→'}</button>
            <button className="ib" onClick={() => setRZoom(z => Math.max(z - .2, .4))}>−</button>
            <span style={{ fontSize: 10, color: "#aaa" }}>{Math.round(rZoom * 100)}%</span>
            <button className="ib" onClick={() => setRZoom(z => Math.min(z + .2, 3))}>+</button>
            <button className="ib" title={rBookmarks.includes(rP) ? "Retirer marque-page" : "Ajouter marque-page (B)"} onClick={() => toggleBookmark(rP)} style={{ color: rBookmarks.includes(rP) ? '#f59e0b' : undefined }}>🔖</button>
            <button className="ib" title="Miniatures" onClick={() => setRShowThumbs(v => !v)} style={{ color: rShowThumbs ? 'var(--ac)' : undefined }}>🖼️</button>
            {perms.canDownload && rCbz && <a href={api.cbzDownloadUrl(rCbz.filepath)} className="btn btn-s btn-g" download onClick={e => e.stopPropagation()}>⬇</a>}
          </div>
        </div>

        {rMode === 'webtoon' ? (
          <div className="rdr-wt" ref={rScrollRef} onClick={handleReaderClick}>
            {rPg.map((u, i) => (
              <img
                key={u}
                ref={el => { rImgRefs.current[i] = el; }}
                src={u}
                alt=""
                draggable={false}
                loading={i < 3 ? 'eager' : 'lazy'}
                style={{
                  width: '100%',
                  maxWidth: '100%',
                  display: 'block',
                  margin: 0,
                  padding: 0,
                  transform: rZoom !== 1 ? `scale(${rZoom})` : undefined,
                  transformOrigin: 'top center'
                }}
              />
            ))}
          </div>
        ) : rMode === 'double' ? (
          <div className="rdr-cv" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 2 }} onClick={handleReaderClick}>
            {rRTL ? (
              <>
                {rPg[rP + 1] && <img src={rPg[rP + 1]} alt="" style={{ maxHeight: '100vh', maxWidth: '49vw', objectFit: 'contain', transform: rZoom !== 1 ? `scale(${rZoom})` : undefined }} draggable={false} />}
                {rPg[rP] && <img src={rPg[rP]} alt="" style={{ maxHeight: '100vh', maxWidth: '49vw', objectFit: 'contain', transform: rZoom !== 1 ? `scale(${rZoom})` : undefined }} draggable={false} />}
              </>
            ) : (
              <>
                {rPg[rP] && <img src={rPg[rP]} alt="" style={{ maxHeight: '100vh', maxWidth: '49vw', objectFit: 'contain', transform: rZoom !== 1 ? `scale(${rZoom})` : undefined }} draggable={false} />}
                {rPg[rP + 1] && <img src={rPg[rP + 1]} alt="" style={{ maxHeight: '100vh', maxWidth: '49vw', objectFit: 'contain', transform: rZoom !== 1 ? `scale(${rZoom})` : undefined }} draggable={false} />}
              </>
            )}
          </div>
        ) : (
          <div className="rdr-cv" onClick={handleReaderClick}>
            {rPg[rP] && <img src={rPg[rP]} alt="" style={{ transform: `scale(${rZoom})` }} draggable={false} />}
          </div>
        )}

        {/* Bookmark indicator */}
        {rBookmarks.includes(rP) && (
          <div style={{ position: 'absolute', top: 60, right: 16, zIndex: 15, color: '#f59e0b', fontSize: 24, textShadow: '0 2px 8px rgba(0,0,0,.6)', pointerEvents: 'none' }}>🔖</div>
        )}

        {/* Thumbnails strip */}
        {rShowThumbs && rBarVisible && (
          <div style={{
            position: 'absolute', bottom: 44, left: 0, right: 0, zIndex: 20,
            background: 'rgba(0,0,0,.9)', backdropFilter: 'blur(8px)',
            display: 'flex', gap: 4, padding: '8px 12px', overflowX: 'auto',
          }}>
            {rPg.map((u, i) => (
              <div key={i} onClick={() => rdrGo(i)} style={{
                position: 'relative', cursor: 'pointer', flexShrink: 0,
                border: i === rP ? '2px solid var(--ac)' : rBookmarks.includes(i) ? '2px solid #f59e0b' : '1px solid #444',
                borderRadius: 4, overflow: 'hidden',
              }}>
                <img src={u} alt="" loading="lazy" style={{ width: 48, height: 68, objectFit: 'cover', display: 'block' }} />
                <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, background: 'rgba(0,0,0,.7)', fontSize: 8, color: '#ccc', textAlign: 'center', padding: '1px 0' }}>{i + 1}</div>
                {rBookmarks.includes(i) && <div style={{ position: 'absolute', top: 1, right: 1, fontSize: 10 }}>🔖</div>}
              </div>
            ))}
          </div>
        )}

        {/* Bookmarks quick-nav */}
        {rBookmarks.length > 0 && rBarVisible && !rShowThumbs && (
          <div style={{
            position: 'absolute', bottom: 44, right: 12, zIndex: 20,
            background: 'rgba(0,0,0,.85)', borderRadius: 8, padding: '6px 10px',
            display: 'flex', gap: 4, alignItems: 'center',
          }}>
            <span style={{ fontSize: 10, color: '#f59e0b', marginRight: 4 }}>🔖</span>
            {rBookmarks.map(pg => (
              <button key={pg} className="ib" style={{ fontSize: 10, color: pg === rP ? 'var(--ac)' : '#ccc', fontWeight: pg === rP ? 700 : 400 }} onClick={() => rdrGo(pg)}>p{pg + 1}</button>
            ))}
          </div>
        )}

        {/* Next volume prompt */}
        {rShowNextPrompt && rNextVol && (
          <div style={{
            position: 'absolute', inset: 0, zIndex: 30,
            background: 'rgba(0,0,0,.8)', backdropFilter: 'blur(8px)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <div style={{ background: '#1a1a2e', borderRadius: 16, padding: 32, maxWidth: 360, textAlign: 'center', border: '1px solid #333' }}>
              <div style={{ fontSize: 48, marginBottom: 12 }}>📖</div>
              <div style={{ color: '#fff', fontSize: 16, fontWeight: 700, marginBottom: 4 }}>Fin du volume</div>
              <div style={{ color: '#aaa', fontSize: 13, marginBottom: 20 }}>Lire le suivant ?</div>
              <div style={{ color: 'var(--ac)', fontSize: 15, fontWeight: 600, marginBottom: 20 }}>
                {rNextVol.tome.volume_display || rNextVol.tome.display || `Tome ${rNextVol.tome.volume || '?'}`}
              </div>
              <div style={{ display: 'flex', gap: 10, justifyContent: 'center' }}>
                <button className="btn" style={{ padding: '8px 20px' }} onClick={() => { setRShowNextPrompt(false); closeReader(); }}>Fermer</button>
                <button className="btn btn-p" style={{ padding: '8px 20px' }} onClick={openNextVolume}>▶ Lire</button>
              </div>
            </div>
          </div>
        )}

        {/* Bottom bar */}
        <div style={{
          position: 'absolute', bottom: 0, left: 0, right: 0, zIndex: 20,
          transform: rBarVisible ? 'translateY(0)' : 'translateY(100%)',
          transition: 'transform .25s ease'
        }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '8px 14px', background: 'rgba(0,0,0,.85)', backdropFilter: 'blur(8px)', gap: 12, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 11, color: '#aaa', fontFamily: "'JetBrains Mono', monospace" }}>Page {rP + 1}{rMode === 'double' && rP + 1 < rPg.length ? `-${rP + 2}` : ''} / {rPg.length}</span>
            <div style={{ flex: 1, height: 3, background: '#333', borderRadius: 2, minWidth: 80 }}>
              <div style={{ height: '100%', background: 'var(--ac)', borderRadius: 2, width: `${((rP + 1) / Math.max(rPg.length,1)) * 100}%`, transition: 'width .15s' }} />
            </div>
            {rNextVol && <span style={{ fontSize: 9, color: 'var(--ac)', opacity: .7 }}>Suivant : {rNextVol.tome.volume_display || rNextVol.tome.display || `T${rNextVol.tome.volume}`}</span>}
          </div>
        </div>
      </div>}

      {/* MODALS */}
      {showUM && <div className="modal-ov" onClick={e => { if (e.target === e.currentTarget) setShowUM(false); }}><div className="modal">
        <h2>{editU ? `Modifier ${editU.username}` : "Créer"}</h2>
        <div className="fld"><label>Nom</label><input value={uf.name} onChange={e => setUf(f => ({ ...f, name: e.target.value }))} /></div>
        <div className="fld"><label>MDP</label><input type="password" value={uf.pass} onChange={e => setUf(f => ({ ...f, pass: e.target.value }))} /></div>
        <div className="fld"><label>Rôle</label><select value={uf.role} onChange={e => setUf(f => ({ ...f, role: e.target.value }))}><option value="user">User</option><option value="admin">Admin</option></select></div>
        {[{ k: "readOnly", l: "Lecture seule" }, { k: "canDownload", l: "Téléchargement" }, { k: "canChangePassword", l: "Changer MDP" }].map(p => <div key={p.k} className="toggle-row"><div className="tl">{p.l}</div><button className={`toggle ${uf[p.k] ? "on" : ""}`} onClick={() => setUf(f => ({ ...f, [p.k]: !f[p.k] }))} /></div>)}
        <div className="card-err">{ue}</div><div className="modal-ft"><button className="btn" onClick={() => setShowUM(false)}>Annuler</button><button className="btn btn-p" onClick={saveUser}>OK</button></div>
      </div></div>}

      {showP && <div className="modal-ov" onClick={e => { if (e.target === e.currentTarget) setShowP(false); }}><div className="modal">
        <h2>👤 {session.username}</h2>
        {themes.length > 0 && <div className="fld" style={{ marginBottom: 16 }}>
          <label>Thème</label>
          <select value={currentThemeId} onChange={async e => {
            const id = e.target.value;
            const t = themes.find(x => x.id === id);
            if (t) { applyTheme(t.colors); setCurrentThemeId(id); try { await api.setUserTheme(id); } catch {} }
          }}>
            {themes.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
        </div>}
        <button className="btn btn-s" style={{ marginBottom: 12 }} onClick={() => { setShowP(false); setShowKeyConfig(true); }}>⌨️ Raccourcis clavier</button>
        {perms.canChangePassword && <><div className="fld"><label>Ancien</label><input type="password" value={pf.old} onChange={e => setPf(f => ({ ...f, old: e.target.value }))} /></div><div className="fld"><label>Nouveau</label><input type="password" value={pf.n1} onChange={e => setPf(f => ({ ...f, n1: e.target.value }))} /></div><div className="fld"><label>Confirmer</label><input type="password" value={pf.n2} onChange={e => setPf(f => ({ ...f, n2: e.target.value }))} /></div><div className="card-err">{pe}</div><button className="btn btn-p btn-s" onClick={changePw}>Changer</button></>}
        <div className="modal-ft"><button className="btn btn-d" onClick={() => { setShowP(false); doLogout(); }}>🚪 Déconnexion</button><button className="btn" onClick={() => setShowP(false)}>Fermer</button></div>
      </div></div>}

      {/* Keyboard Config Modal */}
      {showKeyConfig && <KeyboardConfigModal keyConfig={keyConfig} onSave={(cfg) => { setKeyConfig(cfg); localStorage.setItem("tamashelf_keys", JSON.stringify(cfg)); setShowKeyConfig(false); show("Raccourcis sauvegardés"); }} onClose={() => setShowKeyConfig(false)} />}

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}



function ThemeCreator({ themes, currentThemeId, applyTheme, setCurrentThemeId, setThemes, show }) {
  const THEME_FIELDS = [
    { key: "d",   label: "Fond profond" },
    { key: "bg",  label: "Fond principal" },
    { key: "c1",  label: "Carte niveau 1" },
    { key: "c2",  label: "Carte niveau 2" },
    { key: "c3",  label: "Carte niveau 3" },
    { key: "inp", label: "Fond input" },
    { key: "brd", label: "Bordure" },
    { key: "brf", label: "Bordure focus" },
    { key: "t1",  label: "Texte principal" },
    { key: "t2",  label: "Texte secondaire" },
    { key: "t3",  label: "Texte discret" },
    { key: "ac",  label: "Accent" },
    { key: "acl", label: "Accent clair" },
    { key: "grn", label: "Succès" },
    { key: "amb", label: "Avertissement" },
    { key: "ros", label: "Erreur/Danger" },
    { key: "cyn", label: "Info" },
  ];

  const defaultColors = (t) => t?.colors || Object.fromEntries(THEME_FIELDS.map(f => [f.key, "#888888"]));

  const [editMode, setEditMode] = useState("select");
  const [editId, setEditId] = useState("");
  const [editName, setEditName] = useState("");
  const [editColors, setEditColors] = useState({});
  const [saving, setSaving] = useState(false);

  const startNew = () => {
    setEditMode("new");
    setEditId("");
    setEditName("");
    setEditColors(defaultColors(themes.find(t => t.id === currentThemeId)));
  };

  const startEdit = (themeId) => {
    const t = themes.find(x => x.id === themeId);
    if (!t || t.builtin) { show("Impossible de modifier un thème intégré"); return; }
    setEditMode("edit");
    setEditId(t.id);
    setEditName(t.name);
    setEditColors({ ...t.colors });
  };

  const previewColors = (colors) => applyTheme(colors);

  const save = async () => {
    if (!editName.trim()) { show("Nom requis"); return; }
    const id = editMode === "new"
      ? (editId.trim() || editName.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, ""))
      : editId;
    if (!/^[a-z0-9-]{1,40}$/.test(id)) { show("ID invalide (lettres minuscules, chiffres, tirets)"); return; }
    setSaving(true);
    try {
      await api.saveTheme({ id, name: editName.trim(), colors: editColors });
      const ts = await api.getThemes();
      setThemes(ts);
      setCurrentThemeId(id);
      setEditMode("select");
      show("✅ Thème sauvegardé");
    } catch (e) { show("❌ " + e.message); }
    setSaving(false);
  };

  const del = async (themeId) => {
    if (!window.confirm("Supprimer ce thème ?")) return;
    try {
      await api.deleteTheme(themeId);
      const ts = await api.getThemes();
      setThemes(ts);
      show("Thème supprimé");
    } catch (e) { show("❌ " + e.message); }
  };

  const exportTheme = (t) => {
    const blob = new Blob([JSON.stringify(t, null, 2)], { type: "application/json" });
    const a = document.createElement("a"); a.href = URL.createObjectURL(blob);
    a.download = `${t.id}.json`; a.click();
  };

  const importTheme = (e) => {
    const file = e.target.files?.[0]; if (!file) return;
    const reader = new FileReader();
    reader.onload = ev => {
      try {
        const t = JSON.parse(ev.target.result);
        if (!t.id || !t.name || !t.colors) { show("Fichier JSON invalide"); return; }
        setEditMode("new");
        setEditId(t.id);
        setEditName(t.name);
        setEditColors(t.colors);
      } catch { show("Erreur de lecture"); }
    };
    reader.readAsText(file);
    e.target.value = "";
  };

  const isEditing = editMode === "new" || editMode === "edit";

  return (
    <div>
      <div className="sec-h">
        <span className="sec-t">🎨 Thèmes</span>
        <div style={{ marginLeft: "auto", display: "flex", gap: 6 }}>
          <label className="btn btn-s" style={{ cursor: "pointer" }}>
            📥 Importer <input type="file" accept=".json" style={{ display: "none" }} onChange={importTheme} />
          </label>
          <button className="btn btn-p btn-s" onClick={startNew}>+ Nouveau</button>
        </div>
      </div>

      {!isEditing && (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(200px, 1fr))", gap: 10, marginBottom: 20 }}>
          {themes.map(t => (
            <div key={t.id} style={{ background: "var(--c1)", border: `2px solid ${currentThemeId === t.id ? "var(--ac)" : "var(--brd)"}`, borderRadius: "var(--r)", padding: 12, cursor: "pointer", transition: "border-color .15s" }}
              onClick={() => { applyTheme(t.colors); setCurrentThemeId(t.id); try { api.setUserTheme(t.id); } catch {} }}>
              <div style={{ display: "flex", gap: 4, marginBottom: 8 }}>
                {["d","bg","c1","ac","t1","grn","amb","ros"].map(k => (
                  <div key={k} style={{ width: 14, height: 14, borderRadius: 3, background: t.colors[k] || "#888" }} title={k} />
                ))}
              </div>
              <div style={{ fontSize: 13, fontWeight: 600, color: "var(--t1)", marginBottom: 4 }}>{t.name}</div>
              {t.builtin && <div style={{ fontSize: 10, color: "var(--t3)" }}>Intégré</div>}
              <div style={{ display: "flex", gap: 4, marginTop: 8 }}>
                <button className="btn btn-s" style={{ fontSize: 10 }} onClick={e => { e.stopPropagation(); exportTheme(t); }}>📤</button>
                {!t.builtin && <>
                  <button className="btn btn-s" style={{ fontSize: 10 }} onClick={e => { e.stopPropagation(); startEdit(t.id); }}>✏️</button>
                  <button className="btn btn-s btn-d" style={{ fontSize: 10 }} onClick={e => { e.stopPropagation(); del(t.id); }}>🗑</button>
                </>}
              </div>
            </div>
          ))}
        </div>
      )}

      {isEditing && (
        <div style={{ maxWidth: 700 }}>
          <div style={{ display: "flex", gap: 8, marginBottom: 16, alignItems: "center" }}>
            <button className="btn btn-s" onClick={() => { setEditMode("select"); const t = themes.find(x => x.id === currentThemeId); if (t) applyTheme(t.colors); }}>← Retour</button>
            <span style={{ fontSize: 14, fontWeight: 600, color: "var(--t1)" }}>{editMode === "new" ? "Nouveau thème" : `Modifier : ${editName}`}</span>
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginBottom: 12 }}>
            {editMode === "new" && <div className="fld" style={{ margin: 0 }}>
              <label>ID (optionnel, auto-généré)</label>
              <input value={editId} onChange={e => setEditId(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ""))} placeholder="mon-theme" />
            </div>}
            <div className="fld" style={{ margin: 0 }}>
              <label>Nom affiché</label>
              <input value={editName} onChange={e => setEditName(e.target.value)} placeholder="Mon Thème" />
            </div>
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(180px, 1fr))", gap: 8, marginBottom: 16 }}>
            {THEME_FIELDS.map(({ key, label }) => (
              <div key={key} style={{ display: "flex", alignItems: "center", gap: 8, background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--rs)", padding: "6px 10px" }}>
                <input type="color" value={editColors[key] || "#888888"} style={{ width: 28, height: 28, border: "none", background: "none", cursor: "pointer", padding: 0, borderRadius: 4 }}
                  onChange={e => {
                    const c = { ...editColors, [key]: e.target.value };
                    setEditColors(c);
                    previewColors(c);
                  }} />
                <div>
                  <div style={{ fontSize: 11, fontWeight: 600, color: "var(--t1)" }}>{label}</div>
                  <div style={{ fontSize: 10, color: "var(--t3)", fontFamily: "monospace" }}>{editColors[key] || ""}</div>
                </div>
              </div>
            ))}
          </div>

          <div style={{ display: "flex", gap: 8 }}>
            <button className="btn btn-p" onClick={save} disabled={saving}>{saving ? "Sauvegarde…" : "💾 Sauvegarder"}</button>
            <button className="btn" onClick={() => exportTheme({ id: editId || "preview", name: editName || "Preview", colors: editColors })}>📤 Exporter JSON</button>
          </div>
        </div>
      )}
    </div>
  );
}


// Page "App Android" : visible par tout le monde (lien de téléchargement du dernier
// APK publié) ; pour l'admin, ajoute un formulaire pour publier une nouvelle version
// (utilisé aussi bien à la main que par le logiciel de build Windows via /api/admin/apk).
// Appli Android : distribuée uniquement via une release GitHub (voir APK_DOWNLOAD_URL
// tout en haut du fichier) -- plus d'upload/hébergement côté serveur TamaShelf. Publier
// une nouvelle version se fait désormais uniquement en créant/mettant à jour la release
// GitHub avec un asset nommé "tamashelf.apk" (voir README).
function AppAndroidView() {
  return (
    <>
      <div className="sec-h"><span className="sec-t">📱 Appli Android</span></div>
      <div style={{ maxWidth: 480, padding: 16, background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--r)" }}>
        <div style={{ fontSize: 15, fontWeight: 600, color: "var(--t1)" }}>TamaShelf</div>
        <p style={{ color: "var(--t2)", fontSize: 12, marginTop: 6 }}>App Android native (Flutter), distribuée via GitHub Releases.</p>
        <a className="btn btn-p" style={{ marginTop: 12, textDecoration: "none", display: "inline-block" }} href={APK_DOWNLOAD_URL}>⬇️ Télécharger le .apk</a>
      </div>
    </>
  );
}

function AdminCbzCoverManager({ allMangas, show, onRefresh }) {
  const [q, setQ] = useState("");
  const [selectedManga, setSelectedManga] = useState(null);
  const [cbzList, setCbzList] = useState([]);
  const [cbzLoading, setCbzLoading] = useState(false);
  const [selectedCbz, setSelectedCbz] = useState(null);
  const [detailsLoading, setDetailsLoading] = useState(false);
  const [nautData, setNautData] = useState(null);
  const [edIdx, setEdIdx] = useState(0);
  const [volKey, setVolKey] = useState("");
  const [busy, setBusy] = useState(false);
  const [previewVer, setPreviewVer] = useState(0);
  const [beforeAfter, setBeforeAfter] = useState(null);
  const [orphanCbr, setOrphanCbr] = useState([]);
  const [orphanCanConvert, setOrphanCanConvert] = useState(false);
  const [orphanLoading, setOrphanLoading] = useState(false);

  const refreshOrphan = async () => {
    setOrphanLoading(true);
    try {
      const r = await api.cbrMissingCbz();
      setOrphanCbr(r.items || []);
      setOrphanCanConvert(!!r.can_convert);
    } catch (e) {
      // silencieux (admin page doit rester utilisable)
      setOrphanCbr([]);
      setOrphanCanConvert(false);
    }
    setOrphanLoading(false);
  };

  useEffect(() => { refreshOrphan(); }, []); // eslint-disable-line

  const list = (allMangas || []).filter(m => (String(m.title || m.cbz_folder || '').toLowerCase().includes(q.toLowerCase()) || String(m.cbz_folder || '').toLowerCase().includes(q.toLowerCase()))).sort((a,b)=>String(a.title||a.cbz_folder||'').localeCompare(String(b.title||b.cbz_folder||''), 'fr', {sensitivity:'base'}));

  const loadCbz = async (m) => {
    setSelectedManga(m);
    setSelectedCbz(null);
    setBeforeAfter(null);
    setCbzList([]);
    setNautData(null);
    setVolKey("");
    setCbzLoading(true);
    try {
      const r = await api.cbzList(m.cbz_folder);
      setCbzList(r.files || []);
    } catch (e) {
      show(`❌ ${e.message}`);
    }
    setCbzLoading(false);
  };

  const loadNaut = async (m) => {
    if (!m?.nautiljon_url) { setNautData(null); return; }
    setDetailsLoading(true);
    try {
      const r = await api.nautiljonManga(m.nautiljon_url);
      setNautData(r || null);
      setEdIdx(0);
      setVolKey("");
    } catch (e) {
      setNautData(null);
      show(`❌ Détails Nautiljon: ${e.message}`);
    }
    setDetailsLoading(false);
  };

  useEffect(() => { if (selectedManga) loadNaut(selectedManga); }, [selectedManga?.id]);

  const editions = Array.isArray(nautData?.editions?.editions) ? nautData.editions.editions : (Array.isArray(nautData?.editions) ? nautData.editions : []);
  const selectedEdition = editions[edIdx] || null;
  const selectedEditionVolumes = Array.isArray(selectedEdition?.volumes) ? selectedEdition.volumes : [];
  const selectedVolume = selectedEditionVolumes.find(v => String(v.volume_number ?? v.number ?? v.volume ?? '') === String(volKey)) || null;

  useEffect(() => {
    if (!selectedCbz) return;
    const vol = selectedCbz.volume;
    if (vol == null) return;
    // tenter de sélectionner l'édition/volume correspondant automatiquement
    for (let i=0; i<editions.length; i++) {
      const vols = Array.isArray(editions[i]?.volumes) ? editions[i].volumes : [];
      const hit = vols.find(v => Number(v.volume_number ?? v.number ?? v.volume) === Number(vol));
      if (hit) {
        setEdIdx(i);
        setVolKey(String(hit.volume_number ?? hit.number ?? hit.volume ?? vol));
        return;
      }
    }
  }, [selectedCbz?.path, editions.length]);

  const replaceCover = async () => {
    if (!selectedCbz) return show('❌ Sélectionne un CBZ');
    const coverUrl = nautiljonMiniUrl(selectedVolume?.cover_full || selectedVolume?.cover_mini || selectedVolume?.cover_url);
    if (!coverUrl) return show('❌ Pas de cover sur ce volume');
    setBusy(true);
    try {
      const prevSrc = api.cbzPageUrl(selectedCbz.path, 0) + `&v=${previewVer}`;
      await api.replaceCbzCover(selectedCbz.path, coverUrl);
      const nextVer = Date.now();
      setPreviewVer(nextVer);
      setBeforeAfter({ cbzPath: selectedCbz.path, beforeSrc: prevSrc, afterSrc: api.cbzPageUrl(selectedCbz.path, 0) + `&v=${nextVer}` });
      show(`✅ Cover remplacée: ${selectedCbz.name}`);
      // force refresh image by cloning object
      setSelectedCbz({ ...selectedCbz });
      onRefresh?.();
    } catch (e) {
      show(`❌ ${e.message}`);
    }
    setBusy(false);
  };

  return (
    <>
      <div className="sec-h"><span className="sec-t">Admin • Covers CBZ</span></div>

      <div style={{ background:'var(--c1)', border:'1px solid var(--brd)', borderRadius:'var(--r)', padding:10, marginBottom:10 }}>
        <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', gap:10 }}>
          <div style={{ fontSize:12, fontWeight:700, color:'var(--t1)' }}>📣 CBR détectés (sans CBZ)</div>
          <button className="btn btn-s" onClick={refreshOrphan} disabled={orphanLoading}>
            {orphanLoading ? '…' : 'Rafraîchir'}
          </button>
        </div>
        <div style={{ fontSize:11, color:'var(--t3)', marginTop:4 }}>
          Les <b>.cbr</b> ne sont pas affichés dans l'onglet Tomes. Convertis-les en <b>.cbz</b> pour les lire.
        </div>
        {orphanCbr.length === 0 ? (
          <div style={{ fontSize:11, color:'var(--t2)', marginTop:8 }}>✅ Aucun CBR orphelin trouvé.</div>
        ) : (
          <div style={{ marginTop:8, display:'flex', flexDirection:'column', gap:6, maxHeight:160, overflow:'auto' }}>
            {orphanCbr.map((it, idx) => (
              <div key={it.cbr_path || idx} style={{ display:'flex', alignItems:'center', gap:8, padding:'6px 8px', border:'1px solid var(--brd)', borderRadius:6, background:'var(--c2)' }}>
                <div style={{ minWidth:0, flex:1 }}>
                  <div style={{ fontSize:11, fontWeight:600, color:'var(--t1)', overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap' }}>📁 {it.folder} • {it.filename}</div>
                  <div style={{ fontSize:10, color:'var(--t3)', overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap' }}>→ {it.expected_cbz_path}</div>
                </div>
                <button
                  className="btn btn-s btn-p"
                  disabled={!orphanCanConvert}
                  title={!orphanCanConvert ? 'Installe 7z + zip sur le serveur' : 'Convertir en CBZ (même dossier)'}
                  onClick={async () => {
                    try {
                      show('Conversion…');
                      await api.convertCbrToCbz(it.cbr_path);
                      show('✅ Converti en CBZ');
                      await refreshOrphan();
                      // refresh list for selected manga if it matches
                      if (selectedManga?.cbz_folder && String(it.folder) === String(selectedManga.cbz_folder)) {
                        loadCbz(selectedManga);
                      }
                      onRefresh?.();
                    } catch (e) {
                      show(`❌ ${e.message}`);
                    }
                  }}
                >
                  🔁 Convertir
                </button>
              </div>
            ))}
          </div>
        )}
        {!orphanCanConvert && orphanCbr.length > 0 && (
          <div style={{ fontSize:11, color:'var(--t3)', marginTop:6 }}>
            ℹ️ Conversion indisponible: installe <code>p7zip-full</code> et <code>zip</code> sur le serveur.
          </div>
        )}
      </div>

      <div style={{ display:'grid', gridTemplateColumns:'minmax(220px, 1fr) minmax(260px, 1.1fr) minmax(320px, 1.4fr)', gap:10, alignItems:'start' }}>
        <div style={{ background:'var(--c1)', border:'1px solid var(--brd)', borderRadius:'var(--r)', padding:10, maxHeight:'70vh', overflow:'auto' }}>
          <div style={{ fontSize:12, fontWeight:600, color:'var(--t1)', marginBottom:6 }}>Mangas ({allMangas.length})</div>
          <input value={q} onChange={e=>setQ(e.target.value)} placeholder="Filtrer…" style={{ width:'100%', marginBottom:8, fontSize:12, padding:'6px 8px' }} />
          <div style={{ display:'flex', flexDirection:'column', gap:4 }}>
            {list.map(m => (
              <button key={m.id} className="btn" onClick={()=>loadCbz(m)} style={{ textAlign:'left', justifyContent:'flex-start', background:selectedManga?.id===m.id?'var(--c2)':'transparent', borderColor:selectedManga?.id===m.id?'var(--ac)':'var(--brd)' }}>
                <span style={{ overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap' }}>{m.title || m.cbz_folder}</span>
              </button>
            ))}
            {list.length===0 && <div style={{ fontSize:11, color:'var(--t3)' }}>Aucun manga</div>}
          </div>
        </div>

        <div style={{ background:'var(--c1)', border:'1px solid var(--brd)', borderRadius:'var(--r)', padding:10, minHeight:260 }}>
          <div style={{ fontSize:12, fontWeight:600, color:'var(--t1)', marginBottom:6 }}>Fichiers CBZ</div>
          {!selectedManga && <div style={{ fontSize:11, color:'var(--t3)' }}>Sélectionne un manga à gauche.</div>}
          {selectedManga && <>
            <div style={{ fontSize:11, color:'var(--t2)', marginBottom:6 }}>📁 {selectedManga.cbz_folder}</div>
            {cbzLoading && <div style={{ fontSize:11 }}>Chargement…</div>}
            {!cbzLoading && <div style={{ display:'flex', flexDirection:'column', gap:4, maxHeight:'58vh', overflow:'auto' }}>
              {cbzList.map(f => (
                <div key={f.path} onClick={()=>{ setSelectedCbz(f); setBeforeAfter(null); setPreviewVer(Date.now()); }} style={{ cursor:'pointer', padding:'6px 8px', border:'1px solid var(--brd)', borderRadius:6, background:selectedCbz?.path===f.path?'var(--c2)':'transparent' }}>
                  <div style={{ fontSize:11, color:'var(--t1)', fontWeight:600 }}>{f.volume_display || '—'} • {f.name}</div>
                  <div style={{ fontSize:10, color:'var(--t3)' }}>{Math.round((f.size||0)/1024/1024*10)/10} Mo</div>
                </div>
              ))}
              {cbzList.length===0 && <div style={{ fontSize:11, color:'var(--t3)' }}>Aucun CBZ</div>}
            </div>}
          </>}
        </div>

        <div style={{ background:'var(--c1)', border:'1px solid var(--brd)', borderRadius:'var(--r)', padding:10, minHeight:260 }}>
          <div style={{ fontSize:12, fontWeight:600, color:'var(--t1)', marginBottom:6 }}>Aperçu & remplacement</div>
          {!selectedCbz && <div style={{ fontSize:11, color:'var(--t3)' }}>Sélectionne un CBZ pour voir sa première image.</div>}
          {selectedCbz && <>
            <div style={{ display:'grid', gridTemplateColumns:'140px 1fr', gap:10 }}>
              <div>
                <img src={api.cbzPageUrl(selectedCbz.path, 0) + `&v=${previewVer}`} alt="" style={{ width:'100%', maxHeight:220, objectFit:'contain', background:'var(--c2)', border:'1px solid var(--brd)', borderRadius:6 }} />
                <div style={{ fontSize:10, color:'var(--t3)', marginTop:4 }}>1ʳᵉ image du CBZ</div>
                {beforeAfter && beforeAfter.cbzPath===selectedCbz.path && <div style={{ marginTop:8 }}>
                  <div style={{ fontSize:10, color:'var(--t3)', marginBottom:4 }}>Aperçu avant / après (dernier remplacement)</div>
                  <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr', gap:6 }}>
                    <div>
                      <img src={beforeAfter.beforeSrc} alt="Avant" style={{ width:'100%', height:120, objectFit:'contain', background:'var(--c2)', border:'1px solid var(--brd)', borderRadius:6 }} />
                      <div style={{ fontSize:10, color:'var(--t3)', marginTop:2, textAlign:'center' }}>Avant</div>
                    </div>
                    <div>
                      <img src={beforeAfter.afterSrc} alt="Après" style={{ width:'100%', height:120, objectFit:'contain', background:'var(--c2)', border:'1px solid var(--brd)', borderRadius:6 }} />
                      <div style={{ fontSize:10, color:'var(--t3)', marginTop:2, textAlign:'center' }}>Après</div>
                    </div>
                  </div>
                </div>}
              </div>
              <div style={{ minWidth:0 }}>
                <div style={{ fontSize:11, color:'var(--t2)', marginBottom:6 }}>{selectedCbz.name}</div>
                {!selectedManga?.nautiljon_url && <div style={{ fontSize:11, color:'var(--t3)' }}>Ce manga n'a pas d'URL Nautiljon associée.</div>}
                {selectedManga?.nautiljon_url && <div style={{ display:'flex', flexDirection:'column', gap:6 }}>
                  <div style={{ fontSize:10, color:'var(--t3)', wordBreak:'break-all' }}>{selectedManga.nautiljon_url}</div>
                  {detailsLoading && <div style={{ fontSize:11 }}>Chargement des éditions…</div>}
                  {!detailsLoading && editions.length===0 && <div style={{ fontSize:11, color:'var(--t3)' }}>Aucune édition trouvée.</div>}
                  {!detailsLoading && editions.length>0 && <>
                    <div>
                      <label style={{ fontSize:10, color:'var(--t3)', display:'block', marginBottom:2 }}>Édition</label>
                      <select value={edIdx} onChange={e=>{ setEdIdx(Number(e.target.value)); setVolKey(''); }} style={{ width:'100%', fontSize:12, padding:'6px 8px' }}>
                        {editions.map((ed, i) => {
                          const lbl = ed.label || ed.name || ed.publisher || ed.country || `Édition ${i+1}`;
                          return <option key={i} value={i}>{lbl}</option>;
                        })}
                      </select>
                    </div>
                    <div>
                      <label style={{ fontSize:10, color:'var(--t3)', display:'block', marginBottom:2 }}>Volume</label>
                      <select value={volKey} onChange={e=>setVolKey(e.target.value)} style={{ width:'100%', fontSize:12, padding:'6px 8px' }}>
                        <option value="">Choisir…</option>
                        {selectedEditionVolumes.map((v, i) => {
                          const num = v.volume_number ?? v.number ?? v.volume ?? '';
                          const title = v.title || v.name || '';
                          return <option key={i} value={String(num)}>{num ? `T${String(num).padStart(2,'0')}` : `Vol ${i+1}`} {title ? `— ${title}` : ''}</option>;
                        })}
                      </select>
                    </div>
                    {selectedVolume && (selectedVolume.cover_full || selectedVolume.cover_mini || selectedVolume.cover_url) && <div style={{ display:'grid', gridTemplateColumns:'80px 1fr', gap:8, alignItems:'start' }}>
                      <img src={nautiljonMiniUrl(selectedVolume.cover_full || selectedVolume.cover_mini || selectedVolume.cover_url)} alt="" style={{ width:80, height:110, objectFit:'cover', border:'1px solid var(--brd)', borderRadius:4 }} />
                      <div>
                        <div style={{ fontSize:11, color:'var(--t2)' }}>Cover Nautiljon sélectionnée</div>
                        <button className="btn btn-p" onClick={replaceCover} disabled={busy} style={{ marginTop:6 }}>
                          {busy ? 'Remplacement…' : '✅ Remplacer la 1ʳᵉ image du CBZ'}
                        </button>
                      </div>
                    </div>}
                  </>}
                </div>}
              </div>
            </div>
          </>}
        </div>
      </div>
    </>
  );
}

/* ═══ Carte de matching manuel avec recherche ═══ */
function UnmatchedCard({ manga, show, onDone }) {
  const [sq, setSq] = useState(manga.cbz_folder);
  const [directUrl, setDirectUrl] = useState("");
  const [results, setResults] = useState([]);
  const [loading, setLoading] = useState(false);
  const [mode, setMode] = useState("search"); // search | manual
  const [manual, setManual] = useState({ title: manga.cbz_folder, synopsis: "", type: "", genres: "", auteur: "" });
  // Use authenticated CBZ cover endpoint (token query param), otherwise the image 401s and won't render
  const folderCoverSrc = api.cbzFolderCoverUrl(manga.cbz_folder);

  const doSearch = async () => {
    if (!sq.trim()) return;
    setLoading(true);
    try {
      const r = await api.nautiljonSearch(sq.trim(), 24);
      setResults(r.results || r.rows || []);
    } catch (e) { show(`❌ ${e.message}`); }
    setLoading(false);
  };

  const validate = async (url) => {
    const cleanUrl = String(url || '').trim();
    if (!cleanUrl) return;
    setLoading(true);
    try { await api.validateMatch(manga.id, cleanUrl); show(`✅ ${manga.cbz_folder} associé`); onDone(); } catch (e) { show(`❌ ${e.message}`); }
    setLoading(false);
  };

  const validateDirectUrl = async () => {
    const u = directUrl.trim();
    if (!u) return;
    if (!/nautiljon\.com/i.test(u)) {
      show('❌ URL Nautiljon invalide');
      return;
    }
    await validate(u);
  };

  const createManual = async () => {
    setLoading(true);
    try {
      const meta = {};
      if (manual.type) meta["Type"] = manual.type;
      if (manual.genres) meta["Genres"] = manual.genres;
      if (manual.auteur) meta["Auteur"] = manual.auteur;
      await api.updateManga(manga.id, { title: manual.title, synopsis: manual.synopsis, metadata_json: meta });
      show(`✅ ${manual.title} créé`);
      onDone();
    } catch (e) { show(`❌ ${e.message}`); }
    setLoading(false);
  };

  return (
    <div style={{ padding: 10, background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--r)", marginBottom: 8 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6 }}>
        <span style={{ fontSize: 13, fontWeight: 600, color: "var(--t1)", flex: 1 }}>📁 {manga.cbz_folder}</span>
        <button className={`btn btn-s ${mode === "search" ? "btn-p" : ""}`} style={{ fontSize: 9 }} onClick={() => setMode("search")}>🔍 Rechercher</button>
        <button className={`btn btn-s ${mode === "manual" ? "btn-p" : ""}`} style={{ fontSize: 9 }} onClick={() => setMode("manual")}>✏️ Manuel</button>
      </div>

      {mode === "search" && <>
        <div style={{ display: "flex", gap: 10, alignItems: "flex-start", marginBottom: 6 }}>
          <img
            src={folderCoverSrc}
            alt=""
            style={{ width: 52, height: 72, borderRadius: 6, objectFit: "cover", border: "1px solid var(--brd)", background: "var(--c2)", flex: "0 0 auto" }}
            onError={(e) => { e.currentTarget.style.display = "none"; }}
          />
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ display: "flex", gap: 4, marginBottom: 6 }}>
              <input style={{ flex: 1, fontSize: 12, padding: "4px 8px" }} value={sq} onChange={e => setSq(e.target.value)} placeholder="Rechercher sur Nautiljon…" onKeyDown={e => e.key === "Enter" && doSearch()} />
              <button className="btn btn-s btn-p" onClick={doSearch} disabled={loading}>{loading ? "…" : "🔍"}</button>
            </div>
            <div style={{ display: "flex", gap: 4, marginBottom: 6 }}>
              <input
                style={{ flex: 1, fontSize: 11, padding: "4px 8px" }}
                value={directUrl}
                onChange={e => setDirectUrl(e.target.value)}
                placeholder="Ou coller l'URL Nautiljon directe (ex: https://www.nautiljon.com/mangas/...)"
                onKeyDown={e => e.key === "Enter" && validateDirectUrl()}
              />
              <button className="btn btn-s btn-g" onClick={validateDirectUrl} disabled={loading || !directUrl.trim()}>
                🔗 Associer URL
              </button>
            </div>
          </div>
        </div>
{results.length > 0 && <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          {results.map((r, i) => {
            // Build cover URL: try cover_url, image_url, or construct from manga URL
            let coverSrc = r.cover_url || r.image_url || "";
            if (!coverSrc && r.url) {
              // Nautiljon pattern: /mangas/one+piece.html -> /images/manga/one+piece/one+piece.jpg
              const slug = String(r.url).replace(/^.*\/mangas\//, "").replace(/\.html$/, "").replace(/\/$/, "");
              if (slug) coverSrc = `https://www.nautiljon.com/images/manga/${slug}/${slug}.jpg`;
            }
            if (coverSrc) coverSrc = nautiljonMiniUrl(coverSrc);
            return (
            <div key={i} style={{ display: "flex", alignItems: "stretch", gap: 10, padding: "6px 8px", background: "var(--c2)", borderRadius: 6, cursor: "pointer", border: "1px solid var(--brd)", transition: "border-color .15s" }} onClick={() => validate(r.url)}
              onMouseEnter={e => e.currentTarget.style.borderColor = "var(--grn)"}
              onMouseLeave={e => e.currentTarget.style.borderColor = "var(--brd)"}>
              {/* Cover thumbnail */}
              <div style={{ width: 52, minHeight: 72, flexShrink: 0, borderRadius: 4, overflow: "hidden", background: "var(--c1)", border: "1px solid var(--brd)" }}>
                {coverSrc
                  ? <img src={coverSrc} alt="" style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }} onError={e => { e.currentTarget.style.display = "none"; e.currentTarget.nextSibling && (e.currentTarget.nextSibling.style.display = "flex"); }} />
                  : null
                }
                <div style={{ width: "100%", height: "100%", display: coverSrc ? "none" : "flex", alignItems: "center", justifyContent: "center", color: "var(--t3)", fontSize: 20 }}>📖</div>
              </div>
              {/* Info */}
              <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "center", minWidth: 0 }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: "var(--t1)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{r.title}</div>
                {r.url && <div style={{ fontSize: 9, color: "var(--t3)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", marginTop: 2 }}>{String(r.url).replace(/^https?:\/\/www\.nautiljon\.com/, "")}</div>}
                {(r.type || r.genres) && <div style={{ display: "flex", gap: 3, marginTop: 3, flexWrap: "wrap" }}>
                  {r.type && <span style={{ fontSize: 9, padding: "1px 5px", borderRadius: 8, background: "var(--ac)", color: "#fff", fontWeight: 600 }}>{r.type}</span>}
                  {(r.genres || "").split(/\s*[-,]\s*/).filter(Boolean).slice(0, 3).map((g, gi) => <span key={gi} style={{ fontSize: 9, padding: "1px 5px", borderRadius: 8, background: "rgba(99,102,241,.12)", color: "var(--acl)", fontWeight: 500 }}>{g}</span>)}
                </div>}
              </div>
              {/* Button */}
              <div style={{ display: "flex", alignItems: "center", flexShrink: 0 }}>
                <button className="btn btn-s btn-g" style={{ fontSize: 9, whiteSpace: "nowrap" }}>✓ Associer</button>
              </div>
            </div>
          );})}
        </div>}
        {results.length === 0 && !loading && <p style={{ fontSize: 10, color: "var(--t3)" }}>Tapez un titre et cliquez 🔍, ou collez directement une URL Nautiljon.</p>}
      </>}

      {mode === "manual" && <>
        <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          <input style={{ fontSize: 11, padding: "3px 6px" }} value={manual.title} onChange={e => setManual(m => ({ ...m, title: e.target.value }))} placeholder="Titre" />
          <input style={{ fontSize: 11, padding: "3px 6px" }} value={manual.auteur} onChange={e => setManual(m => ({ ...m, auteur: e.target.value }))} placeholder="Auteur" />
          <div style={{ display: "flex", gap: 4 }}>
            <input style={{ flex: 1, fontSize: 11, padding: "3px 6px" }} value={manual.type} onChange={e => setManual(m => ({ ...m, type: e.target.value }))} placeholder="Type (Shonen, Seinen…)" />
            <input style={{ flex: 1, fontSize: 11, padding: "3px 6px" }} value={manual.genres} onChange={e => setManual(m => ({ ...m, genres: e.target.value }))} placeholder="Genres" />
          </div>
          <textarea style={{ fontSize: 11, padding: "3px 6px", minHeight: 40, resize: "vertical" }} value={manual.synopsis} onChange={e => setManual(m => ({ ...m, synopsis: e.target.value }))} placeholder="Synopsis (optionnel)" />
          <button className="btn btn-s btn-p" onClick={createManual} disabled={loading}>💾 Créer la fiche</button>
        </div>
      </>}
    </div>
  );
}

/* ═══ Homepage View ═══ */
function HomepageView({ onOpenManga, onResumeReading, allMangas, show }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    api.getHomepage().then(setData).catch(() => {}).finally(() => setLoading(false));
  }, []);

  if (loading) return <div className="loading"><div className="spinner" /> Chargement...</div>;
  if (!data) return <div className="empty"><p>Erreur de chargement</p></div>;

  const Section = ({ title, icon, children }) => (
    <div style={{ marginBottom: 24 }}>
      <div className="sec-h"><span className="sec-t">{icon} {title}</span></div>
      {children}
    </div>
  );

  const MangaScroll = ({ items, onSelect }) => (
    <div style={{ display: "flex", gap: 10, overflowX: "auto", paddingBottom: 8 }}>
      {items.map(m => (
        <div key={m.id} onClick={() => onSelect(m)} style={{ minWidth: 100, maxWidth: 100, cursor: "pointer", flexShrink: 0 }}>
          <div style={{ width: 100, height: 142, borderRadius: "var(--r)", overflow: "hidden", background: "var(--c2)", border: "1px solid var(--brd)" }}>
            <img src={api.cbzFolderCoverUrl(m.cbz_folder)} alt="" loading="lazy" style={{ width: "100%", height: "100%", objectFit: "cover" }}
              onError={e => { const fb = m.cover_url ? nautiljonMiniUrl(m.cover_url) : ""; if (fb && !e.target.dataset.fb) { e.target.dataset.fb = "1"; e.target.src = fb; } else e.target.style.opacity = ".2"; }} />
          </div>
          <div style={{ fontSize: 10, color: "var(--t1)", marginTop: 4, fontWeight: 600, lineHeight: 1.3, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{m.title}</div>
        </div>
      ))}
    </div>
  );

  const findManga = (id) => allMangas.find(m => m.id === id) || allMangas.find(m => m.grouped_variants?.some(v => v.id === id));

  return <>
    {data.progress?.length > 0 && (
      <Section title="Reprendre la lecture" icon="📖">
        <div style={{ display: "flex", gap: 10, overflowX: "auto", paddingBottom: 8 }}>
          {data.progress.map(p => {
            const pct = p.total_pages > 0 ? Math.round(p.current_page / p.total_pages * 100) : 0;
            return (
              <div key={`${p.manga_url}__${p.volume_id}`} onClick={() => onResumeReading(p)} style={{ minWidth: 100, maxWidth: 100, cursor: "pointer", flexShrink: 0 }}>
                <div style={{ position: "relative", width: 100, height: 142, borderRadius: "var(--r)", overflow: "hidden", background: "var(--c2)", border: "1px solid var(--brd)" }}>
                  <img src={api.cbzFolderCoverUrl(p.manga_url)} alt="" style={{ width: "100%", height: "100%", objectFit: "cover" }} onError={e => { e.target.style.opacity = ".2"; }} />
                  <div style={{ position: "absolute", bottom: 0, left: 0, right: 0, height: 4, background: "var(--brd)" }}>
                    <div style={{ width: pct + "%", height: "100%", background: "var(--ac)" }} />
                  </div>
                </div>
                <div style={{ fontSize: 10, color: "var(--t1)", marginTop: 4, fontWeight: 600, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{p.title || p.manga_url}</div>
                <div style={{ fontSize: 9, color: "var(--t3)" }}>{pct}%</div>
              </div>
            );
          })}
        </div>
      </Section>
    )}

    {data.recent?.length > 0 && (
      <Section title="Derniers ajoutés" icon="🆕">
        <MangaScroll items={data.recent} onSelect={m => { const found = findManga(m.id); if (found) onOpenManga(found); }} />
      </Section>
    )}

    {data.top_rated?.length > 0 && (
      <Section title="Mes favoris" icon="⭐">
        <MangaScroll items={data.top_rated} onSelect={m => { const found = findManga(m.id); if (found) onOpenManga(found); }} />
      </Section>
    )}

    {data.recommendations?.length > 0 && (
      <Section title={`Recommandés (${data.top_genre || ""})`} icon="💡">
        <MangaScroll items={data.recommendations} onSelect={m => { const found = findManga(m.id); if (found) onOpenManga(found); }} />
      </Section>
    )}

    {(!data.progress?.length && !data.recent?.length) && (
      <div className="empty"><div className="ei">📚</div><p>Bienvenue ! Synchronisez votre bibliothèque pour commencer.</p></div>
    )}
  </>;
}

/* ═══ Collections View ═══ */
function CollectionsView({ allMangas, onOpenManga, show }) {
  const [collections, setCollections] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showCreate, setShowCreate] = useState(false);
  const [form, setForm] = useState({ name: "", description: "", color: "#6366f1", icon: "📚" });

  const load = async () => {
    setLoading(true);
    try { setCollections(await api.getCollections()); } catch {}
    setLoading(false);
  };
  useEffect(() => { load(); }, []);

  const create = async () => {
    if (!form.name.trim()) return;
    try { await api.createCollection(form); show("✅ Collection créée"); setShowCreate(false); setForm({ name: "", description: "", color: "#6366f1", icon: "📚" }); load(); }
    catch (e) { show("❌ " + e.message); }
  };

  const remove = async (id) => {
    if (!confirm("Supprimer cette collection ?")) return;
    try { await api.deleteCollection(id); load(); } catch {}
  };

  const icons = ["📚", "⭐", "❤️", "🔥", "🎯", "📖", "🏆", "💎", "🌸", "⚔️", "🎭", "🌙"];
  const colors = ["#6366f1", "#f43f5e", "#f59e0b", "#10b981", "#3b82f6", "#8b5cf6", "#ec4899", "#14b8a6"];

  return <>
    <div className="sec-h">
      <span className="sec-t">📂 Collections</span>
      <button className="btn btn-p btn-s" style={{ marginLeft: "auto" }} onClick={() => setShowCreate(!showCreate)}>+ Créer</button>
    </div>

    {showCreate && (
      <div style={{ background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--r)", padding: 14, marginBottom: 12 }}>
        <div className="fld"><label>Nom</label><input value={form.name} onChange={e => setForm(f => ({ ...f, name: e.target.value }))} placeholder="Ma collection" /></div>
        <div className="fld"><label>Description</label><input value={form.description} onChange={e => setForm(f => ({ ...f, description: e.target.value }))} placeholder="Optionnel" /></div>
        <div style={{ display: "flex", gap: 8, marginBottom: 8 }}>
          <div><label style={{ fontSize: 10, color: "var(--t3)" }}>Icône</label><div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>{icons.map(ic => <span key={ic} onClick={() => setForm(f => ({...f, icon: ic}))} style={{ cursor: "pointer", fontSize: 18, opacity: form.icon === ic ? 1 : .3 }}>{ic}</span>)}</div></div>
          <div><label style={{ fontSize: 10, color: "var(--t3)" }}>Couleur</label><div style={{ display: "flex", gap: 4 }}>{colors.map(c => <div key={c} onClick={() => setForm(f => ({...f, color: c}))} style={{ width: 20, height: 20, borderRadius: "50%", background: c, cursor: "pointer", border: form.color === c ? "2px solid #fff" : "2px solid transparent" }} />)}</div></div>
        </div>
        <button className="btn btn-p" onClick={create}>Créer</button>
      </div>
    )}

    {loading ? <div className="loading"><div className="spinner" /></div> :
      collections.length === 0 ? <div className="empty"><p>Aucune collection. Créez-en une !</p></div> :
      collections.map(col => (
        <div key={col.id} style={{ background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--r)", padding: 14, marginBottom: 8 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
            <span style={{ fontSize: 22 }}>{col.icon}</span>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 14, fontWeight: 700, color: "var(--t1)" }}>{col.name} <span style={{ color: col.color, fontSize: 11 }}>({col.count})</span></div>
              {col.description && <div style={{ fontSize: 10, color: "var(--t3)" }}>{col.description}</div>}
            </div>
            <button className="btn btn-s btn-d" onClick={() => remove(col.id)}>🗑️</button>
          </div>
          {col.manga_ids?.length > 0 && (
            <div style={{ display: "flex", gap: 6, overflowX: "auto", paddingBottom: 4 }}>
              {col.manga_ids.map(id => {
                const m = allMangas.find(x => x.id === id || x.grouped_variants?.some(v => v.id === id));
                if (!m) return null;
                return <div key={id} onClick={() => onOpenManga(m)} style={{ minWidth: 60, maxWidth: 60, cursor: "pointer", flexShrink: 0 }}>
                  <img src={api.cbzFolderCoverUrl(m.cbz_folder)} alt="" style={{ width: 60, height: 85, borderRadius: 6, objectFit: "cover", background: "var(--c2)" }} onError={e => { e.target.style.opacity = ".2"; }} />
                  <div style={{ fontSize: 8, color: "var(--t2)", marginTop: 2, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{m.title}</div>
                </div>;
              })}
            </div>
          )}
        </div>
      ))
    }
  </>;
}

/* ═══ Stats View ═══ */
function StatsView({ show }) {
  const [stats, setStats] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    api.getStats().then(setStats).catch(() => {}).finally(() => setLoading(false));
  }, []);

  if (loading) return <div className="loading"><div className="spinner" /></div>;
  if (!stats) return <div className="empty"><p>Pas encore de statistiques</p></div>;

  const hours = Math.floor(stats.total_seconds / 3600);
  const mins = Math.floor((stats.total_seconds % 3600) / 60);

  const maxPages = Math.max(...(stats.daily || []).map(d => d.pages_read), 1);

  return <>
    <div className="sec-h"><span className="sec-t">📊 Statistiques de lecture</span></div>

    {/* Summary cards */}
    <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10, marginBottom: 20 }}>
      {[
        { icon: "📄", label: "Pages lues", value: stats.total_pages.toLocaleString() },
        { icon: "📖", label: "Volumes lus", value: stats.total_volumes },
        { icon: "⏱️", label: "Temps de lecture", value: hours > 0 ? `${hours}h ${mins}m` : `${mins}m` },
        { icon: "📅", label: "Jours actifs", value: stats.active_days },
        { icon: "📚", label: "En cours", value: stats.in_progress },
      ].map((s, i) => (
        <div key={i} style={{ background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--r)", padding: 14, textAlign: "center" }}>
          <div style={{ fontSize: 24 }}>{s.icon}</div>
          <div style={{ fontSize: 20, fontWeight: 800, color: "var(--t1)", marginTop: 4 }}>{s.value}</div>
          <div style={{ fontSize: 10, color: "var(--t3)" }}>{s.label}</div>
        </div>
      ))}
    </div>

    {/* Daily chart */}
    {stats.daily?.length > 0 && <>
      <div className="sec-h"><span className="sec-t">📈 30 derniers jours</span></div>
      <div style={{ display: "flex", alignItems: "flex-end", gap: 2, height: 120, padding: "0 4px", background: "var(--c1)", borderRadius: "var(--r)", border: "1px solid var(--brd)", marginBottom: 16 }}>
        {stats.daily.map((d, i) => (
          <div key={i} title={`${d.date}: ${d.pages_read} pages`}
            style={{ flex: 1, background: "var(--ac)", borderRadius: "2px 2px 0 0", minHeight: 2,
              height: `${Math.max(2, (d.pages_read / maxPages) * 100)}%`, opacity: d.pages_read > 0 ? 1 : .15 }} />
        ))}
      </div>
    </>}

    {/* Top genres */}
    {stats.top_genres?.length > 0 && <>
      <div className="sec-h"><span className="sec-t">🏷️ Genres préférés</span></div>
      <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
        {stats.top_genres.map(([genre, count], i) => (
          <span key={i} className="genre-badge genre-badge-outline" style={{ color: tagColor(genre), borderColor: tagColor(genre) + "66", padding: "4px 10px" }}>
            {genre} <span style={{ opacity: .6 }}>({count})</span>
          </span>
        ))}
      </div>
    </>}
  </>;
}

/* ═══ Duplicates Manager ═══ */
function DuplicatesManager({ show, onRefresh }) {
  const [dups, setDups] = useState([]);
  const [loading, setLoading] = useState(true);

  const load = async () => {
    setLoading(true);
    try {
      const r = await api.detectDuplicates();
      setDups(r.duplicates || []);
    } catch (e) { show("Erreur: " + e.message); }
    setLoading(false);
  };

  React.useEffect(() => { load(); }, []);

  const merge = async (keepId, mergeIds) => {
    try {
      await api.mergeMangas(keepId, mergeIds.join(","));
      show("✅ Fusion effectuée");
      load();
      onRefresh();
    } catch (e) { show("❌ " + e.message); }
  };

  return <>
    <div className="sec-h"><span className="sec-t">🔀 Doublons détectés</span><span className="cnt">{dups.length}</span>
      <button className="ib" onClick={load} style={{ marginLeft: "auto" }}>🔄</button>
    </div>
    {loading ? <div className="loading"><div className="spinner" /> Analyse...</div> :
      dups.length === 0 ? <div className="empty"><p>Aucun doublon détecté</p></div> :
      dups.map((g, gi) => (
        <div key={gi} style={{ background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--r)", padding: 12, marginBottom: 8 }}>
          <div style={{ fontSize: 13, fontWeight: 600, color: "var(--t1)", marginBottom: 8 }}>📁 {g.key} <span style={{ color: "var(--t3)", fontWeight: 400 }}>({g.count} dossiers)</span></div>
          {g.items.map((item, ii) => (
            <div key={item.id} style={{ display: "flex", alignItems: "center", gap: 8, padding: "4px 8px", background: ii === 0 ? "rgba(52,211,153,.08)" : "var(--c2)", borderRadius: 4, marginBottom: 3, border: ii === 0 ? "1px solid rgba(52,211,153,.2)" : "1px solid var(--brd)" }}>
              <span className={`badge ${item.match_status === "matched" ? "bg" : "ba"}`}>{item.match_status === "matched" ? "✓" : "?"}</span>
              <span style={{ flex: 1, fontSize: 11, color: "var(--t1)" }}>{item.cbz_folder}</span>
              <span style={{ fontSize: 9, color: "var(--t3)" }}>#{item.id}</span>
            </div>
          ))}
          <div style={{ display: "flex", gap: 4, marginTop: 6 }}>
            <button className="btn btn-s btn-g" onClick={() => {
              const keep = g.items.find(i => i.match_status === "matched") || g.items[0];
              const others = g.items.filter(i => i.id !== keep.id).map(i => i.id);
              if (others.length && confirm(`Fusionner ${others.length} dossier(s) dans "${keep.cbz_folder}" ?`)) {
                merge(keep.id, others);
              }
            }}>🔀 Fusionner</button>
            <span style={{ fontSize: 9, color: "var(--t3)", alignSelf: "center" }}>Garde le premier (associé) et fusionne les volumes des autres</span>
          </div>
        </div>
      ))
    }
  </>;
}

/* ═══ Keyboard Config Modal ═══ */
function KeyboardConfigModal({ keyConfig, onSave, onClose }) {
  const defaults = {
    nextPage: "ArrowRight",
    prevPage: "ArrowLeft",
    nextPageAlt: " ",
    toggleBar: "Escape",
    toggleBookmark: "b",
    toggleWebtoon: "w",
    toggleDouble: "d",
    zoomIn: "+",
    zoomOut: "-",
    zoomReset: "0",
  };
  const labels = {
    nextPage: "Page suivante",
    prevPage: "Page précédente",
    nextPageAlt: "Page suivante (alt)",
    toggleBar: "Afficher/masquer barre",
    toggleBookmark: "Marque-page",
    toggleWebtoon: "Mode webtoon",
    toggleDouble: "Mode double page",
    zoomIn: "Zoom +",
    zoomOut: "Zoom -",
    zoomReset: "Zoom reset",
  };
  const [cfg, setCfg] = useState({ ...defaults, ...keyConfig });
  const [recording, setRecording] = useState(null);

  const keyDisplay = (k) => {
    if (k === " ") return "Espace";
    if (k === "ArrowRight") return "→";
    if (k === "ArrowLeft") return "←";
    if (k === "ArrowUp") return "↑";
    if (k === "ArrowDown") return "↓";
    if (k === "Escape") return "Échap";
    return k.length === 1 ? k.toUpperCase() : k;
  };

  useEffect(() => {
    if (!recording) return;
    const h = (e) => {
      e.preventDefault();
      e.stopPropagation();
      setCfg(prev => ({ ...prev, [recording]: e.key }));
      setRecording(null);
    };
    window.addEventListener("keydown", h, true);
    return () => window.removeEventListener("keydown", h, true);
  }, [recording]);

  return (
    <div className="modal-ov" onClick={e => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="modal">
        <h2>⌨️ Raccourcis clavier</h2>
        <p style={{ color: "var(--t3)", fontSize: 11, marginBottom: 14 }}>Cliquez sur une touche puis appuyez sur la nouvelle touche souhaitée.</p>
        {Object.entries(labels).map(([key, label]) => (
          <div key={key} className="key-row">
            <div className="key-label">{label}</div>
            <button
              className={`key-btn ${recording === key ? "recording" : ""}`}
              onClick={() => setRecording(recording === key ? null : key)}
            >
              {recording === key ? "..." : keyDisplay(cfg[key] || defaults[key])}
            </button>
          </div>
        ))}
        <div className="modal-ft">
          <button className="btn" onClick={() => { setCfg({ ...defaults }); }}>Réinitialiser</button>
          <button className="btn" onClick={onClose}>Annuler</button>
          <button className="btn btn-p" onClick={() => onSave(cfg)}>Sauvegarder</button>
        </div>
      </div>
    </div>
  );
}

/* ═══ CoverFlow View ═══ */
function CoverFlowView({ mangas, onSelect }) {
  const [idx, setIdx] = React.useState(0);
  const containerRef = React.useRef(null);

  React.useEffect(() => { setIdx(0); }, [mangas]);

  const go = (dir) => setIdx(i => Math.max(0, Math.min(mangas.length - 1, i + dir)));

  React.useEffect(() => {
    const h = (e) => {
      if (e.key === "ArrowLeft") go(-1);
      if (e.key === "ArrowRight") go(1);
      if (e.key === "Enter" && mangas[idx]) onSelect(mangas[idx]);
    };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  });

  if (!mangas.length) return <div className="empty"><p>Aucun manga.</p></div>;

  const visible = 7;
  const half = Math.floor(visible / 2);
  const m = mangas[idx];
  const meta = m?.metadata_json || {};
  const genres = (meta.Genres || "").split(/\s*[-,]\s*/).filter(Boolean).slice(0, 4);

  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", padding: "20px 0", userSelect: "none", flex: 1 }}>
      {/* Carousel */}
      <div ref={containerRef} style={{ display: "flex", alignItems: "center", justifyContent: "center", height: 320, width: "100%", position: "relative", overflow: "hidden" }}>
        <button onClick={() => go(-1)} style={{ position: "absolute", left: 10, zIndex: 10, background: "var(--c2)", border: "1px solid var(--brd)", borderRadius: "50%", width: 36, height: 36, color: "var(--t1)", cursor: "pointer", fontSize: 18 }}>‹</button>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 0, height: "100%", width: "100%" }}>
          {Array.from({ length: visible }, (_, vi) => {
            const mi = idx - half + vi;
            if (mi < 0 || mi >= mangas.length) return <div key={vi} style={{ width: 120, flexShrink: 0 }} />;
            const manga = mangas[mi];
            const diff = vi - half;
            const scale = 1 - Math.abs(diff) * 0.15;
            const opacity = 1 - Math.abs(diff) * 0.25;
            const zIndex = visible - Math.abs(diff);
            const isCurrent = diff === 0;
            return (
              <div key={manga.id} onClick={() => isCurrent ? onSelect(manga) : setIdx(mi)}
                style={{
                  width: isCurrent ? 180 : 120, height: isCurrent ? 270 : 180,
                  flexShrink: 0, cursor: "pointer", transition: "all .3s ease",
                  transform: `scale(${scale}) translateX(${diff * -10}px)`,
                  opacity, zIndex, position: "relative",
                  borderRadius: 10, overflow: "hidden",
                  boxShadow: isCurrent ? "0 8px 32px rgba(255,107,53,.3)" : "0 4px 16px rgba(0,0,0,.3)",
                  border: isCurrent ? "2px solid var(--ac)" : "1px solid var(--brd)",
                }}>
                <img
                  src={api.cbzFolderCoverUrl(manga.cbz_folder)}
                  alt="" loading="lazy"
                  style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
                  onError={e => {
                    const fb = manga.cover_url ? nautiljonMiniUrl(manga.cover_url) : "";
                    if (fb && !e.target.dataset.fb) { e.target.dataset.fb = "1"; e.target.src = fb; }
                    else e.target.style.opacity = ".2";
                  }}
                />
              </div>
            );
          })}
        </div>
        <button onClick={() => go(1)} style={{ position: "absolute", right: 10, zIndex: 10, background: "var(--c2)", border: "1px solid var(--brd)", borderRadius: "50%", width: 36, height: 36, color: "var(--t1)", cursor: "pointer", fontSize: 18 }}>›</button>
      </div>

      {/* Info */}
      <div style={{ textAlign: "center", marginTop: 16, maxWidth: 400 }}>
        <div style={{ fontSize: 18, fontWeight: 700, color: "var(--t1)", cursor: "pointer" }} onClick={() => onSelect(m)}>{m.title}</div>
        <div style={{ fontSize: 11, color: "var(--t3)", marginTop: 4 }}>{m.cbz_folder}</div>
        {genres.length > 0 && (
          <div style={{ display: "flex", justifyContent: "center", gap: 4, marginTop: 8, flexWrap: "wrap" }}>
            {genres.map((g, i) => <span key={i} className="genre-badge genre-badge-outline" style={{ color: tagColor(g), borderColor: tagColor(g) + "66", fontSize: 10, padding: "2px 8px" }}>{g}</span>)}
          </div>
        )}
        <div style={{ fontSize: 11, color: "var(--t3)", marginTop: 8, fontFamily: "monospace" }}>{idx + 1} / {mangas.length}</div>
      </div>
    </div>
  );
}

function AdminLibraryManager({ show, users, loadUsers }) {
  const [libs, setLibs] = useState([]);
  const [showForm, setShowForm] = useState(false);
  const [editLib, setEditLib] = useState(null);
  const [form, setForm] = useState({ name: "", cbz_path: "", is_public: true });
  const [accessLibId, setAccessLibId] = useState(null);
  const [accessUserIds, setAccessUserIds] = useState([]);
  const [err, setErr] = useState("");
  const [compareA, setCompareA] = useState(null);
  const [compareB, setCompareB] = useState(null);
  const [compareResult, setCompareResult] = useState(null);
  const [compareLoading, setCompareLoading] = useState(false);
  const [copyingFolder, setCopyingFolder] = useState(null);

  const loadLibs = async () => {
    try { setLibs(await api.adminGetLibraries()); } catch (e) { show(e.message); }
  };

  useEffect(() => { loadLibs(); loadUsers(); }, []); // eslint-disable-line

  const openCreate = () => { setEditLib(null); setForm({ name: "", cbz_path: "", is_public: true }); setErr(""); setShowForm(true); };
  const openEdit = (lib) => { setEditLib(lib); setForm({ name: lib.name, cbz_path: lib.cbz_path, is_public: !!lib.is_public }); setErr(""); setShowForm(true); };
  const saveLib = async () => {
    if (!form.name.trim()) { setErr("Nom requis"); return; }
    try {
      if (editLib) await api.adminUpdateLibrary(editLib.id, form);
      else await api.adminCreateLibrary(form);
      setShowForm(false);
      loadLibs();
      show(editLib ? "Modifié" : "Créée");
    } catch (e) { setErr(e.message); }
  };
  const delLib = async (lib) => {
    if (!window.confirm(`Supprimer « ${lib.name} » et tous ses mangas ?`)) return;
    try { await api.adminDeleteLibrary(lib.id); loadLibs(); show("Supprimée"); } catch (e) { show(e.message); }
  };
  const openAccess = async (lib) => {
    setAccessLibId(lib.id);
    try { const r = await api.adminGetLibraryAccess(lib.id); setAccessUserIds(r.user_ids || []); } catch {}
  };
  const saveAccess = async () => {
    try { await api.adminSetLibraryAccess(accessLibId, accessUserIds); setAccessLibId(null); loadLibs(); show("Accès sauvegardé"); } catch (e) { show(e.message); }
  };
  const toggleUser = (uid) => setAccessUserIds(ids => ids.includes(uid) ? ids.filter(i => i !== uid) : [...ids, uid]);

  const runCompare = async () => {
    if (!compareA || !compareB || compareA === compareB) { show("Sélectionnez 2 bibliothèques différentes"); return; }
    setCompareLoading(true);
    setCompareResult(null);
    try { setCompareResult(await api.adminCompareLibraries(compareA, compareB)); }
    catch (e) { show(e.message); }
    setCompareLoading(false);
  };

  const transferManga = async (folder, fromLib, toLib, dstFolder = null) => {
    setCopyingFolder(`${folder}::${dstFolder || ""}`);
    try {
      const r0 = await api.adminTransferManga(folder, fromLib, toLib, dstFolder);
      const copied = (r0.copied || []).length;
      show(copied > 0 ? `✅ ${copied} fichier(s) transféré(s)` : `✅ Rien à copier (déjà à jour)`);
      const r = await api.adminCompareLibraries(compareA, compareB);
      setCompareResult(r);
    } catch (e) { show(`❌ ${e.message}`); }
    setCopyingFolder(null);
  };

  const accessLib = libs.find(l => l.id === accessLibId);

  const FileChips = ({ entries }) => {
    const list = entries || [];
    if (list.length === 0) return <span style={{ fontSize: 10, color: "var(--t3)" }}>—</span>;
    const labelOf = (e) => typeof e === "string" ? e : (e.display || e.name || "");
    return (
      <div style={{ display: "flex", flexWrap: "wrap", gap: 4 }}>
        {list.slice(0, 18).map((e, idx) => {
          const lab = labelOf(e);
          const key = typeof e === "string" ? `${e}-${idx}` : (e.key || e.name || `${idx}`);
          return (
            <span key={key} style={{ fontSize: 10, color: "var(--t2)", padding: "2px 6px", border: "1px solid var(--brd)", borderRadius: 999, background: "var(--c2)" }}>{lab}</span>
          );
        })}
        {list.length > 18 && <span style={{ fontSize: 10, color: "var(--t3)" }}>+{list.length - 18}</span>}
      </div>
    );
  };

  return (
    <>
      <div className="sec-h"><span className="sec-t">Bibliothèques</span><button className="btn btn-p btn-s" style={{ marginLeft: "auto" }} onClick={openCreate}>+ Créer</button></div>
      <div style={{ display: "flex", flexDirection: "column", gap: 8, maxWidth: 700 }}>
        {libs.map(lib => (
          <div key={lib.id} style={{ padding: 12, background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: "var(--r)" }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 700, fontSize: 14, color: "var(--t1)" }}>{lib.name}</div>
                <div style={{ fontSize: 11, color: "var(--t3)", marginTop: 2 }}>{lib.cbz_path || "Chemin non défini"} — {lib.manga_count} manga(s)</div>
                <div style={{ marginTop: 4 }}>
                  {lib.is_public
                    ? <span className="badge bg" style={{ fontSize: 10 }}>Public</span>
                    : <span className="badge bb" style={{ fontSize: 10 }}>Restreint</span>}
                  {!lib.is_public && lib.user_ids?.length > 0 && (
                    <span style={{ fontSize: 10, color: "var(--t3)", marginLeft: 6 }}>{lib.user_ids.length} utilisateur(s) autorisé(s)</span>
                  )}
                </div>
              </div>
              <div style={{ display: "flex", gap: 4, flexShrink: 0 }}>
                <button className="btn btn-s" onClick={() => openEdit(lib)}>Modifier</button>
                <button className="btn btn-s" onClick={() => openAccess(lib)}>Accès</button>
                <button className="btn btn-s btn-d" onClick={() => delLib(lib)}>Suppr</button>
              </div>
            </div>
          </div>
        ))}
        {libs.length === 0 && <div className="empty"><p>Aucune bibliothèque.</p></div>}
      </div>

      {libs.length >= 2 && (
        <div style={{ marginTop: 24 }}>
          <div className="sec-h"><span className="sec-t">Comparer deux bibliothèques</span></div>
          <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap", marginBottom: 12 }}>
            <select value={compareA || ""} onChange={e => { setCompareA(Number(e.target.value) || null); setCompareResult(null); }} style={{ padding: "4px 8px", fontSize: 12, background: "var(--c2)", color: "var(--t1)", border: "1px solid var(--brd)", borderRadius: "var(--r)" }}>
              <option value="">— Bibliothèque A —</option>
              {libs.map(l => <option key={l.id} value={l.id}>{l.name}</option>)}
            </select>
            <span style={{ color: "var(--t3)" }}>vs</span>
            <select value={compareB || ""} onChange={e => { setCompareB(Number(e.target.value) || null); setCompareResult(null); }} style={{ padding: "4px 8px", fontSize: 12, background: "var(--c2)", color: "var(--t1)", border: "1px solid var(--brd)", borderRadius: "var(--r)" }}>
              <option value="">— Bibliothèque B —</option>
              {libs.filter(l => l.id !== compareA).map(l => <option key={l.id} value={l.id}>{l.name}</option>)}
            </select>
            <button className="btn btn-p btn-s" onClick={runCompare} disabled={compareLoading || !compareA || !compareB}>
              {compareLoading ? "…" : "Comparer"}
            </button>
          </div>

          {compareResult && (() => {
            const { lib_a, lib_b, rows } = compareResult;

            const needs = (rows || []).filter(r => r?.diff?.can_transfer_a_to_b).length;
            return (
              <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
                <div style={{ fontSize: 12, color: "var(--t3)" }}>
                  {needs > 0 ? (
                    <span>⚠ <b style={{ color: "var(--t1)" }}>{needs}</b> manga(s) à transférer de <b style={{ color: "var(--t1)" }}>{lib_a.name}</b> vers <b style={{ color: "var(--t1)" }}>{lib_b.name}</b></span>
                  ) : (
                    <span>✅ Aucun transfert nécessaire</span>
                  )}
                </div>

                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 120px", gap: 8, fontSize: 11, color: "var(--t3)" }}>
                  <div style={{ paddingLeft: 10 }}>🅰️ {lib_a.name}</div>
                  <div style={{ paddingLeft: 10 }}>🅱️ {lib_b.name}</div>
                  <div style={{ textAlign: "right", paddingRight: 10 }}>Transfert</div>
                </div>

                <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                  {(rows || []).map(r => {
                    const title = r?.a?.exists ? r.a.title : (r?.b?.title || r.key || "");
                    const disabled = !r?.diff?.can_transfer_a_to_b;
                    const srcFolder = r?.a?.folder || r.key || "";
                    const dstFolder = (r?.b?.exists && r?.b?.folder) ? r.b.folder : srcFolder;
                    const copyKey = `${srcFolder}::${dstFolder}`;
                    return (
                      <div key={r.key || copyKey} style={{ background: "var(--c1)", border: `1px solid ${disabled ? "var(--brd)" : "var(--ac)"}`, borderRadius: "var(--r)", overflow: "hidden" }}>
                        <div style={{ padding: "8px 10px", borderBottom: "1px solid var(--brd)", display: "flex", alignItems: "center", gap: 10 }}>
                          <div style={{ flex: 1, minWidth: 0 }}>
                            <div style={{ fontSize: 12, color: "var(--t1)", fontWeight: 700, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{title}</div>
                            <div style={{ fontSize: 10, color: "var(--t3)", marginTop: 2 }}>
                              🅰️ {srcFolder}{r?.b?.exists ? `  →  🅱️ ${dstFolder}` : ""}
                            </div>
                          </div>
                          <button
                            className={`btn btn-s ${disabled ? "" : "btn-p"}`}
                            style={{ width: 120, justifyContent: "center" }}
                            disabled={disabled || copyingFolder === copyKey || !r.a.exists}
                            onClick={() => transferManga(srcFolder, lib_a.id, lib_b.id, dstFolder)}
                          >{copyingFolder === copyKey ? "…" : "Transférer →"}</button>
                        </div>

                        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, padding: 10, background: "var(--c2)" }}>
                          <div style={{ background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: 10, padding: 10 }}>
                            <div style={{ fontSize: 10, color: "var(--t3)", marginBottom: 6 }}>{r.a.exists ? "Tomes/chapitres présents" : "—"}</div>
                            <FileChips entries={r.a.entries} />
                          </div>
                          <div style={{ background: "var(--c1)", border: "1px solid var(--brd)", borderRadius: 10, padding: 10 }}>
                            <div style={{ fontSize: 10, color: "var(--t3)", marginBottom: 6 }}>{r.b.exists ? "Tomes/chapitres présents" : "Manga absent"}</div>
                            <FileChips entries={r.b.entries} />
                          </div>
                        </div>

                        {!disabled && r.b.exists && (r.diff?.missing_in_b || []).length > 0 && (
                          <div style={{ padding: "8px 10px", fontSize: 10, color: "var(--t3)" }}>
                            Manquants dans <b style={{ color: "var(--t2)" }}>{lib_b.name}</b> : {r.diff.missing_in_b.join(", ")}
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              </div>
            );
          })()}
        </div>
      )}

      {showForm && (
        <div className="modal-ov" onClick={e => { if (e.target === e.currentTarget) setShowForm(false); }}>
          <div className="modal">
            <h2>{editLib ? `Modifier ${editLib.name}` : "Nouvelle bibliothèque"}</h2>
            <div className="fld"><label>Nom</label><input value={form.name} onChange={e => setForm(f => ({ ...f, name: e.target.value }))} /></div>
            <div className="fld"><label>Chemin CBZ</label><input value={form.cbz_path} onChange={e => setForm(f => ({ ...f, cbz_path: e.target.value }))} placeholder="/media/mangas" /></div>
            <div className="toggle-row">
              <div className="tl">Publique (visible par tous)</div>
              <button className={`toggle ${form.is_public ? "on" : ""}`} onClick={() => setForm(f => ({ ...f, is_public: !f.is_public }))} />
            </div>
            <div className="card-err">{err}</div>
            <div className="modal-ft"><button className="btn" onClick={() => setShowForm(false)}>Annuler</button><button className="btn btn-p" onClick={saveLib}>OK</button></div>
          </div>
        </div>
      )}

      {accessLibId != null && (
        <div className="modal-ov" onClick={e => { if (e.target === e.currentTarget) setAccessLibId(null); }}>
          <div className="modal">
            <h2>Accès — {accessLib?.name}</h2>
            <p style={{ fontSize: 12, color: "var(--t3)", marginBottom: 10 }}>
              {accessLib?.is_public ? "Cette bibliothèque est publique. Les restrictions ci-dessous ne s'appliquent que si vous la passez en mode restreint." : "Cochez les utilisateurs qui peuvent voir cette bibliothèque."}
            </p>
            <div style={{ display: "flex", flexDirection: "column", gap: 6, maxHeight: 260, overflowY: "auto" }}>
              {(users || []).filter(u => u.role !== "admin").map(u => (
                <div key={u.id} className="toggle-row">
                  <div className="tl">{u.username}</div>
                  <button className={`toggle ${accessUserIds.includes(u.id) ? "on" : ""}`} onClick={() => toggleUser(u.id)} />
                </div>
              ))}
              {(users || []).filter(u => u.role !== "admin").length === 0 && <p style={{ fontSize: 11, color: "var(--t3)" }}>Aucun utilisateur non-admin.</p>}
            </div>
            <div className="modal-ft"><button className="btn" onClick={() => setAccessLibId(null)}>Annuler</button><button className="btn btn-p" onClick={saveAccess}>Sauvegarder</button></div>
          </div>
        </div>
      )}
    </>
  );
}
