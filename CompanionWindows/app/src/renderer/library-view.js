'use strict';
// Pure helpers for the Games tab: filtering, sorting, the default view, and the windowing maths
// that keeps a library of thousands of titles smooth (only the rows on screen exist in the DOM).
// A plain script in the sandboxed renderer (window.LibraryView) and a CommonJS module under
// `npm test` — no DOM in here.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.LibraryView = api;
}(typeof self !== 'undefined' ? self : this, () => {
  const KIND_LABEL = { vr: 'VR', flat: 'Desktop', both: 'VR + desktop' };
  const KIND_ORDER = { vr: 0, both: 1, flat: 2 };

  /** 'all' | 'vr' | 'flat'. "Both" titles belong to both filters. */
  function matchesKind(title, filter) {
    if (filter === 'vr') return title.kind === 'vr' || title.kind === 'both';
    if (filter === 'flat') return title.kind === 'flat' || title.kind === 'both';
    return true;
  }

  const time = (t) => (t.lastPlayed ? Date.parse(t.lastPlayed) || 0 : 0);
  const byName = (a, b) => String(a.name).localeCompare(String(b.name), undefined, { sensitivity: 'base' });

  const SORTS = {
    name: byName,
    played: (a, b) => time(b) - time(a) || byName(a, b),
    size: (a, b) => (b.sizeBytes || 0) - (a.sizeBytes || 0) || byName(a, b),
    kind: (a, b) => KIND_ORDER[a.kind] - KIND_ORDER[b.kind] || byName(a, b),
  };

  /** The titles to show, in order. Never mutates its input. */
  function visibleTitles(titles, { query = '', kind = 'all', sort = 'name' } = {}) {
    const q = String(query).trim().toLowerCase();
    const out = (titles || []).filter((t) => matchesKind(t, kind)
      && (!q || String(t.name).toLowerCase().includes(q)));
    return out.sort(SORTS[sort] || SORTS.name);
  }

  /** Grid when most of the library is VR (box art is what the PCVR gallery is about), else list. */
  function defaultView(titles) {
    if (!titles || titles.length === 0) return 'grid';
    const vr = titles.filter((t) => t.kind === 'vr' || t.kind === 'both').length;
    return vr * 2 >= titles.length ? 'grid' : 'list';
  }

  /**
   * Which items to render for a scroll position. Rows of `columns` items, each row `rowHeight`
   * tall; `overscan` rows either side so fast scrolling does not show blanks.
   */
  function windowFor({ count, columns = 1, rowHeight, scrollTop, viewportHeight, overscan = 4 }) {
    const cols = Math.max(1, columns | 0);
    const rows = Math.ceil(count / cols);
    const firstRow = Math.max(0, Math.floor(scrollTop / rowHeight) - overscan);
    const lastRow = Math.min(rows, Math.ceil((scrollTop + viewportHeight) / rowHeight) + overscan);
    return {
      start: Math.min(count, firstRow * cols),
      end: Math.min(count, lastRow * cols),
      totalHeight: rows * rowHeight,
      offsetTop: firstRow * rowHeight,
      columns: cols,
    };
  }

  /** How many grid columns fit. */
  function gridColumns(width, minTile, gap) {
    return Math.max(1, Math.floor((width + gap) / (minTile + gap)));
  }

  function formatSize(bytes) {
    if (!bytes) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let v = bytes;
    let i = 0;
    while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
    return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
  }

  /** "Today", "Yesterday", "3 days ago", or a date; '' for never. */
  function formatPlayed(iso, now = Date.now()) {
    const t = iso ? Date.parse(iso) : NaN;
    if (!Number.isFinite(t)) return '';
    const day = 86400000;
    const startOfToday = new Date(now); startOfToday.setHours(0, 0, 0, 0);
    if (t >= startOfToday.getTime()) return 'Today';
    if (t >= startOfToday.getTime() - day) return 'Yesterday';
    const days = Math.floor((startOfToday.getTime() - t) / day) + 1;
    if (days < 30) return `${days} days ago`;
    return new Date(t).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  }

  return {
    KIND_LABEL, matchesKind, visibleTitles, defaultView, windowFor, gridColumns, formatSize, formatPlayed,
  };
}));
