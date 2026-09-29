#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Z96A 桌面修复: 让 gdm3 当显示管理器, 并让 root 会话下的 pipewire 真的起来。
#
# 这不是"锦上添花"的一组配置, 是三处踩过的坑的修复, 缺一处现象就回来:
#
#   1. 偏色 + 桌面卡顿。板子上 lightdm 装着并且实际在跑, 抢在 gdm3 前面接管了
#      会话。lightdm 走 X11, 而这块板子的 Mali 用户态是 gbm-wayland 变体,
#      **不带 GLX** —— 于是 X11 下所有 OpenGL 回落到 Mesa llvmpipe 软解,
#      gnome-shell 空载就烧 47% CPU, 偏色也是同源。gdm3 的 daemon.conf 早就配好
#      了 Wayland, 只是一直没被启动 (历史上装过依赖 lightdm 的 xfce 桌面包)。
#      切到 gdm3 之后实测: libmali 映射 185 个, llvmpipe / swrast 各 0 个,
#      负载从 7.21 掉到 1.5, 偏色消失。
#
#   2. root 登不进去。/etc/pam.d/gdm-password 里有
#          auth required pam_succeed_if.so user != root quiet_success
#      自动登录同样要走这条认证链, 所以 AutomaticLogin=root 是**静默失败** ——
#      日志里只剩一行 gdm-session-worker [pam/gdm-password]。
#
#   3. 桌面上一点声音都没有。Debian 的 pipewire 单元带 ConditionUser=!root,
#      而本板图形会话以 root 身份运行, systemd 从开机到桌面一次都没放行过,
#      日志里只有 "skipped because of an unmet condition check"。加上包列表里
#      装的是 pulseaudio 而非 pipewire-audio (前者不提供 /usr/bin/pipewire-pulse),
#      两个独立原因叠在一起。
#
# 做法: 把 overlay/ 下的文件树整个拷进镜像根, 然后当场验收。数据放在 extension
# 自己的目录里 (${EXTENSION_DIR}), 和框架自带的 extensions/cloud-init 一个路子。

function pre_customize_image__z96a_desktop_fix() {
	display_alert "Z96A desktop fix" "gdm3 autologin + pipewire under a root session" "info"

	local src="${EXTENSION_DIR}/overlay"
	if [[ ! -d "${src}" ]]; then
		display_alert "Z96A desktop fix" "overlay/ is missing next to the extension -- the fix would silently not ship" "err"
		exit 1
	fi

	run_host_command_logged cp -a "${src}/." "${SDCARD}/"

	# GitHub artifact 不保留 Unix 权限位 (build-with-mali.yml 里那段 chmod 恢复
	# 循环只覆盖 z96a-repo 里的路径, 管不到复制进 extensions/ 之后的副本)。
	# 所以这里显式补一次, 而不是指望 cp -a 把 755 带过来。
	run_host_command_logged chmod 755 "${SDCARD}/usr/lib/armbian/z96a-desktop-setup"

	# 当场验收。overlay 里的东西少一个, 现象就是"修了一半", 比构建失败更难查。
	local f
	for f in \
		"etc/lib/systemd/user/pipewire.socket.d/z96a-root-session.conf" \
		"etc/lib/systemd/user/pipewire.service.d/z96a-root-session.conf" \
		"etc/lib/systemd/user/pipewire-pulse.socket.d/z96a-root-session.conf" \
		"etc/lib/systemd/user/pipewire-pulse.service.d/z96a-root-session.conf" \
		"etc/lib/systemd/user/pipewire-media-session.service.d/z96a-root-session.conf" \
		"usr/lib/systemd/system/z96a-desktop-setup.service" \
		"usr/lib/armbian/z96a-desktop-setup" \
		"var/lib/AccountsService/users/root"; do
		if [[ ! -e "${SDCARD}/${f}" ]]; then
			display_alert "Z96A desktop fix" "not staged into the image: ${f}" "err"
			exit 1
		fi
	done

	if [[ ! -x "${SDCARD}/usr/lib/armbian/z96a-desktop-setup" ]]; then
		display_alert "Z96A desktop fix" "z96a-desktop-setup landed without its exec bit" "err"
		exit 1
	fi

	display_alert "Z96A desktop fix" "staged 8 files (gdm3 autologin + 5 pipewire drop-ins)" "info"
	return 0
}
