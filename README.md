# Kilonova

[![Rust core](https://github.com/Dhiva-Labs/kilonova/actions/workflows/rust.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/rust.yml)
[![Linux](https://github.com/Dhiva-Labs/kilonova/actions/workflows/linux.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/linux.yml)
[![Windows](https://github.com/Dhiva-Labs/kilonova/actions/workflows/windows.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/windows.yml)
[![Android](https://github.com/Dhiva-Labs/kilonova/actions/workflows/android.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/android.yml)
[![Bindings](https://github.com/Dhiva-Labs/kilonova/actions/workflows/bindings.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/bindings.yml)
[![Design lint](https://github.com/Dhiva-Labs/kilonova/actions/workflows/design.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/design.yml)
[![Regtest](https://github.com/Dhiva-Labs/kilonova/actions/workflows/regtest.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/regtest.yml)
[![Public nodes](https://github.com/Dhiva-Labs/kilonova/actions/workflows/nodes.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/nodes.yml)
[![Fuzz](https://github.com/Dhiva-Labs/kilonova/actions/workflows/fuzz.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/fuzz.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-7A5B00)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-Linux%20%7C%20Windows%20%7C%20Android-5A6275)](#build-from-source)

An open-source Monero wallet for Linux, Windows and Android, by Dhiva Labs:
a Flutter app over a Rust core, with full-node and light-wallet-server sync,
Tor/SOCKS5 support, offline signing and encrypted backups.

> **Not audited, and every release so far is a pre-release.** Kilonova has
> had no external security review. Do not keep more in it than you can
> afford to lose. Stagenet and testnet are there to try it without risk.
> What a reviewer would look at is in [docs/AUDIT-SCOPE.md](docs/AUDIT-SCOPE.md).

Kilonova can sync two ways, chosen per wallet:

- **Full mode:** the app scans the blockchain itself against a Monero node,
  either one of the bundled public nodes or your own. No keys leave your
  device.
- **LWS mode:** a monero-lws server you choose does the scanning, so sync is
  fast. The server receives your private view key and can see your incoming
  payments. Your spend key always stays on your device.

It holds multiple wallets side by side, and each wallet belongs to one
network: mainnet, stagenet or testnet.

Kilonova works end to end (sync, send, receive) and is tested against
Monero's reference wallet, but see the warning above.

## What it does

- Several wallets on mainnet, stagenet and testnet: create, or restore from
  a 25-word or Polyseed seed, a spend key, or as view-only.
- Full sync from a node you choose, including payments waiting in the pool.
- Light wallet server sync with consent per server; every output the server
  reports is checked with your own keys.
- Send to several recipients or send everything; review what the signed
  transaction pays before confirming with your password or fingerprint.
- QR codes and amount requests; camera scanning on Android, image files on
  desktop.
- Offline signing: a phone that never goes online holds the spend key and
  signs for a view-only wallet, with the two exchanging QR codes or files.
- Address book, transaction notes and payment proofs.
- Backups of the wallets you choose to one file, encrypted with its own
  passphrase.
- Tor or SOCKS5 proxy for all traffic, onion nodes, pinned certificates for
  your own node.
- Optional, off by default: prices in your currency, payment notifications,
  checks for payments while the app is closed on Android.

## Engineering highlights

- **A lying light-wallet server cannot add to your balance.** LWS mode
  trusts the server only to find transactions. A test runs a fake server
  that forges outputs and amounts and invents spends, and checks the wallet
  keeps only what its own keys confirm:
  [`kn-sync/tests/lws_dishonest_server.rs`](core/kn-sync/tests/lws_dishonest_server.rs).
  The threat model covers the cross-check against a node.
- **Secrets are wiped from memory.** Seeds and private keys sit in
  `Zeroizing` containers, which clear them on drop, and `Debug` output does
  not print them: [`kn-keys`](core/kn-keys/src/lib.rs). Key derivation is
  checked against `monero-wallet-cli` test vectors in
  [`kn-keys/tests`](core/kn-keys/tests).
- **Tested against a real Monero network.** Regtest suites run monerod and
  monero-lws from [`tools/devnet`](tools/devnet) and cover full sync, LWS
  sync, sending in both modes, offline signing and broadcast fallback; they
  run in [`regtest.yml`](.github/workflows/regtest.yml).
- **Fuzzing of everything read from outside.** Targets for light wallet
  server replies, addresses, wallet files and backup bundles, with a corpus,
  run weekly in [`fuzz.yml`](.github/workflows/fuzz.yml). See
  [`core/fuzz`](core/fuzz).
- **Written threat model.** Assets, adversaries (lying nodes, a light wallet
  server, network observers, someone holding a locked device or a backup)
  and what is deliberately out of scope: [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).
  Decisions are recorded as [ADRs](docs/adr).
- **Offline signing that reads the transaction.** The cold wallet checks
  what the transaction it is asked to sign really pays before signing:
  [`kn-tx/src/cold.rs`](core/kn-tx/src/cold.rs).
- **One Rust core, two front ends.** The same core compiles to WebAssembly
  for the browser extension in [`extension/`](extension) (unreleased; it
  syncs and shows the balance but cannot send yet).
- **Reproducibility check.** [`reproducible.yml`](.github/workflows/reproducible.yml)
  builds the Linux tarball and arm64 APK on two runners on tags and compares
  them. It reports and does not block a release.

## Download

Builds for Android, Linux (.deb and tarball) and Windows (installer and zip)
are on the [releases page](https://github.com/Dhiva-Labs/kilonova/releases),
with `SHA256SUMS`. The latest is
[v0.4.0](https://github.com/Dhiva-Labs/kilonova/releases/tag/v0.4.0), marked
as a pre-release. How releases are made is in
[docs/RELEASING.md](docs/RELEASING.md).

## How it is built

| Part | Technology | Location |
|---|---|---|
| Interface | Flutter | [`app/`](app) |
| Wallet core | Rust, on [monero-oxide](https://github.com/monero-oxide/monero-oxide) | [`core/`](core) |
| Bridge | flutter_rust_bridge 2.13 | [`core/kn-ffi`](core/kn-ffi), [`app/lib/src/rust`](app/lib/src/rust) (generated) |
| Local test networks | Docker Compose: monerod + monero-lws | [`tools/devnet`](tools/devnet) |

Keys, scanning, transaction building and signing live in the Rust core. The
Flutter app never handles a spend key directly. The reasoning is in
[docs/adr/0001-rust-core-and-monero-oxide.md](docs/adr/0001-rust-core-and-monero-oxide.md).

## Build from source

You need:

- Rust (the version is pinned in [`core/rust-toolchain.toml`](core/rust-toolchain.toml); rustup installs it)
- Flutter 3.44 or newer
- Linux: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`
- Windows: Visual Studio 2022 with the "Desktop development with C++" workload
- Android: Android SDK and NDK (Android Studio installs both)

```sh
git clone https://github.com/Dhiva-Labs/kilonova
cd kilonova/app
flutter run -d linux      # or: -d windows, or an Android device id
```

The Rust core is compiled automatically for the target platform on the first
build, through cargokit.

Run the checks CI runs (format, clippy, Rust and Flutter tests, design
lint):

```sh
tools/check.sh             # add --regtest with tools/devnet running
```

To run only the Rust tests: `cd core && cargo test --workspace`. The
regtest suites are marked `#[ignore]` and need the devnet from
[`tools/devnet`](tools/devnet); `tools/check.sh --regtest` runs them with
the exact commands CI uses. Fuzzing is described in
[`core/fuzz/README.md`](core/fuzz/README.md).

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md),
which covers setup, the pull request flow and the design rules in
[docs/DESIGN.md](docs/DESIGN.md). Issues labelled `good first issue` are a
good place to begin.

Please report security problems privately, as described in
[SECURITY.md](SECURITY.md), not in public issues.

## Privacy

Kilonova collects nothing. There are no accounts, no analytics and no crash
reporting. The [privacy policy](PRIVACY.md) explains what each network
connection reveals and to whom. The same text ships inside the app under
Settings, Privacy policy.

## License

[MIT](LICENSE). The bundled IBM Plex fonts are under the
[SIL Open Font License](app/assets/fonts/OFL.txt).

Kilonova is an independent project and is not affiliated with the Monero
Project.
