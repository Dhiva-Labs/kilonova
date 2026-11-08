# addons.mozilla.org listing

Copy for the Firefox Add-ons developer hub. The Chrome Web Store copy is in
[STORE_LISTING.md](STORE_LISTING.md).

## Files

| Upload | Make it with |
|---|---|
| Add-on package | `npm run package:firefox` → `dist/kilonova-firefox-<version>.zip` |
| Source code | `npm run package:source` → `dist/kilonova-source-<version>.zip` (needed: the package holds WebAssembly and bundled JavaScript; [BUILD_FIREFOX.md](BUILD_FIREFOX.md) has the rebuild steps) |

Distribution: **On this site** (listed). Compatibility: Firefox for desktop.
Leave Firefox for Android unticked until it has been tried there.

## Describe add-on

**Name:** Kilonova

**Add-on URL:** `kilonova`

**Summary** (250 characters at most):

> A Monero wallet. Your keys stay in this browser, sealed with your password, and it scans the chain itself against a node you choose.

**Description:**

```
Kilonova is an open-source wallet for Monero that runs in your browser.

What it does
• Creates a new wallet (16-word seed) or restores one from a 16 or 25-word seed.
• Seals the wallet with your password (Argon2id and XChaCha20-Poly1305). It never leaves your browser unencrypted.
• Shows your balance and your receive address.
• Syncs by scanning blocks itself: it fetches blocks from a node you choose and finds your payments on your device, so the node never learns which payments are yours.

Nodes
Pick a community node from the list or enter the address of your own. Kilonova asks for access to a node only when you choose it, and removes the add-on's address from its requests.

What it does not do
• No account and no sign-up. Dhiva Labs runs no server for it.
• No analytics or tracking.
• Sending is not in this version yet.

A public node can see your IP address and which blocks you fetch. For the most privacy, use your own node.

Kilonova is MIT licensed. Source code, build steps and tests: https://github.com/Dhiva-Labs/kilonova
```

**Categories:** Privacy & Security, Other

**Tags:** monero, wallet, cryptocurrency, privacy

**Support website:** https://github.com/Dhiva-Labs/kilonova/issues

**Homepage:** https://github.com/Dhiva-Labs/kilonova

**License:** The MIT License

**Privacy policy:** tick "This add-on has a privacy policy" and paste
[PRIVACY.md](PRIVACY.md).

**Version release notes (0.4.0):**

> First Firefox release. Create or restore a wallet, keep it sealed with your password, see your balance and receive address, and sync against a node you choose. Sending is not in this version.

## Notes to reviewer

```
No account or login is needed.

1. Open the add-on. On the first screen choose "Stagenet" (a test network whose coins have no value), then "Create a wallet".
2. Write down the 16 words (or just tick the box), press Continue, and choose any password of 8 or more characters.
3. The wallet asks to connect to a community node. Firefox closes popups when a permission prompt opens, so the add-on opens itself in a tab and asks there: allow access to that one node. It syncs in a few seconds and shows "Synced, block ..." with a 0 balance and a receive address.
4. Lock (padlock icon) and unlock with the same password. The node button (ring icon) lists other nodes.

Sending is not in this version.

Source: the uploaded source archive rebuilds the package byte for byte; extension/BUILD_FIREFOX.md has the toolchain versions, steps and a note on each permission. The WebAssembly is the wallet core in core/kn-wasm (Rust).
```
