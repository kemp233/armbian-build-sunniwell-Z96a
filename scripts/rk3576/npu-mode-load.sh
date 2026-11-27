#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# npu-mode-load - boot-time loader for the RK3576 RKNPU memory manager.
#
# Reads the desired mode from /etc/npu_mode ("drm" or "heap"), defaults to
# "heap" when the file is missing, and loads the matching rknpu module.
# It never fails the boot: a missing module is only reported.

set -uo pipefail

MODULE_DIR="${NPU_MODULE_DIR:-/opt/rknpu}"
STATE_FILE="${NPU_STATE_FILE:-/etc/npu_mode}"

mode="heap"
if [ -r "$STATE_FILE" ]; then
    read -r mode < "$STATE_FILE"
fi

case "$mode" in
    drm)  module="${MODULE_DIR}/rknpu_drm.ko" ;;
    heap) module="${MODULE_DIR}/rknpu_heap.ko" ;;
    *)
        echo "npu-mode-load: invalid mode '$mode' in $STATE_FILE, using heap" >&2
        mode="heap"
        module="${MODULE_DIR}/rknpu_heap.ko"
        ;;
esac

if [ ! -s "$module" ]; then
    echo "npu-mode-load: module not found: $module" >&2
    exit 0
fi

if [ -d /sys/module/rknpu ]; then
    echo "npu-mode-load: rknpu already loaded, leaving it alone"
    exit 0
fi

if insmod "$module"; then
    echo "npu-mode-load: loaded $module ($mode mode)"
else
    echo "npu-mode-load: failed to load $module" >&2
fi
exit 0
