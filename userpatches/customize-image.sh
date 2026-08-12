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
apt-get install -y network-manager wpasupplicant wireless-tools rfkill i2c-tools || true
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
SSID="2333666"
PSK="enenredick233"
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

# === 新增：上电/电源/PMU 早期调试脚本和 systemd 服务（输出到串口） ===
# 目的：在 sysinit 之前尽早运行，直接把结果输出到指定串口以方便只读 TTL 情况下观察
# 请根据你的板子串口修改 TTY_PATH（默认使用 ttyS2，因为 boot script 中使用 console=ttyS2）
TTY_PATH=/dev/ttyS2

cat > /usr/local/bin/power-debug-early.sh <<'POWDBG'
#!/bin/sh
set -eu

# power-debug-early.sh - run early and print directly to serial
# Note: avoid commands requiring network or complex services

echo "=== POWER DEBUG EARLY START: $(date -u) ==="
uname -a || true

echo "--- /proc/cmdline ---"
cat /proc/cmdline || true

echo "--- tail dmesg (last 200) ---"
dmesg | tail -n 200 || true

echo "--- dmesg grep PM/PMIC/charger/PD ---"
dmesg | grep -i -E 'pmu|pm_domain|power|rk809|rk817|cn3705|sc8886|husb|husb311|charger|power_supply|regulator|genpd' || true

echo "--- /sys/class/power_supply ---"
if [ -d /sys/class/power_supply ]; then
  for p in /sys/class/power_supply/*; do
    echo "== $p =="
    cat "$p"/uevent 2>/dev/null || true
    for f in type status online present capacity voltage_now current_now; do
      [ -f "$p/$f" ] && echo "$f: $(cat $p/$f 2>/dev/null)"
    done
  done
fi

echo "--- /sys/class/regulator summary ---"
if [ -d /sys/class/regulator ]; then
  for r in /sys/class/regulator/*; do
    echo "== $r =="
    [ -f "$r/enable" ] && echo "enable: $(cat $r/enable 2>/dev/null)"
    [ -f "$r/microvolts" ] && echo "microvolts: $(cat $r/microvolts 2>/dev/null)"
  done
fi

# GPIO quick summary
if [ -f /sys/kernel/debug/gpio ]; then
  echo "--- /sys/kernel/debug/gpio ---"
  cat /sys/kernel/debug/gpio || true
elif [ -d /sys/class/gpio ]; then
  echo "--- exported GPIOs ---"
  ls -l /sys/class/gpio || true
fi

# I2C quick scan if i2cdetect exists (safe, read-only scan)
if command -v i2cdetect >/dev/null 2>&1; then
  echo "--- i2c buses ---"
  i2cdetect -l || true
  for bus in /sys/bus/i2c/devices/i2c-*; do
    busnum=$(basename "$bus" | cut -d- -f2)
    echo "i2cdetect -y -r $busnum"
    i2cdetect -y -r "$busnum" || true
  done
else
  echo "i2c-tools not installed"
fi

# Platform devices relevant to PMIC/charger
ls /sys/bus/platform/devices | egrep -i 'pmu|charger|usb|rk809|rk817|husb|cn3705|sc8886' || true

echo "=== POWER DEBUG EARLY END: $(date -u) ==="
POWDBG

chmod +x /usr/local/bin/power-debug-early.sh || true

cat > /etc/systemd/system/power-debug-early.service <<'POWESVC'
[Unit]
Description=Power/PMU early debug collector (prints to serial)
DefaultDependencies=no
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/power-debug-early.sh
StandardOutput=tty
StandardError=inherit
TTYPath=/dev/ttyS2
TTYReset=yes
TimeoutStartSec=0

[Install]
WantedBy=sysinit.target
POWESVC

# Enable early service and disable getty on that tty to avoid conflict
systemctl enable power-debug-early.service || true
systemctl mask getty@ttyS2.service || true

# === 保留之前的 power-debug 服务（full log to /var/log） ===
cat > /usr/local/bin/power-debug.sh <<'POWDEBUG'
#!/bin/bash
set -euo pipefail
LOGDIR=/var/log
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
OUT="${LOGDIR}/power-debug-${TIMESTAMP}.log"
SUMMARY="${LOGDIR}/power-debug-latest.log"
exec > >(tee -a "$OUT" "$SUMMARY") 2>&1

echo "=== POWER DEBUG START: $(date -u) ==="
uname -a
cat /proc/cmdline || true

echo "--- dmesg (last 200 lines) ---"
dmesg | tail -n 200 || true

echo "--- grep PM/PMU/NPU/CHARGE/PD ---"
dmesg | grep -i -E 'pmu|pm_domain|power|rk809|rk817|cn3705|sc8886|husb|husb311|npu|rknpu|charger|battery|power_supply' || true

echo "--- /sys/class/power_supply ---"
if [ -d /sys/class/power_supply ]; then
  for p in /sys/class/power_supply/*; do
    echo "== $p =="
    cat "$p"/uevent 2>/dev/null || true
    for f in $(ls -1 "$p" 2>/dev/null); do
      case "$f" in
        uevent) ;;
        type|status|online|present|capacity|voltage_now|current_now|charge_full|charge_now)
          echo "$f:"; cat "$p/$f" 2>/dev/null || true;;
      esac
    done
  done
fi

echo "--- /sys/class/regulator ---"
if [ -d /sys/class/regulator ]; then
  for r in /sys/class/regulator/*; do
    echo "== $r =="; for f in enabled microvolts cur_microamp consumer_supply; do echo "$f:"; cat "$r/$f" 2>/dev/null || true; done
  done
fi

# GPIO summary
echo "--- GPIO status (/sys/kernel/debug/gpio if available, else /sys/class/gpio ) ---"
if mountpoint -q /sys/kernel/debug; then
  if [ -f /sys/kernel/debug/gpio ]; then
    cat /sys/kernel/debug/gpio || true
  fi
fi
if [ -d /sys/class/gpio ]; then
  echo "Exported GPIOs:"; ls -1 /sys/class/gpio || true
fi

# I2C buses and devices
echo "--- I2C buses (/sys/bus/i2c/devices) ---"
if [ -d /sys/bus/i2c/devices ]; then
  ls -l /sys/bus/i2c/devices || true
  echo "-- Bus probes (if i2c-tools installed) --"
  if command -v i2cdetect >/dev/null 2>&1; then
    for bus in /sys/bus/i2c/devices/i2c-*; do
      busnum=$(basename "$bus" | cut -d- -f2)
      echo "i2cdetect -y -r $busnum" || true
      i2cdetect -y -r "$busnum" || true
    done
  else
    echo "i2c-tools (i2cdetect) not installed"
  fi
fi

# List platform devices relevant to PMIC/charger
echo "--- Platform devices (grep for pmu/charger/usb/power) ---"
ls /sys/bus/platform/devices | egrep -i 'pmu|charger|usb|rk809|rk817|husb|cn3705|sc8886' || true

# debugfs: clk and genpd
echo "--- debugfs: clocks and genpd (if mounted) ---"
if [ -d /sys/kernel/debug ]; then
  if [ -f /sys/kernel/debug/clk/clk_summary ]; then
    echo "--- clk_summary ---"; sed -n '1,200p' /sys/kernel/debug/clk/clk_summary || true
  fi
  if [ -d /sys/kernel/debug/pm_genpd ]; then
    echo "--- pm_genpd ---"; ls -l /sys/kernel/debug/pm_genpd || true
    for d in /sys/kernel/debug/pm_genpd/*; do echo "== $d =="; cat "$d" 2>/dev/null || true; done
  fi
fi

# Show regulator/pmu kernel messages
echo "--- journalctl -k | grep -i pmu|regulator (last 200 lines) ---"
journalctl -k -n 200 --no-pager | egrep -i 'pmu|regulator|power domain|genpd|rk809|rk817|cn3705|sc8886|husb' || true

# Save dmesg full to separate file for later upload
dmesg > "${LOGDIR}/power-debug-dmesg-${TIMESTAMP}.log" || true

# Keep only last 5 rotated logs to save space
ls -1t ${LOGDIR}/power-debug-*.log 2>/dev/null | tail -n +6 | xargs -r rm -f

echo "=== POWER DEBUG END: $(date -u) ==="
POWDEBUG

cat > /etc/systemd/system/power-debug.service <<'POWDSVC'
[Unit]
Description=Power/PMU debug collector
After=multi-user.target network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/power-debug.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
POWDSVC

# Enable services so they run at first boot
systemctl enable power-debug.service || true

# End of script

# === v34: Live hardware extraction (update-motd.d + /boot/) ===
# This runs at boot, extracts live FDT/GPIO/IOMUX/PWM/clocks/PD/USB/regulators
# Output goes to /etc/motd and /boot/ files

mkdir -p /etc/update-motd.d
cat > /etc/update-motd.d/99-live-extract <<'MOTDEOF'
#!/bin/bash
# v34 - Live hardware extraction (runs at every boot via update-motd.d)
MARKER=/tmp/.extract_done
OUT=/root/v34_extract.txt
BOOT=/boot

if [ -f "$MARKER" ]; then
    [ -f "$OUT" ] && cat "$OUT"
    exit 0
fi

{
    echo ""
    echo "=========================================="
    echo " v34 LIVE HARDWARE EXTRACTION"
    echo "=========================================="

    # 1. Live FDT -> base64
    if [ -f /sys/firmware/fdt ]; then
        cp /sys/firmware/fdt "$BOOT/v2_real_live.dtb"
        sz=$(stat -c%s /sys/firmware/fdt)
        echo "FDT: ${sz} bytes"
        echo "---BEGIN FDT BASE64---"
        base64 /sys/firmware/fdt
        echo "---END FDT BASE64---"
    fi

    # 2. GPIO
    echo "=== GPIO ==="
    cat /sys/kernel/debug/gpio > "$BOOT/v2_gpio_live.txt"
    cat /sys/kernel/debug/gpio

    # 3. IOMUX
    echo "=== IOMUX ==="
    cat /sys/kernel/debug/pinctrl/*/pinmux-pins > "$BOOT/v2_iomux_live.txt" 2>/dev/null
    cat /sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null

    # 4. PWM
    echo "=== PWM ==="
    cat /sys/kernel/debug/pwm > "$BOOT/v2_pwm_live.txt"
    cat /sys/kernel/debug/pwm

    # 5. Clocks
    echo "=== CLOCKS (USB/PWM/eDP) ==="
    grep -iE "pwm|pipe|usb|edp|vop" /sys/kernel/debug/clk/clk_summary > "$BOOT/v2_clk_live.txt"
    grep -iE "pwm|pipe|usb|edp|vop" /sys/kernel/debug/clk/clk_summary

    # 6. Power domains
    echo "=== POWER DOMAINS ==="
    cat /sys/kernel/debug/pm_genpd/pm_genpd_summary > "$BOOT/v2_pd_live.txt"
    cat /sys/kernel/debug/pm_genpd/pm_genpd_summary

    # 7. USB topology
    echo "=== USB TOPOLOGY ==="
    for dev in /sys/bus/usb/devices/*/; do
        [ -f "$dev/speed" ] && echo "$(basename $dev): speed=$(cat $dev/speed) vid=$(cat $dev/idVendor 2>/dev/null) pid=$(cat $dev/idProduct 2>/dev/null)"
    done

    # 8. Regulators
    echo "=== REGULATORS ==="
    for r in /sys/class/regulator/*/; do
        [ -d "$r" ] || continue
        name=$(cat "$r/name" 2>/dev/null)
        if echo "$name" | grep -qiE "usb|vbus|otg|host|lcd|vcc5v0|vcc3v3|pipe"; then
            echo "$(basename $r): $name uV=$(cat $r/microvolts 2>/dev/null) state=$(cat $r/state 2>/dev/null)"
        fi
    done

    # 9. dmesg
    echo "=== DMESG ==="
    dmesg | grep -iE "usb|dwc3|drm|edp|panel|backlight|pwm|pipe|power.domain|pm_genpd|phy|vbus|husb|rockchip_drm|vop" | tail -200

    echo "=========================================="
    echo " v34 EXTRACTION COMPLETE"
    echo "=========================================="
} > $OUT 2>&1

cat $OUT
touch $MARKER
sync
MOTDEOF

chmod 755 /etc/update-motd.d/99-live-extract
echo "Live extraction script added to /etc/update-motd.d/99-live-extract"
