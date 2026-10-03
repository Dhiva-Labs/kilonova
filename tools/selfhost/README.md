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
