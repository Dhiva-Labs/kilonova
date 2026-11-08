// End-to-end test: the Firefox build in headless Firefox (WebDriver BiDi),
// against a real Monero mainnet node reached through a logging proxy.
//
//   npm run build:firefox
//   node test/e2e-firefox.mjs [--shots dir]
//
// Env: FIREFOX (default /snap/firefox/current/usr/lib/firefox/firefox: the
// snap's /usr/bin/firefox is a launcher WebDriver can't drive), NODE_URL
// (default: the first bundled mainnet node, https://xmr-node.cakewallet.com:18081).
//
// A new wallet starts some 20,000 blocks behind the tip, so a run against
// mainnet takes 10-15 minutes.
//
// The wallet is pointed at the proxy through its own "Node" screen, and the
// host permission goes through the same path a user takes: on Firefox the
// popup opens popup.html?tab=1 in a tab to ask. The permission doorhanger is
// switched off with extensions.webextOptionalPermissionPrompts=false, which
// grants permissions.request without a prompt.

import assert from 'node:assert/strict';
import { createServer, request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';

const here = dirname(fileURLToPath(import.meta.url));
const extPath = join(here, '..', 'dist', 'firefox');
const upstream = new URL(process.env.NODE_URL || 'https://xmr-node.cakewallet.com:18081');
const shotsAt = process.argv.indexOf('--shots');
const shots = shotsAt > 0 ? process.argv[shotsAt + 1] : null;
if (shots) await mkdir(shots, { recursive: true });

const ID = 'kilonova@dhiva-labs';
const UUID = '3f1d8a52-6c0e-4b7a-9d21-5e8c40a7b6f3';
const EXT = `moz-extension://${UUID}`;
const PASSWORD = 'correct horse';

// A proxy in front of the node that records what the extension sends.
const seen = [];
const send = upstream.protocol === 'https:' ? httpsRequest : httpRequest;
const proxy = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    seen.push({ method: req.method, url: req.url, headers: { ...req.headers } });
    // Forward only what a node needs; the recorded headers are the point.
    const up = send(
      { host: upstream.hostname, port: upstream.port, path: req.url, method: req.method, headers: { 'content-type': req.headers['content-type'] || 'application/json', 'content-length': body.length }, timeout: 60000 },
      (upRes) => {
        res.writeHead(upRes.statusCode, upRes.headers);
        upRes.pipe(res);
      },
    );
    up.on('error', () => res.writeHead(502).end());
    up.end(body);
  });
});
await new Promise((r) => proxy.listen(0, '127.0.0.1', r));
const NODE = `http://127.0.0.1:${proxy.address().port}`;

async function tipHeight() {
  const res = await fetch(new URL('/json_rpc', NODE), { method: 'POST', body: JSON.stringify({ jsonrpc: '2.0', id: '0', method: 'get_info' }) });
  return (await res.json()).result.height;
}

const profile = await mkdtemp(join(tmpdir(), 'kilonova-ff-e2e-'));
const browser = await puppeteer.launch({
  browser: 'firefox',
  executablePath: process.env.FIREFOX || '/snap/firefox/current/usr/lib/firefox/firefox',
  headless: true,
  // WebDriver may only open moz-extension:// pages with this flag.
  args: ['--remote-allow-system-access'],
  // Isolated from the desktop session: no display, no session bus.
  env: { HOME: profile, TMPDIR: profile, PATH: process.env.PATH, LANG: 'en_US.UTF-8' },
  extraPrefsFirefox: {
    'extensions.webextensions.uuids': JSON.stringify({ [ID]: UUID }),
    'extensions.webextOptionalPermissionPrompts': false,
    // Extension errors go to stdout.
    'devtools.console.stdout.content': true,
  },
});

const errors = [];
const warnings = [];
const watch = (stream) =>
  stream.on('data', (d) => {
    for (const line of String(d).split('\n')) {
      if (!line.includes(UUID) && !line.startsWith('console.')) continue;
      if (/error/i.test(line) || line.startsWith('console.error:')) errors.push(`[firefox] ${line.trim()}`);
      else if (/warn/i.test(line)) warnings.push(`[firefox] ${line.trim()}`);
    }
  });
watch(browser.process().stdout);
watch(browser.process().stderr);

const results = [];
async function step(name, fn) {
  const t0 = Date.now();
  try {
    await fn();
    results.push(true);
    console.log(`  ok  ${name} (${Date.now() - t0} ms)`);
  } catch (err) {
    results.push(false);
    console.log(`  FAIL ${name}\n       ${String(err?.stack || err).split('\n').slice(0, 6).join('\n       ')}`);
    if (errors.length) console.log(`       errors: ${errors.join(' | ')}`);
    throw err;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const track = (p, tag) => {
  p.on('console', (m) => {
    if (m.type() === 'error') errors.push(`[${tag}] ${m.text()}`);
    else if (m.type() === 'warning') warnings.push(`[${tag}] ${m.text()}`);
  });
  p.on('pageerror', (e) => errors.push(`[${tag}] ${e.message}`));
  return p;
};
const where = (p) => p.evaluate(() => `${location.href} ${document.readyState}`).catch(() => '');
// Puppeteer doesn't see navigations inside extension pages, so ask the page.
async function openExt(path, tag) {
  const p = track(await browser.newPage(), tag);
  await p.setViewport({ width: 360, height: 600 });
  p.goto(EXT + path, { timeout: 0 }).catch(() => {});
  for (let i = 0; (await where(p)) !== `${EXT + path} complete`; i++) {
    if (i > 100) throw new Error(`${path} did not load`);
    await sleep(100);
  }
  return p;
}
const text = (p) => p.evaluate(() => document.body.innerText);
async function waitText(p, needle, ms = 60000) {
  for (const end = Date.now() + ms; !(await text(p).catch(() => '')).includes(needle); await sleep(200)) {
    if (Date.now() > end) throw new Error(`timed out waiting for "${needle}"; page shows: ${(await text(p)).replace(/\n+/g, ' | ')}`);
  }
}
async function waitSel(p, sel, ms = 30000) {
  for (const end = Date.now() + ms; !(await p.$(sel)); await sleep(200)) {
    if (Date.now() > end) throw new Error(`timed out waiting for ${sel}; page shows: ${(await text(p)).replace(/\n+/g, ' | ')}`);
  }
}
const click = (p, label) => p.locator(`button ::-p-text(${label})`).click();
const type = async (p, sel, value) => {
  await p.click(sel);
  await p.type(sel, value);
};
// WebDriver can't screenshot extension pages (privileged scope), so the
// snapshot is taken in the parent process, as the browser's own tab capture.
async function shot(p, name) {
  if (!shots) return;
  // The wallet column: 360 px wide, inside the tab's 1 px border.
  const box = await p.evaluate(() => {
    const r = document.getElementById('app').getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  });
  const inTab = (await where(p)).includes('?tab=1');
  const size = inTab ? { x: box.x + 1, y: box.y + 1, width: box.width - 2, height: box.height - 2 } : { x: 0, y: 0, width: 360, height: 600 };
  const href = (await where(p)).replace(/ \w+$/, '');
  const { contexts } = (await browser.connection.send('browsingContext.getTree', { 'moz:scope': 'chrome' })).result;
  const { result } = await browser.connection.send('script.evaluate', {
    expression: `(async () => {
      const win = Services.wm.getMostRecentWindow('navigator:browser');
      const tab = win.gBrowser.tabs.find((t) => t.linkedBrowser.currentURI.spec === ${JSON.stringify(href)});
      win.gBrowser.selectedTab = tab;
      await new Promise((r) => win.setTimeout(r, 300));
      const br = win.gBrowser.selectedBrowser;
      const wg = br.browsingContext.currentWindowGlobal;
      const bitmap = await wg.drawSnapshot(new DOMRect(${size.x}, ${size.y}, ${size.width}, ${size.height}), 2, 'white');
      const canvas = win.document.createElementNS('http://www.w3.org/1999/xhtml', 'canvas');
      canvas.width = bitmap.width;
      canvas.height = bitmap.height;
      canvas.getContext('2d').drawImage(bitmap, 0, 0);
      return canvas.toDataURL('image/png');
    })()`,
    target: { context: contexts[0].context },
    awaitPromise: true,
  });
  const url = result.result?.value;
  assert.ok(url, `snapshot failed: ${JSON.stringify(result)}`);
  await writeFile(join(shots, `${name}.png`), Buffer.from(url.split(',')[1], 'base64'));
}
const addressOf = (p) => p.$eval('#address', (el) => el.textContent.trim());

try {
  await browser.installExtension(extPath);
  await sleep(1000);
  console.log(`Kilonova Firefox e2e on ${await browser.version()}, node ${upstream.origin}`);

  let page;
  let address;

  await step('popup loads, wasm core initialises, no console errors', async () => {
    page = await openExt('/popup.html', 'popup');
    await waitText(page, 'A Monero wallet in your browser');
    assert.deepEqual(errors, []);
    await shot(page, '1-welcome');
  });

  await step('create a wallet: seed screen, password, receive address', async () => {
    await click(page, 'Create a wallet');
    await waitSel(page, 'ol.seed li');
    assert.equal((await page.$$('ol.seed li')).length, 16);
    await page.click('#wrote');
    await click(page, 'Continue');
    await type(page, '#f-password', PASSWORD);
    await type(page, '#f-repeat', PASSWORD);
    await click(page, 'Create wallet');
    await waitSel(page, '#address');
    address = await addressOf(page);
    assert.match(address, /^4[0-9A-Za-z]{94}$/);
  });

  await step('pick the node: host access is requested from a tab and granted', async () => {
    // The default node needs host access; the wallet waits for it rather
    // than reaching anywhere. Choose the proxy as "your own node".
    await waitText(page, 'needs your permission to connect');
    await page.click('button[aria-label="Node"]');
    await waitText(page, 'COMMUNITY NODES');
    await type(page, '#f-custom', NODE);
    await click(page, 'Use this node');
    await waitText(page, 'Allow 127.0.0.1');
    assert.equal(seen.length, 0, 'nothing reached the node before access was granted');
    // Firefox closes the popup for a prompt, so the wallet moves to a tab.
    const opened = new Promise((resolve) => browser.once('targetcreated', resolve));
    await click(page, 'Allow 127.0.0.1');
    await opened;
    await sleep(500);
    const pages = await browser.pages();
    let found = null;
    for (const p of pages) if ((await where(p)).startsWith(`${EXT}/popup.html?tab=1`)) found = p;
    assert.ok(found, 'popup.html?tab=1 opened in a tab');
    track(found, 'tab');
    page = found;
    // The wallet is locked in a fresh page; unlock, then allow the node.
    await waitText(page, 'Unlock your wallet');
    await type(page, '#f-password', PASSWORD);
    await click(page, 'Unlock');
    await waitSel(page, '#address');
    await waitText(page, 'Allow 127.0.0.1').catch(() => {});
    if ((await text(page)).includes('Allow 127.0.0.1')) await click(page, 'Allow 127.0.0.1');
  });

  await step('sync reaches the node tip; balance is 0', async () => {
    // A new wallet starts a little before today, and a full scan of those
    // blocks against a public node takes a while.
    const t0 = Date.now();
    let last = '';
    while (!(await text(page)).includes('Synced, block')) {
      const m = (await text(page)).match(/Scanning block ([\d,]+) of ([\d,]+)/);
      if (m && m[1] !== last && Date.now() - t0 > 0) {
        last = m[1];
        if (Number(m[1].replace(/\D/g, '')) % 1000 < 60) console.log(`       scanning ${m[1]} of ${m[2]}`);
      }
      assert.ok(Date.now() - t0 < 20 * 60000, `sync did not finish: ${(await text(page)).replace(/\n+/g, ' | ')}`);
      await sleep(500);
    }
    const tip = await tipHeight();
    const shown = (await text(page)).match(/Synced, block ([\d,\s  .]+)/)[1];
    const height = Number(shown.replace(/\D/g, ''));
    console.log(`       synced block ${height}, node tip ${tip}`);
    // New blocks arrive every two minutes; allow for one or two.
    assert.ok(Math.abs(tip - height) <= 3, `synced ${height}, node at ${tip}`);
    const label = await page.$eval('.balance', (el) => el.getAttribute('aria-label'));
    assert.match(label, /^0(\.0+)? XMR$/);
    assert.equal(await addressOf(page), address);
    await shot(page, '2-synced');
  });

  await step('node traffic: no Origin, Cookie or credentials', async () => {
    assert.ok(seen.length > 0, 'the extension reached the node through the proxy');
    const bad = seen.filter(({ headers: h }) => h.origin || h.cookie || h.authorization || h['proxy-authorization']);
    const origins = [...new Set(seen.map((s) => s.headers.origin).filter(Boolean))];
    assert.equal(bad.length, 0, `Origin/credentials sent: origin=${origins.join(',')} e.g. ${JSON.stringify(bad[0]?.headers)}`);
    console.log(`       ${seen.length} requests, no Origin/Cookie/Authorization; headers: ${[...new Set(seen.flatMap((s) => Object.keys(s.headers)))].join(',')}`);
  });

  await step('lock, then unlock with the password: same address', async () => {
    await page.click('button[aria-label="Lock"]');
    await waitText(page, 'Unlock your wallet');
    await type(page, '#f-password', PASSWORD);
    await click(page, 'Unlock');
    await waitSel(page, '#address');
    assert.equal(await addressOf(page), address);
    await waitText(page, 'Synced, block', 120000);
  });

  await step('no console errors', async () => {
    assert.deepEqual(errors, []);
  });
} finally {
  await browser.close().catch(() => {});
  proxy.close();
  await rm(profile, { recursive: true, force: true });
}

if (warnings.length) console.log(`warnings:\n  ${[...new Set(warnings)].join('\n  ')}`);
const failed = results.filter((r) => !r).length;
console.log(failed ? `${failed} failed` : `all ${results.length} passed`);
process.exit(failed ? 1 : 0);
