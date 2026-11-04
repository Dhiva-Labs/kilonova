// End-to-end test: the built extension in headless Chrome against the
// devnet's regtest node (tools/devnet, profile regtest, port 18181).
//
//   npm run build:test && npm run test:e2e [-- --shots dir] [--dark]
//
// It creates a wallet, then restores a second one whose address it mines
// coinbase outputs to, and checks the balance the extension shows against
// the rewards the node reports. Node traffic goes through a logging proxy
// so the test can also check what the extension sends.
//
// Env: CHROME (default /usr/bin/google-chrome), REGTEST (default
// http://127.0.0.1:18181).

import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';
import { Wallet, initSync, newSeed } from '../build/wasm/kn_wasm.js';

const here = dirname(fileURLToPath(import.meta.url));
const ext = join(here, '..', 'dist', 'chrome');
const regtest = new URL(process.env.REGTEST || 'http://127.0.0.1:18181');
const shotsAt = process.argv.indexOf('--shots');
const shots = shotsAt > 0 ? process.argv[shotsAt + 1] : null;
const dark = process.argv.includes('--dark');
if (shots) await mkdir(shots, { recursive: true });

initSync({ module: await readFile(join(here, '..', 'build', 'wasm', 'kn_wasm_bg.wasm')) });

async function rpc(method, params = {}) {
  const res = await fetch(new URL('/json_rpc', regtest), {
    method: 'POST',
    body: JSON.stringify({ jsonrpc: '2.0', id: '0', method, params }),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${method}: ${body.error.message}`);
  return body.result;
}

// A proxy in front of the node that records what the extension sends.
const seen = [];
const proxy = createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    seen.push({ url: req.url, headers: req.headers });
    const up = request(
      { host: regtest.hostname, port: regtest.port, path: req.url, method: req.method, headers: { 'content-length': Buffer.concat(chunks).length } },
      (upRes) => {
        res.writeHead(upRes.statusCode, upRes.headers);
        upRes.pipe(res);
      },
    );
    up.on('error', () => res.writeHead(502).end());
    up.end(Buffer.concat(chunks));
  });
});
await new Promise((r) => proxy.listen(0, '127.0.0.1', r));
const NODE = `http://127.0.0.1:${proxy.address().port}`;

const profile = await mkdtemp(join(tmpdir(), 'kilonova-ext-e2e-'));
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || '/usr/bin/google-chrome',
  headless: true,
  pipe: true,
  enableExtensions: true,
  userDataDir: profile,
  // Isolated from the desktop session: no display, no session bus.
  env: { HOME: profile, PATH: process.env.PATH, LANG: 'en_US.UTF-8' },
  args: ['--no-first-run', '--no-default-browser-check'],
});

const results = [];
let debugPage = null;
let debugErrors = [];
async function step(name, fn) {
  const t0 = Date.now();
  try {
    await fn();
    results.push(true);
    console.log(`  ok  ${name} (${Date.now() - t0} ms)`);
  } catch (err) {
    results.push(false);
    const shown = await debugPage?.evaluate(() => document.body.innerText).catch(() => '');
    if (shown) console.log(`       page: ${shown.replace(/\n+/g, ' | ')}`);
    if (debugErrors.length) console.log(`       errors: ${debugErrors.join(' | ')}`);
    console.log(`  FAIL ${name}\n       ${String(err?.stack || err).split('\n').slice(0, 6).join('\n       ')}`);
    throw err;
  }
}

const text = (page, selector) => page.$eval(selector, (el) => el.textContent.trim());
const click = (page, label) => page.locator(`button ::-p-text(${label})`).click();
async function shot(page, name) {
  if (shots) await page.screenshot({ path: join(shots, `${name}.png`) });
}
async function waitForText(page, needle, timeout = 60000) {
  await page.waitForFunction((n) => document.body.innerText.includes(n), { timeout, polling: 200 }, needle);
}

try {
  const id = await browser.installExtension(ext);
  const popup = `chrome-extension://${id}/popup.html`;
  const page = await browser.newPage();
  await page.setViewport({ width: 360, height: 600 });
  if (dark) await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }]);
  const errors = [];
  debugPage = page;
  debugErrors = errors;
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));

  // Point the regtest network ("fakechain" uses mainnet addresses) at the
  // proxy before the first wallet exists.
  const useNode = () =>
    page.evaluate((node) => chrome.storage.local.set({ settings: { nodes: { mainnet: node } } }), NODE);

  await step('welcome screen loads the wasm core', async () => {
    await page.goto(popup);
    await waitForText(page, 'A Monero wallet in your browser');
    await useNode();
    await shot(page, '1-welcome');
  });

  await step('create: seed, password, wallet', async () => {
    await click(page, 'Create a wallet');
    await page.waitForSelector('ol.seed li');
    const words = await page.$$eval('ol.seed li', (els) => els.map((e) => e.textContent));
    assert.equal(words.length, 16);
    await shot(page, '2-seed');
    assert.equal(await page.$eval('button.primary', (b) => b.disabled), true, 'Continue waits for the checkbox');
    await page.click('#wrote');
    await click(page, 'Continue');
    await page.type('#f-password', 'correct horse');
    await page.type('#f-repeat', 'correct horse');
    await click(page, 'Create wallet');
    await page.waitForSelector('#address', { timeout: 30000 });
    const addr = await text(page, '#address');
    assert.match(addr, /^4[0-9A-Za-z]{94}$/);
    // The extension's address matches the core's derivation of the seed.
    const again = Wallet.create(words.join(' '), 'mainnet', 'x'.repeat(8), 0, false, Date.now() / 1000);
    assert.equal(again.address(), addr);
    again.free();
    await waitForText(page, 'Synced, block');
    await shot(page, '3-wallet-new');
  });

  // A second wallet, restored from a classic seed with no date, scans from
  // the first block and so sees coinbase outputs mined to it.
  const words = newSeed(false, Date.now() / 1000);
  const probe = Wallet.create(words, 'mainnet', 'x'.repeat(8), 0, false, Date.now() / 1000);
  const address = probe.address();
  probe.free();
  let expected = 0n;
  let spendable = 0n;

  await step('regtest: mine 80 blocks to a fresh address', async () => {
    const { blocks } = await rpc('generateblocks', { amount_of_blocks: 80, wallet_address: address });
    const { height } = await rpc('get_info');
    for (const hash of blocks) {
      const { block_header } = await rpc('get_block_header_by_hash', { hash });
      expected += BigInt(block_header.reward);
      // Coinbase outputs unlock 60 blocks after their own.
      if (block_header.height + 60 <= height - 1) spendable += BigInt(block_header.reward);
    }
    assert.ok(expected > 0n);
  });

  await step('restore: classic seed scans from the first block', async () => {
    await page.evaluate(() => chrome.storage.local.clear());
    await page.reload();
    await waitForText(page, 'A Monero wallet in your browser');
    await useNode();
    await click(page, 'Restore from a seed');
    await page.type('#f-seed', words);
    await waitForText(page, 'Classic 25-word seed.');
    await click(page, 'Continue');
    await page.type('#f-password', 'correct horse');
    await page.type('#f-repeat', 'correct horse');
    await click(page, 'Restore wallet');
    await page.waitForSelector('#address', { timeout: 30000 });
    assert.equal(await text(page, '#address'), address);
    await waitForText(page, 'Synced, block');
    const label = await page.$eval('.balance', (el) => el.getAttribute('aria-label'));
    // aria-label is "<whole>.<decimals> XMR"; compare in atomic units.
    const [whole, frac = ''] = label.replace(' XMR', '').replace(/,/g, '').split('.');
    const atomic = BigInt(whole) * 10n ** 12n + BigInt(frac.padEnd(12, '0'));
    assert.equal(atomic, expected, `balance ${label}, node says ${expected} atomic units`);
    if (spendable !== expected) await waitForText(page, 'XMR spendable');
    await shot(page, '4-wallet-funded');
  });

  await step('lock, wrong password, unlock resumes from the sealed cache', async () => {
    await page.click('button[aria-label="Lock"]');
    await waitForText(page, 'Unlock your wallet');
    await page.type('#f-password', 'wrong password');
    await click(page, 'Unlock');
    await waitForText(page, 'Wrong password');
    await shot(page, '5-unlock-error');
    await page.$eval('#f-password', (el) => (el.value = ''));
    await page.type('#f-password', 'correct horse');
    await click(page, 'Unlock');
    await page.waitForSelector('#address', { timeout: 30000 });
    // The cache restores the balance before any block is fetched.
    const label = await page.$eval('.balance', (el) => el.getAttribute('aria-label'));
    assert.notEqual(label, '0.0 XMR');
    await waitForText(page, 'Synced, block');
  });

  await step('node traffic: no cookies, credentials or extension origin', async () => {
    assert.ok(seen.length > 0, 'the extension reached the node through the proxy');
    for (const { headers } of seen) {
      assert.equal(headers.cookie, undefined);
      assert.equal(headers.authorization, undefined);
    }
    // The extension's origin would tell the node this is Kilonova.
    const origins = [...new Set(seen.map((s) => s.headers.origin).filter(Boolean))];
    assert.deepEqual(origins, [], `Origin sent: ${origins.join(', ')}`);
    console.log(`       ${seen.length} requests, no Origin header`);
  });

  await step('no page errors', async () => {
    assert.deepEqual(errors, []);
  });
} finally {
  await browser.close();
  proxy.close();
  await rm(profile, { recursive: true, force: true });
}

const failed = results.filter((r) => !r).length;
console.log(failed ? `${failed} failed` : `all ${results.length} passed`);
process.exit(failed ? 1 : 0);
