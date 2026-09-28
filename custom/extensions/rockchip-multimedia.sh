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
	# VA 驱动: sfqr0414/rockchip_vaapi_driver, C++20 + CMake, 经 MPP 拿帧的
	# dma-buf fd 直接导出, 有真正的零拷贝开关 ROCKCHIP_VAAPI_DISABLE_STABLE_EXPORT=1
	# (mpp_decoder.cpp: stable_export_enabled_), 并且原生导出 __vaDriverInit_1_0
	# (driver.cpp 的 extern "C" __vaDriverInit_1_0), libva 1.17/2.x 都能 dlopen。
	#
	# 换掉之前那个 woodyst/rockchip-vaapi 的两个理由:
	#   1. 它只有"每帧 memcpy 进驱动自有常驻 DRM 缓冲"一种导出方式, 根本没有零拷贝;
	#   2. 它其实一次都没编进过镜像。构建容器是 Ubuntu jammy arm64, 装的是
	#      libva-dev:arm64 2.14; 而它 Makefile 里硬写的 -lrockchip_mpp 找不到库
	#      —— 旧代码把 LIBRARY_PATH 拼成了 stage/mpp/usr/usr/lib/... (lib_dir 本身
	#      已经是 "usr/lib/aarch64-linux-gnu", 再叠 ${prefix} 就成了 usr/usr)。
	#      日志里那行 "VA-API driver build failed" 只是 warn, 镜像照样出, 于是
	#      /usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so 一直是空的。
	#      现在改成硬失败, 编不出来就不让镜像出去。
	#
	# 按 commit 钉死而不是 master: 这份补丁是照着 f120c5e 生成的, 上游一改就
	# 可能对不上, 到时候构建会直接失败而不是悄悄编出一个行为不明的驱动。
	EXT_VADRV_GIT="https://github.com/sfqr0414/rockchip_vaapi_driver.git"
	EXT_VADRV_REF="f120c5e855aa5f4e4856ec473aa0abf0c53567d8"

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

	# 40 位 commit SHA: git clone --branch 只认 tag/branch, 传 SHA 会报
	# "Remote branch <sha> not found", 而它的兜底 clone 拉的是默认分支 HEAD,
	# 于是钉版本等于没钉。GitHub 允许按 SHA 取 (allowReachableSHA1InWant),
	# 所以这里 clone 后再 fetch --depth 1 那个 SHA。
	if [[ "${git_ref}" =~ ^[0-9a-f]{40}$ ]]; then
		if [[ -d "${dst_dir}/.git" ]]; then
			git -C "${dst_dir}" fetch --depth 1 origin "${git_ref}" && \
				git -C "${dst_dir}" checkout -q FETCH_HEAD
		else
			rm -rf "${dst_dir}"
			git clone --filter=blob:none "${git_url}" "${dst_dir}" && \
				git -C "${dst_dir}" fetch --depth 1 origin "${git_ref}" && \
				git -C "${dst_dir}" checkout -q FETCH_HEAD
		fi
	elif [[ -d "${dst_dir}/.git" ]]; then
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

	# 钉的是 SHA 的话, 确认真的 checkout 到了那个 commit —— fetch 失败但
	# clone 成功时会静默停在默认分支上, 补丁多半对不上, 早失败比晚失败好。
	if [[ "${git_ref}" =~ ^[0-9a-f]{40}$ ]]; then
		local got
		got="$(git -C "${dst_dir}" rev-parse HEAD 2>/dev/null || echo none)"
		if [[ "${got}" != "${git_ref}" ]]; then
			display_alert "rockchip-multimedia" "pinned ${git_ref} but HEAD is ${got}" "err"
			return 1
		fi
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
# 找 extensions/vaapi-compat/ 目录 (补丁 + <format> 兼容头都在里面)。
# 和上面找 mali-repo 用的是同一套候选路径, 因为 custom/extensions/ 会被 rsync
# 到 build/extensions/, 而 SRC 指向的正是那个 build 树。
function _rockchip_multimedia_find_vaapi_compat() {
	local _c
	for _c in \
		"${SRC:-}/extensions/vaapi-compat" \
		/armbian/extensions/vaapi-compat \
		"${SRC:-}/custom/extensions/vaapi-compat" \
		/armbian/custom/extensions/vaapi-compat \
		"$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/vaapi-compat"
	do
		[[ -n "${_c}" && -d "${_c}" ]] || continue
		[[ -f "${_c}/format" && -f "${_c}/rockchip_vaapi_driver-local.patch" ]] || continue
		echo "${_c}"
		return 0
	done
	return 1
}

function _rockchip_multimedia_build_vaapi() {
	_rmm_init
	local src_dir="${work_dir}/src/rockchip_vaapi_driver"
	local build_dir="${work_dir}/build/rockchip_vaapi_driver"
	local stage_dir="${work_dir}/stage/rockchip-vaapi"

	_rockchip_multimedia_fetch_pinned "${EXT_VADRV_GIT}" "${EXT_VADRV_REF}" "${src_dir}" || return 1

	# 板上验证过的本地修补。内容全是板上跑出来的问题, 不是可选优化:
	#   * vtable 里原本没人填的槽位补成 no-op —— 原样是 calloc 出来的 NULL,
	#     客户端调到就是跳空指针;
	#   * vaQuerySurfaceAttributes / vaGetSurfaceAttributes 在 vtable 里位置写反了;
	#   * ffmpeg 的 libavutil 建 surface 时不填 attr.value.type, 而这块板的
	#     VAGenericValueType 从 1 开始, 于是 value.type==0 被当成非法值拒掉;
	#   * RK3568 上 MPP 会在**成功解出**的帧上残留 errinfo (实测恒为 10), 默认不信它;
	#   * 输出线程在持 pending_mutex_ 的路径里再调 getPendingQueueSummary() 会自死锁;
	#   * AV1 profile 不再对外宣称支持 (MPP 报 "unable to create dec av1 for soc rk3568");
	#   * 默认走 stable-export, ROCKCHIP_VAAPI_DISABLE_STABLE_EXPORT=1 才切真零拷贝;
	#   * CMakeLists 链 fmt (下面那个 <format> 兼容头要它)。
	# 补丁是照 ${EXT_VADRV_REF} 那个 commit 生成的; 重复跑构建时已经在树上就跳过。
	local compat_dir
	compat_dir="$(_rockchip_multimedia_find_vaapi_compat || true)"
	if [[ -z "${compat_dir}" ]]; then
		exit_with_error "rockchip-multimedia: extensions/vaapi-compat/ not found (needs format + rockchip_vaapi_driver-local.patch)"
	fi
	if git -C "${src_dir}" apply --reverse --check "${compat_dir}/rockchip_vaapi_driver-local.patch" 2>/dev/null; then
		display_alert "rockchip-multimedia" "VA driver local patch already applied" "info"
	elif ! git -C "${src_dir}" apply --check "${compat_dir}/rockchip_vaapi_driver-local.patch" 2>/dev/null; then
		exit_with_error "rockchip-multimedia: cannot apply ${compat_dir}/rockchip_vaapi_driver-local.patch to ${EXT_VADRV_REF}"
	else
		git -C "${src_dir}" apply "${compat_dir}/rockchip_vaapi_driver-local.patch"
		display_alert "rockchip-multimedia" "applied VA driver local patch -> ${src_dir}" "info"
	fi

	# 构建依赖。libva 是构建容器 (Ubuntu jammy arm64) 的 2.14, 原生带
	# VAProfileH264High10, 驱动也按 2.x 的 va_backend.h 写, 不需要任何占位补丁。
	#
	# 这里**没有** libva-drm-dev: Ubuntu/Debian 没有这个包, CMakeLists 里的
	# pkg_check_modules(LIBVA_DRM REQUIRED libva-drm) 是靠 libva-dev 自带的
	# /usr/lib/<triplet>/pkgconfig/libva-drm.pc 和 va/va_drm.h 满足的。
	# 之前误列了它, apt 报 "Unable to locate package libva-drm-dev", 整个
	# install 一起失败。板子上编译成功那套依赖里也没有它, 可以对上。
	#
	# libfmt-dev 是给 <format> 兼容头用的 (gcc-11/12 没有 C++20 <format>),
	# 它在 Ubuntu 的 universe 里; 构建镜像 universe 是开的 (libva-dev 能装就是证明)。
	local va_pkgs=()
	local p
	for p in cmake pkg-config g++ make libva-dev libdrm-dev libfmt-dev; do
		dpkg -s "${p}" >/dev/null 2>&1 || va_pkgs+=("${p}")
	done
	if [[ ${#va_pkgs[@]} -gt 0 ]]; then
		# apt-get install 里只要有一个包定位不到, 整条命令就不装任何东西。
		# 先把定位不到的挑出来单独报错, 别再让一个不存在的包把整批拖垮。
		local unavailable=()
		for p in "${va_pkgs[@]}"; do
			apt-cache show "${p}" >/dev/null 2>&1 || unavailable+=("${p}")
		done
		if [[ ${#unavailable[@]} -gt 0 ]]; then
			exit_with_error "rockchip-multimedia: no such package: ${unavailable[*]} (needed: ${va_pkgs[*]})"
		fi

		display_alert "rockchip-multimedia" "installing VA driver build deps: ${va_pkgs[*]}" "info"
		apt-get -qq update -y >/dev/null 2>&1 || true
		# 编不出驱动就别让镜像出去: 之前 woodyst 那版是 warn, 结果镜像里
		# 一直没有 rockchip_drv_video.so, 板子上才发现。
		if ! apt-get -qq install -y "${va_pkgs[@]}"; then
			# 再点名一次到底哪个没装上, 免得只能对着 apt 的一行输出猜。
			local still_missing=()
			for p in "${va_pkgs[@]}"; do
				dpkg -s "${p}" >/dev/null 2>&1 || still_missing+=("${p}")
			done
			exit_with_error "rockchip-multimedia: failed to install VA driver build deps: ${still_missing[*]:-${va_pkgs[*]}}"
		fi
	fi

	# MPP 是上一步 DESTDIR staged 的, 没进宿主 /usr。注意 lib_dir 本身就是
	# "usr/lib/aarch64-linux-gnu" 这个相对路径, 再叠 ${prefix} 会拼出
	# usr/usr/lib/... —— 之前 woodyst 那版就是这么把 -lrockchip_mpp 弄丢的。
	local mpp_stage="${work_dir}/stage/mpp"
	# 只在下面这两条 cmake 命令作用域里给, 不 export 出去: LD_LIBRARY_PATH 指向
	# 的是 /tmp 下的 staging 目录, 泄到后面构建步骤里会让它们优先加载这里的
	# librockchip_mpp, 而不是镜像里那一份。
	local mpp_lib_dir="${mpp_stage}/${lib_dir}"
	local mpp_inc_dir="${mpp_stage}${prefix}/include/rockchip"
	[[ -f "${mpp_inc_dir}/rk_mpi.h" ]] || \
		exit_with_error "rockchip-multimedia: ${mpp_inc_dir}/rk_mpi.h missing (MPP build stage incomplete)"
	[[ -f "${mpp_lib_dir}/librockchip_mpp.so" ]] || \
		exit_with_error "rockchip-multimedia: ${mpp_lib_dir}/librockchip_mpp.so missing (MPP build stage incomplete)"

	# <format> 垫头: 构建容器的 g++ 是 jammy 的 11 (板子上是 12), libstdc++ 都
	# 没有 C++20 <format>, 而 src/util/log.h 是驱动本体的头, 跑不掉。
	# 兼容头用 libfmt 实现那几个 API, 靠 -I 的搜索顺序抢在系统头前面。
	# 于是所有目标都得链 fmt —— 补丁里的 CMakeLists 已经加了。
	local compat_inc="${work_dir}/vaapi-compat-include"
	rm -rf "${compat_inc}"
	mkdir -p "${compat_inc}"
	install -m 644 "${compat_dir}/format" "${compat_inc}/format"
	# Debian/Ubuntu 的 libdrm 把头装在 /usr/include/libdrm/, 没有 /usr/include/drm/
	# 这一层, 而驱动按 libdrm 官方布局 include <drm/drm_fourcc.h>。
	if [[ ! -d /usr/include/drm ]]; then
		[[ -d /usr/include/libdrm ]] || exit_with_error "rockchip-multimedia: libdrm headers not found under /usr/include"
		ln -sfn /usr/include/libdrm "${compat_inc}/drm"
	fi

	rm -rf "${build_dir}"
	mkdir -p "${build_dir}"
	cd "${build_dir}" || return 1

	LIBRARY_PATH="${mpp_lib_dir}:${LIBRARY_PATH:-}" \
	LD_LIBRARY_PATH="${mpp_lib_dir}:${LD_LIBRARY_PATH:-}" \
	cmake "${src_dir}" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_C_COMPILER="${CC}" \
		-DCMAKE_CXX_COMPILER="${CXX}" \
		-DCMAKE_C_FLAGS="-I${compat_inc}" \
		-DCMAKE_CXX_FLAGS="-I${compat_inc}" \
		-DROCKCHIP_MPP_LIB="${mpp_lib_dir}/librockchip_mpp.so" \
		-DROCKCHIP_MPP_INCLUDE="${mpp_inc_dir}" \
		|| exit_with_error "rockchip-multimedia: cmake configure failed for ${src_dir}"

	# 只编驱动本体。tools/ 下那几个探针要 EGL/GLES/gbm 头, 那是板上排查 Firefox
	# 时用的, 跟镜像无关; 全量 make 会因为它们编不出来。
	LIBRARY_PATH="${mpp_lib_dir}:${LIBRARY_PATH:-}" \
	cmake --build . --target rockchip_drv_video -j"$(nproc)" \
		|| exit_with_error "rockchip-multimedia: rockchip_drv_video build failed"

	local va_out="${build_dir}/rockchip_drv_video.so"
	[[ -f "${va_out}" ]] || exit_with_error "rockchip-multimedia: ${va_out} not produced"

	# 门禁一: libva 靠 dlopen 找 __vaDriverInit_1_0 拿驱动入口。少了它就是
	# "vaInitialize: va_openDriver() failed" —— 板子上 Firefox 加载失败过一次。
	nm -D --defined-only "${va_out}" | grep -q " __vaDriverInit_1_0$" || \
		exit_with_error "rockchip-multimedia: ${va_out} does not export __vaDriverInit_1_0"

	# 门禁二: 别把带 not found 的库塞进镜像。构建容器本身就是 arm64, 未必装了
	# aarch64-linux-gnu-* 那套交叉 binutils, 两个名字都试一遍。
	local objdump_bin="" _t=""
	for _t in objdump aarch64-linux-gnu-objdump; do
		command -v "${_t}" >/dev/null 2>&1 && { objdump_bin="${_t}"; break; }
	done
	local missing_libs=""
	if [[ -n "${objdump_bin}" ]]; then
		missing_libs="$("${objdump_bin}" -p "${va_out}" 2>/dev/null | awk '/NEEDED/ {print $2}' | while read -r _l; do
			[[ -f "${mpp_lib_dir}/${_l}" || -e "/usr/lib/aarch64-linux-gnu/${_l}" ]] || echo "${_l}"
		done)"
	fi
	[[ -z "${missing_libs}" ]] || \
		exit_with_error "rockchip-multimedia: unresolved DT_NEEDED: ${missing_libs}"

	# lib_dir 已经是 "usr/lib/aarch64-linux-gnu" 这个相对路径, 这里再叠
	# ${prefix} 会得到 usr/usr/lib/... , rsync 进 rootfs 之后驱动就落在
	# /usr/usr/lib/... 下面, libva 照样找不到。跟上面 RKNN 那段一个写法。
	mkdir -p "${stage_dir}/${lib_dir}/dri"
	install -m 755 "${va_out}" "${stage_dir}/${lib_dir}/dri/rockchip_drv_video.so"
	rsync -av "${stage_dir}/" "${SDCARD}/"
	display_alert "rockchip-multimedia" "VA-API driver installed: usr/${lib_dir}/dri/rockchip_drv_video.so ($(stat -c '%s' "${va_out}") bytes)" "info"
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

# RK3568 的 rkvdec 必须由 vendor MPP rkvdec2 拥有, 否则硬解必然失败。
#
# of_match_node() 拿 compatible 列表的**第一个**串去匹配。本树里:
#   mpp_rkvdec2.c:1752  "rockchip,rkv-decoder-rk3568"  <- 全树唯一认这个串的驱动
#   mpp_rkvdec.c:1834   "rockchip,rkv-decoder-v1"      <- V1, RK3288/3399 时代转址表
#   staging rkvdec      "rockchip,rk3399-vdec"          <- 跟这个节点无关
#
# 所以 DTB 的第一个串必须是 rk3568。曾经在这里往 compatible 里**注入**
# rockchip,rkv-decoder-v1, 那是反的: V1 驱动抢先绑上, 而 RK3568 的 vdpu383 写的
# 是寄存器 128~232, V1 却按 {4,6,7,10,...} 去转址, 于是内核读到 "reg[10]=0x1",
# 拿 fd=1 去 dma_buf_get -> -EINVAL, 日志是
#   mpp_translate_reg_address:1897: reg[ 10]: 0x00000001 fd 1 failed
#
# 现在改成: 探测到 v1 就把它摘掉, 并确认 rk3568 排在最前。
function _rockchip_multimedia_setup_vdec_mpp_owner() {
	# 1) 顺手把 staging V4L2 驱动拉黑。它在 RK3568 上本来就绑不上 (只认
	#    rk3399-vdec), 但留着这条可以防止将来有人重新打开 CONFIG_VIDEO_ROCKCHIP_VDEC
	#    时又踩"V4L2 抢节点"这个已经被证伪的假设。
	cat > "${SDCARD}/etc/modprobe.d/blacklist-rockchip-vdec.conf" <<'MODEOF'
# rkvdec must be owned by the MPP framework (mpp_rkvdec2) for libva/MPP decode.
# The staging rockchip_vdec driver only matches rockchip,rk3399-vdec, so it is
# useless on RK3568; blacklisting it keeps the VPU node unambiguously MPP's.
blacklist rockchip_vdec
blacklist v4l2_h264
blacklist v4l2_hp9
blacklist v4l2_vp9
MODEOF
	display_alert "rockchip-multimedia" "blacklisted staging rockchip_vdec (MPP rkvdec2 owns rkvdec)" "info"

	# 2) dtb: 保证 rkvdec 的 compatible 第一个串是 rockchip,rkv-decoder-rk3568。
	#    armbian 启动用 /boot/dtb/<fdtfile>, 不是 /boot/dtb-<kernel>/.
	local dtb_glob="${SDCARD}/boot/dtb"
	local fdtfile
	fdtfile="$(grep -i '^fdtfile=' "${SDCARD}/boot/armbianEnv.txt" 2>/dev/null | cut -d= -f2 | tr -d ' \t\r' || true)"
	if [[ -z "${fdtfile}" ]]; then
		display_alert "rockchip-multimedia" "no fdtfile in armbianEnv.txt; skipping dtb rkvdec check" "warn"
		return 0
	fi

	local dtb="${dtb_glob}/${fdtfile}"
	if [[ ! -f "${dtb}" ]]; then
		display_alert "rockchip-multimedia" "dtb not found: ${dtb}" "warn"
		return 0
	fi
	if ! command -v dtc >/dev/null 2>&1; then
		display_alert "rockchip-multimedia" "dtc missing; skipping dtb rkvdec check" "warn"
		return 0
	fi

	# -@ 让 dtc 保留 __symbols__; armbian 的 boot.cmd 靠它做 dtbo 的 fdt apply。
	# 反编译和回编译都带 -@ (注意是 -@ 这个开关, 不是给文件名加 @ 后缀 ——
	# 后缀那种老写法会让 dtc 直接建出一个名字里带 @ 的文件)。
	local dts_tmp
	dts_tmp="$(mktemp --suffix=.dts)"
	if ! dtc -@ -I dtb -O dts -o "${dts_tmp}" "${dtb}" 2>/dev/null; then
		display_alert "rockchip-multimedia" "dtc decompile of ${fdtfile} failed; dtb left untouched" "warn"
		rm -f "${dts_tmp}"
		return 0
	fi

	# 已经是想要的样子就不动它 —— 重编译一次 dtb 毫无收益还有风险。
	if grep -q 'compatible = "rockchip,rkv-decoder-rk3568' "${dts_tmp}"; then
		display_alert "rockchip-multimedia" "dtb ${fdtfile}: rkvdec already on rockchip,rkv-decoder-rk3568" "info"
		rm -f "${dts_tmp}"
		return 0
	fi

	# compatible 字符串里的 \0 分隔符在 dts 里是字面 "\0"。
	# 只摘掉 v1 那一个 token, 前面 "compatible = \"" 必须留着。
	sed -i 's|rockchip,rkv-decoder-v1\\0||g' "${dts_tmp}"
	if ! grep -q 'compatible = "rockchip,rkv-decoder-rk3568' "${dts_tmp}"; then
		display_alert "rockchip-multimedia" "rkvdec compatible not rk3568-first after cleanup in ${fdtfile}; dtb not patched" "warn"
		rm -f "${dts_tmp}"
		return 0
	fi

	cp "${dtb}" "${dtb}.bak"
	if dtc -@ -I dts -O dtb -o "${dtb}.new" "${dts_tmp}" 2>/dev/null; then
		# 回读确认: 真正的判据是 rk3568 排第一, 而不是"跑通没报错"。
		if dtc -I dtb -O dts "${dtb}.new" 2>/dev/null \
			| grep -q 'compatible = "rockchip,rkv-decoder-rk3568'; then
			mv -f "${dtb}.new" "${dtb}"
			rm -f "${dts_tmp}"
			display_alert "rockchip-multimedia" "patched dtb: rkvdec now rk3568-first (v1 removed) in ${fdtfile}" "info"
			return 0
		fi
		display_alert "rockchip-multimedia" "patched dtb failed readback check; restored backup" "warn"
	fi
	rm -f "${dtb}.new" "${dts_tmp}"
	cp "${dtb}.bak" "${dtb}"
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
# And one thing has to be written into the rootfs rather than into a package:
#
#   3. gdm3 owns /etc/gdm3/daemon.conf, so the wayland-first version cannot ship
#      inside the armbian-<release>-desktop-gnome .deb.
#
# With all three fixed the greeter logs "Created gbm renderer for '/dev/dri/card0'"
# and comes up on Wayland ("Using Wayland display name 'wayland-0'").
function _rockchip_multimedia_setup_gpu_access() {
	display_alert "rockchip-multimedia" "granting video/render access to Mali gbm and /dev/dma_heap" "info"

	# Group membership has to be edited *inside* the image. A bare `usermod`
	# acts on the build host's accounts: Debian-gdm does not exist there, and
	# with `set -e` still in effect the first such name aborts the build.
	local _gdm_user=Debian-gdm
	local _users=()
	if grep -q "^${_gdm_user}:" "${SDCARD}/etc/passwd" 2>/dev/null; then
		_users+=("${_gdm_user}")
	fi
	# Any pre-existing interactive user, so a serial-console install can log in
	# and get a GPU session without a manual usermod.
	while read -r _u; do
		if [[ -n "${_u}" ]]; then
			_users+=("${_u}")
		fi
	done < <(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' "${SDCARD}/etc/passwd" 2>/dev/null)

	if grep -q '^video:' "${SDCARD}/etc/group" 2>/dev/null &&
		grep -q '^render:' "${SDCARD}/etc/group" 2>/dev/null; then
		for _u in "${_users[@]}"; do
			usermod --root "${SDCARD}" -aG video,render "${_u}" ||
				display_alert "rockchip-multimedia" "could not add ${_u} to video/render" "warn"
		done
	else
		display_alert "rockchip-multimedia" "no video/render group in image; skipping group grants" "warn"
	fi

	mkdir -p "${SDCARD}/etc/udev/rules.d"
	cat > "${SDCARD}/etc/udev/rules.d/60-dma-heap-access.rules" <<'RULEOF'
# libmali's armsoc gbm backend opens these heaps from gbm_create_device().
# The kernel creates them 0600 root:root, so without this rule no non-root
# graphics session (GDM greeter included) can build a gbm device.
SUBSYSTEM=="dma_heap", KERNEL=="system|system-uncached|reserved", MODE="0660", GROUP="video"
KERNEL=="dma_heap[0-9]*", MODE="0660", GROUP="video"
RULEOF

	# gdm3 owns /etc/gdm3/daemon.conf, so the gnome desktop package cannot
	# ship its own copy: dpkg aborts the unpack with "trying to overwrite
	# '/etc/gdm3/daemon.conf', which is also in package gdm3" and the image
	# build dies. Write it straight into the rootfs instead, which also means
	# the wayland greeter survives a later gdm3 upgrade as an unmodified
	# conffile conflict rather than a hard install failure.
	local _dconf_src="${SRC:-/armbian}/packages/blobs/desktop/gdm/daemon.conf"
	if [[ -f "${_dconf_src}" ]]; then
		mkdir -p "${SDCARD}/etc/gdm3"
		if cp "${_dconf_src}" "${SDCARD}/etc/gdm3/daemon.conf"; then
			display_alert "rockchip-multimedia" "installed wayland-first gdm3 daemon.conf" "info"
		else
			display_alert "rockchip-multimedia" "could not install ${_dconf_src}; greeter session type left at the gdm3 default" "warn"
		fi
	else
		display_alert "rockchip-multimedia" "gdm3 daemon.conf not found at ${_dconf_src}; greeter session type left at the gdm3 default" "warn"
	fi
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
	# libva 的驱动名是 .so 文件名里 _drv_video.so 之前的部分。装的是
	# rockchip_drv_video.so (sfqr0414/rockchip_vaapi_driver), 所以名字是 rockchip;
	# 之前写的 rkmpp 是 woodyst/rockchip-vaapi 那个的产物名, 换驱动后没跟着改,
	# 结果 libva 去找 rkmpp_drv_video.so 找不到 —— 板子上 Firefox 加载不了
	# VA 驱动就是这么来的。
	cat > "${SDCARD}/etc/profile.d/rockchip-vaapi.sh" << 'EOF'
export LIBVA_DRIVER_NAME=rockchip
export LIBVA_DRIVERS_PATH=/usr/lib/aarch64-linux-gnu/dri

# 默认是 stable-export (每帧 memcpy 进驱动自有的常驻 DRM 缓冲再导出), 因为
# 这块板的 Mali + Xorg 合成栈吃不下 dmabuf。零拷贝开关是它反过来:
#   export ROCKCHIP_VAAPI_DISABLE_STABLE_EXPORT=1
# 真零拷贝时驱动会 mpp_buffer_inc_ref + dup 帧的 fd, 省掉那次 memcpy, 但导出
# 出去的是 MPP 的帧缓冲, 显示端必须能直接引用它。
#
# 另外两个调试开关: ROCKCHIP_VAAPI_STRICT_ERRINFO=1 恢复"信 errinfo"(默认不信,
# 因为 RK3568 上 MPP 在成功解出的帧上也残留 errinfo); ROCKCHIP_VAAPI_AV1_EXPORT_P010=1
# 是 AV1 10bit 导出用的, 这块板用不上。
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
	# The VA-API driver now belongs here too: its build is a hard failure
	# (exit_with_error) rather than a warning, so by the time we get to the
	# pre-umount verify it has either been installed or the build already died.
	for f in \
		"${lib_dir}/librockchip_mpp.so" \
		"${lib_dir}/librga.so" \
		"${lib_dir}/librknnrt.so" \
		"${lib_dir}/dri/rockchip_drv_video.so"; do
		if [[ ! -e "${SDCARD}/${f}" ]]; then
			exit_with_error "rockchip-multimedia: expected file missing from rootfs: /${f}"
		fi
	done

	# 可执行位和 profile.d 脚本同样要真的在, 不能靠 "optional"。
	if [[ ! -x "${SDCARD}/${lib_dir}/dri/rockchip_drv_video.so" ]]; then
		exit_with_error "rockchip-multimedia: /${lib_dir}/dri/rockchip_drv_video.so is not executable"
	fi
	# profile.d 里写的驱动名必须和实际装进来的 .so 对得上, 否则 libva 按名字
	# 去找 ${LIBVA_DRIVER_NAME}_drv_video.so 会找不到。
	if ! grep -q "^export LIBVA_DRIVER_NAME=rockchip$" "${SDCARD}/etc/profile.d/rockchip-vaapi.sh" 2>/dev/null; then
		exit_with_error "rockchip-multimedia: /etc/profile.d/rockchip-vaapi.sh does not set LIBVA_DRIVER_NAME=rockchip"
	fi

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

	# usermod needs to chroot into the image, which fails silently if the build
	# ever runs unprivileged, so check the group membership actually landed.
	if grep -q '^Debian-gdm:' "${SDCARD}/etc/passwd" 2>/dev/null; then
		if ! awk -F: '$1 == "video" {print $4}' "${SDCARD}/etc/group" |
			tr ',' '\n' | grep -qx 'Debian-gdm'; then
			exit_with_error "rockchip-multimedia: Debian-gdm is not in the video group; the greeter cannot open /dev/dri/card0"
		fi
	fi

	# Only a warning: without gdm3 there is no greeter to configure, and the
	# stock daemon.conf is a sane fallback for a desktop-less image.
	if [[ -f "${SDCARD}/etc/gdm3/daemon.conf" ]] &&
		! grep -q '^WaylandEnable=true' "${SDCARD}/etc/gdm3/daemon.conf"; then
		display_alert "rockchip-multimedia" "gdm3 daemon.conf does not enable Wayland; the blob has no GLX, so the greeter will use llvmpipe" "warn"
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