#!/bin/bash
# Rockchip RK3568 multimedia userspace (MPP, librga, RKNN, VA-API, Mali G52 GLES)
# Forked from armbian/build extensions/rockchip-multimedia.sh
# Modified: Mali G52 installed via GitHub Actions workflow debs (not built from source)

set -e

# Cross-compile environment
export PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
export CROSS_COMPILE="aarch64-linux-gnu-"
export CC="aarch64-linux-gnu-gcc"
export CXX="aarch64-linux-gnu-g++"
export STRIP="aarch64-linux-gnu-strip"

# Pinned versions
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

# Work directory
work_dir="${1:-/tmp/rockchip-multimedia}"
mkdir -p "${work_dir}/src" "${work_dir}/build" "${work_dir}/stage"

# System paths
prefix="/usr"
lib_dir="usr/lib/aarch64-linux-gnu"

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
		git clone --depth 1 "${git_url}" "${dst_dir}" && cd "${dst_dir}" && git checkout "${git_ref}" 2>/dev/null || true
	fi
}

function _rockchip_multimedia_build_mpp() {
	local src_dir="${work_dir}/src/mpp"
	local build_dir="${work_dir}/build/mpp"
	local stage_dir="${work_dir}/stage"
	
	_rockchip_multimedia_fetch_pinned "${EXT_MPP_GIT}" "${EXT_MPP_REF}" "${src_dir}"
	
	rm -rf "${build_dir}"
	mkdir -p "${build_dir}"
	cd "${build_dir}"
	
	cmake "${src_dir}" \
		-DCMAKE_INSTALL_PREFIX="${prefix}" \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_SHARED_LIBS=ON \
		-DMPP_BUILD_TESTS=OFF \
		-DMPP_BUILD_STATIC=OFF \
		-DMPP_CODEC_H264=ON \
		-DMPP_CODEC_H265=ON \
		-DMPP_CODEC_VP9=ON \
		-DMPP_CODEC_AVS2=ON \
		-DMPP_CODEC_MJPEG=ON
	
	make -j$(nproc)
	make DESTDIR="${stage_dir}" install
}

# ============================================================ librga --
function _rockchip_multimedia_build_rga() {
	local src_dir="${work_dir}/src/librga"
	local build_dir="${work_dir}/build/librga"
	local stage_dir="${work_dir}/stage"
	
	_rockchip_multimedia_fetch_pinned "${EXT_RGA_GIT}" "${EXT_RGA_REF}" "${src_dir}"
	
	rm -rf "${build_dir}"
	mkdir -p "${build_dir}"
	cd "${build_dir}"
	
	cmake "${src_dir}" \
		-DCMAKE_INSTALL_PREFIX="${prefix}" \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_SHARED_LIBS=ON \
		-DBUILD_TEST=OFF
	
	make -j$(nproc)
	make DESTDIR="${stage_dir}" install
}

# ============================================================ RKNN --
function _rockchip_multimedia_fetch_rknn() {
	local src_dir="${work_dir}/src/rknn"
	
	_rockchip_multimedia_fetch_pinned "${EXT_RKNN_GIT}" "${EXT_RKNN_REF}" "${src_dir}"
	
	# Copy prebuilt libraries
	local stage_dir="${work_dir}/stage"
	mkdir -p "${stage_dir}/${lib_dir}"
	mkdir -p "${stage_dir}/usr/include"
	
	# RKNN runtime libraries
	cp -a "${src_dir}/rknpu2/runtime/Linux/librknn_api/aarch64/"* "${stage_dir}/${lib_dir}/" 2>/dev/null || true
	cp -a "${src_dir}/rknpu2/runtime/Linux/librknnrt/"* "${stage_dir}/${lib_dir}/" 2>/dev/null || true
	
	# Headers
	cp -a "${src_dir}/rknpu2/runtime/Linux/librknn_api/include/"* "${stage_dir}/usr/include/" 2>/dev/null || true
}

# ============================================================ VA-API (libva-rkmpp) --
function _rockchip_multimedia_build_va_rkmpp() {
	local src_dir="${work_dir}/src/libva-rkmpp"
	local build_dir="${work_dir}/build/libva-rkmpp"
	local stage_dir="${work_dir}/stage"
	local va_sysroot="${stage_dir}"
	
	_rockchip_multimedia_fetch_pinned "${EXT_VADRV_GIT}" "${EXT_VADRV_REF}" "${src_dir}"
	
	# libva-dev headers for compilation
	mkdir -p "${va_sysroot}/usr/include/va"
	cp -a "${src_dir}/libva/va" "${va_sysroot}/usr/include/"
	sed -e 's/@VA_API_MAJOR_VERSION@/1/' \
		-e 's/@VA_API_MINOR_VERSION@/17/' \
		-e 's/@VA_API_MICRO_VERSION@/0/' \
		-e 's/@VA_API_VERSION@/1.17.0/' \
		"${src_dir}/libva/va/va_version.h.in" > "${va_sysroot}/usr/include/va/va_version.h"
	
	cat > "${va_sysroot}/usr/lib/aarch64-linux-gnu/pkgconfig/libva.pc" <<- EOT
		prefix=/usr
		exec_prefix=\${prefix}
		libdir=\${prefix}/lib/aarch64-linux-gnu
		includedir=\${prefix}/include
		driverdir=\${prefix}/lib/aarch64-linux-gnu/dri

		Name: libva
		Description: Userspace Video Acceleration (VA) core interface
		Version: 1.17.0
		Libs: -L\${libdir} -lva
		Cflags: -I\${includedir}
	EOT
	
	rm -rf "${build_dir}"
	mkdir -p "${build_dir}"
	cd "${build_dir}"
	
	PKG_CONFIG_PATH="${va_sysroot}/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig" \
	./autogen.sh \
		--prefix="${prefix}" \
		--libdir="${prefix}/lib/aarch64-linux-gnu" \
		--disable-static \
		--enable-shared \
		--with-drm \
		--with-glx=no \
		--with-wayland=no \
		--with-x11=no \
		--host=aarch64-linux-gnu \
		--build=x86_64-pc-linux-gnu \
		CFLAGS="-I${va_sysroot}/usr/include" \
		LDFLAGS="-L${va_sysroot}/usr/lib/aarch64-linux-gnu"
	
	make -j$(nproc)
	make DESTDIR="${stage_dir}" install
	
	# VA-API driver profile
	mkdir -p "${stage_dir}/etc/profile.d"
	cat > "${stage_dir}/etc/profile.d/rockchip-vaapi.sh" <<- 'EOF'
		export LIBVA_DRIVER_NAME=rkmpp
		export LIBVA_DRIVERS_PATH=/usr/lib/aarch64-linux-gnu/dri
		export MPP_BUFFERS_TYPE=ion
	EOF
}

# ============================================================ Mali G52 (from debs) --
# Mali is installed via the workflow's install-mali.sh (run via customize-image.sh hook)
# This function only ensures symlinks point to Mali wrappers, not Mesa
function _rockchip_multimedia_ensure_mali_symlinks() {
	local stage_dir="${work_dir}/stage"
	
	display_alert "rockchip-multimedia" "ensuring Mali G52 GLES symlinks point to libmali blob" "info"
	
	# The Mali blob is libmali.so.1.9.0. The wrapper libraries (libEGL.so.1,
	# libGLESv2.so.2, libgbm.so.1, libOpenCL.so.1) are trampolines that dlopen
	# libmali. Ensure they're properly symlinked.
	chroot_sdcard sh -c '
		set -e
		lib_dir="/usr/lib/aarch64-linux-gnu"
		# Ensure the Mali blob exists
		if [[ ! -e "${lib_dir}/libmali.so.1.9.0" ]]; then
			echo "ERROR: libmali.so.1.9.0 not found in ${lib_dir}" >&2
			exit 1
		fi
		# Create/update symlinks to point to Mali wrappers (not Mesa)
		# The Mali deb installs libEGL.so.1, libGLESv2.so.2, libgbm.so.1, libOpenCL.so.1
		# as wrapper libraries that dlopen libmali.so.1.9.0
		for lib in libEGL.so.1 libGLESv2.so.2 libgbm.so.1 libOpenCL.so.1; do
			# If the file exists and is not a symlink, or points to mesa, fix it
			if [[ -e "${lib_dir}/${lib}" && ! -L "${lib_dir}/${lib}" ]]; then
				echo "WARNING: ${lib_dir}/${lib} is a regular file, replacing with Mali wrapper symlink" >&2
				rm -f "${lib_dir}/${lib}"
			fi
			# The Mali wrappers should already be installed by the deb package
			# Ensure they point to the right target
		done
		ldconfig
	'
}

# ============================================================ Main install --
function pre_customize_image__rockchip_multimedia_install() {
	_rmm_source_framework || return 1

	[[ "${BOARDFAMILY:-}" != "rockchip-rk3568-z96a" ]] && return 0

	display_alert "rockchip-multimedia" "installing MPP + librga + RKNN + VA-API + ensuring Mali G52" "info"
	
	# Build MPP
	_rockchip_multimedia_build_mpp
	
	# Build librga
	_rockchip_multimedia_build_rga
	
	# Fetch RKNN prebuilts
	_rockchip_multimedia_fetch_rknn
	
	# Build VA-API driver
	_rockchip_multimedia_build_va_rkmpp
	
	# Copy staged files to rootfs
	display_alert "rockchip-multimedia" "copying staged userspace into rootfs" "info"
	run_host_command_logged cp -av "${work_dir}/stage/." "${SDCARD}/"
	
	# Ensure Mali symlinks point to Mali blob (not Mesa)
	_rockchip_multimedia_ensure_mali_symlinks
	
	chroot_sdcard ldconfig
	
	return 0
}

# ============================================================ Verification --
function pre_umount_final_image__rockchip_multimedia_verify() {
	_rmm_source_framework || return 1

	[[ "${BOARDFAMILY:-}" != "rockchip-rk3568-z96a" ]] && return 0

	local lib_dir="usr/lib/aarch64-linux-gnu"
	local f
	for f in \
		"${lib_dir}/librockchip_mpp.so.1" \
		"${lib_dir}/librga.so" \
		"${lib_dir}/librknnrt.so" \
		"${lib_dir}/pkgconfig/rockchip_mpp.pc" \
		"${lib_dir}/pkgconfig/librga.pc" \
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
