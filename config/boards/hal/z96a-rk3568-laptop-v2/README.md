# Z96A V2 HAL — force U-Boot ↔ Kernel DT sync

## Problem
U-Boot and Kernel come from different repos → DTB drift:
- Recovery thr `9` vs `1750`/`0x6d6`
- CPU clocks CRU vs SCMI
- Regulator topology (vdd_logic vs fake vdd_cpu)

## Solution in this tree
1. **Canonical HAL** under this directory (`uboot/*.dts`, `HAL.md`)
2. **Build-time inject**: `pre_config_uboot_target__z96a_hal_inject_dt` in
   `config/sources/families/rockchip-rk3568-z96a.conf` overwrites U-Boot board DT
3. **Patch.sh**: `patch/u-boot/u-boot-z96a-v2026.01/z96a-hal-inject-dt.patch.sh`
4. **Kernel board DTS** (edge+legacy) carry matching `adc-keys` thr=9 + SCMI cpu clocks + vdd_logic
5. **boot.cmd** fdt-sets SCMI cpu clocks as last-resort safety net
6. **CI gate**: `.github/workflows/z96a-hal-sync.yml` + hooks in build workflows

## Commands
```bash
./config/boards/hal/z96a-rk3568-laptop-v2/scripts/sync-hal-into-trees.sh
./config/boards/hal/z96a-rk3568-laptop-v2/scripts/check-hal-sync.sh
```

## Edit policy
- Change Recovery/SCMI/regulator contract **only** in HAL + kernel board DTS together
- Never “fix thr only in one tree”
