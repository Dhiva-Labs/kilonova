# Audit scope

What an external reviewer of Kilonova should look at, and how to build and
run the tests that back the claims below. Update the file list in the same
PR as any change that moves code into or out of scope.

Status: Kilonova is **not audited**; no external review has taken place, and
this file is preparation for one, not a result of one. It was written for
the 0.3.0 tag and has been refreshed against `main` at commit `d1e67b3`
(after the v0.4.0 tag, which is the latest release). The file lists and
test names below were checked against that tree; the tests themselves were
not re-run for the refresh.

## In scope

The Rust core (`core/`) is where keys, funds and the light-wallet trust
boundary live. The Flutter app (`app/`) calls into it through
`flutter_rust_bridge` and holds no cryptographic logic of its own; it is out
of scope except where noted.

### Keys and seeds: `core/kn-keys/src/lib.rs`

25-word mnemonic and Polyseed generation and recovery, restore from spend or
view key, view-only wallets, subaddress derivation. Test vectors against
`monero-wallet-cli` live in `core/kn-keys/tests/vectors.rs` and
`core/kn-keys/tests/vectors.json`; `core/kn-keys/tests/claimed.rs` checks
claimed-but-unproven properties the code relies on.

### Wallet files and the encrypted store: `core/kn-store/src/lib.rs`, `core/kn-store/src/crypto.rs`, `core/kn-store/src/bundle.rs`

Argon2id key derivation, XChaCha20-Poly1305 encryption of the wallet file,
sync cache and settings, and the wallet registry (which holds no secrets).
`core/kn-store/src/sealed.rs` is the wallet-file container shared with the
browser extension.
Tests: `core/kn-store/tests/store.rs`, `core/kn-store/tests/compat.rs`
(old-format files still open), fixtures in `core/kn-store/tests/fixtures/`.
Backup bundles (`bundle.rs`): a versioned container of wallet files and
sync caches copied as stored, sealed with its own passphrase; restoring must
never overwrite an existing wallet. Tests: `core/kn-store/tests/backup.rs`
and the v1 fixture.
Fuzzed: `core/fuzz/fuzz_targets/wallet_files.rs`,
`core/fuzz/fuzz_targets/backup_bundles.rs`.

### Transaction construction and signing: `core/kn-tx/src/lib.rs`

Build, sign, fee computation and caps, decoy handling (including the ring
checks on a light wallet server's decoys), sweep, `Backend::Full` /
`Backend::Lws` submission, and broadcasting through a node other than the
sync node (`publish_through`, `publish_signed_through`). The fee cap
described in `docs/THREAT_MODEL.md` lives here; the burning-bug handling
(one spendable output per one-time key) lives in `core/kn-sync/src/scan.rs`
and `lws.rs`, not here.
Tests: `core/kn-tx/tests/fee_cap.rs` (runs in plain `cargo test`; it covers
the light wallet server path only), `core/kn-tx/tests/regtest_send.rs`,
`core/kn-tx/tests/regtest_lws_send.rs`,
`core/kn-tx/tests/regtest_full_lws.rs`, `core/kn-tx/tests/regtest_coins.rs`
and `core/kn-tx/tests/regtest_broadcast.rs` (all need the devnet).

### Cold signing: `core/kn-tx/src/cold.rs`

The offline-wallet signing path: reads payments, change and fee from the
transaction it is asked to sign rather than from a textual description,
refuses inputs it cannot spend or change that does not return to itself,
derives key images only for outputs it owns, and binds the signing request
to one wallet and network. This is the one path where a compromised
watching wallet is the adversary (see "Parties and what they can do" in
`docs/THREAT_MODEL.md`). Tests: `core/kn-tx/tests/regtest_cold.rs` (needs
the devnet) and the unit tests in `cold.rs`.

### Light-wallet sync and its verification: `core/kn-sync/src/lws.rs`

The monero-lws REST client (`login`, `get_address_info`,
`import_wallet_request`, `upsert_subaddrs`, `get_unspent_outs`,
`get_address_txs`, plus the random-outputs, fee and submit calls used when
sending) and, critically, the local checks that treat every answer as
untrusted: output ownership verified against the wallet's own keys, RingCT
amounts checked against the reported commitment (which a determined server
can fake; see the threat model), duplicate one-time keys collapsed to one,
"spent" only accepted when the server's key image matches one known
locally, and the transport rules (https/Tor/localhost only, enforced in
`LwsServer::new`; 64 MiB answer cap). The per-server view-key consent is
enforced in `lws_round` in `core/kn-ffi/src/api/sync.rs` (the stored consent
lives in `core/kn-ffi/src/api/wallets.rs`), not in `lws.rs`.
Tests: `core/kn-sync/tests/regtest_lws.rs` (needs the devnet),
`core/kn-sync/tests/lws_dishonest_server.rs` (an adversarial fake server;
one of its two tests needs the devnet's monerod),
`core/kn-sync/tests/lws_transport.rs`, `core/kn-sync/tests/tls_pinning.rs`.
Fuzzed: `core/fuzz/fuzz_targets/lws_replies.rs`.

### Payment proofs and cross-checking a server: `core/kn-sync/src/proof.rs`, `core/kn-sync/src/crosscheck.rs`

`proof.rs` checks a payment proof (transaction key, address, amount)
against the chain without trusting a claim. `crosscheck.rs` is the
"confirm the server's payments" feature (on by default) that re-fetches a
transaction from a node and compares it output by output to what the LWS
server reported. Both look transactions up through `core/kn-sync/src/cover.rs`,
which pads each request with cover hashes (test:
`core/kn-sync/tests/cover_lookups.rs`).
Related: `core/kn-sync/src/opinion.rs` (compares one block hash, ten below
the tip, with a bundled node, once per run) and `core/kn-sync/src/scan.rs`
(the full-mode scanner). `proof.rs` and `crosscheck.rs` have no unit tests
of their own: `crosscheck.rs` is exercised by the devnet-only test
`invented_payments_are_dropped_once_a_node_is_asked` in
`lws_dishonest_server.rs`, and `proof.rs` by a check in
`core/kn-tx/tests/regtest_send.rs`. A reviewer should treat this as thin
coverage, not as "already covered."

### The FFI surface: `core/kn-ffi/src/api/`

The only way the Flutter app reaches the core: `book.rs`, `coins.rs`,
`cold.rs`, `core.rs`, `network.rs`, `nodes.rs`, `preferences.rs`,
`price.rs`, `proof.rs`, `requests.rs`, `send.rs`, `sync.rs`, `wallets.rs`,
and, added since 0.3.0, `background.rs`, `backup.rs` and `push.rs`. Beside
them, `core/kn-ffi/src/background.rs` and `core/kn-ffi/src/node_settings.rs`
are hand-written entry points and settings handling.
Every exported function is a trust boundary from Dart's point of view;
check that inputs crossing it (addresses, amounts, server URLs) are
validated on the Rust side, not assumed valid because the UI validated
them first. `core/kn-ffi/src/frb_generated.rs` is generated by
`flutter_rust_bridge_codegen` and not hand-reviewed line by line, but its
generation inputs (the files above) are.

### Node and transport handling: `core/kn-sync/src/node.rs`, `core/kn-sync/src/tls.rs`, `core/kn-sync/src/discover.rs`

Node selection, certificate pinning, proxy/Tor support (including the
per-wallet, per-purpose SOCKS credentials that isolate Tor circuits, tested
in `core/kn-sync/tests/proxy.rs`), and LAN node discovery. `core/kn-sync/src/blocks.rs` and `core/kn-sync/src/state.rs`
hold the full-mode scanner's block handling and sync state, feeding
`scan.rs`. `blocks.rs` is where a node's blocks are checked (numbering, hash
chain, transaction hashes); note that proof of work is not checked anywhere.

### Background checks and push: `core/kn-sync/src/watch.rs`, `core/kn-sync/src/push.rs`, `core/kn-ffi/src/background.rs`

Added after 0.3.0. The watch state (which holds the private view key and
never the spend key or seed; unit-tested in `watch.rs`) that the Android
background worker keeps encrypted under a Keystore key, and the
UnifiedPush endpoint rules. The Kotlin side that holds the Keystore key and
the fingerprint vault (`app/android/app/src/main/kotlin/com/dhivalabs/kilonova/BackgroundChecks.kt`,
`BiometricVault.kt`, `PushService.kt`) is in `app/` and so formally out of
scope below, but a reviewer of these features should read it. Tests:
`core/kn-sync/tests/selfhost_push.rs` and `core/kn-ffi/tests/regtest_background.rs`
(both need services from `tools/`).

## Out of scope

- **The browser extension**, `extension/` and `core/kn-wasm`: on `main`
  after v0.4.0 but in no release, and not covered by
  `docs/THREAT_MODEL.md`. It runs the same core compiled to WebAssembly and
  holds keys while the popup is open; it would need its own scope and threat
  model before a review of it makes sense.
- **`app/`** (Flutter/Dart UI), except that a reviewer may want to confirm
  that values shown on cold-signing and seed screens match what
  `kn-tx::cold` and `kn-keys` actually produced, since the review screen is
  the user's only check.
- **`core/kn-ffi/src/frb_generated.rs`, `core/kn-ffi/src/bench.rs`,
  `core/kn-ffi/src/test_store.rs`**: generated code and test-only scaffolding,
  not hand-written logic.
- **`tools/`, `packaging/`, `fastlane/`, `.github/`, `docs/`**: build,
  release and documentation tooling. `tools/devnet/` is in scope only as
  the thing that makes the regtest suites below reproducible, not as
  production code. `tools/selfhost/` (including `relay/relay.py`, which
  `docs/THREAT_MODEL.md` relies on for the claim that pushes carry no
  amount) is also out of scope here, which means that claim is not covered
  by this review unless it is added.
- **The Monero protocol itself and monero-oxide's own crates**
  (`monero-wallet`, `monero-rpc`, the curve/transcript crates from
  `serai-dex/serai`): out of scope for this review. Kilonova's dependency
  policy (below) is what a reviewer should check instead of re-auditing
  monero-oxide.
- **monerod and monero-lws**: run as external services in `tools/devnet/`
  and `tools/selfhost/`; Kilonova treats both as untrusted (monerod
  partially, monero-lws fully; see `docs/THREAT_MODEL.md`), which is the
  point of the verification code listed above.

## Trust boundaries

Summarized from `docs/THREAT_MODEL.md`, which is the source of truth and
should be read in full before reviewing:

- The spend key never leaves the device in either sync mode.
- A Monero node (full mode) sees IP and sync timing and can lie about the
  chain or pool; it cannot forge a valid signature or spend. Mitigated by
  user-chosen nodes, local verification of what can be checked locally
  (block linkage and transaction hashes, not proof of work), and one block
  hash compared with a second node (`opinion.rs`), which is a partial check.
  Node traffic is encrypted only for https addresses.
- A light-wallet server (LWS mode) holds the view key and can see all
  incoming payments; it cannot derive the spend key or produce a valid
  spend. Every output it reports is re-verified locally (`lws.rs`); the
  view key is shared only after explicit, per-server consent.
- A compromised or malicious watching wallet can ask a cold wallet to sign
  anything; the cold wallet's own parsing of the transaction
  (`kn-tx/src/cold.rs`) and the user's review screen are the defence, not
  trust in the watching wallet.
- Out of scope for the threat model itself (and therefore for this audit):
  malware with root/administrator access, hardware attacks on the device,
  a user who shares their seed, and bugs in the Monero protocol.

## Building and running the tests

Pinned Rust toolchain: `core/rust-toolchain.toml` (`rustup show
active-toolchain` from `core/` installs it). All commands below run from
the repository root unless noted.

### Unit and property tests

```sh
cd core
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

### Regtest suites (require the devnet)

These exercise real transaction construction, LWS sync against a real
monero-lws, and cold signing against a regtest `monerod`. They are marked
`#[ignore]` so a plain `cargo test` skips them.

```sh
cd tools/devnet
KN_UID=$(id -u) KN_GID=$(id -g) docker compose --profile regtest up -d
                            # see tools/devnet/README.md
cd ../..
tools/check.sh --regtest
```

`tools/check.sh --regtest` runs, in order: `kn-sync`'s `regtest` and
`regtest_lws`, `kn-tx`'s `regtest_send`, `regtest_lws_send`,
`regtest_full_lws` and `regtest_cold`, `kn-sync`'s
`lws_dishonest_server`, `kn-tx`'s `regtest_coins` and `regtest_broadcast`,
and `kn_ffi`'s `regtest_background`, each with `--test-threads 1` since
they share the devnet's chain state, then a Flutter regtest test. The
`regtest.yml` CI job runs the Rust tests in that list except
`regtest_background`, and not the Flutter one.
`kn-sync`'s `selfhost_push` needs the self-hosting kit and is run by
hand.

### Fuzzing

Needs nightly Rust and `cargo-fuzz` (`cargo install cargo-fuzz --locked`;
see `core/fuzz/README.md`):

```sh
cd core/fuzz
cargo +nightly fuzz run lws_replies -- -max_total_time=300
cargo +nightly fuzz run addresses -- -max_total_time=300
cargo +nightly fuzz run wallet_files -- -max_total_time=300
cargo +nightly fuzz run backup_bundles -- -max_total_time=300
```

`.github/workflows/fuzz.yml` runs all four for five minutes weekly;
`core/fuzz/corpus/` holds seed inputs and `core/fuzz/artifacts/` would hold
any crashing input found.

### Dependency checks

```sh
cd core
cargo install cargo-deny --locked
cargo deny check
```

See "Dependency policy" below for what this enforces.

## Dependency policy

- Few dependencies. The monero-oxide crates (`monero-wallet`,
  `monero-daemon-rpc`, `monero-interface`, `monero-epee`) are pinned in
  `Cargo.toml` with `=` to exact versions from crates.io. Other crypto
  crates (`curve25519-dalek`, `argon2`, `chacha20poly1305`, `zeroize`) are
  declared with version ranges in `Cargo.toml` and held to one exact version
  and checksum by `core/Cargo.lock`, which is committed. Releases are not
  built with `--locked`, so a reviewer should confirm the lockfile is what
  actually gets built.
- Two git dependencies pinned in `Cargo.toml` to an exact commit (`rev`):
  `monero-seed` and `polyseed` from
  `https://github.com/kayabaNerve/monero-wallet-util` (currently
  `797fe701a6f9e99ae614c49479bb981de1afe8ec`, because the crates.io
  releases predate the 2025 Polyseed fixes; see `core/kn-keys/Cargo.toml`).
  `monero-wallet` itself now comes from crates.io. A third git source, a
  `serai-dex/serai` revision pulled in transitively by monero-oxide's
  curve and transcript crates (currently
  `4b89cf0206184886e96d0663861596312e5b47d2`), is pinned only by
  `core/Cargo.lock`, not by a `rev` in a manifest. Check `core/Cargo.lock`
  for the exact current revisions. `core/deny.toml`'s `[sources]` section
  allows git dependencies only from the GitHub organizations `kayabaNerve`
  and `serai-dex` (the whole organizations, not just those repositories), so
  a dependency switching to an unreviewed fork elsewhere fails
  `cargo deny check`; a different repository in those two organizations
  would pass.
- `core/deny.toml` enforces an explicit license allow-list (matched to what
  the tree actually uses, not a generic permissive list), flags duplicate
  crate versions as a warning worth looking at (crypto crates especially:
  two copies of a curve or hash implementation mean two codepaths were
  reviewed, or not, instead of one), and checks RustSec advisories. Two
  advisories are currently ignored, each with a documented reason in
  `core/deny.toml`: `RUSTSEC-2025-0056` (`adler`, unmaintained but not
  vulnerable, reached through `flutter_rust_bridge`'s backtrace dependency)
  and `RUSTSEC-2026-0387` (`crypto-bigint` 0.5.5, reached through
  monero-oxide's hash-to-point, where the timing variation involves only a
  public output key; the fix is not available for the 0.5 line). A reviewer
  should judge the second reasoning for themselves. `cargo deny check`
  runs in CI (`.github/workflows/rust.yml`).
- Dependabot opens weekly update PRs for Cargo, pub and GitHub Actions
  (`.github/dependabot.yml`); crypto crates' major (for some, minor)
  versions are left for manual upgrade. Every GitHub Action in the
  workflows is pinned to a commit hash.
- `CODEOWNERS` lists a single owner for `/core/`, `/core/kn-ffi/src/api/`
  and `/.github/workflows/`, on top of the repository-wide default. Branch
  protection on `main` requires a code-owner review but is not enforced
  for administrators, so for a single-maintainer project this is a process
  check, not a second pair of eyes.

## Known limitations

- `proof.rs` and `crosscheck.rs` have no unit tests of their own; see the
  section on them above for what covers them (only tests that need the
  devnet). A reviewer relying on "tested" as a signal should check this
  pair of files more closely than the rest of `kn-sync`.
- The LWS cross-check (`crosscheck.rs`) is **on by default** (it was
  described here as off by default until this refresh, which was wrong
  for the code). Turning it on tells a node which transactions the wallet
  is interested in, which is why each lookup carries cover hashes
  (`cover.rs`); the trade-off is documented in `docs/THREAT_MODEL.md`.
- A node's proof of work is not verified, and the second-node check
  compares a single block hash once per run; a lying node is only partly
  contained (see the threat model).
- Most bundled public nodes are plain http, so node traffic is not
  encrypted in general; only LWS servers are required to use an encrypted
  channel.
- Reproducible builds (so a reviewer can confirm a built binary matches
  this source) are only partly in place: see `docs/RELEASING.md` and
  `tools/repro-check.sh`. The Rust library is byte-identical across two
  builds; the rest of the Linux bundle (the GTK runner, one plugin, the
  Dart snapshot), the `.deb` and everything on Windows are not, and the
  Android APK comparison in CI reports without blocking a release. Do not
  assume a release binary can be rebuilt bit for bit.
- There is no multisig or hardware-wallet support (see
  `docs/ROADMAP-NEXT.md`, "Not doing, on purpose"), so there is no
  multi-party signing path to review. Offline single-key signing does
  exist (`kn-tx/src/cold.rs`, above).
- The app has not had a prior external security review; this is the first
  one being prepared for, and nothing in this repository is a substitute
  for it.
