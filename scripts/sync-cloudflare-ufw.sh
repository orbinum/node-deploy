#!/usr/bin/env bash
# Sync the ufw allow-list for ports 80/443 to Cloudflare's current edge ranges.
#
# Cloudflare's IP ranges change occasionally. If a new range is added and ufw
# doesn't allow it, legitimate Cloudflare traffic to the origin gets dropped.
# Run this from cron (monthly is plenty) to keep the rules in sync.
#
# It is idempotent: it deletes the ufw rules it previously added (tagged via the
# rule comment) and re-adds the current set, so it never accumulates stale rules.
#
# Usage:
#   sudo ./sync-cloudflare-ufw.sh
#
# Cron (monthly, logs to syslog):
#   0 4 1 * * root /path/to/node-deploy/scripts/sync-cloudflare-ufw.sh 2>&1 | logger -t cf-ufw
set -euo pipefail

PORTS=(80 443)
TAG="cf-edge"   # ufw rule comment used to find/remove our own rules

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root (ufw needs root)." >&2
  exit 1
fi

# Fetch current ranges. Fail closed: if the fetch fails, leave existing rules
# untouched rather than wiping the allow-list and locking Cloudflare out.
v4="$(curl -fsS https://www.cloudflare.com/ips-v4)" || { echo "fetch ips-v4 failed" >&2; exit 1; }
v6="$(curl -fsS https://www.cloudflare.com/ips-v6)" || { echo "fetch ips-v6 failed" >&2; exit 1; }

if [[ -z "$v4" ]]; then
  echo "empty ips-v4 response, aborting" >&2
  exit 1
fi

# Remove the rules we added on a previous run (matched by the TAG comment).
# ufw has no "delete by comment", so parse `ufw status numbered` and delete by
# index from the bottom up (indices shift as you delete).
mapfile -t stale < <(ufw status numbered | grep "# ${TAG}" | grep -oE '^\[[ 0-9]+\]' | tr -d '[] ' | sort -rn)
for idx in "${stale[@]}"; do
  # --force skips the y/n prompt. Do NOT pipe `yes` here: when ufw exits, yes
  # keeps writing to a closed pipe, gets SIGPIPE, and under `set -o pipefail`
  # that aborts the whole script mid-delete (leaving the allow-list incomplete).
  ufw --force delete "$idx" >/dev/null
done

# Re-add the current ranges for each port. ponytail: empty ips-v6 just means
# no v6 rules get added — harmless on an IPv4-only host.
for ip in $v4 $v6; do
  [[ -z "$ip" ]] && continue
  for port in "${PORTS[@]}"; do
    ufw allow from "$ip" to any port "$port" proto tcp comment "${TAG}" >/dev/null
  done
done

echo "Synced ufw ${PORTS[*]} allow-list to $(wc -w <<<"$v4 $v6") Cloudflare ranges."
