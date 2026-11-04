# Chrome Web Store listing

Copy for the Chrome Web Store dashboard. Keep it plain: the store rejects
lists of brands or keywords and any keyword repeated more than five times.

## Package

`npm run build`, then zip the contents of `dist/chrome` with
`manifest.json` at the root of the zip.

## Store listing tab

**Name:** Kilonova (from the manifest)

**Summary** (from the manifest, 132 characters at most):

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
Pick a community node from the list or enter the address of your own. Kilonova asks for access to a node only when you choose it, and removes the extension's origin from its requests.

What it does not do
• No account and no sign-up. Dhiva Labs runs no server for it.
• No analytics or tracking.
• Sending is not in this version yet.

A public node can see your IP address and which blocks you fetch. For the most privacy, use your own node.

Kilonova is MIT licensed. Source code, build steps and tests: https://github.com/Dhiva-Labs/kilonova
```

**Category:** Tools

**Language:** English

**Graphics** (in `store-assets/`, rebuilt from the e2e screenshots):

| Field | File |
|---|---|
| Store icon (128x128) | `store-icon-128.png` |
| Screenshots (1280x800) | `screenshot-1-welcome.png`, `screenshot-2-wallet-dark.png`, `screenshot-3-wallet-light.png` |
| Small promo tile (440x280) | `promo-small-440x280.png` |
| Marquee promo tile (1400x560) | `promo-marquee-1400x560.png` |

**Official URL / homepage:** https://github.com/Dhiva-Labs/kilonova

**Support URL:** https://github.com/Dhiva-Labs/kilonova/issues

## Privacy practices tab

**Single purpose:**

> Kilonova is a Monero wallet: it creates or restores a wallet, keeps it encrypted in the browser, and shows its balance and receive address by scanning blocks from a node the user chooses.

**Permission justifications:**

| Permission | Justification |
|---|---|
| `storage` | Stores the password-encrypted wallet, its encrypted scan progress, and the node the user chose. Only the wallet's network name, random id and the node address are stored unencrypted. |
| `declarativeNetRequestWithHostAccess` | Adds one session rule that removes the Origin header from the extension's own requests to the node the user chose, so the node cannot tell the request comes from this extension. It does not read, block or change any other traffic. |
| Host permissions (`http://*/*`, `https://*/*`, optional) | Requested at runtime for one node at a time, when the user picks a node from the community list or enters their own. Needed to fetch blocks from that node. Nothing is granted at install. |

**Remote code:** No, I am not using remote code. (The WebAssembly module is
bundled in the package; the CSP allows `'wasm-unsafe-eval'` for it only.)

**Data usage:** tick these, because the extension handles them, even though
it processes them only on the device and sends none of them anywhere:

- Financial and payment information (wallet keys, balance, addresses)
- Authentication information (the wallet password)

Then tick all three certifications: not sold to third parties, not used or
transferred for purposes unrelated to the single purpose, not used to
determine creditworthiness.

**Privacy policy URL:**
https://github.com/Dhiva-Labs/kilonova/blob/main/extension/PRIVACY.md

## Test instructions (for reviewers)

```
No account or login is needed.

1. Open the extension. On the first screen choose "Stagenet" (a test network whose coins have no value), then "Create a wallet".
2. Write down the 16 words (or just tick the box), press Continue, and choose any password of 8 or more characters.
3. The wallet opens and asks permission to connect to a community node. Press "Allow". It syncs in a few seconds and shows "Synced, block ..." with a 0 balance and a receive address.
4. Lock (padlock icon) and unlock with the same password. The node button (ring icon) lists other nodes.

Sending is not in this version.
```

## Distribution tab

Visibility: Public. Pricing: free. Regions: all.
