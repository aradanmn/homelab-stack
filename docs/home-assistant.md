# Home Assistant (the Green)

Home Assistant runs on its own hardware, the HA Green at 10.0.10.20
(Home Assistant OS, core 2026.11.0 when this was written), not on the
homelab host. This is the runbook for what is configured on it, how to
change it, and how to rebuild it. Alerting has its own page,
[alerting.md](alerting.md). A snapshot of the config files is in
[`../home-assistant/`](../home-assistant/README.md).

- **Reach:** `https://ha-web.home.example.com` (Traefik route in
  `rules/routers.yml`), or `http://10.0.10.20:8123`. Shell: `ssh ha`
  (the Terminal & SSH add-on; `ha core check`, `ha core logs`,
  `ha core stop|start` work there). The box has no Python; do conversions
  on the homelab host.
- **Companion app:** alerts and automations notify `notify.phones`, a
  notify group defined in `/config/packages/site.yaml` (not in git; template
  in `home-assistant/packages/site.yaml.example`). It lists the phones'
  `mobile_app_*` services. Every alert and the daily sweep push go through it.

## 1. What lives where

| Thing | Where on the Green | How to change it |
|---|---|---|
| Alerts, problem sensors, probes, dead-man ping, NAS rules | `/config/packages/monitoring.yaml` | edit over ssh, `ha core check`, then `template.reload` for sensors; new or changed `alert:` entries need an HA restart (the `alert` integration has no reload) |
| Monitoring dashboard | `/config/dashboards/monitoring.yaml` (YAML mode, registered by the package) | edit over ssh, reload the browser page; no restart |
| Home and Sense Power dashboards | `/config/.storage/lovelace.lovelace`, `lovelace.sense_power` (UI-stored) | section 2 |
| 36 `*_daily_cost` sensors, AC/furnace/dryer, unexplained power | `/config/configuration.yaml`, `template:` | edit, `ha core check`, `template.reload` |
| Electricity price, AI summary text | UI helpers (Settings, Devices & services, Helpers) | see section 6 for their definitions |
| UGREEN NAS integration | Marketplace-installed, `custom_components/ugreen`; config entry "MIMIR" | section 3 |
| Secrets | `/config/secrets.yaml`: `healthchecks_ping_url` | [secrets.md](secrets.md) |

Exact copies of the YAML files and exports of the two UI dashboards are in
`home-assistant/` in this repo. **Home Assistant is the live copy**; refresh
the snapshot after changing it (command in `home-assistant/README.md`).

## 2. The dashboards

| Sidebar name | URL | Kind | Views |
|---|---|---|---|
| Overview (the default) | `/lovelace` | UI-stored | Home, Upstairs, Downstairs, Exterior |
| Map | `/map` | UI-stored | the map |
| Monitoring | `/monitoring-yaml` | YAML file | Status, Network, Trends, Alerts |
| Sense Power | `/sense-power` | UI-stored | Power, Devices, Live |

HA 2026.11 also ships **built-in dashboards** (an auto-generated
"Overview" with a house icon, Lights, Security, Climate, Energy,
Maintenance). They are separate from ours and show up in Settings,
Dashboards under "Built-in". The user-created grid-icon "Overview" is the
default, so the sidebar, the browser and the app open ours. Two things to
know about the built-in ones: there are two entries called "Overview", and
the built-in Lights summary counts only `light.*` entities while most of
this house's lights are `switch.*` (the Lutron wall switches), so it
reports "All off" with lights on. Use Home, "On right now".

**What each view is for**

- **Home / Home:** AI summary, "On right now" (a tile per light or fan,
  shown only while it is on; the radon fan is left out because it runs all
  the time), climate, who is home, Smart Away. To include another light
  add a tile with a `visibility` state condition and add the entity to
  both conditions lists (the tile and the "All lights and fans are off"
  card).
- **Home / Upstairs, Downstairs, Exterior:** every light, fan, media
  player, occupancy and temperature tile by room; the doorbell camera is on
  Exterior. The **Kasa and Tapo smart plugs** sit in the same room sections as
  the lights (office strip in Office, the entertainment and aquarium strips in
  Family Room, Keurig in Kitchen, and so on). The ones that matter ask "are you
  sure?" on the icon: radon fan, aquarium pump and heater, mini fridge, Venmar,
  WD My Book (the Time Machine disk) and the Lutron hub. **Read-only, no
  switch (2026-11-10):** the NAS outlet (Office), and the modem, UniFi gateway
  and switch and the Mac Mini homelab host (Utility Room) are shown as power
  tiles (watts, tap for details), never as toggles, because switching them off
  from a dashboard cuts power to the NAS's RAID or cuts off the way back (you
  would have to go to the plug). **Not shown anywhere:** the four outlets with
  nothing in use: Computer Desk `Tapo P316M_4` and `_6` (`switch.framework_desktop`),
  and the Aquarium strip's two spares. The strips' "auto-off",
  "auto-update" and LED switches are settings, not outlets, and are not shown.
  The Office strip (Tapo name "Computer Desk Power Strip") has CalDigit Dock,
  Desk Outlet, the HP DeskJet 2952 printer (the plug is still named "HP Envy"
  in the Tapo app, so the Home tile overrides the name) and three never-named
  plugs: `Tapo P316M_3`, `_4` and `_6`. `_6` (entity `switch.framework_desktop`)
  has nothing plugged in and is not shown anywhere.
  **The NAS is on outlet 3** (Scott, 2026-11-09): `switch.unnamed_p316m_tapo_p316m_3_3`,
  power `sensor.unnamed_p316m_tapo_p316m_3_current_consumption_3`. It was
  identified from the Tapo history (a spike to 48 W at 17:15 on 2026-11-06 when
  it started, then 20 to 23 W; it drops to about 9 W overnight, with bursts to
  40 to 50 W during backups, which is what an idle NAS with spun-down disks
  and a busy one look like; it has never been off since). That outlet is deliberately **not** a toggle on any
  dashboard: cutting the NAS's power is an unclean shutdown of the RAID volume
  that holds the backups. It is monitored instead: `sensor.nas_power_draw`
  (the outlet's watts, shown as "Power draw (outlet)" in the Status NAS
  column) and the critical alert **NAS plug off** (below). If that outlet ever
  changes, edit the three entity ids in `packages/monitoring.yaml`
  (`nas_plug_off`, `nas_power_draw`, and the `nas_down` alert message).
- **Monitoring / Status:** one screen, four columns: Right now (a
  headline, four service tiles, links), Homelab host, NAS (mimir), Home.
  **Network:** UniFi devices as one table (status, CPU, memory, uptime,
  firmware), gateway gauges, client counts and the SSID switches.
  **Trends:** 24 h graphs. **Alerts:** a Health table, the sensor details
  list, and the silence toggles for the alerts.
- **Status symbols.** The Status headline and the Alerts "Health" table are
  driven by the **alert entities**, not the problem sensors: an alert is
  `idle` (condition false), `on` (true, nobody acknowledged) or `off`
  (true but acknowledged), so it carries the sensor's state and more. ✅ is
  idle; 🛑 is a problem on one of the seven alerts that page critically
  (Internet, AdGuard, NAS down, NAS storage unhealthy, NAS plug off, radon
  fan stopped, aquarium pump stopped); ⚠️ is a problem on
  any other; ❔ is an unavailable alert. An acknowledged problem keeps its
  symbol and says "acknowledged", so a silenced alert cannot quietly look
  fine. The list of seven is written in two places (the headline card and the
  Health table's rows); keep them in sync with the alerts that carry
  `push.sound.critical`. The sensor details list below the table is labelled
  in the positive ("Internet up", "NAS storage healthy") so "OK" reads as
  healthy; the sensors keep their "...down" names.
- **Sense Power / Power:** whole-home gauge, energy graph, today's cost
  (always on, other, Sense-identified, whole home), daily energy for the last 7 days in three charts (Family Room, Kitchen & Exercise; Office & Utility Room; Aquarium, Radon fan & Fridge) covering every outlet in use,
  and two history graphs that each add up to the whole home: always on +
  other + Sense-identified, and plugs + Sense-identified (not on a plug) +
  unexplained (the chart shows the filtered copy, see section 8; Sense's two categories leave out the appliances it has identified, about
  175 W of fridges, so charts without that series do not add up). **Devices:** every plug's daily cost by room, including the HP DeskJet printer and the NAS (Office). Anything with a Tapo outlet in use is on all three tabs; if you plug something new in, it needs a cost template (section 4), a tile in Devices, a graph line in Live and a bar in the daily charts.
  **Live:** a 24 h power graph per room; the radon fan's is pinned to 0 to 80 W
  so its normal 1 to 2 W of noise does not look like swings.

Removed on 2026-11-09: the Lutron dashboard (its lighting view held no
entity that Home lacked; the Pico remote buttons were dropped on purpose)
and the UniFi Network dashboard (its useful half is Monitoring, Network;
its firewall-rule toggles were 13 of 17 dead after the firewall rework and
toggling rules from HA is easy to do by accident).

### Layout rules (learned the hard way)

These dashboards use the **sections** view. The rules that decide whether
they look right:

- Each section column is 12 grid columns wide; `column_span: 2` makes a
  section 24 wide, `3` makes it 36.
- **Tiles default to half width (6 of 12).** A tile left alone in a row
  leaves a half-empty row. Give a lone tile `grid_options: {columns: 12}`;
  pairs need nothing; gauges are `columns: 6` so two sit side by side.
- `max_columns` is a cap. HA drops to fewer columns on a narrower window by
  itself (phone: one column), but a section column tops out at roughly
  500 px, so on a very wide window the content is centred, not stretched.
  Size `max_columns` to the number of sections in the view.
- Several single-tile rooms share one section, separated by
  `heading_style: subtitle` headings.
- On a tile card the **icon** toggles a switch and the rest of the tile opens
  the details, so an "are you sure?" goes on `icon_tap_action`
  (`confirmation: {text: ...}`), not `tap_action`.
- `visibility` conditions on a card are ANDed. "On right now" relies
  on that.
- A markdown card that renders a Jinja table must use a literal block
  (`|-`), not a folded one (`>-`), or the table rows are joined into one line.
- Show a date/time helper with `type: simple-entity`; a plain
  `input_datetime` row renders as an editable picker.
- After editing, check that every run of tiles in a section ends on a full
  12-column row (the 2026-11-09 rebuild did this with a short script).

### Changing a dashboard

**Monitoring (YAML):** edit `/config/dashboards/monitoring.yaml` over ssh
and reload the page. Keep a `.bak-<date>` next to it first.

**Home, Sense Power (UI-stored), way 1, no downtime:** open the dashboard,
pencil, the three-dot menu, "Raw configuration editor", select all, paste
the matching file from `home-assistant/dashboards/`, Save.

**Way 2, when you want to script it:** HA holds these in memory, so a file
edited while HA runs is overwritten at the next UI save. Stop HA first.

```bash
ssh ha 'cp -p /config/.storage/lovelace.lovelace /config/.storage/lovelace.lovelace.bak-$(date +%Y%m%d)'
# on the homelab host: put the new config into the storage wrapper
ssh ha 'cat /config/.storage/lovelace.lovelace' | python3 -I -c '
import json,sys,yaml
d=json.load(sys.stdin); d["data"]["config"]=yaml.safe_load(open(sys.argv[1]))
json.dump(d,sys.stdout,indent=2,ensure_ascii=False)' new-home.yaml > lovelace.lovelace.new
ssh ha 'ha core stop'
ssh ha 'cat > /config/.storage/lovelace.lovelace' < lovelace.lovelace.new
for i in 1 2 3 4 5 6 7 8; do ssh ha 'ha core start' 2>&1 | grep -q "not ready" && sleep 10 || break; done
```

- `ha core start` right after a stop can be refused with "Supervisor is not
  ready to perform this operation" (seen 2026-11-09): retry, as above.
- A boot takes about 4 to 6 minutes before everything is loaded. The
  front page on port 8123 answers within seconds and is **not** a readiness
  signal; use an authenticated API call (for example `render_template`).
- **Restarting HA clears the bell.** Persistent notifications live in
  memory. The daily sweep posts its report at about 05:31 (section 8).

## 3. The UGREEN NAS in Home Assistant

The NAS is `mimir`, a UGREEN DH4300 Plus at 10.0.10.40 (UGOS web UI on
port 9999). The HA integration is the community project
`Tom-Bom-badil/home-assistant_ugreen-nas`, domain `ugreen`, version
v2026.10.1 when installed and v2026.11.1 since 2026-11-09. It logs in to the same web API the UGOS UI uses.
Nothing runs on the NAS and no SSH is involved. The project was tested on
the DXP 4800+ and 480T, so a DH4300 Plus may have gaps.

**Install (HA 2026.11 or later):** HACS is now built in as the
**Marketplace** (Settings, Marketplace). The old `get.hacs.xyz` installer
stops working at 2026.11. Marketplace, search "UGreen", Install; it opens
the setup flow with no restart. Updates through the Marketplace still need
a restart. Marketplace projects are community code that "is not tested,
audited, or supported by the Home Assistant project and runs inside your
Home Assistant" (HA 2026.11 release notes), so treat each as a trust
decision.

**On the NAS first (UGOS, Control Panel, User Management):**

1. Create a dedicated user named `homeassistant`. Role **Admin** (the
   integration's wiki requires it). Untick "Personal Folder". Tick "not
   allowed to change the password". Give it no shared-folder access
   (Deny on every share); admin may bypass that, which is accepted.
2. Password: long, letters and digits only. UGOS can truncate some special
   characters, which shows up as `invalid_auth`. Keep it in Bitwarden
   (entry for 10.0.10.40, user `homeassistant`); do not paste it into
   chat or a command.
3. Control Panel, Security: turn **off** the HTTP to HTTPS redirect (or use
   HTTPS in the integration). 2FA is supported by this version (tick the
   box in the setup flow and enter one code) but off is simpler.

**Then in HA (Settings, Devices & services, UGREEN NAS):** IP
`10.0.10.40`, port `9999`, the username and password, name left at the
default `UGREEN NAS` (every entity is `*.ugreen_nas_*`), HTTPS off.
Errors: `invalid_auth` is the password; `400 Bad Request` is an HTTP/HTTPS
mismatch (the redirect); `500` is 2FA on without the box ticked;
`cannot_connect` is HA unable to reach 10.0.10.40:9999.

**What it gives you:** 206 entities on v2026.10.1 and 211 on v2026.11.1 (the
update added GPU, NPU and VPU sensors; the GPU temperature reads 0 °C, so it
means nothing here): CPU, memory, per-disk
temperature and status, pool and volume status, volume sizes, fan, LAN
rates, UGOS version, and buttons (shutdown, reboot, fan and power modes,
wake). The buttons are **not** on any dashboard on purpose.

**Updating the integration** needs an HA restart (Marketplace updates do). Our
NAS rules read specific entity ids (the server, pool, volume and disk statuses,
the temperatures, the raw volume byte counts) and fail open on `unavailable`, so
a renamed entity would silently stop being watched instead of raising an alert.
So record those sensors before an update and compare after: entity count, every
status still `Normal`, no `ugreen_nas*` entity unavailable, all alerts idle.
v2026.11.1 was checked this way on 2026-11-09: nothing renamed; temperatures and
percentages became whole numbers (NAS CPU shows 5 %, not 4.3 %). The release
notes did not list which pool status codes were relabeled, so watch the
"NAS storage unhealthy" sensor after any update.

**Quirks that matter:**

- Pool-level "used" equals "total" (free 0). Fullness is computed from the
  volume byte counts instead: `sensor.nas_volume_1_used` and
  `sensor.nas_volume_2_used` (templates in the package).
- Temperatures are in °F (HA runs imperial). The alert thresholds are °F;
  UGOS's own `temperature_status_code` (0 = fine) is unit-independent and
  is the second trigger.
- No SMART attributes are exposed, only a status per disk, so the rules
  cannot warn about drive wear early. The two pool-1 HGST drives had about
  55,000 power-on hours and the Seagate about 36,700 on 2026-11-09.
- When the NAS is off all ~200 entities go unavailable at once. The
  "Unavailable entity spike" counter skips `ugreen_nas` entities so one
  outage is one alert ("NAS down"), not two.

**Related but separate:** `binary_sensor.nas_ui` is a REST probe of
`http://10.0.10.40:9999/desktop/` made directly, not through Traefik, so
it shows the NAS itself. `https://nas-web.home.example.com` is a Traefik
route to the same UI (`rules/routers.yml`, homelab-stack#53). The
integration talks to the IP, so it does not depend on Traefik or DNS.

The four NAS alerts (down, storage unhealthy, volume over 85 %, running
hot) are in [alerting.md](alerting.md).

## 4. Cost sensors

36 template sensors in `configuration.yaml`, named `*_daily_cost` (three added 2026-11-10: NAS and HP DeskJet printer, both on the Computer Desk strip with `_3`-suffixed entities, and `sensor.sense_identified_daily_cost`, which is whole home minus always on minus other so the four Today's cost tiles add up to the total). Each is
that device's **today** energy (the plug's `today_s_consumption`, or the
Sense `daily_energy`) times `sensor.rpu_electricity_price`, in USD. Since
2026-11-09 they are rounded to **3 decimals** (they were 2, which made most
devices read $0.00). They reset at midnight, so early-morning numbers are
small.

One of them, `sensor.whole_home_daily_cost`, is Sense's whole-home `daily_energy`
times the price. It exists because Sense's own
`sensor.sense_1000019509_daily_energy_cost` uses a different rate: on
2026-11-09 it said $0.025 for 14.1 kWh, which is $1.78 at the RPU price, so the
Power tab's "Whole-Home Total" tile was wrong until it read the template.

A rolling 24 h cost was considered and not built: the plugs' counters reset
at midnight and many expose no lifetime total, so it would need about 32
new `statistics` sensors (24 h mean of `current_consumption` times
0.024 times the price). If it is ever wanted, do it for the five or six
devices that matter (Aquarium Heater, Fridge, Radon Fan, UniFi Gateway,
the homelab plug), not all 32.

`sensor.rpu_electricity_price` is a template helper (unit USD/kWh) with
seasonal rates, and a rate change on 2027-01-01. Its definition is in
section 6.

Two plug entities have **misleading ids**: `sensor.wd_my_book_daily_cost` is
the cost of the plug named "Mac Mini Proxmox", and
`sensor.mac_mini_proxmox_daily_cost` is the cost of "WD My Book". Checked
2026-11-09: the sensor names are built from the plugs' own names (the Tapo
strip's plug 3 is "Mac Mini Proxmox", plug 4 is "WD My Book", as set in the
Tapo app) and the ids are stale from when the templates were created. The
dashboards show the real names ("Mac Mini (homelab host)", "WD My Book"); the
homelab host is the old Proxmox machine, wiped to Debian in place. The radon fan is the plug
`switch.bedside_lamp`, deliberately labelled "Radon Fan" everywhere.

The built-in **Energy** dashboard keeps its device list in
`/config/.storage/energy` (not in the snapshot). On 2026-11-09 two dead entries
were removed from it (the HP printer's sensor, and the orphaned
`fridge_daily_energy_2`, replaced by `sensor.fridge_daily_energy`). A device that
disappears from HA is cleaned out in Settings, Dashboards, Energy, or by editing
that file with HA stopped (section 2).

## 5. Backups and restore

- **Automatic backups** go to two places: "This system" (the Green's own
  `/backup`, several recent ones) and **Home Assistant Cloud** (the latest
  only, 5 GB maximum). A full backup includes all of `/config`, so the YAML
  files, the UI dashboards and `.storage` are in it. Apps are included;
  media and the share folder are not.
- Backups are **encrypted**. The key is shown under Settings, System,
  Backups, three-dot menu, "Change encryption key". **Save it outside HA**
  (Bitwarden). Without it neither the local nor the cloud copy can be
  restored.
- `home-assistant/` in this repo is an independent, readable copy of the
  config files, but not of credentials, device pairings or the entity
  registry.
- **The Green's own disk (28 GB).** `sensor.ha_disk_used` is a `command_line`
  sensor (`df` on `/config`, every 5 minutes) and feeds "HA disk over 85
  percent" (30 min). With retention "keep 3" it sits near 63 %. A failed backup
  job does not trim old copies, so a run of failures grows it by about 1.7 GB a
  day.
- **The success timestamp.** `sensor.backup_last_successful_automatic_backup`
  feeds the "HA backup stale" alert (36 h). HA records a success only when
  **every** selected location succeeds. Where the reason for a failure
  lives: the entity `event.backup_automatic_backup` (attributes `event_type`
  and `failed_reason`, for example `upload_failed`), not the logs.
  On 2026-11-09 the 04:59 backup (interrupted by an HA stop at about 05:04)
  and an 11:33 backup (started 7 minutes after an HA restart) failed with
  `upload_failed` to Home Assistant Cloud, with nothing in any log. A backup
  started at 18:55, with HA up for hours, succeeded in all three locations
  and the Cloud upload took about 6 minutes. Likely cause, not proven: the
  Cloud connection is not ready for several minutes after a restart, so
  **wait about 10 minutes after any HA restart before a backup**.
- **The NAS is a backup location (2026-11-09).** Storage `mimir_backups`,
  NFS, `10.0.10.40:/volume1/ha-backups`, usage Backup (so it is the
  default backup location, which also holds the automatic pre-update backups).
  Locations on for the daily automatic backup: This system, `mimir_backups`
  and Home Assistant Cloud (kept on because it is the only off-site copy).
  Retention is "3 backups"; HA trims after a successful run. NAS side
  (UGOS, Files, shared folder `ha-backups`, NFS Permissions): client
  `10.0.10.20`, Read/Write, squash "No mapping" (HA mounts as root), Async
  **off**, unprivileged ports **off**. UGOS's NFS maximum protocol is NFSv3,
  the only choice offered. Check from the host: `showmount -e 10.0.10.40`
  lists `/volume1/ha-backups 10.0.10.20`; on the Green `ha mounts info`
  shows `state: active` and `default_backup_mount: mimir_backups`. Without
  the NAS rule the mount fails with "access denied by server".

## 6. Recreate it from nothing

Prefer a restore: new Green, onboarding, Settings, System, Backups,
upload the backup or pick the cloud one, enter the key. Everything below is
for when there is no usable backup.

1. **Install Home Assistant OS** on the Green, onboard as `Scott Dean`,
   time zone `America/Chicago`, **imperial units** (the °F thresholds and
   dashboards assume it). In UniFi, give it the DHCP reservation
   10.0.10.20.
2. **Add-ons:** Terminal & SSH (add the `claude` user's public key so
   `ssh ha` works), AdGuard Home (see [services.md](services.md), adguard).
3. **Integrations** (Settings, Devices & services). Settings the files
   depend on: Sense (home monitor `sense_1000019509`); TP-Link (Kasa and
   Tapo plugs, which produce the `*_current_consumption` and
   `*_today_s_consumption` sensors); UniFi; Ecobee (`climate.thermostat`,
   the room sensors); Lutron Caseta (10.0.107.50); Apple TV, Google Cast,
   Android TV Remote, Vizio, HEOS; Reolink (the front door camera);
   Matter and Thread; Anthropic (the `ai_task` entity
   `ai_task.utility_room_claude_ai_task` for the AI summary); Home Assistant
   Cloud (for the backup copy); **Ping** `1.1.1.1` (count 5, consider home
   180); **Certificate Expiry** `ha-web.home.example.com:443`; **Minecraft
   Server** `10.0.10.10:25565` (Java); **Glances** `10.0.10.10:61208`
   (no SSL); AdGuard Home; Met.no weather (`weather.forecast_home`); the
   companion app, signed in on each phone (it creates a
   `notify.mobile_app_*` service per phone; list them in
   `/config/packages/site.yaml`). The Glances, Minecraft, Certificate Expiry
   and UniFi integrations name their entities after the address or domain;
   rename those to the neutral ids the config uses (see
   `home-assistant/README.md`).
4. **Helpers** (Settings, Devices & services, Helpers):
   - Text, name `AI Home Summary`, maximum length 255, icon
     `mdi:robot-outline` (entity `input_text.ai_home_summary`).
   - Template, sensor, name `RPU Electricity Price`, unit `USD/kWh`, state:

     ```
     {% set m = now().month %}{% set summer = 6 <= m <= 9 %}{% set y2027 = now().year >= 2027 %}{{ (0.16108 if summer else 0.13483) if y2027 else (0.15074 if summer else 0.12619) }}
     ```
5. **Files.** From the homelab host, in this checkout:

   ```bash
   cd /home/claude/workspace/homelab-stack/home-assistant
   ssh ha 'mkdir -p /config/packages /config/dashboards /config/themes'
   for f in configuration.yaml scripts.yaml automations.yaml packages/monitoring.yaml \
            dashboards/monitoring.yaml themes/haven.yaml; do
     ssh ha "cat > /config/$f" < $f
   done
   ```

   Then create `/config/secrets.yaml` with one key, `healthchecks_ping_url`
   (value in the vault as `healthchecks-ping-url`, see
   [secrets.md](secrets.md)). Run `ssh ha 'ha core check'`.
   `configuration.yaml` also defines the HomeKit bridge, so the iPhone must
   re-pair it (HA posts the pairing code as a notification; I did not
   re-pair a bridge when writing this, so check the HomeKit integration's
   page if no code shows).
6. **UGREEN NAS:** section 3.
7. **Backup storage.** NAS rule and HA storage as in section 5 ("The NAS is a
   backup location"), then tick the locations under Settings, System,
   Backups, Automatic backup.
8. **Dashboards.** Monitoring is registered by the package and appears in
   the sidebar after the restart in step 8. For the others: Settings,
   Dashboards, Add dashboard, "New dashboard from scratch": title
   `Sense Power`, URL `sense-power`, icon `mdi:flash`, show in sidebar. Open
   it, pencil, three-dot menu, Raw configuration editor, paste
   `dashboards/sense-power.yaml`. For Home: edit the default dashboard
   (or create one titled Overview, URL `lovelace`, and "Set as default"),
   paste `dashboards/home.yaml`. Set the theme to **Haven** in your profile.
9. **Restart HA once** so the `alert:` entries load, then check section 7.

What the repo cannot give back: integration logins and device pairings
(re-enter or re-pair), the entity registry (names, areas, which entities
were removed), and UI helpers beyond the two in step 4. A backup restores
all of those.

## 7. After a rebuild (or any big change), check

```bash
ssh ha 'ha core check'                                   # config valid
ssh ha 'ha core logs 2>&1 | grep -c " ERROR "'           # 0 after a clean start
```

In HA (Developer tools, Template):

```
unavailable: {{ states('sensor.ha_unavailable_entities') }}              (0 or 1)
problems: {{ states('sensor.monitoring_active_problems') }}              (0)
NAS: {{ states('sensor.ugreen_nas_server_status') }}                     (Normal)
alerts idle: {{ states.alert | selectattr('state','eq','idle') | list | count }}   (17)
```

Then open each dashboard view and look for "Entity not found" tiles. The
unavailable counter reads a few dozen for a minute after `template.reload`
(the template entities restart); wait a minute before judging it.

## 8. Gotchas

- **Give HA about 10 minutes after a restart** before anything that needs an
  outside connection (a backup to Cloud, a push). Three things failed within
  minutes of restarts on 2026-11-09: the 05:31 sweep push, the 04:59 backup and
  the 11:33 backup.
- **The daily sweep report lives in HA's bell, which a restart empties.**
  `maintainer-sweep.timer` runs at 05:30 on the homelab host and
  `maintainer-post.service` posts the result (persistent notification id
  `maintainer_sweep`, plus one companion-app push) at about 05:31. Restart
  HA outside roughly 05:25 to 05:45, or repost the same report with
  `sudo systemctl start maintainer-post.service` (no model cost; it sends one
  more push). Learned 2026-11-09 when a restart at 05:35 removed that
  morning's report.
- `post.sh` uses `curl -sS` without `-f`, so an HTTP error from HA (bad
  token, missing service) still prints "posted". If a report ever fails to
  appear while the journal says it posted, check the token first
  (`journalctl -u maintainer-post.service`, and HA's log for "invalid
  authentication from 10.0.10.10").
- "Entity not found" on a dashboard tile means the entity no longer exists
  at all (removed integration or device). "Unavailable" tiles still render.
  After removing a device, delete its tile.
- 15 UniFi firewall-rule switches became orphans after the 2026-11-08 rule
  cleanup and were deleted from Settings, Entities (filter "Unavailable").
  A rule removed in UniFi leaves an `unavailable` switch behind; clear it
  the same way, or the unavailable counter drifts above its baseline of 0
  to 1.
- Editing a file under `/config/.storage` while HA runs does nothing
  useful and is overwritten by the next UI save. Stop HA first (section 2).
- Edit over ssh with a dated `.bak-` copy beside the file; `ha core check`
  before any reload or restart.
- **New Tapo strips and the plug sum.** `sensor.home_energy_explained_tapo_kasa`
  adds every `tplink` sensor whose id ends in `_current_consumption` with an
  optional `_<number>` suffix. Outlets on a second or third strip get a suffix
  when names collide (`..._p316m_3_current_consumption_2`, `_3`). Until
  2026-11-10 the match had no suffix part, so five outlets (23.7 W, including
  the NAS and the UniFi Gateway) were left out of "explained" and counted as
  unexplained (about 30 to 40 W on average, 24 W in the first spot reading).
  If unexplained looks high after plugging in a new strip, check
  `integration_entities('tplink')` against the sum.
- **A load on a plug that Sense also detects is counted twice.** Sense listed
  the Keurig's heating element as "Mystery Heat 4": 1,329 to 1,393 W at the same
  minutes the Keurig's plug read 1,355 to 1,396 W, every day. Plugs + identified
  then exceeded the whole home by about 1,400 W and `unexplained` dipped to
  -2,500 W (-5,200 W on 2026-11-08 with the dryer), which squashed the chart.
  `sensor.home_energy_identified_off_plug_sense` is the Sense-identified sum
  without the devices listed in `on_a_plug` (now only
  `sensor.mystery_heat_4_power`); `unexplained` and the plugs chart use it, the
  always-on + other + identified chart keeps the full `..._identified_sense`.
  If Sense identifies another device that is also on a plug, add it to
  `on_a_plug`. Not a bug, leave alone: while a burner or the oven is on,
  unexplained rises by up to about +2,600 W, because Sense's stove estimate
  tops out near 1,100 W while the whole home reads about 3,000 W. And
  `identified` read exactly 0 W from 2026-11-03 to 11-06 (the Sense device
  sensors reported nothing), so those days' unexplained is the whole home
  minus plugs only.
- **Brief dips and spikes in unexplained, and the filtered copy.** The Tapo
  plugs report about every 5 s, Sense (whole home and its devices) about every
  30 s or slower, and Sense's own device sensors step at slightly different
  moments from its whole-home reading. So whenever a big load switches (the
  Keurig, 1,360 W; a 360 to 480 W Sense device overnight) the subtraction
  dips and then spikes by about the size of the step (-1,147 W seen on
  2026-11-11). `sensor.home_energy_unexplained_filtered` is what the Sense
  Power chart shows: a `statistics` sensor (`state_characteristic: median`,
  `max_age` 3 minutes, `sampling_size` 450 because the source updates about
  twice a second). A median drops anything shorter than about 90 s and passes
  real loads (furnace, stove) with about 1.5 minutes of delay. The chart
  clips at 0 with `min_y_axis: 0`, because a negative unexplained load is
  never real (and the median, not a clip, must do the cleaning first). The
  alert keeps the raw `sensor.home_energy_unexplained`. Tried and dropped on
  2026-11-13: a 30 s average of the plug total (helped about 15 percent; most
  of the jitter is Sense against itself); absolute value (turns dips into
  spikes and stops averaging cancelling them). Real, understood unexplained
  load: the furnace (`sensor.furnace_running`), roughly 450 to 900 W while it
  runs, about 05:00 to 07:00 and 15:00 to 19:00, because Sense's "Furnace Fan"
  device reads 0 W.
- **`ha core check` does not catch a bad platform sensor.** A `sensor:` entry
  with an invalid option (the `filter` platform has no `median`) passes the check,
  is logged at startup as `Invalid config for 'sensor' from integration
  'filter'` and is silently skipped, so the entity never exists. After a restart
  that adds a platform sensor, confirm the entity exists with a state and search
  the log: `ha core logs -n 600 | grep -i "invalid config"` (the command returns
  only the last N lines, default 100). A template's `states('x')` returns
  `unknown` for a missing entity, which looks like a sensor still warming up.
- **The UniFi integration can recreate its entities with a `_2` suffix.**
  On 2026-11-11 the UCG restarted itself and the UniFi Network app switched its
  internal ids from 24-character ids to UUIDs. After the HA restart on
  2026-11-12 13:50 the integration therefore made 33 new entities (the four
  WiFi networks' switch, client counter, QR code and password button, and 17
  firewall-policy switches) with a `_2` suffix, and the old ones stayed behind
  as dead copies (`restored: true`). Symptom: `sensor.ha_unavailable_entities`
  stuck at 26 (baseline 1), the "Unavailable entity spike" alert on from about
  16:00, and dashboards pointing at the old ids showing unavailable (the
  Monitoring Network tab's Wi-Fi networks). Reloading the integration does not
  fix it. **Fixed 2026-11-13** through HA's websocket API (the same calls as the
  Settings page): for each pair, `config/entity_registry/remove` on the dead
  original, then `config/entity_registry/update` with `new_entity_id` on the live
  `_2` one, so every dashboard keeps its original ids and nothing was edited.
  By hand: Settings, Devices & services, Entities, delete the unavailable
  original, then open the `_2` entity, Settings, Entity ID, remove the `_2`.
  **Do not strip every `_2`:** `device_tracker.p316m_2`, `ep25_2`,
  `macbook_pro_2`, `steamdeck_2`, the `*_link_speed_2` sensors and the
  `*_port_2` switches are different devices that share a name (their unique ids
  are MAC addresses or port numbers). A true duplicate has the same kind of
  unique id (`wlan-`, `wlan_clients-`, `firewall_policy-`, ...) as an
  unavailable original. The ten `laundryrmsw_port_*_power_cycle` buttons that
  read unavailable are ports that no longer offer PoE power cycling; buttons do
  not count toward the counter. After any restart check
  `sensor.ha_unavailable_entities` is back to 0 to 2 a few minutes later, not
  just that the alerts are idle at +10 s.
