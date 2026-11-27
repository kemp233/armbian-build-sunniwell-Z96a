#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# npu-mode - switch the RK3576 RKNPU memory manager at runtime.
#
# The RK3576 kernel ships CONFIG_ROCKCHIP_RKNPU=m with both memory managers
# available as interchangeable modules:
#   rknpu_drm.ko  -> DRM GEM memory manager  (/dev/dri/card0 + /dev/rknpu)
#   rknpu_heap.ko -> dma-buf heap manager   (/dev/rknpu + /dev/dma_heap/*)
#
# Usage:
#   npu-mode drm     load the DRM GEM variant
#   npu-mode heap    load the DMA heap variant
#   npu-mode status  show the currently active variant
#
# Switching stops NPU users, unloads the current module and loads the other one.
# It normally takes a few seconds and does not require a reboot.

set -uo pipefail

MODULE_DIR="${NPU_MODULE_DIR:-/opt/rknpu}"
STATE_FILE="${NPU_STATE_FILE:-/etc/npu_mode}"
DRM_MODULE="${MODULE_DIR}/rknpu_drm.ko"
HEAP_MODULE="${MODULE_DIR}/rknpu_heap.ko"

log() { printf '%s\n' "$*"; }
err() { printf 'npu-mode: %s\n' "$*" >&2; }

# Processes that must not hold the NPU device while the module is swapped.
# pkill -f patterns are matched against the full command line.
NPU_USER_PATTERNS=(
    'qwen3_asr_cli'
    'qwen3_asr'
    'rkvoice'
    'rkvoice_stream'
    'rknn_benchmark'
    'rknn_toolkit'
    'cosyvoice'
    'matcha'
    'vocos'
)

stop_npu_users() {
    local pat
    for pat in "${NPU_USER_PATTERNS[@]}"; do
        # Never match this script itself.
        pkill -f -- "$pat" 2>/dev/null && log "npu-mode: stopped '$pat'"
    done
    # Give the kernel a moment to release the device.
    sleep 1
}

loaded_module() {
    # Returns the module name currently registered with the kernel, if any.
    cat /proc/modules 2>/dev/null | awk '$1 == "rknpu" { print $1; exit }'
}

active_mode() {
    local mod desc
    mod="$(loaded_module)"
    if [ -z "$mod" ]; then
        echo "none"
        return
    fi
    # The two variants carry different MODULE_DESCRIPTION strings:
    #   "RKNPU driver (DRM GEM memory manager)"
    #   "RKNPU driver (DMA heap memory manager)"
    desc="$(modinfo -F description rknpu 2>/dev/null)"
    case "$desc" in
        *"DRM GEM memory manager"*)  echo "drm" ;;
        *"DMA heap memory manager"*) echo "heap" ;;
        *) echo "unknown" ;;
    esac
}

do_status() {
    local mod mode
    mod="$(loaded_module)"
    mode="$(active_mode)"
    log "npu-mode: kernel module rknpu = ${mod:-<not loaded>}"
    log "npu-mode: active memory manager = ${mode}"
    if [ -f "$STATE_FILE" ]; then
        log "npu-mode: recorded state = $(cat "$STATE_FILE")"
    fi
    if [ -d /sys/module/rknpu ]; then
        log "npu-mode: /dev/rknpu present: $([ -e /dev/rknpu ] && echo yes || echo no)"
    fi
    if [ -d /sys/class/drm ]; then
        log "npu-mode: DRM devices: $(ls /sys/class/drm 2>/dev/null | tr '\n' ' ')"
    fi
    ls -l /dev/dma_heap 2>/dev/null | sed 's/^/npu-mode: /' || true
}

load_variant() {
    local mode="$1" module="$2"

    if [ ! -s "$module" ]; then
        err "module not found: $module"
        return 1
    fi

    stop_npu_users

    if [ -n "$(loaded_module)" ]; then
        log "npu-mode: unloading current rknpu module"
        if ! rmmod rknpu 2>/dev/null; then
            # Some builds register the DMA-heap variant under a different name.
            rmmod rknpu_heap 2>/dev/null || true
        fi
        # Wait for the device node to disappear.
        local i
        for i in $(seq 1 20); do
            [ -z "$(loaded_module)" ] && break
            sleep 0.5
        done
        if [ -n "$(loaded_module)" ]; then
            err "could not unload rknpu; is an NPU process still running?"
            return 1
        fi
    fi

    log "npu-mode: loading $module"
    if ! insmod "$module"; then
        err "insmod failed for $module"
        return 1
    fi

    echo "$mode" > "$STATE_FILE" 2>/dev/null || true
    log "npu-mode: switched to ${mode} mode"
    do_status
    return 0
}

case "${1:-}" in
    drm)
        load_variant drm "$DRM_MODULE"
        ;;
    heap)
        load_variant heap "$HEAP_MODULE"
        ;;
    status)
        do_status
        ;;
    *)
        echo "Usage: npu-mode {drm|heap|status}" >&2
        exit 2
        ;;
esac
