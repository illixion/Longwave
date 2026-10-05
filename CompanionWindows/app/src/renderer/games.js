'use strict';
// Games tab: the public game library (VR and desktop) in a grid of box art or a list. Both are
// windowed — only the rows on screen exist in the DOM — so a library of thousands of titles
// scrolls as smoothly as one of ten. Pure maths in library-view.js; this file is the DOM.
(() => {
  const $ = (id) => document.getElementById(id);
  const LV = window.LibraryView;
  const api = window.hotspot;
  const LIST_ROW = 40;          // must match .lib-row height
  const TILE_MIN = 136;         // min grid tile width
  const TILE_GAP = 12;
  const VIEW_KEY = 'longwave.games.view';
  const SORT_KEY = 'longwave.games.sort';

  let titles = [];
  let visible = [];
  let selectedId = null;
  let kindFilter = 'all';
  let viewMode = null;          // 'grid' | 'list'; null until the first load picks a default
  let loading = false;
  let loadedOnce = false;
  let frame = 0;

  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* per-viewer convenience only */ } },
  };

  const el = {
    search: $('libSearch'), sort: $('libSort'), add: $('libAdd'), refresh: $('libRefresh'),
    count: $('libCount'), scroller: $('libScroller'), spacer: $('libSpacer'), empty: $('libEmpty'),
    detail: $('libDetail'), dArt: $('libDetailArt'), dName: $('libDetailName'), dMeta: $('libDetailMeta'),
    launch: $('libLaunch'), launchWhere: $('libLaunchWhere'), shortcut: $('libShortcut'),
    kind: $('libKind'), exposedRow: $('libExposedRow'), exposed: $('libExposed'), exposedHint: $('libExposedHint'),
    optimizedRow: $('libOptimizedRow'), optimized: $('libOptimized'), optimizedNote: $('libOptimizedNote'),
    remove: $('libRemove'), msg: $('libMsg'),
  };

  function setMsg(text, isError = false) {
    el.msg.textContent = text || '';
    el.msg.classList.toggle('is-error', isError);
  }

  const errText = (e) => String(e && e.message ? e.message : e)
    .replace(/^Error invoking remote method '[^']+': (Error: )?/, '').replace(/^[a-zA-Z]+: /, '');

  // ---- Art: fetched lazily for what is on screen, cached as data: URLs ----
  const artUrls = new Map();
  const artPending = new Map();
  function art(path) {
    if (!path) return Promise.resolve(null);
    if (artUrls.has(path)) return Promise.resolve(artUrls.get(path));
    if (!artPending.has(path)) {
      artPending.set(path, api.gameArt(path).then((url) => {
        artPending.delete(path);
        if (artUrls.size > 600) artUrls.delete(artUrls.keys().next().value);
        artUrls.set(path, url);
        return url;
      }).catch(() => { artPending.delete(path); return null; }));
    }
    return artPending.get(path);
  }

  function attachArt(container, path) {
    art(path).then((url) => {
      if (!url || !container.isConnected) return;
      const img = document.createElement('img');
      img.alt = '';
      img.decoding = 'async';
      img.addEventListener('load', () => container.classList.add('has-art'));
      img.addEventListener('error', () => img.remove());
      img.src = url;
      container.prepend(img);
    });
  }

  // ---- Data ----
  async function load(refresh = false) {
    if (loading) return;
    loading = true;
    el.count.textContent = loadedOnce ? el.count.textContent : 'Reading the library…';
    try {
      titles = (await api.libraryList(refresh)) || [];
      loadedOnce = true;
      setMsg('');
    } catch (e) {
      const text = errText(e);
      setMsg(text.includes('not connected')
        ? 'Waiting for the Companion service — the library will load by itself.'
        : `Could not read the library: ${text}`, !text.includes('not connected'));
    } finally {
      loading = false;
    }
    if (!viewMode) setViewMode(store.get(VIEW_KEY) || LV.defaultView(titles), false);
    apply();
  }

  function replaceTitle(updated) {
    if (!updated) return;
    const i = titles.findIndex((t) => t.id === updated.id);
    if (i >= 0) titles[i] = updated; else titles.push(updated);
  }

  function apply() {
    visible = LV.visibleTitles(titles, { query: el.search.value, kind: kindFilter, sort: el.sort.value });
    const vr = titles.filter((t) => t.kind !== 'flat').length;
    const exposed = titles.filter((t) => t.exposed && t.kind !== 'flat').length;
    el.count.textContent = titles.length === 0 && !loadedOnce ? el.count.textContent
      : `${titles.length} games · ${vr} VR · ${exposed} on the headset`
        + (visible.length !== titles.length ? ` · showing ${visible.length}` : '');
    el.empty.classList.toggle('hidden', visible.length > 0);
    el.empty.textContent = titles.length === 0
      ? 'No games yet. Steam games appear by themselves; add anything else with "Add a game…".'
      : 'Nothing matches.';
    el.scroller.scrollTop = Math.min(el.scroller.scrollTop, Math.max(0, layout().totalHeight - el.scroller.clientHeight));
    render(true);
    renderDetail();
  }

  // ---- Windowed rendering ----
  function layout() {
    const width = el.scroller.clientWidth - 24;
    if (viewMode === 'grid') {
      const columns = LV.gridColumns(width, TILE_MIN, TILE_GAP);
      const tileWidth = (width - (columns - 1) * TILE_GAP) / columns;
      const rowHeight = Math.round(tileWidth * 1.5) + TILE_GAP;
      return { columns, rowHeight, ...LV.windowFor({ count: visible.length, columns, rowHeight,
        scrollTop: el.scroller.scrollTop, viewportHeight: el.scroller.clientHeight, overscan: 2 }) };
    }
    return { columns: 1, rowHeight: LIST_ROW, ...LV.windowFor({ count: visible.length, rowHeight: LIST_ROW,
      scrollTop: el.scroller.scrollTop, viewportHeight: el.scroller.clientHeight, overscan: 8 }) };
  }

  let lastWindow = '';
  function render(force = false) {
    const w = layout();
    el.spacer.style.height = `${w.totalHeight + (viewMode === 'grid' ? 12 : 0)}px`;
    const key = `${viewMode}:${w.start}:${w.end}:${w.columns}:${visible.length}`;
    if (!force && key === lastWindow) return;
    lastWindow = key;

    const win = document.createElement('div');
    win.className = 'lib-window';
    win.style.top = `${w.offsetTop + (viewMode === 'grid' ? 12 : 0)}px`;
    if (viewMode === 'grid') {
      for (let i = w.start; i < w.end; i += w.columns) {
        const row = document.createElement('div');
        row.className = 'lib-grid-row';
        row.style.gridTemplateColumns = `repeat(${w.columns}, minmax(0, 1fr))`;
        row.style.height = `${w.rowHeight - TILE_GAP}px`;
        row.style.marginBottom = `${TILE_GAP}px`;
        for (let j = i; j < Math.min(i + w.columns, w.end); j++) row.append(tile(visible[j], j));
        win.append(row);
      }
    } else {
      for (let i = w.start; i < w.end; i++) win.append(listRow(visible[i], i));
    }
    el.spacer.replaceChildren(win);
  }

  function lamp(t) {
    const s = document.createElement('span');
    s.className = 'lib-lamp' + (t.exposed && t.kind !== 'flat' ? ' is-exposed' : '');
    s.title = t.exposed && t.kind !== 'flat' ? 'On the headset' : '';
    return s;
  }

  function common(node, t, i) {
    node.dataset.id = t.id;
    node.dataset.index = String(i);
    node.setAttribute('role', 'option');
    node.setAttribute('aria-selected', String(t.id === selectedId));
    node.classList.toggle('is-selected', t.id === selectedId);
    node.addEventListener('click', () => select(t.id));
    node.addEventListener('dblclick', () => launch(t));
    return node;
  }

  function tile(t, i) {
    const d = document.createElement('div');
    d.className = 'lib-tile';
    const ph = document.createElement('div');
    ph.className = 'lib-tile-placeholder';
    ph.textContent = (t.name || '?').trim().charAt(0).toUpperCase();
    const cap = document.createElement('div');
    cap.className = 'lib-tile-caption';
    const name = document.createElement('span');
    name.textContent = t.name;
    cap.append(name);
    if (t.kind !== 'flat') cap.append(badge(t.kind === 'vr' ? 'VR' : 'VR+'));
    d.append(ph, cap, lamp(t));
    d.title = t.name;
    attachArt(d, t.portraitArt || t.landscapeArt);
    return common(d, t, i);
  }

  function badge(text) {
    const b = document.createElement('span');
    b.className = 'lib-badge';
    b.textContent = text;
    return b;
  }

  function listRow(t, i) {
    const r = document.createElement('div');
    r.className = 'lib-row';
    const name = document.createElement('span');
    name.className = 'lib-row-name';
    const strong = document.createElement('strong');
    strong.textContent = t.name;
    name.append(lamp(t), strong);
    if (t.optimizedAvailable && t.optimized) name.append(badge('Optimised'));
    const kind = document.createElement('span');
    kind.textContent = LV.KIND_LABEL[t.kind] || '';
    const played = document.createElement('span');
    played.textContent = LV.formatPlayed(t.lastPlayed) || '—';
    const size = document.createElement('span');
    size.className = 'num';
    size.textContent = LV.formatSize(t.sizeBytes);
    r.append(name, kind, played, size);
    return common(r, t, i);
  }

  // ---- Selection, keyboard ----
  function select(id, { scroll = false } = {}) {
    selectedId = id;
    for (const n of el.spacer.querySelectorAll('[data-id]')) {
      const on = n.dataset.id === id;
      n.classList.toggle('is-selected', on);
      n.setAttribute('aria-selected', String(on));
    }
    if (scroll) scrollToIndex(visible.findIndex((t) => t.id === id));
    renderDetail();
  }

  function scrollToIndex(i) {
    if (i < 0) return;
    const w = layout();
    const top = Math.floor(i / w.columns) * w.rowHeight;
    if (top < el.scroller.scrollTop) el.scroller.scrollTop = top;
    else if (top + w.rowHeight > el.scroller.scrollTop + el.scroller.clientHeight) {
      el.scroller.scrollTop = top + w.rowHeight - el.scroller.clientHeight;
    }
    render();
  }

  el.scroller.addEventListener('keydown', (e) => {
    if (visible.length === 0) return;
    const cols = layout().columns;
    const i = Math.max(0, visible.findIndex((t) => t.id === selectedId));
    const step = { ArrowDown: cols, ArrowUp: -cols, ArrowRight: viewMode === 'grid' ? 1 : 0,
      ArrowLeft: viewMode === 'grid' ? -1 : 0, PageDown: cols * 10, PageUp: -cols * 10 }[e.key];
    if (e.key === 'Enter' && selectedId) {
      e.preventDefault();
      const t = visible[i];
      if (t) launch(t);
      return;
    }
    let next = null;
    if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = visible.length - 1;
    else if (step) next = selectedId ? i + step : 0;
    if (next === null) return;
    e.preventDefault();
    next = Math.max(0, Math.min(visible.length - 1, next));
    select(visible[next].id, { scroll: true });
  });

  el.scroller.addEventListener('scroll', () => {
    if (frame) return;
    frame = requestAnimationFrame(() => { frame = 0; render(); });
  }, { passive: true });
  new ResizeObserver(() => render(true)).observe(el.scroller);

  // ---- Detail pane ----
  function renderDetail() {
    const t = titles.find((x) => x.id === selectedId);
    el.detail.classList.toggle('hidden', !t);
    if (!t) return;
    el.dName.textContent = t.name;
    el.dMeta.textContent = [
      LV.KIND_LABEL[t.kind] + (t.kindOverridden ? ' (your choice)' : ''),
      t.source === 'steam' ? 'Steam' : t.linkedSteamAppId ? `Added by you, runs as Steam app ${t.linkedSteamAppId}` : 'Added by you',
      LV.formatSize(t.sizeBytes),
      t.lastPlayed ? `Played ${LV.formatPlayed(t.lastPlayed).toLowerCase()}` : 'Never played',
    ].filter(Boolean).join(' · ');
    el.dArt.replaceChildren();
    attachArt(el.dArt, t.landscapeArt || t.portraitArt);
    el.launchWhere.textContent = t.kind === 'flat' ? 'Starts on the desktop.'
      : 'Starts in VR while PCVR is on, otherwise on the desktop.';
    el.kind.value = t.kindOverridden ? t.kind : '';
    el.kind.options[0].textContent = `As detected (${LV.KIND_LABEL[t.detectedKind] || 'Desktop'})`;
    const vrCapable = t.kind !== 'flat';
    el.exposed.checked = Boolean(t.exposed) && vrCapable;
    el.exposed.disabled = !vrCapable;
    el.exposedHint.textContent = vrCapable ? 'In the PCVR game gallery on Vision Pro'
      : 'Only VR games can be shown on the headset for now';
    el.optimizedRow.classList.toggle('hidden', !t.optimizedAvailable);
    el.optimized.checked = Boolean(t.optimized);
    el.optimizedNote.textContent = t.optimizedNote || '';
    el.remove.classList.toggle('hidden', t.source !== 'custom');
  }

  const selected = () => titles.find((x) => x.id === selectedId);

  async function launch(t) {
    setMsg(`Starting ${t.name}…`);
    try {
      const ok = await api.libraryLaunch(t.id);
      setMsg(ok ? `Started ${t.name}.` : '');
      if (ok) load();
    } catch (e) {
      setMsg(`Could not start ${t.name}: ${errText(e)}`, true);
    }
  }

  el.launch.addEventListener('click', () => { const t = selected(); if (t) launch(t); });
  el.shortcut.addEventListener('click', async () => {
    const t = selected();
    if (!t) return;
    try {
      const made = await api.libraryCreateShortcut(t.id);
      setMsg(made ? `Desktop shortcut created: ${made}` : 'The shortcut could not be created.', !made);
    } catch (e) { setMsg(`The shortcut could not be created: ${errText(e)}`, true); }
  });
  el.kind.addEventListener('change', async () => {
    const t = selected();
    if (!t) return;
    try {
      replaceTitle(await api.librarySetKind(t.id, el.kind.value || null));
      apply();
    } catch (e) { setMsg(`Could not save: ${errText(e)}`, true); }
  });
  el.exposed.addEventListener('change', async () => {
    const t = selected();
    if (!t) return;
    const ids = new Set(titles.filter((x) => x.exposed).map((x) => x.id));
    if (el.exposed.checked) ids.add(t.id); else ids.delete(t.id);
    try {
      titles = (await api.librarySetExposed([...ids])) || titles;
      apply();
    } catch (e) {
      el.exposed.checked = !el.exposed.checked;
      setMsg(`Could not save: ${errText(e)}`, true);
    }
  });
  el.optimized.addEventListener('change', async () => {
    const t = selected();
    if (!t) return;
    try {
      titles = (await api.librarySetOptimized(t.id, el.optimized.checked)) || titles;
      apply();
    } catch (e) {
      el.optimized.checked = !el.optimized.checked;
      setMsg(`Could not save: ${errText(e)}`, true);
    }
  });
  el.remove.addEventListener('click', async () => {
    const t = selected();
    if (!t) return;
    try {
      await api.libraryRemoveCustom(t.id);
      titles = titles.filter((x) => x.id !== t.id);
      selectedId = null;
      setMsg(`Removed ${t.name} from the library.`);
      apply();
    } catch (e) { setMsg(`Could not remove: ${errText(e)}`, true); }
  });
  el.add.addEventListener('click', async () => {
    try {
      const added = await api.libraryAdd();
      if (!added) return;
      replaceTitle(added);
      selectedId = added.id;
      el.search.value = '';
      apply();
      select(added.id, { scroll: true });
      setMsg(`${added.name} is in the library.`);
    } catch (e) { setMsg(`Could not add that game: ${errText(e)}`, true); }
  });
  el.refresh.addEventListener('click', () => load(true));

  // ---- Toolbar ----
  function setViewMode(mode, remember = true) {
    viewMode = mode === 'list' ? 'list' : 'grid';
    if (remember) store.set(VIEW_KEY, viewMode);
    for (const b of document.querySelectorAll('[data-view-mode]')) {
      const on = b.dataset.viewMode === viewMode;
      b.classList.toggle('is-on', on);
      b.setAttribute('aria-pressed', String(on));
    }
    el.scroller.dataset.mode = viewMode;
  }
  for (const b of document.querySelectorAll('[data-view-mode]')) {
    b.addEventListener('click', () => { setViewMode(b.dataset.viewMode); apply(); });
  }
  for (const b of document.querySelectorAll('[data-kind]')) {
    b.addEventListener('click', () => {
      kindFilter = b.dataset.kind;
      for (const o of document.querySelectorAll('[data-kind]')) {
        o.classList.toggle('is-on', o === b);
        o.setAttribute('aria-pressed', String(o === b));
      }
      apply();
    });
  }
  el.sort.value = store.get(SORT_KEY) || 'name';
  el.sort.addEventListener('change', () => { store.set(SORT_KEY, el.sort.value); apply(); });
  el.search.addEventListener('input', apply);
  el.search.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown' && visible.length) {
      e.preventDefault();
      select(visible[0].id, { scroll: true });
      el.scroller.focus();
    }
  });

  // The shell calls this each time the tab is opened: a rescan touches the disk, so it happens
  // when someone is looking, and the backend's own short cache keeps a quick revisit cheap.
  window.GamesTab = {
    shown() { load(); },
    connected(isUp) { if (isUp && !loadedOnce) load(); },
  };
})();
