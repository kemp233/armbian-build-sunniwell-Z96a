#!/usr/bin/env bash
#
# custom/extensions/rockchip-multimedia.sh
#
# Rockchip RK3568 multimedia userspace for the z96a image. The kernel side is
# already complete (linux-rockchip-rk3568-z96a-legacy config has these =y):
#
#   component    userspace                  device node       kernel driver
#   -----------  -------------------------  ----------------  --------------------------
#   MPP (VPU)    librockchip-mpp.so.1       /dev/mpp_service  CONFIG_ROCKCHIP_MPP_*
#   RGA          librga.so (im2d API)       /dev/rga          CONFIG_VIDEO_ROCKCHIP_RGA
#   RKNN (NPU)   librknnrt.so               /dev/dri/renderD* CONFIG_ROCKCHIP_RKNPU (DRM)
#   GLES         Mesa Panfrost (distro)     /dev/dri/*        CONFIG_DRM_PANFROST
#   VA-API       rockchip_drv_video.so      (wraps MPP)       via libva2 -> MPP
#
# The VA-API driver gives Firefox-esr/mpv hardware video decode: libva dlopens
# rockchip_drv_video.so which links librockchip_mpp.so.1 and exports
# __vaDriverInit_1_17 (matches bookworm's libva 2.17, whose libva.pc reports
# VA-API Version: 1.17.0). Firefox prefs + LIBVA_DRIVER_NAME=rockchip are
# preseeded in the image.
#
# Vulkan is intentionally NOT provided: the G52 (Bifrost) is driven by Mesa
# Panfrost, and bookworm's Mesa (22.3) has no panvk Vulkan support for v9.
# panvk needs Mesa >= 24.2 (trixie/sid userspace). The old plan of injecting
# the proprietary libmali blob is dead: it needs CONFIG_MALI_BIFROST, which
# conflicts with Panfrost, and the blob in custom/blobs has no Vulkan symbols.
#
# Everything lands in the multiarch lib dir with headers + pkg-config files so
# applications can compile against MPP/RGA/RKNN on-device.
#
# Enable: ENABLE_EXTENSIONS="rockchip-multimedia" (set by custom/config/boards/z96a-v2.conf)

# Pinned upstream refs, fetched by full SHA so builds are reproducible:
#   rockchip-linux/mpp        develop 0986d01294d5c2449c14cf13af9b740368c33967 (2026-08-26)
#   airockchip/librga         main    2b32edcb97b601b25683e2941d888c8515da6d55 (2026-06-10, 1.10.6_[3])
#   airockchip/rknn-toolkit2  tag v2.3.2
#   intel/libva               tag 2.17.0 b431a1a94f5e1f060f2ea2cf3169024830b7d0b1 (headers only)
#   tarcila/libva-rkmpp       master  e69ea1368893cc15c8d59618397ab8d78df648b9 (2024-10-16)
declare -g EXT_RKMPP_GIT="https://github.com/rockchip-linux/mpp.git"
declare -g EXT_RKMPP_REF="0986d01294d5c2449c14cf13af9b740368c33967"
declare -g EXT_LIBRGA_GIT="https://github.com/airockchip/librga.git"
declare -g EXT_LIBRGA_REF="2b32edcb97b601b25683e2941d888c8515da6d55"
declare -g EXT_RKNN_VERSION="2.3.2"
declare -g EXT_RKNN_BASE="https://raw.githubusercontent.com/airockchip/rknn-toolkit2/v${EXT_RKNN_VERSION}/rknpu2/runtime/Linux/librknn_api"
declare -g EXT_LIBVA_GIT="https://github.com/intel/libva.git"
declare -g EXT_LIBVA_REF="2.17.0"
declare -g EXT_VADRV_GIT="https://github.com/tarcila/libva-rkmpp.git"
declare -g EXT_VADRV_REF="e69ea1368893cc15c8d59618397ab8d78df648b9"

# Fetch `repo_url` at pinned `sha` into `dest_dir` (idempotent).
function _rockchip_multimedia_fetch_pinned() {
	local repo_url="${1}" sha="${2}" dest_dir="${3}"
	if [[ ! -d "${dest_dir}/.git" ]]; then
		run_host_command_logged git init "${dest_dir}"
		run_host_command_logged git -C "${dest_dir}" remote add origin "${repo_url}"
	fi
	# GitHub enables allow-reachable-SHA-in-want, so depth-1 fetch by sha works.
	run_host_command_logged git -C "${dest_dir}" fetch --depth 1 origin "${sha}"
	run_host_command_logged git -C "${dest_dir}" checkout --detach FETCH_HEAD
	return 0
}

# Build host: cross toolchain + build systems for MPP and the VA-API driver.
# libdrm-dev is needed by the libmali GBM blob's meson dependency check.
# meson is needed to build the libmali wrapper libraries.
function add_host_dependencies__rockchip_multimedia_host_deps() {
	declare -g EXTRA_BUILD_DEPS="${EXTRA_BUILD_DEPS} gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cmake ninja-build meson autoconf automake libtool pkg-config libdrm-dev"
}

function post_family_config__rockchip_multimedia_gles_packages() {
	[[ "${BOARDFAMILY:-}" != "rockchip-rk3568-z96a" ]] && return 0
	display_alert "rockchip-multimedia" "adding GLES userspace packages" "info"
	# libmali blob provides EGL/GLES3.2; keep libgl1-mesa-dri for the GLX/swrast
	# fallback and libva2/libva-drm2 + vainfo for the VA-API->MPP decode path.
	# Mesa's libEGL/libGLESv2 are replaced by the blob at install time below.
	add_packages_to_image libegl1 libgles2 libgl1-mesa-dri libva2 libva-drm2 vainfo
	if [[ "${BUILD_MINIMAL:-}" != "yes" ]]; then
		add_packages_to_image glmark2-es2 # on-device GLES sanity check
	fi
	return 0
}

# Mali-G52 (Bifrost, CSF) proprietary userspace from tsukumijima/libmali-rockchip.
# Kernel side is CONFIG_MALI_BIFROST + CONFIG_MALI_CSF_SUPPORT (r18p0 kbase),
# so the matching userspace DDK is g24p0. The blob ships EGL/GLES3.2/OpenCL;
# it has no Vulkan, which is why Mesa panvk is not a replacement here.
declare -g EXT_LIBMALI_GIT="https://github.com/tsukumijima/libmali-rockchip.git"
declare -g EXT_LIBMALI_REF="bd33ee262f47fd936b831afccaa0759b3ecc2482" # v1.9-1-20260312
declare -g EXT_LIBMALI_GPU="bifrost-g52"
declare -g EXT_LIBMALI_VERSION="g24p0"
# 'gbm' blob links only libdrm; the x11-wayland-gbm variant additionally needs
# wayland/X11 dev packages present at build time on the host. GBM EGL is enough
# for both Xorg (via modesetting) and Wayland compositors on this stack.
declare -g EXT_LIBMALI_PLATFORM="${EXT_LIBMALI_PLATFORM:-gbm}"

# Cross-compile libmali's wrapper libraries (libEGL/libGLESv2/...) against the
# prebuilt blob. Meson runs on the host; only the wrapper .so files are built,
# the 56MB blob itself is copied as-is.
function _rockchip_multimedia_build_libmali() {
	local work_dir="${1}" stage="${2}" prefix="${3}"
	local lib_dir="usr/lib/aarch64-linux-gnu"
	local src="${work_dir}/src/libmali"
	local build="${work_dir}/build/libmali"

	_rockchip_multimedia_fetch_pinned "${EXT_LIBMALI_GIT}" "${EXT_LIBMALI_REF}" "${src}"

	# The wrapper .so files are arch-independent trampolines that dlopen
	# libmali, so they are built with the host compiler. meson picks the blob
	# via scripts/grabber.sh from (gpu, version, platform, optimize-level).
	run_host_command_logged meson setup "${build}" "${src}" \
		"-Darch=aarch64" \
		"-Dgpu=${EXT_LIBMALI_GPU}" \
		"-Dversion=${EXT_LIBMALI_VERSION}" \
		"-Dplatform=${EXT_LIBMALI_PLATFORM}" \
		"-Dopencl-icd=false" \
		"-Dhooks=true" \
		"-Dwrappers=auto" \
		"-Doptimize-level=O3" \
		"--default-library=shared" \
		"--prefix=/usr" \
		"--libdir=${lib_dir#usr/}" \
		"--buildtype=release"
	run_host_command_logged ninja -C "${build}"
	run_host_command_logged env DESTDIR="${stage}" ninja -C "${build}" install

	# udev node for the kbase driver (mali0) + render node permissions.
	mkdir -p "${stage}/etc/udev/rules.d"
	cat > "${stage}/etc/udev/rules.d/50-mali.rules" <<- 'EOT'
		KERNEL=="mali0", MODE="0660", GROUP="video"
		KERNEL=="mali", MODE="0660", GROUP="video"
	EOT
}

# Resolve the aarch64 cross-compiler prefix. Prefer the framework's own
# toolchain (CROSS_COMPILE, possibly "ccache /path/prefix-"); fall back to the
# apt-installed debian cross gcc, which add_host_dependencies guarantees.
function _rockchip_multimedia_cross_prefix() {
	local prefix="${CROSS_COMPILE:-aarch64-linux-gnu-}"
	prefix="${prefix##* }" # drop "ccache " style prefixes
	if [[ -z "${prefix}" ]] || ! type -p "${prefix}gcc" > /dev/null 2>&1; then
		prefix="aarch64-linux-gnu-"
	fi
	echo "${prefix}"
	return 0
}

function pre_customize_image__rockchip_multimedia_install() {
	[[ "${BOARDFAMILY:-}" != "rockchip-rk3568-z96a" ]] && return 0

	local lib_dir="usr/lib/aarch64-linux-gnu"
	local work_dir="${SRC}/output/rockchip-multimedia"
	local src_dir="${work_dir}/src"
	local stage="${work_dir}/stage"
	local prefix cross

	prefix="$( _rockchip_multimedia_cross_prefix )"
	cross="aarch64-linux-gnu" # multiarch triplet for the target libs

	display_alert "rockchip-multimedia" "installing MPP/RGA/RKNN userspace (cross prefix: ${prefix})" "info"
	mkdir -p "${stage}/${lib_dir}" "${stage}/usr/include" "${src_dir}"

	# ------------------------------------------------------------------ MPP --
	# NOTE: upstream develop names the library with an underscore:
	#       librockchip_mpp.so.1 (Debian's packages use a hyphen; this is not Debian).
	if [[ ! -e "${stage}/${lib_dir}/librockchip_mpp.so.1" ]]; then
		_rockchip_multimedia_fetch_pinned "${EXT_RKMPP_GIT}" "${EXT_RKMPP_REF}" "${src_dir}/mpp"
		# Cross toolchain file for cmake; MPP has no external deps beyond libc.
		cat > "${src_dir}/aarch64-cross.cmake" <<- EOT
			set(CMAKE_SYSTEM_NAME Linux)
			set(CMAKE_SYSTEM_PROCESSOR aarch64)
			set(CMAKE_C_COMPILER "${prefix}gcc")
			set(CMAKE_CXX_COMPILER "${prefix}g++")
			set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
			set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
			set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
			set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
		EOT
		run_host_command_logged cmake -S "${src_dir}/mpp" -B "${src_dir}/mpp/build" -G Ninja \
			"-DCMAKE_TOOLCHAIN_FILE=${src_dir}/aarch64-cross.cmake" \
			"-DCMAKE_BUILD_TYPE=Release" \
			"-DCMAKE_INSTALL_PREFIX=/usr" \
			"-DCMAKE_INSTALL_LIBDIR=${lib_dir#usr/}" \
			"-DCMAKE_INSTALL_INCLUDEDIR=include" \
			"-DBUILD_SHARED_LIBS=ON" \
			"-DBUILD_TEST=ON"
		run_host_command_logged cmake --build "${src_dir}/mpp/build" -j "$(nproc)"
		run_host_command_logged env DESTDIR="${stage}" cmake --install "${src_dir}/mpp/build"
	else
		display_alert "rockchip-multimedia" "MPP already staged, reusing" "debug"
	fi

	# ---------------------------------------------------------------- librga --
	# The librga core is only buildable via AOSP (Android.bp); upstream ships
	# prebuilt aarch64 libs + im2d headers in-repo, which is what we stage.
	if [[ ! -e "${stage}/${lib_dir}/librga.so" ]]; then
		_rockchip_multimedia_fetch_pinned "${EXT_LIBRGA_GIT}" "${EXT_LIBRGA_REF}" "${src_dir}/librga"
		run_host_command_logged cp -av "${src_dir}/librga/libs/Linux/gcc-aarch64/librga.so" "${stage}/${lib_dir}/"
		run_host_command_logged mkdir -pv "${stage}/usr/include/rga"
		run_host_command_logged cp -av "${src_dir}/librga/include/"*.h "${src_dir}/librga/include/im2d.hpp" "${stage}/usr/include/rga/"
		cat > "${stage}/${lib_dir}/pkgconfig/librga.pc" <<- EOT
			prefix=/usr
			libdir=\${prefix}/lib/${cross}
			includedir=\${prefix}/include

			Name: librga
			Description: Rockchip RGA userspace library (im2d API)
			Version: 1.10.6
			Libs: -L\${libdir} -lrga
			Cflags: -I\${includedir}/rga
		EOT
	else
		display_alert "rockchip-multimedia" "librga already staged, reusing" "debug"
	fi

	# ------------------------------------------------------------------ RKNN --
	if [[ ! -e "${stage}/${lib_dir}/librknnrt.so" ]]; then
		run_host_command_logged mkdir -pv "${stage}/usr/include/rknn"
		run_host_command_logged curl -fL --retry 3 -o "${stage}/${lib_dir}/librknnrt.so" \
			"${EXT_RKNN_BASE}/aarch64/librknnrt.so"
		for rknn_header in rknn_api.h rknn_matmul_api.h rknn_custom_op.h; do
			run_host_command_logged curl -fL --retry 3 -o "${stage}/usr/include/rknn/${rknn_header}" \
				"${EXT_RKNN_BASE}/include/${rknn_header}"
		done
		cat > "${stage}/${lib_dir}/pkgconfig/librknnrt.pc" <<- EOT
			prefix=/usr
			libdir=\${prefix}/lib/${cross}
			includedir=\${prefix}/include

			Name: librknnrt
			Description: Rockchip RKNN runtime (NPU C API)
			Version: ${EXT_RKNN_VERSION}
			Libs: -L\${libdir} -lrknnrt
			Cflags: -I\${includedir}/rknn
		EOT
	else
		display_alert "rockchip-multimedia" "RKNN already staged, reusing" "debug"
	fi

	# ---------------------------------------------------------------- VA-API --
	# rockchip_drv_video.so: VA-API backend wrapping MPP, so Firefox/mpv get
	# hardware video decode. Cross-built with libva 2.17 headers (headers-only,
	# vendored from the tag) because the builder container's distro libva would
	# emit the wrong init-symbol version. Verified in a bookworm container: the
	# result links only librockchip_mpp.so.1 + libc and exports
	# __vaDriverInit_1_17, matching bookworm's libva2 2.17 runtime.
	if [[ ! -e "${stage}/${lib_dir}/dri/rockchip_drv_video.so" ]]; then
		local va_sysroot="${work_dir}/libva-sysroot"
		rm -rf "${va_sysroot}"
		mkdir -p "${va_sysroot}/usr/include" "${va_sysroot}/usr/lib/aarch64-linux-gnu/pkgconfig"
		_rockchip_multimedia_fetch_pinned "${EXT_LIBVA_GIT}" "${EXT_LIBVA_REF}" "${src_dir}/libva"
		# Headers live at the repo root in libva/<va> (not include/va).
		run_host_command_logged cp -a "${src_dir}/libva/va" "${va_sysroot}/usr/include/"
		# The git tag ships only the va_version.h.in template; distro libva-dev
		# packages ship it pre-generated. Generate it for VA-API 1.17.0 (= libva
		# 2.17.0), matching the .pc Version below - rockchip_drv_video.c includes
		# <va/va_version.h> (via va.h) and the build fails without it.
		sed -e 's/@VA_API_MAJOR_VERSION@/1/' \
			-e 's/@VA_API_MINOR_VERSION@/17/' \
			-e 's/@VA_API_MICRO_VERSION@/0/' \
			-e 's/@VA_API_VERSION@/1.17.0/' \
			"${src_dir}/libva/va/va_version.h.in" > "${va_sysroot}/usr/include/va/va_version.h"
		# Replicate bookworm's libva.pc: Version is the VA-API version (1.17.0),
		# NOT the libva release version (2.17.0) - configure derives the
		# __vaDriverInit_<maj>_<min> symbol from this field.
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

		_rockchip_multimedia_fetch_pinned "${EXT_VADRV_GIT}" "${EXT_VADRV_REF}" "${src_dir}/libva-rkmpp"
		# autogen.sh runs `autoreconf -v --install` then `./configure "$@"`,
		# so flags must be passed positionally. Both of those are relative to
		# the source dir (autoreconf looks for configure.ac in $PWD, configure
		# is generated and run in-place), so cd into the source tree first -
		# calling autogen.sh by absolute path from the framework root CWD fails
		# with "autoreconf: error: 'configure.ac' is required" and Error 127.
		# Pass pkg-config + sysroot include (matches the libc/libdrm + VA
		# headers we vendored) and a sysroot library lookup so the driver
		# links librockchip_mpp.so.1 from the stage dir (already cross-built
		# above).
		# LIBS must NOT be forced here: configure's "compiler creates
		# executables" sanity check links a test binary and would try to link
		# -lrockchip_mpp against a lib dir that is still empty at that point,
		# failing with "C compiler cannot create executables" (Error 77, run
		# 34563571369). libtool picks -lrockchip_mpp up from the driver's own
		# Makefile.am at make time, with LDFLAGS pointing at the stage dir.
		run_host_command_logged cd "${src_dir}/libva-rkmpp" "&&" \
			env -u PKG_CONFIG_PATH PKG_CONFIG_PATH="${va_sysroot}/usr/lib/aarch64-linux-gnu/pkgconfig" \
			./autogen.sh \
				--host=aarch64-linux-gnu \
				--prefix=/usr \
				--with-drivers-path="/usr/${lib_dir#usr/}/dri" \
				CPPFLAGS="-I${va_sysroot}/usr/include" \
				LDFLAGS="-L${stage}/${lib_dir}" \
				ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes
		run_host_command_logged make -C "${src_dir}/libva-rkmpp" -j "$(nproc)"
		run_host_command_logged mkdir -pv "${stage}/${lib_dir}/dri"
		run_host_command_logged cp -av "${src_dir}/libva-rkmpp/src/.libs/rockchip_drv_video.so" "${stage}/${lib_dir}/dri/"
	else
		display_alert "rockchip-multimedia" "VA-API driver already staged, reusing" "debug"
	fi

	# --------------------------------------------- udev rules + copy to rootfs --
	cat > "${SDCARD}/etc/udev/rules.d/60-rockchip-multimedia.rules" <<- 'EOF'
		# Rockchip multimedia accelerators: allow the 'video' group.
		# /dev/mpp_service - VPU via MPP   /dev/rga - 2D blitter   /dev/rknpu - NPU
		KERNEL=="mpp_service", MODE="0660", GROUP="video"
		KERNEL=="rga",         MODE="0660", GROUP="video"
		KERNEL=="rknpu",       MODE="0660", GROUP="video"
	EOF

	# Point libva at the rockchip backend + relax the RDD sandbox that blocks
	# VAAPI in Firefox on this stack. /etc/environment covers display-manager
	# sessions; /etc/profile.d covers shell logins.
	cat > "${SDCARD}/etc/profile.d/rockchip-vaapi.sh" <<- 'EOF'
		export LIBVA_DRIVER_NAME=rockchip
		export MOZ_DISABLE_RDD_SANDBOX=1
	EOF
	chmod 0755 "${SDCARD}/etc/profile.d/rockchip-vaapi.sh"
	if ! grep -q "^LIBVA_DRIVER_NAME=" "${SDCARD}/etc/environment" 2>/dev/null; then
		echo 'LIBVA_DRIVER_NAME=rockchip' >> "${SDCARD}/etc/environment"
		echo 'MOZ_DISABLE_RDD_SANDBOX=1' >> "${SDCARD}/etc/environment"
	fi

	# Firefox-esr prefs (only when firefox-esr is present in this image).
	local ff_pref_dir="${SDCARD}/usr/lib/firefox-esr/defaults/pref"
	if [[ -d "${SDCARD}/usr/lib/firefox-esr" ]]; then
		mkdir -p "${ff_pref_dir}"
		cat > "${ff_pref_dir}/rockchip-vaapi.js" <<- 'EOF'
			// Hardware video decode via VA-API -> rockchip(MPP). Set by the
			// rockchip-multimedia build extension.
			pref("media.ffmpeg.vaapi.enabled", true);
			pref("media.hardware-video-decoding.force-enabled", true);
			pref("media.rdd-ffmpeg.enabled", true);
			pref("media.av1.enabled", false); // RK3568 has no AV1 decoder; avoid sw-AV1 on youtube
		EOF
	else
		display_alert "rockchip-multimedia" "firefox-esr not in image, skipping browser prefs" "info"
	fi

	# ------------------------------------------------------------- libmali --
	# Mali-G52 proprietary userspace (EGL/GLES3.2/OpenCL). The blob is built
	# against CONFIG_MALI_BIFROST+CSF, so its libEGL/libGLESv2 must win over
	# Mesa's; dpkg alternatives are not used because Debian's mesa packages
	# do not register GL alternatives, so the files are overwritten directly.
	display_alert "rockchip-multimedia" "building libmali (G52 g24p0 ${EXT_LIBMALI_PLATFORM})" "info"
	if [[ ! -e "${stage}/${lib_dir}/libmali.so.1.9.0" ]]; then
		_rockchip_multimedia_build_libmali "${work_dir}" "${stage}" "${prefix}"
	else
		display_alert "rockchip-multimedia" "libmali already staged, reusing" "debug"
	fi

	display_alert "rockchip-multimedia" "copying staged userspace into rootfs" "info"
	run_host_command_logged cp -av "${stage}/." "${SDCARD}/"

	# libmali's wrappers replace Mesa's GL stack. Mesa's libGL (GLX on X) stays,
	# but libEGL/libGLESv2 must point at the blob for hardware acceleration.
	# Move Mesa's copies aside (not remove: GLX still needs libgl1-mesa-dri).
	for _gl in libEGL.so.1 libGLESv2.so.2 libOpenCL.so.1; do
		if [[ -e "${SDCARD}/${lib_dir}/mesa/${_gl}" || -L "${SDCARD}/${lib_dir}/${_gl}" ]]; then
			run_host_command_logged mv -v "${SDCARD}/${lib_dir}/${_gl}" "${SDCARD}/${lib_dir}/${_gl}.mesa"
		fi
	done

	chroot_sdcard ldconfig

	return 0
}

# Fail the build loudly if anything is missing - replaces the old "set +e and
# hope" GH-action approach that silently produced broken images.
function pre_umount_final_image__rockchip_multimedia_verify() {
	[[ "${BOARDFAMILY:-}" != "rockchip-rk3568-z96a" ]] && return 0

	local lib_dir="usr/lib/aarch64-linux-gnu"
	local f
	for f in \
		"${lib_dir}/librockchip_mpp.so.1" \
		"${lib_dir}/librga.so" \
		"${lib_dir}/librknnrt.so" \
		"${lib_dir}/pkgconfig/rockchip_mpp.pc" \
		"${lib_dir}/pkgconfig/librga.pc" \
		"${lib_dir}/pkgconfig/librknnrt.pc" \
		"usr/include/rockchip/rk_mpi.h" \
		"usr/include/rga/im2d.h" \
		"usr/include/rknn/rknn_api.h" \
		"${lib_dir}/dri/rockchip_drv_video.so" \
		"${lib_dir}/libmali.so.1.9.0" \
		"etc/udev/rules.d/60-rockchip-multimedia.rules" \
		"etc/udev/rules.d/50-mali.rules" \
		"etc/profile.d/rockchip-vaapi.sh"; do
		if [[ ! -e "${SDCARD}/${f}" ]]; then
			exit_with_error "rockchip-multimedia: expected file missing from rootfs: /${f}"
		fi
	done

	# libEGL/libGLESv2 must resolve to the blob, not Mesa, or GL is software.
	for _gl in libEGL.so.1 libGLESv2.so.2; do
		if [[ ! -L "${SDCARD}/${lib_dir}/${_gl}" ]]; then
			exit_with_error "rockchip-multimedia: /${lib_dir}/${_gl} is not a symlink to libmali"
		fi
		local _target
		_target="$(readlink -f "${SDCARD}/${lib_dir}/${_gl}")"
		if [[ "${_target}" != *libmali* ]]; then
			exit_with_error "rockchip-multimedia: ${_gl} -> ${_target} (expected libmali blob)"
		fi
	done

	display_alert "rockchip-multimedia" "verified: MPP + librga + RKNN runtime + libmali G52 GLES + VA-API backend installed" "info"
	display_alert "rockchip-multimedia" "on-device checks: vainfo, mpi_dec_test, glmark2-es2; firefox about:support should show HW decode" "info"
	return 0
}
