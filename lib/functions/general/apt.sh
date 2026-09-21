#!/usr/bin/env bash
# apt.sh - shim for armbian build compatibility
# Sources apt-utils.sh which provides package management functions

fw_dir="${SRC:-/armbian}/lib/functions"
if [[ -f "${fw_dir}/general/apt-utils.sh" ]]; then
    source "${fw_dir}/general/apt-utils.sh"
fi
# Also source package-lists.sh for add_packages_to_image
if [[ -f "${fw_dir}/configuration/package-lists.sh" ]]; then
    source "${fw_dir}/configuration/package-lists.sh"
fi
