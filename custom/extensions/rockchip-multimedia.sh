#!/bin/bash
# Rockchip RK3568 multimedia userspace (MPP, librga, RKNN, VA-API, Mali G52 GLES)
# Forked from armbian/build extensions/rockchip-multimedia.sh
# Modified: Mali G52 installed via GitHub Actions workflow debs (not built from source)

set -e

# Cross-compile environment - detects native ARM64 vs cross-compile from x86_64
function _rmm_setup_cross_compile() {
	# Source framework to get ARCH variable if available
	_rmm_source_framework || true

	# Determine if we're native ARM64 or cross-compiling
	# Use dpkg-architecture to check if target ARCH matches host
	local target_arch="${ARCH:-arm64}"
	local host_arch
	host_arch=$(dpkg --print-architecture 2>/dev/null || echo "unknown")

	if dpkg-architecture -e "${target_arch}" 2>/dev/null; then
		# Native ARM64 build (e.g., on ubuntu-24.04-arm runner)
		display_alert "rockchip-multimedia" "Native ARM64 build detected (target=${target_arch}, host=${host_arch})" "info"
		export PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
		export CROSS_COMPILE=""
		export CC="gcc"
		export CXX="g++"
		# Resolve strip to an absolute path; the armbian docker image may not
		# have it in PATH, and cmake records CMAKE_STRIP verbatim, so a bare
		# "strip" becomes <build_dir>/strip and fails with "not found".
		export STRIP="$(command -v strip || true)"
		export _RMM_NATIVE_BUILD=1
	else
		# Cross-compilation from x86_64 to ARM64
		display_alert "rockchip-multimedia" "Cross-compile build detected (target=${target_arch}, host=${host_arch})" "info"
		export PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
		export CROSS_COMPILE="aarch64-linux-gnu-"
		export CC="aarch64-linux-gnu-gcc"
		export CXX="aarch64-linux-gnu-g++"
		export STRIP="aarch64-linux-gnu-strip"
		export _RMM_NATIVE_BUILD=0
	fi
}

# Pinned versions
function _rmm_pinned_versions() {
	EXT_MPP_GIT="https://github.com/rockchip-linux/mpp.git"
	EXT_MPP_REF="1.1.0"  # latest release tag
	EXT_RGA_GIT="https://github.com/airockchip/librga.git"
	EXT_RGA_REF="v1.10.0"
	EXT_RKNN_GIT="https://github.com/rockchip-linux/rknn-toolkit2.git"
	EXT_RKNN_REF="v1.6.0"  # latest release tag
	# VA 驱动: woodyst/rockchip-vaapi 通过 MPP 实现完整硬件解码 (H264/HEVC/VP9),
	# 注册 VAEntrypointVLD 解码入口; 旧 kleopatra999 版只有编码.
	EXT_VADRV_GIT="https://github.com/woodyst/rockchip-vaapi.git"
	EXT_VADRV_REF="master"

	# Mali-G52 (Bifrost, CSF) is installed from the .deb produced by
	# build-with-mali.yml during the formal pre_customize_image hook.
	# This extension verifies the provider wrappers and their symlinks.
	declare -g EXT_LIBMALI_GIT="https://github.com/tsukumijima/libmali-rockchip.git"
	declare -g EXT_LIBMALI_REF="g52-g24p0-gbm"
	declare -g EXT_LIBMALI_PLATFORM="gbm"
}

# Work directory
function _rmm_setup_work_dir() {
	# Declare globally so _rockchip_multimedia_build_*() can see it.
	# A `local` here would be invisible outside this function and the
	# callers would resolve ${work_dir} to an empty string, which made
	# cmake write into /build/mpp and look for /build/mpp/strip.
	declare -g work_dir="${1:-/tmp/rockchip-multimedia}"
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
# bind-mount does not exist yet. At that point, SRC points to the build
# repo on the host. Inside the container, /armbian is the bind mount.
# Any function that needs framework helpers calls _rmm_source_framework first.
function _rmm_source_framework() {
	if [[ -n "${_RMM_FRAMEWORK_SOURCED:-}" ]]; then
		return 0
	fi
	# Use SRC (set by compile.sh) on host, /armbian inside container
	local fw_dir="${SRC:-/armbian}/lib/functions/general"
	for f in extensions.sh apt-utils.sh; do
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

	# Mali G52 provides EGL/GLES3.2/GBM through the package produced by
	# build-with-mali.yml. Keep Mesa's desktop GLX fallback available for
	# X11 desktops, and add the tools/regulatory data used to verify USB
	# Ethernet and USB Wi-Fi/Bluetooth devices.
	add_packages_to_image libegl1 libgles2 libgl1-mesa-dri libva2 libva-drm2 vainfo glmark2-es2 mesa-utils-extra ethtool iw wireless-regdb bluez
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

	# Fail loudly if we still have no sources; building an empty tree
	# produces confusing cmake/make errors further down.
	if [[ ! -f "${dst_dir}/README.md" && ! -f "${dst_dir}/CMakeLists.txt" && ! -f "${dst_dir}/meson.build" ]]; then
		display_alert "rockchip-multimedia" "Failed to fetch ${git_url}@${git_ref}" "err"
		return 1
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
	
	# Set cmake cross-compile flags based on native vs cross
	local cmake_cross_flags=()
	if [[ "${_RMM_NATIVE_BUILD:-0}" == "1" ]]; then
		# Native build - no cross-compile flags needed
		cmake_cross_flags=()
	else
		# Cross-compile build
		cmake_cross_flags=(
			-DCMAKE_CROSSCOMPILING=ON
			-DCMAKE_SYSTEM_NAME=Linux
			-DCMAKE_SYSTEM_PROCESSOR=aarch64
			-DCMAKE_SYSROOT="${SDCARD}"
			-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
			-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
			-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
			-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
		)
	fi

	cmake "${src_dir}" \
		-DCMAKE_INSTALL_PREFIX="${prefix}" \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_TESTS=OFF \
		-DBUILD_STATIC=OFF \
		-DCMAKE_C_COMPILER="${CC}" \
		-DCMAKE_CXX_COMPILER="${CXX}" \
		"${cmake_cross_flags[@]}"
	# Only pass CMAKE_STRIP when we actually have one; an empty/invalid
	# value makes the static-library "strip" step fail with Error 127.
	[[ -n "${STRIP:-}" ]] && cmake -DCMAKE_STRIP="${STRIP}" .

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

	_rockchip_multimedia_fetch_pinned "${EXT_RGA_GIT}" "${EXT_RGA_REF}" "${src_dir}" || return 1

	# Upstream librga (airockchip) ships prebuilt libraries and headers; the
	# old CMakeLists.txt build was removed.  Just stage the aarch64 libs +
	# headers and copy them into the image.
	local prebuilt_dir="${src_dir}/libs/Linux/gcc-aarch64"
	if [[ -f "${prebuilt_dir}/librga.so" ]]; then
		display_alert "rockchip-multimedia" "installing librga prebuilt (aarch64)" "info"
		# NOTE: lib_dir is already relative ("usr/lib/aarch64-linux-gnu"), so it
		# must NOT be prefixed with ${prefix} - that would yield usr/usr/lib/...
		mkdir -p "${stage_dir}/${lib_dir}" "${stage_dir}/usr/include/rga"
		cp -a "${prebuilt_dir}/librga.so" "${stage_dir}/${lib_dir}/librga.so"
		cp -a "${prebuilt_dir}/librga.a" "${stage_dir}/${lib_dir}/librga.a" 2>/dev/null || true
		cp -a "${src_dir}/include/." "${stage_dir}/usr/include/rga/" 2>/dev/null || true
		rsync -av "${stage_dir}/" "${SDCARD}/"
		return 0
	fi

	# Fall back to building from source for older librga releases.
	mkdir -p "${build_dir}"
	cd "${build_dir}"

	local cmake_cross_flags=()
	if [[ "${_RMM_NATIVE_BUILD:-0}" == "1" ]]; then
		cmake_cross_flags=()
	else
		cmake_cross_flags=(
			-DCMAKE_CROSSCOMPILING=ON
			-DCMAKE_SYSTEM_NAME=Linux
			-DCMAKE_SYSTEM_PROCESSOR=aarch64
			-DCMAKE_SYSROOT="${SDCARD}"
			-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
			-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
			-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
			-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
		)
	fi

	cmake "${src_dir}" \
		-DCMAKE_INSTALL_PREFIX="${prefix}" \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_TESTS=OFF \
		-DBUILD_SHARED_LIBS=ON \
		-DCMAKE_C_COMPILER="${CC}" \
		-DCMAKE_CXX_COMPILER="${CXX}" \
		"${cmake_cross_flags[@]}"
	[[ -n "${STRIP:-}" ]] && cmake -DCMAKE_STRIP="${STRIP}" .

	make -j"$(nproc)"
	DESTDIR="${stage_dir}" make install
	rsync -av "${stage_dir}/" "${SDCARD}/"
}

# ============================================================ RKNN --
function _rockchip_multimedia_build_rknn() {
	_rmm_init
	local src_dir="${work_dir}/src/rknn-toolkit2"
	local stage_dir="${work_dir}/stage/rknn"

	_rockchip_multimedia_fetch_pinned "${EXT_RKNN_GIT}" "${EXT_RKNN_REF}" "${src_dir}" || return 1

	# RKNN toolkit2 provides prebuilt libs under
	# rknpu2/runtime/Linux/librknn_api/aarch64/
	local prebuilt_dir="${src_dir}/rknpu2/runtime/Linux/librknn_api/aarch64"
	local include_dir="${src_dir}/rknpu2/runtime/Linux/librknn_api/include"
	if [[ -d "${prebuilt_dir}" ]]; then
		display_alert "rockchip-multimedia" "installing RKNN prebuilt runtime (aarch64)" "info"
		mkdir -p "${stage_dir}/${lib_dir}" "${stage_dir}${prefix}/include/rockchip"
		cp -av "${prebuilt_dir}/"*.so* "${stage_dir}/${lib_dir}/"
		[[ -d "${include_dir}" ]] && cp -av "${include_dir}/"*.h "${stage_dir}${prefix}/include/rockchip/" 2>/dev/null || true
		rsync -av "${stage_dir}/" "${SDCARD}/"
	else
		display_alert "rockchip-multimedia" "RKNN prebuilt libs not found at ${prebuilt_dir}" "warn"
	fi
}

# ============================================================ VA-API --
function _rockchip_multimedia_build_vaapi() {
	_rmm_init
	local src_dir="${work_dir}/src/libva-rkmpp"
	local stage_dir="${work_dir}/stage/libva-rkmpp"

	_rockchip_multimedia_fetch_pinned "${EXT_VADRV_GIT}" "${EXT_VADRV_REF}" "${src_dir}" || return 1

	# woodyst/rockchip-vaapi: VA-API -> MPP 桥接, 注册 VLD 解码 (H264/HEVC/VP9).
	# 依赖 libva 头文件 + librockchip_mpp (上一步已装).
	if ! pkg-config --exists libva 2>/dev/null; then
		display_alert "rockchip-multimedia" "installing libva dev package for VA-API build" "info"
		apt-get -qq update -y && apt-get -qq install -y libva-dev
	fi

	# MPP 库已 staged, 链接时指过去
	local mpp_stage="${work_dir}/stage/mpp"
	if [[ -d "${mpp_stage}${prefix}/${lib_dir}" ]]; then
		export LIBRARY_PATH="${mpp_stage}${prefix}/${lib_dir}:${LIBRARY_PATH:-}"
		export LD_LIBRARY_PATH="${mpp_stage}${prefix}/${lib_dir}:${LD_LIBRARY_PATH:-}"
		export PKG_CONFIG_PATH="${mpp_stage}${prefix}/${lib_dir}/pkgconfig:${PKG_CONFIG_PATH:-}"
	fi

	cd "${src_dir}"
	# 目标名与旧驱动一致, 直接覆盖只有编码的 rockchip_drv_video.so
	local va_out="rockchip_drv_video.so"
	if make -j"$(nproc)" CC="${CC}" 2>&1; then
		mkdir -p "${stage_dir}${prefix}/${lib_dir}/dri"
		install -m 755 "${va_out}" "${stage_dir}${prefix}/${lib_dir}/dri/${va_out}"
		rsync -av "${stage_dir}/" "${SDCARD}/"
		display_alert "rockchip-multimedia" "VA-API decode driver installed (${va_out})" "info"
	else
		display_alert "rockchip-multimedia" "VA-API driver build failed; MPP remains the video path" "warn"
	fi
}

# ============================================================ Hooks --
function pre_customize_image__rockchip_multimedia_install() {
	_rmm_source_framework || return 1
	_rmm_init

	local mali_repo="${MALI_REPO_PATH:-}"
	if [[ -z "${mali_repo}" || ! -d "${mali_repo}" ]]; then
		for _mali_candidate in \
			"${SRC:-}/extensions/mali-repo" \
			/armbian/extensions/mali-repo \
			"${SRC:-}/custom/mali-repo" \
			/armbian/custom/mali-repo \
			"${SRC:-}/mali-repo" \
			/armbian/mali-repo; do
			if [[ -d "${_mali_candidate}" ]]; then
				mali_repo="${_mali_candidate}"
				break
			fi
		done
	fi
	if [[ -z "${mali_repo}" || ! -d "${mali_repo}" ]]; then
		exit_with_error "rockchip-multimedia: Mali repository directory is not available"
	fi

	local mali_deb
	mali_deb="$(find "${mali_repo}" -maxdepth 1 -type f -name 'libmali-*.deb' -print -quit)"
	if [[ -z "${mali_deb}" || ! -s "${mali_deb}" ]]; then
		exit_with_error "rockchip-multimedia: no non-empty Mali package found in ${mali_repo}"
	fi

	display_alert "rockchip-multimedia" "installing Mali package: ${mali_deb}" "info"
	install_deb_chroot "${mali_deb}"

	display_alert "rockchip-multimedia" "installing MPP + librga + RKNN + VA-API backend" "info"

	_rockchip_multimedia_build_mpp
	_rockchip_multimedia_build_rga
	_rockchip_multimedia_build_rknn
	_rockchip_multimedia_build_vaapi

	display_alert "rockchip-multimedia" "installed MPP + librga + RKNN runtime + VA-API backend" "info"
}

# NOTE: the first customize_image definition wins, so symlink setup runs from
# the final pre-umount hook below after the Mali package has been installed.
function _rockchip_multimedia_setup_mali_symlinks() {
	display_alert "rockchip-multimedia" "configuring Mali G52 EGL/GLES/GBM providers" "info"

	local mali_lib_dir="${lib_dir}/mali-egl"
	for _wrapper in libEGL.so.1 libGLESv2.so.2 libgbm.so.1; do
		if [[ ! -e "${SDCARD}/${mali_lib_dir}/${_wrapper}" ]]; then
			exit_with_error "rockchip-multimedia: Mali wrapper missing: /${mali_lib_dir}/${_wrapper}"
		fi
		ln -sf "mali-egl/${_wrapper}" "${SDCARD}/${lib_dir}/${_wrapper}"
	done

	# OpenCL support is chip/blob dependent and is not required for the desktop.
	if [[ -e "${SDCARD}/${mali_lib_dir}/libOpenCL.so.1" ]]; then
		ln -sf "mali-egl/libOpenCL.so.1" "${SDCARD}/${lib_dir}/libOpenCL.so.1"
	fi

	mkdir -p "${SDCARD}/etc/profile.d"
	cat > "${SDCARD}/etc/profile.d/rockchip-vaapi.sh" << 'EOF'
export LIBVA_DRIVER_NAME=rkmpp
export LIBVA_DRIVERS_PATH=/usr/lib/aarch64-linux-gnu/dri
EOF

	display_alert "rockchip-multimedia" "Mali G52 providers configured" "info"
}

function pre_umount_final_image__rockchip_multimedia_verify() {
	_rmm_source_framework || return 1
	_rmm_init

	# Set up the Mali symlinks here (the customize_image hook is dropped by
	# the framework due to an "Extension conflict") and *then* verify.
	_rockchip_multimedia_setup_mali_symlinks

	display_alert "rockchip-multimedia" "verifying installation on rootfs" "info"

	# SDCARD is a readonly global - use it directly

	# Check core libraries. Names match what the build steps actually install:
	# MPP installs librockchip_mpp.so (not libmpp.so), librga ships prebuilt
	# librga.so, RKNN runtime ships librknnrt.so (not librknn_api.so).
	# The VA-API driver (rkmpp_drv_video.so) is optional - its build is
	# non-fatal because it needs librkenc-* which we do not build.
	for f in \
		"${lib_dir}/librockchip_mpp.so" \
		"${lib_dir}/librga.so" \
		"${lib_dir}/librknnrt.so"; do
		if [[ ! -e "${SDCARD}/${f}" ]]; then
			exit_with_error "rockchip-multimedia: expected file missing from rootfs: /${f}"
		fi
	done

	# Optional bits: only warn if the VA-API driver was skipped.
	for f in \
		"${lib_dir}/dri/rkmpp_drv_video.so" \
		"etc/profile.d/rockchip-vaapi.sh"; do
		if [[ ! -e "${SDCARD}/${f}" ]]; then
			display_alert "rockchip-multimedia" "optional file missing from rootfs: /${f}" "warn"
		fi
	done

	# Runtime provider links must resolve inside the Mali package directory.
	for _gl in libEGL.so.1 libGLESv2.so.2 libgbm.so.1; do
		if [[ ! -L "${SDCARD}/${lib_dir}/${_gl}" ]]; then
			exit_with_error "rockchip-multimedia: /${lib_dir}/${_gl} is not a Mali provider symlink"
		fi
		local _target
		_target="$(readlink -f "${SDCARD}/${lib_dir}/${_gl}")"
		if [[ "${_target}" != *"${lib_dir}/mali-egl/"* ]]; then
			exit_with_error "rockchip-multimedia: ${_gl} -> ${_target} (expected Mali provider)"
		fi
	done

	# Reject Meson's small dummy library. The real G52 g24p0 blob is tens of MB.
	local _mali_core
	_mali_core="$(find "${SDCARD}/${lib_dir}/mali-egl" -maxdepth 1 -type f -name 'libmali.so.*' -size +10M -print -quit)"
	if [[ -z "${_mali_core}" ]]; then
		exit_with_error "rockchip-multimedia: real Mali G52 blob missing or implausibly small"
	fi
	display_alert "rockchip-multimedia" "verified Mali core: ${_mali_core} ($(stat -c '%s' "${_mali_core}") bytes)" "info"
	display_alert "rockchip-multimedia" "verified: MPP + librga + RKNN runtime + Mali G52 EGL/GLES/GBM installed" "info"
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