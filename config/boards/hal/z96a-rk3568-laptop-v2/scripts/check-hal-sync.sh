#!/usr/bin/env bash
# Fail if U-Boot/Kernel HAL fields drift.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# repo root = five levels up from scripts: scripts->halboard->hal->boards->config->ROOT
ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
if [[ ! -f "$ROOT/compile.sh" ]]; then
  ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
fi
if [[ ! -f "$ROOT/compile.sh" ]]; then
  # from config/boards/hal/BOARD/scripts -> up 5 is repo
  ROOT="$(cd "$HAL_DIR/../../../.." && pwd)"
fi
if [[ ! -f "$ROOT/compile.sh" ]]; then
  echo "HAL-CHECK ERROR: cannot find compile.sh (ROOT=$ROOT)" >&2
  exit 2
fi

fail=0
say() { echo "HAL-CHECK: $*"; }
err() { echo "HAL-CHECK ERROR: $*" >&2; fail=1; }

say "repo=$ROOT"
say "hal=$HAL_DIR"

UB_DTS="$HAL_DIR/uboot/rk3568-z96a-laptop-v2.dts"
[[ -f "$UB_DTS" ]] || err "missing $UB_DTS"
grep -q 'press-threshold-microvolt = <9>' "$UB_DTS" || err "U-Boot HAL dts thr != 9"
grep -q 'label = "volume up"' "$UB_DTS" || err "U-Boot HAL missing volume up"
grep -q 'io-channels = <&saradc 0>' "$UB_DTS" || err "U-Boot HAL must use saradc ch0"

for kd in \
  "$ROOT/patch/kernel/rockchip-rk3568-z96a/edge/dt/rk3568-z96a-laptop-v2.dts" \
  "$ROOT/patch/kernel/rockchip-rk3568-z96a/legacy/dt/rk3568-z96a-laptop-v2.dts"
do
  [[ -f "$kd" ]] || { err "missing $kd"; continue; }
  say "scan $(basename "$(dirname "$(dirname "$kd")")")/$(basename "$kd")"
  if ! grep -q 'adc-keys' "$kd"; then
    err "$kd missing adc-keys"
  else
    if ! grep -A30 'adc-keys' "$kd" | grep -qE 'press-threshold-microvolt = <(0x09|9)>'; then
      err "$kd adc-keys thr must be 9"
      grep -A30 'adc-keys' "$kd" | head -35 || true
    fi
    if grep -A40 'adc-keys' "$kd" | grep -q 'button-recovery'; then
      err "$kd must not use fake button-recovery label (factory=volume up only)"
    fi
  fi
  grep -q 'protocol@14' "$kd" || err "$kd missing SCMI protocol@14"
  if ! grep -qE 'clocks = <0x02 0x00>|clocks = <&scmi_clk 0>' "$kd"; then
    err "$kd CPU clocks not SCMI clk0"
  fi
  grep -q 'regulator-name = "vdd_logic"' "$kd" || err "$kd missing vdd_logic"
  grep -q 'regulator-name = "vdd_gpu"' "$kd" || err "$kd missing vdd_gpu"
  if grep -q 'gpu-thermal' "$kd"; then
    # require trips within next 40 lines after gpu-thermal
    if ! awk '/gpu-thermal \{/,0{print; if(++n>40) exit}' "$kd" | grep -q 'trips'; then
      err "$kd gpu-thermal missing trips"
    fi
  fi
done

BS="$ROOT/config/bootscripts/boot-z96a-rk3568-laptop-v2.cmd"
[[ -f "$BS" ]] || err "missing bootscript"
grep -q 'fdt set /cpus/cpu@0 clocks' "$BS" || err "bootscript missing SCMI cpu clock fdt set"
grep -q 'Z96A-HAL' "$BS" || err "bootscript missing Z96A-HAL marker"

for d in "$ROOT/patch/u-boot/u-boot-z96a-v2026.01" "$ROOT/userpatches/u-boot/u-boot-z96a-v2026.01"; do
  [[ -d "$d" ]] || continue
  if [[ -f "$d/rk3568-z96a-laptop-v2.dts" ]]; then
    grep -q 'press-threshold-microvolt = <9>' "$d/rk3568-z96a-laptop-v2.dts" \
      || err "$d copy thr != 9"
  fi
done

# Family must reference HAL inject hook
FAM="$ROOT/config/sources/families/rockchip-rk3568-z96a.conf"
grep -q 'z96a_hal_inject_dt' "$FAM" || err "family conf missing pre_config_uboot_target__z96a_hal_inject_dt"

if [[ "$fail" -ne 0 ]]; then
  say "FAILED"
  exit 1
fi
say "OK — thr=9, SCMI clk0, vdd_logic/vdd_gpu, gpu-thermal trips, bootscript, family hook"
exit 0
