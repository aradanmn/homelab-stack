# Updating a service

Nothing updates this stack by itself. The daily maintainer sweep reports
which images are behind upstream; a person decides, and
`scripts/stack-update.sh` does the mechanical part with a check before and
a way back. One service per change.

## Procedure

1. **Read the release notes** for every version between the running one
   and the target. Look for renamed settings, removed options and one-way
   data migrations.
2. **Pre-check** on the host. Nothing running is touched:

   ```
   scripts/stack-update.sh precheck <service> <image:tag>
   ```

   It runs the current image and then the new one in a sandbox: same
   command, environment and read-only mounts, every writable mount a
   copy, no network, no published ports. It reports whether the new
   version stays up, the log lines that look like trouble, and which
   files it rewrote in the copy. Exit 0 is a pass, 1 means the new
   version does not stay up, 3 means inconclusive (the current version
   cannot run in the sandbox either, as with Glances). It also fails if
   the tag cannot be pulled: an upstream release is not always published
   under the same tag name, or at all.
3. **Change the tag** in `docker-compose.yml` on a branch and open a pull
   request with the pre-check result in the body. Merging it is the
   approval. A moving tag (`latest`, a bare minor such as `3.6`, `smb`)
   needs no tag change; skip to step 4.
4. **Apply** on the host, when someone is there to watch:

   ```
   scripts/stack-update.sh apply <service>
   ```

   It pulls the checkout and the image, saves the service's writable
   config under `appdata/.pre-update/<service>-<time>/`, restarts
   `homelab-stack.service`, waits, and verifies: the container is
   running the new image, has not restarted, is not unhealthy, and (for
   AdGuard and Traefik) answers a DNS or HTTPS request. If verification
   fails it rolls back by itself and exits 1. Running it again when
   nothing changed is a no-op.
5. **Look yourself.** The verification is deliberately small. Open the
   service and check what the release notes said would change.

## Rolling back later

```
scripts/stack-update.sh rollback <service>
```

puts back the newest saved state: the previous compose file, the previous
image (also for a moving tag) and the saved config. It leaves
`docker-compose.yml` different from the branch on purpose; revert the tag
change in a pull request, then follow the two commands it prints.

## What it does not cover

- **Large writable mounts are not saved.** Anything over 200 MB is
  treated as data (AdGuard's `work/`, Scrypted's volume): the pre-check
  gives the trial an empty directory there and apply does not copy it.
  The nightly restic backup is the only copy, so a new version that
  migrates its data in place can only be undone from restic.
- **The trial has no network.** It proves the new version reads the
  config and starts. It does not prove upstream DNS, certificate
  renewal, or that two services still talk to each other
  (adguard-sync against a new AdGuard, Traefik against a new
  socket-proxy).
- **A deploy applies everything merged**, not only the one tag; apply
  lists the other changes before it restarts the unit.
- **The three newest saved states per service are kept**; older ones are
  removed after a verified apply.

`scripts/tests/test_stack_update.sh` runs the whole thing against a
throwaway compose project, including an update that fails and is rolled
back.
