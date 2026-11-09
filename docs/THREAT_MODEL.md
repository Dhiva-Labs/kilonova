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
locally; suggested fee rates above a hard cap (`MAX_FEE_PER_WEIGHT` in
[`kn-tx`](../core/kn-tx/src/lib.rs), about 2,500 times mainnet's normal
rate) are refused and the send review screen warns when the fee is over 5%
of the amount ([`send_screen.dart`](../app/lib/features/send/send_screen.dart));
outputs that reuse a one-time key (the "burning bug") count once, at the
larger amount ([`scan.rs`](../core/kn-sync/src/scan.rs)); Tor/SOCKS proxy
support.
What "checks what it can locally" means, in
[`blocks.rs`](../core/kn-sync/src/blocks.rs) and `scan.rs`: blocks come
back numbered as asked and each builds on the previous one by hash, and
every transaction matches the hash its block lists; outputs are found with
the wallet's own keys, and a spend is recognised only by a key image the
wallet derived itself (or, for a view-only wallet, one its cold wallet
supplied). **Not implemented:** the wallet does not check proof
of work, block difficulty or any other consensus rule, and does not check
that the node's decoys are well chosen or that the fee estimate is
reasonable below the cap. A node can therefore feed a fabricated chain that
is internally consistent; the only defence against that is the second
opinion below, and it is partial.

**A node linking a transaction to the wallet that syncs from it.** The
sync node sees the wallet's address (or exit) and which blocks it fetches;
if it also received the wallet's transactions, it could tie them to that
sync pattern. With a proxy set and "send through a different node" on (the
default), every transaction, cold-wallet ones included, is published
through a node drawn at random from the bundled list for the network,
never the sync node (in LWS mode, never the network's node), over the
wallet's broadcast circuit ([`kn-tx`, `publish_through`](../core/kn-tx/src/lib.rs);
[`kn-sync`, `other_node`](../core/kn-sync/src/node.rs); the choice is made in
[`kn-ffi/src/api/send.rs`](../core/kn-ffi/src/api/send.rs)). The sync node
is not sent the transaction unless the other node fails or does not answer
in 45 seconds, in which case it goes the usual way and the app says so.
Tested on two regtest daemons with the link between them cut: the
transaction is in the other node's pool and never reaches the sync node
([`kn-tx/tests/regtest_broadcast.rs`](../core/kn-tx/tests/regtest_broadcast.rs),
which needs the Docker devnet and runs in the regtest CI job, not in a plain
`cargo test`). The bundled node list is community-run and mostly plain
http (`nodes.json`), so the transaction crosses the proxy's last hop
unencrypted. What remains:
the broadcast node sees the transaction and the broadcast circuit's exit;
a fallback reveals it to the sync node as before; the sync node can still
guess from timing (a decoy and fee request right before a transaction
appears on the network). Without a proxy it is off, since it would show
the user's IP address to one more node.

**Light wallet server (LWS mode).** Holds the view key, so it sees all
incoming payments and can infer spends. Can lie about outputs, spent status
and decoys.
Mitigations, implemented in [`kn-sync/src/lws.rs`](../core/kn-sync/src/lws.rs)
and tested against a dishonest server
([`kn-sync/tests/lws_dishonest_server.rs`](../core/kn-sync/tests/lws_dishonest_server.rs);
the test of invented payments needs the devnet, the rest run in a plain
`cargo test`) and fuzzed (`core/fuzz`, `lws_replies`):
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
  default (the check is in `lws_round` in
  [`kn-ffi/src/api/sync.rs`](../core/kn-ffi/src/api/sync.rs), not in
  `lws.rs`);
- the view key travels only over https, Tor (onion addresses) or to this
  device: plain http to another machine is refused (`LwsServer::new`), and
  `host:port` means https for servers;
- answers are capped at 64 MiB, so a server cannot exhaust memory.

When sending in LWS mode the server also picks the decoys, suggests the fee
and, without a proxy (or with sending through a different node turned
off), broadcasts the transaction (`kn-tx`, `Backend::Lws`). Kilonova checks
that the ring has 16 distinct outputs whose keys and commitments are valid
curve points, with the real one included (`lws_ring` in `kn-tx`), and
refuses fee rates or rounding masks above the caps, and shows the fee
before anything is broadcast. It cannot check that the decoys are real
outputs on the chain or well distributed. A server already knows which output
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
Mitigations: TLS when the address is https (always required for LWS servers
unless they are onion addresses or on this device), optional certificate
pinning for https addresses ([`tls.rs`](../core/kn-sync/src/tls.rs)),
optional proxy. **Not a mitigation for node traffic in general:** a node
address entered as `host:port` is http, and most of the bundled public
nodes are plain http, so the blocks fetched, the transactions looked up and
the transactions broadcast to such a node are visible to anyone on the path
(a Tor exit included) and can be altered in transit. Kilonova's local
checks (above) are what limits the damage.

**A node or server linking wallets by IP address.** Without a proxy, every
wallet on a device shares one address. Through Tor, each wallet and each
purpose (sync, broadcast, cross-check, second opinion, proof, price, node
discovery and tests) connects with its own SOCKS5 username and password,
which Tor's default stream isolation turns into separate circuits
([`kn-sync/src/node.rs`](../core/kn-sync/src/node.rs), `Circuit`; unit-tested
there and in [`kn-sync/tests/proxy.rs`](../core/kn-sync/tests/proxy.rs)). The credentials hash the wallet id and
purpose only, never key material. What remains: timing (wallet A's sync
and wallet B's sync starting together), a proxy that does not isolate by
credentials (non-Tor SOCKS proxies, or Tor with `IsolateSOCKSAuth` turned
off), and everything a single circuit's node sees about that one wallet.

**A node that lies about the chain.** Once per sync run, full-mode wallets
compare a block ten below the tip with a bundled node they do not use (over
the proxy); a disagreement is shown to the user
([`opinion.rs`](../core/kn-sync/src/opinion.rs); the run-once logic is in
`kn-ffi/src/api/sync.rs`). Private test chains are skipped. If the
reference node cannot answer within 30 seconds, nothing is shown: an
unanswered check is not a disagreement. Only one block hash is compared, so
this catches a node feeding a chain of its own at that moment, not one that
only withholds transactions, and not one that serves the real chain to
this check and a false one otherwise.

**A light wallet server that invents payments.** With "confirm the server's
payments" on, each reported transaction is fetched from the network's node
and compared output by output (one-time key and amount or commitment);
payments the node contradicts are dropped and stay dropped. On by default
([`crosscheck.rs`](../core/kn-sync/src/crosscheck.rs); the setting's default
is in `kn-ffi/src/node_settings.rs`). If the node cannot be reached the
payments are accepted unchecked.

**A node learning which transactions the wallet looks up.** The
cross-check and payment proofs ask a node for specific transactions. Each
request carries 8 hashes ([`kn-sync/src/cover.rs`](../core/kn-sync/src/cover.rs)): the real one at a
uniformly random position and 7 real transactions drawn from random blocks
of a 20-block window that contains the real one's height at a random
offset (the latest 20 blocks when the height is unknown). The batch size
never changes, cover answers are discarded unread, and only an answer
that hashes to the wanted transaction is used
([`kn-sync/tests/cover_lookups.rs`](../core/kn-sync/tests/cover_lookups.rs)). What remains: timing (a lookup right
after a payment arrives), a node that also knows the wallet's history from
elsewhere, and transactions in sparse stretches of chain, where cover is
drawn per block and so favours transactions from emptier blocks.

**The push path (self-hosted, optional).** With payment pushes on
(`tools/selfhost`, `push-register`), the owner's monero-lws calls the kit's
relay for each payment to a registered wallet. The relay drops the webhook
body and posts only the wallet's topic to the kit's ntfy, so a push carries
no amount, address or transaction id
([`relay.py`](../tools/selfhost/relay/relay.py); `tools/selfhost/test-push.sh`
checks this on regtest, but only when run by hand: no CI job runs it or
`kn-sync/tests/selfhost_push.rs`). The topic is 16 random bytes, never derived from the
address or view key; whoever learns it (from the code, the device, the
phone's UnifiedPush app or the server) learns when that wallet receives
payments and nothing else. A push only makes the wallet sync, so a forged
or replayed push costs a sync and a misleading "something arrived"
notification, never a wrong balance. On Android a UnifiedPush endpoint is
bound at the relay only if it is on the wallet's own server
([`kn-sync/src/push.rs`](../core/kn-sync/src/push.rs), `endpoint_topic`), so pushes never pass through a
third-party push service; the kit's compose file publishes no ports for the relay or ntfy and the
Tor service is the way in, and ntfy is set to forward nothing upstream
([`compose.yaml`](../tools/selfhost/compose.yaml)). That is the kit's
default; a user who changes it is on their own. Desktops poll
the topic through the proxy on the wallet's sync circuit, which the server
could link to that wallet anyway. Anyone who can reach the relay and knows
a topic can also bind their own endpoint to it and receive its pushes.

**A watching wallet (or whoever controls it) talking to a cold wallet.** The
cold wallet holds the spend key and never goes online. It reads payments,
change and fee from the transaction it signs, never from the request's
description; refuses inputs it cannot spend, change that does not return to
itself and fees above the cap; and only derives key images for outputs it
owns ([`kn-tx/src/cold.rs`](../core/kn-tx/src/cold.rs), tested in
[`regtest_cold.rs`](../core/kn-tx/tests/regtest_cold.rs) and in the unit tests
in `cold.rs`). Messages carry a short tag of the wallet's address and the
network, and the cold wallet refuses ones for another wallet or network;
the tag is not a signature, so it stops mix-ups, not a malicious sender. A
compromised watching wallet can still ask the owner to sign a payment to
anyone: the cold wallet's review screen, which shows what will actually be
signed, is the defence. The pairing code carries the view key and asks for
the password.

**Someone with the device, locked.** Can copy wallet files.
Mitigations: wallet files are encrypted with Argon2id (64 MiB, 3 passes by
default) and XChaCha20-Poly1305
([`kn-store/src/crypto.rs`](../core/kn-store/src/crypto.rs)); Android cloud
backup and device transfer are disabled for app data
([`AndroidManifest.xml`](../app/android/app/src/main/AndroidManifest.xml),
[`data_extraction_rules.xml`](../app/android/app/src/main/res/xml/data_extraction_rules.xml)).
A weak wallet password is only as strong as Argon2id makes guessing it.

**Someone with a backup file.** A backup (Settings, Backup) can end up on a
USB stick or in cloud storage. It holds each chosen wallet's file and sync
cache exactly as stored, never decrypted (so nothing the locked wallet file
does not hold, even if the wallet was unlocked when the backup was made),
the wallet list entries and the node, server and pinned certificate
settings. The whole bundle is sealed with its own passphrase through the
same Argon2id and XChaCha20-Poly1305 envelope
([`kn-store/src/bundle.rs`](../core/kn-store/src/bundle.rs)),
so names, networks and settings are hidden too, and the wallet files inside
still need their own passwords. Someone who guesses a weak backup
passphrase learns that metadata and gets copies of the locked wallet files,
the same as copying them off the device. The app requires 12 characters for the passphrase when a backup is made
(`kn-ffi/src/api/backup.rs`) and cannot recover it. Restoring never replaces a wallet already on the device: a
clashing id or name is restored next to it under a new id or "(restored)"
name, and bundle contents are length-checked and fuzzed
([`core/fuzz`](../core/fuzz/fuzz_targets/backup_bundles.rs),
`backup_bundles`; tests in [`kn-store/tests/backup.rs`](../core/kn-store/tests/backup.rs)).

**Someone with the device, unlocked and the wallet open.** Can spend.
Mitigations: on Android every unlocked wallet is locked when the app leaves
the foreground (background checks, below, need no unlocked wallet), and on
desktops when the window is closed, unless the owner turns on syncing with
the window closed (Linux and Windows, after a consent screen; the app then
stays in the system tray, or minimized where there is no tray, until quit
from there); showing the seed, changing the password and deleting a
wallet all ask for the password again; seed screens are kept out of screenshots
and screen recording (`FLAG_SECURE` on Android, display affinity on Windows
10 2004 and later; Linux has no equivalent). Sending, signing on a cold
wallet and showing a transaction key ask for the password (or a fingerprint)
again. There is no inactivity timer: an unlocked wallet stays unlocked
while the app is in the foreground (or, on desktops, after the window is
closed if syncing with the window closed is on). The Android fingerprint
option keeps the wallet password encrypted under a Keystore key that needs a
strong biometric
([`BiometricVault.kt`](../app/android/app/src/main/kotlin/com/dhivalabs/kilonova/BiometricVault.kt));
anyone whose fingerprint or face the phone accepts can then spend.
The lock-on-leaving logic is in
[`wallet_registry.dart`](../app/lib/features/wallets/wallet_registry.dart) and
[`desktop_shell.dart`](../app/lib/platform/desktop_shell.dart); screen
capture protection is in
[`MainActivity.kt`](../app/android/app/src/main/kotlin/com/dhivalabs/kilonova/MainActivity.kt)
and [`flutter_window.cpp`](../app/windows/runner/flutter_window.cpp).

**Background checks (Android, optional, off by default).** After a consent
screen, the owner picks wallets to check for incoming payments about every
15 minutes with the app closed (WorkManager; no Flutter engine starts). For
each, a watch state is kept ([`kn-sync/src/watch.rs`](../core/kn-sync/src/watch.rs)): network, mode,
primary address, private view key, public spend key, subaddress counts,
scanned height and recent block hashes, transactions already announced,
and the node or the light wallet server the owner agreed to. Never the
spend key or seed (unit-tested; the format refuses unknown fields). It is
encrypted with AES-GCM under a non-exportable Android Keystore key, bound
to the wallet id, in the app's no-backup directory
([`BackgroundChecks.kt`](../app/android/app/src/main/kotlin/com/dhivalabs/kilonova/BackgroundChecks.kt)). The key has no
user-authentication requirement, so checks run with the phone locked;
whoever can run code as Kilonova on the device (or root) can therefore
read the chosen wallets' view keys and see their incoming payments, but
not spend. Copied off the device, the files are useless without the
Keystore key. Turning checks off, taking a wallet off the list or deleting
the wallet deletes its watch state; with none left, the key too, and the
periodic work is cancelled. The upgrade that introduced checks turns the
old background sync setting off. Checks use the wallet's sync circuit and
the app's current proxy, node and pinned certificates (read from its
settings); with a proxy set and not answering, a check is skipped, never
sent directly. In LWS mode the view key goes only to the server the owner
agreed to for that wallet; if the app's server setting changed, checks
skip. In full mode a check is a view-only scan (`sync_with`, at most 1,440
blocks or one minute per run; a wallet more than a week behind skips to the
last day), so it finds incoming payments and pool payments but not spends.
What remains: the node or server sees a request about every 15 minutes
from the wallet's circuit, including while the app is closed, which says
the phone is on and checking; a node can still hide payments from a check
as it can from a sync.

**Malicious dependency or build pipeline.** Could ship code that leaks keys.
Mitigations that exist: the monero-oxide crates are pinned to exact
versions in `Cargo.toml` (`=0.2.0` and the like) and every other crate,
crypto ones included, is locked to an exact version and checksum by
[`core/Cargo.lock`](../core/Cargo.lock) (the manifests themselves use ranges
for crates such as `curve25519-dalek`, `argon2` and `zeroize`); the two git
dependencies (`monero-seed` and `polyseed`) are pinned to a commit, and
the lockfile pins a third, `serai-dex/serai`, pulled in by monero-oxide;
[`cargo deny`](../core/deny.toml) runs in CI
([`rust.yml`](../.github/workflows/rust.yml)) and rejects unknown registries
and git sources, unlicensed crates and RustSec advisories except two it
ignores with written reasons; Dependabot proposes upgrades weekly and
leaves major (for some, minor) upgrades of the crypto crates to be done
by hand ([`dependabot.yml`](../.github/dependabot.yml)); every GitHub Action in the
workflows is pinned to a commit hash. `CODEOWNERS` names a single owner for
`/core/`, the FFI API and the workflows, and `main` requires a code-owner
review, but that is one person, and branch protection is not enforced for
administrators.
**Partial:** reproducible builds. The Rust library is byte-identical across
two builds, but the rest of the Linux bundle, the `.deb` and everything on
Windows are not, and the two-runner reproducibility check in CI reports without blocking a
release; see [`RELEASING.md`](RELEASING.md). Today nobody can confirm from the
source alone that a released binary matches it.

## Out of scope

- Malware with root or administrator access on the user's device.
- Hardware attacks: cold boot, side channels on the device.
- A user who shares their seed.
- Bugs in the Monero protocol itself.

## Status

Kilonova is **not audited**. No external security review has taken place,
and this document is the project's own analysis, not an assurance.

It was first written ahead of the code. It has since been read against the
code at `main` (commit `d1e67b3`, after the v0.4.0 release): each
mitigation above names the file that implements it, and where one claimed
more than the code does, the text now says what is and is not done. Things
a reader should not assume are covered:

- Proof of work and consensus rules are not checked for a node's chain.
- Node traffic is only encrypted where the node address is https, and most
  bundled nodes are not.
- There is no inactivity lock.
- Reproducible builds are partial.
- Several of the tests cited need the Docker devnet and run only in the
  regtest CI job, or by hand (`tools/selfhost/test-push.sh`); this
  document's claims were not re-run when it was refreshed, only compared
  with the source.
- The browser extension (`extension/`, `core/kn-wasm`) is on `main` but not
  in any release and is not modelled here. Its own README says it keeps
  keys inside a WebAssembly module while unlocked, cannot use Tor or pin
  certificates, and does not yet send; none of that has been analysed against
  this model.

Each milestone should check that its mitigations are implemented and tested
before it is marked done, and this file should change in the same PR as any
change that moves a trust boundary.
