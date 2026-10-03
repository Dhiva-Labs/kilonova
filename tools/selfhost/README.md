# Self-hosting a node and light wallet server

Runs your own Monero node (pruned) and monero-lws on any machine with
Docker, reachable from anywhere as a Tor onion service. Nothing is opened on
your router, and no one but you learns the address.

```sh
cd tools/selfhost
docker compose up -d
```

The node first syncs the whole blockchain: expect a day or more and about
100 GB of disk. Then print the pairing code:

```sh
docker compose run --rm pair
```

In Kilonova, open Settings, Pair with your server, and scan the QR code (or
paste the `kilonova-server:` line). Kilonova sets the node and the light
wallet server for that network. Onion addresses need Tor on the phone or
computer: Orbot on Android, the Tor service on Linux and Windows; Kilonova
asks for it if no proxy is set.

The pairing code lets anyone who has it use your server, and send it a
wallet's view key. Show it only to your own devices. To revoke it, remove
the `tor-data` volume and pair again: Tor creates a new address.

For stagenet, change `--network=main` to `--network=stage` and add
`--stagenet` to monerod, and set `KN_NETWORK: stagenet` for the `pair`
service.

## Payment notifications

The kit also runs ntfy and a small relay, so your phone or computer can be
told the moment a payment reaches one of your wallets, without Google,
Apple or anyone else in between and without keeping the wallet unlocked.

1. Open the wallet in Kilonova in LWS mode with this server, so the light
   wallet server knows it.
2. On the server, register the wallet's primary address:

   ```sh
   ./push-register 4...yourAddress
   ```

   It prints a `kilonova-push:` code and its QR code.
3. In Kilonova, open Settings, Background, Payment notifications from your
   server, choose the wallet and scan the code.

On Android, Kilonova receives pushes through a UnifiedPush distributor.
Install the ntfy app (F-Droid or Play), and in its settings set the default
server to the `http://...onion` address from the code (the `server` part);
with Orbot running in VPN mode the ntfy app reaches it over Tor. Kilonova
then asks which distributor to use. On Linux and Windows, Kilonova checks
the server itself through your Tor proxy while it runs, also from the
system tray (Settings, Background, Keep syncing when the window is closed).

What travels: when a payment to the wallet enters the pool, and again when
it is first confirmed, monero-lws calls the relay's webhook with the amount
and transaction id. The relay drops all of it and posts only the wallet's
topic (a random string, not derived from any key) to ntfy. The phone shows
"Something arrived" and the wallet syncs to show the real amount. Anyone
who learns the topic, or the code, learns when that wallet receives
payments, nothing more; your server already knows that much.

To stop pushes for a wallet, `./push-register --remove <address>`, and turn
it off in Kilonova. Running `./push-register` again makes a new topic.

The relay and ntfy are reachable only through the onion address. ntfy
keeps messages for 12 hours and forwards nothing to ntfy.sh.
`./test-push.sh` checks the whole path on a private regtest chain.
