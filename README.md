# homelab-stack

Everything that runs on the one homelab host, `homelab` (10.0.10.10,
Debian 13 + Docker), as a single Docker Compose project: Traefik with a
wildcard certificate, AdGuard DNS, Glances for Home Assistant's host
monitoring, the Time Machine share and Scrypted. Plus
the handful of native systemd units that fetch secrets and run backups.
The Minecraft server is the separate `minecraft-stack` repo on the same host.

Addresses (`10.0.<vlan>.<host>`) and the domain (`home.example.com`) in
these docs are examples. The real values live in the untracked `.env` (see
`.env.example`) and in Home Assistant's `secrets.yaml`.
`scripts/leak-check.sh` fails if a real one gets into a tracked file; CI runs
it on every push and pull request.

Written by Claude (Anthropic's Claude Code); see Authorship below.

## Where things are

| | |
|---|---|
| `docker-compose.yml` | every container, one file |
| `rules/routers.yml` | Traefik routes to backends that are not containers (UniFi, Home Assistant, BlueMap) |
| `appdata/` | each service's config and data; config without secrets is tracked, data and secrets are not |
| `scripts/` | the native units and the collector scripts they run |
| `timemachine/` | the Samba and Avahi config carried over from the old Time Machine host |
| `docs/services.md` | **what each service is for, how to reach it, where its data is, how to check and update it** |
| `docs/host-bootstrap.md` | **rebuild the host from bare metal, step by step** |
| `docs/secrets.md` | how secrets reach the stack from Bitwarden Secrets Manager without touching disk |
| `docs/home-assistant.md` | **the HA Green: what is configured where, the dashboards, the NAS integration, how to recreate it all** |
| `home-assistant/` | a snapshot of the HA Green's config files and dashboards (HA is the live copy); see its README |

## Day to day

```
cd /home/claude/workspace/homelab-stack
git pull --ff-only
sudo systemctl restart homelab-stack.service      # docker compose up -d with the secrets env; only changed containers restart
docker compose ps                                  # everything Up
docker logs <container> --since 1h
```

- **Change a service:** edit `docker-compose.yml` on a branch, open a PR,
  merge, then the three lines above. Pin image tags; never `:latest`
  except Scrypted, which ships nothing else.
- **Rotate a secret:** change it in the vault, then
  `sudo systemctl restart homelab-stack-secrets.service homelab-stack.service`.
- **Add a web UI:** give the container `traefik.*` labels like the others.
  DNS needs nothing; one wildcard rewrite in AdGuard sends every
  `*.home.example.com` name to this host.
- **Alerts** are Home Assistant alerts pushed to the companion app (`docs/alerting.md`); the daily maintainer sweep
  posts to Mattermost. Nothing else reports.

## Versioning

Each meaningful change gets a git tag (`vX.Y.Z`, semver-ish) as well as its
commit, so `git log --oneline --decorate` shows what changed when, and
`git checkout <tag>` before `docker compose up -d` deploys a known-good
point. `v1.0.0` is the 2026-09-13 cutover from Nginx Proxy Manager.

## Authorship

The compose file, routing rules, collector scripts, systemd units and
these docs were written by Claude (Anthropic's Claude Code) in sessions
driven by Scott Dean, who set the goals, made every design decision
(what to run, what to retire, how addresses and secrets are handled),
tested each change on the live network and reviewed and merged the
pull requests. Chat transcripts behind the decisions are archived in the
private `claude_sessions` repo.
