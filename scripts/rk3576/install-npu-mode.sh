#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# install-npu-mode - install the RKNPU mode-switching helper on an RK3576 board.
#
# Usage: install-npu-mode.sh [module-directory]
#
# Installs:
#   <module-dir>/rknpu_drm.ko, rknpu_heap.ko   the two interchangeable modules
#   <module-dir>/npu-mode                      runtime switch command
#   <module-dir>/npu-mode-load                 boot-time loader
#   /etc/npu_mode                              current mode ("drm" or "heap")
#   /etc/systemd/system/npu-mode.service       boot-time module loading
#
# Run it as root on the board.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
MOD_DIR="${1:-/opt/rknpu}"

if [ "$(id -u)" -ne 0 ]; then
    echo "install-npu-mode: must run as root" >&2
    exit 1
fi

for f in rknpu_drm.ko rknpu_heap.ko npu-mode npu-mode-load; do
    if [ ! -s "$SRC_DIR/$f" ]; then
        echo "install-npu-mode: missing source file: $SRC_DIR/$f" >&2
        exit 1
    fi
done

mkdir -p "$MOD_DIR"
install -m 0644 "$SRC_DIR/rknpu_drm.ko"  "$MOD_DIR/rknpu_drm.ko"
install -m 0644 "$SRC_DIR/rknpu_heap.ko" "$MOD_DIR/rknpu_heap.ko"
install -m 0755 "$SRC_DIR/npu-mode"      "$MOD_DIR/npu-mode"
install -m 0755 "$SRC_DIR/npu-mode-load" "$MOD_DIR/npu-mode-load"

# Default mode: keep the mode the kernel currently runs with, otherwise heap.
if [ ! -f /etc/npu_mode ]; then
    if [ -d /sys/module/rknpu ]; then
        desc="$(modinfo -F description rknpu 2>/dev/null || true)"
        case "$desc" in
            *"DRM GEM memory manager"*) echo drm  > /etc/npu_mode ;;
            *)                          echo heap > /etc/npu_mode ;;
        esac
    else
        echo heap > /etc/npu_mode
    fi
fi

install -m 0644 "$SRC_DIR/npu-mode.service" /etc/systemd/system/npu-mode.service
systemctl daemon-reload
systemctl enable npu-mode.service

ln -sf "$MOD_DIR/npu-mode" /usr/local/bin/npu-mode

echo "install-npu-mode: installed into $MOD_DIR (current mode: $(cat /etc/npu_mode))"
echo "install-npu-mode: run 'npu-mode status', switch with 'npu-mode drm' / 'npu-mode heap'"
