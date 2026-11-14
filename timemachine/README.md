# LXC 104 `timemachine`

Samba + Avahi serving the WD My Book (USB on pve, bind-mounted at
`/mnt/timemachine`, `mp0` in the container config) as a Time Machine
target for the Macs. Nothing else runs here. Tracked since 2026-11-04 so
the container can be rebuilt from this directory (claude_sessions#36, F9).

## Rebuild

1. Debian LXC, unprivileged, `nesting=1`, 1 core, 2 GB, 8 GB rootfs, DHCP
   (UniFi reservation 10.0.10.104), `onboot=1`, mount point
   `mp0: /mnt/timemachine,mp=/mnt/timemachine` from pve.
2. `apt install samba avahi-daemon prometheus-node-exporter`.
3. Copy `smb.conf` to `/etc/samba/smb.conf` and
   `avahi-timemachine.service` to `/etc/avahi/services/timemachine.service`.
4. Create the share user: `useradd -M -s /usr/sbin/nologin tmuser`, then
   `smbpasswd -a tmuser` with the password from Bitwarden (homelab vault,
   Time Machine item). `tmuser` is the only account the share needs. The
   container still carries two stale Samba accounts, `pvebackup` and
   `retrogames` (Proxmox now backs up to the NAS over NFS, retrogames moved
   to the NAS); remove them with `pdbedit -x pvebackup; pdbedit -x retrogames`.
5. `systemctl enable --now smbd nmbd avahi-daemon`.
6. The Mac picks the share up by Bonjour as "TimeMachine"; the
   `fruit:time machine max size = 1460G` cap is 80% of the disk and is the
   only tuning.

The plan of record is to retire this container and the My Book once the
NAS has a disk large enough for the ~1 TB bundle (claude_sessions#36, Q6).
