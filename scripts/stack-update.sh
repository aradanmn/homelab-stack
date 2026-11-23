#!/usr/bin/env bash
# Update one service of this stack with a check before and a way back.
#
#   scripts/stack-update.sh precheck <service> <image:tag> [--keep]
#   scripts/stack-update.sh apply    <service>
#   scripts/stack-update.sh rollback <service>
#
# Nothing here runs on a timer. A person (or a Claude session they told to)
# runs it; docs/updating.md has the whole procedure.
#
# precheck  Trial-runs <image:tag> beside the live container: same command,
#           environment and read-only mounts, but every writable mount is a
#           copy, there is no network and no published port. Prints whether
#           the new version stays up, the log lines that look like trouble,
#           and which files in the copies it rewrote (names only). Changes
#           nothing that is running. Exit 0 = the trial stayed up.
# apply     Run after the tag change is merged. Pulls the checkout and the
#           image, saves the service's writable config under
#           appdata/.pre-update/, deploys, then verifies. A failed
#           verification rolls back by itself.
# rollback  Puts back the newest saved state for the service: compose file,
#           image and config.
#
# Writable mounts larger than STACK_COPY_LIMIT_MB (default 200) are data, not
# config: precheck gives the trial an empty directory instead, and apply does
# not save them (the nightly restic backup is their copy). Both say so.
#
# Environment (tests override these; the defaults are the live host):
#   STACK_ROOT        checkout to work on (default: this script's checkout)
#   STACK_DEPLOY_CMD  how to deploy (default: restart homelab-stack.service)
#   STACK_HELPER_IMAGE  small image with sh, cp, du, diff (default alpine:latest)
#   STACK_TRIAL_SECONDS, STACK_SETTLE_SECONDS, STACK_COPY_LIMIT_MB, STACK_KEEP
set -uo pipefail

ROOT="${STACK_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
DEPLOY_CMD="${STACK_DEPLOY_CMD:-sudo -n systemctl restart homelab-stack.service}"
HELPER="${STACK_HELPER_IMAGE:-alpine:latest}"
TRIAL_SECONDS="${STACK_TRIAL_SECONDS:-20}"
SETTLE_SECONDS="${STACK_SETTLE_SECONDS:-15}"
COPY_LIMIT_MB="${STACK_COPY_LIMIT_MB:-200}"
KEEP="${STACK_KEEP:-3}"                 # saved states kept per service
SNAPROOT="$ROOT/appdata/.pre-update"
COMPOSE="$ROOT/docker-compose.yml"

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'stack-update: %s\n' "$*" >&2; exit 2; }

# ---- questions (no side effects) -------------------------------------------

# container id of a service of THIS checkout's compose project ("" if none)
cid_of() {
  docker ps -aq --filter "label=com.docker.compose.project.working_dir=$ROOT" \
                --filter "label=com.docker.compose.service=$1" | head -n 1
}

# image reference the compose file names for a service
compose_image() {
  (cd "$ROOT" && docker compose config --no-interpolate --format json 2>/dev/null) \
    | jq -r --arg s "$1" '.services[$s].image // empty'
}

image_id() { docker image inspect "$1" --format '{{.Id}}' 2>/dev/null; }

# one line per mount: type, source (volume name for volumes), destination, rw
mounts_of() {
  docker inspect "$1" --format '{{json .Mounts}}' \
    | jq -r '.[] | select(.Type=="bind" or .Type=="volume")
             | [.Type, (if .Type=="volume" then .Name else .Source end), .Destination, (.RW|tostring)] | @tsv'
}

size_mb() {  # of a bind source or a volume; "" if it cannot be read
  docker run --rm --network none -v "$1:/s:ro" "$HELPER" du -sm /s 2>/dev/null | cut -f1
}

newest_snapshot() {
  # shellcheck disable=SC2012  # names are ours: <service>-<timestamp>
  ls -1d "$SNAPROOT/$1"-[0-9]* 2>/dev/null | sort | tail -n 1
}

# Is the service healthy on the expected image? Prints the reason when not.
# $3 = restart count seen before the settle wait.
check_container() {
  local svc="$1" want="$2" before="$3" cid st
  cid="$(cid_of "$svc")"
  [ -n "$cid" ] || { say "verify: no container for $svc"; return 1; }
  st="$(docker inspect "$cid" --format '{{.State.Status}} {{.Image}} {{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
  # shellcheck disable=SC2086
  set -- $st
  [ "$1" = running ]   || { say "verify: $svc is $1, not running"; return 1; }
  [ "$2" = "$want" ]   || { say "verify: $svc runs a different image than expected"; return 1; }
  [ "$3" = "$before" ] || { say "verify: $svc restarted during the settle wait (crash loop)"; return 1; }
  [ "$4" != unhealthy ] || { say "verify: $svc reports unhealthy"; return 1; }
  return 0
}

# Does the service do its job? Only services with a cheap, local, unambiguous
# probe have one; the rest pass on check_container alone.
probe_service() {
  local svc="$1" try out
  for try in 1 2 3; do
    case "$svc" in
      adguard)
        out="$(dig +short +time=3 +tries=1 @127.0.0.1 example.com A 2>/dev/null)"
        [ -n "$out" ] && return 0 ;;
      traefik)
        out="$(curl -sk -m 5 -o /dev/null -w '%{http_code}' https://127.0.0.1/ 2>/dev/null)"
        case "$out" in 2??|3??|4??) return 0 ;; esac ;;
      *) return 0 ;;
    esac
    [ "$try" = 3 ] || sleep 5
  done
  say "verify: $svc probe failed (adguard: DNS answer on 127.0.0.1; traefik: HTTPS answer on 127.0.0.1)"
  return 1
}

# ---- actions ---------------------------------------------------------------

need_tools() {
  local t
  for t in docker jq git flock; do command -v "$t" >/dev/null || die "missing tool: $t"; done
  [ -f "$COMPOSE" ] || die "no docker-compose.yml under $ROOT"
}

lock() {
  mkdir -p "$SNAPROOT" || die "cannot create $SNAPROOT"
  exec 9>"$SNAPROOT/.lock"
  flock -n 9 || die "another stack-update run holds the lock"
}

# Remove a scratch tree whose files may belong to root (copied with cp -a).
# Refuses anything that is not one of our own mktemp or snapshot paths.
remove_tree() {
  local d="$1"
  case "$d" in
    /tmp/stack-update.*|"$SNAPROOT"/*-[0-9]*) ;;
    *) say "not removing unexpected path: $d"; return 1 ;;
  esac
  [ -d "$d" ] || return 0
  docker run --rm --network none -v "$d:/t" "$HELPER" sh -c 'rm -rf /t/* /t/.[!.]* 2>/dev/null; true'
  rmdir "$d" 2>/dev/null || true
}

deploy() { (cd "$ROOT" && bash -c "$DEPLOY_CMD"); }

# Wait, then verify. $1 service, $2 expected image id.
settle_and_verify() {
  local svc="$1" want="$2" cid before waited=0
  cid="$(cid_of "$svc")"
  before="$( [ -n "$cid" ] && docker inspect "$cid" --format '{{.RestartCount}}' )"
  say "waiting ${SETTLE_SECONDS}s for $svc to settle"
  sleep "$SETTLE_SECONDS"
  # a health check that is still starting gets up to 60 s more
  while [ "$waited" -lt 60 ]; do
    cid="$(cid_of "$svc")"
    [ -n "$cid" ] && [ "$(docker inspect "$cid" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')" = starting ] || break
    sleep 5; waited=$((waited + 5))
  done
  check_container "$svc" "$want" "${before:-0}" && probe_service "$svc"
}

# Copy each writable mount of container $1 that is small enough into $2/<n>.
# Writes $2/mounts.tsv: n, type, source, destination, saved|skipped, size MB.
save_mounts() {
  local cid="$1" dest="$2" n=0 type src dst rw mb
  mkdir -p "$dest"
  : > "$dest/mounts.tsv"
  while IFS=$'\t' read -r type src dst rw; do
    [ "$rw" = true ] || continue
    n=$((n + 1))
    mb="$(size_mb "$src")"
    if [ -n "$mb" ] && [ "$mb" -le "$COPY_LIMIT_MB" ]; then
      docker run --rm --network none -v "$src:/s:ro" -v "$dest:/d" "$HELPER" cp -a /s "/d/$n" \
        || die "could not copy $src"
      printf '%s\t%s\t%s\t%s\tsaved\t%s\n' "$n" "$type" "$src" "$dst" "$mb" >> "$dest/mounts.tsv"
    else
      printf '%s\t%s\t%s\t%s\tskipped\t%s\n' "$n" "$type" "$src" "$dst" "${mb:-?}" >> "$dest/mounts.tsv"
    fi
  done < <(mounts_of "$cid")
}

report_mounts() {  # $1 = mounts.tsv, $2 = word for what happened to saved ones
  local n type src dst what mb
  while IFS=$'\t' read -r n type src dst what mb; do
    if [ "$what" = saved ]; then say "  [$n] $dst  ($mb MB)  $2"
    else say "  [$n] $dst  ($mb MB)  NOT $2: over ${COPY_LIMIT_MB} MB, treated as data"; fi
  done < "$1"
}

# Run image $1 for TRIAL_SECONDS in the sandbox, writable mounts under
# $tmp/$2. Prints the outcome; returns 0 if it was still running at the end.
# Uses the caller's tmp, name, ro_args, extra_args and cmd.
run_trial() {
  local image="$1" label="$2" quiet="${3:-}" args=() n type src dst what mb state rc=0
  while IFS=$'\t' read -r n type src dst what mb; do
    if [ "$what" = saved ]; then args+=(-v "$tmp/$label/$n:$dst")
    else mkdir -p "$tmp/empty-$label/$n"; args+=(-v "$tmp/empty-$label/$n:$dst"); fi
  done < "$tmp/before/mounts.tsv"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" --network none --env-file "$tmp/env" \
      "${extra_args[@]}" "${ro_args[@]}" "${args[@]}" "$image" "${cmd[@]}" >/dev/null \
    || die "the trial container could not be created for $image"
  sleep "$TRIAL_SECONDS"
  state="$(docker inspect "$name" --format '{{.State.Status}} exit={{.State.ExitCode}}')"
  case "$state" in running*) ;; *) rc=1 ;; esac
  if [ -z "$quiet" ]; then
    case "$rc" in 0) say "trial container: still running" ;; *) say "trial container: $state  <-- did not stay up" ;; esac
    say "log lines that mention a problem or a migration (network errors are expected;"
    say "timestamps removed, repeats counted, first 25 kinds):"
    docker logs "$name" 2>&1 | grep -iE 'error|fatal|panic|warn|deprecat|migrat|invalid|unknown|unsupported|schema' \
      | sed -E 's/^[0-9TZ:.\/ -]+//; s/[0-9.]+(µs|ms|s)\b/N/g' | cut -c1-110 | sort | uniq -c | sort -rn | head -n 25 | sed 's/^/  /'
    say "last lines of the log:"
    docker logs --tail 5 "$name" 2>&1 | cut -c1-220 | sed 's/^/  /'
  fi
  docker rm -f "$name" >/dev/null 2>&1
  return "$rc"
}

# names of the files under $tmp/$1 that differ from $tmp/before, one per line
changed_files() {
  docker run --rm --network none -v "$tmp:/t:ro" "$HELPER" diff -rq /t/before "/t/$1" 2>&1 \
    | grep -v 'mounts\.tsv' \
    | sed -E -e 's#^Files /t/before/([0-9]+)/?(.*) and .* differ$#[\1] \2  changed#' \
             -e 's#^Only in /t/[a-z]+/([0-9]+)/?(.*): (.*)$#[\1] \2/\3  added or removed#' \
    | cut -c1-220 | sort
}

cmd_precheck() {
  local svc="${1:-}" new="${2:-}" keep="${3:-}"
  [ -n "$svc" ] && [ -n "$new" ] || die "usage: precheck <service> <image:tag> [--keep]"
  need_tools
  local cid old tmp name
  cid="$(cid_of "$svc")"; [ -n "$cid" ] || die "no container for service '$svc' in $ROOT"
  old="$(docker inspect "$cid" --format '{{.Config.Image}}')"
  tmp="$(mktemp -d /tmp/stack-update.XXXXXX)" || die "mktemp failed"
  chmod 700 "$tmp"
  name="stack-precheck-$svc-$$"
  # shellcheck disable=SC2064
  trap "docker rm -f '$name' >/dev/null 2>&1; [ '$keep' = --keep ] || remove_tree '$tmp'" EXIT

  step "precheck $svc: $old -> $new"
  docker pull -q "$new" >/dev/null || die "cannot pull $new"

  # What the live container adds on top of its image: environment, command.
  # Environment goes file to file (it can hold secrets) and is never printed.
  docker inspect "$cid" --format '{{json .Config.Env}}' > "$tmp/env.c"
  docker image inspect "$old" --format '{{json .Config.Env}}' > "$tmp/env.i" 2>/dev/null || echo '[]' > "$tmp/env.i"
  jq -rn --slurpfile c "$tmp/env.c" --slurpfile i "$tmp/env.i" '(($c[0] // []) - ($i[0] // []))[]' > "$tmp/env"
  local ro_args=() extra_args=() cmd=() c_cmd i_cmd c_user type src dst rw
  c_cmd="$(docker inspect "$cid" --format '{{json .Config.Cmd}}')"
  i_cmd="$(docker image inspect "$old" --format '{{json .Config.Cmd}}' 2>/dev/null)"
  if [ "$c_cmd" != "$i_cmd" ] && [ "$c_cmd" != null ]; then mapfile -t cmd < <(jq -r '.[]' <<<"$c_cmd"); fi
  if [ "$(docker inspect "$cid" --format '{{json .Config.Entrypoint}}')" != \
       "$(docker image inspect "$old" --format '{{json .Config.Entrypoint}}' 2>/dev/null)" ]; then
    say "note: the service overrides the image entrypoint; the trial uses each image's own"
  fi
  c_user="$(docker inspect "$cid" --format '{{.Config.User}}')"
  [ -z "$c_user" ] || extra_args+=(--user "$c_user")

  # Mounts: read-only ones as they are, writable ones as copies (one set per run).
  save_mounts "$cid" "$tmp/before"
  docker run --rm --network none -v "$tmp:/t" "$HELPER" sh -c 'cp -a /t/before /t/current && cp -a /t/before /t/new' \
    || die "copy failed"
  while IFS=$'\t' read -r type src dst rw; do
    [ "$rw" = false ] && ro_args+=(-v "$src:$dst:ro")
  done < <(mounts_of "$cid")
  say "writable mounts given to the trial:"
  report_mounts "$tmp/before/mounts.tsv" "copied"

  # The sandbox is not the real setup (no network, no ports, no host
  # namespaces). The current image goes first: if even that cannot run here,
  # the trial says nothing about the new one.
  say "trial of the current image, then the new one, ${TRIAL_SECONDS}s each (no network, no ports)"
  local base=0 rc=0
  run_trial "$old" current quiet || base=1
  step "result for $new"
  run_trial "$new" new || rc=1

  say "files the new version changed in the copies (names only, [n] as above):"
  changed_files current > "$tmp/changed.current"
  changed_files new > "$tmp/changed.new"
  comm -13 "$tmp/changed.current" "$tmp/changed.new" | head -n 60 | sed 's/^/  /'
  say "  (plus $(comm -12 "$tmp/changed.current" "$tmp/changed.new" | wc -l) that the current version rewrites as well)"
  if [ "$keep" = --keep ]; then
    say "kept for a closer look (root-owned, may hold secrets): $tmp/before and $tmp/new"
    say "remove with: docker run --rm -v $tmp:/t $HELPER sh -c 'rm -rf /t/*' && rmdir $tmp"
  fi

  step "verdict"
  if [ "$base" = 1 ]; then
    say "INCONCLUSIVE: the current image does not stay up in the trial either, so the trial"
    say "cannot judge this service. Rely on the release notes and on apply's verification."
    return 3
  fi
  if [ "$rc" = 1 ]; then say "FAIL: the current image stays up in the trial and the new one does not."; return 1; fi
  say "PASS: the new image stays up on a copy of the live config. Read the log lines and"
  say "the changed files above before relying on it."
  return 0
}

# Put back saved state $2 for service $1 and deploy. Used by rollback and by
# a failed apply.
restore() {
  local svc="$1" snap="$2" old_ref old_id old_commit cid n type src dst what mb
  [ -r "$snap/meta" ] || die "no usable saved state at $snap"
  old_ref="$(sed -n 's/^image_ref=//p' "$snap/meta")"
  old_id="$(sed -n 's/^image_id=//p' "$snap/meta")"
  old_commit="$(sed -n 's/^commit=//p' "$snap/meta")"
  step "rollback $svc to $old_ref (saved $(basename "$snap"))"
  image_id "$old_id" >/dev/null || die "the old image is no longer on this host; pull $old_ref by hand"
  # a moving tag (latest, a bare minor) now points at the new image: point it back
  docker tag "$old_id" "$old_ref" || die "could not re-tag the old image"
  git -C "$ROOT" checkout -q "$old_commit" -- docker-compose.yml || die "could not restore docker-compose.yml"
  cid="$(cid_of "$svc")"
  [ -z "$cid" ] || docker stop "$cid" >/dev/null
  while IFS=$'\t' read -r n type src dst what mb; do
    [ "$what" = saved ] || continue
    # copy over what is there; files only the new version created are left alone
    if [ -d "$snap/mounts/$n" ]; then
      docker run --rm --network none -v "$snap/mounts:/s:ro" -v "$src:/d" "$HELPER" cp -a "/s/$n/." /d/ \
        || die "could not restore $dst"
    else
      docker run --rm --network none -v "$snap/mounts:/s:ro" -v "$src:/d" "$HELPER" sh -c "cat /s/$n > /d" \
        || die "could not restore $dst"
    fi
    say "  restored $dst"
  done < "$snap/mounts/mounts.tsv"
  deploy || die "deploy failed during rollback; the stack needs a person now"
  if settle_and_verify "$svc" "$old_id"; then
    say "rollback verified: $svc is back on $old_ref"
    if ! git -C "$ROOT" diff --quiet -- docker-compose.yml; then
      say "docker-compose.yml now differs from the branch on purpose. Revert the tag change"
      say "upstream, then: git -C $ROOT checkout docker-compose.yml && git -C $ROOT pull"
    fi
    return 0
  fi
  die "rollback did not verify; the stack needs a person now"
}

cmd_rollback() {
  local svc="${1:-}" snap
  [ -n "$svc" ] || die "usage: rollback <service>"
  need_tools; lock
  snap="$(newest_snapshot "$svc")"
  [ -n "$snap" ] || die "no saved state for $svc under $SNAPROOT"
  restore "$svc" "$snap"
}

cmd_apply() {
  local svc="${1:-}"
  [ -n "$svc" ] || die "usage: apply <service>"
  need_tools; lock
  local cid old_ref old_id old_commit new_ref new_id snap
  cid="$(cid_of "$svc")"; [ -n "$cid" ] || die "no container for service '$svc' in $ROOT"
  [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] \
    || die "the checkout has uncommitted changes; commit or discard them first"
  old_ref="$(docker inspect "$cid" --format '{{.Config.Image}}')"
  old_id="$(docker inspect "$cid" --format '{{.Image}}')"
  old_commit="$(git -C "$ROOT" rev-parse HEAD)"

  step "apply $svc"
  git -C "$ROOT" pull -q --ff-only || die "git pull failed"
  new_ref="$(compose_image "$svc")"; [ -n "$new_ref" ] || die "service '$svc' is not in docker-compose.yml"
  docker pull -q "$new_ref" >/dev/null || die "cannot pull $new_ref"
  new_id="$(image_id "$new_ref")"
  say "running: $old_ref"
  say "wanted:  $new_ref"
  if [ "$new_id" = "$old_id" ]; then
    say "already on that image; nothing to do"
    return 0
  fi
  if [ "$(git -C "$ROOT" rev-parse HEAD)" != "$old_commit" ]; then
    say "this deploy also applies everything else merged since the last one:"
    git -C "$ROOT" diff --stat "$old_commit" HEAD | sed 's/^/  /'
  fi

  snap="$SNAPROOT/$svc-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$snap" || die "cannot create $snap"
  printf 'service=%s\nimage_ref=%s\nimage_id=%s\ncommit=%s\nnew_ref=%s\n' \
    "$svc" "$old_ref" "$old_id" "$old_commit" "$new_ref" > "$snap/meta"
  save_mounts "$cid" "$snap/mounts"
  say "saved to $snap:"
  report_mounts "$snap/mounts/mounts.tsv" "saved"

  if ! deploy; then
    say "deploy command failed"
    restore "$svc" "$snap"; exit 1
  fi
  if settle_and_verify "$svc" "$new_id"; then
    say "verified: $svc is running $new_ref"
    # keep the newest $KEEP saved states of this service
    # shellcheck disable=SC2012
    ls -1d "$SNAPROOT/$svc"-[0-9]* 2>/dev/null | sort | head -n -"$KEEP" | while IFS= read -r old; do
      remove_tree "$old"
    done
    return 0
  fi
  say "verification failed; rolling back"
  restore "$svc" "$snap"
  exit 1
}

case "${1:-}" in
  precheck) shift; cmd_precheck "$@" ;;
  apply)    shift; cmd_apply "$@" ;;
  rollback) shift; cmd_rollback "$@" ;;
  *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
