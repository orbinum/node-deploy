#!/usr/bin/env python3
"""Static checks on the public RPC stacks: what the node exposes and what Caddy
lets through. Stdlib only, no Docker — CI runs it on every push.

Run: python3 -m unittest tests/test_rpc_config.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CADDYFILE = (ROOT / "common" / "Caddyfile").read_text()
RPC_STACKS = ("testnet/rpc/docker-compose.yml", "mainnet/rpc/docker-compose.yml")


def node_command(compose: str) -> str:
    start = compose.index("  orbinum-rpc-node:\n")
    return compose[start : compose.index("\n  caddy:\n", start)]


def endpoints(compose: str) -> list[dict[str, str]]:
    found = re.findall(r'--experimental-rpc-endpoint "([^"]+)"', node_command(compose))
    return [dict(kv.split("=", 1) for kv in e.split(",")) for e in found]


def caddy_ceiling(snippet: str) -> int:
    """Upstream connections Caddy can open through one snippet, all imports."""
    body = re.search(rf"\({snippet}\) \{{(.*?)\n\}}", CADDYFILE, re.S).group(1)
    cap = int(re.search(r"max_conns_per_host (\d+)", body).group(1))
    return cap * len(re.findall(rf"^\s*import {snippet}$", CADDYFILE, re.M))


class PublicRpcTests(unittest.TestCase):
    def test_node_serves_only_safe_methods(self):
        # The binary forces `--rpc-methods Unsafe`; only an endpoint's own
        # `methods=` keeps the unsafe namespace off a public node.
        for path in RPC_STACKS:
            with self.subTest(path):
                compose = (ROOT / path).read_text()
                command = node_command(compose)
                self.assertNotRegex(command, r"--(unsafe-)?rpc-(external|methods|port)\b")
                eps = endpoints(compose)
                self.assertEqual(len(eps), 2)
                for ep in eps:
                    self.assertEqual(ep.get("methods"), "safe", ep)
                    # `cors=` turns on the node's Host filter, which rejects
                    # the public Host Caddy forwards.
                    self.assertNotIn("cors", ep)

    def test_websocket_endpoint_is_loopback_and_rate_limited(self):
        for path in RPC_STACKS:
            with self.subTest(path):
                ws = endpoints((ROOT / path).read_text())[1]
                self.assertTrue(ws["listen-addr"].startswith("127.0.0.1:"), ws)
                self.assertIn("rate-limit", ws)

    def test_caddy_caps_stay_under_each_endpoint(self):
        # The 2026-09-14 outage: the caps summed past the node's limit.
        for path in RPC_STACKS:
            with self.subTest(path):
                http, ws = (int(e["max-connections"]) for e in endpoints((ROOT / path).read_text()))
                self.assertLess(caddy_ceiling("rpc_upstream"), http)
                self.assertLess(caddy_ceiling("rpc_upstream_ws"), ws)

    def test_forwarded_client_ip_trusted_only_from_cloudflare(self):
        # Every matcher on the header also requires a Cloudflare source IP.
        guarded = re.findall(r"header CF-Connecting-IP \*\n\s*import cloudflare_edge\n", CADDYFILE)
        self.assertEqual(len(guarded), 2)
        self.assertEqual(CADDYFILE.count("header CF-Connecting-IP *"), len(guarded))


if __name__ == "__main__":
    unittest.main()
