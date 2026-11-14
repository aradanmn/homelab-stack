# Alerting

Since 2026-11-07 Home Assistant is the alerting engine for the homelab
(claude_sessions#38). Prometheus, Grafana, the exporters and Pushover are
gone. Everything below lives in one file on the HA Green:
`/config/packages/monitoring.yaml` (loaded through `homeassistant: packages:`
in `configuration.yaml`). Edit it over `ssh ha`, run `ha core check`, then
`template.reload` for sensor changes (no restart). A new or changed `alert:`
entry needs `ha core restart`: the `alert` integration has no reload
action. Restarting HA also empties the bell, including the daily sweep
report (see [home-assistant.md](home-assistant.md), section 8). The
dashboard that shows all of this is the Monitoring dashboard,
`/config/dashboards/monitoring.yaml`; layout and how to change it are in
[home-assistant.md](home-assistant.md). A readable copy of both files is in
`home-assistant/` in this repo.

## How an alert is built

1. A **problem sensor**: a template `binary_sensor` with `device_class:
   problem` that is `on` when something is wrong, with `delay_on` carrying
   the old Grafana `for` duration. Sensors it reads are HA's own entities,
   or come from the `ping`, `cert_expiry`, `minecraft_server`, `glances`
   and REST integrations.
2. An **`alert:`** entry watching that sensor's `on` state. It sends to
   `notify.phones` (a notify group of companion-app phones, defined in
   the untracked `/config/packages/site.yaml`), repeats on
   the listed schedule until acknowledged in the app, and sends a
   done message when the sensor clears. The seven that must wake someone
   (internet, AdGuard, NAS down, NAS storage unhealthy, NAS plug off, radon fan
   stopped, aquarium pump stopped) carry
   `push.sound.critical: 1`, which
   bypasses Focus and Do Not Disturb (confirmed working 2026-11-07 for
   internet and AdGuard; the two NAS ones use the same setting and have not
   been fired for real; the radon fan and pump ones are new on 2026-11-09 and
   also unfired). The
   `alert` integration sends its `done_message` with the same `data`, so
   the "answering again" message of a critical alert is critical too.

## The alerts

| Alert | Fires when | Was (Grafana) |
|---|---|---|
| Internet down | ping 1.1.1.1 fails 2 min | Internet/WAN drop detected |
| AdGuard down | `adguard.home.example.com` login page not answering 3 min | Service probe failed |
| Minecraft server down | port 25565 status off 3 min | Service probe failed (tcp) |
| TLS certificate expiring | `ha-web` cert expires in < 14 days | TLS certificate expiring |
| Restic backup stale | `input_datetime.restic_backup_last_success` older than 36 h | Restic backup missed |
| AC / Furnace / Dryer running 90+ min | `sensor.<x>_running` at 1 for 90 min continuously | sustained runtime rules |
| Unexplained power over 1200 W | `sensor.home_energy_unexplained` above 1200 W for 20 min | sustained rise (was a 20 min average) |
| Unavailable entity spike | more than 25 entities `unavailable` for 2 h (healthy is 0 to 1). `unknown`, stateless domains (button, event, stt, tts, notify, siren) and the NAS integration's `ugreen_nas*` entities are not counted | > 150 for 2 h |
| Low battery device | any battery sensor below 15 % for 1 h | Home Assistant low battery device |
| NAS down | the `nas_ui` probe is not `on`, or the UGREEN integration's `server_status` is unavailable/unknown, for 5 min. The message includes the outlet's current draw (`sensor.nas_power_draw`), so "down, still drawing 20 W" (hung) reads differently from "0 W" (power lost) | new 2026-11-09 |
| NAS plug off (critical) | the NAS's Tapo outlet (`switch.unnamed_p316m_tapo_p316m_3_3`) is `off` for 1 min; repeats 15 then 60 min. Fires before "NAS down" can, and says why | new 2026-11-09 |
| NAS storage unhealthy | any pool, volume, disk or the server itself reports something other than `Normal`, for 5 min | new 2026-11-09 |
| NAS volume over 85 percent | volume 1 or volume 2 above 85 % full for 30 min | new 2026-11-09 |
| NAS running hot | CPU above 176 °F, or any disk above 122 °F, or UGOS's own temperature status non-zero, for 15 min | new 2026-11-09 |
| Radon fan stopped (critical) | the fan's plug draws under 20 W for 15 min (normal 56.7 to 59.4 W over a week) | new 2026-11-09 |
| Aquarium pump stopped (critical) | the pump's plug draws under 5 W for 15 min (normal 15.2 to 16.9 W over a week) | new 2026-11-09 |
| Stack container down | fewer than 10 containers running on homelab (Glances count) for 5 min; change the 10 in the package when the stack changes | new 2026-11-09 |
| HA backup stale | no successful HA backup for 36 h (`sensor.backup_last_successful_automatic_backup`) | new 2026-11-09 |
| UniFi device offline | any of the 9 UniFi devices (gateway, 3 switches, 5 APs) not `connected` for 5 min | new 2026-11-09 |
| Key device unavailable | doorbell camera, Sense, thermostat, radon plug or pump plug `unavailable` for 10 min | new 2026-11-09 |
| HA disk over 85 percent | the Green's data disk above 85 % for 30 min (`sensor.ha_disk_used`, a `command_line` sensor on `df /config`; about 63 % with backup retention at 3) | new 2026-11-09 |
| Time Machine disk over 85 percent | the Time Machine disk above 85 % for 30 min. The share is capped at 1,460 GB (80 % of the disk), so 85 % means something else fills it or the cap fails | new 2026-11-09 |

### The NAS rules (2026-11-09, claude_sessions#26)

The UGREEN NAS `mimir` is read by the Marketplace-installed UGREEN
integration ([home-assistant.md](home-assistant.md), section 3). Design
choices worth knowing:

- **Volumes, not pools.** The integration reports a pool's "used" equal to
  its "total", so the 85 % rule reads `sensor.nas_volume_1_used` and
  `sensor.nas_volume_2_used`, template sensors computed from the volume byte
  counts (Volume 1 was 52 %, Volume 2 69 % on 2026-11-09).
- **One outage, one alert.** "NAS down" covers the UI probe
  (`binary_sensor.nas_ui`, a direct REST probe of
  `http://10.0.10.40:9999/desktop/`, not through Traefik) and the
  integration losing the NAS (a failing login while the UI still answers).
  "NAS storage unhealthy" skips `unavailable`/`unknown` so an outage does
  not also fire it, and the unavailable-entity counter skips the NAS's
  ~200 entities for the same reason.
- **Temperatures are in °F** (HA runs imperial). UGOS's own
  `temperature_status_code` is the unit-independent second trigger.
- A UGOS reboot or update takes the NAS away for a few minutes; the 5
  minute delay is there so that does not page.
- No SMART attributes are exposed, only a per-disk status, so none of this
  warns about drive wear early.
- Not fired for real. The expressions were tested against live state, and a
  simulated "Degraded" status and a 125 °F disk both evaluate to a problem.

### More signals (2026-11-09)

Eight alerts for things that existed but nothing watched (container count, HA
backup age, radon fan, aquarium pump, UniFi devices, key devices, Time
Machine disk, the Green's own disk). Choices worth knowing: every rule **fails open** (an
`unavailable` or `unknown` reading is "cannot tell", never a problem, so a
flickering sensor does not page; a dead device is the job of "Key device
unavailable" and "UniFi device offline"); the two plug thresholds sit far
below a week of steady readings, and the pump's one dip to 0 W on 2026-11-03
shows the rule would have fired; and `sensor.updates_waiting` (count of
pending updates: HA core, OS, supervisor, add-ons, UniFi and doorbell
firmware, the UGREEN integration, UGOS) is **shown on Status, not alerted**,
because the patch cadence is monthly.

`sensor.monitoring_active_problems` counts every template `binary_sensor`
with `device_class: problem` that is on (all of this file's alert sensors),
and lists their names in the `active` attribute. It is a quick check for the
post-change checklist ([home-assistant.md](home-assistant.md), section 7). The
Monitoring dashboard's headline and Health table read the alert entities
instead, because an alert's state (`idle`, `on`, `off` = acknowledged) already
includes the sensor's and adds the acknowledgement.

Mattermost's probe was removed with Mattermost itself (2026-11-07).
Not carried over, on purpose: WiFi retry rates, weak RSSI and the 7-day
traffic baseline (unpoller analytics, blind since 2026-10-29, never
missed); the IDS/IPS count (the UniFi app notifies itself); open Repairs
(visible in the HA UI); host pending updates and failed systemd units
(the daily maintainer sweep reports them); the exporter-unreachable and
heartbeat-stale self-monitoring of the removed stack.

## Dead-man's switch

`automation.monitoring_healthchecks_dead_man_ping` calls
`rest_command.healthchecks_ping` every 15 minutes while
`binary_sensor.internet_down` is off. Healthchecks.io pages by its own
channel if the pings stop, so "HA is down" and "the internet is down"
both show up as silence. The ping URL is `!secret healthchecks_ping_url`
in HA's `secrets.yaml` (same value as the former `alerting-heartbeat`
timer used).

## Host metrics

`glances` (this compose file) exposes the host and container state on
`10.0.10.10:61208`; the HA `glances` integration polls it. That gives HA
the host's disk, memory, CPU, temperatures and a **count** of running
containers (`sensor.homelab_containers_active`, 10 on 2026-11-09).
Disk, memory and the container count have alerts. The count alert says
that *a* container is down, not which; `docker compose ps` on the host
does. The `docker-stack-health`
collector that was meant to provide `sensor.docker_stack_down` and
`sensor.docker_images_behind` never shipped: it is the unmerged branch
`docker-stack-health`, there is no timer for it on the host, and neither
sensor exists in HA (checked 2026-11-09); an earlier version of this page
said they did. The daily maintainer sweep also lists container state (from
Glances) in its report.

## Jobs reporting success

A job that must prove it ran sets an `input_datetime` helper through
`scripts/ha_mark_success.sh <entity>` (root, uses the stack's HA token in
`/run/homelab-stack/ha_scrape_token`). The restic backup is the first one.
