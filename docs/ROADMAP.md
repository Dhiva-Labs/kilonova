# After 0.1.0: what only Kilonova will do

Most Monero wallets compete on the same list: send, receive, a node picker,
maybe Tor. Kilonova's edge comes from what it already has that others do
not: two sync modes per wallet with a light wallet server that is **checked,
not trusted**, a Rust core that can serialize unsigned transactions, pinned
certificates, Tor for everything, and background sync with notifications.
The features below build on that. Each one is something no mainstream
wallet (official GUI/CLI, Feather, Cake, Monerujo, Stack, MyMonero) offers
today, or offers only on desktop, and each is feasible with the code in
this repository.

Ordered by value for effort. Sizes: S (days), M (one to two weeks),
L (several weeks).

All eight shipped in 0.2.0. The next plan is in [ROADMAP-NEXT.md](ROADMAP-NEXT.md).

## 1. Phone as the cold wallet (L)

Two Kilonova installs, one seed: the phone holds the spend key and never
goes online for this wallet; the desktop (or the same phone's other wallet)
is view-only and does the syncing. Sending is three QR scans:

1. The watching wallet builds the transaction and shows it as a QR
   (monero-oxide's `SignableTransaction` already serializes).
2. The cold wallet scans it, shows the review screen, asks for the
   password, signs, and shows the signed transaction as a QR.
3. The watching wallet scans that and publishes it.

Key images travel the same way once, so the watching wallet knows what is
spent. Feather and the official wallet do cold signing with files on
desktop only; no wallet does it phone to desktop with QR codes. It turns an
old Android phone into a hardware wallet with a screen, for free.

Needs: an animated multi-part QR format for payloads over a few KB (the
`ur` style used by Bitcoin wallets is fine to adopt), `export_outputs` /
`import_key_images` in `kn-tx`, a "cold" flag on wallets that disables
every network call, and the scanner the app already has.

## 2. Pair with your own server by QR (M)

A `tools/selfhost` Docker Compose that runs monerod plus monero-lws behind
a Tor onion service with a self-signed certificate, and prints a pairing QR
containing the onion address, the certificate fingerprint and the network.
The app scans it and sets the server, pins the certificate and turns on the
Tor proxy in one step. The light wallet server then runs on hardware the
user owns, reachable from anywhere, with nothing to configure in a router.

Everything the QR carries already has a setting in the app; the work is
the compose file, the QR format, the pairing screen, and a guide. No other
wallet ships a self-hosting kit that pairs with one scan.

## 3. Light wallet server cross-check (M)

Today the server can invent an incoming payment that fails when spent.
Close that hole: when the server reports a new payment, fetch that
transaction from a public node (through Tor) and verify the output against
it. The node learns one transaction hash, never which address is the
user's, and the server can no longer lie about what arrived. Show the
result on the transaction: "Confirmed by node.example". This makes
Kilonova's LWS mode the only one with no trust in the server's reports at
all, and the threat model gets simpler to explain.

## 4. Payment requests that watch for their payment (M)

A merchant-style feature inside a personal wallet: "Request 0.25 XMR from
Ana" creates a fresh subaddress, a `monero:` link and a QR with the amount,
and a card under a REQUESTS eyebrow. When a payment of that amount reaches
that subaddress the card flips to paid, with a notification. Optional
expiry and note. Freelancers and small shops get invoicing without a
payment processor; no mobile wallet has it.

Needs: a request list in the wallet file, matching in the sync code (one
subaddress per request makes it exact), and a screen.

## 5. Coin control and a privacy check on mobile (M)

Show the wallet's outputs ("coins") with amount, age, lock state, and the
address they arrived on; let the user freeze one or pick which to spend.
Before sending, a short privacy check names what could link the payment:
spending coins received on several subaddresses together, sending change
to a frozen coin, or paying an amount equal to a known request. Feather has
coin control on desktop; on Android nothing does, and no wallet explains
the linking risk at send time in plain words.

Needs: `spendable()` already returns outputs; add a frozen set and a
selection to `prepare`, a coins screen, and the checks in the review step.

## 6. Second opinion on the node (S)

A lying node can feed a wallet a fake chain. Once per sync, compare the
chosen node's tip hash with one bundled node over Tor; if they differ for
more than a few blocks, show "Your node disagrees with the network" with
the heights. Cheap, and no wallet does it.

## 7. Find my node on the LAN (S)

Nodes on the local network announce themselves (monerod answers on its
RPC port; mDNS where available). The node picker lists "Found on your
network: 192.168.1.20:18081" with its height. Removes the one step that
stops most people from using their own node.

## 8. Verify a payment proof (S)

The app generates transaction keys; let it also check one. Paste a
transaction hash, key and address, and the app asks the node and reports
what that address received. Feather has this on desktop; mobile wallets
do not.

## Not on this list, on purpose

- Built-in Tor: Orbot and the Tor service exist and are better maintained.
- Fiat on-ramps, swaps, staking: outside the wallet's job and the privacy
  policy.
- Multisig and hardware wallets: on the long-term plan, but every wallet
  that has them has them; they are table stakes, not an edge.
