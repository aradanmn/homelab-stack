#!/bin/bash
# One-off disk cleanup for the homelab host after the 2026-11-07 rebuild.
#
#   scripts/host_cleanup.sh            dry run: show what would go (default)
#   sudo scripts/host_cleanup.sh --apply
#
# Removes only:
#   1. /mnt/old, the staging copy of the old LXC homes extracted during
#      docs/host-bootstrap.md. Refused unless it looks like that folder, is
#      not a mount point, and the vzdump originals are readable on the NAS.
#   2. Docker images no container uses (docker image prune -a). Images of
#      running or stopped containers are kept.
# Touches nothing else: not the Minecraft backups, not appdata, not volumes.
# Safe to run twice: a missing /mnt/old is reported and skipped.
set -euo pipefail

EXPECT_HOST=homelab
OLD=/mnt/old
NAS=/mnt/mimir-backups

apply=0
case "${1:-}" in
  "") ;;
  --apply) apply=1 ;;
  *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
esac

[ "$(hostname)" = "$EXPECT_HOST" ] || { echo "refusing: this is $(hostname), not $EXPECT_HOST" >&2; exit 1; }
if [ "$apply" = 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "refusing: --apply needs root (try: sudo $0 --apply)" >&2; exit 1
fi

echo "== disk before"
df -h / | tail -1

echo
echo "== 1. $OLD"
if [ ! -e "$OLD" ]; then
  echo "absent, nothing to do"
else
  [ -d "$OLD" ] && [ ! -L "$OLD" ] || { echo "refusing: $OLD is not a plain directory" >&2; exit 1; }
  if mountpoint -q "$OLD"; then echo "refusing: $OLD is a mount point" >&2; exit 1; fi
  [ "$(realpath "$OLD")" = "$OLD" ] || { echo "refusing: $OLD resolves elsewhere" >&2; exit 1; }
  [ -d "$OLD/home/claude" ] || { echo "refusing: $OLD/home/claude missing, this is not the restore folder" >&2; exit 1; }
  mountpoint -q "$NAS" || { echo "refusing: $NAS is not mounted, cannot confirm the originals exist" >&2; exit 1; }
  ls "$NAS"/dump/vzdump-lxc-101-*.tar.zst >/dev/null 2>&1 \
    || { echo "refusing: no vzdump-lxc-101 backup on the NAS" >&2; exit 1; }
  echo "size: $(du -xsh "$OLD" 2>/dev/null | cut -f1)  (originals confirmed on $NAS)"
  if [ "$apply" = 1 ]; then
    rm -rf --one-file-system -- "$OLD"
    echo "removed $OLD"
  else
    echo "would remove $OLD"
  fi
fi

echo
echo "== 2. unused Docker images"
docker system df | sed -n 1,2p
if [ "$apply" = 1 ]; then
  docker image prune -a -f | tail -1
else
  echo "would run: docker image prune -a -f (images with no container; running stack untouched)"
fi

echo
echo "== disk after"
df -h / | tail -1
[ "$apply" = 1 ] || echo "(dry run: nothing changed. Re-run with --apply as root.)"
