#!/bin/bash
set -euo pipefail

# 1. 设置 root 密码
echo "root:1234" | chpasswd

# 2. 强开 SSH
mkdir -p /etc/ssh
if grep -q '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null; then
  sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
else
  echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
fi
systemctl enable ssh || true

# 3. 彻底杀死 Armbian 首次运行向导（防止它占领串口）
systemctl mask armbian-firstrun.service || true
systemctl mask armbian-firstrun-config.service || true
# 关键：创建一个标志文件，告诉 Armbian 配置已完成
touch /root/.not_configured
rm -f /root/.not_configured

# === 无线网络：更可靠的方法 ===

# 0) 常见工具与固件（可选，若镜像已含这些包可跳过）
export DEBIAN_FRONTEND=noninteractive
apt-get update || true
# 安装 NetworkManager、wpasupplicant 与常见固件包；允许失败以免阻塞构建
apt-get install -y network-manager wpasupplicant wireless-tools rfkill || true
apt-get install -y firmware-realtek firmware-ralink linux-firmware || true

# 1) 确保 NetworkManager 在启动时可用
systemctl enable NetworkManager || true
systemctl restart NetworkManager || true

# 2) 解除硬/软阻塞
rfkill unblock all || true

# 3) 等待驱动加载（短等待），并确保接口被 NM 管理
# 注意：接口名可能不是 wlan0，脚本后面会尝试根据实际设备名创建连接
sleep 2

# 查找可能的无线接口（先找以 "wl" 开头的）
WIFIDEV=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wl|^wlan' | head -n1 || true)
# 如果未找到，回退使用 wlan0 作为尝试
if [ -z "${WIFIDEV}" ]; then
  WIFIDEV=wlan0
fi

# 4) 使用 nmcli 创建/修改连接（比直接写文件更可靠）
SSID="你的WiFi名称"
PSK="你的WiFi密码"
CON_NAME="DefaultWiFi"

# 如果已有同名连接则跳过创建
if ! nmcli -t -f NAME connection show | grep -qx "${CON_NAME}"; then
  nmcli connection add type wifi ifname "${WIFIDEV}" con-name "${CON_NAME}" ssid "${SSID}" || true
fi

# 设置 WPA-PSK、自动连接
nmcli connection modify "${CON_NAME}" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "${PSK}" connection.autoconnect yes 2>/dev/null || true
nmcli device set "${WIFIDEV}" managed yes 2>/dev/null || true

# 尝试立即连接（但不要让构建失败）
nmcli connection up "${CON_NAME}" ifname "${WIFIDEV}" || true

# 5) rc.local：将 IP 打到串口（保留原意，但增加串口回退）
cat > /etc/rc.local <<'RCLOCALEOF'
#!/bin/bash
(
    sleep 15
    while true; do
        # 优先写 /dev/ttyFIQ0，若不存在则回退到 /dev/ttyS0
        OUT=/dev/ttyFIQ0
        if [ ! -e "$OUT" ]; then OUT=/dev/ttyS0; fi

        echo "--- [MY IP ADDRESS IS] ---" > "$OUT"
        ip addr show | grep -E "inet .* (wlan|eth)" -n --color=never > "$OUT" || true
        sleep 5
    done
) &
exit 0
RCLOCALEOF
chmod +x /etc/rc.local

# End of script
