#!/bin/bash
# Fail if site-specific detail is in the tracked files of a commit.
#
#   scripts/leak-check.sh [<commit>]      (default HEAD)
#
# This repo is public. Real addresses, the real domain and personal notify
# targets live in the untracked .env and in Home Assistant, never here.
# Built-in patterns cover the generic shapes. Site patterns that cannot be
# written in a public file (the real domain) come from:
#   - LEAK_EXTRA_PATTERNS  one extended regex per line (CI: a repository secret)
#   - DOMAIN in the checkout's .env, or the main checkout's when run from a
#     linked worktree, when that file exists (the live host)
# Matches are printed as file:line only, never the matching text.
# Exit 0 clean, 1 on a match, 2 if the check itself could not run.
set -uo pipefail
commit="${1:-HEAD}"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "leak-check: not a git checkout" >&2; exit 2; }
cd "$root" || exit 2
git rev-parse --verify -q "$commit^{commit}" >/dev/null || { echo "leak-check: no such commit: $commit" >&2; exit 2; }

site=""
if [ -n "${LEAK_EXTRA_PATTERNS:-}" ]; then site="$LEAK_EXTRA_PATTERNS"; fi
# .env of this checkout, else of the main checkout when this is a linked worktree
env_file=.env
[ -r "$env_file" ] || env_file="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.env"
if [ -r "$env_file" ]; then
  d="$(sed -n 's/^DOMAIN=//p' "$env_file" | tail -n 1)"
  if [ -n "$d" ]; then site="$site
$(printf '%s' "$d" | sed 's/[.]/[.]/g')"; fi
fi

hits=0
scan() {  # $1 label, $2 regex, $3 optional regex of allowed matches
  local out rc
  out="$(git grep -nIE -e "$2" "$commit" -- . 2>&1)"; rc=$?
  if [ $rc -gt 1 ]; then echo "leak-check: git grep failed for '$1'" >&2; exit 2; fi
  if [ -n "${3:-}" ]; then out="$(printf '%s\n' "$out" | grep -vE -e "$3")"; fi
  out="$(printf '%s\n' "$out" | sed '/^$/d' | cut -d: -f2,3)"
  if [ -n "$out" ]; then
    hits=1
    printf '%s\n' "$out" | sed "s/^/LEAK ($1): /"
  fi
}

# Built-in patterns, written so that this file does not match itself.
scan "private address"          '192\.168\.[0-9]+\.[0-9]+'
scan "address in an entity id"  '192[_]168_[0-9]+'
scan "personal notify target"   'mobile_app[_][a-z0-9*]' 'mobile_app[_](your_|second_|\*)'
scan "personal mail address"    '[A-Za-z0-9._-]+@(gmail|icloud|outlook|yahoo|hotmail)[.]com'
# Hardware addresses: only the documentation range (RFC 7042) and its
# locally administered twin may appear.
scan "hardware (MAC) address"   '([0-9A-Fa-f]{2}[:]){5}[0-9A-Fa-f]{2}' '0[02]:00:5[eE]:00:53:[0-9A-Fa-f]{2}'

n=0
while IFS= read -r re; do
  [ -n "$re" ] || continue
  n=$((n+1))
  scan "site pattern $n" "$re"
done <<<"$site"

if [ $hits -ne 0 ]; then
  echo "leak-check: FAILED. Move the value to .env or Home Assistant's secrets.yaml." >&2
  exit 1
fi
echo "leak-check: clean ($commit, 5 built-in and $n site patterns)"
