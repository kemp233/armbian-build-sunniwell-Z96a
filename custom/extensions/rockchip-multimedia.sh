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
	# build-with-mali.yml.
	#
	# libgl1-mesa-dri provides the desktop GLX fallback that X11-only
	# desktops (cinnamon/xfce on this board) need. For wayland desktops
	# (gnome) it is actively harmful: gnome-shell resolves GL via GLX during
	# the X11-greeter phase and would pick Mesa's llvmpipe instead of the
	# Mali blob, so hardware compositing never engages.
	local mesa_glx_pkg=""
	if [[ "${DESKTOP_ENVIRONMENT:-}" != "gnome" ]]; then
		mesa_glx_pkg="libgl1-mesa-dri"
	fi

	# add tools/regulatory data used to verify USB Ethernet and USB
	# Wi-Fi/Bluetooth devices.
	add_packages_to_image libegl1 libgles2 ${mesa_glx_pkg} libva2 libva-drm2 vainfo glmark2-es2 mesa-utils-extra ethtool iw wireless-regdb bluez
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

	# MPP 头文件装在 staging 目录 (不落宿主 /usr/include), 必须显式指给 Makefile.
	# Makefile 用 := 硬编码 CFLAGS, 命令行传 CFLAGS 会覆盖 pkg-config 的 libva include,
	# 所以直接在 Makefile 里追加 include 路径.
	local mpp_inc="${mpp_stage}${prefix}/include"
	if [[ -d "${mpp_inc}/rockchip" ]]; then
		sed -i "s|-I/usr/include/rockchip|-I${mpp_inc} -I${mpp_inc}/rockchip -I/usr/include/rockchip|" "${src_dir}/Makefile"
		display_alert "rockchip-multimedia" "patched Makefile include path -> ${mpp_inc}" "info"
	fi

	# woodyst/rockchip-vaapi 面向 libva 2.x (VA-API 1.20), Debian bookworm 是 libva 1.17:
	#   1. VAProfileH264High10 枚举在 libva 1.17 里不存在 (2.x 才加), 编译报 undeclared.
	#      用一个不冲突的占位值 (0x1000), 让 case 分支编过去; RK3568 硬件没有 High10 解码,
	#      占位值不会真的被走到.
	#      注意: 不能用 VAProfileH264StereoHigh+1, 那样会撞上 VAProfileHEVCMain=17 (duplicate case).
	#   2. 驱动只导出 __vaDriverInit_1_20, 而 libva 1.17 dlopen 后找 __vaDriverInit_1_0,
	#      "has no function __vaDriverInit_1_0" -> 加薄别名.
	if ! grep -q "libva < 2.0 lacks High10" "${src_dir}/src/h264.h"; then
		sed -i "/#include <va\/va.h>/a #include <va/va_compat.h>\n\n/* libva < 2.0 lacks High10 profile enum */\n#ifndef VAProfileH264High10\n#define VAProfileH264High10 (0x1000)\n#endif" "${src_dir}/src/h264.h"
	fi
	if ! grep -q "__vaDriverInit_1_0" "${src_dir}/src/rockchip_drv_video.c"; then
		cat >> "${src_dir}/src/rockchip_drv_video.c" <<'VAEOF'

/* libva < 2.0 (Debian bookworm = 1.17) looks up __vaDriverInit_1_0, but this
 * driver only exports __vaDriverInit_1_20. Provide a thin alias. */
extern VAStatus __vaDriverInit_1_20(VADriverContextP ctx);
VAStatus __vaDriverInit_1_0(VADriverContextP ctx) { return __vaDriverInit_1_20(ctx); }
VAEOF
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
	_rockchip_multimedia_setup_vdec_mpp_owner
	_rockchip_multimedia_setup_gpu_access

	display_alert "rockchip-multimedia" "installed MPP + librga + RKNN runtime + VA-API backend" "info"
}

# RK3568 rkvdec 被 staging 的 rockchip_vdec (V4L2) 和 mpp_rkvdec (MPP) 同时 claim.
# 内核里 mpp_rkvdec 的 of_match 表是旧的 (只认 rk3328/rk3399/v1), 不含
# rockchip,rkv-decoder-rk3568, 而 rockchip_vdec 有 rk3568 alias -> V4L2 抢先绑定,
# MPP 拿不到设备, libva 报 "client 9 driver is not ready".
# 修复: (1) blacklist rockchip_vdec; (2) dtb 里给 rkvdec 加 v1 compatible.
function _rockchip_multimedia_setup_vdec_mpp_owner() {
	# 1) 永久禁用 staging V4L2 驱动 (它和 MPP 抢同一个 fdf80200.rkvdec)
	cat > "${SDCARD}/etc/modprobe.d/blacklist-rockchip-vdec.conf" <<'MODEOF'
# rkvdec must be owned by the MPP framework (mpp_rkvdec) for libva/MPP decode.
# The staging rockchip_vdec driver grabs fdf80200.rkvdec first and leaves MPP
# with "client 9 driver is not ready".
blacklist rockchip_vdec
blacklist v4l2_h264
blacklist v4l2_vp9
MODEOF
	display_alert "rockchip-multimedia" "blacklisted staging rockchip_vdec (MPP owns rkvdec)" "info"

	# 2) dtb: rkvdec 加 rockchip,rkv-decoder-v1 (mpp_rkvdec 认的 compatible).
	#    armbian 启动用 /boot/dtb/<fdtfile>, 不是 /boot/dtb-<kernel>/.
	local dtb_glob="${SDCARD}/boot/dtb"
	local fdtfile
	fdtfile="$(grep -i '^fdtfile=' "${SDCARD}/boot/armbianEnv.txt" 2>/dev/null | cut -d= -f2 | tr -d ' \t\r' || true)"
	if [[ -z "${fdtfile}" ]]; then
		display_alert "rockchip-multimedia" "no fdtfile in armbianEnv.txt; skipping dtb rkvdec patch" "warn"
		return 0
	fi

	local dtb="${dtb_glob}/${fdtfile}"
	if [[ ! -f "${dtb}" ]]; then
		display_alert "rockchip-multimedia" "dtb not found: ${dtb}" "warn"
		return 0
	fi
	if ! command -v dtc >/dev/null 2>&1; then
		display_alert "rockchip-multimedia" "dtc missing; skipping dtb rkvdec patch" "warn"
		return 0
	fi

	# 已打过补丁就跳过
	if dtc -I dtb -O dts "${dtb}" 2>/dev/null | grep -q "rkv-decoder-v1"; then
		display_alert "rockchip-multimedia" "dtb already has rkv-decoder-v1" "info"
		return 0
	fi

	local dts_tmp
	dts_tmp="$(mktemp)"
	dtc -I dtb -O dts "${dtb}" > "${dts_tmp}" 2>/dev/null
	# compatible 字符串里的 \0 分隔符在 dts 里是字面 "\0"
	sed -i 's|compatible = "rockchip,rkv-decoder-rk3568\\0rockchip,rkv-decoder-v2";|compatible = "rockchip,rkv-decoder-v1\\0rockchip,rkv-decoder-rk3568\\0rockchip,rkv-decoder-v2";|' "${dts_tmp}"

	if dtc -I dtb -O dts "${dtb}" 2>/dev/null | grep -q "rkv-decoder-v1"; then
		: # 已含
	elif grep -q "rkv-decoder-v1" "${dts_tmp}"; then
		cp "${dtb}" "${dtb}.bak"
		if dtc -I dts -O dtb -o "${dtb}" "${dts_tmp}" 2>/dev/null; then
			display_alert "rockchip-multimedia" "patched dtb: added rkv-decoder-v1 to ${fdtfile}" "info"
		else
			cp "${dtb}.bak" "${dtb}"
			display_alert "rockchip-multimedia" "failed to recompile patched dtb; restored backup" "warn"
		fi
	else
		display_alert "rockchip-multimedia" "rkvdec compatible string not found in ${fdtfile}; dtb not patched" "warn"
	fi
	rm -f "${dts_tmp}"
}

# GPU access for the closed-source Mali blob.
#
# The G52 userspace blob here is the ARM proprietary mali_kbase stack: the kernel
# side is /dev/mali0 (mali_kbase does not implement DRM, so there is no GPU render
# node) and the userspace side is libmali's own "armsoc" gbm backend. That backend
# opens /dev/dma_heap/* from inside gbm_create_device().
#
# Two things block every non-root graphics session without this rule:
#
#   1. dma-heap nodes are created 0600 root:root and no distro rule opens them up.
#      libmali's gbm_create_device() then gets EACCES on /dev/dma_heap/system and
#      /dev/dma_heap/system-uncached. The errno left behind is ENOENT, from the
#      "protected" heap it probes last and that does not exist, so mutter reports
#      the confusing "Failed to create gbm device: No such file or directory" and
#      the GDM greeter's Wayland session dies ("Session never registered").
#   2. The GDM greeter runs as Debian-gdm, which is in neither video nor render and
#      gets no uaccess ACL, so it cannot even open /dev/dri/card0.
#
# With both fixed the greeter logs "Created gbm renderer for '/dev/dri/card0'" and
# comes up on Wayland ("Using Wayland display name 'wayland-0'").
function _rockchip_multimedia_setup_gpu_access() {
	display_alert "rockchip-multimedia" "granting video/render access to Mali gbm and /dev/dma_heap" "info"

	# The Debian-gdm user only exists once gdm3 is installed; the gnome env pulls
	# it in, but a bare desktop image may not have it yet.
	local _gdm_user=Debian-gdm
	if getent passwd "${_gdm_user}" >/dev/null; then
		usermod -aG video,render "${_gdm_user}"
	fi

	# Any pre-existing interactive user, so a serial-console install can log in
	# and get a GPU session without a manual usermod.
	for _u in $(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' "${SDCARD}/etc/passwd" 2>/dev/null); do
		usermod -aG video,render "${_u}"
	done

	mkdir -p "${SDCARD}/etc/udev/rules.d"
	cat > "${SDCARD}/etc/udev/rules.d/60-dma-heap-access.rules" <<'RULEOF'
# libmali's armsoc gbm backend opens these heaps from gbm_create_device().
# The kernel creates them 0600 root:root, so without this rule no non-root
# graphics session (GDM greeter included) can build a gbm device.
SUBSYSTEM=="dma_heap", KERNEL=="system|system-uncached|reserved", MODE="0660", GROUP="video"
KERNEL=="dma_heap[0-9]*", MODE="0660", GROUP="video"
RULEOF

	# No gdm config here on purpose: the gnome desktop package ships
	# packages/blobs/desktop/gdm/daemon.conf, which already pins
	# WaylandEnable=true and the wayland greeter. gdm3 merges daemon.conf with
	# custom.conf, so writing a second file here would only duplicate it.
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

	# Without this rule the blob cannot build a gbm device as a normal user and
	# the GDM greeter silently falls back to X11 with llvmpipe.
	if [[ ! -f "${SDCARD}/etc/udev/rules.d/60-dma-heap-access.rules" ]]; then
		exit_with_error "rockchip-multimedia: /etc/udev/rules.d/60-dma-heap-access.rules missing; Mali gbm will fail for non-root"
	fi

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