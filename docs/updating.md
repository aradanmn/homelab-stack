# Updating a service

Nothing updates this stack by itself (no Watchtower, on purpose). The
daily maintainer sweep reports which images are behind; a person decides;
`scripts/stack-update.sh` does the mechanical part, with a check before
and a way back. This page is the whole procedure, as it was first run on
2026-11-23 for adguard-sync, Traefik, socket-proxy and AdGuard Home.

## Who does what

| Step | Who |
|---|---|
| Report that an image is behind | The daily sweep, under "Would propose" (report only) |
| Read the release notes, run the pre-check, open the tag pull request | Whoever does the update: a person, or a Claude session they asked |
| Approve | The owner, by merging the pull request (`master` accepts nothing else) |
| Apply, verify, check the service | The same operator, after the owner says go |

Nothing in this procedure runs on a timer, and an agent does not merge its
own tag pull request.

## Rules

- **One service per pull request, one merge at a time.** A deploy applies
  everything merged since the last one. Two merged tag changes restart
  two services in one go, and a failed verification rolls the compose
  file back for both.
- **Pin the exact version** (`traefik:3.7.19`, never `traefik:3.7`). The
  sweep compares the tag in `docker-compose.yml` with upstream; a tag that
  hides the patch level hides patch releases, which is where security
  fixes arrive.
- **Moving tags are the exception, not a choice.** Three images publish no
  exact version: socket-proxy (`3.4`, named after its HAProxy line,
  rebuilt weekly), Time Machine (`smb`) and Scrypted (`latest`). The sweep
  watches those by image digest or release date. They have no tag to
  change, so they skip step 4 below.
- **A release on GitHub is not an image you can pull.** Registries lag by
  hours or days (Traefik 3.7.20), use another tag form (`0.3.0`, then
  `v0.4.0`), or never publish the tag (socket-proxy v0.6.0). The pre-check
  settles it: it fails when the tag cannot be pulled.
- **Dependent services go first.** Update the thing that talks to a
  service before the service: adguard-sync before AdGuard Home. Leave a
  day-old `.0` release alone unless it fixes something you need.

## Procedure

Run everything on the host, from the checkout.

### 1. Read the release notes

Every release between the running version and the target, plus the
project's migration notes if it has them. You are looking for: renamed or
removed settings, changed defaults, one-way migrations of config or data,
and anything about the features this stack uses (the service's block in
`docker-compose.yml` and, for Traefik, `rules/`). Write down what applies
and why the rest does not; it goes in the pull request.

### 2. Pre-check

```
scripts/stack-update.sh precheck <service> <image:tag>
```

Nothing running is touched. The current image and then the new one run in
a sandbox: same command, environment and read-only mounts, every writable
mount a copy, no network, no published ports. It prints whether the new
version stays up, the log lines that look like trouble, and which files it
rewrote in the copy.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | PASS: the new version starts on a copy of the live config | Read the log lines and the changed files anyway |
| 1 | FAIL: the current version stays up in the sandbox, the new one does not | Stop; the release notes will say why |
| 3 | INCONCLUSIVE: the current version cannot run in the sandbox either (Glances) | Rely on the release notes and on step 6 |
| 2 | The check could not run; most often the tag cannot be pulled | Look up which tags the registry really has |

When the new version rewrites a config file, find out what changed before
going on: rerun with `--keep`, compare the two copies key by key, then
remove the kept directory with the command it prints. The copies can hold
secrets; compare names and structure, do not paste values anywhere.

The sandbox proves the new version reads the config and starts. It cannot
prove anything that needs the network or another service. Where that
matters, test it directly in a throwaway container (for socket-proxy:
start the new image with the same settings and confirm which Docker API
paths answer 200 and which 403).

### 3. Record a baseline

Write down what "working" looks like now, so step 6 is a comparison and
not an impression:

| Service | Baseline |
|---|---|
| traefik, socket-proxy | Status code of every routed host name, and the certificate's expiry date |
| adguard | An ordinary name resolves; a blocked name returns `0.0.0.0`; a local `*.home.example.com` name returns the host. On both DNS servers |
| adguard-sync | The last "Sync done" line in its log |
| anything else | Container up, and the one thing you use it for |

### 4. Open the tag pull request

One line in `docker-compose.yml`, on a branch. Put in the body: the
version change, the release-note findings from step 1, the pre-check
result, what the sandbox could not prove, and what will be interrupted
during the restart. The `leak-check` must pass. The owner merges.

### 5. Apply

After the merge, and after the owner says go:

```
scripts/stack-update.sh apply <service>
```

It pulls the checkout and the image, saves the service's writable mounts
under `appdata/.pre-update/<service>-<time>/`, restarts
`homelab-stack.service`, waits, and verifies: the container runs the new
image, has not restarted, is not unhealthy, and (AdGuard, Traefik)
answers a DNS or HTTPS request. If verification fails it rolls back by
itself and exits 1.

Mounts over 200 MB are treated as data and not saved. When the new
version may migrate its data (a major version, a new storage format),
raise the limit for that run so the data is saved and can be restored:

```
STACK_COPY_LIMIT_MB=3000 scripts/stack-update.sh apply adguard
```

"already on that image; nothing to do" means exactly that. It is also the
answer when only the tag name changed (pinning `3.7` to `3.7.19`): the
container is then recreated under the new name by the next deploy of
anything, with a few seconds' interruption.

### 6. Check against the baseline

Repeat step 3 and compare. Then read the service's log for errors
(`docker logs <container> --since 10m`) and check what the release notes
said would change. For AdGuard, restart `adguard-sync` or wait for its
next run and confirm "Sync done". For Traefik and socket-proxy, one
"Provider error ... EOF" at the moment socket-proxy restarts is the
connection dropping; what matters is that requests answer 200 afterwards.

### 7. Rolling back later

```
scripts/stack-update.sh rollback <service>
```

puts back the newest saved state: the previous compose file, the previous
image (also for a moving tag) and the saved mounts. It leaves
`docker-compose.yml` different from the branch on purpose; revert the tag
change in a pull request, then run the two commands it prints.

## Notes per service

| Service | Interrupted during the restart | Remember |
|---|---|---|
| traefik | Every web route, a few seconds | Read the v3 migration notes for each patch in between |
| socket-proxy | Nothing visible; Traefik stops seeing container changes for a few seconds | Moving tag `3.4`: apply again to take a newer build |
| adguard | DNS on this server, a few seconds; clients fall back to the replica | Save `work/` too (limit above). The config file is migrated on first start and the old version may not read it back. The replica is the Home Assistant add-on and updates from Home Assistant, not from here; the sync logs "Versions do not match" until both agree |
| adguard-sync | Nothing; it runs every 10 minutes | Update it before AdGuard Home |
| glances | The host metrics Home Assistant reads | Pre-check is always inconclusive |
| timemachine | A running backup | Moving tag `smb`; check a real backup from the Mac afterwards (see services.md) |
| scrypted | Cameras in the Home app | Moving tag `latest`; its volume is not saved unless the limit is raised |

## What the tool does not cover

- **Large writable mounts are not saved** unless the limit is raised.
  Otherwise the nightly restic backup is their only copy.
- **The pre-check has no network.** See step 2.
- **A deploy applies everything merged**, not only the one tag; apply
  lists the other changes before it restarts the unit.
- **Saved states are pruned only by later applies:** the three newest per
  service are kept. A saved data directory stays on disk until then.
- **The verification is small on purpose.** Step 6 is not optional.

`scripts/tests/test_stack_update.sh` runs the tool against a throwaway
compose project, including an update that fails and is rolled back.
