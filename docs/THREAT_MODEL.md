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
locally (proof of work, key images, output ownership); suggested fee rates
above a hard cap (`MAX_FEE_PER_WEIGHT` in `kn-tx`, about 2,500 times
mainnet's normal rate) are refused and the review screen warns when the fee
is over 5% of the amount; outputs that reuse a one-time key (the "burning
bug") count once, at the larger amount; Tor/SOCKS proxy support.

**A node linking a transaction to the wallet that syncs from it.** The
sync node sees the wallet's address (or exit) and which blocks it fetches;
if it also received the wallet's transactions, it could tie them to that
sync pattern. With a proxy set and "send through a different node" on (the
default), every transaction, cold-wallet ones included, is published
through a node drawn at random from the bundled list for the network,
never the sync node (in LWS mode, never the network's node), over the
wallet's broadcast circuit (`kn-tx`, `publish_through`; `kn-sync`,
`other_node`). The sync node is not contacted at all unless that node fails
or does not answer in 45 seconds, in which case the transaction goes the
usual way and the app says so. Tested on two regtest daemons with the link
between them cut: the transaction is in the other node's pool and never
reaches the sync node (`kn-tx/tests/regtest_broadcast.rs`). What remains:
the broadcast node sees the transaction and the broadcast circuit's exit;
a fallback reveals it to the sync node as before; the sync node can still
guess from timing (a decoy and fee request right before a transaction
appears on the network). Without a proxy it is off, since it would show
the user's IP address to one more node.

**Light wallet server (LWS mode).** Holds the view key, so it sees all
incoming payments and can infer spends. Can lie about outputs, spent status
and decoys.
Mitigations, implemented in `kn-sync/src/lws.rs` and tested against a
dishonest server (`kn-sync/tests/lws_dishonest_server.rs`):
- the spend key never leaves the device;
- every output the server reports must open with the wallet's own keys
  (output key, subaddress and index all checked), or it is dropped and the
  user is told how many were dropped. For RingCT outputs the amount must
  open the commitment the server reports; since the server could report a
  matching fake commitment, this stops mistakes and lazy lies, not a server
  determined to invent payments (which then fail when spent). Miner outputs
  and outputs reported without a commitment are taken at the server's word;
- a one-time key reported twice counts once, at the larger amount;
- an output counts as spent only when one of the server's candidate key
  images equals the key image derived locally, so a server cannot fake a
  spend;
- the view key is sent only after the user agrees for that exact server,
  and changing servers asks again; Kilonova runs no server and sets no
  default;
- the view key travels only over https, Tor (onion addresses) or to this
  device: plain http to another machine is refused, and `host:port` means
  https for servers;
- answers are capped at 64 MiB, so a server cannot exhaust memory.

When sending in LWS mode the server also picks the decoys, suggests the fee
and, without a proxy (or with sending through a different node turned
off), broadcasts the transaction (`kn-tx`, `Backend::Lws`). Kilonova checks
that the ring has 16 distinct, valid outputs with the real one included, and
refuses fee rates or rounding masks above the caps, and shows the fee
before anything is broadcast. A server already knows which output
is real from the view key, so decoys it picks protect only against third
parties; a dishonest server could pick decoys that are easy for others to
rule out.

What remains possible for a dishonest server: hiding payments, inventing
incoming payments (which fail when spent), hiding spends, weak decoys, and,
when it is the one broadcasting (no proxy, or sending through a different
node turned off, or that node failing), not broadcasting a transaction. A transaction the server withholds while
reporting it unconfirmed is released after 30 blocks; one it withholds while
claiming it was mined shows as sent, and its inputs stay marked spent until
the wallet syncs in full mode. These are inherent to giving a server the
view key; full sync avoids them.

**Network observer.** Sees connections to nodes and servers.
Mitigations: TLS to nodes and LWS servers, optional certificate pinning,
optional proxy.

**A node or server linking wallets by IP address.** Without a proxy, every
wallet on a device shares one address. Through Tor, each wallet and each
purpose (sync, broadcast, cross-check, second opinion, proof, price, node
discovery and tests) connects with its own SOCKS5 username and password,
which Tor's default stream isolation turns into separate circuits
(`kn-sync/src/node.rs`, `Circuit`). The credentials hash the wallet id and
purpose only, never key material. What remains: timing (wallet A's sync
and wallet B's sync starting together), a proxy that does not isolate by
credentials (non-Tor SOCKS proxies, or Tor with `IsolateSOCKSAuth` turned
off), and everything a single circuit's node sees about that one wallet.

**A node that lies about the chain.** Once per sync run, full-mode wallets
compare a block ten below the tip with a bundled node they do not use (over
the proxy); a disagreement is shown to the user. Private test chains are
skipped. This catches a node feeding a chain of its own, not one that only
withholds transactions.

**A light wallet server that invents payments.** With "confirm the server's
payments" on, each reported transaction is fetched from the network's node
and compared output by output (one-time key and amount or commitment);
payments the node contradicts are dropped and stay dropped. On by default.

**A node learning which transactions the wallet looks up.** The
cross-check and payment proofs ask a node for specific transactions. Each
request carries 8 hashes (`kn-sync/src/cover.rs`): the real one at a
uniformly random position and 7 real transactions drawn from random blocks
of a 20-block window that contains the real one's height at a random
offset (the latest 20 blocks when the height is unknown). The batch size
never changes, cover answers are discarded unread, and only an answer
that hashes to the wanted transaction is used
(`kn-sync/tests/cover_lookups.rs`). What remains: timing (a lookup right
after a payment arrives), a node that also knows the wallet's history from
elsewhere, and transactions in sparse stretches of chain, where cover is
drawn per block and so favours transactions from emptier blocks.

**The push path (self-hosted, optional).** With payment pushes on
(`tools/selfhost`, `push-register`), the owner's monero-lws calls the kit's
relay for each payment to a registered wallet. The relay drops the webhook
body and posts only the wallet's topic to the kit's ntfy, so a push carries
no amount, address or transaction id (`tools/selfhost/test-push.sh` checks
this on regtest). The topic is 16 random bytes, never derived from the
address or view key; whoever learns it (from the code, the device, the
phone's UnifiedPush app or the server) learns when that wallet receives
payments and nothing else. A push only makes the wallet sync, so a forged
or replayed push costs a sync and a misleading "something arrived"
notification, never a wrong balance. On Android a UnifiedPush endpoint is
bound at the relay only if it is on the wallet's own server
(`kn-sync/src/push.rs`, `endpoint_topic`), so pushes never pass through a
third-party push service; the relay and ntfy are reachable only through the
onion address, and ntfy is set to forward nothing upstream. Desktops poll
the topic through the proxy on the wallet's sync circuit, which the server
could link to that wallet anyway. Anyone who can reach the relay and knows
a topic can also bind their own endpoint to it and receive its pushes.

**A watching wallet (or whoever controls it) talking to a cold wallet.** The
cold wallet holds the spend key and never goes online. It reads payments,
change and fee from the transaction it signs, never from the request's
description; refuses inputs it cannot spend, change that does not return to
itself and fees above the cap; and only derives key images for outputs it
owns (`kn-tx/src/cold.rs`). Messages are bound to one wallet and network. A
compromised watching wallet can still ask the owner to sign a payment to
anyone: the cold wallet's review screen, which shows what will actually be
signed, is the defence. The pairing code carries the view key and asks for
the password.

**Someone with the device, locked.** Can copy wallet files.
Mitigations: wallet files are encrypted with Argon2id and
XChaCha20-Poly1305; Android cloud backup and device transfer are disabled for
app data.

**Someone with a backup file.** A backup (Settings, Backup) can end up on a
USB stick or in cloud storage. It holds each chosen wallet's file and sync
cache exactly as stored, never decrypted (so nothing the locked wallet file
does not hold, even if the wallet was unlocked when the backup was made),
the wallet list entries and the node, server and pinned certificate
settings. The whole bundle is sealed with its own passphrase through the
same Argon2id and XChaCha20-Poly1305 envelope (`kn-store/src/bundle.rs`),
so names, networks and settings are hidden too, and the wallet files inside
still need their own passwords. Someone who guesses a weak backup
passphrase learns that metadata and gets copies of the locked wallet files,
the same as copying them off the device. The app requires 12 characters for the passphrase and cannot
recover it. Restoring never replaces a wallet already on the device: a
clashing id or name is restored next to it under a new id or "(restored)"
name, and bundle contents are length-checked and fuzzed
(`core/fuzz`, `backup_bundles`).

**Someone with the device, unlocked and the wallet open.** Can spend.
Mitigations: on Android every unlocked wallet is locked when the app leaves
the foreground, and on desktops when the window is closed, unless the owner
turns on background sync (Android) or syncing with the window closed (Linux
and Windows; the app then stays in the system tray, or minimized where
there is no tray, until quit from there); showing the seed, changing the password and deleting a
wallet all ask for the password again; seed screens are kept out of screenshots
and screen recording (`FLAG_SECURE` on Android, display affinity on Windows
10 2004 and later; Linux has no equivalent). Sending, signing on a cold
wallet and showing a transaction key ask for the password (or a fingerprint)
again.

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
