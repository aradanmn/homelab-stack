#!/usr/bin/env bash
# Enables SSH access to a SteamOS machine (Steam Deck, or the Framework PC since
# it moved to SteamOS) for user claude on host homelab (10.0.10.10).
# Came from the retired `infra` repo (2026-11-09). The key below is the public
# half of ~/.ssh/id_ed25519 on homelab; update it here if that key is replaced.
# Run in Konsole (Desktop Mode) as the deck user:  bash setup-claude-steamos.sh
#
# SteamOS notes: /home and /etc persist across SteamOS updates, so both the
# key and the sshd enablement survive. No separate user is created — SteamOS
# is built around the 'deck' user and its immutable rootfs makes extra
# accounts more trouble than they're worth.
set -euo pipefail

PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIGCCkF8Kr3otZWl49zo/Oh9yfMt79WNAcJ3MF6Z87J1 claude-lxc'

# --- ssh key for the deck user ---
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if ! grep -qF "$PUBKEY" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    echo "$PUBKEY" >> "$HOME/.ssh/authorized_keys"
fi
chmod 600 "$HOME/.ssh/authorized_keys"
echo "ssh key installed for user deck"

# --- sudo needs the deck account to have a password ---
if ! sudo -n true 2>/dev/null; then
    if ! passwd -S "$USER" 2>/dev/null | grep -q ' P '; then
        echo "No password set for $USER yet — setting one now (needed for sudo):"
        passwd
    fi
fi

# --- enable sshd now and on every boot ---
sudo systemctl enable --now sshd
echo "sshd enabled"

echo
echo "Current IPs (tell Claude which to use):"
ip -4 -o addr show scope global | awk '{print "  " $2 ": " $4}'
echo "Done."
