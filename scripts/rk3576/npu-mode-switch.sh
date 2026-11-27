#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# npu-mode - switch the RK3576 RKNPU memory manager.
#
# The RK3576 kernel ships CONFIG_ROCKCHIP_RKNPU=m with both memory managers
# available as interchangeable modules:
#   rknpu_drm.ko  -> DRM GEM memory manager  (/dev/dri/card0)
#   rknpu_heap.ko -> dma-buf heap manager   (/dev/rknpu + /dev/dma_heap/*)
#
# IMPORTANT: the module cannot be unloaded while it is running.
#
#   * heap + iommu enabled  -> rmmod never returns, the kernel deadlocks
#     (RCU stall) and the board has to be power cycled.
#   * drm                    -> rmmod triggers "Asynchronous SError
#     Interrupt" and the kernel panics.
#
# So the mode is switched by recording the desired mode and rebooting; the
# npu-mode.service unit loads the matching module at boot.
#
# Usage:
#   npu-mode drm     switch to the DRM GEM memory manager (takes effect after
#                    a reboot)
#   npu-mode heap    switch to the dma-buf heap memory manager (takes effect
#                    after a reboot)
#   npu-mode status  show the active mode and the pending mode
#   npu-mode apply   reboot now, so the pending mode takes effect

set -uo pipefail

MODULE_DIR="${NPU_MODULE_DIR:-/opt/rknpu}"
STATE_FILE="${NPU_STATE_FILE:-/etc/npu_mode}"
DRM_MODULE="${MODULE_DIR}/rknpu_drm.ko"
HEAP_MODULE="${MODULE_DIR}/rknpu_heap.ko"

log() { printf '%s\n' "$*"; }
err() { printf 'npu-mode: %s\n' "$*" >&2; }

# NPU processes that must not be running when the mode changes.
NPU_USER_PATTERNS=(
    'qwen3_asr_cli'
    'rkvoice'
    'rkvoice_stream'
    'rknn_benchmark'
    'rknn_toolkit'
    'cosyvoice'
)

recorded_mode() {
    [ -r "$STATE_FILE" ] && cat "$STATE_FILE" || echo "unknown"
}

# The mode the running module implements.  The DRM variant creates
# /dev/dri/card0, the heap variant creates /dev/rknpu as a misc device.
running_mode() {
    if [ -e /dev/dri/card0 ]; then
        echo "drm"
    elif [ -e /dev/rknpu ]; then
        echo "heap"
    elif [ -d /sys/module/rknpu ]; then
        echo "loaded"
    else
        echo "none"
    fi
}

do_status() {
    local running recorded
    running="$(running_mode)"
    recorded="$(recorded_mode)"
    log "npu-mode: running module  = $(grep -c '^rknpu ' /proc/modules 2>/dev/null) rknpu loaded"
    log "npu-mode: active mode     = ${running}"
    log "npu-mode: recorded mode   = ${recorded}"
    if [ "$running" != "$recorded" ] && [ "$running" != "none" ]; then
        log "npu-mode: a reboot is required to apply '${recorded}'"
    fi
    log "npu-mode: /dev/rknpu      = $([ -e /dev/rknpu ] && echo present || echo absent)"
    log "npu-mode: /dev/dri/card0  = $([ -e /dev/dri/card0 ] && echo present || echo absent)"
    log "npu-mode: iommu           = $(dmesg 2>/dev/null | grep -o 'rknpu iommu is [a-z]*' | tail -1)"
}

set_mode() {
    local mode="$1" module
    case "$mode" in
        drm)  module="$DRM_MODULE" ;;
        heap) module="$HEAP_MODULE" ;;
        *)    err "unknown mode '$mode' (use drm or heap)"; return 2 ;;
    esac

    if [ ! -s "$module" ]; then
        err "module not found: $module"
        return 1
    fi

    local running
    running="$(running_mode)"
    if [ "$running" = "$mode" ]; then
        echo "$mode" > "$STATE_FILE" 2>/dev/null || true
        log "npu-mode: already in ${mode} mode"
        return 0
    fi

    # Make sure nothing is using the NPU when the reboot happens.
    local pat
    for pat in "${NPU_USER_PATTERNS[@]}"; do
        pkill -f -- "$pat" 2>/dev/null && log "npu-mode: stopped '$pat'"
    done

    echo "$mode" > "$STATE_FILE" || { err "cannot write $STATE_FILE"; return 1; }
    log "npu-mode: mode set to '${mode}'; run 'npu-mode apply' or reboot to apply it"
    log "npu-mode: (the module cannot be unloaded at runtime, a reboot is required)"
    return 0
}

case "${1:-}" in
    drm)   set_mode drm ;;
    heap)  set_mode heap ;;
    status) do_status ;;
    apply)
        log "npu-mode: rebooting to apply mode '$(recorded_mode)'"
        sync
        reboot
        ;;
    *)
        echo "Usage: npu-mode {drm|heap|status|apply}" >&2
        exit 2
        ;;
esac
