#!/usr/bin/env bash
# Populate /home/claude/.secrets on LXC 105 from Bitwarden Secrets Manager.
# The directory is a tmpfs (home-claude-.secrets.mount), so the claude user's
# timers and cron scripts keep reading the
# same paths while nothing persists on disk (claude_sessions#24 step 4b,
# option B). Runs as root from claude-secrets.service.
#
# Bootstrap: the `claude` machine-account token is an encrypted systemd
# credential handed in via LoadCredentialEncrypted=. After every good fetch
# the whole directory is also saved as an encrypted bundle under
# /var/lib/claude-secrets and restored from there only when BWS is
# unreachable, so a boot without internet still brings the claude user's
# consumers up (with a WARNING in the journal).
set -uo pipefail
# The three overrides exist for scripts/tests/test_fetch_claude_secrets.sh,
# which runs this without root against a stub vault; the unit sets none.
OUT="${CLAUDE_SECRETS_DIR:-/home/claude/.secrets}"
OWNER="${CLAUDE_SECRETS_OWNER:-claude}"
STATE="${CLAUDE_SECRETS_STATE:-/var/lib/claude-secrets}"
BUNDLE="$STATE/bundle.cred"
BWS="${BWS_BIN:-/usr/local/bin/bws}"

# BWS secret name -> file under $OUT, written byte-for-byte (jq -j, no added
# newline; every consumer strips). REQUIRED: a missing vault entry fails the
# fetch and the bundle is used instead. OPTIONAL: missing in the vault means
# the file is skipped with a log line and removed if a previous run wrote it,
# which is how a file gets retired (claude_sessions#24 step 5).
declare -A REQUIRED=(
  [homeassistant]=homeassistant                  # check-new-ha-devices, HA_TOKEN for the homeassistant MCP server (~/.bashrc)
  [reolink]=reolink                              # ~/doorbell-collect collect.py, pull_hist.py, zone.py (run by hand)
  [minecraft-stack-env]=minecraft-stack.env      # one RCON_PASSWORD=... line; minecraft-stack/.env is a symlink to it
)
declare -A OPTIONAL=(
  [healthchecks-ping-url]=healthchecks-ping-url  # no host consumer since 2026-11-07 (the HA dead-man automation holds its own copy); kept while the vault entry exists
  [unifi]=unifi
)
# $OUT/gh-token.env is one "GH_TOKEN=<classic PAT>" line (claude_sessions#24
# step 4d). Env-file form rather than a bare value because it has two readers:
# ~/.profile sources it for tmux sessions and their archive hooks, and the
# claude-remote-control / claude-archive-backfill user units load it with
# EnvironmentFile= (a user unit never reads ~/.profile). REQUIRED.
GH_TOKEN_ENTRY=github-token-claude-lxc105
# The bootstrap token itself is written too: interactive `bws` for uid claude
# reads it from this file.
BOOTSTRAP_FILE=bitwarden-secretsmanager-token

log() { echo "fetch_claude_secrets: $*" >&2; }

# Refuse to write onto the on-disk directory: only ever populate the tmpfs.
if [ "$(findmnt -no FSTYPE "$OUT" 2>/dev/null)" != tmpfs ]; then
  log "$OUT is not a mounted tmpfs (home-claude-.secrets.mount inactive?); refusing to write secrets to disk"
  exit 1
fi

umask 077
install -d -m 0700 "$STATE"

finish() {
  # Every file is read by uid claude only (directly, by its timers, or
  # bind-mounted into containers running as the same uid), so the whole tree
  # is claude:claude 0600 under a 0700 directory. This also repairs the
  # ownership tar leaves behind when root restores the bundle.
  chown -R "$OWNER:$OWNER" "$OUT"
  chmod 0700 "$OUT"
  find "$OUT" -mindepth 1 -type f -exec chmod 0600 {} +
}

use_bundle() {
  if [ -s "$BUNDLE" ]; then
    log "WARNING using cached bundle from $(date -r "$BUNDLE" '+%Y-%m-%d %H:%M %Z') ($1)"
    if systemd-creds decrypt --name=claude-secrets-bundle "$BUNDLE" - | tar -C "$OUT" -xf -; then
      finish
      log "restored $(find "$OUT" -mindepth 1 -type f | wc -l) files from the fallback bundle"
      exit 0
    fi
    log "bundle decrypt failed"
  fi
  log "no secrets available ($1); $OUT left as it was"
  exit 1
}

if [ -z "${CREDENTIALS_DIRECTORY:-}" ] || [ ! -r "$CREDENTIALS_DIRECTORY/bws-token" ]; then
  use_bundle "no bws-token credential"
fi
token="$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/bws-token")"
export BWS_ACCESS_TOKEN="$token"
all="$(timeout 60 "$BWS" secret list 2>/dev/null)"; rc=$?
unset BWS_ACCESS_TOKEN
if [ "$rc" -ne 0 ] || [ -z "$all" ]; then
  use_bundle "bws secret list failed (rc=$rc)"
fi

count() { jq -r --arg k "$1" '[.[] | select(.key==$k)] | length' <<<"$all"; }
value() { jq -j --arg k "$1" '.[] | select(.key==$k) | .value' <<<"$all"; }

# Build the new set in a scratch directory on the same tmpfs, then move the
# files into place one by one (each mv is atomic on the same filesystem).
tmpdir="$(mktemp -d "$OUT/.fetch.XXXXXX")"
fail() { log "$1"; find "$tmpdir" -mindepth 1 -delete; rmdir "$tmpdir"; use_bundle "$1"; }
fetch_into() {  # fetch_into <vault-name> <file>; returns 1 when the entry is absent
  case "$(count "$1")" in
    1) value "$1" > "$tmpdir/$2" ;;
    0) return 1 ;;
    *) fail "BWS has more than one secret named $1; refusing to guess" ;;
  esac
}

for name in "${!REQUIRED[@]}"; do
  fetch_into "$name" "${REQUIRED[$name]}" || fail "BWS has no secret named $name (required)"
done
skipped=()
for name in "${!OPTIONAL[@]}"; do
  fetch_into "$name" "${OPTIONAL[$name]}" || skipped+=("${OPTIONAL[$name]}")
done
[ "$(count "$GH_TOKEN_ENTRY")" -eq 1 ] || fail "BWS has no single secret named $GH_TOKEN_ENTRY (required for gh-token.env)"
printf 'GH_TOKEN=%s\n' "$(value "$GH_TOKEN_ENTRY" | tr -d '[:space:]')" > "$tmpdir/gh-token.env"
printf '%s' "$token" > "$tmpdir/$BOOTSTRAP_FILE"
unset token all

for f in "$tmpdir"/*; do mv -f "$f" "$OUT/$(basename "$f")"; done
rmdir "$tmpdir"
# An optional entry removed from the vault: drop the file an earlier run of
# this boot wrote. Files this script does not manage are never touched.
for f in "${skipped[@]}"; do
  [ -f "$OUT/$f" ] && { find "$OUT" -maxdepth 1 -name "$f" -type f -delete; log "removed $f: no longer in the vault"; }
done
finish

if tar -C "$OUT" -cf - . | systemd-creds encrypt --name=claude-secrets-bundle - "$BUNDLE.tmp" 2>/dev/null; then
  mv -f "$BUNDLE.tmp" "$BUNDLE"; chmod 0600 "$BUNDLE"
  bundle_msg="fallback bundle refreshed"
else
  find "$STATE" -maxdepth 1 -name bundle.cred.tmp -delete
  bundle_msg="WARNING could not refresh the fallback bundle"
fi
log "wrote $(find "$OUT" -mindepth 1 -type f | wc -l) files to $OUT from BWS; $bundle_msg"
[ "${#skipped[@]}" -eq 0 ] || log "skipped optional entries not in the vault: ${skipped[*]}"
