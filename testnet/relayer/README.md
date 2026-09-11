# Hyperbridge relayer

Tesseract, so Orbinum and Hyperbridge can verify each other's finality proofs and carry
ISMP messages between them.

It holds no authority: a forged proof is rejected by verification on the receiving side.
Postman, not notary. Anyone may run one.

## No node in this stack

Tesseract reaches Orbinum over the network. The endpoint is set in `relayer.toml`, and it
**must be an archive node** — `relayer.toml.example` lists which ones qualify.

### Why archive, and why the failure is silent

`ismp_queryEvents` is how Tesseract finds the messages Orbinum dispatches. It does not
read stored events: it **re-executes the runtime** at each block to read `System::Events`,
which is cleared at the start of every block (`pallet-ismp-rpc` → `block_events` →
`read_events_no_consensus`).

A node without the state for a block returns an **empty list and no error**. The relayer
logs `no new messages` over ranges that did contain them, forwards nothing, and looks
healthy throughout — consensus proofs keep flowing, because those need no historical
state.

This stack used to run its own node with `--state-pruning 1000`, chosen precisely because
GRANDPA proving only needs justifications and headers. True for consensus, false for
messaging. Consensus flowed for weeks while every ISMP message was dropped. Rather than
make that node archive — a full resync and a second archive node to maintain — it was
removed, since the fleet already has archive nodes.

The trade: the relayer now depends on another box being reachable.

## Deploy

```bash
cp .env.example .env
cp relayer.toml.example relayer.toml
$EDITOR relayer.toml               # both signer lines, and the archive node's address

docker compose up -d
```

`relayer.toml` is gitignored — it carries the signer secrets in the clear, because
Tesseract does not expand environment variables in its config.

Tesseract restarts on its own until the node it points at can answer — expected while
that node is still syncing, or before it has been opened to this box.

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

The reverse direction — Hyperbridge's height on our chain — is read from whichever node
this relayer points at (measured 2026-09-09: `KUSAMA-4009/PAS0` at height 10403562,
74s old):

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"ismp_queryStateMachineLatestHeight",
       "params":[{"state_id":"KUSAMA-4009","consensus_state_id":"PAS0"}]}' \
  http://10.0.0.10:9944
```

Both halves matter and neither is visible from one side alone: our proofs landing on
Hyperbridge can only be read from Gargantua, theirs landing on us only from our node.
That is what the exporter below measures.

## Ports

This stack binds nothing. Tesseract only makes outbound connections — to Hyperbridge,
and to the node that serves Orbinum — so there is no port to collide with a validator or
an indexer sharing the box, and no firewall rule to add here.
