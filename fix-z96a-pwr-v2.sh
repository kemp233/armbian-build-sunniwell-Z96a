#!/usr/bin/env bash
# =============================================================================
# Z96a (Sunniwell RH218 / RK3568, RK809+SC8886 新板) — USB/eDP/充电链 一键修复 v2
#
# v2 = v1 (USB VBUS + eDP 3V3) + 新增:
#   [显示] 背光 pwm10 -> pwm9, 补 enable-gpios=GPIO2_D5; 面板 6bit (0x1009/bpc=6);
#          vcc3v3_lcd0_n vin 对齐原厂 vcc3v3_sys
#   [充电] sc8886: legacy 修正悬空 phandle 引用与中断脚(GPIO0_B2)/pinctrl;
#          edge 用原厂完整参数替换空壳节点; compatible 统一 southchip,sc8886;
#          新增 charger_ok pinctrl
#   [电量] battery 节点(rk817,battery + OCV 表 + saradc ch5 + 充电 LED 脚)
#          嵌套回 pmic@20 内 —— 原厂电量计节点必须在 PMIC 子级
#   [音频] i2c3 启用 + 两颗 ES7202 (0x30/0x32) 麦克风 ADC 节点
#
# 原厂参考: z96a-extract/233-analysis/dts/boot-0.dts (与实机 RK809-5/SC8886/HUSB311 一致)
# 兼容三种状态: 全新树 / 已跑过 v1 / 已跑过 v2 (幂等跳过)
# 用法: ./fix-z96a-pwr-v2.sh [备用仓库根目录]    备份: *.bak-pwrfix2
# =============================================================================
set -euo pipefail

MARKER="z96a-pwrfix-v2"
ROOT="${1:-$(cd "$(dirname "$0")" && pwd)}"

KLEG="$ROOT/patch/kernel/rockchip-rk3568-z96a/legacy/dt/rk3568-z96a-laptop-v2.dts"
KEDGE="$ROOT/patch/kernel/rockchip-rk3568-z96a/edge/dt/rk3568-z96a-laptop-v2.dts"
UBHAL="$ROOT/config/boards/hal/z96a-rk3568-laptop-v2/uboot/rk3568-z96a-laptop-v2.dts"
UBP1="$ROOT/userpatches/u-boot/u-boot-z96a-v2026.01/rk3568-z96a-laptop-v2.dts"
UBP2="$ROOT/patch/u-boot/u-boot-z96a-v2026.01/rk3568-z96a-laptop-v2.dts"

for f in "$KLEG" "$KEDGE" "$UBHAL" "$UBP1" "$UBP2"; do
	[[ -f "$f" ]] || { echo "缺失文件: $f (确认 ROOT=$ROOT 是正确的构建树)"; exit 1; }
done

python3 - "$MARKER" "$KLEG" "$KEDGE" "$UBHAL" "$UBP1" "$UBP2" <<'PYEOF'
import sys, shutil, subprocess, os

MARKER = sys.argv[1]
KLEG, KEDGE, UBHAL, UBP1, UBP2 = sys.argv[2:7]

# ---------- 共用 phandle (legacy/edge 两文件一致): gpio0=0x41 gpio2=0x132 gpio4=0x1e4
# saradc=0x1dd pwm9=0x1d7 pwm10=0x124 vcc3v3_sys=0x134 vcc5v0_sys=0x12f
# 新分配: charger_ok=0x330 battery=0x331 es7202=0x332 es7202b=0x333 (两文件均空闲)

HOST1_REG = """	vcc5v0-usb2-host1 {
		compatible = "regulator-fixed";
		regulator-name = "vcc5v0_usb2_host1";
		regulator-always-on;
		regulator-boot-on;
		regulator-min-microvolt = <0x4c4b40>;
		regulator-max-microvolt = <0x4c4b40>;
		enable-active-high;
		gpio = <0x1e4 0x0b 0x00>;
		vin-supply = <0x12f>;
		pinctrl-names = "default";
		pinctrl-0 = <0x32c>;
		phandle = <0x32d>;
	};

	vcc5v0-usb2-host2 {
		compatible = "regulator-fixed";
		regulator-name = "vcc5v0_usb2_host2";
		regulator-always-on;
		regulator-boot-on;
		regulator-min-microvolt = <0x4c4b40>;
		regulator-max-microvolt = <0x4c4b40>;
		enable-active-high;
		gpio = <0x1e4 0x09 0x00>;
		vin-supply = <0x12f>;
		pinctrl-names = "default";
		pinctrl-0 = <0x32e>;
		phandle = <0x32f>;
	};
"""

HOST1_HOST2_PINCTRL = """			vcc5v0-usb2-host1-en {
				rockchip,pins = <0x04 0x0b 0x00 0x116>;
				phandle = <0x32c>;
			};

			vcc5v0-usb2-host2-en {
				rockchip,pins = <0x04 0x09 0x00 0x116>;
				phandle = <0x32e>;
			};
"""

LCD_REG_FIXED = """	vcc3v3-lcd0-n {
		compatible = "regulator-fixed";
		regulator-name = "vcc3v3_lcd0_n";
		regulator-boot-on;
		regulator-always-on;
		regulator-min-microvolt = <0x325aa0>;
		regulator-max-microvolt = <0x325aa0>;
		enable-active-high;
		gpio = <0x41 0x17 0x00>;
		vin-supply = <0x12f>;
		pinctrl-names = "default";
		pinctrl-0 = <0x32b>;
		phandle = <0x326>;
	};
"""

LCD_PINCTRL = """			lcd0-pwr {
				rockchip,pins = <0x00 0x17 0x00 0x11f>;
				phandle = <0x32b>;
			};

"""

NTC = "<0x1745f 0x161f3 0x14f87 0x13d1b 0x12aaf 0x11842 0x10ad6 0xfd6a 0xeffe 0xe292 0xd524 0xcb2e 0xc138 0xb742 0xad4c 0xa355 0x9bed 0x9485 0x8d1d 0x85b5 0x7e4a 0x78b7 0x7324 0x6d91 0x67fe 0x626a 0x5e31 0x59f8 0x55bf 0x5186 0x4d49 0x4a0f 0x46d5 0x439b 0x4061 0x3d23 0x3aa7 0x382b 0x35af 0x3333 0x30b4 0x2ec4 0x2cd4 0x2ae4 0x28f4 0x2710 0x258f 0x240e 0x228d 0x210c 0x1f88 0x1e59 0x1d2a 0x1bfb 0x1acc 0x199c 0x18ac 0x17bc 0x16cc 0x15dc 0x14ec 0x142d 0x136e 0x12af 0x11f0 0x1131 0x1098 0xfff 0xf66 0xecd 0xe33 0xdb8 0xd3d 0xcc2 0xc47 0xbcb 0xb68 0xb05 0xaa2 0xa3f 0x9d9>"

# battery 节点 —— 必须是 pmic@20 的子节点 (3-tab 缩进)
BATTERY_BLOCK = """			battery {
				compatible = "rk817,battery";
				ocv_table = <0x19c8 0x1ab8 0x1b0a 0x1b58 0x1b98 0x1bd2 0x1bfa 0x1c16 0x1c32 0x1c52 0x1c7c 0x1cc4 0x1d18 0x1d6c 0x1dc2 0x1e22 0x1e84 0x1eee 0x1f5e 0x1fde 0x20aa>;
				design_capacity = <0x1405>;
				design_qmax = <0x157c>;
				bat_res = <0x96>;
				sleep_enter_current = <0x12c>;
				sleep_exit_current = <0x12c>;
				sleep_filter_current = <0x64>;
				power_off_thresd = <0x19c8>;
				zero_algorithm_vol = <0x1e14>;
				max_soc_offset = <0x3c>;
				monitor_sec = <0x05>;
				sample_res = <0x0a>;
				virtual_power = <0x00>;
				bat_res_up = <0x8c>;
				bat_res_down = <0x14>;
				design_max_voltage = <0x206c>;
				io-channels = <0x1dd 0x05>;
				io-channel-names = "battery-chan-5";
				enough-led-ctl-gpios = <0x41 0x1e 0x00>;
				charging-led-ctl-gpios = <0x41 0x1d 0x00>;
				phandle = <0x331>;
			};

"""

# charger_ok pinctrl (原厂 pcfg-pull-up=0x118, gpio0 B2)
CHARGER_PINCTRL = """		charger {

			charger_ok {
				rockchip,pins = <0x00 0x12 0x00 0x118>;
				phandle = <0x330>;
			};
		};

"""

ES7202_NODES = """		es7202@30 {
			compatible = "ES7202_PDM_ADC_1";
			status = "okay";
			reg = <0x30>;
			#sound-dai-cells = <0x00>;
			phandle = <0x332>;
		};

		es7202_sdi3@32 {
			compatible = "ES7202_PDM_ADC_2";
			status = "okay";
			reg = <0x32>;
			#sound-dai-cells = <0x00>;
			phandle = <0x333>;
		};
"""

def insert_i2c3(work):
    """i2c@fe5c0000: 启用总线 + 挂两颗 ES7202 (括号配平定位节点结束)"""
    if "es7202@30" in work:
        return work, "已存在"
    i = work.find("i2c@fe5c0000 {")
    if i < 0:
        raise RuntimeError("找不到 i2c@fe5c0000 节点")
    start = work.index("{", i)
    depth = 0
    for pos in range(start, len(work)):
        if work[pos] == "{": depth += 1
        elif work[pos] == "}":
            depth -= 1
            if depth == 0: break
    else:
        raise RuntimeError("i2c@fe5c0000 括号不配平")
    block = work[i:pos]
    if 'status = "disabled";' in block:
        work = work[:i] + block.replace('status = "disabled";', 'status = "okay";', 1) + work[pos:]
        i = work.find("i2c@fe5c0000 {"); start = work.index("{", i); depth = 0
        for pos in range(start, len(work)):
            if work[pos] == "{": depth += 1
            elif work[pos] == "}":
                depth -= 1
                if depth == 0: break
    # 在节点收尾 '};' 前插入
    close = work.rfind("\t};", i, pos + 2)
    work = work[:close] + "\n" + ES7202_NODES + "\t" + work[close:]
    return work, "已插入"

def apply(path, edits):
    src = open(path).read()
    if MARKER in src:
        print(f"  跳过(已修复 v2): {path}")
        return
    work = src
    try:
        for i, (old, new, cnt) in enumerate(edits):
            if new in work:            # 已应用(v1 或 v2 先前跑过) -> 跳过
                continue
            found = work.count(old)
            if found != cnt:
                raise RuntimeError(f"编辑 #{i}: 期望 {cnt} 处, 实际 {found} 处\n--- 期望片段 ---\n{old[:300]}")
            work = work.replace(old, new)
        work, note = insert_i2c3(work)
        work = work.replace("/dts-v1/;",
            f"/dts-v1/;\n/* {MARKER}: USB VBUS/eDP3V3/backlight-pwm9/panel-6bit/battery/sc8886/ES7202 aligned to factory DT */", 1)
    except RuntimeError as e:
        print(f"!! 中止: {path}\n{e}", file=sys.stderr)
        sys.exit(1)
    bak = path + ".bak-pwrfix2"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
    open(path, "w").write(work)
    print(f"  已修复: {path} (备份 {os.path.basename(bak)})")

# ============================ legacy (5.10) ============================
LEG_EDITS = [
# ---- v1: USB VBUS ----
("\t\tenable-active-high;\n\t\tgpio = <0x4c 0x0f 0x00>;\n\t\tvin-supply = <0x12f>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x130>;\n\t\tphandle = <0x112>;",
 "\t\tvin-supply = <0x12f>;\n\t\tphandle = <0x112>;", 1),
("\t\tgpio = <0x4c 0x0e 0x00>;", "\t\tgpio = <0x41 0x06 0x00>;", 1),
("\t\tgpio = <0x132 0x1d 0x00>;", "\t\tgpio = <0x41 0x05 0x00>;", 1),
("\t\tgpio = <0x41 0x15 0x00>;", "\t\tgpio = <0x132 0x1f 0x00>;", 1),
("\t\tpinctrl-0 = <0x133>;\n\t\tphandle = <0x40>;\n\n\tvcc3v3-lcd0-n {\n\t\tcompatible = \"regulator-fixed\";\n\t\tregulator-name = \"vcc3v3_lcd0_n\";\n\t\tregulator-boot-on;\n\t\tregulator-min-microvolt = <3300000>;\n\t\tregulator-max-microvolt = <3300000>;\n\t\tenable-active-high;\n\t\tgpio = <0x4c 0x07 0x00>;\n\t\tvin-supply = <0x12f>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x13a>;\n\t\tphandle = <0x326>;\n\t};\n\n\t};",
 "\t\tpinctrl-0 = <0x133>;\n\t\tphandle = <0x40>;\n\t};\n\n" + HOST1_REG + "\n" + LCD_REG_FIXED, 1),
("\t\t\t\trockchip,pins = <0x03 0x0e 0x00 0x116>;", "\t\t\t\trockchip,pins = <0x00 0x06 0x00 0x116>;", 1),
("\t\t\t\trockchip,pins = <0x02 0x1d 0x00 0x116>;", "\t\t\t\trockchip,pins = <0x00 0x05 0x00 0x116>;", 1),
("\t\t\t\trockchip,pins = <0x00 0x15 0x00 0x11f>;", "\t\t\t\trockchip,pins = <0x02 0x1f 0x00 0x11f>;", 1),
("\t\t\tlcd0-pwr {\n\t\t\t\trockchip,pins = <0x00 0x07 0x00 0x11f>;\n\t\t\t\tphandle = <0x32b>;\n\t\t\t};\n\t\t};",
 "\t\t\tlcd0-pwr {\n\t\t\t\trockchip,pins = <0x00 0x17 0x00 0x11f>;\n\t\t\t\tphandle = <0x32b>;\n\t\t\t};\n\n" + HOST1_HOST2_PINCTRL + "\t\t};", 1),
("\t\t\t\trockchip,pins = <0x00 0x1d 0x00 0x118>;", "\t\t\t\trockchip,pins = <0x00 0x15 0x00 0x118>;", 1),
("\t\t\tvbus-supply = <0x112>;\n\t\t\tinterrupt-parent = <0x41>;\n\t\t\tinterrupts = <0x1d 0x08>;\n\t\t\tstatus = \"okay\";",
 "\t\t\tvbus-supply = <0x40>;\n\t\t\tswitch-ctl-gpios = <0x1e4 0x1a 0x00>;\n\t\t\tinterrupt-parent = <0x41>;\n\t\t\tinterrupts = <0x15 0x08>;\n\t\t\tstatus = \"okay\";", 1),
("\t\t\ttry-power-role = \"sink\";", "\t\t\ttry-power-role = \"source\";", 1),
("\t\t\tphy-supply = <0x112>;\n\t\t\tphandle = <0x2b>;",
 "\t\t\tphy-supply = <0x114>;\n\t\t\tphandle = <0x2b>;", 1),
("\t\t\tstatus = \"okay\";\n\t\t\tphy-supply = <0x40>;\n\t\t\tphandle = <0x28>;",
 "\t\t\tstatus = \"okay\";\n\t\t\tphandle = <0x28>;", 1),
("\t\t\tstatus = \"okay\";\n\t\t\tphy-supply = <0x40>;\n\t\t\tphandle = <0x2d>;",
 "\t\t\tstatus = \"okay\";\n\t\t\tphy-supply = <0x114>;\n\t\t\tphandle = <0x2d>;", 1),
("\tedp-panel {\n\t\tcompatible = \"simple-panel\";\n\t\tstatus = \"okay\";\n\t\tpower-supply = <0x2f>; /* vcc3v3_pmu - LDO_REG6 on RK809 PMIC */",
 "\tedp-panel {\n\t\tcompatible = \"simple-panel\";\n\t\tstatus = \"okay\";\n\t\tpower-supply = <0x326>; /* vcc3v3_lcd0_n - GPIO0_C7, aligned to factory DT */", 1),
# ---- v2: 背光 pwm9 + 使能脚 ----
("\t\tpwms = <0x124 0x00 0x61a8 0x00>;", "\t\tpwms = <0x1d7 0x00 0x61a8 0x00>;", 1),
("\t\tdefault-brightness-level = <0xc8>;\n\t\tpower-supply = <0x2f>; /* vcc3v3_pmu - LDO_REG6 on RK809 PMIC */\n\t\tphandle = <0x13d>;",
 "\t\tdefault-brightness-level = <0xc8>;\n\t\tenable-gpios = <0x132 0x1d 0x00>;\n\t\tphandle = <0x13d>;", 1),
# ---- v2: 面板 6bit ----
("\t\tbus-format = <0x100a>;\n\t\tbpc = <0x08>;", "\t\tbus-format = <0x1009>;\n\t\tbpc = <0x06>;", 1),
# ---- v2: lcd vin -> vcc3v3_sys (原厂) ----
("\t\tvin-supply = <0x12f>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x32b>;\n\t\tphandle = <0x326>;",
 "\t\tvin-supply = <0x134>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x32b>;\n\t\tphandle = <0x326>;", 1),
# ---- v2: sc8886 中断脚 GPIO0_B2 + 悬空 pinctrl-0(0x46 指向 soc_slppin_slp) ----
("\t\t\tinterrupts = <0x1d 0x08>;\n\t\t\tpinctrl-names = \"default\";\n\t\t\tpinctrl-0 = <0x46>;",
 "\t\t\tinterrupts = <0x12 0x08>;\n\t\t\tpinctrl-names = \"default\";\n\t\t\tpinctrl-0 = <0x330>;", 1),
# ---- v2: sc8886 NTC io-channels 悬空 phandle(0x42=endpoint@0) -> saradc 0x1dd ----
("\t\t\tio-channels = <0x42 0x04>;", "\t\t\tio-channels = <0x1dd 0x04>;", 1),
# ---- v2: charger_ok pinctrl (fusb30x 组之后) ----
("\t\t\t\tphandle = <0x3f>;\n\t\t\t};\n\t\t};",
 "\t\t\t\tphandle = <0x3f>;\n\t\t\t};\n\t\t};\n\n" + CHARGER_PINCTRL.rstrip("\n"), 1),
# ---- v2: battery 节点嵌套进 pmic@20 (regulators 之后, codec 之前) ----
("\n\n\t\t\tcodec {\n\t\t\t\t#sound-dai-cells",
 "\n\n" + BATTERY_BLOCK + "\t\t\tcodec {\n\t\t\t\t#sound-dai-cells", 1),
]

# ============================ edge (6.1) ============================
EDGE_EDITS = [
# ---- v1 ----
("\t\t// enable-active-high;  // removed: always-on via vin-supply\n\t\t// gpio = <0x4c 0x0f 0x00>;  // removed: always-on via vin-supply\n\t\tvin-supply = <0x12f>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x130>;\n\t\tphandle = <0x112>;",
 "\t\tvin-supply = <0x12f>;\n\t\tphandle = <0x112>;", 1),
("\t\t// enable-active-high;  // removed: always-on via vin-supply\n\t\t// gpio = <0x4c 0x0e 0x00>;  // removed: always-on via vin-supply\n\t\tvin-supply = <0x12f>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x131>;\n\t\tphandle = <0x114>;",
 "\t\tenable-active-high;\n\t\tgpio = <0x41 0x06 0x00>;\n\t\tvin-supply = <0x12f>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x131>;\n\t\tphandle = <0x114>;", 1),
("\t\t// enable-active-high;  // removed: always-on via vin-supply\n\t\t// gpio = <0x132 0x1d 0x00>;  // removed: always-on via vin-supply\n\t\tvin-supply = <0x12f>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x133>;\n\t\tphandle = <0x40>;",
 "\t\tenable-active-high;\n\t\tgpio = <0x41 0x05 0x00>;\n\t\tvin-supply = <0x12f>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x133>;\n\t\tphandle = <0x40>;", 1),
("\tz96a-keyboad-vcc {",
 HOST1_REG + "\n" + LCD_REG_FIXED + "\n\tz96a-keyboad-vcc {", 1),
("\t\tgpio = <0x41 0x15 0x00>;", "\t\tgpio = <0x132 0x1f 0x00>;", 1),
("\t\t\t\trockchip,pins = <0x03 0x0e 0x00 0x116>;", "\t\t\t\trockchip,pins = <0x00 0x06 0x00 0x116>;", 1),
("\t\t\t\trockchip,pins = <0x02 0x1d 0x00 0x116>;", "\t\t\t\trockchip,pins = <0x00 0x05 0x00 0x116>;", 1),
("\t\t\t\trockchip,pins = <0x00 0x15 0x00 0x11f>;", "\t\t\t\trockchip,pins = <0x02 0x1f 0x00 0x11f>;", 1),
("\t\t\tz96a-camera-pwr {\n\t\t\t\trockchip,pins = <0x02 0x10 0x00 0x11f>;\n\t\t\t\tphandle = <0x136>;\n\t\t\t};\n\t\t};",
 "\t\t\tz96a-camera-pwr {\n\t\t\t\trockchip,pins = <0x02 0x10 0x00 0x11f>;\n\t\t\t\tphandle = <0x136>;\n\t\t\t};\n\n" + LCD_PINCTRL + HOST1_HOST2_PINCTRL + "\t\t};", 1),
("\t\t\t\trockchip,pins = <0x00 0x1d 0x00 0x118>;", "\t\t\t\trockchip,pins = <0x00 0x15 0x00 0x118>;", 1),
("\t\trockchip,pins = <0x00 0x1d 0x00 0x118>;", "\t\trockchip,pins = <0x00 0x15 0x00 0x118>;", 1),
("\t\t\t/* vcc5v0_usb (0x112): known-good VBUS rail on V2 */\n\t\t\tvbus-supply = <0x112>;\n\t\t\tinterrupt-parent = <0x41>;\n\t\t\tinterrupts = <0x1d 0x08>;\n\t\t\tstatus = \"okay\";",
 "\t\t\tvbus-supply = <0x40>;\n\t\t\tswitch-ctl-gpios = <0x1e4 0x1a 0x00>;\n\t\t\tinterrupt-parent = <0x41>;\n\t\t\tinterrupts = <0x15 0x08>;\n\t\t\tstatus = \"okay\";", 1),
("\t\t\ttry-power-role = \"sink\";", "\t\t\ttry-power-role = \"source\";", 1),
("\t\t\tphy-supply = <0x112>;\n\t\t\tpinctrl-names = \"default\";\n\t\t\tpinctrl-0 = <0x135>; /* z96a_keyboard_pwr - GPIO0_21 for GL852G hub power */\n\t\t\tphandle = <0x2b>;",
 "\t\t\tphy-supply = <0x114>;\n\t\t\tphandle = <0x2b>;", 1),
("\tedp-panel {\n\t\tcompatible = \"simple-panel\";\n\t\tstatus = \"okay\";\n\t\tpower-supply = <0x2f>; /* vcc3v3_pmu - LDO_REG6 on RK809 PMIC */",
 "\tedp-panel {\n\t\tcompatible = \"simple-panel\";\n\t\tstatus = \"okay\";\n\t\tpower-supply = <0x326>; /* vcc3v3_lcd0_n - GPIO0_C7, aligned to factory DT */", 1),
# ---- v2: 背光/面板/lcd vin (同 legacy) ----
("\t\tpwms = <0x124 0x00 0x61a8 0x00>;", "\t\tpwms = <0x1d7 0x00 0x61a8 0x00>;", 1),
("\t\tdefault-brightness-level = <0xc8>;\n\t\tpower-supply = <0x2f>; /* vcc3v3_pmu - LDO_REG6 on RK809 PMIC */\n\t\tphandle = <0x13d>;",
 "\t\tdefault-brightness-level = <0xc8>;\n\t\tenable-gpios = <0x132 0x1d 0x00>;\n\t\tphandle = <0x13d>;", 1),
("\t\tbus-format = <0x100a>;\n\t\tbpc = <0x08>;", "\t\tbus-format = <0x1009>;\n\t\tbpc = <0x06>;", 1),
("\t\tvin-supply = <0x12f>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x32b>;\n\t\tphandle = <0x326>;",
 "\t\tvin-supply = <0x134>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x32b>;\n\t\tphandle = <0x326>;", 1),
# ---- v2: sc8886 空壳(silergy) -> 原厂完整节点 ----
('\t\tsc8886@6b {\n\t\t\tcompatible = "silergy,sc8886";\n\t\t\treg = <0x6b>;\n\t\t\tstatus = "okay";\n\t\t\tphandle = <0x176>;\n\t\t};',
 '\t\tsc8886@6b {\n\t\t\tcompatible = "southchip,sc8886";\n\t\t\treg = <0x6b>;\n\t\t\tinterrupt-parent = <0x41>;\n\t\t\tinterrupts = <0x12 0x08>;\n\t\t\tpinctrl-names = "default";\n\t\t\tpinctrl-0 = <0x330>;\n\t\t\tti,charge-current = <0xf4240>;\n\t\t\tti,max-input-voltage = <0xe4e1c0>;\n\t\t\tti,max-input-current = <0x5b8d80>;\n\t\t\tti,max-charge-voltage = <0x803c20>;\n\t\t\tti,input-current = <0x2dc6c0>;\n\t\t\tti,input-current-sdp = <0x1e8480>;\n\t\t\tti,input-current-dcp = <0x1e8480>;\n\t\t\tti,input-current-cdp = <0x3567e0>;\n\t\t\tti,minimum-sys-voltage = <0x64b540>;\n\t\t\tti,otg-voltage = <0x4c4b40>;\n\t\t\tti,otg-current = <0x7a120>;\n\t\t\tpd-charge-only = <0x00>;\n\t\t\tntc_table = ' + NTC + ';\n\t\t\tntc_degree_from = <0x01 0x14>;\n\t\t\tio-channels = <0x1dd 0x04>;\n\t\t\tio-channel-names = "temp-chan-4";\n\t\t\ttemp_res_up = <0x2710>;\n\t\t\tlow_temp_off = <0x00>;\n\t\t\thigh_temp_off = <0x2b>;\n\t\t\tstatus = "okay";\n\t\t\tphandle = <0x176>;\n\t\t};', 1),
# ---- v2: charger_ok pinctrl + battery (同 legacy) ----
("\t\t\t\tphandle = <0x3f>;\n\t\t\t};\n\t\t};",
 "\t\t\t\tphandle = <0x3f>;\n\t\t\t};\n\t\t};\n\n" + CHARGER_PINCTRL.rstrip("\n"), 1),
("\n\n\t\t\tcodec {\n\t\t\t\t#sound-dai-cells",
 "\n\n" + BATTERY_BLOCK + "\t\t\tcodec {\n\t\t\t\t#sound-dai-cells", 1),
]

UB_APPEND = '''
/* ---- z96a-pwrfix: USB VBUS rails, aligned to factory DT ---- */
/ {
	vcc5v0_host: regulator-vcc5v0-host {
		compatible = "regulator-fixed";
		regulator-name = "vcc5v0_host";
		regulator-min-microvolt = <5000000>;
		regulator-max-microvolt = <5000000>;
		enable-active-high;
		gpio = <&gpio0 RK_PA6 GPIO_ACTIVE_HIGH>;
		pinctrl-names = "default";
		pinctrl-0 = <&z96a_vcc5v0_host_en>;
		regulator-always-on;
		regulator-boot-on;
	};

	vcc5v0_otg: regulator-vcc5v0-otg {
		compatible = "regulator-fixed";
		regulator-name = "vcc5v0_otg";
		regulator-min-microvolt = <5000000>;
		regulator-max-microvolt = <5000000>;
		enable-active-high;
		gpio = <&gpio0 RK_PA5 GPIO_ACTIVE_HIGH>;
		pinctrl-names = "default";
		pinctrl-0 = <&z96a_vcc5v0_otg_en>;
	};

	vcc5v0_usb2_host1: regulator-vcc5v0-usb2-host1 {
		compatible = "regulator-fixed";
		regulator-name = "vcc5v0_usb2_host1";
		regulator-min-microvolt = <5000000>;
		regulator-max-microvolt = <5000000>;
		enable-active-high;
		gpio = <&gpio4 RK_PB3 GPIO_ACTIVE_HIGH>;
		pinctrl-names = "default";
		pinctrl-0 = <&z96a_vcc5v0_host1_en>;
		regulator-always-on;
		regulator-boot-on;
	};

	vcc5v0_usb2_host2: regulator-vcc5v0-usb2-host2 {
		compatible = "regulator-fixed";
		regulator-name = "vcc5v0_usb2_host2";
		regulator-min-microvolt = <5000000>;
		regulator-max-microvolt = <5000000>;
		enable-active-high;
		gpio = <&gpio4 RK_PB1 GPIO_ACTIVE_HIGH>;
		pinctrl-names = "default";
		pinctrl-0 = <&z96a_vcc5v0_host2_en>;
		regulator-always-on;
		regulator-boot-on;
	};

	vcc5v0_usb_keyboard: regulator-vcc5v0-usb-keyboard {
		compatible = "regulator-fixed";
		regulator-name = "vcc5v0_usb_keyboard";
		regulator-min-microvolt = <5000000>;
		regulator-max-microvolt = <5000000>;
		enable-active-high;
		gpio = <&gpio2 RK_PD7 GPIO_ACTIVE_HIGH>;
		pinctrl-names = "default";
		pinctrl-0 = <&z96a_keyboard_pwr>;
		regulator-always-on;
		regulator-boot-on;
	};
};

&pinctrl {
	z96a-usb-pwr {
		z96a_vcc5v0_host_en: z96a-vcc5v0-host-en {
			rockchip,pins = <0 RK_PA6 0 &pcfg_pull_none>;
		};

		z96a_vcc5v0_otg_en: z96a-vcc5v0-otg-en {
			rockchip,pins = <0 RK_PA5 0 &pcfg_pull_none>;
		};

		z96a_vcc5v0_host1_en: z96a-vcc5v0-host1-en {
			rockchip,pins = <4 RK_PB3 0 &pcfg_pull_none>;
		};

		z96a_vcc5v0_host2_en: z96a-vcc5v0-host2-en {
			rockchip,pins = <4 RK_PB1 0 &pcfg_pull_none>;
		};

		z96a_keyboard_pwr: z96a-keyboard-pwr {
			rockchip,pins = <2 RK_PD7 0 &pcfg_pull_none>;
		};
	};
};

&usb_host0_xhci {
	vbus-supply = <&vcc5v0_otg>;
};

&usb_host1_xhci {
	vbus-supply = <&vcc5v0_host>;
};
'''

print("== 1/3 内核 legacy dts ==")
apply(KLEG, LEG_EDITS)
print("== 2/3 内核 edge dts ==")
apply(KEDGE, EDGE_EDITS)
print("== 3/3 U-Boot dts (HAL canonical + 镜像同步) ==")
ub = open(UBHAL).read()
if "z96a-pwrfix" not in ub:
    bak = UBHAL + ".bak-pwrfix2"
    if not os.path.exists(bak): shutil.copy2(UBHAL, bak)
    anchor = '\n&usb2phy0 {\n\tstatus = "okay";\n};'
    if anchor not in ub:
        print("!! U-Boot dts 锚点缺失(&usb2phy0 块)", file=sys.stderr); sys.exit(1)
    open(UBHAL, "w").write(ub.replace(anchor, anchor + UB_APPEND, 1))
    print(f"  已修复: {UBHAL}")
else:
    print("  跳过(已含 pwrfix 块)")
import filecmp
for m in (UBP1, UBP2):
    if not filecmp.cmp(UBHAL, m, shallow=False):
        shutil.copy2(UBHAL, m); print(f"  已同步: {m}")

# ---------- 校验 ----------
if shutil.which("dtc"):
    for f in (KLEG, KEDGE):
        r = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", "/dev/null", f], capture_output=True, text=True)
        print(f"  dtc {'OK' if r.returncode==0 else 'FAIL'}: {os.path.basename(f)}")
        if r.returncode != 0:
            print(r.stderr[:2000], file=sys.stderr); sys.exit(1)
else:
    print("  (未安装 dtc, 跳过语法校验)")

for f in (KLEG, KEDGE):
    s = open(f).read()
    checks = [
        "gpio = <0x41 0x06 0x00>", "gpio = <0x41 0x05 0x00>",
        "gpio = <0x1e4 0x0b 0x00>", "gpio = <0x1e4 0x09 0x00>",
        "gpio = <0x132 0x1f 0x00>", "gpio = <0x41 0x17 0x00>",
        "switch-ctl-gpios = <0x1e4 0x1a 0x00>", 'try-power-role = "source"',
        "pwms = <0x1d7 0x00 0x61a8 0x00>", "enable-gpios = <0x132 0x1d 0x00>",
        "bus-format = <0x1009>", "bpc = <0x06>",
        'compatible = "southchip,sc8886"', "interrupts = <0x12 0x08>",
        "io-channels = <0x1dd 0x04>", 'compatible = "rk817,battery"',
        "io-channels = <0x1dd 0x05>", "es7202@30", "es7202_sdi3@32",
        'power-supply = <0x326>;', "vin-supply = <0x134>;\n\t\tpinctrl-names = \"default\";\n\t\tpinctrl-0 = <0x32b>",
    ]
    missing = [c for c in checks if c not in s]
    assert not missing, f"{f}: 缺少 {missing}"
print("校验通过: USB VBUS / eDP 电源+背光 / 6bit 面板 / battery / sc8886 / ES7202 全部就位")
PYEOF

echo
echo "================= 完成 ================="
echo "重新编译 (edge/6.1 是你移植目标):"
echo "  cd $ROOT && ./compile.sh build BOARD=z96a-rk3568-laptop-v2 BRANCH=edge \\"
echo "      KERNEL_CONFIGURE=no"
echo "如 dtb 未更新, 删内核缓存后重编: rm -rf $ROOT/cache/kernel*"
echo
echo "!! 驱动侧自查 (dts 之外必须确认, 内核源码编译后):"
echo "   grep -r 'rk817_battery'   cache/linux-*edge*/kernel/drivers/power/supply/  # 电量计(含分压手搓补丁)"
echo "   grep -rl 'southchip,sc8886' cache/linux-*edge*/kernel/drivers/             # 快充"
echo "   grep -rl 'hynetek,husb311'  cache/linux-*edge*/kernel/drivers/              # Type-C PD"
echo "   缺哪个就从 legacy 5.10 的驱动/补丁移植哪个, 否则对应节点不绑定(USB 供电不受影响)。"
echo
echo "刷机后验证:"
echo "  cat /sys/kernel/debug/regulator/regulator_summary | grep -iE '5v|3v3_lcd'"
echo "  ls /sys/class/power_supply/    # 应出现 battery (rk817-battery)"
echo "  dmesg | grep -iE 'sc8886|husb311|es7202|pwm-backlight'"
echo
echo "已知风险: 原厂曾因 husb311 中断挂死在 Linux 禁用它。若启动卡死,"
echo "将 husb311@4e 改回 status=\"disabled\" (VBUS 由 vcc5v0_otg always-on 硬给电, USB 仍可用)。"
