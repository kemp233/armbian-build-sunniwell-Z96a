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
echo "z96a-hal-inject-dt: done thr=9"
