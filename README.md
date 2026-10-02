# Kilonova

[![Rust core](https://github.com/Dhiva-Labs/kilonova/actions/workflows/rust.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/rust.yml)
[![Linux](https://github.com/Dhiva-Labs/kilonova/actions/workflows/linux.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/linux.yml)
[![Windows](https://github.com/Dhiva-Labs/kilonova/actions/workflows/windows.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/windows.yml)
[![Android](https://github.com/Dhiva-Labs/kilonova/actions/workflows/android.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/android.yml)
[![Bindings](https://github.com/Dhiva-Labs/kilonova/actions/workflows/bindings.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/bindings.yml)
[![Design lint](https://github.com/Dhiva-Labs/kilonova/actions/workflows/design.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/design.yml)
[![Regtest](https://github.com/Dhiva-Labs/kilonova/actions/workflows/regtest.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/regtest.yml)
[![Public nodes](https://github.com/Dhiva-Labs/kilonova/actions/workflows/nodes.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/kilonova/actions/workflows/nodes.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-7A5B00)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-Linux%20%7C%20Windows%20%7C%20Android-5A6275)](#build-from-source)

An open-source Monero wallet for Linux, Windows and Android, by Dhiva Labs.

Kilonova can sync two ways, chosen per wallet:

- **Full mode:** the app scans the blockchain itself against a Monero node,
  either one of the bundled public nodes or your own. No keys leave your
  device.
- **LWS mode:** a monero-lws server you choose does the scanning, so sync is
  fast. The server receives your private view key and can see your incoming
  payments. Your spend key always stays on your device.

It holds multiple wallets side by side, and each wallet belongs to one
network: mainnet, stagenet or testnet.

> **Status: early development.** This is milestone M0, the project scaffold.
> Kilonova cannot create wallets or move funds yet, and it has not been
> audited. Do not use it with real funds. See [PLAN.md](PLAN.md) for the
> roadmap.

## How it is built

| Part | Technology | Location |
|---|---|---|
| Interface | Flutter | [`app/`](app) |
| Wallet core | Rust; wallet logic uses [monero-oxide](https://github.com/monero-oxide/monero-oxide) from M1 | [`core/`](core) |
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

Run the checks CI runs:

```sh
cd core && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test && cargo build
cd ../app && flutter analyze && flutter test
cd .. && dart run tools/design_lint/bin/design_lint.dart
```

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
