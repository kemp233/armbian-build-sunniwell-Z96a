#!/usr/bin/env bash
# files.sh - shim for armbian build compatibility
# Sources host/docker.sh which provides download_and_verify, etc.

fw_dir="${SRC:-/armbian}/lib/functions"
if [[ -f "${fw_dir}/host/docker.sh" ]]; then
    source "${fw_dir}/host/docker.sh"
fi
if [[ -f "${fw_dir}/general/downloads.sh" ]]; then
    source "${fw_dir}/general/downloads.sh"
fi
