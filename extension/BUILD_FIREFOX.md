# Building the Firefox add-on from source

Notes for addons.mozilla.org reviewers. The package holds a WebAssembly
module compiled from Kilonova's Rust wallet core, and an esbuild bundle of
the TypeScript popup (bundled, not minified). This archive holds the source
and the steps to rebuild the exact files in `kilonova-firefox-<version>.zip`.

## Environment used

- Ubuntu 26.04.1 LTS, x86_64
- Rust 1.97.1, pinned by `core/rust-toolchain.toml` (rustup installs it on
  first use), with the `wasm32-unknown-unknown` target
- `wasm-bindgen-cli` 0.2.118, the version in `core/Cargo.lock`
- Node.js 24; `npm ci` installs the exact versions in `package-lock.json`
  (esbuild 0.28.2)
- Network access for cargo: crates.io, plus one git dependency
  (`monero-wallet-util` at a fixed revision). `core/Cargo.lock` pins all of it.

## Steps

```bash
rustup target add wasm32-unknown-unknown --toolchain 1.97.1
cargo install wasm-bindgen-cli --version 0.2.118 --locked
cd extension
npm ci
node build.mjs --firefox    # unpacked add-on in dist/firefox
```

`dist/firefox` then matches the submitted package file for file:

```bash
mkdir /tmp/kilonova && unzip -q kilonova-firefox-0.4.0.zip -d /tmp/kilonova
diff -r /tmp/kilonova dist/firefox && echo identical
```

`build.mjs` remaps the checkout and the cargo home to fixed paths
(`--remap-path-prefix`), so the `.wasm` is byte-identical wherever it is
built. `npm run package:firefox` runs the same build and zips it as
`dist/kilonova-firefox-<version>.zip`; `npm run package:source` makes this
source archive with `git archive`.

## Where each file in the package comes from

| Package path | Source |
|---|---|
| `kn_wasm_bg.wasm` | `core/kn-wasm` and the crates it uses, built with `cargo build -p kn-wasm --release --target wasm32-unknown-unknown`, then `wasm-bindgen --target web` |
| `popup.js` | esbuild bundle of `src/popup.ts`, the other `src/*.ts` files, and the JavaScript glue wasm-bindgen writes (`build/wasm/kn_wasm.js`) |
| `popup.html`, `popup.css` | copied from `src/` |
| `icons/` | copied from `icons/` |
| `fonts/` | IBM Plex Sans and Mono with their licence (`OFL.txt`), copied from `app/assets/fonts/`. The add-on never fetches fonts. |
| `LICENSE` | the repository's MIT licence |
| `manifest.json` | `manifest.json`, with `browser_specific_settings.gecko` added by `build.mjs --firefox` |

## Notes for review

- **What it does.** Kilonova is a Monero wallet. It creates and restores
  wallets, seals them with a password, shows the balance and the receive
  address, and syncs by fetching blocks from a node and scanning them in the
  add-on. It cannot send yet. It does not mine.
- **`'wasm-unsafe-eval'`** in the CSP is for the wallet core's WebAssembly.
  There is no `'unsafe-eval'` and no remote code.
- **`optional_host_permissions`** (`http://*/*`, `https://*/*`): nothing is
  granted at install. When the user picks a node (from the community list
  the add-on ships with, or their own), it asks for that one host. Firefox
  closes the popup when a permission prompt opens, so on Firefox it asks
  from a tab (`popup.html?tab=1`).
- **`declarativeNetRequestWithHostAccess`**: one session rule that removes
  the `Origin` header from the add-on's own requests to the node, so a node
  operator can't see the install's `moz-extension://` address. There are no
  other rules.
- **`storage`**: the wallet, sealed with the password (Argon2id with
  64 MiB, then XChaCha20-Poly1305), and the node address.
- **`data_collection_permissions: none`**: the only network traffic is
  block, header and transaction-pool requests to the node the user picks.
  It never sends the seed, keys, password, addresses or balance, and nothing
  goes to Dhiva Labs.
- **To try it**: create a wallet, pick a node from the list, and let it
  sync. No account is needed.
