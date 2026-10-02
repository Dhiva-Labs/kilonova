# Kilonova: Monero wallet by Dhiva Labs

Plan draft, revised 2026-10-02. Becomes `PLAN.md` in the initial commit.

## 1. Goal

A non-custodial, open-source Monero wallet for **Linux, Windows and Android**,
with:

- **Two sync modes per wallet:** Full (local scanning against a monerod node)
  and LWS (scanning delegated to a monero-lws server).
- **Multiple wallets** side by side, each with its own password, network and
  sync mode.
- **Network switching** between mainnet, stagenet and testnet.
- A plain, readable privacy policy shipped in the app, the repo and the website.

| Mode | Who scans the chain | What leaves the device | Trade-off |
|---|---|---|---|
| **Full** | The app, against a monerod node (own or remote) | Nothing secret. The node sees your IP and which blocks you fetch | Slower first sync, best privacy |
| **LWS** | A monero-lws server | **Private view key.** The server can see incoming funds | Instant sync, needs a trusted LWS (ideally self-hosted) |

In both modes the **spend key never leaves the device**. Key images,
transaction construction and signing always happen locally.

## 2. Stack

- **UI: Flutter** for Android, Linux and Windows from one codebase.
- **Core: Rust**, called from Dart via `flutter_rust_bridge`.
  - **monero-oxide** (`monero-wallet`, `monero-rpc`) for keys, output
    scanning, decoy selection and transaction building.
  - Own `lws` module for the monero-lws REST API.
- Why not wallet2 / monero_c: wallet2's light-wallet mode is legacy, so LWS
  would need a second transaction builder anyway. One Rust core for both modes
  means one signing path to audit, and monero-oxide is where the FCMP++ work
  lives.
- **Fallback:** if monero-oxide falls short (audit status, missing feature),
  full mode moves to monero_c/wallet2 behind the same `SyncBackend` trait.
  Decided at the end of M2.

### Layout

```
kilonova/
├─ app/                  Flutter UI
│  ├─ lib/theme/         design tokens (colors, type, spacing); the only place colors live
│  ├─ lib/features/      wallets, sync, send, receive, settings
│  └─ assets/fonts/      bundled fonts (never fetched at runtime)
├─ core/                 Rust workspace
│  ├─ kn-keys/           seeds (25-word + Polyseed), subaddresses, view-only
│  ├─ kn-store/          encrypted wallet files, wallet registry, sync cache
│  ├─ kn-sync/           SyncBackend trait; full/ and lws/ implementations
│  ├─ kn-tx/             build, sign, fees, broadcast
│  └─ kn-ffi/            flutter_rust_bridge surface (the only exports)
├─ docs/
│  ├─ adr/               architecture decision records
│  ├─ DESIGN.md          visual rules (section 6)
│  └─ THREAT_MODEL.md
├─ tools/devnet/         docker compose: stagenet + testnet monerod, monero-lws
└─ .github/              CI, issue/PR templates, CODEOWNERS
```

Crates are added in the milestone that needs them: M0 ships `kn-ffi` only,
`kn-keys` and `kn-store` arrive in M1, `kn-sync` in M2 and M3, `kn-tx` in M4.

```rust
trait SyncBackend {
    async fn sync(&mut self, keys: &ViewKeys, from_height: u64) -> SyncDelta;
    async fn unspent_outputs(&self) -> Vec<OwnedOutput>; // spent-ness verified locally via key images
    async fn decoys(&self, n: usize, amounts: &[u64]) -> Decoys;
    async fn submit(&self, tx: &SignedTx) -> TxHash;
    async fn fee_estimate(&self) -> FeeRates;
}
```

## 3. Multi-wallet and networks

- **Wallet registry** (`kn-store`): a small index file listing wallets by id,
  display name, network, mode and file path. It holds **no secrets and no
  balances**, so the wallet list can show without unlocking anything.
- Each wallet is its own encrypted file with its own password. Unlocking one
  never unlocks another.
- **Network is fixed per wallet at creation** (address prefixes differ per
  network, and mixing stagenet coins into a mainnet view is how people get
  confused). Restoring the same seed on another network creates a separate
  wallet entry.
- **Network switcher** at the top of the wallet list: Mainnet / Stagenet /
  Testnet. It filters the list and picks the node/LWS defaults for that
  network. Node and LWS settings are stored per network.
- **Non-mainnet is always visible:** a solid, full-width status strip reading
  "Stagenet: coins have no value" on every screen of a test-network wallet.
- Sync runs for the open wallet. Background sync (Android WorkManager, a
  desktop tray option) covers wallets the user marks "keep synced", one at a
  time, to keep battery and node load sane.
- Quick wallet switching from the app bar; locked wallets show name and
  network only.

## 4. Security baseline (every milestone)

- Wallet files: Argon2id KDF + XChaCha20-Poly1305. Secrets zeroized in Rust,
  kept out of Dart strings wherever possible.
- Seed shown once with a verification step. `FLAG_SECURE` on Android seed and
  send screens; Windows `SetWindowDisplayAffinity` on the same screens.
- LWS mode shows a one-time, plain-language warning that the view key is
  shared, and links the self-hosting guide.
- LWS "spent" claims are hints only; the app recomputes key images locally.
- TLS with optional cert pinning for nodes and LWS; SOCKS5/Tor proxy setting.
- No analytics, no telemetry, no remote crash reporting, no runtime font or
  asset fetching.
- `CODEOWNERS` requires maintainer review for `kn-keys`, `kn-tx`, `kn-store`
  and `kn-sync/lws`.

## 5. Open-source and contribution model

**Repo flow**
1. Create `Dhiva-Labs/kilonova` (public, `main`).
2. Initial commit pushed directly to `main` (milestone M0).
3. Fork to `dhivadhiva/kilonova`; locally `origin` = fork, `upstream` = org.
4. Immediately turn on branch protection for org `main`: PR required, CI
   green, CODEOWNERS review, no force-push, linear history.
5. Every change after that, including the maintainer's, is a PR from a fork
   branch. Squash-merge, conventional commit titles, no AI attribution.

**Contributor setup in M0**
- `CONTRIBUTING.md`: dev setup per OS, how to run devnet, branch naming,
  commit style, what needs tests, the design rules in `docs/DESIGN.md`.
- `CODE_OF_CONDUCT.md` (Contributor Covenant), `SECURITY.md` with a private
  disclosure address and a "never open public issues for vulnerabilities"
  note.
- **DCO sign-off** (`git commit -s`) instead of a CLA.
- Issue templates (bug, feature, translation), PR template with a checklist
  that includes the design rules.
- Labels: `good first issue`, `help wanted`, `area:core`, `area:ui`,
  `security-sensitive`, `platform:windows|linux|android`.
- Translations via Flutter ARB files, English as source.
- `docs/adr/` records each significant decision so contributors can see why,
  not just what.

**Quality bar (what keeps it from reading as generated)**
- Small, reviewed PRs with real descriptions; no 5,000-line drops.
- Tests next to the code they test; Rust core targets high branch coverage on
  keys, tx and store.
- No dead code, no commented-out blocks, no placeholder screens merged to
  `main`, no TODOs without an issue link.
- Comments explain *why*; code reads like one author wrote it.
- `cargo clippy -D warnings`, `flutter analyze` with strict lints, both in CI.

## 6. Design rules

The full rules and color tokens live in [`docs/DESIGN.md`](docs/DESIGN.md).
In short: Kilonova gold (`#7A5B00` light, `#E8B931` dark) is the only
interactive color, on deep-space surfaces (`#0B0F17` dark, `#F6F7F9` light),
set in IBM Plex Sans and IBM Plex Mono. None of the template-app patterns
(gradients, glass cards, scroll fade-ins, em dashes, buzzwords and the rest of
the list) are allowed, and CI enforces the mechanical ones.

## 7. Privacy policy

Shipped as `PRIVACY.md`, as an
in-app screen (Settings → Privacy, readable offline) and on the website.
Written to be read, not to cover us: what is collected (nothing), what each
network connection reveals and to whom, and how to minimise it. Any change
to it goes through a PR with the `privacy` label and a dated changelog at the
bottom.

## 8. Milestones

M0 is the direct commit; everything after is one or more PRs from the fork.

### M0: Scaffold

**Status: done.**

- Flutter shell for Android, Linux and Windows; Rust workspace;
  flutter_rust_bridge proven end to end on all three.
- Theme tokens + fonts per section 6; design lints wired into CI.
- `PLAN.md`, `README.md` (scope, "unaudited" warning), `PRIVACY.md`,
  `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, LICENSE, templates,
  CODEOWNERS, ADR-0001 (Rust core + monero-oxide).
- CI matrix: ubuntu (Rust + Linux build + Android debug APK), windows-latest
  (Windows build), design lints, `cargo fmt/clippy/test`, `flutter analyze/test`.
- `tools/devnet/`: stagenet + testnet monerod and monero-lws.

### M1: Keys, wallet files and multi-wallet

**Status: done.** Windows Hello unlock is not done yet.

- Create / restore from 25-word mnemonic and Polyseed, restore from keys,
  view-only wallets.
- Subaddresses with labels.
- Wallet registry, per-wallet encrypted files, network chosen at creation,
  network switcher, non-mainnet status strip.
- Unlock by password; biometric on Android, Windows Hello later.
- Test vectors against monero-wallet-cli for every network.

### M2: Full-mode sync

**Status: done.**

- monerod RPC: `get_info`, `get_blocks.bin`, `get_transaction_pool`.
- Scanner with subaddress lookahead, key images, spent tracking, reorgs,
  restore height.
- Balances, history, progress. Node manager per network: bundled public nodes plus user-added nodes, user's choice wins.
- **Decision point:** monero-oxide vs wallet2 for full mode (ADR-0002).

### M3: LWS-mode sync

**Status: done.** Not yet tested against MyMonero's hosted API, which needs an account; monero-lws is tested on every push.

- `login`, `import_request`, `get_address_info`, `get_address_txs`,
  `get_unspent_outs`; local key-image verification.
- Per-wallet mode switch with cache rebuild. LWS server URL entered by the user per network (own monero-lws or a provider like MyMonero); no default server. Compatibility tests against monero-lws on devnet and against MyMonero's API on mainnet with a view-only test wallet.

### M4: Sending

**Status: done.** The full-mode ⇄ LWS-mode test runs on the regtest devnet in CI rather than on stagenet.

- Build + sign in `kn-tx`, fee priorities, multiple destinations, sweep.
- Decoys: gamma via `get_output_distribution` (full),
  `get_random_outs` (LWS, documented trade-off).
- Confirm screen, `monero:` URI, QR scan (Android camera; desktop paste/image).
- Stagenet end-to-end: full-mode wallet ⇄ LWS-mode wallet.

### M5: Receive and daily use

**Status: done.** Background sync is Android only; desktops sync while the app is open.

- Receive with QR and amount request, address book, tx notes, tx proofs.
- Background sync for "keep synced" wallets, incoming-tx notifications.
- Opt-in fiat price display (off by default; listed in the privacy policy).

### M6: Hardening and v1.0

**Status: in progress.** Done: fuzz targets with a weekly CI run, release
packaging (split APKs, .deb, tarball, Windows installer and zip, draft
releases with checksums), F-Droid metadata. Open: external review, Windows
code signing, Snap/Flatpak/PPA uploads, F-Droid submission. 0.1.0 ships as
an unaudited pre-release before these.

- External review of `kn-keys`, `kn-tx`, `kn-store`, `lws`.
- Fuzzing of RPC/LWS parsers.
- Packaging: Android (reproducible build, F-Droid metadata, GitHub APK),
  Linux (deb + PPA, snap, Flatpak), Windows (signed installer, MSIX later).
- Mainnet is selectable from M1 but marked "unaudited, small amounts only"
  until M6 completes.

### Later

What Kilonova can do that other wallets do not, ordered by value for
effort, is in [docs/ROADMAP.md](docs/ROADMAP.md).

- Hardware wallets (Ledger, Trezor), multisig, macOS/iOS.
- **FCMP++ migration:** new transaction construction, no decoys. Track
  monero-oxide and monero-lws and ship before the hard fork activates.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Signing or key bug loses funds | Test vectors vs monero-wallet-cli, "unaudited" mainnet label, external review before v1 |
| Wrong-network confusion | Network fixed per wallet, permanent status strip on test networks |
| FCMP++ lands mid-build | Tx building isolated in `kn-tx`; core on the FCMP++ reference stack |
| Malicious LWS server | View key only; local key-image checks; self-host guide |
| Windows code signing cost / SmartScreen warnings | Budget for a certificate before v1; ship unsigned pre-releases labelled as such |
| monero-oxide gap | wallet2 fallback behind `SyncBackend` (ADR-0002) |
| Name collision on "Kilonova" | Trademark and app-store search before M0 goes public |

## 10. Decisions

| # | Decision | Detail |
|---|---|---|
| 1 | **License: MIT** | `LICENSE` in M0, SPDX headers in source files |
| 2 | **Bundled public node list, user can override** | Curated list of well-known Monero community public nodes per network (mainnet, stagenet, testnet), shipped inside the app as a static file. No runtime fetch of the list. Users can add their own node and set it as default; the app remembers it per network. The list is updated through PRs, and a CI job checks that listed nodes still answer `get_info` on the right network |
| 3 | **No Dhiva Labs LWS server** | LWS mode has no default server. The user enters the URL of a server they run (monero-lws) or one they choose to trust, such as MyMonero's. The client speaks the MyMonero-compatible light-wallet REST API that monero-lws implements, so both work |
| 4 | **Accent: Kilonova gold** | `#7A5B00` light / `#E8B931` dark on deep-space surfaces; full token table in section 6 |
