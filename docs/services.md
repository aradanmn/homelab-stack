# Services

One entry per container in `docker-compose.yml`, plus the native pieces on
the host. For each: what it is for, how you reach it, where its data
lives, which secret it needs, how to update it, how to check it. Paths are
relative to the checkout, `/home/claude/workspace/homelab-stack`. The
host is `homelab`, 10.0.10.10 (claude_sessions#37); "the controller"
is UniFi at `https://10.0.1.1`.

**Conventions that apply to every service**

- Reach it through Traefik at `https://<name>.home.example.com`. The
  names resolve through one wildcard rewrite in AdGuard
  (`*.home.example.com` to 10.0.10.10).
- Update: edit the image tag in `docker-compose.yml`, commit, then
  `sudo systemctl restart homelab-stack.service`. That runs
  `docker compose up -d` with the secrets env file; only changed
  containers restart.
- Logs: `docker logs <container> --since 1h`.
- Data under `appdata/<service>/` is gitignored and backed up nightly by
  restic to the NAS (`/mnt/mimir-backups/restic`).
- Secrets are fetched from Bitwarden Secrets Manager into
  `/run/homelab-stack/` at boot; see [secrets.md](secrets.md).

## traefik

- **For:** the only thing listening on 80 and 443. Routes every
  `*.home.example.com` name to a container or a non-container backend,
  and holds the wildcard TLS certificate.
- **Reach:** `https://traefik-web.home.example.com` (dashboard, read-only).
- **Routes:** containers in this stack carry `traefik.*` labels in the
  compose file. Backends that are not containers (UniFi, Home Assistant,
  BlueMap on the Minecraft stack) are in `rules/routers.yml`.
- **Certificate:** issued and renewed by Traefik itself through Cloudflare
  DNS-01, stored in `appdata/traefik/acme.json`. Needs
  `CF_DNS_API_TOKEN` from the secrets env file. Renews 30 days before
  expiry; nothing to do by hand. If `acme.json` is lost, a fresh one is
  issued at the next start in about a minute.
- **Check:** the dashboard shows every router green;
  `curl -sI https://grafana-web.home.example.com | head -1` is `200`.

## socket-proxy

- **For:** lets Traefik read container labels without mounting the Docker
  socket into Traefik. Internal network only, no ports.
- **Check:** `docker logs socket-proxy` is quiet; Traefik's dashboard
  lists the Docker provider.

## adguard

- **For:** the house DNS and ad blocking. Primary resolver handed out by
  DHCP (DNS 1 = 10.0.10.10); the AdGuard add-on on Home Assistant Green
  (10.0.10.20) is DNS 2, kept identical by the `adguard-sync` container in this stack.
- **Reach:** `https://adguard.home.example.com` (also `ns1-web`).
  Port 53 is published on the host; the web UI is only behind Traefik.
- **Data:** `appdata/adguard/conf/AdGuardHome.yaml` (the config; a copy
  is pulled nightly into `claude_sessions/adguard-backup/`),
  `appdata/adguard/work/` (filters, stats, query log).
- **Host needs:** port 53 free (`DNSStubListener=no` in
  `/etc/systemd/resolved.conf.d/homelab.conf`) and the host's own
  resolver pointed at 10.0.10.20, never at this container.
- **Secret:** none for the container.
- **Check:** `dig +short @10.0.10.10 adguard.home.example.com`
  answers `10.0.10.10`; the UI shows queries arriving.

## glances

- **For:** host CPU, memory, load, disk and per-container state for the
  Home Assistant `glances` integration (host `10.0.10.10`, port 61208,
  no auth, API v4). Added 2026-11-07 when Prometheus, Grafana and the
  exporters were retired (claude_sessions#38): Home Assistant is the
  alerting engine now, see `docs/alerting.md`.
- **Reach:** `http://10.0.10.10:61208/api/4/status` on the LAN only;
  not behind Traefik because the API has no authentication.
- **Config:** none. `pid: host` and the read-only `/:/rootfs` mount give
  it the host's processes and the root filesystem; Docker through
  `socket-proxy` (`DOCKER_HOST=tcp://socket-proxy:2375`).
- **Check:** `curl -s http://10.0.10.10:61208/api/4/containers | jq length`
  matches `docker ps | wc -l`; in Home Assistant the Glances device shows
  the containers.

## timemachine

- **For:** the Samba share the Macs back up to with Time Machine. The
  disk is the WD My Book on USB, mounted on the host at `/mnt/timemachine`.
- **Reach:** the Mac finds "homelab" in Finder by Bonjour; the host's
  avahi-daemon advertises it with `timemachine/avahi-timemachine.service`
  installed as `/etc/avahi/services/timemachine.service`. Port 445 is
  published on the host.
- **Config:** environment in the compose file. The 1460 GB cap
  (`VOLUME_SIZE_LIMIT`) is 80 percent of the disk. The original Samba
  config from LXC 104 is kept in `timemachine/` for reference.
- **Secret:** `timemachine.env` from BWS (`timemachine-env`): the share
  user's password.
- **Check:** `smbclient -L //10.0.10.10 -U tmuser` lists
  `TimeMachine`; System Settings, Time Machine on the Mac shows the last
  backup time moving.
- **Must confirm after any move or rebuild: ownership of the existing
  bundle.** `SET_PERMISSIONS=true` only fixes the top folder of the disk,
  not the files inside `*.sparsebundle`. After the 2026-11-07 move from
  LXC 104 the bundle was still owned by uid 101000 (the LXC's mapped
  root), so Samba (uid 1000) could connect and read but not write, and the
  Mac's backup failed with no useful error. Confirm with
  `docker exec timemachine su -s /bin/sh tmuser -c 'touch "/opt/tmuser/<Mac name>.sparsebundle/lock" && echo OK'`
  and `find /mnt/timemachine -xdev ! -uid 1000 | grep -v lost+found | wc -l`
  (must print 0). Fix: `docker exec timemachine chown -R 1000:1000 /opt/tmuser/`.
  Then start one real backup from the Mac; a green `smbclient` listing
  does not prove it can write.

## scrypted

- **For:** the Reolink doorbell into HomeKit Secure Video. Runs with host
  networking because HomeKit discovery is mDNS and the camera streams are
  RTP; its HomeKit plugin is pinned to the VLAN 40 address 10.0.40.107.
- **Reach:** `https://10.0.40.107:10443` (the Scrypted console; not
  behind Traefik, it is on the Media VLAN on purpose).
- **Data:** `appdata/scrypted/volume/` (every plugin and setting).
- **Update:** the vendor only publishes `:latest`, so
  `docker compose pull scrypted && docker compose up -d scrypted` when
  you choose to.
- **Check:** the console loads; the doorbell tile streams in the Home
  app. If the Home app shows no recording options, see claude_sessions#18.

## Home Assistant and the NAS (separate hardware, not containers)

- **For:** alerting, the Monitoring, Home and Sense Power dashboards, and
  monitoring the UGREEN NAS `mimir`. Runs on the HA Green, 10.0.10.20,
  not on this host.
- **Reach:** `https://ha-web.home.example.com` (Traefik route in
  `rules/routers.yml`); the NAS UI at `https://nas-web.home.example.com`
  (route to `10.0.10.40:9999`, homelab-stack#53) or `http://10.0.10.40:9999`.
- **Config:** lives on the Green. A readable snapshot is in
  `home-assistant/`; the runbook (what is where, how to change a dashboard,
  the NAS integration, how to recreate it all) is
  [home-assistant.md](home-assistant.md); alert rules are in
  [alerting.md](alerting.md).
- **Backups:** HA's own automatic backups to "This system" and Home
  Assistant Cloud; the restic backup of this host does not cover it.
- **Check:** `ssh ha 'ha core check'` is clean and the Monitoring dashboard
  shows 0 active problems.

## Native on the host (not containers)

| Unit | What | Source | Secret it reads |
|---|---|---|---|
| `homelab-stack-secrets.service` | fetches the stack's secrets into `/run/homelab-stack` before Docker | `scripts/` | the `lxc101` BWS token, an encrypted credential in `/etc/homelab-stack/` |
| `homelab-stack.service` | `docker compose up -d` with the secrets env | `scripts/` | |
| `claude-secrets.service` + `home-claude-.secrets.mount` | the `claude` user's `~/.secrets` tmpfs | `scripts/` | the `claude` BWS token in `/etc/claude-secrets/` |
| `avahi-daemon` | advertises the Time Machine share | Debian package | |
| `claude-remote-control.service` (user `claude`) | Claude Code sessions from the phone land here | `claude_sessions/maintainer/systemd/` | |
| `claude-archive-backfill.timer` (user `claude`, 30 min) | archives transcripts the session-end hook missed | same | |
| `maintainer-sweep.timer` (user `maintainer`, daily 05:30) | the report-only maintainer sweep, reports into Home Assistant (persistent notification + push) | `claude_sessions/maintainer/` | its own BWS token in `/etc/maintainer/` |

The Minecraft server is its own repo, `minecraft-stack`, checked out at
`/home/claude/workspace/minecraft-stack` on the same host (port 25565 on
the host, BlueMap behind Traefik as `map.home.example.com`).

## SSH from this host to SteamOS machines

`scripts/setup-claude-steamos.sh` lets user `claude` on this host SSH into a
SteamOS machine as `deck` (the Steam Decks, and the Framework PC since it
moved to SteamOS). Run it once on the SteamOS machine in Konsole:
`bash setup-claude-steamos.sh`. It installs the host's public key, sets a
`deck` password if none exists, and enables `sshd`. Then add a `Host` entry
to `~/.ssh/config` on this host. It came from the retired `infra` repo,
whose Proxmox and Bazzite variants were dropped with those installs.
