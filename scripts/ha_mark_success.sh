#!/bin/bash
# Record "this job just succeeded" in Home Assistant by setting an
# input_datetime helper to now. Replaces write_liveness.py (node_exporter
# textfile) since 2026-11-07 (claude_sessions#38). The helper is persisted by
# HA across restarts; the matching template binary_sensor turns on when it is
# older than the job's allowed gap.
#
#   ha_mark_success.sh input_datetime.restic_backup_last_success
#
# Runs as root from the job's unit; the token is the stack's HA token in
# /run/homelab-stack (fetched at boot, root only). Never echo the token.
set -euo pipefail
entity="${1:?usage: ha_mark_success.sh input_datetime.<helper>}"
token_file=/run/homelab-stack/ha_scrape_token
# HA_URL from the environment, else from the checkout's .env (site values live there)
env_file="$(dirname "$(readlink -f "$0")")/../.env"
ha_url="${HA_URL:-}"
if [ -z "$ha_url" ] && [ -r "$env_file" ]; then
  ha_url="$(sed -n 's/^HA_URL=//p' "$env_file" | tail -n 1)"
fi
[ -n "$ha_url" ] || { echo "ha_mark_success: HA_URL is not set and not in $env_file" >&2; exit 1; }
[ -r "$token_file" ] || { echo "ha_mark_success: $token_file unreadable" >&2; exit 1; }
curl -fsS -m 15 -o /dev/null \
  -H "Authorization: Bearer $(tr -d '\n' < "$token_file")" \
  -H 'Content-Type: application/json' \
  -d "{\"entity_id\":\"$entity\",\"datetime\":\"$(date '+%Y-%m-%d %H:%M:%S')\"}" \
  "$ha_url/api/services/input_datetime/set_datetime"
echo "ha_mark_success: $entity set"
