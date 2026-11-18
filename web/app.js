// ScamShield iPhone web app. Talks to the Mac agent over the API in docs/API.md.
// No dependencies, no build step. All untrusted text (names, summaries, transcripts)
// goes into the DOM through textContent via h(); innerHTML is only used for the
// static icon markup below.

const BUCKETS = ['attention', 'review', 'scam'];
const TITLES = { attention: 'Attention', review: 'Review', scam: 'Scams', settings: 'Settings' };
const CATEGORIES = {
  attention: ['personal', 'known_contact', 'appointment', 'medical', 'delivery', 'recruiter', 'business',
    'financial_legit', 'callback_request', 'repeated_caller'],
  review: ['no_message', 'unclear'],
  scam: ['fraud', 'robocall', 'loan_offer', 'telemarketing', 'spam_other', 'blocked'],
};
const CATEGORY_LABELS = {
  personal: 'Personal', known_contact: 'Contact', appointment: 'Appointment', medical: 'Medical',
  delivery: 'Delivery', recruiter: 'Recruiter', business: 'Business', financial_legit: 'Bank / Finance',
  callback_request: 'Call-back request', repeated_caller: 'Repeated caller', no_message: 'No message',
  unclear: 'Unclear', fraud: 'Fraud', robocall: 'Robocall', loan_offer: 'Loan offer',
  telemarketing: 'Telemarketing', spam_other: 'Other spam', blocked: 'Blocked',
};
const DEFAULT_CATEGORY = { attention: 'personal', review: 'unclear', scam: 'spam_other' };
const POLL_MS = 60_000;
const TIMEOUT_MS = 8_000;
const CACHE_KEY = 'scamshield.items.v1';

const ICONS = {
  chevron: '<svg viewBox="0 0 8 14"><path d="m1.2 1.2 5.6 5.8-5.6 5.8" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  back: '<svg viewBox="0 0 13 21"><path d="M11 2 2.5 10.5 11 19" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  phone: '<svg viewBox="0 0 24 24"><path fill="currentColor" d="M6.6 10.8a15.1 15.1 0 0 0 6.6 6.6l2.2-2.2a1 1 0 0 1 1-.25c1.1.37 2.3.57 3.6.57a1 1 0 0 1 1 1V20a1 1 0 0 1-1 1A17 17 0 0 1 3 4a1 1 0 0 1 1-1h3.5a1 1 0 0 1 1 1c0 1.25.2 2.45.57 3.57a1 1 0 0 1-.25 1z"/></svg>',
  voicemail: '<svg viewBox="0 0 24 24"><g fill="none" stroke="currentColor" stroke-width="2"><circle cx="6.5" cy="12" r="3.5"/><circle cx="17.5" cy="12" r="3.5"/><path d="M6.5 15.5h11"/></g></svg>',
  check: '<svg viewBox="0 0 24 24"><path d="m5 12.5 4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  checkCircle: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="m8 12.3 2.8 2.8L16.2 9.6"/></svg>',
  warning: '<svg viewBox="0 0 24 24"><path d="M12 3.5 2.5 20h19Z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/><path d="M12 10v4.5" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="17.2" r="1.2" fill="currentColor"/></svg>',
  info: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 11v5.5"/><circle cx="12" cy="7.8" r="1.1" fill="currentColor" stroke="none"/></svg>',
  person: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="8" r="4.2"/><path d="M3.8 20.5c.8-4 4.2-6.5 8.2-6.5s7.4 2.5 8.2 6.5Z"/></svg>',
  shieldX: '<svg viewBox="0 0 28 28"><path d="M14 3.5c3 1.8 6 2.4 8.5 2.4v7c0 5.6-3.5 9-8.5 11.3-5-2.3-8.5-5.7-8.5-11.3v-7c2.5 0 5.5-.6 8.5-2.4Z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/><path d="m11 11 6 6m0-6-6 6" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
  shieldCheck: '<svg viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3.5c3 1.8 6 2.4 8.5 2.4v7c0 5.6-3.5 9-8.5 11.3-5-2.3-8.5-5.7-8.5-11.3v-7c2.5 0 5.5-.6 8.5-2.4Z"/><path d="m10.2 14.2 2.6 2.6 5-5.3"/></svg>',
  offline: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M2 8.8a15 15 0 0 1 20 0M5 12.4a10 10 0 0 1 14 0M8.5 15.8a5 5 0 0 1 7 0"/><circle cx="12" cy="19.5" r="1" fill="currentColor"/><path d="M3 3l18 18"/></svg>',
  folder: '<svg viewBox="0 0 24 24"><path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h4.6l2 2.2h8.4A1.5 1.5 0 0 1 21 8.7v9.8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5Z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/></svg>',
  block: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="m5.6 5.6 12.8 12.8"/></svg>',
  archive: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"><rect x="3" y="4" width="18" height="4.5" rx="1"/><path d="M5 8.5V19a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8.5M10 12.5h4"/></svg>',
  reopen: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/></svg>',
  share: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12M8 7l4-4 4 4"/><path d="M8 10H6a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-9a1 1 0 0 0-1-1h-2"/></svg>',
  bell: '<svg viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"><path d="M14 3.5c-4 0-7 3-7 7v4.6l-2 3.4h18l-2-3.4v-4.6c0-4-3-7-7-7Z"/><path d="M11 21.5a3 3 0 0 0 6 0"/></svg>',
  addSquare: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3.5" y="3.5" width="17" height="17" rx="4"/><path d="M12 8v8M8 12h8"/></svg>',
};

// ---------------------------------------------------------------- state

const state = {
  buckets: { attention: null, review: null, scam: null }, // arrays of Item once loaded
  counts: null,
  signature: '',
  fetchedAt: 0,        // ms of last successful /api/items round
  cachedAt: 0,         // ms the cached snapshot was saved, while showing cache
  offline: false,
  error: null,
  inflight: null,
  rerun: false,       // a mutation happened while a fetch was in flight
  lastAttempt: 0,
  showDoneScams: false,
  noMessageOpen: false,
  detailCache: {},     // id -> Item fetched directly (cold deep link)
  detailError: {},     // id -> message
  status: null,
  statusError: null,
  blocklist: null,
  blocklistError: null,
  settingsSignature: '',
  push: null,          // { kind: 'on'|'off'|'denied'|'unsupported'|'needs-install' }
  route: null,
  scroll: {},
  pushedDetail: false,
  sheet: null,
};

const $ = (sel) => document.querySelector(sel);
const main = $('#main');
const navbar = $('#navbar');
const bannerEl = h('div', { id: 'banner' });
const subtitleEl = h('p', { class: 'subtitle' });

// ---------------------------------------------------------------- DOM helpers

function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (value == null || value === false) continue;
    if (key === 'class') el.className = value;
    else if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
    else if (key === 'checked' || key === 'disabled') el[key] = Boolean(value);
    else el.setAttribute(key, value === true ? '' : value);
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false) continue;
    el.append(kid instanceof Node ? kid : String(kid));
  }
  return el;
}

function icon(name, cls) {
  const tpl = document.createElement('template');
  tpl.innerHTML = ICONS[name];
  const el = tpl.content.firstElementChild;
  el.setAttribute('aria-hidden', 'true');
  el.setAttribute('focusable', 'false');
  if (cls) el.setAttribute('class', cls);
  return el;
}

function section(header, body, footer, extraClass) {
  return h('section', { class: 'section' + (extraClass ? ' ' + extraClass : '') },
    header ? h('h2', { class: 'section-header' }, header) : null,
    body,
    footer ? h('p', { class: 'section-footer' }, footer) : null);
}

function cell(label, value, opts = {}) {
  return h('li', {}, h('div', { class: 'cell' },
    opts.dot ? h('span', { class: 'dot dot--' + opts.dot, 'aria-hidden': 'true' }) : null,
    h('span', { class: 'cell-label' }, label, opts.sub ? h('span', { class: 'cell-sub' }, opts.sub) : null),
    value != null ? h('span', { class: 'cell-value' }, value) : null,
    opts.trailing || null));
}

function actionCell(label, onclick, { iconName, destructive, disabled } = {}) {
  return h('li', {}, h('button', {
    type: 'button', class: 'cell ' + (destructive ? 'cell--destructive' : 'cell--action'), onclick, disabled,
  }, iconName ? icon(iconName, 'cell-icon') : null, h('span', { class: 'cell-label' }, label)));
}

function emptyState(iconName, title, text, action) {
  return h('div', { class: 'empty' }, icon(iconName), h('h2', {}, title), text ? h('p', {}, text) : null, action || null);
}

function spinner() {
  return h('div', { class: 'loading', role: 'status' }, h('span', { class: 'spinner is-spinning' }),
    h('span', { class: 'sr-only' }, 'Loading'));
}

// ---------------------------------------------------------------- formatting

const fmtTime = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
const fmtWeekday = new Intl.DateTimeFormat(undefined, { weekday: 'long' });
const fmtShortWeekday = new Intl.DateTimeFormat(undefined, { weekday: 'short' });
const fmtDate = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' });
const fmtDateYear = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
const fmtRelative = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });
const fmtNumber = new Intl.NumberFormat();

function parseDate(value) {
  const d = value instanceof Date ? value : new Date(value);
  return isNaN(d) ? null : d;
}

function dayDiff(d) {
  const start = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  return Math.round((start(new Date()) - start(d)) / 86_400_000);
}

// Row timestamp: "Now", "12m ago", "3:42 PM", "Yesterday", "Mon", "Nov 2".
function relTime(value) {
  const d = parseDate(value);
  if (!d) return '';
  const secs = (Date.now() - d) / 1000;
  if (secs < 60) return 'Now';
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
  const days = dayDiff(d);
  if (days === 0) return fmtTime.format(d);
  if (days === 1) return 'Yesterday';
  if (days < 7) return fmtShortWeekday.format(d);
  return (d.getFullYear() === new Date().getFullYear() ? fmtDate : fmtDateYear).format(d);
}

// Long form: "Today at 3:42 PM", "Monday, Nov 16 at 3:42 PM".
function longDate(value) {
  const d = parseDate(value);
  if (!d) return '';
  const days = dayDiff(d);
  const time = fmtTime.format(d);
  if (days === 0) return `Today at ${time}`;
  if (days === 1) return `Yesterday at ${time}`;
  const date = (d.getFullYear() === new Date().getFullYear() ? fmtDate : fmtDateYear).format(d);
  return `${days < 7 ? fmtWeekday.format(d) + ', ' : ''}${date} at ${time}`;
}

// Settings-style: "2 minutes ago", "yesterday".
function ago(value) {
  const d = parseDate(value);
  if (!d) return 'Never';
  const secs = Math.round((d - Date.now()) / 1000);
  const abs = Math.abs(secs);
  if (abs < 45) return 'Just now';
  if (abs < 3600) return fmtRelative.format(Math.round(secs / 60), 'minute');
  if (abs < 86_400) return fmtRelative.format(Math.round(secs / 3600), 'hour');
  return fmtRelative.format(Math.round(secs / 86_400), 'day');
}

function snapshotTime(ms) {
  const d = new Date(ms);
  return dayDiff(d) === 0 ? fmtTime.format(d) : longDate(d);
}

function duration(sec) {
  const s = Math.max(0, Math.round(Number(sec) || 0));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

function pct(x) {
  return x == null || isNaN(x) ? '–' : `${Math.round(Number(x) * 100)}%`;
}

function plural(n, word) {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}

function categoryLabel(category) {
  return CATEGORY_LABELS[category] || String(category || 'Other').replace(/_/g, ' ');
}

// Scam callers often claim to be someone they are not, so only trust Contacts there.
function callerName(item) {
  const claimed = item.bucket !== 'scam' && (item.caller?.organization || item.caller?.name);
  return item.contactName || claimed || item.displayNumber || item.number || 'No Caller ID';
}

function callerDetail(item) {
  const parts = [];
  const name = callerName(item);
  const org = item.caller?.organization;
  const person = item.caller?.name;
  if (item.bucket === 'scam' && !item.contactName && (org || person)) parts.push(`Claims to be ${org || person}`);
  else if (org && person && name === org) parts.push(person);
  const number = item.displayNumber || item.number;
  if (number && number !== name) parts.push(number);
  if (!number) parts.push('Caller ID withheld');
  return parts.join(' · ');
}

function initials(name) {
  const words = name.replace(/[^\p{L}\s]/gu, '').trim().split(/\s+/).filter(Boolean);
  return words.slice(0, 2).map((w) => w[0].toUpperCase()).join('');
}

function avatar(item, large) {
  const cls = 'avatar' + (large ? ' avatar--lg' : '');
  if (item.bucket === 'scam') return h('span', { class: cls + ' avatar--scam', 'aria-hidden': 'true' }, icon('warning'));
  const named = item.contactName || item.caller?.organization || item.caller?.name;
  const letters = named ? initials(callerName(item)) : '';
  const tint = item.bucket === 'attention' ? ' avatar--attention' : '';
  return h('span', { class: cls + tint, 'aria-hidden': 'true' }, letters || icon('person'));
}

function chip(item) {
  return h('span', { class: `chip chip--${item.bucket}` }, categoryLabel(item.category));
}

function showsCallBack(item) {
  return Boolean(item.number) && (item.callback?.recommended || item.bucket === 'attention');
}

// FaceTime calls can come from an Apple ID email instead of a phone number. Those can be
// called back over FaceTime, but not dialled, blocked or looked up in the reputation data.
function isPhoneNumber(number) {
  return typeof number === 'string' && number !== '' && !number.includes('@');
}

function callBackLink(item) {
  return isPhoneNumber(item.number)
    ? { href: `tel:${item.number}`, label: 'Call Back' }
    : { href: `facetime-audio:${item.number}`, label: 'Call Back with FaceTime' };
}

function hasDuration(vm) {
  return Number(vm?.durationSec) > 0;
}

// ---------------------------------------------------------------- API

class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
    this.offline = status === 0;
  }
}

async function api(path, { method = 'GET', body } = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  let res;
  try {
    res = await fetch(path, {
      method,
      cache: 'no-store',
      signal: ctrl.signal,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new ApiError("Can't reach your Mac. It may be asleep or offline.", 0);
  } finally {
    clearTimeout(timer);
  }
  let data = null;
  try {
    data = await res.json();
  } catch {
    if (res.ok) throw new ApiError('The Mac sent an unreadable response.', res.status);
  }
  if (!res.ok) throw new ApiError(data?.error || `The Mac agent returned an error (${res.status}).`, res.status);
  return data;
}

const itemPath = (id) => `api/items/${encodeURIComponent(id)}`;

function errorMessage(err) {
  return err instanceof ApiError ? err.message : `Something went wrong: ${err?.message || err}`;
}

// ---------------------------------------------------------------- data

function saveCache(results) {
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify({ savedAt: Date.now(), results }));
  } catch { /* storage full or disabled: offline view just won't have data */ }
}

function loadCache() {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    const snap = raw && JSON.parse(raw);
    if (!snap?.results) return;
    applyResults(snap.results);
    state.cachedAt = snap.savedAt || 0;
  } catch { /* corrupt cache: ignore */ }
}

function applyResults(results) {
  for (const b of BUCKETS) if (results[b]) state.buckets[b] = results[b].items || [];
  state.counts = results.scam?.counts || results.attention?.counts || state.counts;
}

// If a fetch is already running it may predate a mutation, so queue one more
// round once it settles rather than trusting its (possibly stale) response.
function refresh() {
  if (state.inflight) {
    state.rerun = true;
    return state.inflight;
  }
  state.lastAttempt = Date.now();
  const before = bannerKey();
  state.inflight = (async () => {
    try {
      const responses = await Promise.all(BUCKETS.map((b) => {
        const done = b === 'scam' && state.showDoneScams ? 1 : 0;
        return api(`api/items?bucket=${b}&include_done=${done}&limit=200`);
      }));
      const results = Object.fromEntries(BUCKETS.map((b, i) => [b, responses[i]]));
      const signature = JSON.stringify(responses.map((r) => [r.items, r.counts]));
      const changed = signature !== state.signature;
      state.signature = signature;
      applyResults(results);
      Object.assign(state, { fetchedAt: Date.now(), cachedAt: 0, offline: false, error: null });
      saveCache(results);
      dataChanged(changed || before !== bannerKey());
    } catch (err) {
      state.offline = err instanceof ApiError && err.offline;
      state.error = state.offline ? null : errorMessage(err);
      dataChanged(before !== bannerKey() || !state.buckets.attention);
    } finally {
      state.inflight = null;
      if (state.rerun) {
        state.rerun = false;
        refresh();
      }
    }
  })();
  return state.inflight;
}

function refreshAll() {
  return Promise.all([refresh(), state.route?.name === 'settings' ? loadSettingsData() : null]);
}

function bannerKey() {
  return `${state.offline}|${state.error}|${state.cachedAt}`;
}

function dataChanged(rerender) {
  updateBadges();
  updateChrome();
  const name = state.route?.name;
  if (rerender && BUCKETS.includes(name)) render();
  if (name === 'item' && !findItem(state.route.id) && !state.detailCache[state.route.id]) render();
}

function allItems() {
  return BUCKETS.flatMap((b) => state.buckets[b] || []);
}

function findItem(id) {
  return allItems().find((i) => i.id === id) || state.detailCache[id] || null;
}

// Put the server's copy of an item into the right bucket list, keeping date order.
function replaceItem(updated) {
  for (const b of BUCKETS) {
    if (state.buckets[b]) state.buckets[b] = state.buckets[b].filter((i) => i.id !== updated.id);
  }
  const list = state.buckets[updated.bucket];
  if (list) {
    const at = list.findIndex((i) => i.date < updated.date);
    list.splice(at === -1 ? list.length : at, 0, updated);
  }
  if (state.detailCache[updated.id]) state.detailCache[updated.id] = updated;
}

function adjustOpenCount(bucket, delta) {
  const c = state.counts?.[bucket];
  if (c) c.open = Math.max(0, c.open + delta);
  updateBadges();
}

async function loadBlocklist() {
  try {
    state.blocklist = (await api('api/blocklist')).numbers || [];
    state.blocklistError = null;
  } catch (err) {
    state.blocklistError = errorMessage(err);
  }
}

async function loadSettingsData() {
  const [status] = await Promise.allSettled([api('api/status'), loadBlocklist()]);
  if (status.status === 'fulfilled') {
    state.status = status.value;
    state.statusError = null;
  } else {
    state.statusError = errorMessage(status.reason);
  }
  state.push = await pushState();
  const signature = JSON.stringify([state.status, state.statusError, state.blocklist, state.blocklistError, state.push]);
  if (signature !== state.settingsSignature && state.route?.name === 'settings') render();
  state.settingsSignature = signature;
}

// ---------------------------------------------------------------- mutations

async function setDone(item, done) {
  const prev = item.done;
  item.done = done;
  adjustOpenCount(item.bucket, done ? -1 : 1);
  if (BUCKETS.includes(state.route?.name)) render();
  try {
    const updated = await api(`${itemPath(item.id)}/done`, { method: 'POST', body: { done } });
    replaceItem(updated);
    if (BUCKETS.includes(state.route?.name)) render();
    toast(done ? 'Marked as done' : 'Moved back to open', { action: 'Undo', onAction: () => setDone(updated, !done) });
    refresh();
  } catch (err) {
    item.done = prev;
    adjustOpenCount(item.bucket, done ? 1 : -1);
    if (BUCKETS.includes(state.route?.name) || state.route?.id === item.id) render();
    toast(errorMessage(err));
  }
}

async function label(item, bucket, category, applyToNumber) {
  try {
    const updated = await api(`${itemPath(item.id)}/label`, {
      method: 'POST', body: { bucket, category, applyToNumber },
    });
    replaceItem(updated);
    toast(`Moved to ${TITLES[updated.bucket]} · ${categoryLabel(updated.category)}`);
    if (state.route?.id === item.id) render();
    refresh();
    return true;
  } catch (err) {
    toast(errorMessage(err));
    return false;
  }
}

async function setBlocked(number, block) {
  try {
    await api('api/blocklist', { method: 'POST', body: { number, block } });
    toast(block ? 'Number blocked' : 'Number unblocked');
    await loadBlocklist();
    if (state.route?.name === 'settings') render();
    updateBlockCell();
    refresh();
  } catch (err) {
    toast(errorMessage(err));
  }
}

function confirmBlock(item, block) {
  const who = item.displayNumber || item.number;
  actionSheet({
    title: block ? `Block ${who}?` : `Unblock ${who}?`,
    message: block
      ? 'Future calls from this number will be filed under Scams as blocked.'
      : 'Calls from this number will be screened normally again.',
    actions: [{ label: block ? 'Block Number' : 'Unblock Number', destructive: block, onSelect: () => setBlocked(item.number, block) }],
  });
}

function confirmArchiveAll() {
  const open = (state.buckets.scam || []).filter((i) => !i.done).length;
  actionSheet({
    title: 'Archive all scam calls?',
    message: `${plural(open, 'call')} will be marked as done. Turn on “Show done” to see them again.`,
    actions: [{
      label: `Archive ${plural(open, 'Call')}`,
      destructive: true,
      onSelect: async () => {
        try {
          const res = await api('api/bulk/done', { method: 'POST', body: { bucket: 'scam' } });
          toast(`Archived ${plural(res.updated ?? open, 'call')}`);
          await refresh();
          render();
        } catch (err) {
          toast(errorMessage(err));
        }
      },
    }],
  });
}

// ---------------------------------------------------------------- push

const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const isStandalone = () => navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;

async function pushState() {
  if (isIOS && !isStandalone()) return { kind: 'needs-install' };
  if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) return { kind: 'unsupported' };
  if (Notification.permission === 'denied') return { kind: 'denied' };
  try {
    const reg = await navigator.serviceWorker.getRegistration();
    const sub = reg && (await reg.pushManager.getSubscription());
    return { kind: sub && Notification.permission === 'granted' ? 'on' : 'off' };
  } catch {
    return { kind: 'off' };
  }
}

function base64UrlToBytes(value) {
  const b64 = value.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(value.length / 4) * 4, '=');
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

function sameKey(sub, key) {
  const current = sub.options?.applicationServerKey;
  if (!current) return true;
  const a = new Uint8Array(current);
  return a.length === key.length && a.every((v, i) => v === key[i]);
}

// Must run straight from a tap: iOS only grants permission inside a user gesture,
// so requestPermission() is called before anything is awaited.
async function enablePush(event) {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    const permission = await Notification.requestPermission();
    if (permission !== 'granted') {
      toast(permission === 'denied'
        ? 'Notifications are turned off for ScamShield in iPhone Settings.'
        : 'Notifications were not enabled.');
      return;
    }
    const reg = await navigator.serviceWorker.ready;
    const { publicKey } = await api('api/push/key');
    if (!publicKey) throw new ApiError('The Mac did not provide a push key.', 500);
    const key = base64UrlToBytes(publicKey);
    let sub = await reg.pushManager.getSubscription();
    if (sub && !sameKey(sub, key)) {
      await sub.unsubscribe();
      sub = null;
    }
    sub = sub || (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key }));
    await api('api/push/subscribe', { method: 'POST', body: sub.toJSON() });
    toast('Notifications are on');
  } catch (err) {
    toast(err instanceof ApiError ? err.message : `Couldn't turn on notifications: ${err?.message || err}`);
  } finally {
    button.disabled = false;
    state.push = await pushState();
    if (state.route?.name === 'settings') render();
  }
}

async function sendTestPush(event) {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    const { sent } = await api('api/push/test', { method: 'POST' });
    toast(sent ? `Test sent to ${plural(sent, 'device')}` : 'No devices are subscribed yet.');
  } catch (err) {
    toast(errorMessage(err));
  } finally {
    button.disabled = false;
  }
}

// Re-send an existing subscription so the Mac keeps it even if its store was reset.
async function resyncPush() {
  if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) return;
  if (Notification.permission !== 'granted') return;
  try {
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    if (sub) await api('api/push/subscribe', { method: 'POST', body: sub.toJSON() });
  } catch { /* Mac unreachable; try again next launch */ }
}

// ---------------------------------------------------------------- chrome: nav bar, banner, badges, toast

function setNav({ title = '', left = null, right = null } = {}) {
  $('#nav-title').textContent = title;
  $('#nav-left').replaceChildren(...[left].flat().filter(Boolean));
  $('#nav-right').replaceChildren(...[right].flat().filter(Boolean));
}

function navButton(label, onclick, opts = {}) {
  return h('button', { type: 'button', class: 'nav-btn' + (opts.back ? ' nav-btn--back' : ''), onclick, disabled: opts.disabled, 'aria-label': opts.ariaLabel },
    opts.iconName ? icon(opts.iconName) : null, opts.iconOnly ? null : label);
}

function updateChrome() {
  const dataAt = state.fetchedAt || state.cachedAt;
  if (state.offline || state.error) {
    const text = state.error
      ? `The Mac agent had a problem: ${state.error}`
      : dataAt ? `Offline — showing data from ${snapshotTime(dataAt)}` : "Can't reach your Mac. It may be asleep.";
    bannerEl.replaceChildren(h('div', { class: 'banner', role: 'status' }, icon('offline'), h('span', {}, text),
      h('button', { type: 'button', class: 'btn-plain', onclick: () => refreshAll() }, 'Retry')));
  } else {
    bannerEl.replaceChildren();
  }
  const bucket = state.route?.name;
  const open = state.counts?.[bucket]?.open;
  const parts = [];
  if (BUCKETS.includes(bucket) && open != null) parts.push(`${open} open`);
  if (state.fetchedAt && !state.offline) parts.push(`Updated ${ago(state.fetchedAt).toLowerCase()}`);
  else if (state.inflight && !dataAt) parts.push('Checking for calls…');
  subtitleEl.textContent = parts.join(' · ');
}

function updateBadges() {
  for (const tab of document.querySelectorAll('.tab[data-tab]')) {
    const name = tab.dataset.tab;
    const badge = tab.querySelector('.badge');
    const open = state.counts?.[name]?.open || 0;
    if (badge) {
      badge.hidden = !open;
      badge.textContent = open > 99 ? '99+' : String(open);
    }
    tab.setAttribute('aria-label', open ? `${TITLES[name]}, ${open} open` : TITLES[name]);
  }
  const attention = state.counts?.attention?.open || 0;
  try {
    if (attention && navigator.setAppBadge) navigator.setAppBadge(attention).catch(() => {});
    else if (navigator.clearAppBadge) navigator.clearAppBadge().catch(() => {});
  } catch { /* badging unsupported */ }
}

function setActiveTab(name) {
  for (const tab of document.querySelectorAll('.tab[data-tab]')) {
    if (tab.dataset.tab === name) tab.setAttribute('aria-current', 'page');
    else tab.removeAttribute('aria-current');
  }
}

let toastTimer = 0;
function toast(message, { action, onAction } = {}) {
  const el = $('#toast');
  el.replaceChildren(h('span', {}, message),
    action ? h('button', { type: 'button', class: 'btn-plain', onclick: () => { hideToast(); onAction(); } }, action) : null);
  el.classList.add('is-visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(hideToast, action ? 5000 : 3200);
}

function hideToast() {
  $('#toast').classList.remove('is-visible');
}

// Show the compact nav title once the large title has scrolled under the bar.
function updateNavScrolled() {
  const title = main.querySelector('.large-title, .hero h1');
  const limit = title ? title.offsetTop + title.offsetHeight - navbar.offsetHeight : 0;
  navbar.classList.toggle('is-scrolled', scrollY > Math.max(0, limit));
}

// ---------------------------------------------------------------- sheets

function openSheet({ title, body, confirmLabel, onConfirm, canConfirm = () => true, actionSheet: isAction }) {
  closeSheet(true);
  const previousFocus = document.activeElement;
  const backdrop = h('div', { class: 'sheet-backdrop', onclick: () => closeSheet() });
  const titleId = 'sheet-title-' + Date.now();
  const sheet = h('div', { class: 'sheet' + (isAction ? ' action-sheet' : ''), role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': titleId });
  let confirmBtn = null;
  if (!isAction) {
    confirmBtn = navButton(confirmLabel, async () => {
      confirmBtn.disabled = true;
      if (await onConfirm()) closeSheet();
      else confirmBtn.disabled = !canConfirm();
    }, { disabled: !canConfirm() });
    sheet.append(h('div', { class: 'sheet-grabber', 'aria-hidden': 'true' }),
      h('div', { class: 'sheet-head' }, navButton('Cancel', () => closeSheet()), h('h2', { id: titleId }, title), confirmBtn));
  } else {
    body.querySelector('.action-head strong')?.setAttribute('id', titleId);
  }
  sheet.append(body);
  const onKey = (e) => { if (e.key === 'Escape') closeSheet(); };
  document.addEventListener('keydown', onKey);
  main.inert = true;
  document.querySelector('.tabbar').inert = true;
  navbar.inert = true;
  $('#sheet-root').replaceChildren(backdrop, sheet);
  state.sheet = { backdrop, sheet, onKey, previousFocus };
  (sheet.querySelector('button:not([disabled]), input') || sheet).focus({ preventScroll: true });
  return { refreshConfirm: () => { if (confirmBtn) confirmBtn.disabled = !canConfirm(); } };
}

function closeSheet(immediate) {
  const current = state.sheet;
  if (!current) return;
  state.sheet = null;
  document.removeEventListener('keydown', current.onKey);
  main.inert = false;
  document.querySelector('.tabbar').inert = false;
  navbar.inert = false;
  const remove = () => { current.backdrop.remove(); current.sheet.remove(); };
  if (immediate) remove();
  else {
    current.sheet.classList.add('is-closing');
    current.backdrop.classList.add('is-closing');
    setTimeout(remove, 220);
  }
  if (current.previousFocus?.isConnected) current.previousFocus.focus({ preventScroll: true });
}

function actionSheet({ title, message, actions }) {
  const body = h('div', {},
    h('div', { class: 'action-group' },
      h('div', { class: 'action-head' }, h('strong', {}, title), message || null),
      actions.map((a) => h('button', {
        type: 'button', class: 'action-btn' + (a.destructive ? ' action-btn--destructive' : ''),
        onclick: () => { closeSheet(); a.onSelect(); },
      }, a.label))),
    h('div', { class: 'action-group' },
      h('button', { type: 'button', class: 'action-btn action-btn--cancel', onclick: () => closeSheet() }, 'Cancel')));
  openSheet({ title, body, actionSheet: true });
}

function openMoveSheet(item) {
  let bucket = item.bucket;
  let category = item.category;
  let always = false;
  const body = h('div');
  const changed = () => always || bucket !== item.bucket || category !== item.category;
  let sheetApi = null;

  const draw = () => {
    const segmented = h('div', { class: 'segmented segmented--sheet', role: 'radiogroup', 'aria-label': 'Section' },
      BUCKETS.map((b) => h('button', {
        type: 'button', role: 'radio', 'aria-checked': String(b === bucket),
        onclick: () => {
          bucket = b;
          if (!CATEGORIES[b].includes(category)) category = b === item.bucket ? item.category : DEFAULT_CATEGORY[b];
          draw();
        },
      }, TITLES[b])));
    const categories = h('ul', { class: 'list', role: 'radiogroup', 'aria-label': 'Category' },
      CATEGORIES[bucket].map((c) => h('li', {}, h('button', {
        type: 'button', class: 'cell', role: 'radio', 'aria-checked': String(c === category),
        onclick: () => { category = c; draw(); },
      }, h('span', { class: 'cell-label' }, categoryLabel(c)), c === category ? icon('check', 'check') : null))));
    const who = item.displayNumber || item.number;
    const alwaysRow = item.number ? section(null,
      h('ul', { class: 'list' }, h('li', {}, h('label', { class: 'cell' },
        h('span', { class: 'cell-label' }, isPhoneNumber(item.number) ? 'Always for this number' : 'Always for this caller'),
        h('input', { type: 'checkbox', role: 'switch', class: 'switch', checked: always, onchange: (e) => { always = e.target.checked; sheetApi?.refreshConfirm(); } })))),
      `Future calls from ${who} will be filed here too, and ScamShield learns from it.`) : null;
    body.replaceChildren(segmented, section(null, categories), alwaysRow);
    sheetApi?.refreshConfirm();
  };
  draw();
  sheetApi = openSheet({
    title: 'Move to…',
    body,
    confirmLabel: 'Save',
    canConfirm: changed,
    onConfirm: () => label(item, bucket, category, always),
  });
}

// ---------------------------------------------------------------- swipe to mark done

function closeOpenSwipes(except) {
  for (const row of document.querySelectorAll('.row[data-open]')) {
    if (row === except) continue;
    delete row.dataset.open;
    row.querySelector('.row-link').style.transform = '';
  }
}

function attachSwipe(row, link, actions, onCommit) {
  const reveal = 88;
  let x0 = 0, y0 = 0, dx = 0, mode = null;
  const setX = (x) => {
    link.style.transform = x ? `translateX(${x}px)` : '';
    actions.style.width = `${Math.max(reveal, -x)}px`;
  };
  row.addEventListener('touchstart', (e) => {
    const t = e.touches[0];
    x0 = t.clientX; y0 = t.clientY; dx = 0; mode = null;
    closeOpenSwipes(row);
  }, { passive: true });
  row.addEventListener('touchmove', (e) => {
    const t = e.touches[0];
    const mx = t.clientX - x0, my = t.clientY - y0;
    if (!mode) {
      if (Math.abs(mx) < 10 && Math.abs(my) < 10) return;
      mode = Math.abs(mx) > Math.abs(my) ? 'h' : 'v';
      if (mode === 'h') row.classList.add('is-swiping');
    }
    if (mode !== 'h') return;
    e.preventDefault();
    dx = Math.min(0, mx - (row.dataset.open ? reveal : 0));
    setX(dx);
  }, { passive: false });
  const end = () => {
    if (mode !== 'h') return;
    row.classList.remove('is-swiping');
    row.dataset.swiped = '1';
    setTimeout(() => delete row.dataset.swiped, 400);
    if (-dx > row.offsetWidth * 0.55) {
      setX(-row.offsetWidth);
      onCommit();
    } else if (-dx > reveal / 2) {
      row.dataset.open = '1';
      setX(-reveal);
    } else {
      delete row.dataset.open;
      setX(0);
    }
    mode = null;
  };
  row.addEventListener('touchend', end);
  row.addEventListener('touchcancel', end);
  link.addEventListener('click', (e) => {
    if (row.dataset.swiped || row.dataset.open) {
      e.preventDefault();
      if (!row.dataset.swiped) closeOpenSwipes();
      return;
    }
    state.pushedDetail = true;
  });
}

// ---------------------------------------------------------------- list views

function callRow(item) {
  const name = callerName(item);
  const vm = item.voicemail;
  const link = h('a', { class: 'row-link', href: `#/item/${encodeURIComponent(item.id)}` },
    avatar(item),
    h('div', { class: 'row-main' },
      h('div', { class: 'row-top' },
        h('span', { class: 'row-title' }, name, item.callCount > 1 ? h('span', { class: 'times' }, ` (${item.callCount})`) : null),
        h('time', { class: 'row-time', datetime: item.date }, relTime(item.date))),
      item.summary ? h('div', { class: 'row-summary' }, item.summary) : null,
      h('div', { class: 'row-meta' },
        chip(item),
        item.done ? h('span', { class: 'chip chip--done' }, 'Done') : null,
        vm ? h('span', { class: 'meta' }, icon('voicemail'),
          hasDuration(vm) ? [h('span', { class: 'sr-only' }, 'Voicemail, '), duration(vm.durationSec)] : 'Voicemail') : null,
        showsCallBack(item) && item.callback?.recommended
          ? h('span', { class: 'meta meta--callback' }, icon('phone'), 'Call back') : null)),
    icon('chevron', 'row-chevron'));
  const actionBtn = h('button', {
    type: 'button', class: 'row-action' + (item.done ? ' row-action--reopen' : ''), tabindex: '-1', 'aria-hidden': 'true',
    onclick: () => setDone(item, !item.done),
  }, icon(item.done ? 'reopen' : 'checkCircle'), item.done ? 'Reopen' : 'Done');
  const actions = h('div', { class: 'row-actions' }, actionBtn);
  const row = h('li', { class: 'row' + (item.done ? ' is-done' : '') }, actions, link);
  attachSwipe(row, link, actions, () => setDone(item, !item.done));
  return row;
}

function callList(items) {
  return h('ul', { class: 'list list--calls' }, items.map(callRow));
}

function groupByDay(items) {
  const groups = [['Today', []], ['Yesterday', []], ['Earlier', []]];
  for (const item of items) {
    const d = parseDate(item.date);
    const days = d ? dayDiff(d) : 99;
    groups[days <= 0 ? 0 : days === 1 ? 1 : 2][1].push(item);
  }
  return groups.filter(([, list]) => list.length);
}

function bucketHeader(bucket) {
  return [h('h1', { class: 'large-title', tabindex: '-1' }, TITLES[bucket]), subtitleEl, bannerEl];
}

function unreachableState() {
  if (!state.offline && !state.error) return spinner();
  return emptyState('offline', "Can't reach your Mac",
    'ScamShield runs on your Mac. It may be asleep or off your tailnet. Wake it, then try again.',
    h('button', { type: 'button', class: 'btn btn--tinted', onclick: () => refreshAll() }, 'Try Again'));
}

function renderBucket(bucket) {
  const view = h('div', {}, bucketHeader(bucket));
  setNav({
    title: TITLES[bucket],
    right: bucket === 'scam'
      ? navButton('Archive All', confirmArchiveAll, { disabled: !(state.buckets.scam || []).some((i) => !i.done) })
      : null,
  });
  const all = state.buckets[bucket];
  if (!all) {
    view.append(unreachableState());
    return view;
  }
  if (bucket === 'attention') renderAttention(view, all.filter((i) => !i.done));
  else if (bucket === 'review') renderReview(view, all.filter((i) => !i.done));
  else renderScams(view, all);
  return view;
}

function renderAttention(view, items) {
  if (!items.length) {
    view.append(emptyState('shieldCheck', "You're all caught up", 'Calls that need you, like appointments, deliveries and people you know, will show up here.'));
    return;
  }
  for (const [day, list] of groupByDay(items)) view.append(section(day, callList(list)));
}

function renderReview(view, items) {
  const withMessage = items.filter((i) => i.category !== 'no_message')
    .sort((a, b) => Boolean(b.voicemail) - Boolean(a.voicemail) || (a.date < b.date ? 1 : -1));
  const noMessage = items.filter((i) => i.category === 'no_message');
  if (!items.length) {
    view.append(emptyState('shieldCheck', 'Nothing to review', "Calls ScamShield isn't sure about will wait here for a quick look."));
    return;
  }
  if (withMessage.length) view.append(section('Left a message', callList(withMessage)));
  if (noMessage.length) {
    const open = state.noMessageOpen;
    const toggle = h('button', {
      type: 'button', class: 'disclosure', 'aria-expanded': String(open), 'aria-controls': 'no-message-list',
      onclick: () => { state.noMessageOpen = !state.noMessageOpen; render(); },
    }, h('span', {}, 'No message left'), h('span', { class: 'count' }, String(noMessage.length)), icon('chevron'));
    const body = h('div', { class: 'list' }, toggle);
    const list = callList(noMessage);
    list.id = 'no-message-list';
    view.append(section(null, body), open ? section(null, list) : null);
  }
}

function renderScams(view, all) {
  const showDone = state.showDoneScams;
  const items = showDone ? all : all.filter((i) => !i.done);
  const setShowDone = (value) => {
    if (state.showDoneScams === value) return;
    state.showDoneScams = value;
    render();
    refresh();
  };
  view.append(h('div', { class: 'segmented', role: 'group', 'aria-label': 'Filter' },
    h('button', { type: 'button', 'aria-pressed': String(!showDone), onclick: () => setShowDone(false) }, 'Open'),
    h('button', { type: 'button', 'aria-pressed': String(showDone), onclick: () => setShowDone(true) }, 'Show Done')));
  if (!items.length) {
    view.append(emptyState('shieldX', 'No scam calls', 'Fraud, robocalls and sales calls are filed here so they never interrupt you.'));
    return;
  }
  const order = [...CATEGORIES.scam, ...new Set(items.map((i) => i.category).filter((c) => !CATEGORIES.scam.includes(c)))];
  for (const category of order) {
    const list = items.filter((i) => i.category === category);
    if (!list.length) continue;
    view.append(section(h('span', {}, categoryLabel(category), ' ', h('span', { class: 'count' }, `· ${list.length}`)), callList(list)));
  }
}

// ---------------------------------------------------------------- detail view

let blockCellSlot = null;
let blockCellItem = null;

function goBack(bucket) {
  if (state.pushedDetail && history.length > 1) {
    state.pushedDetail = false;
    history.back();
  } else {
    location.replace(`#/${bucket || 'attention'}`);
  }
}

function fetchDetail(id) {
  if (state.detailCache[id] === undefined) {
    state.detailCache[id] = null;
    delete state.detailError[id];
    api(itemPath(id)).then((item) => {
      state.detailCache[id] = item;
    }).catch((err) => {
      delete state.detailCache[id];
      state.detailError[id] = err;
    }).finally(() => {
      if (state.route?.name === 'item' && state.route.id === id) render();
    });
  }
}

function renderDetail(id) {
  const item = findItem(id);
  const fromBucket = item?.bucket || state.lastBucket || 'attention';
  setNav({
    title: item ? callerName(item) : '',
    left: navButton(TITLES[fromBucket], () => goBack(fromBucket), { back: true, iconName: 'back' }),
  });
  setActiveTab(fromBucket);
  if (!item) {
    const err = state.detailError[id];
    if (!err) {
      fetchDetail(id);
      return h('div', {}, bannerEl, spinner());
    }
    delete state.detailError[id];
    return h('div', {}, bannerEl, err.status === 404
      ? emptyState('info', 'Call not found', 'This call may have been removed from your history.')
      : emptyState('offline', "Couldn't load this call", errorMessage(err),
        h('button', { type: 'button', class: 'btn btn--tinted', onclick: () => render() }, 'Try Again')));
  }
  return detailView(item);
}

function detailView(item) {
  const name = callerName(item);
  const vm = item.voicemail;
  const tint = `--tint: var(--tint-${item.bucket})`;
  const view = h('div', {});

  view.append(h('div', { class: 'hero' },
    avatar(item, true),
    h('h1', { tabindex: '-1' }, name),
    h('div', { class: 'hero-sub' }, callerDetail(item)),
    h('div', { class: 'hero-sub' }, longDate(item.date), item.callCount > 1 ? ` · ${item.callCount} calls in 24h` : ''),
    h('div', { class: 'hero-chips' },
      h('span', { class: `chip chip--${item.bucket}` }, `${TITLES[item.bucket]} · ${categoryLabel(item.category)}`),
      item.done ? h('span', { class: 'chip chip--done' }, 'Done') : null,
      item.userLabeled ? h('span', { class: 'chip' }, 'Labeled by you') : null)));
  view.append(bannerEl);

  if (showsCallBack(item)) {
    const prob = item.callback?.probability;
    const link = callBackLink(item);
    view.append(h('div', { class: 'hero-actions' },
      h('a', { class: 'btn btn--block btn--call', href: link.href }, icon('phone'), link.label),
      item.callback?.recommended && prob != null ? h('p', { class: 'hint' }, `Worth a call back · ${pct(prob)} likely`) : null));
  }

  if (item.summary) view.append(section('What they wanted', h('div', { class: 'card' }, h('p', { class: 'summary' }, item.summary))));

  if (vm) view.append(section('Voicemail', voicemailCard(vm)));
  else view.append(section('Voicemail', h('div', { class: 'card' }, h('p', { class: 'audio-missing' }, 'No voicemail was left.'))));

  const reasons = item.reasons || [];
  view.append(section('Why it’s here', h('div', { class: 'card', style: tint },
    reasons.length ? h('ul', { class: 'reasons' }, reasons.map((r) => h('li', {}, icon(item.bucket === 'scam' ? 'warning' : 'checkCircle'), h('span', {}, r)))) : null,
    h('div', { class: 'cell-sub' }, `Confidence ${pct(item.confidence)}`),
    h('div', { class: 'meter', role: 'img', 'aria-label': `Confidence ${pct(item.confidence)}` },
      h('span', { style: `width: ${Math.round((Number(item.confidence) || 0) * 100)}%` })))));

  if (isPhoneNumber(item.number)) view.append(section('Number reputation', reputationList(item.reputation)));

  blockCellSlot = h('li', {});
  blockCellItem = item;
  view.append(section(null, h('ul', { class: 'list' },
    actionCell(item.done ? 'Mark as Not Done' : 'Mark as Done', () => {
      if (item.done) setDone(item, false).then(() => render());
      else { goBack(item.bucket); setDone(item, true); }
    }, { iconName: item.done ? 'reopen' : 'checkCircle' }),
    actionCell('Move to…', () => openMoveSheet(item), { iconName: 'folder' }),
    isPhoneNumber(item.number) ? blockCellSlot : null)));
  updateBlockCell();
  if (isPhoneNumber(item.number) && state.blocklist == null) loadBlocklist().then(updateBlockCell);
  return view;
}

function voicemailCard(vm) {
  const card = h('div', { class: 'card' });
  if (vm.hasAudio && vm.id) {
    const audio = h('audio', { controls: true, preload: 'none', src: `api/audio/${encodeURIComponent(vm.id)}` });
    audio.addEventListener('error', () => {
      audio.replaceWith(h('p', { class: 'audio-missing' }, 'The recording isn’t available right now.'));
    });
    card.append(audio);
  }
  const text = (vm.transcript || '').trim();
  const transcript = h('p', { class: 'transcript', id: 'transcript' }, text || 'No transcript available.');
  const conf = vm.transcriptConfidence;
  const foot = h('div', { class: 'transcript-foot' },
    h('span', {}, [hasDuration(vm) ? duration(vm.durationSec) : null,
      conf != null ? (conf < 0.6 ? 'low-confidence transcript' : `transcript ${pct(conf)} confident`) : null].filter(Boolean).join(' · ')));
  if (text.length > 180) {
    const more = h('button', { type: 'button', class: 'btn-plain', 'aria-expanded': 'false', 'aria-controls': 'transcript' }, 'Show More');
    more.addEventListener('click', () => {
      const expanded = transcript.classList.toggle('is-expanded');
      more.setAttribute('aria-expanded', String(expanded));
      more.textContent = expanded ? 'Show Less' : 'Show More';
    });
    foot.append(more);
  }
  card.append(transcript, foot);
  return card;
}

function reputationList(rep) {
  if (!rep || (!rep.complaints && !rep.score && !rep.robocallShare)) {
    return h('ul', { class: 'list' }, cell('No spam reports for this number', null));
  }
  return h('ul', { class: 'list' },
    cell('Spam score', pct(rep.score)),
    cell('Complaints', fmtNumber.format(rep.complaints || 0)),
    cell('Last reported', rep.lastReported ? relTime(rep.lastReported) : 'Never'),
    cell('Robocall share', pct(rep.robocallShare)));
}

function updateBlockCell() {
  if (!blockCellSlot || !isPhoneNumber(blockCellItem?.number)) return;
  const item = blockCellItem;
  const blocked = (state.blocklist || []).some((b) => b.number === item.number);
  const fresh = actionCell(blocked ? 'Unblock Number' : 'Block Number', () => confirmBlock(item, !blocked),
    { iconName: 'block', destructive: !blocked });
  blockCellSlot.replaceChildren(...fresh.childNodes);
}

// ---------------------------------------------------------------- settings view

function renderSettings() {
  setNav({ title: 'Settings' });
  return h('div', {},
    h('h1', { class: 'large-title', tabindex: '-1' }, 'Settings'),
    h('p', { class: 'subtitle' }),
    bannerEl,
    notificationsSection(),
    agentSection(),
    permissionsSection(),
    blocklistSection(),
    h('p', { class: 'section-footer', style: 'text-align:center' },
      `ScamShield · ${state.fetchedAt ? `calls updated ${ago(state.fetchedAt).toLowerCase()}` : 'waiting for your Mac'}`));
}

function notificationsSection() {
  const kind = state.push?.kind;
  if (kind === 'needs-install') {
    return section('Notifications', h('div', { class: 'card' },
      h('p', { style: 'margin:0 0 10px;font-size:15px' }, 'To get alerts on this iPhone, ScamShield has to be opened from your Home Screen:'),
      h('ol', { class: 'instructions' },
        h('li', {}, 'Tap ', icon('share'), ' Share in Safari'),
        h('li', {}, 'Choose ', icon('addSquare'), ' Add to Home Screen'),
        h('li', {}, 'Open ScamShield from your Home Screen and come back here'))),
    'Requires iOS 16.4 or later.');
  }
  const labels = { on: 'On', off: 'Off', denied: 'Turned off', unsupported: 'Not supported' };
  const rows = [cell('Notifications', labels[kind] || '…', { dot: kind === 'on' ? 'ok' : kind === 'denied' ? 'down' : null })];
  if (kind === 'off' || kind === 'on') {
    rows.push(actionCell(kind === 'on' ? 'Re-register This Device' : 'Enable Notifications', enablePush, { iconName: 'bell' }));
  }
  if (kind === 'on') rows.push(actionCell('Send Test Notification', sendTestPush, { iconName: 'checkCircle' }));
  const devices = state.status?.pushSubscriptions;
  if (typeof devices === 'number') rows.push(cell('Devices registered on Mac', fmtNumber.format(devices)));
  const footer = {
    on: 'You’ll be alerted when a call needs your attention.',
    off: 'Get an alert when a missed call needs your attention.',
    denied: 'Turn notifications back on in iPhone Settings › Notifications › ScamShield.',
    unsupported: 'This browser can’t receive web notifications.',
  }[kind];
  return section('Notifications', h('ul', { class: 'list' }, rows), footer);
}

function agentSection() {
  const st = state.status;
  if (!st) {
    return section('Mac agent', h('ul', { class: 'list' }, state.statusError
      ? [cell("Can't reach your Mac", null, { dot: 'down', sub: state.statusError }), actionCell('Try Again', () => loadSettingsData())]
      : cell('Checking…', null)));
  }
  const model = (v) => (v === 'ok' ? 'Running' : v === 'down' ? 'Down' : v || 'Unknown');
  const dot = (v) => (v === 'ok' ? 'ok' : v === 'down' ? 'down' : null);
  const reachable = !state.statusError;
  const rep = st.reputation || {};
  const repSub = [
    rep.complaints != null ? `${fmtNumber.format(rep.complaints)} complaint reports` : null,
    rep.updatedAt ? `updated ${ago(rep.updatedAt).toLowerCase()}` : null,
  ].filter(Boolean).join(' · ');
  return section('Mac agent', h('ul', { class: 'list' },
    st.error ? cell('Agent reported a problem', null, { dot: 'down', sub: typeof st.error === 'string' ? st.error : JSON.stringify(st.error) }) : null,
    cell('Connection', reachable ? 'Online' : 'Offline', { dot: reachable ? 'ok' : 'down', sub: reachable ? null : state.statusError }),
    cell('Last check', ago(st.lastIngest)),
    cell('Last call seen', st.lastCallSeen ? relTime(st.lastCallSeen) : 'Never'),
    cell('Last voicemail seen', st.lastVoicemailSeen ? relTime(st.lastVoicemailSeen) : 'Never'),
    cell('Classifier model', model(st.models?.decider), { dot: dot(st.models?.decider) }),
    cell('Summary model', model(st.models?.writer), { dot: dot(st.models?.writer) }),
    cell('Reputation database', `${fmtNumber.format(rep.numbers || 0)} numbers`, { sub: repSub || null }),
    cell('Waiting to process', fmtNumber.format(st.pending || 0)),
    cell('Version', st.version || '–')));
}

function permissionsSection() {
  const perms = state.status?.permissions;
  if (!perms || typeof perms !== 'object') return null;
  const names = { contacts: 'Contacts', calendar: 'Calendar' };
  const labels = { granted: 'Allowed', authorized: 'Allowed', denied: 'Denied', restricted: 'Restricted', notDetermined: 'Not asked', not_determined: 'Not asked' };
  const keys = Object.keys(perms);
  if (!keys.length) return null;
  const missing = keys.some((k) => !['granted', 'authorized'].includes(perms[k]));
  return section('Mac permissions', h('ul', { class: 'list' }, keys.map((k) => {
    const v = perms[k];
    const ok = v === 'granted' || v === 'authorized';
    return cell(names[k] || k, labels[v] || String(v ?? 'Unknown'), { dot: ok ? 'ok' : v === 'denied' || v === 'restricted' ? 'down' : null });
  })), missing
    ? 'Allow access in System Settings › Privacy & Security on your Mac so ScamShield can recognise people you know and appointments you’ve booked.'
    : 'Used to recognise people you know and appointments you’ve booked.');
}

function blocklistSection() {
  const list = state.blocklist;
  if (!list) {
    return section('Blocked numbers', h('ul', { class: 'list' },
      cell(state.blocklistError ? "Couldn't load blocked numbers" : 'Loading…', null, { sub: state.blocklistError })));
  }
  if (!list.length) return section('Blocked numbers', h('ul', { class: 'list' }, cell('No blocked numbers', null)));
  return section('Blocked numbers', h('ul', { class: 'list' }, list.map((b) => cell(
    b.displayNumber || b.number,
    null,
    {
      sub: [b.reason, b.addedAt ? `added ${relTime(b.addedAt)}` : null].filter(Boolean).join(' · '),
      trailing: h('button', {
        type: 'button', class: 'btn-plain', 'aria-label': `Unblock ${b.displayNumber || b.number}`,
        onclick: () => confirmBlock({ number: b.number, displayNumber: b.displayNumber }, false),
      }, 'Unblock'),
    }))), 'Calls from blocked numbers are filed under Scams.');
}

// ---------------------------------------------------------------- routing

function parseRoute() {
  const hash = location.hash.replace(/^#\/?/, '');
  if (hash.startsWith('item/')) {
    let id = hash.slice(5);
    try { id = decodeURIComponent(id); } catch { /* use raw id */ }
    return { name: 'item', id };
  }
  const name = hash.split(/[/?]/)[0];
  if (name === 'scams') return { name: 'scam' };
  return { name: TITLES[name] ? name : 'attention' };
}

function render(animation) {
  const route = state.route;
  let view;
  if (route.name === 'item') view = renderDetail(route.id);
  else {
    setActiveTab(route.name);
    view = route.name === 'settings' ? renderSettings() : renderBucket(route.name);
  }
  updateChrome();
  main.replaceChildren(view);
  if (animation) {
    main.classList.remove('view-push', 'view-pop', 'view-fade');
    void main.offsetWidth;
    main.classList.add(`view-${animation}`);
  }
  updateNavScrolled();
}

function onRouteChange() {
  const prev = state.route;
  const route = parseRoute();
  if (prev && prev.name !== 'item') state.scroll[prev.name] = scrollY;
  if (prev && BUCKETS.includes(prev.name)) state.lastBucket = prev.name;
  if (route.name !== 'item') state.pushedDetail = false;
  state.route = route;
  closeSheet(true);
  closeOpenSwipes();
  const animation = route.name === 'item' && prev?.name !== 'item' ? 'push' : prev?.name === 'item' && route.name !== 'item' ? 'pop' : 'fade';
  render(animation);
  scrollTo(0, route.name === 'item' ? 0 : state.scroll[route.name] || 0);
  updateNavScrolled();
  if (prev) main.querySelector('h1')?.focus({ preventScroll: true });
  if (route.name === 'settings') loadSettingsData();
}

// ---------------------------------------------------------------- lifecycle

let pollTimer = 0;
function startPolling() {
  clearInterval(pollTimer);
  pollTimer = setInterval(() => {
    if (document.visibilityState === 'visible') refreshAll();
  }, POLL_MS);
}

function setupPullToRefresh() {
  const ptr = $('#ptr');
  const threshold = 80;
  let y0 = null, pull = 0;
  addEventListener('touchstart', (e) => {
    y0 = scrollY <= 0 && !state.sheet && e.touches.length === 1 ? e.touches[0].clientY : null;
    pull = 0;
  }, { passive: true });
  addEventListener('touchmove', (e) => {
    if (y0 == null) return;
    pull = Math.max(0, e.touches[0].clientY - y0);
    ptr.classList.add('is-pulling');
    ptr.style.setProperty('--pull', String(Math.min(1, pull / threshold)));
  }, { passive: true });
  addEventListener('touchend', async () => {
    if (y0 == null) return;
    y0 = null;
    ptr.classList.remove('is-pulling');
    if (pull < threshold) return;
    ptr.classList.add('is-loading');
    await refreshAll();
    ptr.classList.remove('is-loading');
  });
}

function setupTabBar() {
  // Tapping the current tab scrolls to top (or pops back from a detail view), like iOS.
  document.querySelector('.tabbar').addEventListener('click', (e) => {
    const tab = e.target.closest('.tab');
    if (tab && state.route?.name === tab.dataset.tab) {
      e.preventDefault();
      scrollTo({ top: 0, behavior: 'smooth' });
    }
  });
}

async function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) return;
  navigator.serviceWorker.addEventListener('message', (e) => {
    if (e.data?.type !== 'navigate' || !e.data.url) return;
    const target = new URL(e.data.url, location.href);
    if (target.hash && target.hash !== location.hash) {
      state.pushedDetail = false;
      location.hash = target.hash;
    }
  });
  try {
    await navigator.serviceWorker.register('sw.js');
    resyncPush();
  } catch (err) {
    console.warn('Service worker registration failed', err);
  }
}

function init() {
  loadCache();
  updateBadges();
  if (!location.hash) history.replaceState(null, '', '#/attention');
  addEventListener('hashchange', onRouteChange);
  addEventListener('scroll', () => requestAnimationFrame(updateNavScrolled), { passive: true });
  addEventListener('online', () => refreshAll());
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') return;
    if (Date.now() - state.lastAttempt > 5000) refreshAll();
    startPolling();
  });
  setupTabBar();
  setupPullToRefresh();
  refresh();
  onRouteChange();
  startPolling();
  registerServiceWorker();
}

init();
