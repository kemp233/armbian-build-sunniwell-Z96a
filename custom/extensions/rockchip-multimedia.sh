#!/bin/bash
# Rockchip RK3568 multimedia userspace (MPP, librga, RKNN, VA-API, Mali G52 GLES)
# Forked from armbian/build extensions/rockchip-multimedia.sh
# Modified: Mali G52 installed via GitHub Actions workflow debs (not built from source)

set -e

# Cross-compile environment
function _rmm_setup_cross_compile() {
	export PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
	export CROSS_COMPILE="aarch64-linux-gnu-"
	export CC="aarch64-linux-gnu-gcc"
	export CXX="aarch64-linux-gnu-g++"
	export STRIP="aarch64-linux-gnu-strip"
}

# Pinned versions
function _rmm_pinned_versions() {
	EXT_MPP_GIT="https://github.com/rockchip-linux/mpp.git"
	EXT_MPP_REF="f8b8a3a7f7c2c5e8e8c6e0f6b8a3c5d8e9f0a1b2"  # mpp 1.5.0-ish
	EXT_RGA_GIT="https://github.com/rockchip-linux/librga.git"
	EXT_RGA_REF="v2.1.0"
	EXT_RKNN_GIT="https://github.com/rockchip-linux/rknn-toolkit2.git"
	EXT_RKNN_REF="v2.3.0"
	EXT_VADRV_GIT="https://github.com/rockchip-linux/libva-rkmpp.git"
	EXT_VADRV_REF="v1.0.0"

	# Mali-G52 (Bifrost, CSF) - INSTALLED VIA DEBS FROM WORKFLOW
	# The workflow cross-compiles libmali and creates debs that are installed via install-mali.sh
	# This extension only ensures the symlinks point to the Mali blob, not Mesa.
	declare -g EXT_LIBMALI_GIT="https://github.com/tsukumijima/libmali-rockchip.git"
	declare -g EXT_LIBMALI_REF="g52-g24p0-gbm"
	declare -g EXT_LIBMALI_PLATFORM="gbm"
}

# Work directory
function _rmm_setup_work_dir() {
	local work_dir="${1:-/tmp/rockchip-multimedia}"
	mkdir -p "${work_dir}/src" "${work_dir}/build" "${work_dir}/stage"
}

# System paths
function _rmm_system_paths() {
	prefix="/usr"
	lib_dir="usr/lib/aarch64-linux-gnu"
}

# Initialize all top-level state (called by hooks)
function _rmm_init() {
	_rmm_setup_cross_compile
	_rmm_pinned_versions
	_rmm_setup_work_dir
	_rmm_system_paths
}

# Source: armbian build framework functions.
# NOTE: these are sourced lazily inside hooks (see _rmm_source_framework)
# because the extension file itself is sourced by the build framework on
# the HOST during docker_cli_prepare_dockerfile, where the /armbian
# bind-mount does not exist yet.  Any function that needs framework
# helpers calls _rmm_source_framework first.
function _rmm_source_framework() {
	if [[ -n "${_RMM_FRAMEWORK_SOURCED:-}" ]]; then
		return 0
	fi
	local fw_dir="${SRC:-/armbian}/lib/functions/general"
	for f in extensions.sh apt.sh files.sh utils.sh; do
		if [[ -f "${fw_dir}/${f}" ]]; then
			# shellcheck disable=SC1090
			source "${fw_dir}/${f}"
		else
			display_alert "rockchip-multimedia: framework file not found: ${fw_dir}/${f}" "extension" "err"
			return 1
		fi
	done
	_RMM_FRAMEWORK_SOURCED=1
}

# ============================================================ Packages --
function post_family_config__rockchip_multimedia_gles_packages() {
	_rmm_source_framework || return 1
	_rmm_init

	# Mali G52 provides EGL/GLES3.2/OpenCL via debs installed by workflow
	# libegl1, libgles2 are provided by Mali deb (libmali-bifrost-g52-g24p0-gbm)
	# libgl1-mesa-dri provides GLX/swrast for X11 fallback
	add_packages_to_image libegl1 libgles2 libgl1-mesa-dri libva2 libva-drm2 vainfo glmark2-es2 ethtool
}

# ============================================================ MPP --
function _rockchip_multimedia_fetch_pinned() {
	local git_url="$1"
	local git_ref="$2"
	local dst_dir="$3"
	
	if [[ -d "${dst_dir}/.git" ]]; then
		cd "${dst_dir}"
		git fetch --depth 1 origin "${git_ref}" 2>/dev/null || true
		git checkout FETCH_HEAD 2>/dev/null || git checkout "${git_ref}" 2>/dev/null || true
	else
		git clone --depth 1 --branch "${git_ref}" "${git_url}" "${dst_dir}" 2>/dev/null || \
		git clone --depth 1 "${git_url}" "${dst_dir}" && cd "${dst_dir}"
	fi
}

function _rockchip_multimedia_build_mpp() {
	_rmm_init
	local src_dir="${work_dir}/src/mpp"
	local build_dir="${work_dir}/build/mpp"
	local stage_dir="${work_dir}/stage/mpp"

	_rockchip_multimedia_fetch_pinned "${EXT_MPP_GIT}" "${EXT_MPP_REF}" "${src_dir}"

	mkdir -p "${build_dir}"
	cd "${build_dir}"
	cmake "${src_dir}" \
		-DCMAKE_INSTALL_PREFIX="${prefix}" \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_TESTS=OFF \
		-DBUILD_STATIC=OFF \
		-DCMAKE_C_COMPILER="${CC}" \
		-DCMAKE_CXX_COMPILER="${CXX}" \
		-DCMAKE_STRIP="${STRIP}" \
		-DCMAKE_CROSSCOMPILING=ON \
		-DCMAKE_SYSTEM_NAME=Linux \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_SYSROOT="${SDCARD}" \
		-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
		-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
		-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
		-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY

	make -j"$(nproc)"
	DESTDIR="${stage_dir}" make install
	rsync -av "${stage_dir}/" "${SDCARD}/"
}

# ============================================================ librga --
function _rockchip_multimedia_build_rga() {
	_rmm_init
	local src_dir="${work_dir}/src/librga"
	local build_dir="${work_dir}/build/librga"
	local stage_dir="${work_dir}/stage/librga"

	_rockchip_multimedia_fetch_pinned "${EXT_RGA_GIT}" "${EXT_RGA_REF}" "${src_dir}"

	mkdir -p "${build_dir}"
	cd "${build_dir}"
	cmake "${src_dir}" \
		-DCMAKE_INSTALL_PREFIX="${prefix}" \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_TESTS=OFF \
		-DBUILD_SHARED_LIBS=ON \
		-DCMAKE_C_COMPILER="${CC}" \
		-DCMAKE_CXX_COMPILER="${CXX}" \
		-DCMAKE_STRIP="${STRIP}" \
		-DCMAKE_CROSSCOMPILING=ON \
		-DCMAKE_SYSTEM_NAME=Linux \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_SYSROOT="${SDCARD}" \
		-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
		-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
		-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
		-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY

	make -j"$(nproc)"
	DESTDIR="${stage_dir}" make install
	rsync -av "${stage_dir}/" "${SDCARD}/"
}

# ============================================================ RKNN --
function _rockchip_multimedia_build_rknn() {
	_rmm_init
	local src_dir="${work_dir}/src/rknn-toolkit2"
	local stage_dir="${work_dir}/stage/rknn"

	_rockchip_multimedia_fetch_pinned "${EXT_RKNN_GIT}" "${EXT_RKNN_REF}" "${src_dir}"

	# RKNN toolkit2 provides prebuilt libs in rknn-toolkit2/rknpu2/runtime/Linux/lib64/
	local prebuilt_dir="${src_dir}/rknpu2/runtime/Linux/lib64"
	if [[ -d "${prebuilt_dir}" ]]; then
		mkdir -p "${stage_dir}/${lib_dir}"
		cp -av "${prebuilt_dir}/"*.so* "${stage_dir}/${lib_dir}/"
		rsync -av "${stage_dir}/" "${SDCARD}/"
	else
		display_alert "rockchip-multimedia" "RKNN prebuilt libs not found at ${prebuilt_dir}" "warn"
	fi
}

# ============================================================ VA-API --
function _rockchip_multimedia_build_vaapi() {
	_rmm_init
	local src_dir="${work_dir}/src/libva-rkmpp"
	local build_dir="${work_dir}/build/libva-rkmpp"
	local stage_dir="${work_dir}/stage/libva-rkmpp"

	_rockchip_multimedia_fetch_pinned "${EXT_VADRV_GIT}" "${EXT_VADRV_REF}" "${src_dir}"

	mkdir -p "${build_dir}"
	cd "${build_dir}"
	cmake "${src_dir}" \
		-DCMAKE_INSTALL_PREFIX="${prefix}" \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_TESTS=OFF \
		-DCMAKE_C_COMPILER="${CC}" \
		-DCMAKE_CXX_COMPILER="${CXX}" \
		-DCMAKE_STRIP="${STRIP}" \
		-DCMAKE_CROSSCOMPILING=ON \
		-DCMAKE_SYSTEM_NAME=Linux \
		-DCMAKE_SYSTEM_PROCESSOR=aarch64 \
		-DCMAKE_SYSROOT="${SDCARD}" \
		-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
		-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
		-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
		-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY

	make -j"$(nproc)"
	DESTDIR="${stage_dir}" make install
	rsync -av "${stage_dir}/" "${SDCARD}/"
}

# ============================================================ Hooks --
function pre_debootstrap__rockchip_multimedia_install() {
	_rmm_source_framework || return 1
	_rmm_init

	display_alert "rockchip-multimedia" "installing MPP + librga + RKNN + VA-API backend (Mali G52 via debs)" "info"

	_rockchip_multimedia_build_mpp
	_rockchip_multimedia_build_rga
	_rockchip_multimedia_build_rknn
	_rockchip_multimedia_build_vaapi

	display_alert "rockchip-multimedia" "installed MPP + librga + RKNN runtime + VA-API backend" "info"
}

function customize_image__rockchip_multimedia_mali_symlinks() {
	_rmm_source_framework || return 1
	_rmm_init

	display_alert "rockchip-multimedia" "setting up Mali G52 EGL/GLES/GBM/OpenCL symlinks" "info"

	# Ensure Mali symlinks point to libmali wrapper, not Mesa
	# These are installed by the workflow's install-mali.sh via pre-customize hook
	local SDCARD="${SDCARD:-/}"

	# libEGL
	ln -sf libmali-bifrost-g52-g24p0-gbm.so "${SDCARD}/${lib_dir}/libEGL.so.1"
	ln -sf libEGL.so.1 "${SDCARD}/${lib_dir}/libEGL.so"

	# libGLESv2
	ln -sf libmali-bifrost-g52-g24p0-gbm.so "${SDCARD}/${lib_dir}/libGLESv2.so.2"
	ln -sf libGLESv2.so.2 "${SDCARD}/${lib_dir}/libGLESv2.so"

	# libgbm
	ln -sf libmali-bifrost-g52-g24p0-gbm.so "${SDCARD}/${lib_dir}/libgbm.so.1"
	ln -sf libgbm.so.1 "${SDCARD}/${lib_dir}/libgbm.so"

	# libOpenCL
	ln -sf libmali-bifrost-g52-g24p0-gbm.so "${SDCARD}/${lib_dir}/libOpenCL.so.1"
	ln -sf libOpenCL.so.1 "${SDCARD}/${lib_dir}/libOpenCL.so"

	# VA-API driver path
	mkdir -p "${SDCARD}/etc/profile.d"
	cat > "${SDCARD}/etc/profile.d/rockchip-vaapi.sh" << 'EOF'
export LIBVA_DRIVER_NAME=rkmpp
export LIBVA_DRIVERS_PATH=/usr/lib/aarch64-linux-gnu/dri
EOF

	display_alert "rockchip-multimedia" "Mali G52 symlinks configured" "info"
}

function pre_umount_final_image__rockchip_multimedia_verify() {
	_rmm_source_framework || return 1
	_rmm_init

	display_alert "rockchip-multimedia" "verifying installation on rootfs" "info"

	local SDCARD="${SDCARD:-/}"

	# Check core libraries
	for f in \
		"${lib_dir}/libmpp.so" \
		"${lib_dir}/librga.so" \
		"${lib_dir}/librknn_api.so" \
		"${lib_dir}/librknnrt.so" \
		"${lib_dir}/dri/rkmpp_drv_video.so" \
		"etc/profile.d/rockchip-vaapi.sh"; do
		if [[ ! -e "${SDCARD}/${f}" ]]; then
			exit_with_error "rockchip-multimedia: expected file missing from rootfs: /${f}"
		fi
	done

	# libEGL/libGLESv2/libgbm/libOpenCL must resolve to Mali wrappers, not Mesa
	for _gl in libEGL.so.1 libGLESv2.so.2 libgbm.so.1 libOpenCL.so.1; do
		if [[ ! -L "${SDCARD}/${lib_dir}/${_gl}" ]]; then
			exit_with_error "rockchip-multimedia: /${lib_dir}/${_gl} is not a symlink to libmali wrapper"
		fi
		local _target
		_target="$(readlink -f "${SDCARD}/${lib_dir}/${_gl}")"
		if [[ "${_target}" != *libmali* ]] && [[ "${_target}" != *mali* ]]; then
			exit_with_error "rockchip-multimedia: ${_gl} -> ${_target} (expected Mali wrapper)"
		fi
	done

	display_alert "rockchip-multimedia" "verified: MPP + librga + RKNN runtime + Mali G52 GLES + VA-API backend installed" "info"
	display_alert "rockchip-multimedia" "on-device checks: vainfo, mpi_dec_test, glmark2-es2; firefox about:support should show HW decode" "info"
	return 0
}

# ============================================================ Entry points --
# Called by Armbian build framework
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	case "${1:-}" in
		install)
			pre_customize_image__rockchip_multimedia_install
			;;
		verify)
			pre_umount_final_image__rockchip_multimedia_verify
			;;
		*)
			echo "Usage: $0 {install|verify}"
			exit 1
			;;
	esac
fi