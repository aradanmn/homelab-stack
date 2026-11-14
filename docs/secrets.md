# Secrets

How every secret reaches the stack and the `claude` user without ever
being a file in this repo or a plain file on disk. Moved verbatim from the
README on 2026-11-06. On the Debian host (claude_sessions#37) the paths
are the same; the only changes are the checkout location,
`/home/claude/workspace/homelab-stack`, and one more fetched file,
`timemachine.env`, for the Time Machine container.

## Secrets from BWS at runtime (claude_sessions#24, 2026-10-29)

Nothing in this tree holds a secret any more. `scripts/homelab-stack-secrets.service`
(root) decrypts the host's one bootstrap secret, the BWS machine-account
token kept as an encrypted systemd credential, fetches five whole-file
secrets into `/run/homelab-stack/` (tmpfs, root 0700) before `docker.service`
starts, and saves the same bundle as an encrypted credential under
`/var/lib/homelab-stack/` so a reboot without internet still brings the
stack up (it logs a WARNING when it had to use the fallback).
`scripts/homelab-stack.service` then runs `docker compose --env-file .env
--env-file /run/homelab-stack/env up -d`: `.env` in the checkout holds the
site settings (addresses, domain; not secret, not committed, see
`.env.example`), the second file the secrets. The compose file bind-mounts the three
exporter configs and the HA token from the runtime directory.

Vault, once: BWS project `homelab-stack`, machine account `homelab-stack` (named after the project it reads) with Can read on that project only, and these
secrets, each holding the whole file's bytes:

| BWS secret | File it replaces |
|---|---|
| `homelab-stack-env` | `.env` (CF_DNS_API_TOKEN) |
| `monitoring-adguard-exporter-env` | `appdata/adguard-exporter/env` (already in the vault) |
| `monitoring-unpoller-up-conf` | `appdata/unpoller/up.conf` (already) |
| `monitoring-ha-scrape-token` | `/run/homelab-stack/ha_scrape_token`, stored without a trailing newline; since 2026-11-07 read only by `scripts/ha_mark_success.sh` (restic success into Home Assistant), the Prometheus scrape is gone |
| `timemachine-env` | `timemachine.env`: `PASSWORD=` for the Time Machine share user |
| `adguardhome-sync-env` | `adguardhome-sync.env`: `ORIGIN_USERNAME=` and `ORIGIN_PASSWORD=` (the AdGuard login) for the `adguard-sync` container |
| `restic-env` | `restic.env`: `RESTIC_REPOSITORY=` and `RESTIC_PASSWORD=` for the restic backups (host-bootstrap section 10) |

Host, as root on LXC 101, in a plain root shell:

```
install -d -m 0755 /usr/local/lib/homelab-stack
install -m 0755 /home/claude/homelab-stack/scripts/fetch_secrets.sh /usr/local/lib/homelab-stack/fetch_secrets.sh
install -m 0644 /home/claude/homelab-stack/scripts/homelab-stack-secrets.service /home/claude/homelab-stack/scripts/homelab-stack.service /etc/systemd/system/
install -d -m 0700 /etc/homelab-stack
systemd-creds encrypt --name=bws-token - /etc/homelab-stack/bws-token.cred     # paste the `homelab-stack` machine-account access token, Enter, Ctrl-D
chmod 0600 /etc/homelab-stack/bws-token.cred
systemctl daemon-reload && systemctl enable --now homelab-stack-secrets.service && systemctl status homelab-stack-secrets.service --no-pager | tail -3
```

Expect "wrote 7 files to /run/homelab-stack from BWS; fallback bundle
refreshed". Then deploy from the runtime secrets, which recreates only the
four containers whose mounts moved:

```
systemctl enable --now homelab-stack.service && docker compose ps --format '{{.Name}}\t{{.Status}}'
```

When every container is Up, remove the on-disk copies and the old `.env`:
`shred -u .env` (the exporter and Prometheus secret files were removed with those services on 2026-11-07).
From then on the deploy command after a `git pull` is
`sudo systemctl restart homelab-stack.service`; give the `claude` user that
one sudo rule. Rotation is a vault edit followed by the same restart.

`docker.service` itself is ordered after the secrets unit by a drop-in: at
boot the restart policies bring every container back before
`homelab-stack.service` runs, and Docker creates an empty directory at a
missing bind source, so the daemon has to wait for the tmpfs too
(`scripts/docker.service.d/homelab-stack-secrets.conf`: `Wants=` and
`After=` for the ordering, and an `ExecStartPre=` that refuses to start
Docker while `/run/homelab-stack/env` is missing, so a re-fetch never
takes Docker down but a failed fetch keeps it from starting):

```
install -d -m 0755 /etc/systemd/system/docker.service.d
install -m 0644 /home/claude/homelab-stack/scripts/docker.service.d/homelab-stack-secrets.conf /etc/systemd/system/docker.service.d/
systemctl daemon-reload && systemctl show docker.service -p Wants -p After -p ExecStartPre | grep -c homelab-stack    # expect 3
```

Mattermost (and its `config.json` with the embedded DSN) was retired 2026-11-07.

### LXC 105: the `claude` user's `~/.secrets` (claude_sessions#24 step 4b)

Same pattern, different consumers: on 105 the digest, heartbeat and
device-check timers and two backup scripts
all read whole-file secrets from `/home/claude/.secrets`, and none of them
change. The directory becomes a tmpfs (`scripts/home-claude-.secrets.mount`,
claude 0700, 1 MiB) that `scripts/claude-secrets.service` (root) populates
at boot through `scripts/fetch_claude_secrets.sh` from the `claude`
machine account, with the same encrypted fallback bundle under
`/var/lib/claude-secrets/`. `scripts/docker.service.d/claude-secrets.conf`
makes `docker.service` start after it, without ever stopping Docker on a
re-fetch (its fail-closed check on `netbot-bots-token` was removed
2026-11-01 with the bots). Files are
written byte-for-byte; the bootstrap token itself is written to
`bitwarden-secretsmanager-token` so interactive `bws` keeps working.

| file | BWS secret(s) | consumers |
|---|---|---|
| `homeassistant` | claude `homeassistant` | check-new-ha-devices, `HA_TOKEN` for the `homeassistant` MCP server in Claude Code (`~/.bashrc`) |
| `minecraft-stack.env` | claude `minecraft-stack-env` (one `RCON_PASSWORD=...` line) | minecraft-stack `docker-compose.yml`, through the `.env` symlink |
| `healthchecks-ping-url` | claude `healthchecks-ping-url` (optional since 2026-11-07) | copied once into Home Assistant `secrets.yaml` (dead-man ping automation); nothing on this host reads it any more, delete the vault entry when convenient |
| `reolink` | claude `reolink` | `~/doorbell-collect` collect.py, pull_hist.py, zone.py (run by hand) |
| `bitwarden-secretsmanager-token` | the unit's own credential | interactive `bws` |
| `gh-token.env` | claude `github-token-claude-lxc105` (classic PAT, `repo project read:org`), written as one `GH_TOKEN=...` line | `gh` in interactive sessions and in `render_session.py`'s SessionEnd/UserPromptSubmit hooks, through `~/.profile` and the two user units below (#24 step 4d) |
| `unifi` | optional, same name | none automated (interactive UniFi API); absent from the vault means absent from the tmpfs |

The first rows and the gh token are
required: a missing one fails the fetch and the bundle is used. The optional ones are skipped
with a journal line when the vault has no entry, and a file an earlier fetch
wrote is removed, so retiring a file is a vault deletion.
Not fetched at all, removed with the rest at step C: `lxc-root-passwords`
(moves to Scott's password vault) and the `bw` CLI trio `bw-session`,
`bitwarden-homelab-clientid`, `bitwarden-homelab-clientsecret` (Scott does
not use `bw` on 105). `grafana-alerting-snapshot.service` is dead (script
missing, no timer) and is left for a separate cleanup.
`scripts/tests/test_fetch_claude_secrets.sh` runs the script without root
against a stub vault.

Vault, once: machine account `claude` already exists (Can read on the
`claude` project only); create `healthchecks-ping-url` and `reolink`
in `claude` with the current files' bytes.

Host, as root on LXC 105 (step C; the mount hides the on-disk files from
the moment it starts, it does not delete them; the mount unit carries
`uid=1000,gid=1000`, so confirm `id -u claude` prints 1000 first):

```
install -d -m 0755 /usr/local/lib/claude-secrets /etc/systemd/system/docker.service.d
install -m 0755 /home/claude/workspace/homelab-stack/scripts/fetch_claude_secrets.sh /usr/local/lib/claude-secrets/fetch_secrets.sh
install -m 0644 /home/claude/workspace/homelab-stack/scripts/claude-secrets.service /home/claude/workspace/homelab-stack/scripts/home-claude-.secrets.mount /etc/systemd/system/
install -m 0644 /home/claude/workspace/homelab-stack/scripts/docker.service.d/claude-secrets.conf /etc/systemd/system/docker.service.d/
install -d -m 0700 /etc/claude-secrets
systemd-creds encrypt --name=bws-token - /etc/claude-secrets/bws-token.cred     # paste the `claude` machine-account token, Enter, Ctrl-D
chmod 0600 /etc/claude-secrets/bws-token.cred
systemctl daemon-reload && systemctl enable --now home-claude-.secrets.mount claude-secrets.service && journalctl -u claude-secrets -n 3 --no-pager
```

Expect "wrote N files to /home/claude/.secrets from BWS; fallback bundle
refreshed" and `ls -la /home/claude/.secrets` all claude 0600. Then run each
consumer once from the tmpfs: `systemctl start daily-digest-dryrun
alerting-heartbeat check-new-ha-devices grafana-config-backup` (or wait for
the timers). Only when every consumer has
succeeded, remove the on-disk copies underneath the mount without
unmounting (an unmount would expose them again until the next fetch):

```
mount --bind / /mnt && shred -u /mnt/home/claude/.secrets/* && umount /mnt
```

`bitwarden-secretsmanager-token` goes last, once an interactive `bws` call has
read its tmpfs copy.
From then on rotation is a vault edit followed by
`systemctl restart claude-secrets.service`. Finish step C with a reboot so
the boot ordering is proven.

#### Step 4d: `gh` without `~/.config/gh/hosts.yml`

Only two things on 105 call `gh` as claude: interactive sessions and
`scripts/render_session.py` (issue suggestions in the archive hooks, and the
backfill timer). `gh` prefers `GH_TOKEN` in its environment over
`hosts.yml`, so the token moves into the tmpfs and the OAuth token is
revoked. It has to be a classic PAT: `gh project item-add` needs the
`project` scope, which fine-grained tokens cannot carry. The file is an
env file, not a bare value, because a user unit does not read
`~/.profile`: sessions started from the phone run inside
`claude-remote-control.service`, and the backfill runs inside
`claude-archive-backfill.service`, and both inherit their environment from
the user manager. Without the drop-ins below, deleting `hosts.yml` would
silently break issue filing for every phone-started session.

Vault, once (Scott): a classic PAT with `repo`, `project`, `read:org`, one
year expiry, stored in the `claude` project as `github-token-claude-lxc105`; add the
expiry to `claude_sessions/docs/expiry-registry.md`.

Host, in this order. As root:

```
install -m 0755 /home/claude/workspace/homelab-stack/scripts/fetch_claude_secrets.sh /usr/local/lib/claude-secrets/fetch_secrets.sh
systemctl restart claude-secrets.service && journalctl -u claude-secrets -n 2 --no-pager   # "wrote N files", N one higher than before
ls -la /home/claude/.secrets/gh-token.env                                               # claude 0600
```

As claude. `~/.profile` gets, after the `.bashrc` block:

```
# claude_sessions#24 step 4d: gh reads GH_TOKEN from the secrets tmpfs
if [ -r "$HOME/.secrets/gh-token.env" ]; then
    set -a; . "$HOME/.secrets/gh-token.env"; set +a
fi
```

and both user units get the same drop-in (`EnvironmentFile=-` so a missing
file leaves the unit running without a token rather than failing it):

```
for u in claude-remote-control claude-archive-backfill; do
  install -d ~/.config/systemd/user/$u.service.d
  printf '[Service]\nEnvironmentFile=-/home/claude/.secrets/gh-token.env\n' > ~/.config/systemd/user/$u.service.d/gh-token.conf
done
systemctl --user daemon-reload
systemctl --user restart claude-archive-backfill.timer
systemctl --user restart claude-remote-control.service      # ends any live phone session: do it between sessions
```

Verify, in a new login shell: `gh auth status` must say the token comes
from `GH_TOKEN`, `gh api user -q .login` prints `aradanmn`, and
`systemctl --user show-environment` still has no `GH_TOKEN` (it is per
unit, not global). Then one end-to-end run of the real path: let a session
end (or `systemctl --user start claude-archive-backfill.service` with a
transcript waiting) and confirm a new line in
`sessions/.state/issue-suggestions.jsonl` with `applied: true`, or the
`gh issue comment` it made. Only after that:

```
rm ~/.config/gh/hosts.yml        # gh now has exactly one credential source
```

and Scott revokes the old OAuth token at github.com/settings/applications
(the "GitHub CLI" authorization). Nobody runs `gh auth login` on 105 again;
it would recreate `hosts.yml` and `gh` would ignore it anyway while
`GH_TOKEN` is set. Rotation afterwards: new PAT in the vault, `systemctl
restart claude-secrets.service`, new login shell; running units pick it up
on their next start.
