#!/bin/bash
# Armbian runs *.patch.sh inside the U-Boot source tree.
set -e
HAL_REL="../../../../config/boards/hal/z96a-rk3568-laptop-v2/uboot"
# When applied, CWD is u-boot source; SRC may be exported by Armbian
if [[ -n "${SRC:-}" && -d "${SRC}/config/boards/hal/z96a-rk3568-laptop-v2/uboot" ]]; then
  HAL="${SRC}/config/boards/hal/z96a-rk3568-laptop-v2/uboot"
elif [[ -d /armbian/config/boards/hal/z96a-rk3568-laptop-v2/uboot ]]; then
  HAL=/armbian/config/boards/hal/z96a-rk3568-laptop-v2/uboot
else
  # best-effort relative from patch worker
  HAL="$(dirname "$0")/../../../config/boards/hal/z96a-rk3568-laptop-v2/uboot"
fi

echo "z96a-hal-inject-dt: HAL=$HAL cwd=$(pwd)"
if [[ ! -f "$HAL/rk3568-z96a-laptop-v2.dts" ]]; then
  echo "HAL dts missing — skip"
  exit 0
fi

mkdir -p arch/arm/dts
cp -av "$HAL/rk3568-z96a-laptop-v2.dts" arch/arm/dts/
cp -av "$HAL/rk3568-z96a-laptop-v2-u-boot.dtsi" arch/arm/dts/
# overwrite any other copies
find . -name 'rk3568-z96a-laptop-v2.dts' ! -path './arch/arm/dts/*' -exec cp -av arch/arm/dts/rk3568-z96a-laptop-v2.dts {} \;
grep -n 'press-threshold-microvolt' arch/arm/dts/rk3568-z96a-laptop-v2.dts || true

# Fix compile error on rockchip-v2026.01 @7c316c68:
# board.c calls rockchip_dnl_mode_check() but the arch boot_mode.h only
# declares setup_boot_mode(). Add a forward declaration in board.c.
# (upstream board.c:206 -> implicit declaration -> -Werror)
if grep -q 'rockchip_dnl_mode_check();' arch/arm/mach-rockchip/board.c; then
  if ! grep -q 'void rockchip_dnl_mode_check(void);' arch/arm/mach-rockchip/board.c; then
    echo "z96a-hal-inject-dt: adding rockchip_dnl_mode_check() forward decl"
    python3 - <<'PY'
import re
p = 'arch/arm/mach-rockchip/board.c'
s = open(p).read()
# insert after the arch-rockchip boot_mode.h include
needle = '#include <asm/arch-rockchip/boot_mode.h>'
if needle in s and 'void rockchip_dnl_mode_check(void);' not in s:
    s = s.replace(needle, needle + '\n\n/* Z96A: board_init() calls dnl check before boot_mode.c is linked */\nvoid rockchip_dnl_mode_check(void);', 1)
    open(p, 'w').write(s)
    print("patched board.c")
PY
  fi
fi
echo "z96a-hal-inject-dt: done thr=9"
