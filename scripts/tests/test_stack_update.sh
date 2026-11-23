#!/usr/bin/env bash
# Exercises scripts/stack-update.sh end to end against a throwaway compose
# project (never the live stack): a scratch git checkout with its own origin,
# two tiny services, and `docker compose up -d` as the deploy command.
#
#   good  runs on any image: an update must go through and be verified.
#   bad   stands in for a service whose new version migrates its config and
#         then fails, and whose old version refuses the migrated config:
#         it only runs on alpine 3.19 with "schema=34" in its config file,
#         and on 3.20 it rewrites the file to 35 and exits.
#
# Covers: precheck passes for good, fails for bad without touching the live
# config, and is inconclusive when the current version cannot run in the
# trial either; apply updates good; apply on bad rolls back by itself and the
# old version runs again (which needs the saved config put back); a repeated
# apply is a no-op; rollback by hand returns good to the old image.
# Needs docker and network access to pull alpine. Takes about two minutes.
# Run from anywhere: scripts/tests/test_stack_update.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../stack-update.sh"
OLD=alpine:3.19 NEW=alpine:3.20
work="$(mktemp -d /tmp/stack-update-test.XXXXXX)"
root="$work/stack"
proj="sutest$$"
fails=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cleanup() {
  (cd "$root" 2>/dev/null && docker compose -p "$proj" down -t 1 >/dev/null 2>&1)
  docker run --rm -v "$work:/t" "$OLD" sh -c 'rm -rf /t/* /t/.[!.]*' >/dev/null 2>&1
  rmdir "$work" 2>/dev/null
}
trap cleanup EXIT

export STACK_ROOT="$root" STACK_SETTLE_SECONDS=6 STACK_TRIAL_SECONDS=5 STACK_HELPER_IMAGE="$OLD"
export STACK_DEPLOY_CMD="docker compose -p $proj up -d --remove-orphans -t 1"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

compose() {  # $1 image for good, $2 image for bad
  cat <<EOF
services:
  good:
    image: $1
    command: ["sleep", "600"]
    volumes:
      - ./appdata/good:/conf
  bad:
    image: $2
    command: ["sh", "-c", "grep -q '^3.20' /etc/alpine-release && echo schema=35 > /conf/app.conf; grep -q '^3.19' /etc/alpine-release && grep -q schema=34 /conf/app.conf && exec sleep 600"]
    volumes:
      - ./appdata/bad:/conf
EOF
}
running_image() { docker inspect "$(docker ps -aq --filter "label=com.docker.compose.project=$proj" --filter "label=com.docker.compose.service=$1")" --format '{{.Config.Image}} {{.State.Status}}' 2>/dev/null; }
push_tags() { compose "$1" "$2" > "$work/src/docker-compose.yml"; git -C "$work/src" commit -qam "$3" && git -C "$work/src" push -q origin master; }

echo "== set up a scratch stack"
docker pull -q "$OLD" >/dev/null && docker pull -q "$NEW" >/dev/null || { echo "cannot pull test images"; exit 3; }
git init -q --bare -b master "$work/origin.git"
git clone -q "$work/origin.git" "$work/src" 2>/dev/null
git -C "$work/src" checkout -q -b master 2>/dev/null
printf 'appdata/\n' > "$work/src/.gitignore"
compose "$OLD" "$OLD" > "$work/src/docker-compose.yml"
git -C "$work/src" add -A && git -C "$work/src" commit -qm initial && git -C "$work/src" push -q origin master
git clone -q "$work/origin.git" "$root"
mkdir -p "$root/appdata/good" "$root/appdata/bad"
echo "schema=34" > "$root/appdata/bad/app.conf"
echo "setting=1" > "$root/appdata/good/app.conf"
(cd "$root" && bash -c "$STACK_DEPLOY_CMD" >/dev/null 2>&1); sleep 3
check "both services start on the old image" '[ "$(running_image good)" = "$OLD running" ] && [ "$(running_image bad)" = "$OLD running" ]'

echo "== precheck"
"$script" precheck good "$NEW" > "$work/out" 2>&1; rc=$?
check "precheck passes for a version that stays up" '[ $rc = 0 ] && grep -q "^PASS" "$work/out"'
"$script" precheck bad "$NEW" > "$work/out" 2>&1; rc=$?
check "precheck fails for a version that exits" '[ $rc = 1 ] && grep -q "^FAIL" "$work/out"'
check "precheck names the rewritten config file" 'grep -q "app.conf  changed" "$work/out"'
check "precheck left the live config alone" 'grep -qx schema=34 "$root/appdata/bad/app.conf"'
check "precheck left no container or scratch copy behind" '[ -z "$(docker ps -aq --filter name=stack-precheck-)" ] && ! ls -d /tmp/stack-update.?????? >/dev/null 2>&1'

# a service that cannot run in the sandbox even on its current image
echo "schema=35" > "$root/appdata/bad/app.conf"
"$script" precheck bad "$NEW" > "$work/out" 2>&1; rc=$?
echo "schema=34" > "$root/appdata/bad/app.conf"
check "precheck is inconclusive when the current version fails the trial too" '[ $rc = 3 ] && grep -q "^INCONCLUSIVE" "$work/out"'

echo "== apply, good path"
push_tags "$NEW" "$OLD" "good to new"
"$script" apply good > "$work/out" 2>&1; rc=$?
check "apply updates the service and verifies it" '[ $rc = 0 ] && grep -q "^verified" "$work/out" && [ "$(running_image good)" = "$NEW running" ]'
check "apply saved the old config" 'ls "$root"/appdata/.pre-update/good-*/mounts/1/app.conf >/dev/null 2>&1'
"$script" apply good > "$work/out" 2>&1; rc=$?
check "a second apply is a no-op" '[ $rc = 0 ] && grep -q "nothing to do" "$work/out"'

echo "== apply, bad path"
push_tags "$NEW" "$NEW" "bad to new"
"$script" apply bad > "$work/out" 2>&1; rc=$?
check "apply reports failure when the new version does not stay up" '[ $rc = 1 ] && grep -q "verification failed; rolling back" "$work/out"'
check "the saved config was put back" 'grep -qx schema=34 "$root/appdata/bad/app.conf"'
check "the old version is running again" '[ "$(running_image bad)" = "$OLD running" ] && grep -q "rollback verified" "$work/out"'
check "the other service was not rolled back" '[ "$(running_image good)" = "$NEW running" ]'

echo "== rollback by hand"
git -C "$root" checkout -q docker-compose.yml
"$script" rollback good > "$work/out" 2>&1; rc=$?
check "rollback returns a service to its old image" '[ $rc = 0 ] && [ "$(running_image good)" = "$OLD running" ]'

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; sed 's/^/    last output: /' "$work/out" | tail -n 25; fi
exit "$fails"
