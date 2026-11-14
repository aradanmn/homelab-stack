#!/usr/bin/env bash
# Nightly restic backup of the host (host-bootstrap section 10). Runs as root
# from restic-backup.service, which loads RESTIC_REPOSITORY and RESTIC_PASSWORD
# from /run/homelab-stack/restic.env (BWS secret restic-env). On success it
# on success sets input_datetime.restic_backup_last_success in Home Assistant (the "Restic backup stale" alert)
# collector; a failed night leaves the old timestamp so the alert can fire.
set -euo pipefail
W=/home/claude/workspace
mountpoint -q /mnt/mimir-backups || { echo "restic_backup: /mnt/mimir-backups is not mounted" >&2; exit 1; }
restic backup "$W/homelab-stack/appdata" "$W/minecraft-stack/data" "$W/minecraft-stack/backups" /home/claude /etc \
  --exclude /home/claude/.cache --exclude /home/claude/.secrets \
  --exclude /home/claude/.rustup --exclude /home/claude/.cargo
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
"$W/homelab-stack/scripts/ha_mark_success.sh" input_datetime.restic_backup_last_success
echo "restic_backup: done"
