# RPC Node

The RPC node exposes a public HTTP/WebSocket endpoint for wallets, dApps, and the explorer. It does **not** participate in consensus.

> **We strongly recommend running the public RPC behind [Cloudflare](https://www.cloudflare.com/).**
> A public RPC is an open attack surface — Cloudflare provides L3/L4 + L7 DDoS
> protection, edge rate limiting, and TLS, while the origin (Caddy + the node)
> only ever accepts traffic from Cloudflare's ranges. This guide assumes that
> setup: the DNS record is proxied through Cloudflare, Caddy terminates TLS with
> a Cloudflare Origin Certificate, and the firewall allows `80`/`443` only from
> Cloudflare. Running without Cloudflare is possible but leaves the node directly
> exposed — not recommended for a public endpoint.

## Firewall ports

The public endpoint sits **behind the Cloudflare proxy**. Allow `80`/`443` only
from Cloudflare's edge ranges so a leaked origin IP can't be hit directly — this
is the main DDoS mitigation.

```bash
sudo ufw allow 22/tcp      # SSH
sudo ufw allow 30333/tcp   # P2P

# 80/443 only from Cloudflare (not the whole internet)
for ip in $(curl -s https://www.cloudflare.com/ips-v4); do
  sudo ufw allow from "$ip" to any port 443 proto tcp
  sudo ufw allow from "$ip" to any port 80 proto tcp
done

sudo ufw deny 9944         # RPC — Caddy reaches the node over loopback
sudo ufw deny 9615         # Prometheus — not public
sudo ufw enable
```

Include both IPv4 **and** IPv6 ranges. If the server has a public IPv6 address,
Cloudflare may reach the origin over IPv6 — allowing only v4 would silently drop
that traffic. Check with `ip -6 addr | grep inet6`.

### Keep the Cloudflare ranges in sync

Cloudflare's edge ranges change occasionally. Use `scripts/sync-cloudflare-ufw.sh`
to refresh the `80`/`443` allow-list (v4 + v6) from cron — it is idempotent and
fails closed (won't wipe the allow-list if the fetch fails):

```bash
# run once now
sudo ./scripts/sync-cloudflare-ufw.sh

# install a monthly cron (logs to syslog under tag cf-ufw)
echo '0 4 1 * * root /opt/node-deploy/scripts/sync-cloudflare-ufw.sh 2>&1 | logger -t cf-ufw' \
  | sudo tee /etc/cron.d/cf-ufw-sync
```

> Adjust the path to wherever you cloned the repo.

## DNS

In Cloudflare, point your domain to the server's public IP and set the record to
**Proxied** (orange cloud) so RPC traffic goes through the edge:

```
rpc-1.testnet.orbinum.io  A  <PUBLIC_IP>   Proxied
```

> The P2P port (`30333`) uses the real origin IP, which the node advertises
> directly — only the HTTPS/WSS endpoint (`443`) is proxied.

## Configure the `.env` file

```bash
cd testnet/rpc
cp .env.example .env
```

Edit `.env` and set:

| Variable        | What to set                                                                   |
| --------------- | ----------------------------------------------------------------------------- |
| `RPC_NAME`      | Identifiable name shown in telemetry (e.g. `Orbinum-RPC-1`).                  |
| `RPC_NODE_KEY`  | This node's libp2p key — generate with `openssl rand -hex 32`.                |
| `RPC_DOMAIN`    | Public domain with a DNS A record pointing to this VPS's public IP.           |
| `TELEMETRY_URL` | On by default; set empty to opt out. See [Telemetry](../README.md#telemetry). |

> **Keep `RPC_NODE_KEY` stable** — this node's PeerId goes public in `bootNodes`.
> If the key changes, the PeerId changes and the chain spec's bootnode entry breaks.

## TLS — Cloudflare Origin Certificate

Caddy terminates TLS with a **Cloudflare Origin Certificate** (not Let's Encrypt),
so the Cloudflare edge can validate the origin end-to-end (`Full (Strict)`).

### Why an Origin Certificate and not Let's Encrypt?

Caddy's default is automatic Let's Encrypt — but the `tls` line in the `Caddyfile`
(`tls /etc/caddy/origin.pem /etc/caddy/origin.key`) overrides that and pins a
specific certificate, so ACME/Let's Encrypt is **disabled** here on purpose.

With the domain proxied through Cloudflare, TLS is split into two hops:

```
client ──TLS──► Cloudflare ──TLS──► Caddy (origin)
       (edge cert)         (origin cert)
```

- **client ↔ Cloudflare** uses Cloudflare's edge certificate (the Advanced
  Certificate) — that's the one browsers trust. Caddy is not involved.
- **Cloudflare ↔ origin** uses the certificate Caddy presents — and only
  Cloudflare needs to trust it, not the public.

Let's Encrypt would fail in this setup: its HTTP-01 / TLS-ALPN challenge connects
to the domain to prove control, but that connection lands on **Cloudflare**, not
Caddy — so the challenge never reaches the origin and the cert can't be issued or
renewed. The same firewall that allows only Cloudflare to reach `80`/`443` also
blocks the Let's Encrypt validator.

The Cloudflare **Origin Certificate** sidesteps all of that: Cloudflare issues it
directly (15-year validity, no challenge), it's trusted only by Cloudflare (which
is all the second hop needs), and it never needs renewal or a public port-80
challenge.

1. Cloudflare → **SSL/TLS → Origin Server → Create Certificate** for
   `*.testnet.orbinum.io`. The private key is shown **once**.
2. Save the two PEM blocks next to the compose file:

   ```bash
   cd testnet/rpc
   nano origin.pem    # paste the "Origin Certificate" block
   nano origin.key    # paste the "Private Key" block
   chmod 600 origin.key
   ```

The compose mounts both into the Caddy container; the `Caddyfile` references them
with `tls /etc/caddy/origin.pem /etc/caddy/origin.key`.

> Cloudflare Universal SSL does not cover level-3 hosts like
> `rpc-1.testnet.orbinum.io`. Order an **Advanced Certificate** for
> `*.testnet.orbinum.io` under SSL/TLS → Edge Certificates, and set SSL/TLS mode
> to **Full (Strict)**.

## Start the RPC node

The `testnet/rpc/docker-compose.yml` stack runs the node **and Caddy**. Caddy is a custom
image (`Caddy.Dockerfile`) — base `caddy:2-alpine` plus the `caddy-ratelimit`
plugin — so it must be built before the first start. It reverse-proxies HTTPS/WSS
on port 443 to the node's local RPC (`localhost:9944`) and rate-limits per client
IP (100 req / 10s, keyed on `CF-Connecting-IP`).

```bash
docker compose build caddy   # compile the rate-limit plugin
docker compose pull          # node image
docker compose up -d
docker compose logs -f orbinum-rpc-node
```

Wait until you see `Idle` or `Syncing` in the logs, then confirm Caddy started
without TLS errors:

```bash
docker logs orbinum-caddy --tail 20
```

## Verify

Hit the public endpoint through Cloudflare — it should return JSON, not an HTML
challenge or a 403:

```bash
curl -s -H "Content-Type: application/json" \
  -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
  https://rpc-1.testnet.orbinum.io

# Expected: {"jsonrpc":"2.0","result":{"isSyncing":false,"peers":3,...},"id":1}
```

Batch requests (used by the indexer / SDK) must also work:

```bash
curl -s -H "Content-Type: application/json" \
  -d '[{"id":1,"jsonrpc":"2.0","method":"eth_blockNumber","params":[]},{"id":2,"jsonrpc":"2.0","method":"eth_blockNumber","params":[]}]' \
  https://rpc-1.testnet.orbinum.io
```

> If you get a Cloudflare bot challenge instead of JSON, add a WAF **Skip** rule
> for the RPC hostnames (skip managed rules + Super Bot Fight Mode).

To bypass Cloudflare/Caddy and hit the node's RPC directly, run the curl
**inside the container** against `localhost:9944`:

```bash
docker exec orbinum-rpc-node curl -s -H "Content-Type: application/json" \
  -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
  http://localhost:9944
```

The endpoint is ready to use as:

- `https://rpc-1.testnet.orbinum.io` — HTTP RPC
- `wss://rpc-1.testnet.orbinum.io` — WebSocket (Polkadot.js, Talisman)

## Private RPC (run your own, for your own use)

The guide above sets up a **public** endpoint (Cloudflare + Caddy + a domain).
If you just want a synced node for **your own** app, indexer, script, or local
development — not a public service — use [`testnet/indexer-rpc`](../testnet/indexer-rpc)
instead.

It serves RPC on **localhost only**: nothing is reachable from the internet, so
there's no firewall mistake to make and no Cloudflare/Caddy/TLS to set up. It
still syncs from the public bootnodes in the spec, so you get a fully synced
archive node feeding only you. It is **not** a bootnode, so `RPC_NODE_KEY` can be
any value.

```bash
cd testnet/indexer-rpc
cp .env.example .env          # fill RPC_NODE_KEY (openssl rand -hex 32)
docker compose up -d
```

Consume it from the same machine:

- `ws://127.0.0.1:9944` — WebSocket (Substrate)
- `http://127.0.0.1:9944` — HTTP (EVM / JSON-RPC)

## Useful Commands

```bash
# Stop the node
docker compose down

# Full reset
docker compose down -v

# Check sync status (inside the container — no Origin needed)
docker exec orbinum-rpc-node curl -s -H "Content-Type: application/json" \
  -d '{"id":1,"jsonrpc":"2.0","method":"system_syncState","params":[]}' \
  http://localhost:9944
```
