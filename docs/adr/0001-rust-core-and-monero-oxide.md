# ADR 0001: Rust core built on monero-oxide, Flutter interface

- Status: accepted
- Date: 2026-10-02

## Context

Kilonova needs two sync modes, Full (the wallet scans blocks from a monerod
node) and LWS (a monero-lws server scans with the user's view key), on
Linux, Windows and Android. In both modes the wallet must build and sign
transactions locally.

The usual options for Monero wallet logic:

1. **wallet2** (Monero's C++ wallet), usually through monero_c bindings.
   Battle-tested for Full mode. Its light-wallet support is legacy and not
   maintained, so LWS mode would need a separate transaction builder anyway.
2. **monero-oxide** (Rust, formerly monero-serai). Published on crates.io as
   `monero-oxide`, `monero-wallet` and related crates under the MIT license.
   It is the library Monero's FCMP++ upgrade is being built on. It is young
   (0.x versions) and parts of it have been externally reviewed, but not the
   whole wallet path.

For the interface, the team already ships Flutter apps on all three target
platforms.

## Decision

- Wallet logic lives in a Rust workspace under `core/`, using monero-oxide
  for keys, scanning, decoy selection and transaction building.
- Both sync modes sit behind one `SyncBackend` trait, so there is one
  signing path to review regardless of mode.
- The interface is Flutter, calling Rust through flutter_rust_bridge 2.x.
  Only `core/kn-ffi` is exported; it converts types and holds no wallet logic.
- Secrets stay in Rust memory and are zeroized there. The Dart side receives
  only what it has to display.

## Consequences

- One language for everything security-critical, with Rust's memory safety.
- FCMP++ support should arrive through monero-oxide instead of a rewrite.
- monero-oxide is pre-1.0. We pin exact versions, review upgrades, and keep
  mainnet labelled "unaudited" until the external review in milestone M6.
- If monero-oxide cannot do something Full mode needs, the fallback is
  wallet2 through monero_c behind the same `SyncBackend` trait. That
  decision is due at the end of milestone M2 and will be recorded as
  ADR 0002.
- Contributors need both Rust and Flutter toolchains.
