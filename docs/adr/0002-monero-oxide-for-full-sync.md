# ADR 0002: monero-oxide for full-mode sync

- Status: accepted
- Date: 2026-10-02

## Context

ADR 0001 chose monero-oxide for the wallet core and left one question open
until milestone M2: whether it is enough for full-mode sync, or whether full
mode should fall back to wallet2 through monero_c.

## Decision

Keep monero-oxide. `kn-sync` uses `monero-daemon-rpc` (with our own HTTP
transport) to fetch blocks and `monero-wallet`'s `Scanner` to find owned
outputs. Key images are computed in `kn-keys`, so the spend key never
leaves it.

## Evidence

The regtest test in `core/kn-sync/tests/regtest.rs` runs against a private
monerod and Monero's own `monero-wallet-rpc` on the same chain, restored
from the same seed. It checks that:

- all 120 mined outputs are found;
- every key image matches monero-wallet-rpc's;
- the balance matches monero-wallet-rpc's;
- a spend made by monero-wallet-rpc from the same seed is detected, with
  the exact amount plus fee and the change counted;
- after a 30-block reorganization the dropped outputs are gone and the
  balance again matches monero-wallet-rpc's.

It also scans live stagenet blocks from the bundled public nodes.

## Consequences

- One wallet stack (monero-oxide) for both sync modes and for signing.
- The HTTP transport is ours, so Tor/SOCKS support and certificate pinning
  can be added without depending on another library's choices.
- monero-oxide's daemon client is pre-1.0; exact versions stay pinned and
  every upgrade runs the regtest test.
