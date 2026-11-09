# Kilonova browser extension

Kilonova as a Chrome and Firefox extension (Manifest V3). It runs the same
Rust wallet core as the app, compiled to WebAssembly, and syncs in Full
mode: it fetches blocks from a node and scans them itself, so the node never
learns which payments are yours. Nothing runs on a Dhiva Labs server.

This is a first version. It creates and restores wallets, seals them with a
password, shows the balance and the receive address, and syncs against a
community node or your own. It cannot send yet.

## How it is built

| Part | What it is |
|---|---|
| `core/kn-wasm` | wasm-bindgen bindings: seeds, sealed storage, sync, balance |
| `core/kn-sync` | built without its `native` feature: the scanner and wallet state, unchanged, generic over the node transport |
| `core/kn-wasm/src/transport.rs` | monero-oxide's daemon client over `fetch` |
| `core/kn-store` | `SealedWallet`: the wallet file format the app writes, kept in extension storage instead of a folder |
| `extension/src` | the popup: plain DOM and TypeScript, no framework |

The wallet blob and the sync cache are the app's own formats (Argon2id with
64 MiB, then XChaCha20-Poly1305). A wallet file from the app opens in the
extension with the same password.

Sizes: the WebAssembly module is about 1.7 MB, and the whole extension zips
to about 1 MB.

## Build

Needs Rust 1.97.1 with the `wasm32-unknown-unknown` target, `wasm-bindgen`
0.2.118 (the version in `core/Cargo.lock`) and Node 24.

```sh
rustup target add wasm32-unknown-unknown
cargo install wasm-bindgen-cli --version 0.2.118 --locked
cd extension
npm ci
npm run build            # dist/chrome
npm run build:firefox    # dist/firefox
```

Load `dist/chrome` with "Load unpacked" on `chrome://extensions` (developer
mode), or `dist/firefox/manifest.json` from `about:debugging` in Firefox.

## Test

```sh
npm test                 # unit tests
npm run check            # TypeScript
```

The end-to-end test drives the built extension in headless Chrome against
the devnet's regtest node. It creates a wallet, restores a second one, mines
80 blocks to it, and checks the balance the extension shows against the
block rewards the node reports. It also checks that requests to the node
carry no cookies, credentials or extension origin.

```sh
cd tools/devnet
KN_UID=$(id -u) KN_GID=$(id -g) docker compose --profile regtest up -d monerod-regtest monerod-regtest-b
cd ../../extension
npm run build:test
npm run test:e2e -- --shots /tmp/kn-shots          # add --dark for dark mode
```

The Firefox end-to-end test needs no devnet: it runs the Firefox build in
headless Firefox against a public mainnet node, through a logging proxy.
It creates a wallet, connects through the same tab Firefox users see for
the permission prompt, syncs to the node's tip, locks and unlocks, and
checks that requests to the node carry no cookies, credentials or
extension origin. A run takes 10-15 minutes. Checked on Firefox 158.

```sh
npm run build:firefox
FIREFOX=/path/to/firefox node test/e2e-firefox.mjs  # NODE_URL=https://host:port for another node
```

## Privacy

- Keys never leave the WebAssembly module unsealed. Closing the popup or
  pressing Lock drops them; the next open asks for the password.
- Nodes get block requests only. A session rule removes the `Origin` header,
  which would otherwise tell a node the request comes from Kilonova (and on
  Firefox, from which install). Requests carry no cookies and refuse
  redirects.
- The extension asks for access to one node's host when you pick it. It
  asks for nothing at install apart from storage.
- A public node still sees your IP address and which blocks you fetch.
  Browsers do not let an extension use Tor per request or pin certificates,
  so the app is the better choice where that matters.

## Not done yet

- Sending, subaddresses, history, multiple wallets, viewing the seed again.
- Sync runs while the popup or tab is open. Background sync needs an
  offscreen document (Chrome) or event page (Firefox).
- Light wallet server mode.
- A CI job for the extension (it touches `.github/workflows`, so it comes in
  its own PR).
