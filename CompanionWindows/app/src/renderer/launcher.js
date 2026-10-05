'use strict';
// Launch game picker: recents, a search over the whole library, and Browse. Everything that
// starts a game happens in the main process; this window only names what was chosen (a library
// id or a recents key) or asks for the native Browse dialog.
(() => {
  const $ = (id) => document.getElementById(id);
  const api = window.launcher;
  const KIND = { vr: 'VR', both: 'VR + desktop', flat: 'Desktop' };
  const MAX_RESULTS = 60;
  let state = null;
  let busy = false;

  function el(tag, props = {}, children = []) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === 'className') node.className = v;
      else if (k === 'text') node.textContent = v;
      else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v);
    }
    for (const c of children) if (c) node.append(c);
    return node;
  }

  function setStatus(text, isError = false) {
    $('status').textContent = text || '';
    $('status').classList.toggle('is-error', isError);
  }

  function renderMode(pcvrOn) {
    $('modeLamp').dataset.state = pcvrOn === 'on' ? 'live' : 'off';
    $('modeText').textContent = pcvrOn === 'on'
      ? 'PCVR is on: VR games start in the headset.'
      : pcvrOn === 'starting'
        ? 'PCVR is starting: VR games wait for the headset.'
        : 'Games start on the desktop.';
  }

  async function run(action) {
    if (busy) return;
    busy = true;
    document.body.setAttribute('aria-busy', 'true');
    for (const b of document.querySelectorAll('button')) b.disabled = true;
    setStatus('Starting…');
    try {
      await action();
      // On success the main process closes this window; a failure was already explained in a dialog.
      setStatus('');
    } catch (e) {
      setStatus(e && e.message ? e.message : String(e), true);
    } finally {
      busy = false;
      document.body.removeAttribute('aria-busy');
      for (const b of document.querySelectorAll('button')) b.disabled = false;
    }
  }

  function itemButton(name, detail, badge, onclick) {
    return el('button', { className: 'item', type: 'button', onclick }, [
      el('span', { className: 'item-text' }, [
        el('strong', { text: name }),
        detail ? el('small', { text: detail }) : null,
      ]),
      badge ? el('span', { className: 'badge', text: badge }) : null,
    ]);
  }

  function renderRecents() {
    const list = $('recents');
    list.replaceChildren();
    for (const r of state.recents) {
      list.append(el('li', {}, [
        itemButton(r.name, r.detail, null, () => run(() => api.launchRecent(r.key))),
        r.canShortcut ? el('button', {
          className: 'side', type: 'button', title: `Put a shortcut to ${r.name} on the desktop`,
          'aria-label': `Create a desktop shortcut for ${r.name}`,
          onclick: async () => {
            const made = await api.createShortcut(r.key);
            setStatus(made ? `Shortcut created: ${made}` : 'The shortcut could not be created.', !made);
          },
        }, [document.createTextNode('Shortcut')]) : null,
      ]));
    }
    $('recentsSection').classList.toggle('hidden', state.recents.length === 0);
  }

  /** Name prefix first, then word prefix, then anywhere — same ranking as game-launcher.js. */
  function search(q) {
    const query = q.trim().toLowerCase();
    if (!query) return [];
    const scored = [];
    for (const t of state.titles) {
      const name = t.name.toLowerCase();
      const at = name.indexOf(query);
      if (at < 0) continue;
      scored.push([at === 0 ? 0 : /[\s:\-_.]/.test(name[at - 1]) ? 1 : 2, name, t]);
    }
    scored.sort((a, b) => a[0] - b[0] || a[1].localeCompare(b[1]));
    return scored.slice(0, MAX_RESULTS).map((x) => x[2]);
  }

  function renderLibrary() {
    const show = state.libraryAvailable && state.titles.length > 0;
    $('librarySection').classList.toggle('hidden', !show);
    if (!show) return;
    const q = $('filter').value;
    const matches = search(q);
    const list = $('library');
    list.replaceChildren();
    for (const t of matches) {
      list.append(el('li', {}, [
        itemButton(t.name, KIND[t.kind] || '', t.optimised ? 'Optimised' : null,
          () => run(() => api.launchTitle(t.id))),
      ]));
    }
    list.classList.toggle('hidden', matches.length === 0);
    const empty = $('libraryEmpty');
    empty.classList.toggle('hidden', matches.length > 0);
    empty.textContent = q.trim()
      ? 'No games match.'
      : `Type to search ${state.titles.length} game${state.titles.length === 1 ? '' : 's'}.`;
  }

  async function refresh() {
    try {
      state = await api.getState();
    } catch (e) {
      setStatus(`Could not read the library: ${e.message}`, true);
      return;
    }
    if (!state) return;
    renderMode(state.pcvrOn);
    $('ask').checked = state.askBeforeLaunch;
    renderRecents();
    renderLibrary();
  }

  // Up/Down move between rows, so the picker works from the keyboard alone.
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { api.close(); return; }
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
    const items = [...document.querySelectorAll('.item')].filter((b) => b.offsetParent !== null);
    if (items.length === 0) return;
    const i = items.indexOf(document.activeElement);
    const next = e.key === 'ArrowDown'
      ? items[Math.min(i + 1, items.length - 1)]
      : i <= 0 ? $('filter') : items[i - 1];
    if (next) { e.preventDefault(); next.focus(); }
  });
  $('filter').addEventListener('input', renderLibrary);
  $('filter').addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    const first = document.querySelector('#library .item');
    if (first) first.click();
  });
  $('browse').addEventListener('click', () => run(() => api.browse()));
  $('close').addEventListener('click', () => api.close());
  $('ask').addEventListener('change', async (e) => {
    $('ask').checked = await api.setAskBeforeLaunch(e.target.checked);
  });
  api.onMode(({ pcvrOn }) => { if (state) { state.pcvrOn = pcvrOn; renderMode(pcvrOn); } });
  api.onRefresh(refresh);

  $('browse').focus();
  refresh();
})();
