#!/usr/bin/env bash
# Copy canonical U-Boot DT from HAL into Armbian patch dirs and optional build tree.
set -euo pipefail
HAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HAL_DIR/../../../.." && pwd)"
[[ -f "$ROOT/compile.sh" ]] || ROOT="$(cd "$HAL_DIR/../../.." && pwd)"
UB_SRC="${1:-}"  # optional: path to u-boot build dir

echo "HAL-SYNC: root=$ROOT"

install -d "$ROOT/patch/u-boot/u-boot-z96a-v2026.01"
install -d "$ROOT/userpatches/u-boot/u-boot-z96a-v2026.01"
cp -a "$HAL_DIR/uboot/rk3568-z96a-laptop-v2.dts" "$ROOT/patch/u-boot/u-boot-z96a-v2026.01/"
cp -a "$HAL_DIR/uboot/rk3568-z96a-laptop-v2-u-boot.dtsi" "$ROOT/patch/u-boot/u-boot-z96a-v2026.01/"
cp -a "$HAL_DIR/uboot/rk3568-z96a-laptop-v2.dts" "$ROOT/userpatches/u-boot/u-boot-z96a-v2026.01/"
cp -a "$HAL_DIR/uboot/rk3568-z96a-laptop-v2-u-boot.dtsi" "$ROOT/userpatches/u-boot/u-boot-z96a-v2026.01/"

# Marker for CI
cat > "$ROOT/patch/u-boot/u-boot-z96a-v2026.01/000-HAL-SYNC.txt" <<EOM
Synced from config/boards/hal/z96a-rk3568-laptop-v2/uboot
Recovery press-threshold-microvolt = 9
Do not edit copies; edit HAL then re-run scripts/sync-hal-into-trees.sh
EOM
cp -a "$ROOT/patch/u-boot/u-boot-z96a-v2026.01/000-HAL-SYNC.txt" \
  "$ROOT/userpatches/u-boot/u-boot-z96a-v2026.01/" 2>/dev/null || true

if [[ -n "$UB_SRC" && -d "$UB_SRC" ]]; then
  echo "HAL-SYNC: injecting into U-Boot tree $UB_SRC"
  # Common locations
  for sub in arch/arm/dts dts arch/arm/dts/rockchip; do
    if [[ -d "$UB_SRC/$sub" ]]; then
      cp -a "$HAL_DIR/uboot/rk3568-z96a-laptop-v2.dts" "$UB_SRC/$sub/" 2>/dev/null || true
      cp -a "$HAL_DIR/uboot/rk3568-z96a-laptop-v2-u-boot.dtsi" "$UB_SRC/$sub/" 2>/dev/null || true
    fi
  done
  # If board file exists elsewhere, overwrite by name
  find "$UB_SRC" -name 'rk3568-z96a-laptop-v2.dts' -print0 2>/dev/null | while IFS= read -r -d '' f; do
    cp -a "$HAL_DIR/uboot/rk3568-z96a-laptop-v2.dts" "$f"
    echo "HAL-SYNC: overwrote $f"
  done
  find "$UB_SRC" -name 'rk3568-z96a-laptop-v2-u-boot.dtsi' -print0 2>/dev/null | while IFS= read -r -d '' f; do
    cp -a "$HAL_DIR/uboot/rk3568-z96a-laptop-v2-u-boot.dtsi" "$f"
    echo "HAL-SYNC: overwrote $f"
  done
fi

echo "HAL-SYNC: done"
