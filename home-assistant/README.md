# home-assistant/

A **snapshot** of the Home Assistant Green's own configuration,
exported on 2026-11-09. Home Assistant is the live copy; this directory exists
so the setup can be recreated if the Green is lost and so changes have a
history. The runbook is [`docs/home-assistant.md`](../docs/home-assistant.md).

| File here | Lives on the Green at | Kind |
|---|---|---|
| `configuration.yaml` | `/config/configuration.yaml` | exact copy (cost templates, HomeKit bridge, includes) |
| `packages/monitoring.yaml` | `/config/packages/monitoring.yaml` | exact copy (problem sensors, alerts, probes, dead-man ping, registers the Monitoring dashboard) |
| `dashboards/monitoring.yaml` | `/config/dashboards/monitoring.yaml` | exact copy (the Monitoring dashboard, YAML mode) |
| `scripts.yaml`, `automations.yaml` | `/config/` | exact copies (AI home summary script, door and string-light automations) |
| `themes/haven.yaml` | `/config/themes/haven.yaml` | exact copy |
| `dashboards/home.yaml` | `/config/.storage/lovelace.lovelace` | **export** of a UI-stored dashboard (YAML form) |
| `dashboards/sense-power.yaml` | `/config/.storage/lovelace.sense_power` | **export** of a UI-stored dashboard (YAML form) |

**Not in this directory, on purpose:** `secrets.yaml` (the dead-man ping URL,
the two probe addresses and the dashboard's link list; key names and example
values are in [`secrets.yaml.example`](secrets.yaml.example), see also
`docs/secrets.md`), `packages/site.yaml` (the `phones` notify group, which
says whose phones get alerts; template in
[`packages/site.yaml.example`](packages/site.yaml.example)), everything else
under `.storage/` (integration credentials, device pairings, the entity
registry), the database, and `custom_components/ugreen` (the Marketplace
installs it). Those come back from a Home Assistant backup, not from git.

Site-specific values stay out of these files: alerts and automations notify
`notify.phones`, addresses come from `!secret`, and entity ids carry neutral
names (`sensor.homelab_*`, `sensor.wildcard_cert_expiry`,
`sensor.guest_wifi_clients`) rather than an address or the domain. A fresh
install gets address-based ids from the Glances, Minecraft, Certificate
Expiry and UniFi integrations; rename those entities to the ids used here.

## Refresh the snapshot after changing HA

Edit on the Green first (that is the live copy), then:

```bash
cd /home/claude/workspace/homelab-stack
for f in configuration.yaml scripts.yaml automations.yaml packages/monitoring.yaml \
         dashboards/monitoring.yaml themes/haven.yaml; do
  ssh ha "cat /config/$f" > home-assistant/$f
done
export_dash() {   # $1 = storage file, $2 = output, $3 = header comment
  ssh ha "cat /config/.storage/$1" | python3 -I -c '
import json,sys,yaml
print(sys.argv[1].replace("\\n","\n"),end="")
print(yaml.safe_dump(json.load(sys.stdin)["data"]["config"],sort_keys=False,allow_unicode=True,width=160),end="")
' "$3" > "$2"
}
export_dash lovelace.lovelace    home-assistant/dashboards/home.yaml \
  "$(head -3 home-assistant/dashboards/home.yaml | sed 's/$/\\n/' | tr -d '\n')"
export_dash lovelace.sense_power home-assistant/dashboards/sense-power.yaml \
  "$(head -3 home-assistant/dashboards/sense-power.yaml | sed 's/$/\\n/' | tr -d '\n')"
git diff --stat home-assistant
```

Check for drift without changing anything (empty output means the snapshot
is current):

```bash
for f in configuration.yaml scripts.yaml automations.yaml packages/monitoring.yaml \
         dashboards/monitoring.yaml themes/haven.yaml; do
  ssh ha "cat /config/$f" | diff -q - home-assistant/$f >/dev/null || echo "DRIFT: $f"
done
```

Scan before committing: `python3 scripts/secret_patterns.py scan home-assistant/`
if that scanner is present in this checkout, otherwise
`grep -rn -i -E 'password|token|api[_-]?key|bearer' home-assistant`.
