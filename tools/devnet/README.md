# Devnet

Local Monero stagenet and testnet nodes with a monero-lws server for each, so
Full mode and LWS mode can be developed without touching mainnet.

| Service | Image | Host port |
|---|---|---|
| `monerod-stagenet` | simple-monerod v0.18.5.1 | `127.0.0.1:38081` (RPC) |
| `lws-stagenet` | monero-lws 0.3 | `127.0.0.1:38443` (REST), `38444` (admin) |
| `monerod-testnet` | simple-monerod v0.18.5.1 | `127.0.0.1:28081` (RPC) |
| `lws-testnet` | monero-lws 0.3 | `127.0.0.1:28443` (REST), `28444` (admin) |

Images are pinned by tag and digest. Nothing is exposed beyond localhost.

## Start

```sh
cd tools/devnet
KN_UID=$(id -u) KN_GID=$(id -g) docker compose --profile stagenet up -d
```

Use `--profile testnet` for testnet, or pass both profiles. Chain data goes to
`tools/devnet/data/`, which git ignores.

## First sync takes a while

monerod has to sync the network before anything is useful. A pruned stagenet
node is a few GB and takes from tens of minutes to a few hours depending on
your connection and disk.

Until monerod passes monero-lws's built-in checkpoints, the LWS container
logs `Unable to sync blockchain` and restarts. That is expected. Check
progress with:

```sh
curl -s http://127.0.0.1:38081/json_rpc \
  -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' | grep -E '"(height|target_height)"'
```

## Dev-only settings

The LWS servers run with `--auto-accept-creation` and `--disable-admin-auth`
so tests can create accounts without an approval step. Never use these flags
on a server other people can reach.

## Known issues

- Some monero-lws builds require AVX-512 and exit with `SIGILL` on older
  CPUs (upstream issue vtnerd/monero-lws#292). If that happens, build the
  image from source with the upstream Dockerfile.

## Stop

```sh
docker compose --profile stagenet down
```

Add `-v` and delete `data/` to start from scratch.
