#!/usr/bin/env bash
# Exercises scripts/fetch_claude_secrets.sh without root or a vault: a stub
# `bws` serves a JSON list, a stub `findmnt` answers "tmpfs", and the output,
# state and credentials directories point into a scratch tree. Covers the
# happy path (files, modes, bootstrap token), a missing
# required entry (no partial writes, exit 1 without a bundle), an optional
# entry disappearing between runs (stale file removed), the gh token entry
# missing (required, env-file form), and a duplicate name.
# Run from anywhere: scripts/tests/test_fetch_claude_secrets.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../fetch_claude_secrets.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/out" "$work/state" "$work/creds"
printf 'tok-claude-lxc\n' > "$work/creds/bws-token"
cat > "$work/bin/findmnt" <<'EOF'
#!/bin/sh
echo tmpfs
EOF
cat > "$work/bin/bws" <<'EOF'
#!/bin/sh
cat "$STUB_VAULT"
EOF
# "encrypt --name=N - OUT" and "decrypt --name=N IN -", as the script calls
# them; a plain copy, so the fallback path can be exercised without root
cat > "$work/bin/systemd-creds" <<'EOF'
#!/bin/sh
case "$1" in
  encrypt) cat > "$4" ;;
  decrypt) cat "$3" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/findmnt" "$work/bin/bws" "$work/bin/systemd-creds"
state="$work/state"           # scenarios that must see no bundle point this elsewhere

vault() {  # vault name=value ... -> JSON list in $STUB_VAULT
  python3 -I -c '
import json, sys
print(json.dumps([{"key": a.split("=",1)[0], "value": a.split("=",1)[1], "projectId": "p"} for a in sys.argv[1:]]))' "$@" > "$work/vault.json"
}
run() {
  PATH="$work/bin:$PATH" STUB_VAULT="$work/vault.json" BWS_BIN="$work/bin/bws" \
  CREDENTIALS_DIRECTORY="$work/creds" CLAUDE_SECRETS_DIR="$work/out" \
  CLAUDE_SECRETS_STATE="$state" CLAUDE_SECRETS_OWNER="$(id -un)" \
  bash "$script" 2> "$work/stderr"
}
fails=0
check() { if "$@"; then :; else echo "FAIL: $*"; fails=$((fails + 1)); fi; }
full_vault() {
  vault homeassistant=ha-token healthchecks-ping-url=https://hc/ping reolink=user:pass minecraft-stack-env=RCON_PASSWORD=rc1 \
        github-token-claude-lxc105=test-token unifi=unifi-key claude-code-oauth-env=CLAUDE_CODE_OAUTH_TOKEN=tok1 "$@"
}

echo "1. happy path"
touch "$work/out/unmanaged-file"; chmod 0644 "$work/out/unmanaged-file"; chmod 0755 "$work/out"
full_vault; run; rc=$?
check [ "$rc" -eq 0 ]
check [ "$(stat -c %a "$work/out/unmanaged-file")" = 600 ]   # finish() tightens everything in the tree, managed or not
check [ "$(stat -c %s "$work/out/healthchecks-ping-url")" -eq 15 ]   # "https://hc/ping" byte-for-byte, no newline added
check [ "$(cat "$work/out/bitwarden-secretsmanager-token")" = tok-claude-lxc ]
check [ "$(cat "$work/out/gh-token.env")" = "GH_TOKEN=test-token" ]   # env-file form, one line, trailing newline
check [ "$(stat -c %a "$work/out/gh-token.env")" = 600 ]
check [ "$(stat -c %a "$work/out/homeassistant")" = 600 ]
check [ "$(stat -c %a "$work/out")" = 700 ]
check [ "$(cat "$work/out/reolink")" = user:pass ]
check [ "$(cat "$work/out/minecraft-stack.env")" = RCON_PASSWORD=rc1 ]
check [ "$(cat "$work/out/claude-code-oauth.env")" = CLAUDE_CODE_OAUTH_TOKEN=tok1 ]
check [ ! -e "$work/out/cloudflare" ]           # retired 2026-11-01: no consumer on 105 (claude_sessions#28)
check [ ! -e "$work/out/gmail_app_password" ]   # retired with it
check [ "$(find "$work/out" -mindepth 1 -type f | wc -l)" -eq 9 ]     # 3 required + unifi + healthchecks + claude-code-oauth.env + gh-token.env + bootstrap + unmanaged
check test -z "$(grep 'skipped optional' "$work/stderr")"
check grep -q 'fallback bundle refreshed' "$work/stderr"
check [ -s "$state/bundle.cred" ]
check [ "$(stat -c %a "$state/bundle.cred")" = 600 ]
check [ -z "$(find "$work/out" -maxdepth 1 -name '.fetch.*')" ]

echo "2. optional entry removed from the vault: stale file dropped, others kept"
vault homeassistant=ha-token healthchecks-ping-url=https://hc/ping reolink=user:pass minecraft-stack-env=RCON_PASSWORD=rc1 \
      github-token-claude-lxc105=test-token
run; rc=$?
check [ "$rc" -eq 0 ]
check [ ! -e "$work/out/unifi" ]
check [ -e "$work/out/homeassistant" ]
check grep -q 'removed unifi' "$work/stderr"
check grep -q 'skipped optional entries not in the vault: .*unifi' "$work/stderr"

state="$work/state-empty"; mkdir -p "$state"   # scenarios 3 to 6 must not find the bundle scenario 2 wrote
echo "3. required entry missing, no bundle: exit 1, nothing partially written"
vault homeassistant=ha-token healthchecks-ping-url=https://hc/ping minecraft-stack-env=RCON_PASSWORD=rc1 github-token-claude-lxc105=test-token unifi=unifi-key
before="$(find "$work/out" -mindepth 1 | sort | md5sum)"
run; rc=$?
check [ "$rc" -eq 1 ]
check grep -q 'no secret named reolink (required)' "$work/stderr"
check [ "$(find "$work/out" -mindepth 1 | sort | md5sum)" = "$before" ]

echo "3b. gh token entry missing: exit 1, nothing partially written"
full_vault; python3 -I -c '
import json,sys; p=sys.argv[1]; json.dump([e for e in json.load(open(p)) if e["key"]!="github-token-claude-lxc105"], open(p,"w"))' "$work/vault.json"
before="$(find "$work/out" -mindepth 1 | sort | md5sum)"
run; rc=$?
check [ "$rc" -eq 1 ]
check grep -q 'no single secret named github-token-claude-lxc105' "$work/stderr"
check [ "$(find "$work/out" -mindepth 1 | sort | md5sum)" = "$before" ]

echo "4. duplicate name: refuses"
full_vault homeassistant=second
run; rc=$?
check [ "$rc" -eq 1 ]
check grep -q 'more than one secret named homeassistant' "$work/stderr"

echo "5. bws unreachable, no bundle: exit 1"
full_vault; printf '' > "$work/vault.json"
run; rc=$?
check [ "$rc" -eq 1 ]
check grep -q 'bws secret list failed' "$work/stderr"

echo "6. not a tmpfs: refuses before touching anything"
full_vault; printf '#!/bin/sh\necho ext4\n' > "$work/bin/findmnt"
run; rc=$?
check [ "$rc" -eq 1 ]
check grep -q 'refusing to write secrets to disk' "$work/stderr"
printf '#!/bin/sh\necho tmpfs\n' > "$work/bin/findmnt"

echo "7. bws unreachable with the bundle from scenario 2: restored, WARNING, ownership and modes reset"
state="$work/state"
printf '' > "$work/vault.json"
printf 'stale' > "$work/out/homeassistant"; chmod 0644 "$work/out/homeassistant"; chmod 0755 "$work/out"
run; rc=$?
check [ "$rc" -eq 0 ]
check grep -q 'WARNING using cached bundle' "$work/stderr"
check grep -q 'restored 7 files from the fallback bundle' "$work/stderr"   # scenario 2's set: 9 minus unifi and claude-code-oauth.env
check [ "$(stat -c %a "$work/out/homeassistant")" = 600 ]
check [ "$(stat -c %a "$work/out")" = 700 ]
check [ ! -e "$work/out/unifi" ]      # scenario 2's bundle was taken after unifi left the vault

if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi
