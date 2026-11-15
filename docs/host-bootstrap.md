# Host bootstrap: rebuild `homelab` from bare metal

How to rebuild the one homelab host (Debian 13 + Docker) from nothing.
Written for the 2026-11-08 move off Proxmox (claude_sessions#37) and kept
as the standing rebuild procedure. Every step says where you type it, the
exact command, and what you should see. What each service is for is in
[services.md](services.md); how secrets flow is in [secrets.md](secrets.md).

**Hosts named here**
- **the box**: the HP EliteDesk 800 G4 (i5-8500, 16 GB, 238 GB NVMe), `homelab`, 10.0.10.10.
- **mimir**: the UGREEN NAS, 10.0.10.40. Holds the backups. Reachable in a browser at `http://10.0.10.40:9999`.
- **HA Green**: Home Assistant, 10.0.10.20. Separate hardware; its AdGuard add-on serves DNS while the box is down. Its own config, dashboards and rebuild steps are in [home-assistant.md](home-assistant.md), not here.
- **the controller**: UniFi, `https://10.0.1.1`.

**Where you type commands**
- "on the box" = the new Debian install, at its console or `ssh claude@10.0.10.10`, then `sudo -i` for a root shell where it says root.

---

## 0. Before you start: things to have in hand

1. **Three new Bitwarden Secrets Manager access tokens.** The ones installed today cannot be read back, and the encrypted copies on the hosts die with the wipe. In the BWS web vault go to Machine accounts, open each of `homelab-stack` (the stack's secrets service), `claude`, `maintainer`, create a new access token named for the unit that will hold it (`homelab-stack-secrets <yyyy-mm>`, `claude-secrets <yyyy-mm>`, `maintainer-secrets <yyyy-mm>`), one-year expiry, and save it in your password vault. You paste each one exactly once in section 5. Done 2026-11-06, expiring 2027-11; revoke the previous tokens once the rebuilt host has fetched successfully, and update `claude_sessions/docs/expiry-registry.md`.
2. **One new BWS secret** named `timemachine-env` in the `homelab-stack` project (where `homelab-stack-env` already lives), whose entire value is one line: `PASSWORD=<the tmuser Samba password from your password vault, Time Machine item>`.
3. **One more new BWS secret**, `adguardhome-sync-env`, same project, whole value two lines: `ORIGIN_USERNAME=<the AdGuard login name>` and `ORIGIN_PASSWORD=<the AdGuard login password>`. It must exist before section 5, because the stack's fetch needs it. Also, in Home Assistant, Settings, Add-ons, AdGuard Home, Configuration, Network, the web interface host port is `3000` (the sync container reaches it at `http://10.0.10.20:3000`); the add-on's "Leave front door open" is on, so the replica needs no login.
4. **One more new BWS secret**, `restic-env`, same project, whole value two lines: `RESTIC_REPOSITORY=/mnt/mimir-backups/restic` and `RESTIC_PASSWORD=<a new 28-character passphrase, also saved in your password vault>`. Avoid `$ # ' " \` backtick and spaces in the passphrase.
5. **The box's wired MAC address**: `00:00:5e:00:53:10`. In the controller, Settings, Networks, TS_Server is the network; under Client Devices find that MAC (it shows as a nameless client at .10) and set a **fixed IP of 10.0.10.10**. Today pve has no reservation; the rebuilt host must get .10 from DHCP so its hostname registers in DNS.
6. **A Debian 13 netinst USB stick** and a keyboard and monitor at the box.
7. **Printed or on your phone**: this file.

## 1. Before wiping: backups (first rebuild only, from Proxmox)

This section applied to the 2026-11-08 move off Proxmox and is kept for the record. For a rebuild after that, the backups are the nightly restic snapshots on the NAS (section 10) and the restore commands in sections 4, 6 and 7 become `restic restore` of the same paths.

Run as root on the Proxmox host.

```
# 1a. fresh backup of all six containers to the NAS (takes 10-20 min)
vzdump 100 101 104 105 111 10443 --storage mimir-backups --mode snapshot --compress zstd
ls -lh /mnt/pve/mimir-backups/dump/ | grep "$(date +%Y_%m_%d)"
```
You should see six `.tar.zst` files with today's date, roughly: 100 about 1 GB, 101 about 9 GB, 104 tiny, 105 about 7.5 GB, 111 about 16 GB, 10443 about 2 GB.

```
# 1b. save the host-side files that are not inside any container
tar czf /mnt/pve/mimir-backups/pve-host-config-$(date +%F).tgz \
  /etc/network/interfaces /etc/fstab /etc/pve/jobs.cfg /etc/pve/storage.cfg \
  /etc/vzdump.conf /etc/pve/lxc/*.conf /root/.ssh/authorized_keys
tar tzf /mnt/pve/mimir-backups/pve-host-config-*.tgz     # 12 lines, including six etc/pve/lxc/<id>.conf
```
`/etc/pve` is a special filesystem; naming the directory alone gives an empty entry, the glob is required.
```
```

```
# 1c. confirm the second DNS server answers (it carries the house on Saturday)
dig +short @10.0.10.20 adguard.home.example.com
```
Expect `10.0.10.101`.

- [ ] 1a six archives on the NAS
- [ ] 1b host config tarball on the NAS
- [ ] 1c HA DNS answers
- [ ] 0.3 reservation for the box at .10 exists in the controller
- [ ] The nightly copy to the NAS's 500 GB disk runs at 04:00; glance at it Saturday morning in the UGOS Sync & Backup app.

## 2. Install Debian

1. Boot the USB stick. Choose the plain installer (not graphical is fine). Hostname: `homelab`. Domain: `home.example.com`. Root password: set one. First user: **username `claude`** (this must be the first user so it gets uid 1000; the secrets tmpfs is keyed to that number). Network: let it use DHCP; it should get 10.0.10.10 from the reservation.
2. Partitioning: "Guided, use entire disk", pick the **NVMe** (238 GB, Toshiba KXG50), all files in one partition, ext4. The SATA SSD and the USB drive are left alone.
   - If the disk still carries a Proxmox install, expect a red "Error while deleting the logical volume: the logical volume vm-100-disk-0 on pve could not be deleted" dialog (seen 2026-11-07). The installer cannot check LVM-thin pools (`thin_check` is not on the netinst image), so when it removes the thin pool `data` the thin volumes inside it go with it, and the later explicit delete of each one fails. Nothing is wrong: press **Continue** (repeat if it comes up again) and the partitioner proceeds with the volumes gone. If it loops or the old `pve` volume group is still listed, switch to a shell with Ctrl-Alt-F2 and run `lvm vgchange -an; lvm vgremove -ff pve; lvm pvremove -ff /dev/nvme0n1p3`, then Ctrl-Alt-F1, Go Back, "Detect disks", and partition again.
3. Software selection: untick everything except **SSH server** and **standard system utilities**.
4. Reboot, log in as `claude`, and from your laptop: `ssh claude@10.0.10.10`. Then:

```
su -                       # root shell
apt update && apt install -y sudo git curl zstd jq nfs-common avahi-daemon \
  python3 python3-requests python3-yaml restic ca-certificates \
  systemd-resolved unzip rsync
usermod -aG sudo claude
ip -br link               # note the wired interface name, probably eno1
```

## 3. Network, mounts, Docker

Run as root on the box. Replace `eno1` below if `ip -br link` showed another name.

```
# 3a. VLAN 40 sub-interface for Scrypted, with its own MAC so the controller sees a separate client
apt install -y vlan
cat >> /etc/network/interfaces <<'EOT'

auto eno1.40
iface eno1.40 inet dhcp
    vlan-raw-device eno1
    hwaddress ether 02:00:5e:00:53:40
    up sysctl -q -w net.ipv4.conf.eno1/40.arp_ignore=1
    up sysctl -q -w net.ipv4.conf.eno1/40.arp_announce=2
    up ip route replace 10.0.107.0/24 via 10.0.40.1 dev eno1.40
    down ip route del 10.0.107.0/24 via 10.0.40.1 dev eno1.40
EOT
ifup eno1.40 && ip -br addr show eno1.40
```
Then in the controller, find the new client with MAC `02:00:5e:00:53:40` on the Media network and give it fixed IP **10.0.40.107**. Run `ifdown eno1.40 && ifup eno1.40` and check it now shows .107.

The `arp_ignore=1` line makes eno1.40 answer ARP only for its own addresses. Without it Linux answers a VLAN-40 ARP for 10.0.10.10 from eno1.40's MAC, dhcpcd on eno1 takes that for another device claiming .10, gives the address up and takes a pool address instead (happened 2026-11-07, 12:25).

The `arp_announce=2` line makes eno1.40 sign the ARP requests it sends with its own address (10.0.40.107). `arp_ignore` only covers replies: with the default `arp_announce=0` the kernel can still send a VLAN-40 ARP request with 10.0.10.10 as the sender, and dhcpcd on eno1 logs that as `02:00:5e:00:53:40 claims 10.0.10.10`. One claim is survived; two inside 10 seconds ("10 second defence failed") and eno1 drops .10 for a pool address, which takes AdGuard, Traefik and Minecraft off their known address while every container stays up (happened 2026-11-13, 04:43, after single claims on 11-07 and 11-08 had passed unnoticed). The cause is inferred from the journal, not from a packet capture. Check: `journalctl -b | grep 'claims 10.0.10.10'` prints nothing. Both sysctls must be `up` lines here, because `systemctl restart networking` recreates eno1.40 and resets them. If the address is already lost, set the sysctl and run `systemctl restart networking`.

The two route `up`/`down` lines send traffic for the IoT network (10.0.107.0/24, where the Reolink "Front" camera lives) out this interface. The controller's policy "Allow Scrypted to R…" (Media to IoT, TCP, destination 10.0.107.100) matches on the source MAC, so edit it in Settings, Policy Engine and change its source MAC to `02:00:5e:00:53:40` (it held the old Scrypted LXC's `bc:24:11:87:33:eb`). Without the route and the new MAC, Scrypted reaches the camera as TS_Server and every connection to 10.0.107.100 times out. Check: `ip route get 10.0.107.100` shows `dev eno1.40 src 10.0.40.107`, and `timeout 4 bash -c 'exec 3<>/dev/tcp/10.0.107.100/9000' && echo open` prints `open`.

```
# 3b. mounts: the Time Machine USB disk and the NAS backup share
mkdir -p /mnt/timemachine /mnt/mimir-backups
cat >> /etc/fstab <<'EOT'
UUID=c9e83c5b-df0e-4739-a1c1-fa648ec2894e  /mnt/timemachine     ext4  defaults,nofail  0 2
10.0.10.40:/volume1/pve-backups         /mnt/mimir-backups   nfs   vers=3,nofail     0 0
EOT
systemctl daemon-reload && mount -a && df -h /mnt/timemachine /mnt/mimir-backups
ls /mnt/mimir-backups/dump | tail -3
```
Both must show. If the NFS mount fails, the NAS export allows client 10.0.10.10 only; check the box really has .10.

```
# 3c. free port 53 and give the host's own resolver HA first, then the gateway, then one public server, never itself
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=10.0.10.20 10.0.10.1 1.1.1.1\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/homelab.conf
systemctl restart systemd-resolved && ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
getent hosts download.docker.com | head -1
ss -lunp | grep ':53 ' || echo "port 53 is free"
```
You should see an address for download.docker.com and "port 53 is free". `systemd-resolved` is its own package on Debian 13 and is installed in section 2; the `&&` matters, because linking `/etc/resolv.conf` to a resolver that is not running leaves the box with no DNS at all. If the `getent` line prints nothing, restore a working resolver and retry:
```
rm /etc/resolv.conf && echo "nameserver 10.0.10.20" > /etc/resolv.conf
```
The box ignores the DNS servers UniFi hands out (ifupdown does not pass DHCP DNS to resolved), so it keeps resolving if HA goes down. Failover is sticky: after HA stops answering, resolved stays on the next server until that one fails. The gateway (10.0.10.1, the UniFi forwarder) resolves DHCP client hostnames and forwards the rest, but the `*.home.example.com` names are AdGuard rewrites, so they do not resolve on the box while it is off HA. Docker, GitHub and apt still work.

```
# 3d. Docker from Docker's own repository
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list
apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
usermod -aG docker claude
docker run --rm hello-world | head -2
```

```
# 3e. the Bitwarden Secrets Manager CLI
V=$(curl -fsSL "https://api.github.com/repos/bitwarden/sdk-sm/releases?per_page=50" | jq -r '[.[] | select(.tag_name | startswith("bws-v"))][0].tag_name'); echo "$V"
curl -fsSL -o /tmp/bws.zip "https://github.com/bitwarden/sdk-sm/releases/download/$V/bws-x86_64-unknown-linux-gnu-${V#bws-v}.zip"
cd /tmp && unzip -o bws.zip && install -m 0755 bws /usr/local/bin/bws && bws --version
```
The first line prints the newest `bws-v…` tag. Do not use the repo's "latest release": `sdk-sm` also publishes the language SDKs (it pointed at `python-v2.1.0`), so that URL 404s. Checked with bws 2.1.0.

## 4. Restore the claude user's home and the repos

Run as root on the box. This brings back SSH keys, the Claude Code login, the three repo checkouts and the archive pipeline exactly as they were on LXC 105.

```
mkdir -p /mnt/old && cd /mnt/old
A=$(ls -t /mnt/mimir-backups/dump/vzdump-lxc-105-*.tar.zst | head -1); echo "$A"
zstd -dc "$A" | tar -xf - --numeric-owner ./home/claude ./etc/systemd/system ./etc/sudoers.d ./etc/cron.d ./var/spool/cron 2>/dev/null
rsync -a --numeric-ids /mnt/old/home/claude/ /home/claude/
chown -R claude:claude /home/claude
ls /home/claude/workspace            # expect claude_sessions homelab-stack minecraft-stack and the rest
```
Then as `claude` (type `su - claude`). The restored checkout already has a local `debian-host` branch, so this needs no network:
```
curl -fsSL https://claude.ai/install.sh | bash && ~/.local/bin/claude --version
cd ~/workspace/homelab-stack && git checkout debian-host
git config --global core.hooksPath /home/claude/workspace/claude_sessions/.githooks
exit
```
The repo remotes are HTTPS and authenticate with `~/.secrets/gh-token.env`, which does not exist until section 5b, so `git pull` waits until 5c. Pulling now asks for a GitHub username and password and fails.

Back as root, install the claude user's crontab from the backup, without the Proxmox-only line (the restore extracts it into `/mnt/old` but does not install it):
```
grep -v pve_update_status /mnt/old/var/spool/cron/crontabs/claude > /tmp/claude.cron
crontab -u claude /tmp/claude.cron
crontab -u claude -l                 # expect only the unifi_ips_alerts line
```

## 5. Secrets

Run as root on the box. Each token goes in with its own paste, and that step waits for you: the `read` line prints a prompt and hides what you paste. Paste the `read` line **on its own**. If it is pasted together with the next line, `read` takes that line as the token.

```
# 5a. the stack's secrets (machine account `homelab-stack`): setup, no token yet
R=/home/claude/workspace/homelab-stack/scripts
install -d -m 0755 /usr/local/lib/homelab-stack && install -m 0755 $R/fetch_secrets.sh /usr/local/lib/homelab-stack/fetch_secrets.sh
install -m 0644 $R/homelab-stack-secrets.service $R/homelab-stack.service /etc/systemd/system/
install -d -m 0700 /etc/homelab-stack
```
Now the token. This waits for you; paste the token named `homelab-stack-secrets <yyyy-mm>`, then Enter:
```
read -rsp 'Paste the homelab-stack-secrets (homelab-stack) token, then press Enter: ' T; echo
```
Then encrypt it and start the service:
```
printf '%s\n' "$T" | systemd-creds encrypt --name=bws-token - /etc/homelab-stack/bws-token.cred; unset T
chmod 0600 /etc/homelab-stack/bws-token.cred
install -d -m 0755 /etc/systemd/system/docker.service.d && install -m 0644 $R/docker.service.d/*.conf /etc/systemd/system/docker.service.d/
systemctl daemon-reload && systemctl enable --now homelab-stack-secrets.service
journalctl -u homelab-stack-secrets.service --no-pager | tail -2
```
Expect "wrote 7 files to /run/homelab-stack from BWS" (seven: the four base files plus `timemachine.env`, `adguardhome-sync.env` and `restic.env`). The "not located on encrypted media" warning from `systemd-creds` only means the disk is not encrypted; it is harmless.

```
# 5b. the claude user's secrets (machine account claude): setup, no token yet
R=/home/claude/workspace/homelab-stack/scripts
install -d -m 0755 /usr/local/lib/claude-secrets && install -m 0755 $R/fetch_claude_secrets.sh /usr/local/lib/claude-secrets/fetch_secrets.sh
install -m 0644 $R/claude-secrets.service $R/home-claude-.secrets.mount /etc/systemd/system/
install -d -m 0700 /etc/claude-secrets
```
Now the token. This waits for you; paste the token named `claude-secrets <yyyy-mm>`, then Enter:
```
read -rsp 'Paste the claude-secrets (claude) token, then press Enter: ' T; echo
```
Then encrypt it and start the units:
```
printf '%s\n' "$T" | systemd-creds encrypt --name=bws-token - /etc/claude-secrets/bws-token.cred; unset T
chmod 0600 /etc/claude-secrets/bws-token.cred
systemctl daemon-reload && systemctl enable --now home-claude-.secrets.mount claude-secrets.service
ls /home/claude/.secrets                                                        # expect homeassistant healthchecks-ping-url ... gh-token.env
systemctl restart docker
```

5c. Pull the repos. This needs 5b, because the git remotes authenticate with `~/.secrets/gh-token.env`. Type `su - claude` first, then paste:
```
cd ~/workspace/homelab-stack && git fetch -q && git pull -q
cd ~/workspace/claude_sessions && git pull -q
cd ~/workspace/minecraft-stack && git pull -q
exit
```
These finish quietly. A username or password prompt means 5b did not mount `~/.secrets`; stop and check `ls /home/claude/.secrets`.

## 6. Bring the stack up

Run as root on the box. Copy the live data out of the 101 backup first.

```
cd /mnt/old
A=$(ls -t /mnt/mimir-backups/dump/vzdump-lxc-101-*.tar.zst | head -1)
zstd -dc "$A" | tar -xf - --numeric-owner ./home/claude/homelab-stack/appdata ./home/claude/homelab-stack/logs
rsync -a --numeric-ids /mnt/old/home/claude/homelab-stack/appdata/ /home/claude/workspace/homelab-stack/appdata/
rsync -a --numeric-ids /mnt/old/home/claude/homelab-stack/logs/    /home/claude/workspace/homelab-stack/logs/
ls /home/claude/workspace/homelab-stack/appdata/traefik/acme.json   # the wildcard certificate; must exist

# AdGuard: config from the nightly backup, data from the LXC 100 backup
A=$(ls -t /mnt/mimir-backups/dump/vzdump-lxc-100-*.tar.zst | head -1)
zstd -dc "$A" | tar -xf - --numeric-owner ./opt/AdGuardHome/data
install -d /home/claude/workspace/homelab-stack/appdata/adguard/conf /home/claude/workspace/homelab-stack/appdata/adguard/work
cp /home/claude/workspace/claude_sessions/adguard-backup/AdGuardHome.yaml /home/claude/workspace/homelab-stack/appdata/adguard/conf/
# the nightly API backup redacts the login hash ("password: REDACTED"): take the real one from the LXC 100 backup
zstd -dc "$A" | tar -xf - --numeric-owner ./opt/AdGuardHome/AdGuardHome.yaml
python3 -I - <<'EOF'
import re
old=open('/mnt/old/opt/AdGuardHome/AdGuardHome.yaml').read()
h=re.search(r'^users:.*?password:\s*(\S+)',old,re.S|re.M).group(1)
p='/home/claude/workspace/homelab-stack/appdata/adguard/conf/AdGuardHome.yaml'
s=open(p).read()
open(p,'w').write(re.sub(r'(^users:.*?password:\s*)\S+',lambda m:m.group(1)+h,s,count=1,flags=re.S|re.M))
EOF
rsync -a /mnt/old/opt/AdGuardHome/data/ /home/claude/workspace/homelab-stack/appdata/adguard/work/data/

# Scrypted: its whole state directory from the LXC 10443 backup
A=$(ls -t /mnt/mimir-backups/dump/vzdump-lxc-10443-*.tar.zst | head -1)
zstd -dc "$A" | tar -xf - --numeric-owner ./root/.scrypted/volume
install -d /home/claude/workspace/homelab-stack/appdata/scrypted
rsync -a /mnt/old/root/.scrypted/volume/ /home/claude/workspace/homelab-stack/appdata/scrypted/volume/

# Time Machine advertisement
install -m 0644 /home/claude/workspace/homelab-stack/timemachine/avahi-timemachine.service /etc/avahi/services/timemachine.service
systemctl restart avahi-daemon

# site settings first: without .env the unit fails and nothing is started
cp -n /home/claude/workspace/homelab-stack/.env.example /home/claude/workspace/homelab-stack/.env   # then fill in the real addresses and domain
systemctl enable --now homelab-stack.service
docker compose --env-file /run/homelab-stack/env -f /home/claude/workspace/homelab-stack/docker-compose.yml ps --format '{{.Name}}\t{{.Status}}'
```
Every container should say Up.

- `https://ha-web.home.example.com` loads through Traefik with a valid certificate.
- `dig +short @10.0.10.10 adguard.home.example.com` answers.
- `https://adguard.home.example.com` shows AdGuard with its old settings. DNS still points that name at the old host until step 9, so on your laptop add `10.0.10.10 adguard.home.example.com` to `/etc/hosts` for now and remove it after step 9. Log in with your usual AdGuard account.
- In Finder, Go, Network: "homelab" appears with the TimeMachine share; in System Settings, Time Machine still lists the disk.
- **Time Machine can write, not just connect.** Run `find /mnt/timemachine -xdev ! -uid 1000 | grep -v lost+found | wc -l`; it must print 0. If not, `docker exec timemachine chown -R 1000:1000 /opt/tmuser/` (a bundle carried over from the LXC is owned by uid 101000, and the container's `SET_PERMISSIONS` does not fix files inside it). Then run Back Up Now on a Mac and watch it finish; listing the share is not enough. See docs/services.md, timemachine.
- `https://10.0.40.107:10443` shows the Scrypted console; the doorbell tile works in the Home app.

Give the `claude` user the deploy rule: `echo 'claude ALL=(root) NOPASSWD: /usr/bin/systemctl, /usr/bin/journalctl' > /etc/sudoers.d/claude && chmod 0440 /etc/sudoers.d/claude`.

## 7. Minecraft

Run as root on the box.
```
cd /mnt/old
A=$(ls -t /mnt/mimir-backups/dump/vzdump-lxc-111-*.tar.zst | head -1)
zstd -dc "$A" | tar -xf - --numeric-owner ./home/claude/minecraft-stack/data ./home/claude/minecraft-stack/backups
rsync -a --numeric-ids /mnt/old/home/claude/minecraft-stack/data/    /home/claude/workspace/minecraft-stack/data/
rsync -a --numeric-ids /mnt/old/home/claude/minecraft-stack/backups/ /home/claude/workspace/minecraft-stack/backups/
chown -R claude:claude /home/claude/workspace/minecraft-stack
ln -sf /home/claude/.secrets/minecraft-stack.env /home/claude/workspace/minecraft-stack/.env     # RCON_PASSWORD comes from BWS (minecraft-stack-env)
cd /home/claude/workspace/minecraft-stack && docker compose up -d && docker compose ps
```
Check: a Minecraft client connects to `minecraft.home.example.com` (after step 9) or `10.0.10.10` now.

## 8. Timers, Remote Control and the sweep bot

As root on the box:
```
M=/home/claude/workspace/claude_sessions/maintainer/systemd; R=/home/claude/workspace/homelab-stack/scripts
loginctl enable-linger claude
```
The unit runs `/usr/local/bin/claude`, but Claude Code is installed under the `claude` user's home, so link it, then start the user units. `runuser` from root needs `XDG_RUNTIME_DIR` for `systemctl --user`:
```
ln -sf /home/claude/.local/bin/claude /usr/local/bin/claude
runuser -l claude -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); mkdir -p ~/.config/systemd/user && cp ~/workspace/claude_sessions/maintainer/systemd/claude-remote-control.service ~/workspace/claude_sessions/maintainer/systemd/claude-archive-backfill.* ~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user enable --now claude-remote-control.service claude-archive-backfill.timer; systemctl --user is-active claude-remote-control.service claude-archive-backfill.timer'
```
Expect `active` twice (`activating` means the unit is crash-looping: `journalctl --user -u claude-remote-control` as claude).
Remote Control needs a full login, not the long-lived token. As `claude`, once: `env -u CLAUDE_CODE_OAUTH_TOKEN claude auth login`, then `env -u CLAUDE_CODE_OAUTH_TOKEN claude auth status` must show `loggedIn: true`. Keep `CLAUDE_CODE_OAUTH_TOKEN` out of `~/.profile`, the unit and its drop-ins (`docs/secrets.md`, "The Claude Code long-lived token"). Starting or restarting the unit ends any live phone session, so do it before the check below, not during one.
Check: open the Claude app, pick the `claude_sessions · homelab` environment and start a session; it runs on the box.

The maintainer sweep bot (users `maintainer` and `maintainer-ctl`, their units, the `maintainer` machine-account token) is re-installed from `claude_sessions/maintainer/README.md`, steps 1 to 5. It is not needed for the house to work; do it after everything else works.

## 9. Last: move DNS (first rebuild only)

1. AdGuard rewrites, in the config file (restored from the backup, they still point at the old Traefik, and the file has `rewrites_enabled: false`, so nothing applies until it is switched on). The host names (`framework`, `homeassistant`, ...) are not rewrites, they come from the controller's DHCP names, so there is deliberately no `*.home.example.com` wildcard. AdGuard rewrites support only a leading `*.`, so each service name is listed. Run as root; it stops AdGuard first because AdGuard rewrites its config on shutdown:
```
C=/home/claude/workspace/homelab-stack/appdata/adguard/conf/AdGuardHome.yaml
docker stop adguard && cp $C $C.bak
python3 -I - <<'EOF'
import re
p='/home/claude/workspace/homelab-stack/appdata/adguard/conf/AdGuardHome.yaml'
s=open(p).read()
names="cc map ns1-web unifi-web ha-web ns2-web traefik-web minecraft adguard agent-web".split()
m=re.search(r'^(  )rewrites:\n(?:    - domain:.*\n      answer:.*\n      enabled:.*\n)+',s,re.M)
if not m: raise SystemExit("rewrites block not found; nothing changed")
block="  rewrites:\n"+"".join(f"    - domain: {n}.home.example.com\n      answer: 10.0.10.10\n      enabled: true\n" for n in names)
open(p,'w').write((s[:m.start()]+block+s[m.end():]).replace("rewrites_enabled: false","rewrites_enabled: true"))
print("wrote", len(names), "rewrites")
EOF
docker start adguard && sleep 8 && for h in adguard minecraft ha-web; do echo -n "$h: "; dig +short $h.home.example.com @10.0.10.10; done
```
Expect `wrote 14 rewrites` and `10.0.10.10` on every line. (If the rewrites list is `rewrites: []` the regex finds nothing: add one entry through the UI first, or insert the block by hand.)

2. In the controller, Settings, Networks: on every network whose DHCP DNS server 1 is `10.0.10.100` (not only TS_Server: the laptop network, Media, IoT, ...) change it to `10.0.10.10`. Leave DNS server 2 at `10.0.10.20`.
3. Home Assistant, Settings, System, Network: this HA version moved the HTTP settings into the UI and ignores an `http:` block in `configuration.yaml` (remove it, a repair notice says so). In the UI's trusted proxies list replace `10.0.10.101` with `10.0.10.10`, with X-Forwarded-For on, and restart HA. Without it HA answers every proxied request with 400 and `https://ha-web.home.example.com` shows "Unable to connect". Check on the box: `curl -sk -o /dev/null -w '%{http_code}\n' https://ha-web.home.example.com --resolve ha-web.home.example.com:443:10.0.10.10` prints 200.
4. On your laptop force a lease renewal on the interface that carries DNS (leases last 8 hours; `scutil --dns | grep -E 'nameserver|if_index' | head` shows it, and it is not always Wi-Fi): `sudo ipconfig set <interface> DHCP`. Then `dscacheutil -q host -a name home-web.home.example.com` should print 10.0.10.10 and `scutil --dns` should list 10.0.10.10 first. Remove the `/etc/hosts` line from step 6.

HA Green's own AdGuard (DNS 2, 10.0.10.20) is kept identical by the `adguard-sync` container in this stack (origin `http://adguard`, replica `http://10.0.10.20:3000`, every 10 minutes and at start). Check: `docker logs --tail 5 adguard-sync` shows a completed sync, then `dig +short grafana-web.home.example.com @10.0.10.20` prints 10.0.10.10.

## 10. Backups of the new layout

As root on the box. The repository path and passphrase come from BWS (`restic-env`, fetched to `/run/homelab-stack/restic.env`); nothing is written to `/etc`. The loop loads the two lines literally, so symbols in the passphrase are safe (do not `source` the file):
```
mountpoint /mnt/mimir-backups                                 # must say "is a mountpoint"
while IFS= read -r l || [ -n "$l" ]; do export "$l"; done < /run/homelab-stack/restic.env
restic init                                                   # uses RESTIC_REPOSITORY and RESTIC_PASSWORD
restic backup /home/claude/workspace/homelab-stack/appdata /home/claude/workspace/minecraft-stack/data /home/claude/workspace/minecraft-stack/backups /home/claude /etc --exclude /home/claude/.cache --exclude /home/claude/.secrets
restic snapshots
# restore test: one directory to /tmp
restic restore latest --target /tmp/restore-test --include /home/claude/workspace/homelab-stack/appdata/adguard && ls /tmp/restore-test/home/claude/workspace/homelab-stack/appdata/grafana
```
Nightly timer (03:30, keeps 7 daily, 4 weekly, 6 monthly; skips `.cache`, `.secrets`, `.rustup`, `.cargo`):
```
install -m 0644 /home/claude/workspace/homelab-stack/scripts/restic-backup.service /home/claude/workspace/homelab-stack/scripts/restic-backup.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now restic-backup.timer
systemctl start restic-backup.service      # test run, waits until the backup ends
journalctl -u restic-backup -n 5 --no-pager
```
A successful run sets `input_datetime.restic_backup_last_success` in Home Assistant through `scripts/ha_mark_success.sh`; the "Restic backup stale" alert there fires after 36 h without one.

## Rollback to Proxmox (first rebuild only)

Reinstall Proxmox from its USB stick, give it 10.0.10.10 (it will take the reservation), mount the NAS share as storage `mimir-backups` (Datacenter, Storage, Add, NFS, server 10.0.10.40, export `/volume1/pve-backups`), restore `/etc/network/interfaces` and `/etc/fstab` from `pve-host-config-<date>.tgz`, then for each guest:
```
pct restore 101 /mnt/pve/mimir-backups/dump/vzdump-lxc-101-<date>.tar.zst --storage local-lvm
```
Six restores and `pct start`, and you are back where Friday ended.

## Afterwards

- [x] Prometheus cleanup: the `pve` scrape job, pve-exporter and the Proxmox dashboard are gone (restic last-success alert added, `restic_backup_last_success_timestamp`).
- [x] Grafana `Proxmox *` / `Guest *` rules deleted 2026-11-07; then the whole Prometheus/Grafana stack was retired the same day (claude_sessions#38), alerting lives in Home Assistant (`docs/alerting.md`). BWS: delete `monitoring-pve-exporter-pve-yml`, `monitoring-unpoller-up-conf`, `monitoring-adguard-exporter-env`, the three `pushover-*` entries and `grafana`.
- [x] Controller: old reservations deleted.
- [x] `docs/host-bootstrap.md` replaces the old Proxmox bootstrap guide as the rebuild guide.
- [ ] Delete the Proxmox vzdump history on mimir after the restic restore test has passed and a week has gone by. Delete `/mnt/old` on the box.
- [ ] Close homelab-stack#8 in favour of the one-host failed-unit rule.
