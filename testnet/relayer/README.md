# Hyperbridge relayer

Tesseract plus a dedicated Orbinum node, so the two chains can verify each other's
finality proofs.

## Why a dedicated node

The relayer holds a long-lived WebSocket and calls RPC methods outside Substrate's Safe
set. Neither works against `rpc-1`:

|                       | rpc-1                        | this node               |
| --------------------- | ---------------------------- | ----------------------- |
| Fronted by Cloudflare | yes — closes idle WebSockets | no                      |
| RPC methods           | `Safe`                       | `Unsafe`, loopback only |
| Serves                | the public                   | one consumer            |

Running Tesseract against `wss://rpc-1.testnet.orbinum.io` dropped its connection every
few minutes and stalled the proof cycle. Same reasoning as `indexer-rpc` — a consumer
that needs something the public endpoint should not offer gets its own node.

`--rpc-methods Unsafe` is only acceptable because the RPC is bound to loopback: no
`--rpc-external`, no `ports:`, no reverse proxy. Nothing outside the box can reach it.

## Pruning

Not a full archive node, unlike `indexer-rpc`:

```
--state-pruning 1000        # the relayer never reads historical state
--blocks-pruning archive    # justifications must survive
```

`prove_finality` reads block justifications and headers, never the historical state
trie — and the state trie is the part that grows without bound. Pruning it is what keeps
this box small.

Bodies stay because pruning them takes the justifications with them, and this node has no
`GrandpaPruningFilter` to hold them back. Bodies are far smaller than state, so the
trade is worth it.

One consequence: if the relayer is down long enough, it asks for headers from a range
that no longer exists, and the proof cycle cannot resume from where it left off. The cap
upstream is `MAX_UNKNOWN_HEADERS = 100_000` — roughly a week at 6s blocks. Longer than
that, wipe the volume and let the node resync.

## Deploy

```bash
cp .env.example .env
$EDITOR .env                       # RPC_NODE_KEY

cp relayer.toml.example relayer.toml
$EDITOR relayer.toml               # both signer lines

docker compose up -d
```

`relayer.toml` is gitignored — it carries the signer secrets in the clear, because
Tesseract does not expand environment variables in its config.

Tesseract restarts on its own until the node has synced enough to answer. That is
expected on a fresh box; the node has to catch up first.

## Generating the signers

Two sr25519 keys, one per chain:

```bash
docker run --rm parity/subkey:latest generate --scheme sr25519
```

Take the **secret seed** (hex), not the mnemonic or the address.

Neither key needs a balance to relay: consensus proofs go through `Ismp::handle_unsigned`
— no signature, no nonce, no fee. The signer is what the accrued `$BRIDGE` rewards are
attributed to. Fund it only if you later claim those, since withdrawal delivery is a
signed extrinsic.

## Checking it works

The number must climb:

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"ismp_queryStateMachineLatestHeight",
       "params":[{"state_id":"SUBSTRATE-orbi","consensus_state_id":"ORBI"}]}' \
  https://gargantua.rpc.polytope.technology
```

That is Hyperbridge's view of Orbinum, and it only advances when it accepts one of our
GRANDPA proofs. In the logs:

```bash
docker logs -f orbinum-tesseract 2>&1 | grep "Transmitting consensus proof"
```

The reverse — Hyperbridge's height on our chain — needs a **BEEFY prover** running
against Gargantua, which is a separate operator role and a separate binary. This relayer
only consumes proofs already accepted into Hyperbridge's offchain storage, so that
direction stays empty until a prover produces them.

## Ports

Defaults collide with any other node on the same box. Change `P2P_PORT`, `RPC_PORT` and
`METRICS_PORT` in `.env` if this shares a machine with a validator or the indexer.
