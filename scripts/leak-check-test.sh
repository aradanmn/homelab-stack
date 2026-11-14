#!/bin/bash
# Test for leak-check.sh: a clean tree passes, each kind of leak fails, and a
# failure never prints the leaked text. Fixtures are built at run time so this
# file holds no text the check would flag.
set -uo pipefail
check="$(cd "$(dirname "$0")" && pwd)/leak-check.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cd "$tmp" && git init -q . && git config user.email t@example.com && git config user.name t
fail=0
commit() { git add -A && git commit -q -m x; }
expect() {  # $1 want rc, $2 name, rest: env assignments for the check
  local want=$1 name=$2; shift 2
  out="$(env "$@" "$check" 2>&1)"; rc=$?
  if [ $rc -eq "$want" ]; then echo "ok   $name"; else echo "FAIL $name (rc $rc, want $want)"; fail=1; fi
}
oct=168
echo "host at 10.0.10.10, notify.phones, mobile_app_your_phone, a@example.com, 00:00:5e:00:53:01, 02:00:5e:00:53:40" > clean.md; commit
expect 0 "clean tree passes" A=1
for kind in "addr:192.$oct.10.10" "entity:sensor.192_${oct}_10_10_cpu" "notify:mobile_app_""janes_phone" "mail:someone@""gmail.com" "mac:c4:65:16:""ab:74:99"; do
  echo "x ${kind#*:} y" > leak.md; commit
  expect 1 "${kind%%:*} is caught" A=1
  case "$out" in *"${kind#*:}"*) echo "FAIL ${kind%%:*}: output prints the leaked text"; fail=1;; esac
  git rm -q leak.md; commit
done
echo "see nas.home.private-site.test" > site.md; commit
expect 0 "site name passes without a site pattern" A=1
expect 1 "site name is caught with LEAK_EXTRA_PATTERNS" LEAK_EXTRA_PATTERNS='private-site[.]test'
printf 'DOMAIN=home.private-site.test\n' > .env; echo .env > .gitignore; commit
expect 1 "site name is caught through DOMAIN in .env" A=1
git worktree add -q "$tmp-wt" HEAD
( cd "$tmp-wt" && out="$("$check" 2>&1)"; [ $? -eq 1 ] ) && echo "ok   linked worktree uses the main checkout's .env" || { echo "FAIL linked worktree"; fail=1; }
git worktree remove --force "$tmp-wt"
rm .env; git rm -q site.md; commit
out="$("$check" no-such-commit 2>&1)"; [ $? -eq 2 ] && echo "ok   bad commit exits 2" || { echo "FAIL bad commit"; fail=1; }
exit $fail
