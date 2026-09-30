#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Z96A mpv/FFmpeg 工具链: 把 build-with-mali.yml step 21/22 在原生 arm64
# runner 上编好的产物铺进镜像根。
#
# 关键背景: step 21/22 把 mpv/ffmpeg/ffprobe/yt-dlp、libav*/libsw*、
# libplacebo、libshaderc、mpv-handler、gstreamer rockchipmpp 插件全部写进
# ${SRC}/extensions/z96a-mpv/overlay/, 树形和镜像里 / 一模一样。但**写入
# 不等于装入** —— run 36672678535 的镜像 (bookworm-170) 刷机后
# /usr/local/bin 里一个工具都没有: 没有任何扩展负责把这个 overlay 铺进
# SDCARD, 它只是 CI 工作区里的一个目录。这就是本扩展存在的理由。
#
# gstreamer 插件的特殊处理: meson 默认 prefix=/usr/local, 插件落在
# /usr/local/lib/aarch64-linux-gnu/gstreamer-1.0/, 而 gstreamer 的插件扫描
# 路径是编译时定的 /usr/lib/aarch64-linux-gnu/gstreamer-1.0/ —— 拷进去也
# 扫不到。所以这里显式把它链接进扫描路径。
#
# 验收原则和 z96a-desktop-fix.sh 一致: overlay 里的东西少一个, 现象就是
# "修了一半" (GPU/VPU 内核侧全绿但 mpv/ffmpeg 消失), 比构建失败更难查。
# 所以每个关键文件当场断言, 缺一个就大声死。


# mpv/ffmpeg 的**运行时**动态库: 这些 -dev 在构建时进的是 bookworm 容器,
# 镜像里需要对应的运行时包, 否则 mpv 一跑就 "libass.so.9: cannot open"。
# bookworm 包名 (noble 有 t64 后缀变体, 换发行版时逐个对着查)。
function post_family_config__z96a_mpv_runtime_libs() {
	add_packages_to_image libass9 libmpg123-0 libopusfile0 libflac8 \
		libspeex1 libvulkan1 libfribidi0 libfreetype6 libharfbuzz0b
}

function pre_customize_image__z96a_mpv_toolchain() {
	display_alert "Z96A mpv toolchain" "staging mpv/ffmpeg/libplacebo/gstreamer-mpp overlay" "info"

	local src="${EXTENSION_DIR}/overlay"
	if [[ ! -d "${src}" ]]; then
		exit_with_error "Z96A mpv toolchain: ${src} does not exist -- step 21/22 did not run or their outputs were lost"
	fi

	run_host_command_logged cp -a "${src}/." "${SDCARD}/"

	# GitHub artifact 不保留权限位; CI 里 cp -a 能保住, 但不能赌 (desktop-fix
	# 在同一类事上栽过)。二进制可执行位显式补一遍。
	local f
	for f in \
		"usr/local/bin/mpv" \
		"usr/local/bin/ffmpeg" \
		"usr/local/bin/ffprobe" \
		"usr/local/bin/yt-dlp" \
		"root/.local/bin/mpv-handler"; do
		[[ -e "${SDCARD}/${f}" ]] || exit_with_error "Z96A mpv toolchain: overlay 里缺 ${f}"
		run_host_command_logged chmod 755 "${SDCARD}/${f}"
	done

	# 当场验收: 库、配置、插件一个都不能少。
	for f in \
		"usr/local/lib/aarch64-linux-gnu/libplacebo.so" \
		"usr/local/lib/libshaderc.so.1" \
		"root/.config/mpv/mpv.conf" \
		"root/.config/mpv-handler/config.toml" \
		"etc/ld.so.conf.d/zz-armbian-local.conf" \
		"etc/udev/rules.d/50-z96a-multimedia.rules" \
		"root/.local/share/applications/mpv-handler.desktop"; do
		[[ -e "${SDCARD}/${f}" ]] || exit_with_error "Z96A mpv toolchain: overlay 里缺 ${f}"
	done
	if ! compgen -G "${SDCARD}/usr/local/lib/libavcodec.so*" >/dev/null; then
		exit_with_error "Z96A mpv toolchain: overlay 里没有 libavcodec"
	fi

	# gstreamer 插件进扫描路径 (见文件头说明)。用符号链接而不是拷贝:
	# 插件自己还依赖同目录的 deps (如果有), 链接保持相对关系。
	local gst_plugin_dir="${SDCARD}/usr/local/lib/aarch64-linux-gnu/gstreamer-1.0"
	if [[ -d "${gst_plugin_dir}" ]]; then
		mkdir -p "${SDCARD}/usr/lib/aarch64-linux-gnu/gstreamer-1.0"
		for plugin in "${gst_plugin_dir}"/*.so; do
			run_host_command_logged ln -sf "/usr/local/lib/aarch64-linux-gnu/gstreamer-1.0/$(basename "${plugin}")" \
				"${SDCARD}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/$(basename "${plugin}")"
		done
	else
		exit_with_error "Z96A mpv toolchain: gstreamer rockchipmpp 插件不在 overlay 里"
	fi

	# ld.so.conf.d/zz-armbian-local.conf 已随 overlay 落地; 现场刷一次缓存,
	# 免得首次开机 mpv 因为 cache 还是旧的而加载不到 libav*。
	chroot_sdcard ldconfig

	display_alert "Z96A mpv toolchain" "mpv/ffmpeg/libplacebo/gstreamer-mpp staged into image" "info"
	return 0
}
