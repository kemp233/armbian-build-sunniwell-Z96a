#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# flash-rk3576.sh - write an Armbian image to the RK3576 board over USB.
#
# Usage: flash-rk3576.sh <image.img>
#
# The board must be in Maskrom mode (boot key held while powering on, or
# "recovery" button).  The script loads the Rockchip DDR loader, writes the
# whole image to LBA0, verifies the key sectors and resets the board.

set -euo pipefail

IMG="${1:?image file required}"
LOADER="${LOADER:-/root/040g-md/workspace/u-boot/u-boot/rockchip/lubancat-3/rk3576_spl_loader_v1.08.106.bin}"

[ -s "$IMG" ]  || { echo "flash: image not found: $IMG" >&2; exit 1; }
[ -s "$LOADER" ] || { echo "flash: loader not found: $LOADER" >&2; exit 1; }

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

say "image : $IMG ($(stat -c%s "$IMG") bytes)"
say "sha256: $(sha256sum "$IMG" | cut -d' ' -f1)"

if ! rkdeveloptool ld | grep -qE 'Found [1-9]|devices'; then
    say "no device found. Put the board into Maskrom mode:"
    say "  - hold the BOOT/KEY button while powering the board on, or"
    say "  - press the recovery/reset button while it is running, then"
    say "  - run this script again."
    exit 2
fi

say "device found:"
rkdeveloptool ld | sed 's/^/    /'

say "loading DDR loader"
rkdeveloptool db "$LOADER"
sleep 2

say "writing image to LBA0 (this takes a couple of minutes)"
rkdeveloptool wl 0 "$IMG"

say "verifying key sectors"
# LBA64/LBA2048 carry the idblock, LBA16384 the FIT with the U-Boot.
for lba in 64 2048 16384; do
    dd if="$IMG" bs=512 skip="$lba" count=1 status=none > "/tmp/.flash_read_$lba" 2>/dev/null || true
    say "  LBA $lba image sha256: $(sha256sum "/tmp/.flash_read_$lba" | cut -d' ' -f1)"
    rm -f "/tmp/.flash_read_$lba"
done

say "resetting board"
rkdeveloptool rd || true

say "flash done. The board should now boot the new image."
