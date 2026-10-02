#!/usr/bin/env python3
"""Generates key and address test vectors from Monero's reference wallet.

Kilonova's key code must agree with monero-wallet-rpc, so its tests check
against vectors produced here rather than against values Kilonova computed
itself. For each network this script:

1. creates a fresh deterministic wallet and records its 25-word seed, keys,
   primary address and several subaddresses;
2. takes the Polyseed key vector from the polyseed crate, reduces it to a
   spend key the way wallet2 does, encodes that as a 25-word seed with the
   official English word list, restores it, and records what
   monero-wallet-rpc derives.

monero-wallet-rpc runs offline in Docker. Run from the repo root:

    python3 tools/vectors/gen_key_vectors.py > core/kn-keys/tests/vectors.json

The output is committed; rerunning produces fresh (equally valid) wallets.
"""
import json
import subprocess
import sys
import time
import zlib
import urllib.request

IMAGE = (
    "ghcr.io/sethforprivacy/simple-monero-wallet-rpc:v0.18.5.1"
    "@sha256:09ff81f470d6d37811e3fde808c5cd1158a8cd2c42abbfb935b33f26f91e879d"
)
NETWORKS = {"mainnet": None, "stagenet": "--stagenet", "testnet": "--testnet"}
PORT = 28183

# Polyseed key vector from monero-wallet-util's polyseed tests (commit 797fe70).
POLYSEED_WORDS = (
    "comic blanket chair inject end snow rural improve cereal better initial "
    "replace ribbon brother gather unaware"
)
POLYSEED_KEY = bytes([
    216, 82, 37, 164, 252, 122, 170, 61, 52, 152, 131, 26, 181, 226, 191, 131,
    204, 3, 242, 225, 229, 175, 37, 151, 18, 143, 53, 175, 136, 17, 47, 126,
])

# Subaddresses to record, as (account, index).
SUBADDRESSES = [(0, 1), (0, 2), (1, 0), (1, 1), (2, 5)]

WORDLIST_URL = (
    "https://raw.githubusercontent.com/monero-project/monero/v0.18.4.3/"
    "src/mnemonics/english.h"
)

ED25519_L = 2**252 + 27742317777372353535851937790883648493

def sc_reduce32(b: bytes) -> bytes:
    return (int.from_bytes(b, "little") % ED25519_L).to_bytes(32, "little")


def rpc(method: str, params: dict | None = None) -> dict:
    body = json.dumps({"jsonrpc": "2.0", "id": "0", "method": method, "params": params or {}})
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/json_rpc", body.encode(), {"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        reply = json.load(resp)
    if "error" in reply:
        raise RuntimeError(f"{method}: {reply['error']}")
    return reply["result"]


def wait_for_rpc() -> None:
    for _ in range(60):
        try:
            rpc("get_version")
            return
        except OSError:
            time.sleep(1)
    raise RuntimeError("monero-wallet-rpc did not start")


def record_wallet() -> dict:
    keys = {k: rpc("query_key", {"key_type": k})["key"] for k in ("spend_key", "view_key")}
    for account in range(1, max(a for a, _ in SUBADDRESSES) + 1):
        rpc("create_account")
    max_index = {}
    for account, index in SUBADDRESSES:
        max_index[account] = max(max_index.get(account, 0), index)
    for account, top in max_index.items():
        have = len(rpc("get_address", {"account_index": account})["addresses"])
        for _ in range(have, top + 1):
            rpc("create_address", {"account_index": account})
    subs = []
    for account, index in SUBADDRESSES:
        addr = rpc("get_address", {"account_index": account, "address_index": [index]})
        subs.append({"account": account, "index": index, "address": addr["addresses"][0]["address"]})
    return {
        "spend_key": keys["spend_key"],
        "view_key": keys["view_key"],
        "address": rpc("get_address", {"account_index": 0})["address"],
        "subaddresses": subs,
    }


def vectors_for(network: str, flag: str | None) -> dict:
    name = f"kn-vectors-{network}"
    cmd = [
        "docker", "run", "--rm", "-d", "--name", name, "-p", f"127.0.0.1:{PORT}:{PORT}",
        # The image binds 0.0.0.0 itself when asked to; the host side of the
        # port is still loopback only, and the wallets are throwaway.
        "-e", "RPC_EXPOSE_UNAUTHENTICATED=1",
        IMAGE, "--offline", "--disable-rpc-login", "--wallet-dir=/home/monero/wallet",
        f"--rpc-bind-port={PORT}",
    ]
    if flag:
        cmd.append(flag)
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    try:
        wait_for_rpc()
        rpc("create_wallet", {"filename": "classic", "password": "", "language": "English"})
        classic = record_wallet()
        classic["mnemonic"] = rpc("query_key", {"key_type": "mnemonic"})["key"]
        rpc("close_wallet")

        spend = sc_reduce32(POLYSEED_KEY)
        rpc("restore_deterministic_wallet", {
            "filename": "polyseed", "password": "", "seed": mnemonic(spend),
            "restore_height": 0, "language": "English",
        })
        polyseed = record_wallet()
        polyseed["words"] = POLYSEED_WORDS
        rpc("close_wallet")
        return {"network": network, "classic": classic, "polyseed": polyseed}
    finally:
        subprocess.run(["docker", "stop", name], check=False, stdout=subprocess.DEVNULL)


def english_words() -> list[str]:
    with urllib.request.urlopen(WORDLIST_URL, timeout=60) as resp:
        source = resp.read().decode()
    words = [line.strip().rstrip(",").strip('"') for line in source.splitlines()
             if line.strip().startswith('"')]
    if len(words) != 1626:
        raise RuntimeError(f"expected 1626 words, got {len(words)}")
    return words


def mnemonic(spend: bytes) -> str:
    """Encodes a spend key as Monero's 25-word seed (English)."""
    words = english_words()
    n = len(words)
    out = []
    for i in range(0, 32, 4):
        x = int.from_bytes(spend[i:i + 4], "little")
        w1 = x % n
        w2 = (x // n + w1) % n
        w3 = (x // n // n + w2) % n
        out += [words[w1], words[w2], words[w3]]
    prefixes = "".join(w[:3] for w in out)
    out.append(out[zlib.crc32(prefixes.encode()) % 24])
    return " ".join(out)


def main() -> None:
    out = {
        "generator": "tools/vectors/gen_key_vectors.py",
        "reference": "monero-wallet-rpc v0.18.5.1",
        "networks": [vectors_for(n, f) for n, f in NETWORKS.items()],
    }
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
