# Orbinum — node deploy

Docker deployment for **user-run Orbinum nodes**: validators and public RPC
nodes that **join** the network through the bootNodes baked into the chain spec.

This repo is intentionally scoped to user nodes. Orbinum's own bootnode / sentry
infrastructure lives elsewhere and is not configured here — so there is nothing
to confuse the two.

## Layout

```
common/                 shared build assets (node image, Caddy image + config)
  Dockerfile            builds the orbinum-node binary
  Caddy.Dockerfile      Caddy + rate-limit plugin
  Caddyfile             RPC reverse proxy: TLS, CORS, per-IP rate limits
testnet/
  chainspec/            testnet-spec.json (the network's genesis + bootNodes)
  validator/            docker-compose.yml + .env.example
  rpc/                  docker-compose.yml + .env.example
mainnet/                same structure as testnet (spec is a placeholder for now)
```

Pick one directory — `<network>/<role>` — copy `.env.example` to `.env`, fill
it, and run compose from inside that directory.

## GHCR — no login needed

`ghcr.io/orbinum/node` is **public**. `docker compose pull` works with no
credentials on a fresh host; nothing to configure.

**If a pull fails with `denied` on a host that used to work**, the cause is a
stored credential that has since expired — Docker keeps sending it instead of
falling back to anonymous. Drop it:

```bash
docker logout ghcr.io
docker compose pull
```

This is not hypothetical: an expired token in `~/.docker/config.json` blocked
the pull on every node during the `v0.1.0-rc.23` recovery, which is why the
image is public and no host stores a token any more.

<details>
<summary>Only if the registry actually asks for credentials</summary>

If a pull still fails with `denied` **after** `docker logout` — the package was
made private again, or you are pulling a different image — authenticate with a
**classic** PAT scoped to `read:packages` only:

```bash
read -rs GHCR_PAT   # paste the token; it does not echo and stays out of history
echo "$GHCR_PAT" | docker login ghcr.io -u <github-username> --password-stdin
unset GHCR_PAT
```

Fine-grained tokens do not work with GHCR unless the org grants Packages access
explicitly; a classic token is the reliable one.

The credential lands in `~/.docker/config.json` as reversible base64, not a
hash, and it does not expire on its own — so it becomes a liability the day it
is revoked or rotated: Docker keeps sending it and every pull fails with
`denied` while the image itself is fine. If you add one, note where, so it can
be removed rather than debugged later.

</details>

## Validator

Joins the network, authors blocks. No public RPC. Needs TCP **30333** reachable.

```bash
cd testnet/validator      # or mainnet/validator
cp .env.example .env       # set VALIDATOR_NAME + VALIDATOR_NODE_KEY
docker compose up -d
```

Generate the node-key with `openssl rand -hex 32`.

Session keys come after the node is synced. Generate them **on the node itself**
and register the public blob on-chain:

```bash
# 1. Generate — returns a 0x blob of 128 hex chars (Aura + GRANDPA)
docker exec orbinum-validator curl -s -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"author_rotateKeys"}' \
  http://localhost:9944

# 2. Submit session.setKeys(keys = <blob>, proof = 0x00) from your validator
#    account — Polkadot.js Apps, Developer → Extrinsics.

# 3. Verify the keystore actually holds them
docker exec orbinum-validator curl -s -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"author_hasSessionKeys","params":["<blob>"]}' \
  http://localhost:9944
```

Step 3 must return `true`. Rotating on one host and registering from another
leaves the chain holding keys no node can sign with — every other check passes and
the validator silently never authors. `proof` is `0x00`, the SCALE encoding of an
empty `Vec<u8>`; a bare `0x` fails to decode outside Polkadot.js Apps.

Inside the container the RPC port is always `9944`. On the host it is whatever
`RPC_PORT` you set (bound to `127.0.0.1`), so `docker exec` avoids the mismatch.

Full walkthrough: [Run a Validator Node](https://docs.orbinum.net/validators/running-a-validator).

## Public RPC

Full archive node behind Caddy (TLS + CORS + rate limiting). Needs a domain.

```bash
cd testnet/rpc            # or mainnet/rpc
cp .env.example .env       # set RPC_NAME, RPC_NODE_KEY, RPC_DOMAIN, resource caps
cp /path/to/origin.pem origin.pem
cp /path/to/origin.key origin.key
docker compose up -d       # builds the Caddy image from ../../common on first run
```

Caddy proxies HTTPS/WSS on your domain to the node on `localhost:9944`.

### TLS

The `Caddyfile` ships configured for the **Cloudflare-proxied** setup, which is
what we recommend for a public endpoint: the DNS record is Proxied (orange
cloud), Cloudflare absorbs L3/L4 + L7 attacks, and the origin only accepts
traffic from Cloudflare's ranges.

In that setup Caddy presents a Cloudflare **Origin Certificate** — hence the two
`cp` lines above. Let's Encrypt cannot be used behind the Cloudflare proxy: its
challenge connects to the domain and lands on Cloudflare, never reaching Caddy,
so the certificate can't be issued or renewed.

**Running without Cloudflare?** Then the origin certificate is not what you
want — drop this line from `common/Caddyfile`:

```caddy
tls /etc/caddy/origin.pem /etc/caddy/origin.key
```

Removing it re-enables Caddy's automatic Let's Encrypt, which needs ports 80 and
443 reachable from the internet. Skip the two `cp` commands in that case. Note
this leaves the node directly exposed, without the edge protection above.

## Telemetry

Every role can report to Orbinum's telemetry at
**[telemetry.orbinum.network](https://telemetry.orbinum.network)** — block
height, finalized blocks, peers, transactions in the pool, propagation time,
version and approximate location.

**It is on by default.** Every role sends to `wss://telemetry.orbinum.io/submit/`
unless told otherwise; the node appears within a few seconds under the name in
`VALIDATOR_NAME` / `RPC_NAME`.

To opt out, set the variable to empty in the node's `.env`:

```sh
TELEMETRY_URL=
```

To report somewhere else instead, put the whole flag in it:

```sh
TELEMETRY_URL=--telemetry-url "wss://telemetry.example/submit/ 0"
```

Either way, **the change needs `up --force-recreate`, not `restart`**:

```sh
docker compose up -d --force-recreate orbinum-rpc-node
```

`restart` restarts the process inside the container that already exists, and a
container's command is fixed when it is created — so the node comes back with
the arguments it had before, and an edited `.env` appears to do nothing.
`docker compose config` is no help here either: it prints what _would_ be
applied, not what the running container holds. To see the arguments a live node
actually has:

```sh
docker inspect orbinum-rpc-node --format '{{join .Config.Cmd " "}}'
```

Three things about that value are load-bearing:

- **The quotes stay.** The node parses `"<url> <level>"` as a single argument;
  without them the level is read as a separate flag and startup fails.
- **The trailing slash stays.** `/submit` without it does not upgrade.
- **`0` is the verbosity level**, not a placeholder. Higher levels add
  per-block chatter that the dashboard does not display.

Telemetry is an outbound connection, so it exposes no port and needs no
firewall change — it works on nodes whose RPC is loopback-only.

Note this reports a node's name, version, block height, peer count and
approximate location. An operator who does not want that published opts out
with the empty value above, and that really does silence the node:
`testnet-spec.json` carries an empty `telemetryEndpoints`. It used to list
Parity's endpoint, inherited from the spec this chain was generated from, which
meant opting out quietly redirected the same data to `telemetry.polkadot.io`
rather than stopping it. That field is metadata read by the client, not part of
the genesis state, so emptying it left the chain's genesis hash untouched.

## Node image

`common/Dockerfile` builds `orbinum-node`. The compose files default to
`ghcr.io/orbinum/node:<network>-latest`; override `ORBINUM_IMAGE` in `.env` to
pin a tag or point at a locally-built image. Watchtower auto-updates the node
container when a new image is published.

**Floating tag or pinned version — pick knowingly.** Following `<network>-latest`
means every release lands on your node within five minutes of being published,
good or bad: `v0.1.0-rc.23` shipped a binary without its executable bit, and every
node on the floating tag was recreated into a container that could not start.
Pinning (`ORBINUM_IMAGE=ghcr.io/orbinum/node:0.1.0-rc.24`) means you move when you
decide to. Both are legitimate; the `.env.example` files say which they default to.

**If a node ever ends up `Created` or `Restarting` after an update**, Watchtower now
recovers it on its own once a fixed image is published under the same tag
(`WATCHTOWER_INCLUDE_STOPPED`, `WATCHTOWER_REVIVE_STOPPED`,
`WATCHTOWER_INCLUDE_RESTARTING`). Before this, Watchtower scanned only running
containers, so a node killed by a bad image was invisible to it and needed a human.
The previous image is also kept on disk (`WATCHTOWER_CLEANUP=false`) so rolling back
is one line: set `ORBINUM_IMAGE` to it and `docker compose up -d <node-service>`.
Stacks deployed before these flags existed need one `git pull && docker compose up -d`
to pick them up — after that, no more visits.

**A testnet image needs `CARGO_FEATURES=hyperbridge-testnet`.** The Hyperbridge
coprocessor is a compile-time constant: without the feature the runtime carries
mainnet's `Polkadot(3367)`, and `is_allowed_proxy` compares the whole SCALE
variant with `==`, so every proxied ISMP request is rejected. Nothing fails at
build or deploy time — it surfaces when a relayer tries to work.

```bash
# testnet
docker build -f common/Dockerfile --build-arg CARGO_FEATURES=hyperbridge-testnet \
  -t orbinum-node:testnet ../node

# mainnet
docker build -f common/Dockerfile -t orbinum-node:mainnet ../node
```

Verify the result rather than trusting the flag — the `node` repo ships
`scripts/verify-coprocessor.sh <testnet|mainnet> [binary]`, which reads the
coprocessor back off a running node. Images published by the release workflow
already get the right feature per environment.

## Chain specs

This repo only **consumes** chain specs. The spec files under `<network>/chainspec/`
are generated in the [`node`](../node) repo and copied here. To cut a new genesis
or refresh bootNodes, regenerate the spec there and copy the resulting
`*-spec.json` into the matching `chainspec/` directory.

`mainnet/chainspec/` is an empty placeholder until the mainnet genesis exists.
