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

## Validator

Joins the network, authors blocks. No public RPC. Needs TCP **30333** reachable.

```bash
cd testnet/validator      # or mainnet/validator
cp .env.example .env       # set VALIDATOR_NAME + VALIDATOR_NODE_KEY
docker compose up -d
```

Generate the node-key with `openssl rand -hex 32`. Session keys are inserted
separately after the node is running (author-set via the node's Unsafe RPC).

## Public RPC

Full archive node behind Caddy (TLS + CORS + rate limiting). Needs a domain
with a Cloudflare **Origin Certificate**.

```bash
cd testnet/rpc            # or mainnet/rpc
cp .env.example .env       # set RPC_NAME, RPC_NODE_KEY, RPC_DOMAIN, resource caps
cp /path/to/origin.pem origin.pem
cp /path/to/origin.key origin.key
docker compose up -d       # builds the Caddy image from ../../common on first run
```

The DNS record must be **Proxied** (orange cloud) in Cloudflare. Caddy proxies
HTTPS/WSS on your domain to the node on `localhost:9944`.

## Node image

`common/Dockerfile` builds `orbinum-node`. The compose files default to
`ghcr.io/orbinum/node:<network>-latest`; override `ORBINUM_IMAGE` in `.env` to
pin a tag or point at a locally-built image. Watchtower auto-updates the node
container when a new image is published.

## Chain specs

This repo only **consumes** chain specs. The spec files under `<network>/chainspec/`
are generated in the [`node`](../node) repo and copied here. To cut a new genesis
or refresh bootNodes, regenerate the spec there and copy the resulting
`*-spec.json` into the matching `chainspec/` directory.

`mainnet/chainspec/` is an empty placeholder until the mainnet genesis exists.
