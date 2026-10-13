/* CleanIT for macOS - web UI. Derived from ../../web/app.js (Windows); talks to the Swift engine through
   window.webkit.messageHandlers.api instead of HTTP. ASCII-only source. */
'use strict';
window.addEventListener('error', e => { try { window.webkit.messageHandlers.api.postMessage({ path: '/api/jserror', body: JSON.stringify({ text: e.message + ' @ ' + e.lineno }) }); } catch (x) {} });

// ---------------------------------------------------------------------------
// Tiny DOM helpers (all text goes through textContent - never innerHTML with data)
// ---------------------------------------------------------------------------
const $ = (s, el) => (el || document).querySelector(s);
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v === null || v === undefined || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k === 'style') el.style.cssText = v;   // CSSOM, allowed by the page's strict CSP (style attributes are not)
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else if (k === 'checked' || k === 'disabled' || k === 'value' || k === 'selected') el[k] = v;
      else el.setAttribute(k, v === true ? '' : v);
    }
  }
  add(el, kids);
  return el;
}
function add(el, kids) {
  for (const k of kids) {
    if (k === null || k === undefined || k === false) continue;
    if (Array.isArray(k)) add(el, k);
    else el.append(k instanceof Node ? k : document.createTextNode(String(k)));
  }
}
const ICONS = {
  home: 'M3 11l9-8 9 8v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z',
  clean: 'M14 3l7 7-8 8H6v-7zM4 21h16M9 14l3 3',
  disk: 'M4 6c0-1.7 3.6-3 8-3s8 1.3 8 3v12c0 1.7-3.6 3-8 3s-8-1.3-8-3zM4 6c0 1.7 3.6 3 8 3s8-1.3 8-3M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3',
  startup: 'M12 3v9M6.3 7.3a8 8 0 1 0 11.4 0',
  apps: 'M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z',
  updates: 'M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5',
  privacy: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6zM9 12l2 2 4-4',
  security: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z',
  health: 'M3 12h4l2-5 4 10 2-5h6',
  fleet: 'M3 5h8v6H3zM13 5h8v6h-8zM8 15h8v6H8zM7 11v2h10v-2M12 13v2',
  settings: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
  folder: 'M3 6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z',
  chip: 'M7 7h10v10H7zM10 10h4v4h-4zM9 3v4M15 3v4M9 17v4M15 17v4M3 9h4M3 15h4M17 9h4M17 15h4',
  file: 'M6 3h8l5 5v13H6zM14 3v5h5',
  cloud: 'M7 18a5 5 0 1 1 .9-9.9A6 6 0 0 1 19 10a4 4 0 0 1 0 8z'
};
function icon(name) {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('fill', 'none'); svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.8'); svg.setAttribute('stroke-linecap', 'round'); svg.setAttribute('stroke-linejoin', 'round');
  const p = document.createElementNS(ns, 'path'); p.setAttribute('d', ICONS[name] || ''); svg.append(p);
  return svg;
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------
function fmtSize(b) {
  b = Number(b);
  if (!(b >= 0)) return 'n/a';
  const u = [['TB', 1099511627776, 2], ['GB', 1073741824, 2], ['MB', 1048576, 1], ['KB', 1024, 0]];
  for (const [n, s, d] of u) if (b >= s) return (b / s).toFixed(d) + ' ' + n;
  return b + ' B';
}
function fmtNum(n) { return Number(n || 0).toLocaleString(); }
function fmtAgo(iso) {
  if (!iso) return 'never';
  const t = new Date(iso).getTime();
  if (isNaN(t)) return String(iso);
  const s = (Date.now() - t) / 1000;
  if (s < 90) return 'just now';
  if (s < 3600) return Math.round(s / 60) + ' min ago';
  if (s < 86400) return Math.round(s / 3600) + ' h ago';
  const d = Math.floor(s / 86400);
  return d + (d === 1 ? ' day ago' : ' days ago');
}
function baseName(p) { const i = p.lastIndexOf('/'); return i >= 0 && p.length > 1 ? p.slice(i + 1) : p; }
function dirName(p) { const i = p.lastIndexOf('/'); return i > 0 ? p.slice(0, i) : '/'; }
function tilde(p) { const home = S.state && S.state.userProfile; return home && p.startsWith(home) ? '~' + p.slice(home.length) : p; }
function scoreColor(s) { return s >= 85 ? 'var(--ok)' : s >= 65 ? 'var(--warn)' : 'var(--bad)'; }

// ---------------------------------------------------------------------------
// Server API
// ---------------------------------------------------------------------------
async function api(path, body) {
  // The Swift side replies with a JSON string, or rejects with an error message.
  let r;
  try { r = await window.webkit.messageHandlers.api.postMessage({ path, body: body === undefined ? null : JSON.stringify(body) }); }
  catch (e) { throw new Error(String(e && e.message || e).replace(/^Error: /, '')); }
  return JSON.parse(r);
}
function offline(expired, title, text) {
  if (S.offline) return;
  S.offline = true;
  document.body.replaceChildren(h('div', { class: 'empty', style: 'padding-top:20vh' },
    h('h2', {}, title || (expired ? 'This window has expired' : 'CleanIT has stopped')),
    h('p', {}, text || 'Quit CleanIT and open it again.')));
}
// Runs a server action as a background job and resolves with its result.
async function run(action, args, onProgress) {
  const { jobId } = await api('/api/run', { action, args: args || {} });
  pingSoon();
  return new Promise((resolve, reject) => {
    const tick = async () => {
      try {
        const j = await api('/api/jobs/' + jobId);
        if (j.status === 'running') { if (onProgress) onProgress(j); setTimeout(tick, 450); }
        else if (j.status === 'done') { pingSoon(); resolve(j.result); }
        else { pingSoon(); reject(new Error(j.error || 'Failed')); }
      } catch (e) { reject(e); }
    };
    setTimeout(tick, 250);
  });
}
async function saveSettings(patch) {
  S.state.settings = await api('/api/settings', patch);
}
function openThing(what, extra) { return api('/api/open', Object.assign({ what }, extra || {})).catch(e => toast(e.message, 'error')); }

// ---------------------------------------------------------------------------
// App state + rendering
// ---------------------------------------------------------------------------
const S = { page: 'dashboard', state: null, busy: {}, failed: {}, cache: {}, sel: {}, tab: {}, progress: {} };
const pages = {};
const NAV = [
  ['dashboard', 'Dashboard', 'home'], ['clean', 'Clean', 'clean'], ['disk', 'Disk', 'disk'], ['startup', 'Startup', 'startup'],
  ['apps', 'Apps', 'apps'], ['updates', 'Updates', 'updates'], ['security', 'Security', 'security'],
  ['health', 'Health', 'health'], ['settings', 'Settings', 'settings']
];

function go(page) { S.page = page; location.hash = page; render(); }
function render() {
  if (S.offline) return;
  const nav = $('#nav-items');
  nav.replaceChildren(...NAV.map(([id, label, ic]) => {
    const badge = id === 'dashboard' && S.cache.dash ? S.cache.dash.Issues.filter(i => i.Level === 'BAD').length : 0;
    return h('button', { class: 'nav-btn' + (S.page === id ? ' active' : ''), type: 'button', onclick: () => go(id) },
      icon(ic), label, badge ? h('span', { class: 'badge', text: String(badge) }) : null);
  }));
  const p = pages[S.page] || pages.dashboard;
  $('#page-title').textContent = p.title;
  const root = h('div');
  try { p.render(root); } catch (e) { root.append(h('div', { class: 'notice warn', text: 'Something went wrong: ' + e.message })); console.error(e); }
  const scroll = $('#page').scrollTop;
  $('#page').replaceChildren(root);
  $('#page').scrollTop = scroll;
}
// Wraps an async action: marks it busy (spinner, buttons disabled), re-renders, reports errors.
async function task(key, fn) {
  if (S.busy[key]) return;
  S.busy[key] = true; S.failed[key] = false; render();
  try { return await fn(); }
  catch (e) { S.failed[key] = true; toast(e.message, 'error'); }
  finally { S.busy[key] = false; S.progress[key] = null; render(); }
}
// Pages load their data automatically once. After a failure they wait for the user to click again
// (otherwise every re-render would retry and stack up error messages).
const queued = {};
function autoLoad(key, fn) {
  if (S.busy[key] || S.failed[key] || queued[key]) return;
  queued[key] = true;
  setTimeout(() => { queued[key] = false; fn(); });
}
function prog(key) { return j => { S.progress[key] = j.statusText || (j.progress >= 0 ? j.progress + '%' : ''); const el = document.getElementById('prog-' + key); if (el) el.textContent = S.progress[key]; }; }
function progLine(key) { return S.busy[key] ? h('div', { class: 'muted small', id: 'prog-' + key, text: S.progress[key] || 'Working...' }) : null; }

function btn(label, onclick, cls, busyKey, disabled) {
  const busy = busyKey && S.busy[busyKey];
  return h('button', { class: 'btn ' + (cls || ''), type: 'button', onclick, disabled: busy || disabled },
    busy ? h('span', { class: 'spin' }) : null, label);
}
function toggle(checked, onchange, disabled) {
  return h('label', { class: 'switch' }, h('input', { type: 'checkbox', checked, disabled, onchange: e => onchange(e.target.checked) }), h('span'));
}
function checkbox(label, checked, onchange) {
  return h('label', { class: 'check' }, h('input', { type: 'checkbox', checked, onchange: e => onchange(e.target.checked) }), label);
}
function tabs(key, list) {
  const cur = S.tab[key] || list[0][0];
  return h('div', { class: 'tabs' }, list.map(([id, label]) =>
    h('button', { class: 'tab' + (cur === id ? ' active' : ''), type: 'button', onclick: () => { S.tab[key] = id; render(); } }, label)));
}
function curTab(key, def) { return S.tab[key] || def; }
function toast(msg, kind) {
  // the same message twice within a few seconds is shown once
  const now = Date.now();
  if (S.lastToast && S.lastToast.msg === msg && now - S.lastToast.at < 5000) return;
  S.lastToast = { msg, at: now };
  const t = h('div', { class: 'toast ' + (kind || ''), text: msg });
  $('#toasts').append(t);
  setTimeout(() => t.remove(), kind === 'error' ? 8000 : 4500);
}

// Modal dialog. buttons: [{id, text, cls}] -> resolves with the clicked id (or null)
function dialog(title, body, buttons, wide) {
  return new Promise(resolve => {
    const close = id => { back.remove(); document.removeEventListener('keydown', esc); resolve(id); };
    const esc = e => { if (e.key === 'Escape') close(null); };
    document.addEventListener('keydown', esc);
    const back = h('div', { class: 'backdrop', onclick: e => { if (e.target === back) close(null); } },
      h('div', { class: 'modal' + (wide ? ' wide' : ''), role: 'dialog' },
        h('header', { text: title }),
        h('div', { class: 'body' }, body),
        h('footer', {}, buttons.map(b => h('button', { class: 'btn ' + (b.cls || ''), type: 'button', onclick: () => close(b.id) }, b.text)))));
    $('#modal-root').append(back);
    const prim = back.querySelector('.btn.primary, .btn.danger'); if (prim) prim.focus();
  });
}
async function confirmBox(title, body, okText, danger) {
  return (await dialog(title, body, [{ id: 'no', text: 'Cancel' }, { id: 'ok', text: okText || 'OK', cls: danger ? 'danger' : 'primary' }])) === 'ok';
}
function bullets(items, max) {
  max = max || 20;
  const list = h('ul', {}, items.slice(0, max).map(t => h('li', {}, t)));
  if (items.length > max) list.append(h('li', { class: 'muted', text: '... and ' + (items.length - max) + ' more' }));
  return list;
}

// macOS has no restore points: files CleanIT removes go to the Trash, startup changes can be undone.
async function restorePointChoice() { return false; }

// ---------------------------------------------------------------------------
// Data table: columns [{key,label,render,sort,cls,nosort}], rows, optional checkboxes + groups
// ---------------------------------------------------------------------------
function table(opts) {
  const { columns, rows, selKey, rowKey, groupBy, groupLabel, onRow, onDbl, selectedKey, empty } = opts;
  const sortKey = 'sort:' + (opts.id || '');
  const sort = S.tab[sortKey];
  let data = rows.slice();
  if (sort) {
    const col = columns.find(c => c.key === sort.key);
    const val = col && (col.sort || (r => r[col.key]));
    if (val) data.sort((a, b) => { const x = val(a), y = val(b); const r = (typeof x === 'number' && typeof y === 'number') ? x - y : String(x).localeCompare(String(y)); return sort.desc ? -r : r; });
  }
  const sel = selKey ? (S.sel[selKey] = S.sel[selKey] || new Set()) : null;
  const head = h('tr', {},
    sel ? h('th', { class: 'cb nosort' }, h('input', { type: 'checkbox', checked: rows.length > 0 && rows.every(r => sel.has(rowKey(r))),
      onchange: e => { rows.forEach(r => e.target.checked ? sel.add(rowKey(r)) : sel.delete(rowKey(r))); render(); } })) : null,
    columns.map(c => h('th', { class: (c.cls || '') + (c.nosort ? ' nosort' : ''), style: c.width ? 'width:' + c.width : null,
      onclick: c.nosort ? null : () => { const s = S.tab[sortKey]; S.tab[sortKey] = { key: c.key, desc: s && s.key === c.key ? !s.desc : !!c.descFirst }; render(); } },
      c.label, sort && sort.key === c.key ? h('span', { class: 'arrow', text: sort.desc ? '\u25BC' : '\u25B2' }) : null)));
  const body = h('tbody');
  let lastGroup;
  for (const r of data) {
    if (groupBy && !sort) {
      const g = groupBy(r);
      if (g !== lastGroup) { lastGroup = g; body.append(h('tr', { class: 'group' }, h('td', { colspan: columns.length + (sel ? 1 : 0) }, groupLabel ? groupLabel(g, data.filter(x => groupBy(x) === g)) : g))); }
    }
    const k = rowKey ? rowKey(r) : null;
    const tr = h('tr', { class: (selectedKey !== undefined && k === selectedKey ? 'selected ' : '') + (opts.rowClass ? opts.rowClass(r) : ''),
      onclick: onRow ? () => onRow(r) : null, ondblclick: onDbl ? () => onDbl(r) : null },
      sel ? h('td', { class: 'cb' }, h('input', { type: 'checkbox', checked: sel.has(k), onclick: e => e.stopPropagation(),
        onchange: e => { e.target.checked ? sel.add(k) : sel.delete(k); if (opts.onSel) opts.onSel(); else render(); } })) : null,
      columns.map(c => h('td', { class: c.cls || '', title: c.title ? c.title(r) : null }, c.render ? c.render(r) : r[c.key])));
    body.append(tr);
  }
  if (!rows.length) body.append(h('tr', {}, h('td', { colspan: columns.length + (sel ? 1 : 0), class: 'empty', text: empty || 'Nothing here yet.' })));
  return h('div', { class: 'table-wrap', style: opts.height ? 'max-height:' + opts.height : null }, h('table', {}, h('thead', {}, head), body));
}

// Score ring (SVG)
function ring(score, size) {
  const ns = 'http://www.w3.org/2000/svg', R = 52, C = 2 * Math.PI * R, arc = 0.75;
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 130 130'); svg.setAttribute('class', 'ring');
  if (size) { svg.style.width = size + 'px'; svg.style.height = size + 'px'; }
  const mk = (stroke, frac) => {
    const c = document.createElementNS(ns, 'circle');
    c.setAttribute('cx', 65); c.setAttribute('cy', 65); c.setAttribute('r', R); c.setAttribute('fill', 'none');
    c.setAttribute('stroke', stroke); c.setAttribute('stroke-width', 11); c.setAttribute('stroke-linecap', 'round');
    c.setAttribute('stroke-dasharray', (C * arc * frac) + ' ' + C); c.setAttribute('transform', 'rotate(135 65 65)');
    return c;
  };
  svg.append(mk('var(--line)', 1));
  if (score !== null && score !== undefined) svg.append(mk(scoreColor(score), Math.max(0.02, score / 100)));
  const t = document.createElementNS(ns, 'text');
  t.setAttribute('x', 65); t.setAttribute('y', 72); t.setAttribute('text-anchor', 'middle'); t.setAttribute('font-size', 34);
  t.setAttribute('font-weight', 600); t.setAttribute('fill', 'currentColor'); t.textContent = score === null || score === undefined ? '--' : score;
  const l = document.createElementNS(ns, 'text');
  l.setAttribute('x', 65); l.setAttribute('y', 96); l.setAttribute('text-anchor', 'middle'); l.setAttribute('font-size', 11);
  l.setAttribute('fill', 'var(--muted)'); l.textContent = 'health score';
  svg.append(t, l);
  return svg;
}
const stat = (k, v, s, cls) => h('div', { class: 'stat' }, h('div', { class: 'k', text: k }), h('div', { class: 'v ' + (cls || ''), text: v }), h('div', { class: 's', text: s || '' }));

// ---------------------------------------------------------------------------
// Pages
// ---------------------------------------------------------------------------
pages.dashboard = {
  title: 'Dashboard',
  render(root) {
    const d = S.cache.dash, junk = S.cache.junk;
    if (!d) autoLoad('dash', loadDashboard);
    const bad = d ? d.Issues.filter(i => i.Level === 'BAD').length : 0;
    const verdict = !d ? 'Checking this Mac...' : (d.Score >= 85 && !bad) ? 'This Mac is in good shape' : bad ? bad + ' important problem' + (bad > 1 ? 's' : '') + ' to fix' : 'A few things could be better';
    root.append(
      h('div', { class: 'card hero' }, ring(d ? d.Score : null),
        h('div', { style: 'flex:1' },
          h('h2', { text: verdict }),
          h('p', { class: 'muted', text: S.busy.smart ? 'Smart Scan is checking junk, security, updates and startup items...' :
            'Smart Scan checks junk, security, updates and startup items in one go. Nothing is changed until you click Clean.' }),
          h('div', { class: 'row' },
            btn('Smart Scan', smartScan, 'primary big', 'smart'),
            junk > 1048576 ? btn('Clean ' + fmtSize(junk), () => cleanKeys(S.state.categories.filter(c => c.default).map(c => c.key)), 'big', 'clean') : null,
            btn('Refresh', loadDashboard, 'link', 'dash')),
          progLine('smart'))),
      h('div', { class: 'stats' },
        stat('Junk found', junk != null ? fmtSize(junk) : '-', junk != null ? 'safe to remove' : 'run Smart Scan'),
        stat('Freed by CleanIT', d ? fmtSize(d.FreedTotal) : '-', 'all time on this Mac'),
        stat('Free on disk', d ? fmtSize(d.FreeBytes) : '-', d ? d.FreePct + '% of ' + fmtSize(d.SizeBytes) : '', d && d.FreePct < 10 ? 'c-BAD' : d && d.FreePct < 20 ? 'c-WARN' : ''),
        stat('Startup items', d ? String(d.StartupCount) : '-', 'start when you log in'),
        stat('Updates waiting', !d ? '-' : (d.AppUpdates < 0 && d.MacUpdates < 0) ? '?' : String(Math.max(0, d.AppUpdates) + Math.max(0, d.MacUpdates)), d ? (d.MacUpdates >= 0 ? d.MacUpdates + ' macOS' : 'macOS not checked') + ', ' + (d.AppUpdates >= 0 ? d.AppUpdates + ' Homebrew' : 'Homebrew not checked') : ''),
        stat('Last clean', d ? fmtAgo(d.LastClean) : '-', d && d.LastClean ? 'freed ' + fmtSize(d.LastFreed) : '')),
      h('div', { class: 'card' }, h('h3', {}, 'What CleanIT found'),
        !d ? h('div', { class: 'empty', text: 'Checking...' }) :
        !d.Issues.length ? h('div', { class: 'empty', text: 'Nothing to fix right now.' }) :
        h('div', { class: 'issues' }, d.Issues.slice().sort((a, b) => ({ BAD: 0, WARN: 1, INFO: 2 }[a.Level] - { BAD: 0, WARN: 1, INFO: 2 }[b.Level]) || b.Penalty - a.Penalty)
          .map(i => h('div', { class: 'issue' }, h('span', { class: 'pill ' + i.Level, text: i.Level === 'BAD' ? 'Fix' : i.Level === 'WARN' ? 'Check' : 'Info' }),
            h('div', { class: 't', text: i.Text }), i.Tab ? btn('Open ' + i.Tab, () => go(i.Tab.toLowerCase()), 'link') : null)))));
  }
};
function loadDashboard() {
  return task('dash', async () => { S.cache.dash = await run('dashboard'); });
}
function smartScan() {
  return task('smart', async () => {
    const r = await run('smartScan', {}, prog('smart'));
    S.cache.dash = r.dash; S.cache.junk = r.junk;
    S.cache.sizes = S.cache.sizes || {};
    for (const x of r.scan) S.cache.sizes[x.Key] = { size: x.Size, running: x.Running };
    toast('Smart Scan done: ' + fmtSize(r.junk) + ' of junk found.');
  });
}

// ----- Clean
pages.clean = {
  title: 'Clean junk',
  render(root) {
    const cats = S.state.categories, sizes = S.cache.sizes || {};
    if (!S.sel.clean) S.sel.clean = new Set(cats.filter(c => c.default).map(c => c.key));
    const sel = S.sel.clean;
    let total = 0, known = false;
    for (const k of sel) if (sizes[k]) { known = true; if (sizes[k].size > 0) total += sizes[k].size; }
    root.append(
      h('div', { class: 'card' },
        h('div', { class: 'row' },
          btn('Scan', scanJunk, 'primary', 'scan'),
          btn('Clean selected', () => cleanKeys([...sel]), 'primary', 'clean', !sel.size),
          btn('Recommended', () => { S.sel.clean = new Set(cats.filter(c => c.default).map(c => c.key)); render(); }),
          btn('None', () => { S.sel.clean = new Set(); render(); }),
          h('span', { class: 'spacer' }),
          h('b', { text: known ? fmtSize(total) + ' selected' : 'Scan to see sizes' })),
        progLine('scan') || progLine('clean')),
      !S.state.fda ? h('div', { class: 'notice small' }, 'Safari, Mail and the Trash need Full Disk Access to be scanned. ',
        btn('How to allow it', fdaHelp, 'link')) : null,
      table({ id: 'clean', selKey: 'clean', rowKey: c => c.key, rows: cats, groupBy: c => c.group, height: 'calc(100vh - 290px)',
        columns: [
          { key: 'name', label: 'Category', render: c => h('div', {}, h('b', { text: c.name }), c.warning ? h('div', { class: 'small c-WARN', text: c.warning }) : null) },
          { key: 'size', label: 'Size', cls: 'num', descFirst: true, sort: c => sizes[c.key] ? sizes[c.key].size : -2,
            render: c => S.busy.scan ? '...' : sizes[c.key] ? (sizes[c.key].size < 0 ? 'no access' : fmtSize(sizes[c.key].size)) : '-' },
          { key: 'note', label: 'Note', nosort: true, render: c => sizes[c.key] && sizes[c.key].running ? h('span', { class: 'pill WARN', title: 'Close these apps for a full clean', text: 'close ' + sizes[c.key].running }) : '' },
          { key: 'description', label: 'What it removes', cls: 'wrap muted', nosort: true }
        ] }));
  }
};
function scanJunk() {
  return task('scan', async () => {
    const keys = S.state.categories.map(c => c.key);
    const r = await run('junkScan', { keys }, prog('scan'));
    S.cache.sizes = S.cache.sizes || {};
    for (const x of r.items) S.cache.sizes[x.Key] = { size: x.Size, running: x.Running };
  });
}
async function cleanKeys(keys) {
  const cats = S.state.categories.filter(c => keys.includes(c.key));
  if (!cats.length) return toast('Tick at least one category first.', 'warn');
  const warn = cats.filter(c => c.warning);
  const running = [...new Set(cats.map(c => (S.cache.sizes || {})[c.key]).filter(x => x && x.running).map(x => x.running))];
  const ok = await confirmBox('Clean ' + cats.length + ' categor' + (cats.length > 1 ? 'ies' : 'y') + '?', [
    bullets(cats.map(c => c.name)),
    warn.length ? h('div', { class: 'notice warn' }, warn.map(c => h('div', {}, h('b', { text: c.name + ': ' }), c.warning))) : null,
    running.length ? h('p', { class: 'muted', text: 'Open apps are skipped - quit them first for a full clean: ' + running.join(', ') }) : null
  ], 'Clean', warn.length > 0);
  if (!ok) return;
  const rp = await restorePointChoice(); if (rp === null) return;
  await task('clean', async () => {
    const r = await run('clean', { keys, restorePoint: rp }, prog('clean'));
    for (const d of r.Details) if (S.cache.sizes && S.cache.sizes[d.Key]) S.cache.sizes[d.Key].size = 0;
    S.cache.junk = 0;
    toast('Done - freed ' + fmtSize(r.Freed) + '.');
    loadDashboard();
  });
}

// ----- Disk
pages.disk = {
  title: 'Disk space',
  render(root) {
    root.append(tabs('disk', [['space', 'Space analyzer'], ['large', 'Large files'], ['dups', 'Duplicate files']]));
    const t = curTab('disk', 'space');
    if (t === 'space') diskSpace(root); else if (t === 'large') diskLarge(root); else diskDups(root);
  }
};
function pathInput(key, def) {
  S.cache[key] = S.cache[key] || def;
  const id = 'places-' + key;
  return [h('input', { type: 'text', value: S.cache[key], list: id, style: 'width:320px', oninput: e => { S.cache[key] = e.target.value; } }),
          h('datalist', { id }, S.state.places.map(p => h('option', { value: p })))];
}
function diskSpace(root) {
  const node = S.cache.diskNode;
  root.append(h('div', { class: 'card' },
    h('div', { class: 'row' }, pathInput('spacePath', S.state.userProfile), btn('Analyze', () => task('space', async () => {
      S.cache.diskNode = await run('diskScan', { path: S.cache.spacePath }, prog('space'));
    }), 'primary', 'space'),
    node && node.parent ? btn('Up', () => openNode(node.parent)) : null,
    node ? btn('Show in Finder', () => openThing('path', { path: node.path })) : null),
    progLine('space'),
    h('p', { class: 'muted small', text: 'Links and online-only iCloud files are not counted. Analyzing / skips other drives. Click a folder to look inside.' })));
  if (!node) { root.append(h('div', { class: 'empty', text: 'Pick a drive or folder and click Analyze.' })); return; }
  // breadcrumb
  const crumbs = []; let p = node.path;
  while (p && p.length >= node.root.length) { crumbs.unshift(p); if (p === node.root) break; const up = dirName(p); if (up === p) break; p = up; }
  root.append(h('div', { class: 'row', style: 'margin-bottom:10px' }, crumbs.map((c, i) => [i ? h('span', { class: 'muted', text: '\u203A' }) : null,
    h('a', { class: 'drill', onclick: () => openNode(c), text: i ? baseName(c) : tilde(c) })]),
    h('span', { class: 'spacer' }), h('b', { text: fmtSize(node.size) }), h('span', { class: 'muted', text: fmtNum(node.files) + ' files' })));
  const rows = node.children.slice();
  if (node.ownFiles > 0) rows.push({ name: '(files directly in this folder)', path: node.path, size: node.ownBytes, files: node.ownFiles, isFiles: true });
  const max = Math.max(1, node.size);
  root.append(table({ id: 'space', rows, rowKey: r => r.path + (r.isFiles ? '*' : ''), height: 'calc(100vh - 360px)',
    columns: [
      { key: 'name', label: 'Folder', render: r => h('div', { class: 'namecell' }, icon(r.isFiles ? 'file' : 'folder'),
          r.hasChildren ? h('a', { class: 'drill', onclick: () => openNode(r.path), text: r.name }) : h('span', { text: r.name + (r.denied ? '  (no access)' : '') })) },
      { key: 'size', label: 'Size', cls: 'num', descFirst: true, render: r => fmtSize(r.size) },
      { key: 'share', label: 'Share', nosort: true, render: r => h('div', { class: 'row', style: 'flex-wrap:nowrap' },
          h('div', { class: 'bar', style: 'flex:1' }, h('i', { style: 'width:' + (100 * r.size / max).toFixed(1) + '%' })),
          h('span', { class: 'muted small', style: 'width:48px;text-align:right', text: (100 * r.size / max).toFixed(1) + '%' })) },
      { key: 'files', label: 'Files', cls: 'num', descFirst: true, render: r => fmtNum(r.files) },
      { key: 'open', label: '', nosort: true, render: r => btn('Open', () => openThing('path', { path: r.path }), 'link') }
    ] }));
}
async function openNode(path) {
  try { S.cache.diskNode = await api('/api/disk/node?path=' + encodeURIComponent(path)); render(); }
  catch (e) { toast(e.message, 'error'); }
}
function diskLarge(root) {
  const L = S.cache.large || [];
  S.cache.largeMin = S.cache.largeMin || 500; S.cache.largeDays = S.cache.largeDays || 0;
  const sel = S.sel.large = S.sel.large || new Set();
  root.append(h('div', { class: 'card' },
    h('div', { class: 'row' }, pathInput('largePath', S.state.userProfile),
      h('span', { class: 'muted', text: 'At least' }), h('input', { type: 'number', min: 1, value: S.cache.largeMin, oninput: e => S.cache.largeMin = +e.target.value }), h('span', { class: 'muted', text: 'MB' }),
      h('span', { class: 'muted', text: 'not used for' }), h('input', { type: 'number', min: 0, value: S.cache.largeDays, oninput: e => S.cache.largeDays = +e.target.value }), h('span', { class: 'muted', text: 'days (0 = any)' }),
      checkbox('Include system folders & ~/Library', !!S.cache.largeSys, v => S.cache.largeSys = v),
      btn('Find', () => task('large', async () => {
        const r = await run('largeFiles', { path: S.cache.largePath, minMB: S.cache.largeMin, days: S.cache.largeDays, includeSystem: !!S.cache.largeSys }, prog('large'));
        S.cache.large = r.items; S.sel.large = new Set();
      }), 'primary', 'large')),
    progLine('large')));
  const sum = L.reduce((a, f) => a + (sel.has(f.path) ? f.size : 0), 0);
  root.append(h('div', { class: 'row', style: 'margin-bottom:10px' },
    h('span', { class: 'muted', text: L.length ? L.length + ' files, ' + fmtSize(L.reduce((a, f) => a + f.size, 0)) + ' total. Nothing is deleted unless you tick it.' : 'Results appear here.' }),
    h('span', { class: 'spacer' }), sel.size ? h('b', { text: sel.size + ' ticked (' + fmtSize(sum) + ')' }) : null,
    btn('Move ticked to Trash', () => recycle('large', [...sel]), 'danger', 'recycle', !sel.size)));
  root.append(table({ id: 'large', rows: L, selKey: 'large', rowKey: f => f.path, height: 'calc(100vh - 380px)',
    columns: [
      { key: 'name', label: 'File', sort: f => baseName(f.path), render: f => h('div', { class: 'namecell' }, icon('file'), baseName(f.path)) },
      { key: 'size', label: 'Size', cls: 'num', descFirst: true, render: f => fmtSize(f.size) },
      { key: 'lastUsed', label: 'Last used', descFirst: true },
      { key: 'folder', label: 'Folder', cls: 'ell muted', sort: f => dirName(f.path), render: f => tilde(dirName(f.path)), title: f => f.path },
      { key: 'open', label: '', nosort: true, render: f => btn('Show', () => openThing('path', { path: f.path }), 'link') }
    ] }));
}
function diskDups(root) {
  const D = S.cache.dups || [];
  S.cache.dupMin = S.cache.dupMin === undefined ? 1 : S.cache.dupMin;
  const sel = S.sel.dups = S.sel.dups || new Set();
  root.append(h('div', { class: 'card' },
    h('div', { class: 'row' }, pathInput('dupPath', S.state.userProfile),
      h('span', { class: 'muted', text: 'At least' }), h('input', { type: 'number', min: 0, value: S.cache.dupMin, oninput: e => S.cache.dupMin = +e.target.value }), h('span', { class: 'muted', text: 'MB' }),
      checkbox('Include system folders & ~/Library', !!S.cache.dupSys, v => S.cache.dupSys = v),
      btn('Find duplicates', () => task('dups', async () => {
        const r = await run('duplicates', { path: S.cache.dupPath, minMB: S.cache.dupMin, includeSystem: !!S.cache.dupSys }, prog('dups'));
        S.cache.dups = r.items; S.sel.dups = new Set();
      }), 'primary', 'dups')),
    progLine('dups'),
    h('p', { class: 'muted small', text: 'Files are compared by content (SHA-256). Hard links are not counted twice.' })));
  const groups = {};
  for (const f of D) (groups[f.group] = groups[f.group] || []).push(f);
  const wasted = Object.values(groups).reduce((a, g) => a + g[0].size * (g.length - 1), 0);
  const tick = oldest => { S.sel.dups = new Set(); for (const g of Object.values(groups)) { const s = g.slice().sort((a, b) => a.modified.localeCompare(b.modified)); const keep = oldest ? s[0] : s[s.length - 1]; for (const f of g) if (f !== keep) S.sel.dups.add(f.path); } render(); };
  root.append(h('div', { class: 'row', style: 'margin-bottom:10px' },
    h('span', { class: 'muted', text: D.length ? Object.keys(groups).length + ' sets of duplicates - ' + fmtSize(wasted) + ' could be freed.' : 'Results appear here.' }),
    h('span', { class: 'spacer' }),
    D.length ? btn('Tick all but the oldest', () => tick(true)) : null, D.length ? btn('Tick all but the newest', () => tick(false)) : null,
    btn('Move ticked to Trash', () => {
      for (const g of Object.values(groups)) if (g.every(f => sel.has(f.path))) return toast('Every copy of "' + baseName(g[0].path) + '" is ticked - leave at least one.', 'error');
      recycle('dups', [...sel]);
    }, 'danger', 'recycle', !sel.size)));
  root.append(table({ id: 'dups', rows: D, selKey: 'dups', rowKey: f => f.path, groupBy: f => f.group, height: 'calc(100vh - 380px)',
    groupLabel: (g, list) => list.length + ' copies of ' + fmtSize(list[0].size) + ' - ' + baseName(list[0].path),
    columns: [
      { key: 'name', label: 'File', sort: f => baseName(f.path), render: f => h('div', { class: 'namecell' }, icon('file'), baseName(f.path)) },
      { key: 'size', label: 'Size', cls: 'num', descFirst: true, render: f => fmtSize(f.size) },
      { key: 'modified', label: 'Modified' },
      { key: 'folder', label: 'Folder', cls: 'ell muted', sort: f => dirName(f.path), render: f => dirName(f.path), title: f => f.path },
      { key: 'open', label: '', nosort: true, render: f => btn('Show', () => openThing('path', { path: f.path }), 'link') }
    ] }));
}
async function recycle(kind, paths) {
  const list = (kind === 'large' ? S.cache.large : S.cache.dups).filter(f => paths.includes(f.path));
  const sum = list.reduce((a, f) => a + f.size, 0);
  if (!await confirmBox('Move ' + list.length + ' file(s) to the Trash?', [h('p', { text: fmtSize(sum) + ' in total. You can put them back from the Trash until you empty it.' }), bullets(list.map(f => tilde(f.path)), 12)], 'Move to Trash', true)) return;
  await task('recycle', async () => {
    const r = await run('recycle', { paths });
    const gone = new Set(r.removed);
    if (kind === 'large') S.cache.large = S.cache.large.filter(f => !gone.has(f.path)); else S.cache.dups = S.cache.dups.filter(f => !gone.has(f.path));
    S.sel[kind] = new Set();
    toast(r.removed.length + ' file(s) moved to the Trash.');
  });
}

// ----- Full Disk Access (optional; lets CleanIT read Safari, Mail and the Trash)
async function fdaHelp() {
  const c = await dialog('Allow Full Disk Access (optional)', [
    h('p', {}, 'macOS protects Safari, Mail and the Trash. To let CleanIT scan and clean them:'),
    h('ol', { class: 'steps' },
      h('li', {}, 'Click ', h('b', { text: 'Open Privacy settings' }), '.'),
      h('li', {}, 'Switch on ', h('b', { text: 'CleanIT' }), ' (or click + and pick CleanIT from Applications).'),
      h('li', {}, 'Quit and reopen CleanIT.')),
    h('p', { class: 'muted small', text: 'Everything else works without it. You can switch it off again at any time.' })
  ], [{ id: 'x', text: 'Close' }, { id: 'go', text: 'Open Privacy settings', cls: 'primary' }]);
  if (c === 'go') openThing('pane', { pane: 'fda' });
}

// ----- Startup
const KIND = { Agent: 'Agent', Daemon: 'Background service', LoginItem: 'Login item' };
pages.startup = {
  title: 'Startup items',
  render(root) {
    const items = S.cache.startup;
    if (!items) autoLoad('startup', loadStartup);
    const ch = S.cache.startupChanges = S.cache.startupChanges || {};
    const n = Object.keys(ch).length;
    root.append(h('div', { class: 'card' },
      h('div', { class: 'row' },
        btn(n ? 'Apply ' + n + ' change' + (n > 1 ? 's' : '') : 'Apply changes', applyStartup, 'primary', 'startupApply', !n),
        btn('Refresh', loadStartup, '', 'startup'),
        btn('Undo all CleanIT changes', async () => {
          if (await confirmBox('Undo startup changes?', 'Switch every item CleanIT turned off back on.', 'Undo all'))
            await task('startupUndo', async () => { await run('startupUndo'); await loadStartup(); });
        }, '', 'startupUndo'),
        btn('Open Login Items settings', () => openThing('pane', { pane: 'loginitems' }), 'link'),
        h('span', { class: 'spacer' }),
        checkbox('Show Apple items', !!S.state.settings.ShowApple, async v => { await saveSettings({ ShowApple: v }); loadStartup(); })),
      h('p', { class: 'muted small', text: 'Switch off what you don\'t need at login. CleanIT uses macOS\'s own on/off switch - files are never deleted, so everything can be switched back on. Background services ask for your password. Orange = unsigned.' }),
      progLine('startup')));
    if (!items) { root.append(h('div', { class: 'empty', text: 'Loading (checking signatures)...' })); return; }
    const on = items.filter(i => (i.id in ch ? ch[i.id] : i.Enabled)).length;
    root.append(h('p', { class: 'muted', text: on + ' of ' + items.length + ' start automatically.' }));
    root.append(table({ id: 'startup', rows: items, rowKey: i => i.id, height: 'calc(100vh - 330px)',
      rowClass: i => (i.Publisher || '').match(/unsigned|NOT valid/) ? 'c-WARN' : '',
      columns: [
        { key: 'on', label: 'On', nosort: true, render: i => toggle(i.id in ch ? ch[i.id] : i.Enabled, v => { if (v === i.Enabled) delete ch[i.id]; else ch[i.id] = v; render(); }) },
        { key: 'Name', label: 'Name', render: i => h('div', {}, h('b', { text: i.Name }), i.Name !== i.Label ? h('div', { class: 'small muted', text: i.Label }) : null) },
        { key: 'Kind', label: 'Type', render: i => h('span', { class: 'pill INFO', text: KIND[i.Kind] || i.Kind }) },
        { key: 'Publisher', label: 'Signed by' },
        { key: 'Status', label: 'Status' },
        { key: 'Command', label: 'Where / command', cls: 'ell muted', render: i => i.Location + ': ' + tilde(i.Command), title: i => i.Command },
        { key: 'open', label: '', nosort: true, render: i => i.Plist || i.Exe ? btn('Show', () => openThing('path', { path: i.Plist || i.Exe }), 'link') : '' }
      ] }));
  }
};
function loadStartup() {
  return task('startup', async () => { S.cache.startupChanges = {}; S.cache.startup = (await run('startupList', { includeApple: !!S.state.settings.ShowApple })).items; });
}
async function applyStartup() {
  const ch = S.cache.startupChanges || {};
  const changes = Object.entries(ch).map(([id, enable]) => ({ id, enable }));
  if (!changes.length) return;
  await task('startupApply', async () => { await run('startupApply', { changes }); toast(changes.length + ' startup change(s) applied.'); });
  await loadStartup();
}

// ----- Apps
pages.apps = {
  title: 'Apps',
  render(root) {
    const items = S.cache.programs;
    if (!items) autoLoad('programs', loadPrograms);
    const f = (S.cache.progFilter || '').toLowerCase();
    const sel = items && items.find(p => p.id === S.cache.progSel);
    root.append(h('div', { class: 'card' },
      h('div', { class: 'row' },
        h('input', { type: 'text', placeholder: 'Search apps...', value: S.cache.progFilter || '', style: 'width:260px', id: 'progsearch',
          oninput: e => { S.cache.progFilter = e.target.value; const pos = e.target.selectionStart; render(); const el = $('#progsearch'); el.focus(); el.setSelectionRange(pos, pos); } }),
        btn('Uninstall', () => sel && uninstallProgram(sel), 'danger', 'uninstall', !sel || sel.builtIn),
        btn('Find leftovers', () => sel && findLeftovers(sel), '', 'leftovers', !sel),
        btn('Show in Finder', () => sel && openThing('path', { path: sel.location }), '', null, !sel),
        h('span', { class: 'spacer' }), btn('Refresh', loadPrograms, 'link', 'programs')),
      h('p', { class: 'muted small', text: sel ? 'Selected: ' + sel.name + (sel.bundleId ? '  (' + sel.bundleId + ')' : '') :
        'Click an app to select it. Uninstall moves the app to the Trash, then CleanIT looks for its leftover settings, caches and helpers.' }),
      progLine('uninstall') || progLine('leftovers') || progLine('programs')));
    if (!items) { root.append(h('div', { class: 'empty', text: 'Loading apps...' })); return; }
    const rows = items.filter(p => !f || p.name.toLowerCase().includes(f) || (p.publisher || '').toLowerCase().includes(f) || (p.bundleId || '').toLowerCase().includes(f));
    root.append(table({ id: 'programs', rows, rowKey: p => p.id, selectedKey: S.cache.progSel, onRow: p => { S.cache.progSel = p.id; render(); }, height: 'calc(100vh - 320px)',
      columns: [
        { key: 'name', label: 'App', render: p => h('b', { text: p.name }) },
        { key: 'publisher', label: 'From' },
        { key: 'version', label: 'Version', cls: 'muted' },
        { key: 'size', label: 'Size', cls: 'num', descFirst: true, render: p => p.size > 0 ? fmtSize(p.size) : '' },
        { key: 'lastUsed', label: 'Last opened', descFirst: true, render: p => p.lastUsed || 'never' },
        { key: 'scope', label: 'For', cls: 'muted' }
      ] }));
  }
};
function loadPrograms() { return task('programs', async () => { S.cache.programs = (await run('programsList', {}, prog('programs'))).items; }); }
async function uninstallProgram(p) {
  if (!await confirmBox('Uninstall ' + p.name + '?', 'The app moves to the Trash (you can put it back until you empty the Trash). Afterwards CleanIT shows the leftovers it finds.', 'Uninstall', true)) return;
  await task('uninstall', async () => {
    const r = await run('uninstall', { id: p.id }, prog('uninstall'));
    S.cache.progSel = null; S.cache.programs = null;
    if (r.hits.length) leftoversDialog(r.name, r.hits); else toast(r.name + ' uninstalled - no leftovers found.');
  });
}
async function findLeftovers(p) {
  await task('leftovers', async () => {
    const r = await run('leftovers', { id: p.id }, prog('leftovers'));
    if (!r.hits.length) toast('No leftovers found for ' + r.name + '.'); else leftoversDialog(r.name, r.hits);
  });
}
async function leftoversDialog(name, hits) {
  S.sel.left = new Set();
  const wrap = h('div');
  const draw = () => wrap.replaceChildren(
    h('p', { class: 'muted', text: 'Nothing is ticked - check each one. Ticked items go to the Trash. If the app is still installed, these are its live settings - leave them.' }),
    table({ id: 'left', rows: hits, selKey: 'left', rowKey: x => x.Path, onSel: draw, height: '50vh',
      columns: [
        { key: 'Type', label: 'Type', render: x => h('span', { class: 'pill INFO', text: x.Type }) },
        { key: 'Path', label: 'Path', cls: 'wrap', render: x => tilde(x.Path) },
        { key: 'Size', label: 'Size', cls: 'num', render: x => fmtSize(x.Size) },
        { key: 'Reason', label: 'Why', cls: 'muted small' }
      ] }));
  draw();
  const c = await dialog('Leftovers of ' + name, wrap, [{ id: 'x', text: 'Close' }, { id: 'rm', text: 'Move ticked to Trash', cls: 'danger' }], true);
  if (c !== 'rm' || !S.sel.left.size) return;
  await task('leftoversRemove', async () => { const r = await run('leftoversRemove', { paths: [...S.sel.left] }); toast(r.removed.length + ' leftover(s) moved to the Trash.'); });
}

// ----- Updates
const IMP = { Important: ['BAD', 'Important'], Recommended: ['WARN', 'Recommended'], Optional: ['INFO', 'Optional'], Automatic: ['OK', 'Automatic'] };
const IMP_ORDER = { Important: 0, Recommended: 1, Optional: 2, Automatic: 3 };
function impPill(i) { const v = IMP[i] || IMP.Optional; return h('span', { class: 'pill ' + v[0], text: v[1] }); }
pages.updates = {
  title: 'Updates',
  render(root) {
    root.append(h('div', { class: 'notice small' },
      h('b', { text: 'Which ones do I need? ' }),
      'CleanIT ticks the ones worth installing for you. ', impPill('Important'), ' install today  ', impPill('Recommended'), ' install soon  ',
      impPill('Optional'), ' only if you want.'));
    root.append(tabs('upd', [['mac', 'macOS & Apple'], ['brew', 'Homebrew']]));
    if (curTab('upd', 'mac') === 'mac') updMac(root); else updBrew(root);
  }
};
function updMac(root) {
  const items = S.cache.macUpd;
  const sel = S.sel.macUpd = S.sel.macUpd || new Set();
  const load = () => task('macUpd', async () => {
    S.cache.macUpd = (await run('macList', {}, prog('macUpd'))).items;
    S.sel.macUpd = new Set(S.cache.macUpd.filter(u => !u.NeedsInput && u.Importance !== 'Optional').map(u => u.Id));
  });
  if (!items && !S.busy.macUpd && !S.cache.macUpdTried) { S.cache.macUpdTried = true; setTimeout(load); }
  let summary = null;
  if (items) {
    const imp = items.filter(u => u.Importance === 'Important').length;
    summary = !items.length ? 'macOS and Apple software are up to date.' :
      imp ? imp + ' important update' + (imp > 1 ? 's' : '') + ' - install today.' : 'No urgent updates.';
  }
  root.append(h('div', { class: 'card' },
    summary ? h('p', { style: 'margin-top:0', text: summary }) : null,
    h('div', { class: 'row' },
      btn(sel.size ? 'Install ' + sel.size + ' update' + (sel.size > 1 ? 's' : '') : 'Install ticked', async () => {
        const ids = [...sel];
        if (!await confirmBox('Install ' + ids.length + ' update(s)?', 'macOS asks for your password. Downloading and installing can take a while.', 'Install')) return;
        await task('macInstall', async () => { await run('macInstall', { ids }, prog('macInstall')); toast('Updates installed.'); });
        load();
      }, 'primary', 'macInstall', !sel.size),
      btn('Check again', load, '', 'macUpd'),
      btn('Open Software Update', () => openThing('pane', { pane: 'updates' }), 'link'),
      btn('App Store updates', () => openThing('pane', { pane: 'appstore' }), 'link')),
    progLine('macUpd') || progLine('macInstall')));
  if (!items) { root.append(h('div', { class: 'empty', text: S.busy.macUpd ? 'Asking Apple\'s update server (can take a minute)...' : 'Click Check again.' })); return; }
  root.append(table({ id: 'macUpd', rows: items.slice().sort((a, b) => IMP_ORDER[a.Importance] - IMP_ORDER[b.Importance]), selKey: 'macUpd', rowKey: u => u.Id,
    empty: 'No updates available.', height: 'calc(100vh - 380px)',
    columns: [
      { key: 'Importance', label: 'Advice', sort: u => IMP_ORDER[u.Importance], render: u => impPill(u.Importance) },
      { key: 'Title', label: 'Update', cls: 'wrap', render: u => h('div', {}, h('b', { text: u.Title }),
          h('div', { class: 'small muted', text: u.NeedsInput ? u.Why + ' Install it from Software Update (button above).' : u.Why })) },
      { key: 'Size', label: 'Size', cls: 'num', descFirst: true, render: u => u.Size > 0 ? fmtSize(u.Size) : '' },
      { key: 'Reboot', label: 'Restart', render: u => u.Reboot ? 'yes' : 'no' }
    ] }));
}
function updBrew(root) {
  if (!S.state.brew) {
    root.append(h('div', { class: 'card' }, h('p', { text: 'Homebrew is not installed. It is only needed if you install developer tools or apps with brew.' }),
      btn('What is Homebrew?', () => openThing('url', { url: 'https://brew.sh' }), 'link')));
    return;
  }
  const items = S.cache.brew;
  if (!items) autoLoad('brew', loadBrew);
  const excl = new Set(S.state.settings.BrewExclude || []);
  const sel = S.sel.brew = S.sel.brew || new Set();
  root.append(h('div', { class: 'card' },
    items ? h('p', { style: 'margin-top:0', text: !items.length ? 'Everything installed with Homebrew is up to date.' : items.length + ' update(s). Recommended ones handle internet data or passwords.' }) : null,
    h('div', { class: 'row' },
      btn(sel.size ? 'Update ' + sel.size : 'Update ticked', async () => {
        const ids = [...sel];
        if (!await confirmBox('Update ' + ids.length + ' item(s) with Homebrew?', 'Apps being updated may close. Save your work first.', 'Update')) return;
        await task('brewUpgrade', async () => { await run('brewUpgrade', { ids }, prog('brewUpgrade')); });
        loadBrew();
      }, 'primary', 'brewUpgrade', !sel.size),
      btn('Tick all', () => { (items || []).filter(u => !excl.has(u.Id) && !u.Pinned).forEach(u => sel.add(u.Id)); render(); }, '', null, !items),
      btn('Check again', loadBrew, '', 'brew')),
    h('p', { class: 'muted small', text: '"Never update" items are skipped here and by the weekly clean.' }),
    progLine('brewUpgrade') || progLine('brew')));
  if (!items) { root.append(h('div', { class: 'empty', text: 'Checking Homebrew...' })); return; }
  root.append(table({ id: 'brew', rows: items.slice().sort((a, b) => IMP_ORDER[a.Importance] - IMP_ORDER[b.Importance] || a.Name.localeCompare(b.Name)),
    selKey: 'brew', rowKey: u => u.Id, empty: 'All up to date.', height: 'calc(100vh - 380px)', rowClass: u => excl.has(u.Id) ? 'muted' : '',
    columns: [
      { key: 'Importance', label: 'Advice', sort: u => IMP_ORDER[u.Importance], render: u => excl.has(u.Id) ? h('span', { class: 'pill INFO', text: 'Never update' }) : impPill(u.Importance) },
      { key: 'Name', label: 'Name', cls: 'wrap', render: u => h('div', {}, h('b', { text: u.Name }), h('div', { class: 'small muted', text: u.Why })) },
      { key: 'Kind', label: 'Type' },
      { key: 'Version', label: 'You have' },
      { key: 'Available', label: 'New', render: u => h('span', { class: 'pill accent', text: u.Available }) },
      { key: 'x', label: '', nosort: true, render: u => btn(excl.has(u.Id) ? 'Allow updates' : 'Never update', async () => {
          if (excl.has(u.Id)) excl.delete(u.Id); else { excl.add(u.Id); sel.delete(u.Id); }
          await saveSettings({ BrewExclude: [...excl] }); render();
        }, 'link') }
    ] }));
}
function loadBrew() {
  return task('brew', async () => {
    S.cache.brew = (await run('brewList', {}, prog('brew'))).items;
    const excl = new Set(S.state.settings.BrewExclude || []);
    S.sel.brew = new Set(S.cache.brew.filter(u => !excl.has(u.Id) && !u.Pinned && u.Importance === 'Recommended').map(u => u.Id));
  });
}

// ----- Security
const SEC_FIX = {
  EnableFirewall: ['Turn on', () => secFix('EnableFirewall'), 'primary'],
  OpenFileVault: ['Open', () => openThing('pane', { pane: 'filevault' }), 'link'],
  OpenPrivacy: ['Open', () => openThing('pane', { pane: 'privacy' }), 'link'],
  OpenUpdates: ['Open', () => openThing('pane', { pane: 'updates' }), 'link'],
  OpenUsers: ['Open', () => openThing('pane', { pane: 'users' }), 'link'],
  OpenSharing: ['Open', () => openThing('pane', { pane: 'sharing' }), 'link'],
  GoUpdates: ['Updates', () => go('updates'), 'link'],
  GoStartup: ['Startup', () => go('startup'), 'link']
};
pages.security = {
  title: 'Security',
  render(root) {
    const items = S.cache.security;
    if (!items) autoLoad('security', loadSecurity);
    root.append(h('div', { class: 'card' }, h('div', { class: 'row' },
      btn('Check again', loadSecurity, 'primary', 'security'),
      btn('Open Privacy & Security', () => openThing('pane', { pane: 'privacy' }), 'link'))));
    if (!items) { root.append(h('div', { class: 'empty', text: 'Checking FileVault, firewall, Gatekeeper, updates and sharing...' })); return; }
    const order = { BAD: 0, WARN: 1, INFO: 2, OK: 3 };
    const bad = items.filter(i => i.Level === 'BAD').length, warn = items.filter(i => i.Level === 'WARN').length;
    root.append(h('div', { class: 'card' }, h('h3', {}, bad ? bad + ' problem(s), ' + warn + ' warning(s)' : warn ? warn + ' warning(s)' : 'All good'),
      items.slice().sort((a, b) => order[a.Level] - order[b.Level]).map(i => {
        const f = i.Level !== 'OK' && SEC_FIX[i.Fix];
        return h('div', { class: 'sec-row' },
          h('span', { class: 'pill ' + i.Level, text: i.Level }), h('b', { text: i.Name }), h('span', { class: 'muted', text: i.Detail }),
          f ? btn(f[0], f[1], f[2], 'fix' + i.Fix) : h('span'));
      })));
  }
};
function loadSecurity() { return task('security', async () => { S.cache.security = (await run('security')).items; }); }
async function secFix(fix) {
  if (fix === 'EnableFirewall' && !await confirmBox('Turn on the firewall?', 'macOS asks for your password. You can turn it off again in System Settings > Network > Firewall.', 'Turn on')) return;
  await task('fix' + fix, async () => { await run('securityFix', { fix }, prog('fix' + fix)); toast('Done.'); });
  loadSecurity();
}

// ----- Health
pages.health = {
  title: 'Health',
  render(root) {
    const text = S.cache.health;
    if (!text) autoLoad('health', loadHealth);
    root.append(h('div', { class: 'card' }, h('div', { class: 'row' },
      btn('Refresh', loadHealth, 'primary', 'health'),
      btn('Fix network (flush DNS)', () => task('dns', async () => { await run('flushDns'); toast('DNS cache flushed.'); }), '', 'dns'),
      btn('Open Storage settings', () => openThing('pane', { pane: 'storage' }), 'link'),
      btn('Open Disk Utility', () => openThing('app', { name: 'com.apple.DiskUtility' }), 'link'),
      btn('Open Activity Monitor', () => openThing('app', { name: 'com.apple.ActivityMonitor' }), 'link'))));
    root.append(h('div', { class: 'card' }, text ? h('pre', { class: 'report', text }) : h('div', { class: 'empty', text: 'Gathering...' })));
  }
};
function loadHealth() { return task('health', async () => { S.cache.health = (await run('health')).text; }); }

// ----- Settings
pages.settings = {
  title: 'Settings',
  render(root) {
    const st = S.state, s = st.settings;
    S.cache.sched = S.cache.sched || { enabled: st.schedule, day: s.ScheduleDay, time: s.ScheduleTime, updates: !!s.ScheduleUpdates };
    const sc = S.cache.sched;
    root.append(
      !st.inApplications ? h('div', { class: 'notice warn', text: 'CleanIT is running from ' + tilde(st.appPath) + '. Drag CleanIT.app into your Applications folder so the weekly clean and Full Disk Access keep working.' }) : null,
      h('div', { class: 'card' }, h('h3', {}, 'Full Disk Access', h('small', { text: 'optional' })),
        h('div', { class: 'row' },
          h('span', { class: 'pill ' + (st.fda ? 'OK' : 'INFO'), text: st.fda ? 'allowed' : 'not allowed' }),
          h('span', { class: 'muted', text: st.fda ? 'CleanIT can scan Safari, Mail and the Trash.' : 'Without it, Safari, Mail and the Trash are skipped. Everything else works.' }),
          h('span', { class: 'spacer' }),
          btn(st.fda ? 'Open Privacy settings' : 'How to allow it', () => st.fda ? openThing('pane', { pane: 'fda' }) : fdaHelp(), st.fda ? 'link' : ''))),
      h('div', { class: 'card' }, h('h3', {}, 'Weekly automatic clean', h('small', { text: 'runs in the background; catches up after sleep' })),
        h('div', { class: 'opt' }, toggle(sc.enabled, v => { sc.enabled = v; render(); }),
          h('div', { class: 't' }, h('b', { text: 'Clean the recommended categories every week' }), h('div', { text: 'You get a notification with the result. Apps that are open are skipped.' }))),
        h('div', { class: 'row' },
          h('span', { class: 'muted', text: 'Day' }),
          h('select', { onchange: e => sc.day = e.target.value }, ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'].map(d => h('option', { value: d, selected: d === sc.day, text: d }))),
          h('span', { class: 'muted', text: 'Time' }),
          h('input', { type: 'time', value: sc.time, onchange: e => sc.time = e.target.value }),
          st.brew ? checkbox('Also update Homebrew', sc.updates, v => sc.updates = v) : null,
          h('span', { class: 'spacer' }),
          btn('Save schedule', () => task('sched', async () => { await run('scheduleSave', sc); await refreshState(); toast(sc.enabled ? 'Weekly clean scheduled.' : 'Weekly clean turned off.'); }), 'primary', 'sched'))),
      h('div', { class: 'card' }, h('h3', {}, 'Undo center'),
        h('p', { class: 'muted small', text: 'Files, apps and leftovers that CleanIT removes go to the Trash. Caches are rebuilt by their apps.' }),
        h('div', { class: 'row' },
          btn('Undo startup changes', () => go('startup')),
          btn('Open the Trash', () => openThing('trash')))),
      h('div', { class: 'card' }, h('h3', {}, 'CleanIT ' + st.version + ' for Mac'),
        h('div', { class: 'row' },
          btn('Open logs', () => openThing('logs')),
          btn('Open data folder', () => openThing('data')),
          btn('CleanIT on GitHub', () => openThing('url', { url: 'https://github.com/Juicethekidd99/CleanIT' }), 'link'),
          h('span', { class: 'spacer' }),
          btn('Quit CleanIT', () => api('/api/quit', {}), 'link')),
        h('p', { class: 'muted small', text: 'Data: ' + tilde(st.dataDir) + '  -  no ads, no telemetry, everything logged. MIT licensed.' })));
  }
};

// ---------------------------------------------------------------------------
// Background polling: running jobs and the activity log
// ---------------------------------------------------------------------------
let pingTimer = null;
function pingSoon() { clearTimeout(pingTimer); pingTimer = setTimeout(ping, 300); }
async function ping() {
  clearTimeout(pingTimer);
  try {
    const r = await api('/api/ping', {});
    $('#jobs').replaceChildren(...r.jobs.map(j => h('div', { class: 'job', title: j.statusText || j.name },
      h('span', { class: 'spin' }), h('span', { class: 'txt', text: j.name + (j.progress >= 0 ? ' ' + j.progress + '%' : '') }),
      h('button', { class: 'x', type: 'button', title: 'Cancel', text: 'Stop', onclick: () => api('/api/jobs/' + j.id + '/cancel', {}) }))));
    pingTimer = setTimeout(ping, r.jobs.length ? 1000 : 4000);
  } catch (e) { pingTimer = setTimeout(ping, 4000); }
}
let logSince = 0;
async function pollLog() {
  try {
    const r = await api('/api/log?since=' + logSince);
    if (r.lines.length) {
      const log = $('#log');
      const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 30;
      for (const l of r.lines) log.append(h('div', { class: 'l-' + l.level, text: l.text }));
      while (log.childElementCount > 1500) log.firstChild.remove();
      if (atBottom) log.scrollTop = log.scrollHeight;
      $('#drawer-last').textContent = r.lines[r.lines.length - 1].text;
    }
    logSince = r.next;
  } catch (e) { /* try again */ }
  setTimeout(pollLog, 1200);
}
async function refreshState() { S.state = await api('/api/state'); render(); }

async function init() {
  $('#drawer-head').addEventListener('click', () => $('#drawer').classList.toggle('collapsed'));
  try { S.state = await api('/api/state'); } catch (e) { offline(false, 'CleanIT could not start', e.message); return; }
  $('#nav-foot').textContent = S.state.computer + '  -  v' + S.state.version;
  const hash = location.hash.slice(1);
  if (pages[hash]) S.page = hash;
  render();
  ping(); pollLog();
}
window.addEventListener('hashchange', () => { const p = location.hash.slice(1); if (pages[p] && p !== S.page) { S.page = p; render(); } });
init();
