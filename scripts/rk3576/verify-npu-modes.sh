#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# verify-npu-modes - check that the RKNPU mode switch works on this board.
#
# Usage: verify-npu-modes.sh [encoder-cli]
#
# For each mode (heap, drm) it:
#   1. loads the matching rknpu module
#   2. checks the device nodes the mode is supposed to create
#   3. runs the ASR encoder CLI and reports whether inference succeeded
#
# The script never leaves the board in a half-switched state: it restores the
# mode that was active when it started.

set -uo pipefail

CLI="${1:-/opt/qwen3_asr/runtime/cpp/build/qwen3_asr_cli}"
MODE_DIR="${NPU_MODULE_DIR:-/opt/rknpu}"
WAV="${ASR_TEST_WAV:-/opt/test3.wav}"
ENCODER_DIR="${ASR_ENCODER_DIR:-/opt/qwen3_asr/models/rknn}"
LLM_DIR="${ASR_LLM_DIR:-/opt/qwen3_asr/models/llm_matmul/w8a16}"
TOKENIZER="${ASR_TOKENIZER:-/opt/qwen3_asr/models/tokenizer/tokens.bin}"

ORIGINAL_MODE=""
ORIGINAL_STATE="/etc/npu_mode"

log() { printf '%s\n' "$*"; }
err() { printf 'verify: %s\n' "$*" >&2; }

current_mode() {
    local desc
    desc="$(modinfo -F description rknpu 2>/dev/null)"
    case "$desc" in
        *"DRM GEM memory manager"*)  echo drm ;;
        *"DMA heap memory manager"*) echo heap ;;
        *) echo none ;;
    esac
}

# device nodes each mode must provide
check_nodes() {
    local mode="$1" rc=0
    if [ "$mode" = "heap" ]; then
        if [ -e /dev/rknpu ]; then
            log "    /dev/rknpu            present"
        else
            err "/dev/rknpu missing in heap mode"; rc=1
        fi
        if [ -d /dev/dma_heap ]; then
            log "    /dev/dma_heap/        $(ls /dev/dma_heap | tr '\n' ' ')"
        else
            err "/dev/dma_heap missing in heap mode"; rc=1
        fi
    else
        if [ -d /sys/class/drm ]; then
            log "    /sys/class/drm/       $(ls /sys/class/drm | tr '\n' ' ')"
        fi
        if [ -e /dev/dri/card0 ]; then
            log "    /dev/dri/card0        present"
        else
            err "/dev/dri/card0 missing in drm mode"; rc=1
        fi
    fi
    return $rc
}

run_encoder() {
    local mode="$1" logf="/tmp/npu_verify_$mode.log"
    if [ ! -x "$CLI" ]; then
        err "encoder CLI not found: $CLI"
        return 2
    fi
    log "    running encoder CLI -> $logf"
    (
        ulimit -n 65536
        export LD_LIBRARY_PATH=/opt/qwen3_asr/rknn_root/lib:/usr/lib
        export MATMUL_DUAL_NPU=1 MATMUL_DECODE_INT8_ACT=1 SILU_NEON=1
        export ATTN_ROPE_LUT=1 OMP_NUM_THREADS=4
        timeout 300 "$CLI" \
            --wav "$WAV" \
            --encoder-dir "$ENCODER_DIR" \
            --llm "$LLM_DIR" \
            --tokenizer "$TOKENIZER" \
            --json "/tmp/npu_verify_$mode.json"
    ) > "$logf" 2>&1
    local rc=$?
    log "    CLI exit code: $rc"
    grep -E 'Encode begin|Encode done|failed to submit|run -|transcribe|DMA Heap|Unable' "$logf" \
        | tail -6 | sed 's/^/      /'
    return $rc
}

ORIGINAL_MODE="$(current_mode)"
if [ "$ORIGINAL_MODE" = "none" ] && [ -r "$ORIGINAL_STATE" ]; then
    ORIGINAL_MODE="$(cat "$ORIGINAL_STATE")"
fi
log "verify: current mode = ${ORIGINAL_MODE:-unknown}"

overall=0
for mode in heap drm; do
    log ""
    log "=== mode: $mode ==="
    if ! "$MODE_DIR/npu-mode" "$mode"; then
        err "failed to switch to $mode"
        overall=1
        continue
    fi
    check_nodes "$mode" || overall=1
    run_encoder "$mode" || overall=1
done

log ""
log "=== restoring original mode: ${ORIGINAL_MODE:-heap} ==="
"$MODE_DIR/npu-mode" "${ORIGINAL_MODE:-heap}" || overall=1

log ""
if [ $overall -eq 0 ]; then
    log "verify: all modes loaded and the encoder ran in both"
else
    log "verify: problems were found (see the messages above)"
fi
exit $overall
