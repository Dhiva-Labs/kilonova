# Threat model

What Kilonova protects, from whom, and what it does not try to defend
against. Update this file in the same PR as any change that moves a trust
boundary.

## Assets

| Asset | If lost or leaked |
|---|---|
| Seed and private spend key | Funds can be stolen |
| Private view key | Incoming payments, and over time spending, become visible |
| Wallet password | Opens the wallet file on that device |
| Transaction history, balances, labels, address book | Financial privacy is lost |
| IP address and timing of syncs and broadcasts | Links the user to their activity |

## Parties and what they can do

**Monero node (Full mode).** Sees the user's IP, sync timing and broadcast
transactions. Can lie: withhold blocks, send a fake chain, hide or invent
pool transactions, give bad fee estimates or decoys.
Mitigations: users can pick their own node; the wallet checks what it can
locally (proof of work, key images, output ownership); Tor/SOCKS proxy
support.

**Light wallet server (LWS mode).** Holds the view key, so it sees all
incoming payments and can infer spends. Can lie about outputs, spent status
and decoys.
Mitigations: the spend key never leaves the device; spent status is
recomputed from locally derived key images; the user picks the server and is
warned before the view key is shared; Kilonova runs no server and sets no
default.

**Network observer.** Sees connections to nodes and servers.
Mitigations: TLS to nodes and LWS servers, optional certificate pinning,
optional proxy.

**Someone with the device, locked.** Can copy wallet files.
Mitigations: wallet files are encrypted with Argon2id and
XChaCha20-Poly1305; Android cloud backup and device transfer are disabled for
app data.

**Someone with the device, unlocked and the wallet open.** Can spend.
Not defended beyond app-level re-authentication for sending (planned).

**Malicious dependency or build pipeline.** Could ship code that leaks keys.
Mitigations: few dependencies with exact pins for crypto crates, reviewed
upgrades, CODEOWNERS on security-sensitive paths, pinned CI actions,
reproducible Android builds (M6).

## Out of scope

- Malware with root or administrator access on the user's device.
- Hardware attacks: cold boot, side channels on the device.
- A user who shares their seed.
- Bugs in the Monero protocol itself.

## Status

This model is written ahead of the code. Each milestone checks that its
mitigations are implemented and tested before it is marked done.
