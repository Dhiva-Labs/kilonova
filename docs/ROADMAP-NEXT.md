# After 0.2.0: what comes next

Kilonova 0.2.0 shipped everything in [ROADMAP.md](ROADMAP.md): an offline
phone that signs over QR codes, pairing with a self-hosted node and light
wallet server, server reports checked against a node, payment requests,
coin control, a second opinion on the chain, node discovery on the LAN and
payment proof checks. The core is five Rust crates on monero-oxide with
regtest coverage for full sync, LWS sync, sending in both modes and cold
signing. The app is Flutter on Linux, Windows and Android, in English only,
not audited, and not yet in F-Droid or signed on Windows.

Two things changed in the landscape since that file was written, and this
plan takes them into account:

- Cake Wallet's Cupcake now does QR cold signing between two phones, and
  Monerujo's Sidekick does it over Bluetooth. Kilonova's offline wallet is
  no longer the only one, so its edge has to be what the cold side verifies
  (it reads the real payments out of the transaction it signs), not that it
  exists.
- MyMonero shut down on 6 January 2026. The light-wallet API lives on in
  monero-lws and in Skylight, but a hosted server is no longer the obvious
  choice, which makes Kilonova's self-hosting kit and server checks more
  useful, not less.

The rule for picking features is the same as before, in this order:
privacy and verifiability first; things other wallets do not do, or do
badly; and feasible with the code in this repository, named per feature.
Where a feature depends on something outside the repository (the FCMP++
hard fork date, monero-oxide's FCMP++ release, a signing certificate), that
dependency is stated and the feature is sized for the part Kilonova
controls.

Sizes: S (days), M (one to two weeks), L (several weeks). Each group is
ordered by value for effort.

## Must do before 1.0

None of these are novel. They are what a wallet needs to be trusted with
real money, and 1.0 should not ship without them.

### 1. Backup and restore of wallet files (M)

**What.** Export one wallet, or all of them, as a single encrypted bundle:
the wallet file, its sync cache, labels, address book, notes, payment
requests and per-wallet settings (node, server, mode, pinned
certificate). Import the bundle on another device or after a reinstall.
The bundle is encrypted with its own passphrase, separate from the wallet
passwords, so a backup can sit on a USB stick or in cloud storage without
exposing anything.

**Why.** Today the only backup is the seed, which recovers funds but not
labels, contacts, requests, notes or the restore height, and forces a
rescan. Every mainstream wallet has some form of file backup; a wallet
without one loses users the first time they change phones.

**Builds on.** `kn-store` already has the per-wallet encrypted file
(`crypto.rs`: Argon2id and XChaCha20-Poly1305), `save_cache` /
`load_cache` and `read_settings` / `write_settings`. The bundle is a new
container in `kn-store` that wraps those byte strings with their own
header, plus an `api/backup.rs` in `kn-ffi` and a screen under Settings.
Android's cloud backup stays disabled; the user chooses where the file
goes.

**Risks.** Format lock-in: version the header from day one and add the
bundle to `core/fuzz` next to `wallet_files.rs`. A backup made while a
wallet is unlocked must not include anything the locked file does not.

**Done when.** Round trip test in `kn-store/tests`: export, wipe,
import, and every field compares equal. A fuzz target for the bundle
parser. A `compat.rs` fixture so a 1.0 bundle still opens in later
versions. The privacy policy says what the bundle contains.

### 2. Reproducible builds and audit preparation (M)

**What.** Make the Android APK and the Linux tarball reproducible: anyone
who checks out the tag gets byte-identical output, and the release notes
show how to verify it. Alongside, write the document an auditor needs:
scope (`kn-keys`, `kn-store`, `kn-tx`, `kn-sync/src/lws.rs`, the FFI
surface), the trust boundaries from `THREAT_MODEL.md`, how to run the
regtest suite, and the dependency policy. Add `cargo-deny` (licenses,
advisories, duplicate crates) to CI and a `cargo-vet` or equivalent
audit record for the crypto dependencies.

**Why.** The threat model lists "malicious dependency or build pipeline"
and promises reproducible Android builds under M6. An external review is
the single thing that removes the "unaudited" warning, and reviewers
charge for time spent orienting; the scope document saves that time.
Reproducibility is also what F-Droid's own build server will test.

**Builds on.** `docs/RELEASING.md`, the release workflow, pinned
toolchains in `core/rust-toolchain.toml` and exact pins for monero-oxide.
The app side needs a pinned Flutter version and a fixed build path.

**Risks.** Flutter's engine artifacts and cargokit are the usual sources
of nondeterminism; expect a few rounds of diffing. The audit itself costs
money and is not sized here.

**Done when.** A CI job builds the APK twice on separate runners and
diffs them. `docs/AUDIT-SCOPE.md` exists and names every file in scope.
`cargo deny check` passes in CI.

### 3. F-Droid, Flatpak and Windows code signing (M)

**What.** Submit to F-Droid (the metadata in `fastlane/` is ready; it
needs a merge request to fdroiddata and a reproducible build). Publish
the Flatpak on Flathub using the AppStream file in `packaging/linux`.
Buy a code-signing certificate and sign the Windows installer and zip so
SmartScreen stops warning.

**Why.** Users who care about privacy install from F-Droid, and a wallet
not on it is invisible to them. The SmartScreen warning is the first
thing a Windows user sees and it reads as "malware".

**Builds on.** `fastlane/metadata`, `packaging/linux`, `packaging/windows`,
the release workflow.

**Risks.** F-Droid review takes weeks and may ask for changes to the
build recipe. Certificate cost and the key-custody question (a hardware
token held by one person, with the procedure written down in
`RELEASING.md`).

**Done when.** The app appears in F-Droid and Flathub; a signed
installer shows the publisher name without a warning; `RELEASING.md`
documents all three.

### 4. FCMP++ and Carrot readiness (L)

**What.** Be able to send, receive and cold-sign on the FCMP++ chain
before it activates on mainnet, with Carrot addresses for new wallets and
legacy seeds still working.

**What I could verify.** The FCMP++ and Carrot beta stressnet v3.0 forks
from testnet on 5 October 2026 (block 3102800, per the
seraphis-migration release). It includes hot-cold wallet support but
states that hardware wallets, multisig and transaction proofs do not
work yet. No mainnet activation date has been published; some news sites
claim FCMP++ already activated in early 2026, and that is false. The
FCMP++ implementation lives on a branch of monero-oxide, with the
`monero-fcmp-plus-plus` crate held back until its audit completes.
vtnerd's CCS proposal for monero-lws includes updating the LWS spec for
Carrot's view-balance key and making the backend work with the FCMP++
branch. I could not verify how far either of those has progressed.

**Why.** Kilonova's whole core is on monero-oxide, which is where the
FCMP++ reference work lives. Being ready at the fork is the one time a
small wallet can be ahead of the large ones, and being late means every
wallet stops working on the day the chain forks.

**Builds on.** `kn-tx` is the only crate that builds transactions, and
`Backend` already abstracts full versus LWS. `kn-keys` owns key
derivation and would grow the Carrot hierarchy (master secret,
prove-spend, view-balance, generate-image) next to the legacy keys.
`kn-sync/src/scan.rs` uses monero-oxide's `Scanner`, so Carrot scanning
is mostly an upgrade. `kn-tx/src/cold.rs` must be re-done for FCMP++
signing, and the stressnet now has reference hot-cold behaviour to test
against. `tools/devnet` gets a third compose profile pointing at the
stressnet binaries.

**Risks.** The biggest item on this list and the one with the least
control: it moves when monero-oxide and the fork move. Spend it in
stages: (a) a stressnet profile in devnet and a CI job that only reports,
(b) scanning and receiving, (c) sending, (d) cold signing, (e) LWS, which
waits on monero-lws. Do not merge anything into `kn-tx` for the live
chain until the crate is published and audited; keep it behind a cargo
feature until then.

**Done when.** `regtest.rs`, `regtest_send.rs` and `regtest_cold.rs`
have FCMP++ counterparts that run against the stressnet daemon in CI; a
Carrot address created in Kilonova receives from monero-wallet-cli and
vice versa; a legacy 25-word seed restores on both chains.

### 5. Multiple accounts (M)

**What.** Accounts (the major subaddress index) as a first-class thing:
create, label, pick which account receives and which pays, balance and
history per account.

**Why.** It is how Monero users separate business from personal, or one
customer from another, inside a single seed. The official wallet, Feather
and Monerujo have it; Kilonova hard-codes account 0.

**Builds on.** `kn-keys::address(network, account, index)` already takes
the account. `SyncState::received_by(account, index)` and
`AddressLabel` carry the account. The work is the lookahead in
`kn-sync/src/scan.rs` (today `SUBADDRESS_LOOKAHEAD` on account 0 only),
the LWS `import_request` path in `lws.rs` that reports handed-out indices
per account, coin selection in `kn-tx::spendable_selected` filtered by
account, and the wallet screen.

**Risks.** Lookahead across accounts multiplies the keys the scanner
checks; keep the account lookahead small (a few) and only extend when
one is used. Payment requests and the "linked addresses" warning in coin
control must learn about accounts or they give wrong answers.

**Done when.** The regtest full and LWS tests receive on account 1 and
spend from it without touching account 0; the coin-control warning fires
across accounts; monero-wallet-rpc agrees on every per-account balance.

### 6. Accessibility (M)

**What.** Screen-reader labels on every control (the app has ten
`Semantics` uses today), focus order and keyboard navigation on desktop,
a large-text pass so amounts and addresses wrap instead of clipping, and
the status-is-never-color-alone rule checked for the new 0.2.0 screens.

**Why.** A wallet that TalkBack cannot read is unusable for blind users,
and desktop users expect Tab and Enter to work. None of the mobile Monero
wallets do this well, so it is cheap to be the one that does.

**Builds on.** `docs/DESIGN.md` already requires contrast and non-color
status; `tools/design_lint` can gain a check for icon buttons without a
label. The widget tests under `app/test/widgets` are the place for
semantics assertions.

**Risks.** Easy to do halfway. Pick a checklist (WCAG 2.2 AA for what
applies to native apps) and test with TalkBack and Orca, not only with
the Flutter semantics tree.

**Done when.** Every interactive widget has a semantics label asserted in
a test; the send flow completes with keyboard only on Linux and Windows;
the lint fails on an unlabeled icon button.

### 7. Translations (M)

**What.** Open the ARB file to translators through Weblate or a similar
hosted tool, add the pipeline that imports completed languages, and ship
the first few (whatever the community provides first; Spanish, German,
Russian and Portuguese cover most Monero users). The privacy policy and
the in-app legal texts are translated last and only by someone who can
vouch for the meaning.

**Why.** The app is English only, which rules out most of the world.
Translation infrastructure is a prerequisite for F-Droid growth and for
contributors who cannot write Rust.

**Builds on.** `app/lib/l10n/app_en.arb` and the generated
`AppLocalizations`; the issue template for translations already exists.

**Risks.** Untranslated strings leak into the UI as the app grows; add a
CI check that every key in `app_en.arb` is used and every language file
has no stale keys. Right-to-left layout is a separate job and not in
this size.

**Done when.** A second language renders every screen without clipping in
the screenshot tests; the sync process is documented in
`CONTRIBUTING.md`.

### 8. Desktop keeps syncing in the tray (S)

**What.** On Linux and Windows, closing the window keeps the app in the
system tray syncing the wallets marked "keep synced", with the same
notification rules as Android.

**Why.** Listed as a known limit in every release note so far. It makes
the watching wallet on a desktop (the partner of an offline phone)
actually useful.

**Builds on.** The background code behind `settings/background_screen.dart`
and the notification plumbing; `kn-ffi/src/api/sync.rs` already runs
sync on a tokio runtime that outlives a screen.

**Risks.** Tray support on Linux varies by desktop; fall back to a plain
hidden window where there is no tray.

**Done when.** A desktop integration test closes the window, mines a
block on regtest that pays the wallet, and sees the notification.

## Differentiators

Six things other wallets do not do, or do only on desktop, each small
enough to ship alongside the list above.

### 1. One Tor circuit per wallet (S)

**What.** When the proxy is Tor, give each wallet (and each separate
purpose: sync, broadcast, cross-check, price) its own SOCKS5 username and
password. Tor isolates circuits by SOCKS credentials, so two wallets on
the same phone never share an exit, and a node that sees wallet A's sync
cannot link it to wallet B's broadcast by IP.

**Why.** Today every connection shares the proxy and therefore, by
default, the same circuit for as long as it lives. A user with a business
wallet and a personal wallet is one exit address to every node they use.
I could not confirm that any mobile wallet does this; Feather routes
through Tor but I did not find per-wallet isolation documented.

**Builds on.** `kn-sync/src/node.rs`: `ProxyUrl` and `set_proxy`. The
change is a per-connection credential derived from the wallet id and
purpose, passed to reqwest's SOCKS proxy. No UI beyond a sentence on the
proxy screen.

**Risks.** Only works with Tor and only when the SOCKS port has isolation
on (Orbot and the Tor daemon do by default). Non-Tor proxies ignore the
credentials, which is harmless. Must not derive the credential from
anything secret.

**Done when.** `kn-sync/tests/proxy.rs` asserts distinct credentials per
wallet and purpose against a fake SOCKS server; the privacy policy
explains what it changes.

### 2. Broadcast through a different node (S)

**What.** Send the signed transaction through a node other than the one
the wallet syncs from, chosen at random from the bundled list, over the
proxy. Off when no proxy is set (it would show a second node your IP for
no gain), on by default with a proxy.

**Why.** The sync node sees your IP and which blocks you fetch; if it
also receives your broadcast, it can tie that transaction to that IP and
sync pattern. Splitting the two is one line in the threat model and
closes the easiest linking a node operator can do. Feather lets you
choose how to broadcast on desktop; on mobile nothing does.

**Builds on.** `kn-tx` publishes through `Backend::Full` with an `Http`
from `node.rs`; `bundled_nodes(network)` already exists; `opinion.rs`
already picks a second node for the chain check and can share the
selection logic. In LWS mode the server broadcasts today; this adds the
option to broadcast through a node instead, which also removes the "server
does not broadcast" case from the threat model.

**Risks.** The second node may be behind or down; fall back to the sync
node with a visible notice. In LWS mode, broadcasting elsewhere means the
server learns of the spend only when it scans it, which is fine.

**Done when.** Regtest with two daemons: the transaction is seen first
in the pool of the broadcast node, never submitted to the sync node;
`THREAT_MODEL.md` updated.

### 3. Cover lookups (S)

**What.** Every time the app asks a node for specific transactions (the
LWS cross-check, payment proof checks, and the planned receipts below),
pad the request with a handful of random recent transaction hashes
fetched from the same node's recent blocks. The node sees a batch and
cannot tell which hash the wallet cared about.

**Why.** The 0.2.0 cross-check is off by default precisely because the
node learns which transactions you look up. With cover, it can be on by
default, which is where the "no trust in the server's reports" claim
actually becomes true for everyone, not only for people who read
settings.

**Builds on.** `kn-sync/src/crosscheck.rs` and `proof.rs` make the
`get_transactions` call; the cover set comes from block headers the
scanner already fetches in full mode, or from one `get_blocks.bin` call
in LWS mode.

**Risks.** A node could still correlate by timing if the cover hashes are
too old or too few; pick from the same height range as the real one and
use the same batch size every time. Costs a little bandwidth.

**Done when.** A test in `kn-sync/tests` records what a fake node
receives and asserts the real hash is indistinguishable in position and
age; the cross-check default flips to on in the same change with a
privacy policy update.

### 4. Notifications from your own server (M)

**What.** The self-hosting kit gains a push path: monero-lws fires a
webhook when a payment reaches a registered address, a small relay in the
kit (ntfy or any UnifiedPush server, bound to the onion address) turns it
into a push, and the app subscribes through a UnifiedPush distributor
over Tor. The push carries only "something arrived for wallet token X";
the app then syncs and shows the real amount. Pairing by the same QR as
0.2.0.

**Why.** Android background sync costs battery and keeps wallets
unlocked; Google's push would tell Google. This is the only way to get
instant, private payment notifications on a phone without either, and it
is only possible because Kilonova already ships a self-hosting kit with
a light wallet server in it. No other wallet can offer it without
running a server for its users.

**Builds on.** `tools/selfhost/compose.yaml` and its Tor config; monero-lws
webhook support (verified in its README, including 0-conf); the pairing
format in `node.rs::ServerPairing` gains a push endpoint; the Android
notification code from M5. Payment requests from 0.2.0 become the natural
thing to register webhooks for.

**Risks.** UnifiedPush distributor availability on the user's phone
(ntfy's own app is one); the webhook token must not be derivable from
the view key; the relay sees timing of payments, which the kit already
does since it runs the server. Desktop gets the same through the tray
item above.

**Done when.** Devnet compose with the relay: a regtest payment produces
a push within one block, and the push payload contains no amount,
address or transaction id. Privacy policy section for the push path.

### 5. Contacts that know who paid you (M)

**What.** Give any address-book contact a receive address of their own
(a fresh subaddress, or one from a dedicated account once accounts
exist). Share it from the contact's card. Incoming payments on that
address show the contact's name in history, and the contact's card shows
what they have paid over time.

**Why.** Monero's history shows amounts and dates and nothing about who
sent them; people keep that in notes or not at all. Subaddress labels
exist in every wallet but no mobile wallet connects them to contacts
and to the history. Freelancers and small shops get a customer ledger
without a payment processor, which is also where payment requests from
0.2.0 lead.

**Builds on.** `kn-store::Contact` and `AddressLabel`,
`SyncState::received_by(account, index)`, `HistoryEntry` which already
records the receiving index, the address book screen and
`receive_screen.dart`.

**Risks.** A contact who shares their address with someone else makes the
attribution wrong; say "arrived on the address you gave Ana", not "from
Ana". Combining coins received from several contacts in one send links
them; the coin-control warning already covers that and should name the
contacts.

**Done when.** Regtest: pay a contact's address from monero-wallet-rpc,
history shows the contact, the coin-control warning names two contacts
when their coins are spent together.

### 6. Receipts: send a payment proof as easily as a payment (S)

**What.** After a send, one tap produces a receipt: transaction id,
transaction key, recipient address and amount, as text, a QR and a
`monero:`-style proof link, so the recipient can check it in Kilonova's
0.2.0 "Check a payment" screen or in any wallet that verifies proofs.
Also the reverse for the address book: sign a short message with the
wallet's spend key to prove an address is yours, and verify one someone
sends you.

**Why.** Disputes over "I paid you" are the most common support question
for Monero merchants, and proofs exist for exactly that but take six
copy-pastes to assemble. Feather and the CLI can generate and verify;
mobile wallets mostly cannot. Message signing is in the CLI and nowhere on
mobile.

**Builds on.** `kn-sync/src/proof.rs` and `kn-ffi/src/api/proof.rs`
already check proofs; `kn-tx` already stores the transaction key
(`SentRecord`); `check_payment_screen.dart` is the verifier side. Signing
needs a small addition to `kn-keys` matching the reference wallet's
message format so proofs verify across wallets.

**Risks.** The proof link format is not standardised; use the parameters
the official `monero:` URI already has (`tx_amount`, `recipient_name`)
plus a documented `tx_key` and accept that other wallets will paste the
fields by hand. Sharing a receipt reveals the amount and the recipient
to whoever sees it; say so on the screen.

**Done when.** Test vectors: a receipt generated by Kilonova verifies in
monero-wallet-cli (`check_tx_key`) and a message signed by the CLI
verifies in Kilonova, for all three networks, in `tools/vectors`.

### 7. Audit view with Carrot (L, after Must do 4)

**What.** Once Carrot wallets exist, let the user export a view-balance
key: a key that shows incoming and outgoing payments without the ability
to spend. Hand it to an accountant, a co-founder, or your own desktop
watching wallet, and they see the full ledger, not only incoming.

**Why.** Today's view key shows receipts, and spends only by inference;
"view-only" wallets in every Monero wallet share that limit. Carrot's
outgoing view keys fix it at the protocol level, and the first wallet to
expose it plainly, with the same consent screen the LWS flow has, gets a
feature nobody else has yet.

**Builds on.** The Carrot key hierarchy from Must do 4 in `kn-keys`;
view-only wallet creation in `restore_wallet_screen.dart`; the consent
dialog pattern in `lws_consent_dialog.dart`.

**Risks.** Entirely gated on the fork and on monero-oxide; do not start
before Must do 4 stage (b) is merged. The same key given to a light
wallet server reveals outgoing payments to it too; the consent text must
say so.

**Done when.** A Carrot wallet on the stressnet devnet exports its
view-balance key; a wallet restored from it on another device shows the
same history including spends, with no spend key present
(`kn-store::WalletSecret` has a variant for it and the send screen is
absent).

## Not doing, on purpose

- **Built-in Tor.** Unchanged from the last plan: Orbot and the Tor
  daemon exist and are better maintained. Circuit isolation above works
  with them.
- **Atomic swaps, Haveno, fiat on-ramps, exchanges.** Outside the
  wallet's job and the privacy policy; every one of them adds a third
  party the policy would have to explain. Cake and Feather already serve
  users who want a swap inside the wallet.
- **Multisig.** Still table stakes rather than an edge, and the FCMP++
  stressnet notes say multisig does not work there yet. Anything built
  now would be rebuilt after the fork.
- **Hardware wallets.** Ledger and Trezor sign only the current protocol
  and have no FCMP++ support (jeffro256's CCS work covers reaching out to
  them). Adding them before the fork means supporting two signing paths
  through a transition. Revisit when a vendor ships FCMP++ firmware. The
  offline phone covers the use case meanwhile.
- **Bluetooth or USB between the cold and watching wallets.** Monerujo's
  Sidekick does Bluetooth. A radio in the cold phone is a channel the
  threat model would have to defend; QR codes and files stay the only
  transports.
- **Mining or P2Pool integration.** Gupax and P2Pool do it; a wallet
  bundling a miner is a different product with a different attack
  surface.
- **Seraphis and Jamtis.** Not on Monero's path any more (FCMP++ with
  Carrot replaced them). Nothing to do.
- **A hosted light wallet server or push relay by Dhiva Labs.** The
  privacy policy's strongest sentence is that Kilonova runs nothing. The
  self-hosting kit is the answer to MyMonero's closure, not a replacement
  for it.
- **macOS and iOS.** Flutter would allow it; signing, notarisation and
  App Store review are a standing cost with no one to carry it yet.
- **Street mode and decoy wallets.** Monerujo has it; a hidden-balance
  toggle is fine to add as a small change but is not a roadmap item.

## Suggested order

1. **M7, "Ready for real money":** backup and restore (Must do 1),
   reproducible builds and the audit scope document (2), F-Droid,
   Flatpak and Windows signing (3), plus one Tor circuit per wallet
   (Differentiator 1) because it is a day's work in `node.rs`. Ends with
   the external review commissioned and 0.3.0 released.
2. **M8, "The network path":** broadcast through a different node,
   cover lookups with the cross-check on by default, notifications from
   your own server, and the desktop tray (Differentiators 2 to 4, Must do
   8). Every item is a sentence removed from the "what remains possible"
   paragraphs of the threat model. Ends with 0.4.0.
3. **M9, "Fork and ledger":** the FCMP++ and Carrot stages (Must do 4)
   in the order given there, multiple accounts (5), contacts that know
   who paid you and receipts (Differentiators 5 and 6), with accessibility
   and translations (6, 7) running in parallel as community work. The
   audit view (Differentiator 7) follows when the fork date is known.
   1.0 is whichever release carries the audit result and FCMP++ support.
