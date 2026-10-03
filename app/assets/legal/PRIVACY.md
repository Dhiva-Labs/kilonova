# Kilonova privacy policy

Last updated: (set on first release)

Kilonova is a Monero wallet made by Dhiva Labs. This page explains, in plain
terms, what the app does with your information.

## The short version

- Dhiva Labs does not collect anything from you. There are no accounts, no
  analytics, no tracking and no crash reports sent to us.
- Your seed and private spend key never leave your device.
- The app does have to talk to the Monero network. Who it talks to, and what
  they can learn, depends on the settings you choose. Those choices are
  described below.

## What stays on your device

- Your seed phrase and private keys, stored in an encrypted wallet file that
  only your password opens.
- Your transaction history, balances, address labels, address book and notes.
- Your settings, including which nodes and servers you use.

We cannot see any of this, recover it, or reset your password. If you lose
your seed and your password, nobody can restore your wallet.

### Backups you make

Settings, Backup saves the wallets you choose to one file, in a place you
pick. The file holds each wallet's file and sync progress exactly as they
are stored (still locked with that wallet's password, so the seed and keys
inside stay encrypted with it), the wallet's name, network and sync mode,
and the node, light wallet server and pinned certificates it used. Labels,
the address book, notes and payment requests are inside the wallet file and
come along with it. The whole file is encrypted again with a backup
passphrase you choose (Argon2id and XChaCha20-Poly1305), separate from your
wallet passwords. Without that passphrase nobody can read the file, not
even which wallets are in it, and nobody can recover the passphrase for
you. The app never sends a backup anywhere; Android's own cloud backup stays
off for app data, so where the file goes is up to you.

## Who the app connects to

### Monero node (Full mode)

In Full mode the app downloads blocks from a Monero node and checks them on
your device. Out of the box it uses a public node from a list of community
nodes bundled with the app. Those nodes are run by third parties, not by
Dhiva Labs. You can add your own node in Settings and make it the default.
The node can see:

- your IP address, unless you use Tor or a proxy;
- when you sync and how much you download;
- transactions you send, when you broadcast them, unless a proxy is set
  (see "Sending through a different node" below).

The node does **not** receive your keys and cannot tell which incoming
transactions are yours. Running your own node gives you the most privacy.

Once each time a wallet starts syncing, the app also asks one of the bundled
public nodes for the hash of a recent block, to check your node is on the
same chain as everyone else. That node sees your IP address (or your
proxy's) and that a Monero wallet checked a block; nothing about any wallet.

If you check a payment proof (a transaction id, its key and an address
someone gave you), the node is asked for that transaction, hidden among
cover lookups (see below).

### Light wallet server (LWS mode)

In LWS mode a monero-lws server scans the blockchain for you. To do that it
needs your **private view key**. With it, the server can see:

- every payment you receive and its amount;
- your IP address, unless you use Tor or a proxy.

It can also see outgoing payments when it notices your coins being spent.
When you send in LWS mode, the server also chooses the decoys for your
transaction and suggests its fee. Without a proxy it also broadcasts it, so
it sees the transaction before anyone else; with a proxy, the transaction
goes out through a different node instead (see below). It
**cannot** spend your funds, because your spend key stays on your device. Only
use a server you run yourself or one you trust, such as MyMonero. Kilonova
does not run a light wallet server and never picks one for you.

Before a wallet's view key is sent anywhere, the app shows you which server
will receive it and asks you to agree. Your answer is remembered for that
wallet and that server only: choosing a different server asks again.

With **Confirm the server's payments with a node** (on by default; you can
turn it off on the light wallet server screen), the app also asks your
network's node for each transaction the server reports, to make sure it
exists as reported.

Whenever the app asks a node for a specific transaction (these checks and
payment proofs), it uses cover lookups: every request names 8 transactions,
yours at a random place among 7 others picked from blocks near yours (or
from the latest blocks, for a payment proof). Every request has the same
size, and the answers for the other 7 are thrown away unread. The node
sees your IP address (or your proxy's) and a batch of ordinary recent
transactions, and cannot tell which one you cared about. It can still see
when you look things up, so Tor or your own node remain the best choice.

### Sending through a different node

When a proxy is set, the app sends each transaction you make (cold-wallet
transactions included) through a node picked at random from the bundled
public nodes, never the node your wallet syncs from (in LWS mode, never
your network's node or your server). That node sees your proxy's address
(a separate Tor circuit for each wallet's payments) and the transaction,
but not your syncing. The node your wallet syncs from learns of the
transaction only the way every node does, from the network. If the other
node does not take the transaction within 45 seconds, the app sends it the
usual way and tells you so. You can turn this off in Settings, Proxy and
Tor. Without a proxy it is off, because it would only show your IP
address to one more node.

### Your own server (optional)

The self-hosting kit in `tools/selfhost` runs a node and a light wallet
server on your own machine as a Tor onion service. Its pairing code holds the
onion address; anyone who has it can use your server, so show it only to your
own devices.

### Payment pushes from your server (optional, off by default)

The kit can also tell you when a payment reaches a wallet. You turn this on
per wallet: `push-register` on your server makes a random topic (not
derived from any key) and tells your light wallet server to call the kit's
relay when a payment to that wallet arrives. The relay throws away what the
light wallet server sends (amount, transaction id) and passes on only the
topic. The push says "something arrived", nothing more; the app then syncs
to show the amount.

- **On Android**, pushes come through a UnifiedPush app you choose, such as
  ntfy, set to use your own server's onion address. Kilonova gives your
  server's relay the address that app was given, so the relay can pass
  pushes on to it; it refuses any address that is not on your own server,
  so no other push service is involved. Kilonova does not use Google's push
  service. The UnifiedPush app learns the topic and when pushes arrive.
- **On Linux and Windows**, Kilonova asks your server for new pushes about
  once a minute while it runs, through your proxy.

Your server learns when you are online (as it does when you sync) and when
the wallet receives payments (which it already sees). Anyone who learns the
topic, from the code or your device, learns when that wallet receives
payments, not how much. The topic is kept in the app's private folder.

### Offline (cold) wallets

A wallet marked offline never connects to anything. It signs for a
view-only "watching" wallet on another device through QR codes or files.
The pairing code it shows carries the private view key, which is why it asks
for the password and should only be shown to your own watching wallet. The
codes it answers with carry key images (so the watching wallet can see your
spends) and signed transactions; they hold no spend key.

### Looking for nodes on your network (optional)

If you tap "Find nodes on this network", the app tries the usual Monero
ports on your own computer and on the other addresses of your local network.
Nothing leaves your local network, and it is never done while a proxy is
set.

### Price data (optional, off by default)

If you turn on prices (Settings, Prices), the app asks CoinGecko
(api.coingecko.com) for the XMR price in the currency you chose, about every
ten minutes, through your proxy if one is set. CoinGecko sees your IP address
(or your proxy's) and the currency. The request carries nothing about any
wallet, and test-network balances are never priced.

### Nothing else

The app does not contact Dhiva Labs servers, ad networks, analytics services
or font/CDN providers. Fonts and icons are bundled with the app.

## Reducing what others can learn

- Run your own Monero node, or your own monero-lws server.
- Turn on Settings, Proxy and Tor. Every connection then goes through Tor (or
  your SOCKS5 proxy), host names are looked up through it, and onion nodes
  can be used. Each wallet, and each kind of request of a wallet (sync,
  sending, checks against a second node, payment proofs, prices, testing
  nodes), uses its own SOCKS username and password. Tor puts connections
  with different credentials on different circuits, so a node cannot tell
  from the exit address that two of your wallets, or one wallet's sync and
  its payment, come from the same phone. The credentials are a hash of the
  wallet's internal id and the kind of request, nothing secret; a proxy
  that is not Tor and does not ask for a password is sent none.
- With a proxy set, leave "Send through a different node" on.
- Leave fiat prices off.

## Permissions

- **Camera (Android):** only to scan QR codes, only while the scanner is open.
  Frames are read on the device and never saved or sent. On desktop you pick an
  image file instead, which is read the same way.
- **Fingerprint or face (Android):** only if you turn on biometric unlock.

Kilonova does not ask for the microphone, contacts, location or shared storage.
- **Notifications:** to tell you about incoming payments, if you turn that on
  (Settings, Notifications and background). Off by default. A locked phone
  shows only that a payment arrived, not the amount or wallet.
- **Background sync (Android):** off by default. If you turn it on, unlocked
  wallets stay unlocked when you leave the app so they keep syncing, behind an
  ongoing notification. Anyone who opens Kilonova on your phone during that
  time can use those wallets.
- **Syncing with the window closed (Linux, Windows):** off by default. If you
  turn it on, closing the window hides Kilonova in the system tray and
  unlocked wallets stay unlocked and keep syncing until you quit from the
  tray. Anyone using your computer meanwhile can open them from the tray.
- **Network:** to reach the node, server or price service you configured.

## Downloads and app stores

If you install Kilonova from an app store or GitHub, that store or site may
collect data under its own policy. Dhiva Labs receives no personal data from
those downloads.

## Children

Kilonova is not directed at children and collects no data from anyone.

## Changes to this policy

Changes are made in public, through pull requests on
github.com/Dhiva-Labs/kilonova, and listed in the changelog below.

## Contact

Questions: reachout@dhivalabs.com.
Security issues: see SECURITY.md in the repository.

## Changelog

Newest first.

- 2026-10-03: with a proxy, transactions are sent through a different node than the one you sync from.
- 2026-10-03: cover lookups; confirming a light wallet server's payments is now on by default.
- 2026-10-03: payment pushes from your own server, and syncing with the window closed on desktops; both off by default.
- 2026-10-03: backups you make; each wallet and kind of request gets its own Tor circuit.
- 2026-10-03: offline wallets, the node check against a public node, confirming server payments, payment proofs, self-hosting and finding nodes on your network.
- 2026-10-02: payment notifications and background sync, both off by default.
- 2026-10-02: name the price service and say how often it is asked.
- 2026-10-02: QR scanning: what the camera is used for, and permissions the app never asks for.
- 2026-10-02: describe what a light wallet server sees when you send.
- 2026-10-02: describe the consent step before a view key is shared with a light wallet server.
- 2026-10-02: first version.
