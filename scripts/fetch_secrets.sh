#!/usr/bin/env bash
# Fetch homelab-stack's secrets from Bitwarden Secrets Manager into
# /run/homelab-stack (tmpfs, root 0700) before Docker starts, with an
# encrypted on-disk fallback for boots when BWS is unreachable
# (claude_sessions#24, option B).
#
# Bootstrap: the only persistent plaintext-free secret is the BWS machine-
# account token, an encrypted systemd credential handed in via
# LoadCredentialEncrypted=. On every successful fetch the whole bundle is
# also saved as an encrypted credential under /var/lib/homelab-stack, and
# used only when a fetch fails, so a reboot without internet still brings
# Traefik and the stack up.
set -uo pipefail
OUT=/run/homelab-stack
STATE=/var/lib/homelab-stack
BUNDLE="$STATE/bundle.cred"
BWS="${BWS_BIN:-/usr/local/bin/bws}"
# BWS secret name -> file under $OUT. Whole-file secrets, written byte-for-byte
# (jq -j: no added newline; ha_scrape_token must not end in one).
declare -A FILES=(
  [homelab-stack-env]=env                               # the former .env: CF_DNS_API_TOKEN
  [monitoring-ha-scrape-token]=ha_scrape_token
  [timemachine-env]=timemachine.env                     # PASSWORD= for the Time Machine share user (claude_sessions#37)
  [adguardhome-sync-env]=adguardhome-sync.env           # ORIGIN_USERNAME= and ORIGIN_PASSWORD= for the adguard-sync container
  [restic-env]=restic.env                               # RESTIC_REPOSITORY= and RESTIC_PASSWORD= for the backups (host-bootstrap section 10)
)

umask 077
install -d -m 0700 -o root -g root "$OUT" "$STATE"

use_bundle() {
  if [ -s "$BUNDLE" ]; then
    echo "fetch_secrets: WARNING using cached bundle from $(date -r "$BUNDLE" '+%Y-%m-%d %H:%M %Z') ($1)" >&2
    systemd-creds decrypt --name=homelab-stack-bundle "$BUNDLE" - | tar -C "$OUT" -xf - && { chmod 0600 "$OUT"/*; chmod 0644 "$OUT/ha_scrape_token"; exit 0; }
    echo "fetch_secrets: bundle decrypt failed" >&2
  fi
  echo "fetch_secrets: no secrets available ($1); stack cannot start" >&2
  exit 1
}

[ -n "${CREDENTIALS_DIRECTORY:-}" ] && [ -r "$CREDENTIALS_DIRECTORY/bws-token" ] || use_bundle "no bws-token credential"
export BWS_ACCESS_TOKEN
BWS_ACCESS_TOKEN="$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/bws-token")"

all="$(timeout 60 "$BWS" secret list 2>/dev/null)" || use_bundle "bws secret list failed"
tmpdir="$(mktemp -d -p "$OUT")"
for name in "${!FILES[@]}"; do
  if ! jq -ej --arg k "$name" '.[] | select(.key==$k) | .value' <<<"$all" > "$tmpdir/${FILES[$name]}"; then
    echo "fetch_secrets: BWS has no secret named $name" >&2
    rm -rf "$tmpdir"; use_bundle "missing $name"
  fi
done
unset BWS_ACCESS_TOKEN
# atomically replace the live files, then refresh the encrypted fallback
for f in "$tmpdir"/*; do mv -f "$f" "$OUT/$(basename "$f")"; done
rmdir "$tmpdir"
# ha_scrape_token goes into an HTTP header byte-for-byte; a newline pasted
# into the vault would break auth silently, so strip trailing whitespace.
printf '%s' "$(cat "$OUT/ha_scrape_token")" > "$OUT/ha_scrape_token"
# Modes: the three files bind-mounted into containers are read by non-root
# container users (prometheus, unpoller), so they are 0644; the
# directory is 0700 root, so no host user other than root can reach them and
# each container sees only the one file it mounts. env and the adguard env
# are read by compose as root and stay 0600.
chmod 0600 "$OUT"/*
chmod 0644 "$OUT/ha_scrape_token"
if tar -C "$OUT" -cf - . | systemd-creds encrypt --name=homelab-stack-bundle - "$BUNDLE.tmp" 2>/dev/null; then
  mv -f "$BUNDLE.tmp" "$BUNDLE"; chmod 0600 "$BUNDLE"
else
  echo "fetch_secrets: WARNING could not refresh the encrypted fallback bundle" >&2; rm -f "$BUNDLE.tmp"
fi
echo "fetch_secrets: wrote $(ls "$OUT" | wc -l) files to $OUT from BWS; fallback bundle refreshed"
