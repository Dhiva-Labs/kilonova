// The wallet UI. One column, rebuilt from plain DOM on every state change;
// the Rust core (kn_wasm) holds the keys and does all the Monero work.

import init, { Wallet, bundledNodes, checkSeed, heightAt, newSeed, normalizeNode } from '../build/wasm/kn_wasm.js';
import { formatHeight, nodeHost, xmrParts } from './format';
import { hasNodeAccess, promptClosesPopup, requestNodeAccess } from './permissions';
import { stripOriginHeader } from './privacy';
import * as store from './storage';

interface Status {
  scanned: number;
  tip: number;
  total: string;
  unlocked: string;
  incoming: string;
  cache?: Uint8Array;
}

type Screen =
  | { name: 'loading' }
  | { name: 'welcome' }
  | { name: 'new-seed'; words: string }
  | { name: 'restore' }
  | { name: 'password'; words: string; createdNow: boolean; restoreHeight?: number }
  | { name: 'unlock' }
  | { name: 'wallet' }
  | { name: 'nodes' };

type SyncView =
  | { kind: 'idle' }
  | { kind: 'needs-access'; node: string }
  | { kind: 'connecting'; node: string }
  | { kind: 'scanning' }
  | { kind: 'synced' }
  | { kind: 'failed'; message: string };

/** Follow the tip this often while the wallet is open. */
const RESYNC_MS = 60_000;
const MIN_PASSWORD = 8;

const app = document.getElementById('app') as HTMLDivElement;
const inTab = new URLSearchParams(location.search).has('tab');
if (inTab) document.body.classList.add('tab');

let screen: Screen = { name: 'loading' };
/** Network picked on the welcome screen, before a wallet exists. */
let network = 'mainnet';
let wallet: Wallet | null = null;
let meta: store.Meta | null = null;
let blob: Uint8Array | null = null;
let settings: store.Settings = { nodes: {} };
let address = '';
let status: Status | null = null;
let syncView: SyncView = { kind: 'idle' };
let syncing = false;
let resyncTimer: number | undefined;
let unlockError = '';
let busy = false;

// --- DOM helpers ----------------------------------------------------------

type Child = Node | string | null | undefined | false;

function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Record<string, unknown> = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === false) continue;
    if (key === 'class') el.className = String(value);
    else if (key.startsWith('on') && typeof value === 'function') {
      el.addEventListener(key.slice(2), value as EventListener);
    } else if (key in el && key !== 'list') (el as unknown as Record<string, unknown>)[key] = value;
    else el.setAttribute(key, value === true ? '' : String(value));
  }
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child);
  }
  return el;
}

const SVG = 'http://www.w3.org/2000/svg';

function icon(paths: string[], label?: string): SVGSVGElement {
  const svg = document.createElementNS(SVG, 'svg');
  svg.setAttribute('viewBox', '0 0 20 20');
  svg.setAttribute('class', 'icon');
  svg.setAttribute('aria-hidden', label ? 'false' : 'true');
  if (label) svg.setAttribute('aria-label', label);
  for (const d of paths) {
    const p = document.createElementNS(SVG, 'path');
    p.setAttribute('d', d);
    svg.append(p);
  }
  return svg;
}

const ICONS = {
  lock: ['M5.5 9h9v7.5h-9z', 'M7.5 9V6.5a2.5 2.5 0 0 1 5 0V9'],
  back: ['M12 4.5 6.5 10l5.5 5.5'],
  copy: ['M7 7h8.5v8.5H7z', 'M4.5 12.5V4.5h8'],
  // The orbit ring as an icon: node and sync settings.
  node: ['M10 3.5a6.5 6.5 0 1 1-6.5 6.5', 'M10 8.25a1.75 1.75 0 1 1 0 3.5a1.75 1.75 0 1 1 0-3.5z'],
};

/** The sync orbit: progress is the arc length, a dot rides its end. */
function orbit(fraction: number, spinning: boolean): SVGSVGElement {
  const size = 20;
  const r = 8;
  const c = size / 2;
  const svg = document.createElementNS(SVG, 'svg');
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('viewBox', `0 0 ${size} ${size}`);
  svg.setAttribute('aria-hidden', 'true');
  const track = document.createElementNS(SVG, 'circle');
  track.setAttribute('cx', String(c));
  track.setAttribute('cy', String(c));
  track.setAttribute('r', String(r));
  track.setAttribute('fill', 'none');
  track.setAttribute('stroke', 'var(--border)');
  track.setAttribute('stroke-width', '1.5');
  svg.append(track);
  const f = Math.max(0, Math.min(1, fraction));
  const group = document.createElementNS(SVG, 'g');
  if (spinning) group.setAttribute('class', 'orbit-spin');
  const angle = f * 2 * Math.PI - Math.PI / 2;
  const x = c + r * Math.cos(angle);
  const y = c + r * Math.sin(angle);
  if (f > 0) {
    const arc = document.createElementNS(SVG, 'path');
    const large = f > 0.5 ? 1 : 0;
    const d = f >= 1 ? `M ${c} ${c - r} a ${r} ${r} 0 1 1 -0.01 0` : `M ${c} ${c - r} A ${r} ${r} 0 ${large} 1 ${x} ${y}`;
    arc.setAttribute('d', d);
    arc.setAttribute('fill', 'none');
    arc.setAttribute('stroke', 'var(--accent)');
    arc.setAttribute('stroke-width', '1.5');
    group.append(arc);
  }
  const dot = document.createElementNS(SVG, 'circle');
  dot.setAttribute('cx', String(x));
  dot.setAttribute('cy', String(y));
  dot.setAttribute('r', '2.25');
  dot.setAttribute('fill', 'var(--accent)');
  group.append(dot);
  svg.append(group);
  return svg;
}

function button(label: string, variant: 'primary' | 'secondary' | 'text', onclick: () => void, extra: Record<string, unknown> = {}) {
  return h('button', { class: `btn ${variant}`, type: 'button', onclick, ...extra }, label);
}

function iconButton(paths: string[], label: string, onclick: () => void) {
  return h('button', { class: 'icon-btn', type: 'button', title: label, 'aria-label': label, onclick }, icon(paths));
}

function field(label: string, input: HTMLInputElement | HTMLTextAreaElement, help?: string, error?: boolean) {
  const id = `f-${label.toLowerCase().replace(/\W+/g, '-')}`;
  input.id = id;
  return h(
    'div',
    { class: 'field' },
    h('label', { htmlFor: id }, label),
    input,
    help ? h('div', { class: error ? 'help error' : 'help' }, help) : null,
  );
}

function segments(options: [string, string][], selected: string, onpick: (value: string) => void) {
  return h(
    'div',
    { class: 'segments', role: 'group', 'aria-label': 'Network' },
    ...options.map(([value, label]) =>
      h('button', { type: 'button', 'aria-pressed': String(value === selected), onclick: () => onpick(value) }, label),
    ),
  );
}

function strip(net: string) {
  if (net === 'mainnet') return null;
  const name = net === 'stagenet' ? 'Stagenet' : 'Testnet';
  return h('div', { class: 'strip', role: 'note' }, `${name}. These coins have no value.`);
}

function header(...actions: Child[]) {
  return h('header', {}, h('span', { class: 'wordmark' }, 'Kilonova'), h('div', {}, ...actions));
}

function toast(text: string) {
  const el = h('div', { class: 'toast', role: 'status' }, text);
  document.body.append(el);
  setTimeout(() => el.remove(), 1800);
}

/** Errors from the core read as sentences: capital first, full stop. */
function errorText(e: unknown): string {
  const text = (e instanceof Error ? e.message : String(e)).trim();
  if (!text) return 'Something went wrong.';
  const sentence = text[0]!.toUpperCase() + text.slice(1);
  return /[.!?]$/.test(sentence) ? sentence : `${sentence}.`;
}

function amount(atomic: string) {
  const { whole, head, tail } = xmrParts(BigInt(atomic));
  return h(
    'div',
    { class: 'balance', 'aria-label': `${whole}.${head}${tail} XMR` },
    `${whole}.${head}`,
    h('span', { class: 'end' }, tail ? h('span', { class: 'tail' }, tail) : null, h('span', { class: 'unit' }, 'XMR')),
  );
}

// --- Screens --------------------------------------------------------------

function welcome() {
  return [
    header(),
    strip(network),
    h(
      'main',
      {},
      h('h1', {}, 'A Monero wallet in your browser'),
      h(
        'p',
        { class: 'secondary' },
        'Your keys stay in this browser, sealed with your password. Kilonova scans the chain itself against a node you choose, so the node never learns which payments are yours.',
      ),
      h('div', {}, h('div', { class: 'eyebrow' }, 'Network'), segments(
        [
          ['mainnet', 'Mainnet'],
          ['stagenet', 'Stagenet'],
          ['testnet', 'Testnet'],
        ],
        network,
        (value) => {
          network = value;
          render();
        },
      )),
      h(
        'div',
        { class: 'stack end' },
        button('Create a wallet', 'primary', () => {
          screen = { name: 'new-seed', words: newSeed(true, Date.now() / 1000) };
          render();
        }),
        button('Restore from a seed', 'secondary', () => {
          screen = { name: 'restore' };
          render();
        }),
      ),
    ),
  ];
}

function newSeedScreen(words: string) {
  const confirm = h('input', { type: 'checkbox', id: 'wrote' });
  const next = button('Continue', 'primary', () => {
    screen = { name: 'password', words, createdNow: true };
    render();
  }, { disabled: true });
  confirm.addEventListener('change', () => {
    next.disabled = !confirm.checked;
  });
  return [
    header(iconButton(ICONS.back, 'Back', () => {
      screen = { name: 'welcome' };
      render();
    })),
    strip(network),
    h(
      'main',
      {},
      h('h1', {}, 'Your seed'),
      h('p', { class: 'secondary' }, 'Write these 16 words down, in order. They are the only way back into this wallet if you lose this browser or forget your password.'),
      h('ol', { class: 'seed card' }, ...words.split(' ').map((w) => h('li', {}, w))),
      h('label', { class: 'check small', htmlFor: 'wrote' }, confirm, h('span', {}, 'I wrote the words down and keep them somewhere safe.')),
      h('div', { class: 'stack end' }, next),
    ),
  ];
}

function restoreScreen() {
  const seed = h('textarea', { spellcheck: false, autocomplete: 'off', placeholder: '16 or 25 words' }) as HTMLTextAreaElement;
  const created = h('input', { type: 'month' }) as HTMLInputElement;
  const seedHelp = h('div', { class: 'help' }, 'Polyseed (16 words) or a classic Monero seed (25 words).');
  const dateField = field('Created around', created, 'For a 25-word seed, scanning starts a month before this. Leave it empty to scan from the first block, which takes hours.');
  dateField.hidden = true;
  const next = button('Continue', 'primary', () => {
    let restoreHeight: number | undefined;
    const info = check();
    if (!info) return;
    if (!info.polyseed && created.value) {
      restoreHeight = heightAt(network, new Date(`${created.value}-01T00:00:00Z`).getTime() / 1000);
    } else if (!info.polyseed) {
      restoreHeight = 0;
    }
    screen = { name: 'password', words: seed.value, createdNow: false, restoreHeight };
    render();
  }, { disabled: true });

  function check(): { polyseed: boolean; birthday?: number } | null {
    const words = seed.value.trim().split(/\s+/).filter(Boolean);
    if (words.length !== 16 && words.length !== 25) {
      seedHelp.className = 'help';
      seedHelp.textContent = `${words.length} words. A seed has 16 or 25.`;
      dateField.hidden = true;
      next.disabled = true;
      return null;
    }
    try {
      const info = checkSeed(seed.value) as { polyseed: boolean; birthday?: number };
      seedHelp.className = 'help';
      if (info.polyseed && info.birthday) {
        const month = new Date(info.birthday * 1000).toLocaleDateString(undefined, { year: 'numeric', month: 'long', timeZone: 'UTC' });
        seedHelp.textContent = `Polyseed, created around ${month}. Scanning starts there.`;
      } else {
        seedHelp.textContent = 'Classic 25-word seed.';
      }
      dateField.hidden = info.polyseed;
      next.disabled = false;
      return info;
    } catch (e) {
      seedHelp.className = 'help error';
      seedHelp.textContent = errorText(e);
      dateField.hidden = true;
      next.disabled = true;
      return null;
    }
  }
  seed.addEventListener('input', check);

  const seedField = h('div', { class: 'field' }, h('label', { htmlFor: 'f-seed' }, 'Seed'), seed, seedHelp);
  seed.id = 'f-seed';
  return [
    header(iconButton(ICONS.back, 'Back', () => {
      screen = { name: 'welcome' };
      render();
    })),
    strip(network),
    h('main', {}, h('h1', {}, 'Restore from a seed'), seedField, dateField, h('div', { class: 'stack end' }, next)),
  ];
}

function passwordScreen(s: Extract<Screen, { name: 'password' }>) {
  const pw = h('input', { type: 'password', autocomplete: 'new-password' }) as HTMLInputElement;
  const again = h('input', { type: 'password', autocomplete: 'new-password' }) as HTMLInputElement;
  const help = h('div', { class: 'help' }, `At least ${MIN_PASSWORD} characters. It seals the wallet in this browser; the seed is still your backup.`);
  const create = button(s.createdNow ? 'Create wallet' : 'Restore wallet', 'primary', async () => {
    if (pw.value.length < MIN_PASSWORD) {
      help.className = 'help error';
      help.textContent = `Use at least ${MIN_PASSWORD} characters.`;
      return;
    }
    if (pw.value !== again.value) {
      help.className = 'help error';
      help.textContent = 'The passwords do not match.';
      return;
    }
    create.disabled = true;
    create.textContent = 'Sealing';
    // Let the button repaint before the key derivation blocks the thread.
    await new Promise((r) => setTimeout(r, 30));
    try {
      const w = Wallet.create(s.words, network, pw.value, s.restoreHeight, s.createdNow, Date.now() / 1000);
      const sealed = w.sealed();
      meta = { id: w.id(), network };
      await store.saveWallet(meta, sealed);
      blob = sealed;
      await opened(w);
    } catch (e) {
      help.className = 'help error';
      help.textContent = errorText(e);
      create.disabled = false;
      create.textContent = s.createdNow ? 'Create wallet' : 'Restore wallet';
    }
  });
  const passwordField = field('Password', pw);
  const againField = h('div', { class: 'field' }, h('label', { htmlFor: 'f-repeat' }, 'Repeat password'), again, help);
  again.id = 'f-repeat';
  again.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') create.click();
  });
  setTimeout(() => pw.focus(), 0);
  return [
    header(iconButton(ICONS.back, 'Back', () => {
      screen = s.createdNow ? { name: 'new-seed', words: s.words } : { name: 'restore' };
      render();
    })),
    strip(network),
    h('main', {}, h('h1', {}, 'Choose a password'), passwordField, againField, h('div', { class: 'stack end' }, create)),
  ];
}

function unlockScreen() {
  const pw = h('input', { type: 'password', autocomplete: 'current-password' }) as HTMLInputElement;
  const go = button(busy ? 'Unlocking' : 'Unlock', 'primary', unlock, { disabled: busy });
  async function unlock() {
    if (!blob || busy) return;
    busy = true;
    go.disabled = true;
    go.textContent = 'Unlocking';
    await new Promise((r) => setTimeout(r, 30));
    try {
      const w = Wallet.unlock(blob, pw.value);
      unlockError = '';
      busy = false;
      await opened(w);
    } catch (e) {
      busy = false;
      unlockError = errorText(e);
      render();
    }
  }
  pw.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') void unlock();
  });
  setTimeout(() => pw.focus(), 0);
  return [
    header(),
    strip(meta?.network ?? 'mainnet'),
    h(
      'main',
      {},
      h('h1', {}, 'Unlock your wallet'),
      field('Password', pw, unlockError || undefined, Boolean(unlockError)),
      h('div', { class: 'stack' }, go),
    ),
  ];
}

function currentNode(): string {
  const net = meta?.network ?? network;
  return settings.nodes[net] ?? bundledNodes(net)[0] ?? '';
}

function syncLine() {
  const s = status;
  const fraction = s && s.tip > 0 ? s.scanned / s.tip : 0;
  const host = nodeHost(currentNode());
  switch (syncView.kind) {
    case 'needs-access':
      return h(
        'div',
        { class: 'stack' },
        h('p', { class: 'small secondary' }, `Kilonova needs your permission to connect to ${host}. It sends block requests only, never your keys or addresses.`),
        button(`Allow ${host}`, 'primary', () => void allowNode(syncView.kind === 'needs-access' ? syncView.node : currentNode())),
      );
    case 'connecting':
      return h('div', { class: 'sync' }, orbit(0.1, true), `Connecting to ${host}`);
    case 'scanning':
      return h('div', { class: 'sync' }, orbit(fraction, false), s ? `Scanning block ${formatHeight(s.scanned)} of ${formatHeight(s.tip)}` : 'Scanning');
    case 'synced':
      return h('div', { class: 'sync' }, orbit(1, false), s ? `Synced, block ${formatHeight(s.tip)}` : 'Synced');
    case 'failed':
      return h(
        'div',
        { class: 'stack' },
        h('p', { class: 'small error', role: 'alert' }, `Could not sync with ${host}. ${syncView.message}`),
        h(
          'div',
          { class: 'actions' },
          button('Try again', 'secondary', () => void startSync()),
          button('Choose a node', 'secondary', () => {
            screen = { name: 'nodes' };
            render();
          }),
        ),
      );
    default:
      return h('div', { class: 'sync' }, orbit(fraction, false), 'Not synced yet');
  }
}

function walletScreen() {
  const s = status;
  const net = meta?.network ?? 'mainnet';
  const spendableDiffers = s && s.unlocked !== s.total;
  const incoming = s && BigInt(s.incoming) > 0n;
  return [
    header(
      iconButton(ICONS.node, 'Node', () => {
        screen = { name: 'nodes' };
        render();
      }),
      iconButton(ICONS.lock, 'Lock', lock),
    ),
    strip(net),
    h(
      'main',
      {},
      h(
        'section',
        {},
        h('div', { class: 'eyebrow' }, 'Balance'),
        amount(s?.total ?? '0'),
        spendableDiffers ? h('p', { class: 'small secondary mono' }, `${xmrParts(BigInt(s.unlocked)).whole}.${xmrParts(BigInt(s.unlocked)).head} XMR spendable`) : null,
        incoming ? h('p', { class: 'small incoming mono' }, `+${xmrParts(BigInt(s.incoming)).whole}.${xmrParts(BigInt(s.incoming)).head} XMR waiting for a block`) : null,
      ),
      h(
        'section',
        {},
        h('div', { class: 'eyebrow' }, 'Receive'),
        h(
          'div',
          { class: 'card stack' },
          h('div', { class: 'address', id: 'address' }, address),
          h(
            'div',
            {},
            button('Copy address', 'secondary', async () => {
              await navigator.clipboard.writeText(address);
              toast('Address copied');
            }),
          ),
        ),
      ),
      h('section', { class: 'end stack' }, syncLine(), h('p', { class: 'small secondary' }, 'Sending is not in this version yet.')),
    ),
  ];
}

function nodesScreen() {
  const net = meta?.network ?? network;
  const current = currentNode();
  const custom = h('input', { type: 'text', placeholder: 'host:port or https://host:port', spellcheck: false, autocomplete: 'off' }) as HTMLInputElement;
  const help = h('div', { class: 'help' }, 'Your own node keeps the most private. A public node sees your IP address and which blocks you fetch.');
  const use = async (url: string) => {
    // The permission prompt must open inside the click.
    const asked = promptClosesPopup && !inTab ? Promise.resolve(false) : requestNodeAccess(url).catch(() => false);
    settings.nodes[net] = url;
    await store.saveSettings(settings);
    screen = { name: 'wallet' };
    if (await asked) {
      void startSync();
    } else {
      syncView = { kind: 'needs-access', node: url };
      render();
    }
  };
  const customField = h('div', { class: 'field' }, h('label', { htmlFor: 'f-custom' }, 'Your own node'), custom, help);
  custom.id = 'f-custom';
  return [
    header(iconButton(ICONS.back, 'Back', () => {
      screen = { name: 'wallet' };
      render();
    })),
    strip(net),
    h(
      'main',
      {},
      h('h1', {}, 'Node'),
      h(
        'div',
        {},
        h('div', { class: 'eyebrow' }, 'Community nodes'),
        h(
          'div',
          { class: 'card', style: 'padding: 4px' },
          ...bundledNodes(net).map((url) =>
            h('button', { type: 'button', class: 'row', 'aria-current': String(url === current), onclick: () => void use(url) }, h('span', { class: 'mono' }, url)),
          ),
        ),
      ),
      customField,
      h(
        'div',
        { class: 'stack' },
        button('Use this node', 'secondary', () => {
          try {
            const url = normalizeNode(custom.value);
            void use(url);
          } catch (e) {
            help.className = 'help error';
            help.textContent = errorText(e);
          }
        }),
      ),
    ),
  ];
}

// --- Actions --------------------------------------------------------------

async function opened(w: Wallet) {
  wallet = w;
  meta = { id: w.id(), network: w.network() };
  address = w.address();
  // Another tab may have changed the node since this one loaded.
  settings = await store.loadSettings();
  const cache = await store.loadCache(meta.id);
  if (cache) w.loadCache(cache);
  status = w.status() as Status;
  syncView = { kind: 'idle' };
  screen = { name: 'wallet' };
  render();
  void startSync();
}

async function allowNode(url: string) {
  if (promptClosesPopup && !inTab) {
    await chrome.tabs.create({ url: chrome.runtime.getURL('popup.html?tab=1') });
    window.close();
    return;
  }
  const granted = await requestNodeAccess(url).catch(() => false);
  if (granted) void startSync();
}

async function startSync() {
  if (!wallet || !meta || syncing) return;
  clearTimeout(resyncTimer);
  const node = currentNode();
  if (!node) {
    syncView = { kind: 'failed', message: 'no node is set' };
    render();
    return;
  }
  if (!(await hasNodeAccess(node))) {
    syncView = { kind: 'needs-access', node };
    render();
    return;
  }
  syncing = true;
  syncView = { kind: 'connecting', node };
  render();
  const id = meta.id;
  try {
    const done = (await wallet.sync(node, (event: Status) => {
      status = event;
      if (event.cache) void store.saveCache(id, event.cache);
      if (syncView.kind !== 'scanning') syncView = { kind: 'scanning' };
      if (screen.name === 'wallet') render();
    })) as Status;
    status = done;
    if (done.cache) await store.saveCache(id, done.cache);
    syncView = { kind: 'synced' };
    resyncTimer = window.setTimeout(() => void startSync(), RESYNC_MS);
  } catch (e) {
    syncView = { kind: 'failed', message: errorText(e) };
  } finally {
    syncing = false;
  }
  if (screen.name === 'wallet') render();
}

function lock() {
  clearTimeout(resyncTimer);
  if (wallet) {
    wallet.cancel();
    // Keys are wiped once a running sync lets go of them, after its batch.
    wallet.free();
  }
  wallet = null;
  status = null;
  address = '';
  syncView = { kind: 'idle' };
  screen = { name: 'unlock' };
  render();
}

// --- Render loop ----------------------------------------------------------

function render() {
  let view: Child[];
  switch (screen.name) {
    case 'loading':
      view = [header(), h('main', {}, h('div', { class: 'sync' }, orbit(0.1, true), 'Loading'))];
      break;
    case 'welcome':
      view = welcome();
      break;
    case 'new-seed':
      view = newSeedScreen(screen.words);
      break;
    case 'restore':
      view = restoreScreen();
      break;
    case 'password':
      view = passwordScreen(screen);
      break;
    case 'unlock':
      view = unlockScreen();
      break;
    case 'wallet':
      view = walletScreen();
      break;
    case 'nodes':
      view = nodesScreen();
      break;
  }
  // Keep focus and typed text when only the sync line changes.
  const active = document.activeElement;
  if (screen.name === 'wallet' && active && app.contains(active) && active.id !== '') {
    const fresh = h('div', {}, ...view);
    const keep = fresh.querySelector(`#${active.id}`);
    if (keep) keep.replaceWith(active);
    app.replaceChildren(...fresh.childNodes);
    return;
  }
  app.replaceChildren(...view.filter((c): c is Node | string => Boolean(c)));
}

async function main() {
  render();
  // Before any request reaches a node. A browser without the API still
  // works; the node then sees the extension's origin.
  await stripOriginHeader().catch((e) => console.warn('origin header stays:', e));
  await init({ module_or_path: new URL('kn_wasm_bg.wasm', import.meta.url) });
  settings = await store.loadSettings();
  const saved = await store.loadWallet();
  if (saved) {
    meta = saved.meta;
    blob = saved.blob;
    screen = { name: 'unlock' };
  } else {
    screen = { name: 'welcome' };
  }
  render();
}

void main();
