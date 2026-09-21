#!/usr/bin/env bash
# utils.sh - shim for armbian build compatibility
# Sources logging functions from the new split layout

fw_dir="${SRC:-/armbian}/lib/functions"
if [[ -f "${fw_dir}/logging/display-alert.sh" ]]; then
    source "${fw_dir}/logging/display-alert.sh"
fi
if [[ -f "${fw_dir}/logging/traps.sh" ]]; then
    source "${fw_dir}/logging/traps.sh"
fi
if [[ -f "${fw_dir}/logging/log.sh" ]]; then
    source "${fw_dir}/logging/log.sh"
fi
