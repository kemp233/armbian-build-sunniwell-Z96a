#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# restore-board-154.sh - put the RK3576 board back into its known-good state
# after a full image flash.
#
# Usage: restore-board-154.sh
#
# The flash wipes the rootfs, so this recreates:
#   - the static WiFi address and the connection profile
#   - the rc.local network bootstrap (it must run before the exit 0)
#   - the ssh service
#   - the userland backup (models, rkvoice, rkvoice-stream, services)
#
# It is meant to run on the board itself, after the first boot.

set -uo pipefail

CON_NAME="${WIFI_CON:-2333666}"
SSID="${WIFI_SSID:-2333666}"
PSK="${WIFI_PSK:-enenredick233}"
IP="${BOARD_IP:-192.168.50.154}/24"
GW="${BOARD_GW:-192.168.50.1}"
DNS="${BOARD_DNS:-192.168.50.1 8.8.8.8}"
BACKUP="${BACKUP_TARBALL:-/opt/userland-backup.tar.gz}"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

say "=== WiFi connection ==="
if nmcli con show "$CON_NAME" >/dev/null 2>&1; then
    nmcli con mod "$CON_NAME" \
        ipv4.method manual ipv4.addresses "$IP" ipv4.gateway "$GW" ipv4.dns "$DNS" \
        wifi.ssid "$SSID" wifi.psk "$PSK" 2>/dev/null \
        || say "could not modify connection $CON_NAME"
else
    nmcli con add type wifi con-name "$CON_NAME" ifname wlan0 ssid "$SSID" \
        -- wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" 2>/dev/null \
        || say "could not create connection $CON_NAME"
    nmcli con mod "$CON_NAME" ipv4.method manual ipv4.addresses "$IP" \
        ipv4.gateway "$GW" ipv4.dns "$DNS" 2>/dev/null || true
fi

say "=== rc.local ==="
mkdir -p /etc/rc.local
cat > /etc/rc.local << 'EOF'
#!/bin/sh -e
# Network bootstrap for the RK3576 board.
ip link set wlan0 up
sleep 2
nmcli con up "2333666" || true
sleep 5
systemctl is-active --quiet ssh.service || systemctl start ssh.service
exit 0
EOF
chmod +x /etc/rc.local

say "=== ssh ==="
systemctl enable ssh.service 2>/dev/null || true
systemctl start ssh.service 2>/dev/null || true

say "=== userland backup ==="
if [ -s "$BACKUP" ]; then
    tar -C / -xzf "$BACKUP" 2>&1 | tail -3
    say "restored from $BACKUP"
else
    say "backup not found at $BACKUP (copy it over first)"
fi

say "=== docker ==="
if ! command -v docker >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq docker.io
fi
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{"iptables":false,"ip6tables":false,"bridge":"none","registry-mirrors":["https://docker.1ms.run"]}
EOF
systemctl restart docker 2>/dev/null || true

say "=== NPU mode helper ==="
if [ -x /opt/rknpu/install-npu-mode.sh ]; then
    /opt/rknpu/install-npu-mode.sh || true
fi

say "=== done. Current addresses ==="
ip -4 addr show wlan0 2>/dev/null | sed 's/^/    /'
