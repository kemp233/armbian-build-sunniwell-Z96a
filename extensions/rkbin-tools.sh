#!/usr/bin/env bash
function fetch_sources_tools__rkbin_tools() {
	# RKBIN_GIT_REF (full ref, e.g. "commit:<sha>") takes precedence; otherwise
	# build a "branch:<name>" ref from RKBIN_GIT_BRANCH. fetch_from_repo accepts
	# branch:/tag:/commit:/head refs. Pinning a commit is needed because
	# rockchip-linux/rkbin master is a rolling release that DELETES old DDR
	# blobs (e.g. the validated v1.25 LB2004 blob) when newer ones land.
	fetch_from_repo "${RKBIN_GIT_URL:-"https://github.com/armbian/rkbin"}" "rkbin-tools" "${RKBIN_GIT_REF:-"branch:${RKBIN_GIT_BRANCH:-"master"}"}"
}

function build_host_tools__install_rkbin_tools() {
	# install only if git commit hash changed
	cd "${SRC}"/cache/sources/rkbin-tools || exit
	# need to check if /usr/local/bin/loaderimage to detect new Docker containers with old cached sources
	if [[ ! -f .commit_id || $(improved_git rev-parse @ 2> /dev/null) != $(< .commit_id) || ! -f /usr/local/bin/loaderimage ]]; then
		display_alert "Installing" "rkbin-tools" "info"
		mkdir -p /usr/local/bin/
		install -m 755 tools/loaderimage /usr/local/bin/
		install -m 755 tools/trust_merger /usr/local/bin/
		improved_git rev-parse @ 2> /dev/null > .commit_id
	fi
}
