#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Z96A Mali GL fix: libmali blob 的 EGL 缺陷补齐 + Firefox 硬件渲染启动器
# + rk809 喇叭增益修复。2026-11-28 排查定案, 三个问题三处修, 缺一处现象就回来:
#
#   1. Firefox 完全无 GPU 渲染。Firefox 的 glxtest 硬性要求
#      eglQueryDeviceStringEXT / eglQueryDisplayAttribEXT / eglGetDisplayDriverName
#      (EGL_EXT_device_query), 而 libmali g24p0 blob **不导出这一组符号**,
#      glxtest 直接判死 → 不开 GPU 进程 → WebRender 全软件 + VA-API 链被跳过。
#      同时 blob 还有四个伴随 bug: eglQueryString 返回空扩展表( epoxy/GTK 全被坑 )、
#      hook 的 eglChooseConfig 对带 EGL_CONFIG_ID 的 attrib 列表直接段错误、
#      KHR 版本参数(MAJOR=3)拒收且裸上下文只有 ES1.1(MAJOR=2 才给 ES3.2)、
#      eglGetPlatformDisplay(WAYLAND) 恒返回 NULL(GTK4 无法建 GL)。
#      修法 = mali_egl_wrapper.c: 一个自包含的 libEGL 转发层, 修完这些缺口后
#      转发给真 blob。glxtest 实测 VENDOR=ARM / RENDERER=Mali-G52 / GLES 3.2,
#      WebRender 硬件合成实测 GPU 负载 30%+ (此前恒 0%)。
#
#   2. 音频全静音。DTS 里 rk809 codec 带两行关键属性:
#          use-ext-amplifier;  spk-use-hp-channel;
#      即喇叭输出走 **耳机通道 + 外部功放**(spk-ctl-gpios), 而
#      "HP Output Gain" 混音器出厂默认 0 (=0dB 且blob 侧把 DAC 后级归零)。
#      功放 GPIO、Playback Path、DAC 音量全对, 就是没声 —— ftrace 抓到
#      gpio-102 在播放时正常拉高, 最后把 HP 增益拉满(3=9dB)才出声。
#      修法 = first-boot 一次性 z96a-audio-setup: 置增益 → alsactl store,
#      之后每次开机由 alsa-restore 常规恢复。
#
#   3. Firefox 的 vaapitest 探测在浏览器启动的 CPU 争抢下超过 WebKit 的
#      2 秒硬超时 → 探测结果判死 → 就算链路全通也进不了硬解。
#      修法 = vaapitest 包一层 nice -10 (实测满载下 53ms, 超时是 2000ms)。
#
# 依赖关系: 本扩展必须在 build-with-mali.yml 装好 libmali deb 之后运行
# (pre_customize_image 阶段天然满足); wrapper 本体只依赖 libc —— 运行期
# dlopen("libmali-hook.so.1"/"libmali.so.1"), 所以编译不需要 blob 头文件/库。
#
# 本扩展形状与 z96a-desktop-fix 一致: 具名 hook + EXTENSION_DIR 自取数据 +
# overlay 整体拷入 + 显式 chmod(GitHub artifact 丢权限位)。

function pre_customize_image__z96a_mali_gl_fix() {
	display_alert "Z96A mali gl fix" "libmali EGL wrapper + firefox-hw + rk809 audio gain" "info"

	local ext="${EXTENSION_DIR}"
	local dest="${SDCARD}/opt/z96a-mali-egl"

	# ------------------------------------------------ 1. 编译 + 安装 wrapper
	# 纯 dlfcn 自包含: 不链 libmali(Actions runner 上没有 blob 库可链),
	# 运行期 dlopen 拿真实现, 板上已验证与 -lmali 链接版行为一致。
	local cc="aarch64-linux-gnu-gcc"
	if ! command -v "$cc" >/dev/null 2>&1; then
		display_alert "Z96A mali gl fix" "cross compiler missing: $cc (crossbuild-essential-arm64)" "err"
		exit 1
	fi
	mkdir -p "$dest"

	local src="$ext/mali_egl_wrapper.c"
	if [[ ! -f "$src" ]]; then
		display_alert "Z96A mali gl fix" "mali_egl_wrapper.c missing next to the extension" "err"
		exit 1
	fi
	run_host_command_logged "$cc" -shared -fPIC -O2 -o "$dest/libEGL.so.1" "$src" -ldl -Wl,-soname,libEGL.so.1

	# glX 探测桩: GTK4/epoxy 探测桌面 GL 时要先看到 glXGetCurrentContext 等
	# 符号存在, 全空壳会让 epoxy 直接 abort("libGL missing methods"的兄弟病)。
	# gl* 核心函数故意不提供: GL 上下文只从 EGL/GLES(mali) 来, Firefox 的
	# dlsym("glGetString") 必须落空后回落到 libGLESv2 —— 这是实测出来的分界线。
	cat > /tmp/z96a-glstub.c <<'GSTUB'
void *glXGetCurrentContext(void) { return 0; }
void *glXGetCurrentDisplay(void) { return 0; }
void *glXGetProcAddress(const char *n) { (void)n; return 0; }
void *glXGetProcAddressARB(const char *n) { (void)n; return 0; }
int glXQueryExtension(void *d, int *a, int *b) { (void)d;(void)a;(void)b; return 0; }
int glXQueryVersion(void *d, int *a, int *b) { (void)d;(void)a;(void)b; return 0; }
void *glXChooseVisual(void *d, int s, int *a) { (void)d;(void)s;(void)a; return 0; }
void *glXChooseFBConfig(void *d, int s, const int *a, int *n) { (void)d;(void)s;(void)a;(void)n; return 0; }
void *glXCreateContext(void *d, void *v, void *s, int f) { (void)d;(void)v;(void)s;(void)f; return 0; }
int glXMakeCurrent(void *d, unsigned long w, void *c) { (void)d;(void)w;(void)c; return 0; }
void glXDestroyContext(void *d, void *c) { (void)d;(void)c; }
void glXSwapBuffers(void *d, unsigned long w) { (void)d;(void)w; }
int glXIsDirect(void *d, void *c) { (void)d;(void)c; return 0; }
const char *glXGetClientString(void *d, int n) { (void)d;(void)n; return 0; }
const char *glXQueryExtensionsString(void *d, int s) { (void)d;(void)s; return 0; }
const char *glXQueryServerString(void *d, int s, int n) { (void)d;(void)s;(void)n; return 0; }
GSTUB
	run_host_command_logged "$cc" -shared -fPIC -O2 -o "$dest/libGL.so.1" /tmp/z96a-glstub.c -Wl,-soname,libGL.so.1
	chmod 644 "$dest/libEGL.so.1" "$dest/libGL.so.1"
	( cd "$dest" && ln -sf libEGL.so.1 libEGL.so && ln -sf libGL.so.1 libGL.so )

	# --------------------------------------- 2. firefox-hw 启动器 + 桌面入口
	# LD_LIBRARY_PATH 把 wrapper 排在最前(只作用于这一棵进程树, 桌面/mutter
	# 继续用 stock libEGL —— wrapper 曾全局替换过, mutter 会被 fake device
	# query 引进多 GPU 路径然后死于 NULL 字符串, greeter 当场回退 X11 偏色)。
	# MOZ_DISABLE_RDD_SANDBOX: RDD 沙箱会拦掉 /dev/mpp_service, VA-API 探测
	# 和解码全挂; 事实上的安全边界由镜像本身的用途决定(调试板, root 会话)。
	mkdir -p "${SDCARD}/usr/local/bin"
	cat > "${SDCARD}/usr/local/bin/firefox-hw" <<'LAUNCHER'
#!/bin/sh
# Z96A: firefox 走 libmali EGL wrapper (libmali blob 缺陷补齐), 见
# /opt/z96a-mali-egl 与 z96a-mali-gl-fix 扩展。只作用本进程树。
LD_LIBRARY_PATH=/opt/z96a-mali-egl:$LD_LIBRARY_PATH MOZ_DISABLE_RDD_SANDBOX=1 exec /usr/lib/firefox-esr/firefox-esr "$@"
LAUNCHER
	chmod 755 "${SDCARD}/usr/local/bin/firefox-hw"

	# 桌面入口重定向: /usr/local/share/applications 优先级高于包自带的
	# /usr/share/applications, 不动包文件就不会被 firefox 升级覆盖回去。
	mkdir -p "${SDCARD}/usr/local/share/applications"
	if [[ -f "${SDCARD}/usr/share/applications/firefox-esr.desktop" ]]; then
		sed 's|^Exec=/usr/lib/firefox-esr/firefox-esr |Exec=/usr/local/bin/firefox-hw |; s|^Exec=firefox-esr |Exec=/usr/local/bin/firefox-hw |' \
			"${SDCARD}/usr/share/applications/firefox-esr.desktop" \
			> "${SDCARD}/usr/local/share/applications/firefox-esr.desktop"
	fi

	# ------------------------------------- 3. vaapitest 探测提权(nice -10)
	# WebKit/Firefox 同步等待 vaapitest 最多 2000ms; 浏览器启动期 4x A55
	# 满载时裸跑会偶发超时 → 探测判死 → 硬解链被跳过。提权后实测满载 53ms。
	if [[ -f "${SDCARD}/usr/lib/firefox-esr/vaapitest" && ! -f "${SDCARD}/usr/lib/firefox-esr/vaapitest.real" ]]; then
		run_host_command_logged mv "${SDCARD}/usr/lib/firefox-esr/vaapitest" "${SDCARD}/usr/lib/firefox-esr/vaapitest.real"
		cat > "${SDCARD}/usr/lib/firefox-esr/vaapitest" <<'NICE'
#!/bin/sh
# Z96A: 探测必须赶在 Firefox 的 VAAPI_TEST_TIMEOUT(2s) 内完成, 提权防
# 浏览器启动期 CPU 争抢把它挤过线(裸跑偶发 2s+, 提权实测 53ms)。
exec nice -n -10 /usr/lib/firefox-esr/vaapitest.real "$@"
NICE
		chmod 755 "${SDCARD}/usr/lib/firefox-esr/vaapitest"
	fi

	# ------------------------------------------- 4. 音频增益修复(first boot)
	# overlay 带 z96a-audio-setup + oneshot unit; 开机后置增益并 alsactl
	# store 固化, 之后走常规 alsa-restore。overlay 里的权限位由
	# build-with-mali.yml 的 chmod 恢复循环统一补, 这里再兜底一次。
	run_host_command_logged cp -a "${ext}/overlay/." "${SDCARD}/"
	chmod 755 "${SDCARD}/usr/lib/armbian/z96a-audio-setup"
	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	ln -sf /usr/lib/systemd/system/z96a-audio-setup.service \
	       "${SDCARD}/etc/systemd/system/multi-user.target.wants/z96a-audio-setup.service"

	# ---------------------------------------------- 5. gstreamer 解码 rank
	# mppvideodec(rockchipmpp) 拉到 primary+100: 所有 gstreamer 消费者
	# (Totem 等) 的 H264/HEVC/VP9 自动走 VPU, 处理不了的格式 decodebin
	# 自动回落软件解码, 无副作用。
	if ! grep -q "GST_PLUGIN_FEATURE_RANK" "${SDCARD}/etc/environment"; then
		echo 'GST_PLUGIN_FEATURE_RANK=mppvideodec:primary+100' >> "${SDCARD}/etc/environment"
	fi

	display_alert "Z96A mali gl fix" "wrapper compiled, firefox-hw + audio-setup installed" "info"
	exit 0
}
