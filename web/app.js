/* CleanIT web UI. Talks only to the local CleanIT server (same origin). ASCII-only source. */
'use strict';

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
function baseName(p) { const i = p.lastIndexOf('\\'); return i >= 0 ? p.slice(i + 1) : p; }
function dirName(p) { const i = p.lastIndexOf('\\'); return i > 0 ? p.slice(0, i) : p; }
function scoreColor(s) { return s >= 85 ? 'var(--ok)' : s >= 65 ? 'var(--warn)' : 'var(--bad)'; }

// ---------------------------------------------------------------------------
// Server API
// ---------------------------------------------------------------------------
async function api(path, body) {
  const opt = body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CleanIT': '1' }, body: JSON.stringify(body) };
  let r;
  try { r = await fetch(path, opt); }
  catch (e) { offline(); throw new Error('CleanIT is not running any more.'); }
  if (r.status === 401) { offline(true); throw new Error('Session expired'); }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}
function offline(expired, title, text) {
  if (S.offline) return;
  S.offline = true;
  document.body.replaceChildren(h('div', { class: 'empty', style: 'padding-top:20vh' },
    h('h2', {}, title || (expired ? 'This window has expired' : 'CleanIT has stopped')),
    h('p', {}, text || 'Close this window and open CleanIT again from its shortcut.')));
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
  ['apps', 'Apps', 'apps'], ['drivers', 'Drivers', 'chip'], ['updates', 'Updates', 'updates'], ['privacy', 'Privacy', 'privacy'], ['security', 'Security', 'security'],
  ['health', 'Health', 'health'], ['fleet', 'Fleet', 'fleet'], ['settings', 'Settings', 'settings']
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
  const up = S.state.update;
  if (up && up.Available && !S.updateDismissed) root.append(updateBanner(up));
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

// Restore point decision: true = make one first, false = skip, null = user cancelled.
async function restorePointChoice() {
  const st = S.state;
  if (!st.settings.RestorePoint || st.restorePointMade) return false;
  if (st.protection === false) {
    const c = await dialog('System Protection is off',
      [h('p', {}, 'Windows restore points are turned off for the system drive, so CleanIT cannot make one before changing things.'),
       h('p', { class: 'muted' }, 'Turning it on uses up to 5% of the drive for restore points.')],
      [{ id: 'cancel', text: 'Cancel' }, { id: 'skip', text: 'Continue without' }, { id: 'on', text: 'Turn on and continue', cls: 'primary' }]);
    if (!c || c === 'cancel') return null;
    if (c === 'skip') return false;
    try { await run('enableProtection'); st.protection = true; } catch (e) { toast(e.message, 'error'); return false; }
  }
  st.restorePointMade = true;
  return true;
}

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
    const verdict = !d ? 'Checking this PC...' : (d.Score >= 85 && !bad) ? 'This PC is in good shape' : bad ? bad + ' important problem' + (bad > 1 ? 's' : '') + ' to fix' : 'A few things could be better';
    root.append(
      h('div', { class: 'card hero' }, ring(d ? d.Score : null),
        h('div', { style: 'flex:1' },
          h('h2', { text: verdict }),
          h('p', { class: 'muted', text: S.busy.smart ? 'Smart Scan is checking junk, security, updates, startup and privacy...' :
            'Smart Scan checks junk, security, updates, startup apps and privacy in one go. Nothing is changed until you click Clean.' }),
          h('div', { class: 'row' },
            btn('Smart Scan', smartScan, 'primary big', 'smart'),
            junk > 1048576 ? btn('Clean ' + fmtSize(junk), () => cleanKeys(S.state.categories.filter(c => c.default).map(c => c.key)), 'big', 'clean') : null,
            btn('Refresh', loadDashboard, 'link', 'dash')),
          progLine('smart'))),
      h('div', { class: 'stats' },
        stat('Junk found', junk != null ? fmtSize(junk) : '-', junk != null ? 'safe to remove' : 'run Smart Scan'),
        stat('Freed by CleanIT', d ? fmtSize(d.FreedTotal) : '-', 'all time on this PC'),
        stat('Free on C:', d ? fmtSize(d.FreeBytes) : '-', d ? d.FreePct + '% of ' + fmtSize(d.SizeBytes) : '', d && d.FreePct < 10 ? 'c-BAD' : d && d.FreePct < 20 ? 'c-WARN' : ''),
        stat('Startup apps', d ? String(d.StartupCount) : '-', 'launch when you sign in'),
        stat('Updates waiting', !d ? '-' : (d.AppUpdates < 0 && d.WinUpdates < 0) ? '?' : String(Math.max(0, d.AppUpdates) + Math.max(0, d.WinUpdates)), d ? (d.AppUpdates >= 0 ? d.AppUpdates + ' apps' : 'apps not checked') + ', ' + (d.WinUpdates >= 0 ? d.WinUpdates + ' Windows' : 'Windows not checked') : ''),
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
      table({ id: 'clean', selKey: 'clean', rowKey: c => c.key, rows: cats, groupBy: c => c.group, height: 'calc(100vh - 290px)',
        columns: [
          { key: 'name', label: 'Category', render: c => h('div', {}, h('b', { text: c.name + (c.deep ? '  (deep, slow)' : '') }), c.warning ? h('div', { class: 'small c-WARN', text: c.warning }) : null) },
          { key: 'size', label: 'Size', cls: 'num', descFirst: true, sort: c => sizes[c.key] ? sizes[c.key].size : -2,
            render: c => S.busy.scan ? '...' : sizes[c.key] ? (sizes[c.key].size < 0 ? 'n/a' : fmtSize(sizes[c.key].size)) : '-' },
          { key: 'note', label: 'Note', nosort: true, render: c => sizes[c.key] && sizes[c.key].running ? h('span', { class: 'pill WARN', title: 'Close these apps for a full clean', text: 'close ' + sizes[c.key].running }) : '' },
          { key: 'description', label: 'What it removes', cls: 'wrap muted', nosort: true }
        ] }));
  }
};
function scanJunk() {
  return task('scan', async () => {
    const keys = S.state.categories.map(c => c.key).filter(k => k !== 'ComponentStore');
    const r = await run('junkScan', { keys }, prog('scan'));
    S.cache.sizes = S.cache.sizes || {};
    for (const x of r.items) S.cache.sizes[x.Key] = { size: x.Size, running: x.Running };
    S.cache.sizes.ComponentStore = { size: -1 };
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
    running.length ? h('p', { class: 'muted', text: 'Open apps (their caches are partly skipped): ' + running.join(', ') }) : null
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
    root.append(tabs('disk', [['free', 'Free up space'], ['space', 'Space analyzer'], ['large', 'Large files'], ['dups', 'Duplicate files']]));
    const t = curTab('disk', 'free');
    if (t === 'free') diskFree(root); else if (t === 'space') diskSpace(root); else if (t === 'large') diskLarge(root); else diskDups(root);
  }
};

// "Free up space" assistant: safe wins first, then things to review, then what to move to another drive.
function loadSpace() {
  return task('spacescan', async () => {
    const r = await run('spaceScan', {}, prog('spacescan'));
    S.cache.space = r;
    S.sel.spaceSafe = new Set(r.Safe.map(i => i.Path));   // safe wins pre-ticked
    S.sel.spaceReview = new Set();
  });
}
function driveBar(d, best) {
  const used = 100 - d.FreePct;
  return h('div', { class: 'drive' },
    h('div', { class: 'row' }, h('b', { text: d.Drive + (d.Label ? '  ' + d.Label : '') }),
      d.Drive === best ? h('span', { class: 'pill OK', text: 'most free space' }) : null,
      h('span', { class: 'spacer' }), h('span', { class: d.FreePct < 10 ? 'c-BAD' : d.FreePct < 20 ? 'c-WARN' : 'muted', text: fmtSize(d.Free) + ' free of ' + fmtSize(d.Size) })),
    h('div', { class: 'bar big' }, h('i', { class: d.FreePct < 10 ? 'bad' : d.FreePct < 20 ? 'warn' : '', style: 'width:' + used.toFixed(1) + '%' })));
}
function moveSteps(kind, item, target) {
  const t = target || 'your other drive';
  const steps = {
    game: ['Open Steam and go to Steam > Settings > Storage.',
      'If ' + t + ' is not listed at the top, click the drop-down > Add Drive > pick ' + t + '.',
      'Select the drive the game is on now, tick "' + item.Name + '", click Move (the "..." button) and pick ' + t + '.',
      'Wait until Steam finishes - the game keeps working and does not need to download again.'],
    vm: ['Shut down the virtual machine "' + item.Name + '" completely (not saved/paused).',
      'In VirtualBox Manager, right-click "' + item.Name + '" > Move...',
      'Choose a folder on ' + t + ' (for example ' + t + '\\VirtualBox VMs) and click Move.',
      'Do not drag the folder in File Explorer - VirtualBox would lose track of the machine.'],
    downloads: ['Open File Explorer, right-click Downloads (left side) > Properties > Location tab.',
      'Click Move... and pick a folder on ' + t + ', e.g. ' + t + '\\Downloads.',
      'Click Apply and answer Yes when Windows asks to move the files.']
  }[kind];
  return dialog(kind === 'game' ? 'Move "' + item.Name + '" to ' + t : kind === 'vm' ? 'Move "' + item.Name + '" to ' + t : 'Move your Downloads folder to ' + t,
    h('ol', { class: 'steps' }, steps.map(s => h('li', { text: s }))), [{ id: 'x', text: 'Got it' }]);
}
function diskFree(root) {
  const r = S.cache.space;
  if (!r) autoLoad('spacescan', loadSpace);
  root.append(h('div', { class: 'card' },
    h('div', { class: 'row' }, h('h3', { style: 'margin:0', text: 'Your drives' }), h('span', { class: 'spacer' }), btn('Scan again', loadSpace, '', 'spacescan')),
    progLine('spacescan') || progLine('spacedel'),
    r ? r.Drives.map(d => driveBar(d, r.Best)) : h('div', { class: 'empty', text: 'Looking for space you can free...' })));
  if (!r) return;
  const sum = (list, sel) => list.filter(i => sel.has(i.Path)).reduce((a, i) => a + i.Size, 0);
  const safeSel = S.sel.spaceSafe, revSel = S.sel.spaceReview;
  const total = sum(r.Safe, safeSel) + sum(r.Review, revSel);
  const itemRow = (i, sel, hideWhy) => h('label', { class: 'opt check-row' },
    h('input', { type: 'checkbox', checked: sel.has(i.Path), onchange: e => { e.target.checked ? sel.add(i.Path) : sel.delete(i.Path); render(); } }),
    h('div', { class: 't' }, h('b', { text: i.Name }), hideWhy ? null : h('div', { text: i.Why })),
    h('span', { class: 'size', text: fmtSize(i.Size) }),
    btn('Show', e => { e.preventDefault(); openThing('path', { path: i.Path }); }, 'link'));

  // Delete bar
  root.append(h('div', { class: 'card sticky-action' }, h('div', { class: 'row' },
    h('div', {}, h('b', { text: total ? 'Ticked: ' + fmtSize(total) + ' will be freed' : 'Tick what you want to remove' }),
      h('div', { class: 'muted small', text: 'Deleted for good (not moved to the Recycle Bin), so the space is really freed. Only files are deleted - never folders.' })),
    h('span', { class: 'spacer' }),
    btn('Delete ticked', deleteSpaceItems, 'danger', 'spacedel', !total))));

  // Safe
  const bins = r.Bins || [];
  root.append(h('div', { class: 'card' }, h('h3', {}, 'Safe to delete', h('small', { text: fmtSize(r.Safe.reduce((a, i) => a + i.Size, 0) + bins.reduce((a, b) => a + b.Size, 0)) })),
    !r.Safe.length && !bins.length ? h('div', { class: 'c-OK', text: 'Nothing obvious to remove.' }) : null,
    bins.map(b => h('div', { class: 'opt' }, h('div', { class: 't' }, h('b', { text: 'Recycle Bin on ' + b.Drive }),
      h('div', { text: 'Files you already deleted. They still take space until the bin is emptied.' })),
      h('span', { class: 'size', text: fmtSize(b.Size) }),
      btn('Empty', async () => {
        if (!await confirmBox('Empty the Recycle Bin on ' + b.Drive + '?', 'Frees ' + fmtSize(b.Size) + '. Files in it are gone for good.', 'Empty', true)) return;
        await task('bin', async () => { const f = await run('emptyBin', { drive: b.Drive }); toast('Freed ' + fmtSize(f) + '.'); });
        loadSpace();
      }, 'primary', 'bin'))),
    r.Safe.map(i => itemRow(i, safeSel)),
    h('div', { class: 'opt' }, h('div', { class: 't' }, h('b', { text: 'Junk files (temp files, caches, update leftovers)' }),
      h('div', { text: 'Handled on the Clean page - safe and automatic.' })), btn('Open Clean', () => go('clean'), 'link'))));

  // Review
  if (r.Review.length) {
    const byKind = {};
    r.Review.forEach(i => (byKind[i.Kind] = byKind[i.Kind] || []).push(i));
    root.append(h('div', { class: 'card' }, h('h3', {}, 'Worth a look', h('small', { text: fmtSize(r.Review.reduce((a, i) => a + i.Size, 0)) + ' in your Downloads - your call' })),
      h('p', { class: 'muted small', text: 'Nothing here is ticked for you. These are your own files; delete the ones you know you no longer need.' }),
      Object.entries(byKind).map(([k, list]) => [
        h('div', { class: 'row', style: 'margin:12px 0 4px' }, h('b', { text: k === 'Disk image' ? 'Disk images (.iso etc.)' : k === 'Installer' ? 'Old setup files' : 'Big archives' }),
          h('span', { class: 'muted small', text: fmtSize(list.reduce((a, i) => a + i.Size, 0)) }), h('span', { class: 'spacer' }),
          btn('Tick all', () => { list.forEach(i => revSel.add(i.Path)); render(); }, 'link'),
          btn('None', () => { list.forEach(i => revSel.delete(i.Path)); render(); }, 'link')),
        // same reason for every file in the group? say it once instead of on every row
        list.every(i => i.Why === list[0].Why) ? h('div', { class: 'muted small', text: list[0].Why }) : null,
        list.map(i => itemRow(i, revSel, list.every(x => x.Why === list[0].Why)))])));
  }

  // Move to another drive
  const sys = r.SystemDrive, best = r.Best;
  const sysDrive = r.Drives.find(d => d.Drive === sys), bestDrive = r.Drives.find(d => d.Drive === best);
  const canMove = best && best !== sys && bestDrive && sysDrive && bestDrive.Free > sysDrive.Free;
  const games = (r.Games || []).filter(g => g.Drive === sys);
  const vms = (r.VMs || []).filter(v => v.Drive === sys);
  if (canMove && (games.length || vms.length || r.DownloadsSize > 20 * 1073741824)) {
    root.append(h('div', { class: 'card' }, h('h3', {}, 'Move big things to ' + best, h('small', { text: best + ' has ' + fmtSize(bestDrive.Free) + ' free' })),
      h('p', { class: 'muted small', text: 'Moving keeps everything working - nothing is deleted. Use the steps for each one; CleanIT does not move these itself because Steam and VirtualBox need to do it to keep track of them.' }),
      games.length ? [h('b', { text: 'Steam games on ' + sys }),
        games.map(g => h('div', { class: 'opt' }, h('div', { class: 't' }, h('b', { text: g.Name })), h('span', { class: 'size', text: fmtSize(g.Size) }),
          btn('How to move', () => moveSteps('game', g, best), 'link')))] : null,
      vms.length ? [h('b', { text: 'Virtual machines on ' + sys }),
        vms.map(v => h('div', { class: 'opt' }, h('div', { class: 't' }, h('b', { text: v.Name }), h('div', { class: 'small muted', text: v.Path })), h('span', { class: 'size', text: fmtSize(v.Size) }),
          btn('How to move', () => moveSteps('vm', v, best), 'link')))] : null,
      r.DownloadsSize > 20 * 1073741824 ? h('div', { class: 'opt' }, h('div', { class: 't' }, h('b', { text: 'Your Downloads folder' }),
          h('div', { text: 'Move the whole Downloads folder to ' + best + ' so new downloads stop filling ' + sys + '.' })),
        h('span', { class: 'size', text: fmtSize(r.DownloadsSize) }), btn('How to move', () => moveSteps('downloads', null, best), 'link')) : null));
  }
}
async function deleteSpaceItems() {
  const r = S.cache.space;
  const list = r.Safe.filter(i => S.sel.spaceSafe.has(i.Path)).concat(r.Review.filter(i => S.sel.spaceReview.has(i.Path)));
  const total = list.reduce((a, i) => a + i.Size, 0);
  if (!await confirmBox('Delete ' + list.length + ' file' + (list.length > 1 ? 's' : '') + ' for good?', [
    h('p', { text: 'Frees ' + fmtSize(total) + '. These are deleted permanently - not moved to the Recycle Bin.' }),
    bullets(list.map(i => i.Name + '  (' + fmtSize(i.Size) + ')'), 20)], 'Delete ' + fmtSize(total), true)) return;
  await task('spacedel', async () => {
    const res = await run('spaceDelete', { paths: list.map(i => i.Path) }, prog('spacedel'));
    toast('Freed ' + fmtSize(res.Freed) + '.');
  });
  loadSpace();
}
function pathInput(key, def) {
  S.cache[key] = S.cache[key] || def;
  const id = 'places-' + key;
  return [h('input', { type: 'text', value: S.cache[key], list: id, style: 'width:320px', oninput: e => { S.cache[key] = e.target.value; } }),
          h('datalist', { id }, S.state.places.map(p => h('option', { value: p })))];
}
function diskSpace(root) {
  const node = S.cache.diskNode;
  root.append(h('div', { class: 'card' },
    h('div', { class: 'row' }, pathInput('spacePath', 'C:\\'), btn('Analyze', () => task('space', async () => {
      S.cache.diskNode = await run('diskScan', { path: S.cache.spacePath }, prog('space'));
    }), 'primary', 'space'),
    node && node.parent ? btn('Up', () => openNode(node.parent)) : null,
    node ? btn('Open in Explorer', () => openThing('path', { path: node.path })) : null),
    progLine('space'),
    h('p', { class: 'muted small', text: 'Links and online-only OneDrive files are not counted. Click a folder to look inside.' })));
  if (!node) { root.append(h('div', { class: 'empty', text: 'Pick a drive or folder and click Analyze.' })); return; }
  // breadcrumb
  const crumbs = []; let p = node.path;
  while (p && p.length >= node.root.length) { crumbs.unshift(p); if (p === node.root) break; const up = dirName(p); if (up === p) break; p = up; }
  root.append(h('div', { class: 'row', style: 'margin-bottom:10px' }, crumbs.map((c, i) => [i ? h('span', { class: 'muted', text: '\u203A' }) : null,
    h('a', { class: 'drill', onclick: () => openNode(c), text: i ? baseName(c) : c })]),
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
      checkbox('Include Windows, Program Files & AppData', !!S.cache.largeSys, v => S.cache.largeSys = v),
      btn('Find', () => task('large', async () => {
        const r = await run('largeFiles', { path: S.cache.largePath, minMB: S.cache.largeMin, days: S.cache.largeDays, includeSystem: !!S.cache.largeSys }, prog('large'));
        S.cache.large = r.items; S.sel.large = new Set();
      }), 'primary', 'large')),
    progLine('large')));
  const sum = L.reduce((a, f) => a + (sel.has(f.path) ? f.size : 0), 0);
  root.append(h('div', { class: 'row', style: 'margin-bottom:10px' },
    h('span', { class: 'muted', text: L.length ? L.length + ' files, ' + fmtSize(L.reduce((a, f) => a + f.size, 0)) + ' total. Nothing is deleted unless you tick it.' : 'Results appear here.' }),
    h('span', { class: 'spacer' }), sel.size ? h('b', { text: sel.size + ' ticked (' + fmtSize(sum) + ')' }) : null,
    btn('Send ticked to Recycle Bin', () => recycle('large', [...sel]), 'danger', 'recycle', !sel.size)));
  root.append(table({ id: 'large', rows: L, selKey: 'large', rowKey: f => f.path, height: 'calc(100vh - 380px)',
    columns: [
      { key: 'name', label: 'File', sort: f => baseName(f.path), render: f => h('div', { class: 'namecell' }, icon('file'), baseName(f.path)) },
      { key: 'size', label: 'Size', cls: 'num', descFirst: true, render: f => fmtSize(f.size) },
      { key: 'lastUsed', label: 'Last used', descFirst: true },
      { key: 'folder', label: 'Folder', cls: 'ell muted', sort: f => dirName(f.path), render: f => dirName(f.path), title: f => f.path },
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
      checkbox('Include Windows, Program Files & AppData', !!S.cache.dupSys, v => S.cache.dupSys = v),
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
    btn('Send ticked to Recycle Bin', () => {
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
  if (!await confirmBox('Send ' + list.length + ' file(s) to the Recycle Bin?', [h('p', { text: fmtSize(sum) + ' in total. You can restore them from the Recycle Bin.' }), bullets(list.map(f => f.path), 12)], 'Recycle', true)) return;
  await task('recycle', async () => {
    const r = await run('recycle', { paths });
    const gone = new Set(r.removed);
    if (kind === 'large') S.cache.large = S.cache.large.filter(f => !gone.has(f.path)); else S.cache.dups = S.cache.dups.filter(f => !gone.has(f.path));
    S.sel[kind] = new Set();
    toast(r.removed.length + ' file(s) moved to the Recycle Bin.');
  });
}

// ----- Startup
pages.startup = {
  title: 'Startup apps',
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
          if (await confirmBox('Undo startup changes?', 'Re-enable every startup item, task and service that CleanIT turned off.', 'Undo all'))
            await task('startupUndo', async () => { await run('startupUndo'); await loadStartup(); });
        }, '', 'startupUndo'),
        h('span', { class: 'spacer' }),
        checkbox('Show Microsoft items', !!S.state.settings.ShowMicrosoft, async v => { await saveSettings({ ShowMicrosoft: v }); loadStartup(); })),
      h('p', { class: 'muted small', text: 'Switch off what you don\'t need at sign-in. Services switched off are set to "Manual" (they still start when something needs them). Orange = unsigned or untrusted publisher.' }),
      progLine('startup')));
    if (!items) { root.append(h('div', { class: 'empty', text: 'Loading (checking signatures)...' })); return; }
    const on = items.filter(i => (i.id in ch ? ch[i.id] : i.Enabled)).length;
    root.append(h('p', { class: 'muted', text: on + ' of ' + items.length + ' start automatically.' }));
    root.append(table({ id: 'startup', rows: items, rowKey: i => i.id, height: 'calc(100vh - 330px)',
      rowClass: i => (i.Publisher || '').match(/unsigned|NOT valid/) ? 'c-WARN' : '',
      columns: [
        { key: 'on', label: 'On', nosort: true, render: i => toggle(i.id in ch ? ch[i.id] : i.Enabled, v => { if (v === i.Enabled) delete ch[i.id]; else ch[i.id] = v; render(); }) },
        { key: 'Name', label: 'Name', render: i => h('b', { text: i.Name }) },
        { key: 'Kind', label: 'Type', render: i => h('span', { class: 'pill INFO', text: { Run: 'App', Folder: 'Folder', Task: 'Task', Service: 'Service' }[i.Kind] }) },
        { key: 'Publisher', label: 'Publisher' },
        { key: 'Status', label: 'Status', render: i => i.Status || (i.Enabled ? 'Enabled' : 'Disabled') },
        { key: 'Command', label: 'Where / command', cls: 'ell muted', render: i => i.Location + ': ' + i.Command, title: i => i.Command },
        { key: 'open', label: '', nosort: true, render: i => i.Exe ? btn('Show', () => openThing('path', { path: i.Exe }), 'link') : '' }
      ] }));
  }
};
function loadStartup() {
  return task('startup', async () => { S.cache.startupChanges = {}; S.cache.startup = (await run('startupList', { includeMicrosoft: !!S.state.settings.ShowMicrosoft })).items; });
}
async function applyStartup() {
  const ch = S.cache.startupChanges || {};
  const changes = Object.entries(ch).map(([id, enable]) => ({ id, enable }));
  if (!changes.length) return;
  const items = S.cache.startup.filter(i => i.id in ch);
  let rp = false;
  if (items.some(i => i.Kind === 'Service')) { rp = await restorePointChoice(); if (rp === null) return; }
  await task('startupApply', async () => { await run('startupApply', { changes, restorePoint: rp }); toast(changes.length + ' startup change(s) applied.'); });
  await loadStartup();
}

// ----- Apps
pages.apps = {
  title: 'Apps',
  render(root) {
    root.append(tabs('apps', [['bloat', 'Bloatware & Store apps'], ['programs', 'Programs (uninstall)']]));
    if (curTab('apps', 'bloat') === 'bloat') appsBloat(root); else appsPrograms(root);
  }
};
function appsBloat(root) {
  const items = S.cache.bloat;
  if (!items) autoLoad('bloat', loadBloat);
  if (S.cache.deprov === undefined) S.cache.deprov = true;
  const sel = S.sel.bloat = S.sel.bloat || new Set();
  root.append(h('div', { class: 'card' },
    h('div', { class: 'row' },
      btn(sel.size ? 'Remove ' + sel.size + ' app' + (sel.size > 1 ? 's' : '') : 'Remove ticked', removeBloat, 'danger', 'bloatRemove', !sel.size),
      btn('Refresh', loadBloat, '', 'bloat'),
      btn('Reinstall removed apps...', showRemovedApps),
      h('span', { class: 'spacer' }),
      checkbox('Also stop them coming back for new users', S.cache.deprov, v => S.cache.deprov = v)),
    h('p', { class: 'muted small', text: 'Recommended ones are pre-ticked. System parts (Store, Defender, winget, shell) are never listed.' }),
    progLine('bloatRemove')));
  if (!items) { root.append(h('div', { class: 'empty', text: 'Loading Store apps...' })); return; }
  const order = a => a.known ? (a.recommended ? 0 : 1) : 2;
  root.append(table({ id: 'bloat', selKey: 'bloat', rowKey: a => a.name, height: 'calc(100vh - 320px)',
    rows: items.slice().sort((a, b) => order(a) - order(b) || a.label.localeCompare(b.label)), groupBy: order,
    groupLabel: g => ['Recommended to remove (ads, trials, retired apps)', 'Optional - remove only if you never use it', 'Other removable Store apps'][g],
    columns: [
      { key: 'label', label: 'App', render: a => h('b', { text: a.label }) },
      { key: 'name', label: 'Package', cls: 'muted' },
      { key: 'publisher', label: 'Publisher' },
      { key: 'installed', label: 'Installed', render: a => a.installed ? 'yes' : 'no' },
      { key: 'provisioned', label: 'For new users', render: a => a.provisioned ? 'yes' : 'no' }
    ] }));
}
function loadBloat() {
  return task('bloat', async () => {
    S.cache.bloat = (await run('bloatList')).items;
    S.sel.bloat = new Set(S.cache.bloat.filter(a => a.known && a.recommended).map(a => a.name));
  });
}
async function removeBloat() {
  const names = [...S.sel.bloat];
  const labels = S.cache.bloat.filter(a => names.includes(a.name)).map(a => a.label);
  if (!await confirmBox('Remove ' + names.length + ' app(s) for all users?', [bullets(labels, 25), h('p', { class: 'muted', text: 'You can reinstall them from the Microsoft Store (Reinstall removed apps).' })], 'Remove', true)) return;
  const rp = await restorePointChoice(); if (rp === null) return;
  await task('bloatRemove', async () => { await run('bloatRemove', { names, deprovision: S.cache.deprov, restorePoint: rp }, prog('bloatRemove')); toast('Apps removed.'); });
  await loadBloat();
}
async function showRemovedApps() {
  let items = [];
  try { items = (await run('removedApps')).items; } catch (e) { return toast(e.message, 'error'); }
  const body = items.length ? h('div', {}, items.slice().reverse().map(a => h('div', { class: 'opt' },
    h('div', { class: 't' }, h('b', { text: a.Label }), h('div', { text: a.Name + ' - removed ' + fmtAgo(a.Date) })),
    btn('Open in Store', () => openThing('url', { url: a.Family ? 'ms-windows-store://pdp/?PFN=' + a.Family : 'ms-windows-store://search/?query=' + encodeURIComponent(a.Label) }))))) :
    h('p', { class: 'muted', text: 'CleanIT has not removed any apps yet.' });
  await dialog('Reinstall removed apps', body, [{ id: 'x', text: 'Close' }]);
}
function appsPrograms(root) {
  const items = S.cache.programs;
  if (!items) autoLoad('programs', loadPrograms);
  const f = (S.cache.progFilter || '').toLowerCase();
  const sel = items && items.find(p => p.id === S.cache.progSel);
  root.append(h('div', { class: 'card' },
    h('div', { class: 'row' },
      h('input', { type: 'text', placeholder: 'Search programs...', value: S.cache.progFilter || '', style: 'width:260px', id: 'progsearch',
        oninput: e => { S.cache.progFilter = e.target.value; const pos = e.target.selectionStart; render(); const el = $('#progsearch'); el.focus(); el.setSelectionRange(pos, pos); } }),
      btn('Uninstall', () => sel && uninstallProgram(sel), 'danger', 'uninstall', !sel),
      btn('Find leftovers', () => sel && findLeftovers(sel), '', 'leftovers', !sel),
      btn('Open install folder', () => sel && sel.location && openThing('path', { path: sel.location }), '', null, !sel || !sel.location),
      h('span', { class: 'spacer' }), btn('Refresh', loadPrograms, 'link', 'programs')),
    h('p', { class: 'muted small', text: sel ? 'Selected: ' + sel.name : 'Click a program to select it. After uninstalling, CleanIT looks for leftover folders and registry keys.' }),
    progLine('uninstall') || progLine('leftovers')));
  if (!items) { root.append(h('div', { class: 'empty', text: 'Loading programs...' })); return; }
  const rows = items.filter(p => !f || p.name.toLowerCase().includes(f) || (p.publisher || '').toLowerCase().includes(f));
  root.append(table({ id: 'programs', rows, rowKey: p => p.id, selectedKey: S.cache.progSel, onRow: p => { S.cache.progSel = p.id; render(); }, height: 'calc(100vh - 320px)',
    columns: [
      { key: 'name', label: 'Program', render: p => h('b', { text: p.name }) },
      { key: 'publisher', label: 'Publisher' },
      { key: 'version', label: 'Version', cls: 'muted' },
      { key: 'size', label: 'Size', cls: 'num', descFirst: true, render: p => p.size > 0 ? fmtSize(p.size) : '' },
      { key: 'date', label: 'Installed', descFirst: true, sort: p => p.date || '' },
      { key: 'scope', label: 'For', cls: 'muted' }
    ] }));
}
function loadPrograms() { return task('programs', async () => { S.cache.programs = (await run('programsList')).items; }); }
async function uninstallProgram(p) {
  if (!await confirmBox('Uninstall ' + p.name + '?', 'Its own uninstaller will open - follow it to the end. Afterwards CleanIT shows any leftovers it finds.', 'Uninstall', true)) return;
  const rp = await restorePointChoice(); if (rp === null) return;
  await task('uninstall', async () => {
    const r = await run('uninstall', { id: p.id, restorePoint: rp }, prog('uninstall'));
    S.cache.progSel = null; S.cache.programs = null;
    if (r.gone) { if (r.hits.length) leftoversDialog(r.name, r.hits); else toast(r.name + ' uninstalled - no leftovers found.'); }
    else toast(r.name + ' still looks installed. If its uninstaller is open, finish it, then use Find leftovers.', 'warn');
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
    h('p', { class: 'muted', text: 'Nothing is ticked - check each one. Folders go to the Recycle Bin; registry keys are backed up to a .reg file first. If the program is still installed, these are its live files - leave them.' }),
    table({ id: 'left', rows: hits, selKey: 'left', rowKey: x => x.Path, onSel: draw, height: '50vh',
      columns: [
        { key: 'Type', label: 'Type', render: x => h('span', { class: 'pill INFO', text: x.Type }) },
        { key: 'Path', label: 'Path', cls: 'wrap' },
        { key: 'Size', label: 'Size', cls: 'num', render: x => x.Type === 'Folder' ? fmtSize(x.Size) : '' },
        { key: 'Reason', label: 'Why', cls: 'muted small' }
      ] }));
  draw();
  const c = await dialog('Leftovers of ' + name, wrap, [{ id: 'x', text: 'Close' }, { id: 'rm', text: 'Remove ticked', cls: 'danger' }], true);
  if (c !== 'rm' || !S.sel.left.size) return;
  await task('leftoversRemove', async () => { const r = await run('leftoversRemove', { paths: [...S.sel.left] }); toast(r.removed.length + ' leftover(s) removed.'); });
}

// ----- Drivers
const DRV_LEVEL = { Recommended: ['WARN', 'Recommended'], Optional: ['INFO', 'Optional'], NotNeeded: ['OK', 'Not needed'] };

// Builds the plain-English "what to do" list from the driver report.
function driverTodos(r) {
  const hidden = new Set(r.HiddenKeys || []);
  const todo = [];
  for (const g of r.Gpu || []) {
    if (g.Level === 'BAD') todo.push({ keys: ['gpu|' + g.Name + '|none'], title: 'Install a graphics driver', why: g.Text, act: g.Page ? ['Get the driver', g.Page] : null });
    else if (g.Level === 'WARN' && g.Latest) todo.push({ keys: ['gpu|' + g.Name + '|' + g.Latest], title: 'Update your ' + g.Vendor + ' graphics driver (' + g.Installed + ' \u2192 ' + g.Latest + ')',
      why: 'Fixes and performance improvements for games, straight from ' + g.Vendor + '. Download it, run it, and pick the "Express" option. Takes about 5 minutes - the screen may go black for a moment.',
      act: g.Download ? ['Download from ' + g.Vendor, g.Download] : ['Open ' + g.Vendor, g.Page] });
    else if (g.Level === 'WARN') todo.push({ keys: ['gpu|' + g.Name + '|' + g.Installed], title: 'Check your ' + g.Vendor + ' graphics driver', why: g.Text, act: g.Page ? ['Open ' + g.Vendor + ' drivers', g.Page] : null });
  }
  const broken = (r.Problems || []).filter(p => p.Level === 'WARN');
  if (broken.length) todo.push({ keys: [], title: 'Fix ' + broken.length + ' device' + (broken.length > 1 ? 's' : '') + ' that ' + (broken.length > 1 ? 'are' : 'is') + ' not working',
    why: broken.map(p => p.Problem).join('; ') + '. Use "Search driver" in the Devices section below.', act: null });
  // Recommended drivers - items that use the same tool (e.g. Intel Wi-Fi + Bluetooth) become one step
  const byLink = {};
  for (const o of (r.Outdated || []).filter(o => o.Level === 'Recommended')) {
    const k = o.Link;
    if (!byLink[k]) byLink[k] = { keys: [], names: [], whys: [], act: [o.Action, o.Link], provider: o.Provider, chipset: o.Key.startsWith('chipset|') };
    byLink[k].keys.push(o.Key); byLink[k].names.push(o.Title); byLink[k].whys.push(o.Why);
  }
  for (const g of Object.values(byLink)) {
    let title;
    if (g.chipset) title = 'Install the latest ' + g.provider + ' chipset drivers';
    else if (/intel/i.test(g.provider) && g.names.length > 1) title = 'Update Intel ' + g.names.map(n => /wi-?fi|wireless|802/i.test(n) && !/bluetooth/i.test(n) ? 'Wi-Fi' : /bluetooth/i.test(n) ? 'Bluetooth' : n).filter((v, i, a) => a.indexOf(v) === i).join(' and ') + ' drivers';
    else title = 'Update ' + g.names.join(', ');
    let why = g.whys[0];
    if (/intel/i.test(g.provider) && !g.chipset) why = (g.names.length > 1 ? 'Covers: ' + g.names.join(', ') + '. ' : '') + 'Intel\'s free Driver & Support Assistant finds and installs the right versions for you. ' + g.whys[0];
    todo.push({ keys: g.keys, title, why, act: g.act });
  }
  if (r.Bios && r.Bios.Level === 'WARN') todo.push({ keys: [r.Bios.Key], title: 'Update your BIOS (carefully)',
    why: 'Your BIOS (' + r.Bios.Version + ') is ' + Math.floor(r.Bios.Years) + ' years old. Updates include CPU security fixes. It takes about 10 minutes - follow the step-by-step guide.', bios: true });
  return todo.filter(t => !t.keys.length || !t.keys.every(k => hidden.has(k)));
}
async function markDriverDone(keys, hide) {
  await task('drvhide', async () => {
    for (const key of keys) await run('driverHide', { key, hide });
    const hk = new Set(S.cache.drivers.HiddenKeys || []);
    keys.forEach(k => hide ? hk.add(k) : hk.delete(k));
    S.cache.drivers.HiddenKeys = [...hk];
    for (const o of S.cache.drivers.Outdated || []) o.Hidden = hk.has(o.Key);
  });
}
function biosGuide(b) {
  const steps = b.Prebuilt ? [
    'Open ' + b.Tool + '.',
    'Let it check for updates and install the BIOS (it may be called "firmware" or "system update").',
    'Keep the PC plugged in and do not turn it off while it updates. It restarts by itself, sometimes more than once.'
  ] : [
    b.Revision ? 'Your board is ' + b.Target + ' revision ' + b.Revision + '. Only use BIOS files made for that revision.'
      : 'Find your board\'s revision: it is printed on the motherboard (often near the bottom-left, e.g. "REV 1.0") and on the box. Windows cannot read it on your board. Only use BIOS files for that exact revision.',
    'Click "Find BIOS download" below, open ' + b.Target + ' on the maker\'s own website (not another site), go to Support > BIOS, and download the newest version that is not marked "beta".',
    'Unzip the download and copy the files to an empty USB stick.',
    'Restart the PC and update using ' + b.Tool + '. Pick the file from the USB stick.',
    'Do not turn off the PC or press anything until it finishes and restarts by itself (5-10 minutes, it may restart more than once).',
    'Afterwards all BIOS settings are back to defaults. If you had turned on XMP/EXPO for your memory speed, turn it on again.'
  ];
  return dialog('How to update your BIOS safely', [
    h('p', { text: 'Your BIOS: ' + b.Version + ' from ' + b.Date + ' (' + b.Target + ').' }),
    h('ol', { class: 'steps' }, steps.map(s => h('li', { text: s }))),
    h('div', { class: 'notice warn', text: 'If the power goes out during the update, the PC may not start. Avoid doing it during storms or if your PC has been shutting down unexpectedly. If unsure, skip it - the PC still works fine with the old BIOS.' })
  ], [{ id: 'x', text: 'Close' }, { id: 'web', text: 'Find BIOS download', cls: 'primary' }]).then(c => { if (c === 'web') openThing('url', { url: b.Link }); });
}

pages.drivers = {
  title: 'Drivers',
  render(root) {
    const r = S.cache.drivers;
    if (!r) autoLoad('drivers', loadDrivers);
    root.append(h('div', { class: 'card' },
      h('div', { class: 'row' },
        btn('Check again', loadDrivers, 'primary', 'drivers'),
        btn('Windows Update drivers', () => { S.tab.upd = 'drv'; go('updates'); }),
        btn('Device Manager', () => openThing('devmgmt'), 'link'),
        h('span', { class: 'spacer' }),
        r ? h('span', { class: 'muted small', text: 'Checked ' + fmtAgo(r.Checked) }) : null),
      h('p', { class: 'muted small', text: 'Official sources only: Windows, NVIDIA\'s own driver lookup, and the makers\' websites. CleanIT never installs drivers from third-party driver databases - that is how "driver updaters" break PCs.' }),
      progLine('drivers')));
    if (!r) { root.append(h('div', { class: 'empty', text: 'Checking graphics drivers, devices, BIOS and the driver store...' })); return; }

    // 1) What to do - plain English, in order
    const todo = driverTodos(r);
    root.append(h('div', { class: 'card todo' }, h('h3', {}, 'What to do', h('small', { text: todo.length ? todo.length + ' step' + (todo.length > 1 ? 's' : '') + ', most important first' : '' })),
      !todo.length ? h('div', { class: 'c-OK', text: 'Nothing to do - your drivers are in good shape.' }) :
      h('ol', { class: 'todo-list' }, todo.map(t => h('li', {},
        h('div', { class: 't' }, h('b', { text: t.title }), h('div', { class: 'muted', text: t.why })),
        h('div', { class: 'row' },
          t.bios ? btn('Show me how', () => biosGuide(r.Bios), 'primary') : t.act ? btn(t.act[0], () => openThing('url', { url: t.act[1] }), 'primary') : null,
          t.keys.length ? btn('Done', () => markDriverDone(t.keys, true), 'link', 'drvhide') : null)))),
      (() => {
        const skip = (r.Outdated || []).filter(o => o.Level !== 'Recommended' && !o.Hidden);
        return skip.length ? h('p', { class: 'muted small', text: 'No need to do anything for: ' + skip.map(o => o.Title + (o.Level === 'NotNeeded' ? '' : ' (only if it gives you trouble)')).join(', ') + '.' }) : null;
      })()));

    // 2) Graphics
    root.append(h('div', { class: 'card' }, h('h3', {}, 'Graphics'),
      !r.Gpu.length ? h('div', { class: 'muted', text: 'No graphics card found.' }) :
      r.Gpu.map(g => h('div', { class: 'opt' },
        h('span', { class: 'pill ' + g.Level, text: g.Level === 'OK' ? 'Up to date' : g.Level === 'WARN' ? 'Update' : g.Level === 'BAD' ? 'Missing' : 'Check' }),
        h('div', { class: 't' }, h('b', { text: g.Name }), h('div', { text: g.Text }),
          h('div', { text: 'Installed ' + (g.Installed || '?') + (g.Date ? ' (' + g.Date + ')' : '') + (g.Latest ? '  -  latest ' + g.Latest : '') })),
        g.Page ? btn(g.Vendor + ' drivers page', () => openThing('url', { url: g.Page }), 'link') : null))));

    // 3) Devices
    const probs = r.Problems || [];
    root.append(h('div', { class: 'card' }, h('h3', {}, 'Devices', h('small', { text: probs.length ? probs.length + ' with problems' : 'all working' })),
      !probs.length ? h('div', { class: 'c-OK', text: 'Every device has a working driver.' }) :
      probs.map(p => h('div', { class: 'opt' }, h('span', { class: 'pill ' + p.Level, text: p.Level === 'INFO' ? 'Off' : 'Problem' }),
        h('div', { class: 't' }, h('b', { text: p.Name }), h('div', { text: p.Problem + (p.HardwareId ? '  -  ' + p.HardwareId : '') })),
        p.HardwareId ? btn('Search driver', () => openThing('url', { url: p.Link }), 'link') : null))));

    // 4) BIOS
    if (r.Bios) root.append(h('div', { class: 'card' }, h('h3', {}, 'BIOS / firmware'),
      h('div', { class: 'opt' }, h('span', { class: 'pill ' + r.Bios.Level, text: r.Bios.Level === 'OK' ? 'Recent' : 'Check' }),
        h('div', { class: 't' }, h('b', { text: r.Bios.Target + '  -  BIOS ' + r.Bios.Version }), h('div', { text: r.Bios.Text })),
        btn('How to update safely', () => biosGuide(r.Bios), 'link'))));

    // 5) All older drivers, sorted by what matters
    const all = r.Outdated || [];
    root.append(h('div', { class: 'card' }, h('h3', {}, 'Older drivers', h('small', { text: all.length + ' dated over 3 years ago' })),
      h('p', { class: 'muted small', text: 'An old date does not always mean an update exists - some makers keep old dates even on new versions. "Recommended" ones are in the to-do list above.' }),
      all.length ? table({ id: 'olddrv', rows: all, rowKey: d => d.Key, height: '360px', rowClass: d => d.Hidden ? 'muted' : '',
        columns: [
          { key: 'Level', label: 'Advice', sort: d => ({ Recommended: 0, Optional: 1, NotNeeded: 2 }[d.Level]), render: d => h('span', { class: 'pill ' + DRV_LEVEL[d.Level][0], text: d.Hidden ? 'Done' : DRV_LEVEL[d.Level][1] }) },
          { key: 'Title', label: 'Driver', render: d => h('div', {}, h('b', { text: d.Title }), h('div', { class: 'small muted', text: d.Why })), cls: 'wrap' },
          { key: 'Date', label: 'Date', render: d => d.Date + ' (' + d.Years + ' y)' },
          { key: 'x', label: '', nosort: true, render: d => h('div', { class: 'row', style: 'flex-wrap:nowrap' },
              btn(d.Action, () => openThing('url', { url: d.Link }), 'link'),
              btn(d.Hidden ? 'Show again' : 'Hide', () => markDriverDone([d.Key], !d.Hidden), 'link', 'drvhide')) }
        ] }) : h('div', { class: 'c-OK', text: 'No old third-party drivers.' })));

    // 6) Driver store cleanup
    const pk = r.Packages || [];
    const rem = pk.filter(p => p.Removable);
    const sel = S.sel.drvpk = S.sel.drvpk || new Set();
    const sum = rem.filter(p => sel.has(p.Published)).reduce((a, p) => a + p.Size, 0);
    root.append(h('div', { class: 'card' }, h('h3', {}, 'Old driver copies', h('small', { text: pk.length ? rem.length + ' removable, ' + fmtSize(rem.reduce((a, p) => a + p.Size, 0)) : '' })),
      h('p', { class: 'muted small', text: 'Optional clean-up. Windows keeps a copy of every driver version ever installed. CleanIT only offers older copies that no device uses and that have a newer version installed; Windows itself refuses to remove anything still in use. You lose "roll back driver" for those old versions.' }),
      !pk.length ? h('div', { class: 'muted', text: 'Needs administrator rights to read the driver store.' }) :
      !rem.length ? h('div', { class: 'c-OK', text: 'No old driver copies - nothing to clean.' }) : [
        h('div', { class: 'row', style: 'margin-bottom:10px' },
          btn('Tick all', () => { rem.forEach(p => sel.add(p.Published)); render(); }),
          h('span', { class: 'spacer' }), sel.size ? h('b', { text: sel.size + ' ticked (' + fmtSize(sum) + ')' }) : null,
          btn('Remove ticked', removeDriverPackages, 'danger', 'drvpk', !sel.size)),
        table({ id: 'drvpk', rows: rem, selKey: 'drvpk', rowKey: p => p.Published, height: '360px',
          columns: [
            { key: 'Name', label: 'Driver', render: p => h('b', { text: p.Name }) },
            { key: 'Provider', label: 'Maker' },
            { key: 'Class', label: 'Type', cls: 'muted' },
            { key: 'Version', label: 'Old version' },
            { key: 'NewestVersion', label: 'Kept (newest)', cls: 'muted' },
            { key: 'Size', label: 'Size', cls: 'num', descFirst: true, render: p => fmtSize(p.Size) }
          ] })]));
  }
};
function loadDrivers() { return task('drivers', async () => { S.cache.drivers = await run('drivers', {}, prog('drivers')); S.sel.drvpk = new Set(); }); }
async function removeDriverPackages() {
  const names = [...S.sel.drvpk];
  const list = S.cache.drivers.Packages.filter(p => names.includes(p.Published));
  if (!await confirmBox('Remove ' + names.length + ' old driver cop' + (names.length > 1 ? 'ies' : 'y') + '?', [bullets(list.map(p => p.Name + ' ' + p.Version + ' (' + p.Provider + ', ' + fmtSize(p.Size) + ')'), 15),
    h('p', { class: 'muted', text: 'Only unused older versions. The current drivers stay. Windows refuses anything still in use.' })], 'Remove', true)) return;
  const rp = await restorePointChoice(); if (rp === null) return;
  await task('drvpk', async () => { const r = await run('driverPackagesRemove', { names, restorePoint: rp }, prog('drvpk')); toast(r.removed.length + ' old driver cop' + (r.removed.length === 1 ? 'y' : 'ies') + ' removed.'); });
  loadDrivers();
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
      impPill('Optional'), ' only if you want  ', impPill('Automatic'), ' Windows does it for you.'));
    root.append(tabs('upd', [['apps', 'Apps (winget)'], ['win', 'Windows Update'], ['drv', 'Drivers']]));
    const t = curTab('upd', 'apps');
    if (t === 'apps') updApps(root); else updWindows(root, t === 'drv' ? 'Driver' : 'Software');
  }
};
function updApps(root) {
  const items = S.cache.winget;
  if (!items && S.state.winget) autoLoad('winget', loadWinget);
  const excl = new Set(S.state.settings.WingetExclude || []);
  const sel = S.sel.winget = S.sel.winget || new Set();
  const rec = (items || []).filter(u => u.Importance === 'Recommended' && !excl.has(u.Id)).length;
  root.append(h('div', { class: 'card' },
    !S.state.winget ? h('div', { class: 'notice warn', text: 'winget isn\'t available. Install "App Installer" from the Microsoft Store.' }) : null,
    items ? h('p', { style: 'margin-top:0', text: !items.length ? 'All your apps are up to date.' :
      rec ? rec + ' app update' + (rec > 1 ? 's are' : ' is') + ' recommended (security fixes). The rest are optional - new features and bug fixes.' :
      'No security-related app updates. The ones below are optional - new features and bug fixes.' }) : null,
    h('div', { class: 'row' },
      btn(sel.size ? 'Update ' + sel.size + ' app' + (sel.size > 1 ? 's' : '') : 'Update ticked', async () => {
        const ids = [...sel];
        if (!await confirmBox('Update ' + ids.length + ' app(s)?', 'Save your work first - some apps may close while they update.', 'Update')) return;
        await task('wingetUpdate', async () => { await run('wingetUpdate', { ids }, prog('wingetUpdate')); });
        loadWinget();
      }, 'primary', 'wingetUpdate', !sel.size),
      btn('Tick all', () => { (items || []).filter(u => !excl.has(u.Id)).forEach(u => sel.add(u.Id)); render(); }, '', null, !items),
      btn('Check again', loadWinget, '', 'winget')),
    h('p', { class: 'muted small', text: '"Never update" apps are skipped here, by the weekly task and by -Updates.' }),
    progLine('wingetUpdate')));
  if (!items) { root.append(h('div', { class: 'empty', text: S.busy.winget ? 'Checking for app updates...' : 'Click Check again.' })); return; }
  root.append(table({ id: 'winget', rows: items.slice().sort((a, b) => IMP_ORDER[a.Importance] - IMP_ORDER[b.Importance] || a.Name.localeCompare(b.Name)),
    selKey: 'winget', rowKey: u => u.Id, empty: 'All apps are up to date.', height: 'calc(100vh - 380px)', rowClass: u => excl.has(u.Id) ? 'muted' : '',
    columns: [
      { key: 'Importance', label: 'Advice', sort: u => IMP_ORDER[u.Importance], render: u => excl.has(u.Id) ? h('span', { class: 'pill INFO', text: 'Never update' }) : impPill(u.Importance) },
      { key: 'Name', label: 'App', cls: 'wrap', render: u => h('div', {}, h('b', { text: u.Name }), h('div', { class: 'small muted', text: u.Why })) },
      { key: 'Version', label: 'You have' },
      { key: 'Available', label: 'New', render: u => h('span', { class: 'pill accent', text: u.Available }) },
      { key: 'x', label: '', nosort: true, render: u => btn(excl.has(u.Id) ? 'Allow updates' : 'Never update', async () => {
          if (excl.has(u.Id)) excl.delete(u.Id); else { excl.add(u.Id); sel.delete(u.Id); }
          await saveSettings({ WingetExclude: [...excl] }); render();
        }, 'link') }
    ] }));
}
function loadWinget() {
  return task('winget', async () => {
    S.cache.winget = (await run('wingetList')).items;
    const excl = new Set(S.state.settings.WingetExclude || []);
    // pre-tick only the updates that matter
    S.sel.winget = new Set(S.cache.winget.filter(u => !excl.has(u.Id) && u.Importance === 'Recommended').map(u => u.Id));
  });
}
function updWindows(root, type) {
  const key = 'wu' + type, items = S.cache[key];
  const sel = S.sel[key] = S.sel[key] || new Set();
  const load = () => task(key, async () => {
    S.cache[key] = (await run('wuList', { type }, prog(key))).items;
    S.sel[key] = new Set(S.cache[key].filter(u => !u.NeedsInput && (u.Importance === 'Important' || u.Importance === 'Recommended')).map(u => u.Id));
  });
  if (!items && !S.busy[key] && !S.cache[key + 'Tried']) { S.cache[key + 'Tried'] = true; setTimeout(load); }
  const imp = (items || []).filter(u => u.Importance === 'Important').length;
  let summary = null;
  if (items) {
    if (!items.length) summary = type === 'Driver' ? 'No driver updates from Windows Update.' : 'Windows is up to date.';
    else if (type === 'Driver') summary = 'Driver updates from Windows Update are optional - install them only if a device has problems. Your graphics driver is better updated from the Drivers page.';
    else if (imp) summary = imp + ' important security update' + (imp > 1 ? 's' : '') + ' - install today. A restart will probably be needed.';
    else if (items.every(u => u.Importance === 'Automatic')) summary = 'Only automatic updates are waiting - Windows installs these by itself. Nothing to do.';
    else summary = 'No urgent updates. The ticked ones are worth installing when convenient.';
  }
  root.append(h('div', { class: 'card' },
    summary ? h('p', { style: 'margin-top:0', text: summary }) : null,
    h('div', { class: 'row' },
      btn(sel.size ? 'Install ' + sel.size + ' update' + (sel.size > 1 ? 's' : '') : 'Install ticked', async () => {
        const ids = [...sel];
        if (!await confirmBox('Install ' + ids.length + ' update(s)?', 'Downloading and installing can take a while. A restart may be needed afterwards.', 'Install')) return;
        await task(key + 'Install', async () => { await run('wuInstall', { type, ids }, prog(key + 'Install')); });
        load();
      }, 'primary', key + 'Install', !sel.size),
      btn('Check again', load, '', key),
      btn('Open Windows Update', () => openThing('url', { url: 'ms-settings:windowsupdate' }), 'link')),
    progLine(key) || progLine(key + 'Install')));
  if (!items) { root.append(h('div', { class: 'empty', text: S.busy[key] ? 'Searching Windows Update (can take a few minutes)...' : 'Click Check again.' })); return; }
  root.append(table({ id: key, rows: items.slice().sort((a, b) => IMP_ORDER[a.Importance] - IMP_ORDER[b.Importance]), selKey: key, rowKey: u => u.Id, empty: 'No updates available.', height: 'calc(100vh - 380px)',
    columns: [
      { key: 'Importance', label: 'Advice', sort: u => IMP_ORDER[u.Importance], render: u => impPill(u.Importance) },
      { key: 'Title', label: type === 'Driver' ? 'Driver update' : 'Update', cls: 'wrap', render: u => h('div', {}, h('b', { text: u.Title }),
          h('div', { class: 'small muted', text: u.NeedsInput ? 'Install this one from Windows Settings (it needs you to click through it).' : u.Why })) },
      { key: 'Size', label: 'Size', cls: 'num', descFirst: true, render: u => fmtSize(u.Size) },
      { key: 'Reboot', label: 'Restart', render: u => u.Reboot ? 'yes' : 'no' }
    ] }));
}

// ----- Privacy
pages.privacy = {
  title: 'Privacy',
  render(root) {
    const items = S.cache.privacy;
    if (!items) autoLoad('privacy', loadPrivacy);
    const ch = S.cache.privChanges = S.cache.privChanges || {};
    const n = Object.keys(ch).length;
    root.append(h('div', { class: 'card' },
      h('div', { class: 'row' },
        btn(n ? 'Apply ' + n + ' change' + (n > 1 ? 's' : '') : 'Apply', applyPrivacy, 'primary', 'privApply', !n),
        btn('Turn on all recommended', () => { for (const i of items || []) { if (i.recommended && !i.protected) ch[i.key] = true; } render(); }, '', null, !items),
        h('span', { class: 'spacer' }),
        btn('Restore everything CleanIT changed', async () => {
          if (!await confirmBox('Restore privacy settings?', 'Every setting CleanIT changed goes back to exactly how it was before.', 'Restore')) return;
          await task('privRestore', async () => { await run('privacyRestore'); }); loadPrivacy();
        }, '', 'privRestore'),
        btn('Restart Explorer', () => task('explorer', () => run('restartExplorer')), 'link', 'explorer')),
      h('p', { class: 'muted small', text: 'On = privacy protected. Original values are saved and can be restored. Some changes show up after restarting Explorer or signing out.' })));
    if (!items) { root.append(h('div', { class: 'empty', text: 'Reading settings...' })); return; }
    const groups = [['Ads', 'Ads & suggestions'], ['Telemetry', 'Data collection'], ['Search', 'Search'], ['AI', 'AI features']];
    for (const [g, label] of groups) {
      const list = items.filter(i => i.group === g);
      if (!list.length) continue;
      root.append(h('div', { class: 'card' }, h('h3', {}, label),
        list.map(i => h('div', { class: 'opt' },
          toggle(i.key in ch ? ch[i.key] : i.protected, v => { if (v === i.protected) delete ch[i.key]; else ch[i.key] = v; render(); }),
          h('div', { class: 't' }, h('b', { text: i.name }), h('div', { text: i.description })),
          i.recommended ? h('span', { class: 'pill accent', text: 'recommended' }) : null,
          i.protected ? h('span', { class: 'pill OK', text: 'on' }) : i.changed ? h('span', { class: 'pill WARN', text: 'partly' }) : h('span', { class: 'pill INFO', text: 'Windows default' })))));
    }
  }
};
function loadPrivacy() { return task('privacy', async () => { S.cache.privChanges = {}; S.cache.privacy = (await run('privacyList')).items; }); }
async function applyPrivacy() {
  const changes = Object.entries(S.cache.privChanges || {}).map(([key, protect]) => ({ key, protect }));
  if (!changes.length) return;
  const rp = await restorePointChoice(); if (rp === null) return;
  await task('privApply', async () => { await run('privacyApply', { changes, restorePoint: rp }); toast('Privacy settings applied.'); });
  loadPrivacy();
}

// ----- Security
pages.security = {
  title: 'Security',
  render(root) {
    const items = S.cache.security;
    if (!items) autoLoad('security', loadSecurity);
    root.append(h('div', { class: 'card' }, h('div', { class: 'row' },
      btn('Check again', loadSecurity, 'primary', 'security'),
      btn('Defender quick scan', () => secFix('QuickScan'), '', 'fixQuickScan'),
      btn('Update virus definitions', () => secFix('UpdateSignatures'), '', 'fixUpdateSignatures'),
      btn('Open Windows Security', () => openThing('url', { url: 'windowsdefender:' }), 'link')),
      progLine('fixQuickScan')));
    if (!items) { root.append(h('div', { class: 'empty', text: 'Checking antivirus, firewall, updates and Windows security features...' })); return; }
    const order = { BAD: 0, WARN: 1, INFO: 2, OK: 3 };
    const bad = items.filter(i => i.Level === 'BAD').length, warn = items.filter(i => i.Level === 'WARN').length;
    root.append(h('div', { class: 'card' }, h('h3', {}, bad ? bad + ' problem(s), ' + warn + ' warning(s)' : warn ? warn + ' warning(s)' : 'All good'),
      items.slice().sort((a, b) => order[a.Level] - order[b.Level]).map(i => h('div', { class: 'sec-row' },
        h('span', { class: 'pill ' + i.Level, text: i.Level }), h('b', { text: i.Name }), h('span', { class: 'muted', text: i.Detail }),
        i.Fix === 'OpenSecurity' ? btn('Open', () => openThing('url', { url: 'windowsdefender:' }), 'link') :
        i.Fix === 'GoUpdates' ? btn('Updates', () => go('updates'), 'link') :
        i.Fix === 'EnableFirewall' ? btn('Turn on', () => secFix('EnableFirewall'), 'primary', 'fixEnableFirewall') :
        i.Fix && i.Level !== 'OK' ? btn('Fix', () => secFix(i.Fix), 'link', 'fix' + i.Fix) : h('span')))));
  }
};
function loadSecurity() { return task('security', async () => { S.cache.security = (await run('security')).items; }); }
async function secFix(fix) {
  if (fix === 'EnableFirewall' && !await confirmBox('Turn on Windows Firewall?', 'For all network profiles (domain, private, public).', 'Turn on')) return;
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
      btn('Optimize drives', async () => { if (await confirmBox('Optimize drives?', 'SSDs get TRIM (never defragmented); hard disks get defragmented - the way Windows recommends.', 'Optimize')) task('optimize', () => run('optimize', {}, prog('optimize'))); }, '', 'optimize'),
      btn('Repair Windows (DISM + SFC)', async () => { if (await confirmBox('Repair Windows system files?', 'Runs DISM /RestoreHealth, then sfc /scannow. Takes 10-30 minutes; you can keep using the PC. Progress shows in Activity.', 'Start repair')) task('repair', () => run('repair', {}, prog('repair'))); }, '', 'repair'),
      btn('Battery report', () => task('battery', () => run('batteryReport')), '', 'battery'),
      btn('Fix network (flush DNS)', () => task('dns', async () => { await run('flushDns'); toast('DNS cache flushed.'); }), '', 'dns'),
      btn('Create restore point', () => task('rp', async () => { await run('restorePointNow', {}, prog('rp')); toast('Restore point created.'); }), '', 'rp')),
      progLine('optimize') || progLine('repair')));
    root.append(h('div', { class: 'card' }, text ? h('pre', { class: 'report', text }) : h('div', { class: 'empty', text: 'Gathering...' })));
  }
};
function loadHealth() { return task('health', async () => { S.cache.health = (await run('health')).text; }); }

// ----- Fleet
pages.fleet = {
  title: 'Fleet - all your PCs',
  render(root) {
    const f = S.state.fleet;
    if (f.Mode === 'off') {
      root.append(h('div', { class: 'card fleet-hero' }, icon('fleet'),
        h('div', { style: 'flex:1' },
          h('h2', { style: 'margin:0 0 6px', text: 'See all your PCs in one place' }),
          h('p', { class: 'muted', text: 'Every PC with CleanIT writes a small health report to a shared folder. This page shows them all: health score, free space, updates and problems.' }),
          f.OneDrive ? h('div', { class: 'row' },
            btn('Use my OneDrive (recommended)', () => task('fleetSetup', async () => { await run('fleetOneDrive'); await refreshState(); toast('Fleet is on - this PC reports to OneDrive.'); }), 'primary big', 'fleetSetup'),
            h('span', { class: 'muted small', text: 'Folder: ' + f.OneDrive + '\\CleanIT Fleet' })) :
            h('div', { class: 'notice warn', text: 'OneDrive is not signed in on this PC. Sign in to OneDrive for the easiest setup, or choose any shared folder below.' }),
          customFleetPath())));
      return;
    }
    const items = S.cache.fleet;
    if (!items) autoLoad('fleet', loadFleet);
    root.append(h('div', { class: 'card' },
      h('div', { class: 'row' },
        h('span', { class: 'pill ' + (f.Reachable ? 'OK' : 'BAD'), text: f.Reachable ? (f.Mode === 'onedrive' ? 'OneDrive' : 'Shared folder') : 'Folder not reachable' }),
        h('span', { class: 'muted ell', title: f.Path, text: f.Path }),
        h('span', { class: 'spacer' }),
        btn('Add a PC', addPc, 'primary', 'addpc'),
        btn('Report now', () => task('fleetWrite', async () => { await run('fleetWrite'); await loadFleet(); }), '', 'fleetWrite'),
        btn('Refresh', loadFleet, '', 'fleet'),
        btn('Change...', changeFleet, 'link'))));
    if (!items) { root.append(h('div', { class: 'empty', text: 'Reading reports...' })); return; }
    if (!items.length) root.append(h('div', { class: 'empty', text: 'No reports yet - click "Report now".' }));
    const sorted = items.slice().sort((a, b) => (b.Computer === S.state.computer) - (a.Computer === S.state.computer) || a.Computer.localeCompare(b.Computer));
    root.append(h('div', { class: 'pcs' }, sorted.map(r => {
      const me = r.Computer === S.state.computer;
      const stale = r.Time && (Date.now() - new Date(r.Time).getTime()) > 14 * 86400000;
      const issues = (r.Issues || []).slice(0, 3);
      return h('div', { class: 'pc' + (me ? ' me' : '') },
        h('div', { class: 'top' }, ring(r.Score, 64),
          h('div', { style: 'flex:1' }, h('h4', {}, r.Computer, me ? h('span', { class: 'pill accent', style: 'margin-left:8px', text: 'this PC' }) : null),
            h('div', { class: 'small ' + (stale ? 'c-WARN' : 'muted'), text: 'Report ' + fmtAgo(r.Time) + (stale ? ' - not seen for a while' : '') }),
            h('div', { class: 'small muted', text: (r.OS || '') + (r.Build ? ' (' + r.Build + ')' : '') }),
            h('div', { class: 'small' }, h('span', { class: 'muted', text: 'CleanIT ' + (r.Version || '?') + ' ' }),
              S.state.update && S.state.update.Latest && r.Version && newer(S.state.update.Latest, r.Version) ? h('span', { class: 'pill WARN', text: 'update available' }) : null))),
        h('dl', {},
          h('dt', { text: 'Free on C:' }), h('dd', { class: r.FreePct < 10 ? 'c-BAD' : r.FreePct < 20 ? 'c-WARN' : '', text: fmtSize(r.FreeBytes) + ' (' + r.FreePct + '%)' }),
          h('dt', { text: 'Freed by CleanIT' }), h('dd', { text: fmtSize(r.FreedTotal) }),
          h('dt', { text: 'Last clean' }), h('dd', { text: fmtAgo(r.LastClean) }),
          h('dt', { text: 'Updates waiting' }), h('dd', { text: Math.max(0, r.AppUpdates) + ' apps, ' + Math.max(0, r.WinUpdates) + ' Windows' }),
          h('dt', { text: 'Restart needed' }), h('dd', { class: r.PendingReboot ? 'c-WARN' : '', text: r.PendingReboot ? 'yes' : 'no' })),
        issues.length ? h('ul', {}, issues.map(i => h('li', { text: String(i).replace(/^\[(BAD|WARN|INFO)\]\s*/, '') }))) : h('div', { class: 'small c-OK', text: 'No problems reported.' }),
        !me ? h('div', { class: 'row end' }, btn('Remove from list', async () => {
          if (!await confirmBox('Remove ' + r.Computer + '?', 'Removes its report from this list. If CleanIT still runs on that PC, it will reappear after its next clean.', 'Remove')) return;
          await task('fleetRemove', () => run('fleetRemove', { computer: r.Computer })); loadFleet();
        }, 'link')) : null);
    })));
  }
};
function customFleetPath() {
  return h('details', { style: 'margin-top:14px' }, h('summary', { class: 'muted', text: 'Use a different folder (network share, NAS, Dropbox...)' }),
    h('div', { class: 'row', style: 'margin-top:8px' },
      h('input', { type: 'text', placeholder: '\\\\NAS\\CleanIT or D:\\Sync\\CleanIT', value: S.cache.fleetPath || '', style: 'width:360px', oninput: e => S.cache.fleetPath = e.target.value }),
      btn('Use this folder', () => task('fleetPath', async () => { await run('fleetSetPath', { path: S.cache.fleetPath || '' }); await refreshState(); }), '', 'fleetPath')),
    h('p', { class: 'muted small', text: 'Network shares: the weekly clean runs as SYSTEM, so the share must allow the PC\'s computer account to write. A synced folder (OneDrive, Dropbox) avoids that.' }));
}
async function changeFleet() {
  const c = await dialog('Fleet folder', [h('p', { text: 'Currently: ' + S.state.fleet.Path }), customFleetPath()],
    [{ id: 'x', text: 'Close' }, { id: 'off', text: 'Turn fleet reporting off', cls: 'danger' }]);
  if (c === 'off') { await task('fleetPath', () => run('fleetSetPath', { path: '' })); await refreshState(); }
  else await refreshState();
}
function loadFleet() { return task('fleet', async () => { S.cache.fleet = (await run('fleetList')).items; }); }
async function addPc() {
  const od = S.state.fleet.Mode === 'onedrive';
  const c = await dialog('Add a PC to your fleet', [
    od ? h('ol', { class: 'steps' },
        h('li', {}, 'Click ', h('b', { text: 'Create setup' }), '. CleanIT puts an "Add a PC - CleanIT setup" folder into your OneDrive fleet folder.'),
        h('li', {}, 'On the other PC (signed in to the same OneDrive), open that folder and double-click ', h('b', { text: 'Install CleanIT on this PC' }), '.'),
        h('li', {}, 'Click Yes on the Windows prompt. Done - it installs, turns on the weekly clean and shows up here.')) :
      h('ol', { class: 'steps' },
        h('li', {}, 'Click ', h('b', { text: 'Create setup' }), '. CleanIT creates an "Add a PC - CleanIT setup" folder.'),
        h('li', {}, 'Copy that folder to the other PC (USB stick, network...).'),
        h('li', {}, 'Double-click ', h('b', { text: 'Install CleanIT on this PC' }), ' and click Yes. It joins this fleet folder automatically.')),
    h('p', { class: 'muted small', text: 'The setup uses the same weekly-clean schedule as this PC.' })
  ], [{ id: 'x', text: 'Cancel' }, { id: 'desk', text: 'Put setup on my Desktop' }, { id: 'go', text: 'Create setup', cls: 'primary' }]);
  if (c !== 'go' && c !== 'desk') return;
  await task('addpc', async () => { await run('fleetSetup', { target: c === 'desk' ? 'desktop' : 'fleet' }); toast('Setup created - the folder is open in Explorer.'); });
}

// ----- Settings
pages.settings = {
  title: 'Settings',
  render(root) {
    const st = S.state, s = st.settings;
    S.cache.sched = S.cache.sched || { enabled: st.schedule, day: s.ScheduleDay, time: s.ScheduleTime, updates: !!s.ScheduleUpdates };
    const sc = S.cache.sched;
    root.append(
      h('div', { class: 'card' }, h('h3', {}, 'Safety'),
        h('div', { class: 'opt' }, toggle(!!s.RestorePoint, v => saveSettings({ RestorePoint: v }).then(render)),
          h('div', { class: 't' }, h('b', { text: 'Create a restore point before changes' }), h('div', { text: 'Before cleaning, removing apps, or changing privacy and services (once per session).' }))),
        st.protection === false ? h('div', { class: 'notice warn', text: 'System Protection (restore points) is OFF for the system drive - CleanIT will offer to turn it on.' }) : null,
        h('div', { class: 'row' }, btn('Create restore point now', () => task('rp', async () => { await run('restorePointNow', {}, prog('rp')); toast('Restore point created.'); }), '', 'rp'),
          btn('Open System Restore', () => openThing('restore'), 'link'))),
      h('div', { class: 'card' }, h('h3', {}, 'Weekly automatic clean', h('small', { text: 'runs as SYSTEM, catches up if the PC was off' })),
        h('div', { class: 'opt' }, toggle(sc.enabled, v => { sc.enabled = v; render(); }),
          h('div', { class: 't' }, h('b', { text: 'Clean the recommended categories every week' }), h('div', { text: 'You get a notification with the result.' }))),
        h('div', { class: 'row' },
          h('span', { class: 'muted', text: 'Day' }),
          h('select', { onchange: e => sc.day = e.target.value }, ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'].map(d => h('option', { value: d, selected: d === sc.day, text: d }))),
          h('span', { class: 'muted', text: 'Time' }),
          h('input', { type: 'time', value: sc.time, onchange: e => sc.time = e.target.value }),
          checkbox('Also update apps (winget)', sc.updates, v => sc.updates = v),
          h('span', { class: 'spacer' }),
          btn('Save schedule', () => task('sched', async () => { await run('scheduleSave', sc); await refreshState(); toast(sc.enabled ? 'Weekly clean scheduled.' : 'Weekly clean turned off.'); }), 'primary', 'sched'))),
      updatesCard(st),
      h('div', { class: 'card' }, h('h3', {}, 'Undo center'),
        h('div', { class: 'row' },
          btn('Undo startup changes', () => go('startup')),
          btn('Restore privacy settings', () => go('privacy')),
          btn('Reinstall removed apps...', showRemovedApps),
          btn('Registry backups folder', () => openThing('backups')),
          btn('System Restore', () => openThing('restore')))),
      h('div', { class: 'card' }, h('h3', {}, 'CleanIT ' + st.version),
        h('div', { class: 'row' },
          btn('Install (Start menu + desktop shortcut)', () => task('install', async () => { await run('installApp'); toast('Installed - use the Start menu or desktop shortcut from now on.'); }), 'primary', 'install'),
          btn('Remove shortcuts & tasks', async () => { if (await confirmBox('Remove CleanIT shortcuts and scheduled tasks?', 'Settings, logs and backups are kept.', 'Remove', true)) { await task('uninstallApp', () => run('uninstallApp')); refreshState(); } }, '', 'uninstallApp'),
          btn('Open logs', () => openThing('logs')),
          btn('Open data folder', () => openThing('data')),
          h('span', { class: 'spacer' }),
          btn('Quit CleanIT', async () => { if (await confirmBox('Quit CleanIT?', 'Stops CleanIT. The weekly clean still runs on schedule.', 'Quit')) { await api('/api/quit', {}); offline(); } }, 'link')),
        h('p', { class: 'muted small', text: 'Data: ' + st.dataDir + '  -  no ads, no telemetry, everything logged. MIT licensed.' })));
  }
};

// ---------------------------------------------------------------------------
// Background polling: jobs (also keeps the server alive) and the activity log
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
  } catch (e) { /* offline() already shown */ }
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
      const last = r.lines[r.lines.length - 1];
      $('#drawer-last').textContent = last.text;
    }
    logSince = r.next;
    setTimeout(pollLog, 1200);
  } catch (e) { /* stopped */ }
}
async function refreshState() { S.state = await api('/api/state'); render(); }

// ---------------------------------------------------------------------------
// Updates (from this project's GitHub releases)
// ---------------------------------------------------------------------------
function newer(a, b) {
  const x = String(a).split('.').map(Number), y = String(b).split('.').map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i++) { const d = (x[i] || 0) - (y[i] || 0); if (d) return d > 0; }
  return false;
}
function updateBanner(up) {
  return h('div', { class: 'card update-banner' },
    h('div', { class: 't' }, h('b', { text: 'CleanIT ' + up.Latest + ' is available' }), h('span', { class: 'muted', text: '  -  you have ' + up.Current })),
    btn('What\'s new', () => showReleaseNotes(up), 'link'),
    btn('Update now', updateNow, 'primary', 'update'),
    btn('Later', () => { S.updateDismissed = true; render(); }, 'link'));
}
function showReleaseNotes(up) {
  return dialog('What\'s new in CleanIT ' + up.Latest, h('pre', { class: 'notes', text: up.Notes || 'No release notes.' }), [{ id: 'x', text: 'Close' }], true);
}
async function checkUpdates(force) {
  const r = await run('updateCheck', { force: !!force });
  S.state.update = r;
  if (force) {
    if (r.Error) toast(r.Error, 'error');
    else toast(r.Available ? 'CleanIT ' + r.Latest + ' is available.' : 'CleanIT is up to date (' + r.Current + ').');
  }
  render();
}
async function updateNow() {
  const up = S.state.update;
  const ok = await confirmBox('Update CleanIT to ' + up.Latest + '?', [
    h('p', { text: 'CleanIT downloads the new version from GitHub, checks it, installs it and reopens itself. Your settings, history and fleet stay as they are. The current version is kept as a backup.' }),
    up.Notes ? h('pre', { class: 'notes', text: up.Notes }) : null], 'Update now');
  if (!ok) return;
  const r = await task('update', () => run('updateInstall', {}, prog('update')));
  if (r && r.updated) {
    offline(false, 'Updating to CleanIT ' + r.version + '...', 'CleanIT will open again in a new window in a few seconds. You can close this one.');
  } else if (r) { toast('CleanIT is already up to date.'); refreshState(); }
}
function updatesCard(st) {
  const s = st.settings, up = st.update || {};
  return h('div', { class: 'card' }, h('h3', {}, 'Updates'),
    h('div', { class: 'row', style: 'margin-bottom:6px' },
      h('span', { text: 'You have CleanIT ' + st.version + '.' }),
      up.Latest ? h('span', { class: up.Available ? 'c-WARN' : 'muted', text: up.Available ? 'Version ' + up.Latest + ' is available.' : 'That is the latest version.' }) : null,
      up.Checked ? h('span', { class: 'muted small', text: '(checked ' + fmtAgo(up.Checked) + ')' }) : null,
      h('span', { class: 'spacer' }),
      btn('Check now', () => task('updCheck', () => checkUpdates(true)), '', 'updCheck'),
      up.Available ? btn('Update now', updateNow, 'primary', 'update') : null,
      up.Url ? btn('Release notes', () => showReleaseNotes(up), 'link') : null),
    h('div', { class: 'opt' }, toggle(s.UpdateCheck !== false, v => saveSettings({ UpdateCheck: v }).then(render)),
      h('div', { class: 't' }, h('b', { text: 'Check for updates when CleanIT opens' }), h('div', { text: 'Looks at github.com/Juicethekidd99/CleanIT at most every 6 hours. Nothing is installed without asking.' }))),
    h('div', { class: 'opt' }, toggle(!!s.AutoUpdate, v => saveSettings({ AutoUpdate: v }).then(render)),
      h('div', { class: 't' }, h('b', { text: 'Install updates automatically during the weekly clean' }),
        h('div', { text: 'Keeps every PC in your fleet current without you touching it. Only downloads from your GitHub repository, and checks the files before installing. Protect your GitHub account with two-factor login if you turn this on.' }))),
    progLine('update'));
}

async function init() {
  $('#drawer-head').addEventListener('click', () => $('#drawer').classList.toggle('collapsed'));
  try { S.state = await api('/api/state'); } catch (e) { return; }
  $('#nav-foot').textContent = S.state.computer + '  -  v' + S.state.version + (S.state.isAdmin ? '' : '  -  NOT ADMIN');
  const hash = location.hash.slice(1);
  if (pages[hash]) S.page = hash;
  render();
  ping(); pollLog();
  if (S.state.settings.UpdateCheck !== false) checkUpdates(false).catch(() => {});   // quiet; cached for 6 h on the server
}
window.addEventListener('hashchange', () => { const p = location.hash.slice(1); if (pages[p] && p !== S.page) { S.page = p; render(); } });
init();
