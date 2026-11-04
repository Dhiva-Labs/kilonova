// Builds the extension into dist/chrome (or dist/firefox with --firefox).
//
//   node build.mjs [--firefox] [--test]
//
// 1. core/kn-wasm to wasm32 (cargo, release profile)
// 2. wasm-bindgen --target web, into build/wasm
// 3. esbuild bundles src/popup.ts
// 4. static files, the app's bundled fonts, and a per-browser manifest
//
// --test adds a host permission for 127.0.0.1 so the e2e test can reach
// the local regtest node without a permission prompt.

import { execFileSync } from 'node:child_process';
import { build } from 'esbuild';
import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..');
const firefox = process.argv.includes('--firefox');
const test = process.argv.includes('--test');
const out = join(here, 'dist', firefox ? 'firefox' : 'chrome');
const wasmOut = join(here, 'build', 'wasm');

const run = (cmd, args, cwd) => execFileSync(cmd, args, { cwd, stdio: 'inherit', env: { ...process.env, CARGO_INCREMENTAL: '0' } });

run('cargo', ['build', '-p', 'kn-wasm', '--release', '--target', 'wasm32-unknown-unknown'], join(repo, 'core'));
await rm(wasmOut, { recursive: true, force: true });
run('wasm-bindgen', [
  '--target', 'web',
  '--out-dir', wasmOut,
  join(repo, 'core', 'target', 'wasm32-unknown-unknown', 'release', 'kn_wasm.wasm'),
], here);

await rm(out, { recursive: true, force: true });
await mkdir(join(out, 'fonts'), { recursive: true });

await build({
  entryPoints: [join(here, 'src', 'popup.ts')],
  bundle: true,
  format: 'esm',
  target: 'es2022',
  outfile: join(out, 'popup.js'),
  // Readable output: store reviewers read the bundle next to the source.
  minify: false,
  legalComments: 'none',
  logLevel: 'warning',
});

await cp(join(wasmOut, 'kn_wasm_bg.wasm'), join(out, 'kn_wasm_bg.wasm'));
await cp(join(here, 'src', 'popup.html'), join(out, 'popup.html'));
await cp(join(here, 'src', 'popup.css'), join(out, 'popup.css'));
await cp(join(here, 'icons'), join(out, 'icons'), { recursive: true });
// The same Plex files the app bundles; never fetched at runtime.
for (const f of ['IBMPlexSans-Regular.ttf', 'IBMPlexSans-Medium.ttf', 'IBMPlexMono-Regular.ttf', 'IBMPlexMono-Medium.ttf', 'OFL.txt']) {
  await cp(join(repo, 'app', 'assets', 'fonts', f), join(out, 'fonts', f));
}
await cp(join(repo, 'LICENSE'), join(out, 'LICENSE'));

const manifest = JSON.parse(await readFile(join(here, 'manifest.json'), 'utf8'));
if (firefox) {
  manifest.browser_specific_settings = {
    gecko: {
      id: 'kilonova@dhiva-labs',
      strict_min_version: '140.0',
      // Full mode sends nodes block requests only: no keys, no addresses.
      data_collection_permissions: { required: ['none'] },
    },
  };
}
if (test) manifest.host_permissions = ['http://127.0.0.1/*'];
await writeFile(join(out, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

console.log(`built ${out}`);
