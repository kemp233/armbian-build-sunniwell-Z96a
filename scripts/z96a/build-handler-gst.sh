#!/bin/bash
# Z96A mpv-handler + gstreamer-rockchip 构建 (step 22 的实际执行体)
# 同样在 debian:bookworm arm64 容器里运行, 原因见 build-mpv-stack.sh。
# mpv-handler 的 Rust (edition 2024, >=1.85) 由容器内 rustup 提供。
set -euo pipefail

set -euo pipefail
STAGE="$PWD/extensions/z96a-mpv/overlay"
WORK="$PWD/.handler-build"
# 这个 step 中途会 cd 进 $WORK 编 mpv-handler, 之后 gstreamer 段
# 的 INSTALL_ROOT/BUILD_PC 必须仍然指回**仓库根** —— 上一个 step
# 的 MPP/FFmpeg/libplacebo 全装在 $REPO_ROOT/.local-root。
# run 36658523536: INSTALL_ROOT 在 cd "$WORK" 之后才算, 相对路径
# 落成了 .handler-build/.local-root (空目录), MPP 断言当场红。
# 断言本身是对的 —— 它如实报告了"那里没有 .pc"。
REPO_ROOT="$PWD"
mkdir -p "$WORK"

# ==================================================================
# 一、mpv-handler —— "Play with MPV" 的来源
# ==================================================================
apt_update_ok=0
for i in 1 2 3; do
  if apt-get update; then apt_update_ok=1; break; fi
  echo "apt-get update failed, retrying (attempt $i/3)"; sleep 10
done
[ "$apt_update_ok" = 1 ] || exit 1
apt-get install -y --no-install-recommends \
  build-essential meson ninja-build pkg-config bison flex curl ca-certificates \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libgstreamer-plugins-bad1.0-dev \
  libx11-dev libdrm-dev
# 装没装上, 当场验, 不留给 meson 的报错去猜
for p in gstreamer-1.0 gstreamer-plugins-base-1.0 gstreamer-plugins-bad-1.0 libdrm; do
  if ! pkg-config --exists "$p"; then
    echo "断言失败: pkg-config 找不到 $p —— apt 安装没生效"
    exit 1
  fi
done
echo "gstreamer 开发包齐了"

# 这是 Rust 项目, edition = 2024, 最低要 Rust 1.85; 而
# ubuntu-24.04 自带的是 1.75, 直接 apt 装 rustc 会在
# "edition2024" 上当场报错。所以必须上 rustup。
if ! command -v cargo >/dev/null 2>&1 || \
   ! cargo --version 2>/dev/null | grep -qE '1\.(8[5-9]|9[0-9])|^cargo 1\.(1[0-9]{2})'; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal
fi
# shellcheck disable=SC1091
. "$HOME/.cargo/env"
cargo --version
rustc --version

cd "$WORK"
MPV_HANDLER_TAG=v0.4.2
git clone --depth 1 --branch "$MPV_HANDLER_TAG" \
  https://github.com/akiirui/mpv-handler.git mpv-handler
cd mpv-handler
cargo build --release
[ -f target/release/mpv-handler ] || {
  echo "断言失败: cargo 没产出 mpv-handler"; exit 1; }

# 装进 stage。注意它是个**用户级**安装 (README 的 Manual installation),
# 桌面会话是 root, 所以路径全在 root 家目录下。
mkdir -p "$STAGE/root/.local/bin" \
         "$STAGE/root/.local/share/applications" \
         "$STAGE/root/.config/mpv-handler"
cp -a target/release/mpv-handler "$STAGE/root/.local/bin/mpv-handler"
chmod 0755 "$STAGE/root/.local/bin/mpv-handler"
cp -a share/linux/mpv-handler.desktop \
      "$STAGE/root/.local/share/applications/mpv-handler.desktop"
cp -a share/linux/mpv-handler-debug.desktop \
      "$STAGE/root/.local/share/applications/mpv-handler-debug.desktop"

# mpv-handler 的配置。它的 config.toml 支持 proxy 字段 —— 这正好
# 是"打开油管没反应"的正解: 不必去改系统级环境变量, 直接让这个
# handler 带着代理去调 yt-dlp。上游默认的 mpv/ytdlp 都是相对路径,
# 交给 PATH 找, 我们装的 /usr/local/bin/mpv 和 yt-dlp 就在里面。
# echo 逐行写, 不用 heredoc: heredoc 体顶格会把 YAML 的 run 块
# 标量截断 (后面 "proxy = ..." 那行不含缩进, 会被当成 YAML 键)。
{
  echo '# 由 build-with-mali.yml 生成'
  echo 'mpv = "/usr/local/bin/mpv"'
  echo 'ytdl = "/usr/local/bin/yt-dlp"'
  echo 'proxy = "http://192.168.50.211:7893"'
} > "$STAGE/root/.config/mpv-handler/config.toml"
cat "$STAGE/root/.config/mpv-handler/config.toml"
cd "$WORK"

# ==================================================================
# 二、rockchip-gstreamer-mpp
# ==================================================================
# 解码器换成 BoxCloudIRL 的 gstreamer-rockchip。
#
# 换掉 resi-labs 那份的唯一原因: 它是**因为 DMCA 被阉割**的分支,
# README 写明不解 AV1 / H.265 / VP9, 只能解 H.264。而 B站和
# YouTube 现在大量用 HEVC, 只解 H.264 的解码器基本没用。
# 我逐行对比过两边的 gst_mpp_video_dec_get_mpp_type(), 差别就是
# resi-labs 删掉的三行:
#     video/x-h265  -> MPP_VIDEO_CodingHEVC
#     video/x-av1   -> MPP_VIDEO_CodingAV1
#     video/x-vp9   -> MPP_VIDEO_CodingVP9
# BoxCloudIRL 这三行都在, 并且和 sink pad 的 caps 模板
# (gstmppvideodec.c:65-69) 一致 —— 不是只写了个声明。
# meson_options.txt 两边逐字相同, 所以下面的 -D 参数照搬即可。
#
# 两点必须心里有数:
#   1. 这个仓库是给 **RK3588** 写的 (debian/control 里明写),
#      而 3588 有 AV1 硬解, **3568 没有**。所以 video/x-av1 这个
#      分支在这块板子上运行时会被 MPP 拒绝 (MPP_ERR_NOT_PERMIT),
#      属于预期, 不是构建失败。
#   2. 它的 encoder 只有 mppvp8enc/mpph264enc/mpph265enc/mppjpegenc,
#      比 resi-labs 那份**少一个 H.265 编码器**。解码补全, 编码略减。
#
# 再次强调: **mpv 永远走不到这里**。mpv 只用 libav*, 播视频靠的是
# FFmpeg 那条 rkmpp 通路(已在板子上实测 8.5% CPU)。换这个插件
# 对 mpv 播放没有任何影响, 别把它的成败当成硬解的成败。
#
# 依赖问题: 它要 librockchip-mpp-dev, 而 Ubuntu noble 没有这个包。
# 镜像里的 MPP 是 custom/extensions/rockchip-multimedia.sh 从源码
# 编的 (rockchip-linux/mpp tag 1.1.0), 但那个扩展是在 compile.sh
# 构建镜像时才跑的, 而这一步在它之前。所以这里为了让 configure 过,
# 临时自己编一份 MPP —— **只用来链接, 不进 stage**, 避免镜像里
# 出现两份 MPP 互相踩。版本钉死成一样的 1.1.0, soname 对得上。
# 注意: **不能**把 librga-dev 也塞进这条命令再加 || true。
# apt 安装是原子的 —— 列表里任何一个包定位不到, 整条命令一个都
# 不装, 而 || true 会把这个失败吞掉, 直到 meson setup 报
# "gstreamer-1.0 dependency not found" 才暴露, 中间隔着几分钟,
# 根本看不出是包没装上。librga-dev 在 noble/arm64 上不存在
# (Launchpad 索引确认), 而下面 meson 本来就 -Drga=disabled,
# 顶层 meson.build 对 disabled 的 required:false 依赖会干净跳过,
# 所以直接不装。
# 这些是插件编译的硬依赖, 失败就该当场红。


# MPP 由**上一个 step** 已经编好 (FFmpeg configure 需要它, 所以
# 顺序在前)。这里只复用, 不重编 —— 编过一次的东西再编一遍纯属
# 浪费, 还可能在 runner 缓存不一致时编出不同版本。
# run 36575615110 的反面教训: 曾经把 MPP 构建放在这里、FFmpeg 在
# 前面一步, 顺序颠倒导致 configure 找不到 rockchip_mpp >= 1.3.9。
# 安装树和 BUILD_PC 镜像要和上一个 step 完全一致 (变量不跨 step,
# 各自重建)。不重建的话 pkg-config 会把 -L 指到真正的
# /usr/local —— runner 上那里是空的, 链接必炸。
# 必须用仓库根 (见本 step 开头 REPO_ROOT 的注释): 此刻 $PWD 是
# .handler-build, 相对路径会指到空的 .local-root。
INSTALL_ROOT="$REPO_ROOT/.local-root"
BUILD_PC="$REPO_ROOT/.pc-build"
mkdir -p "$BUILD_PC"
# find 的起始路径必须先 exist: 目录不存在时 find 返回 1,
# 2>/dev/null 只藏报错不藏退出码, pipefail + set -e 会无声杀死
# 整个 step —— run 36581861684 就这么死在 apt 装完之后, 日志里
# 一个字都没有。
mkdir -p "$INSTALL_ROOT/usr/local/lib/pkgconfig" \
         "$INSTALL_ROOT/usr/local/lib/aarch64-linux-gnu/pkgconfig"
find "$INSTALL_ROOT/usr/local/lib/pkgconfig" \
     "$INSTALL_ROOT/usr/local/lib/aarch64-linux-gnu/pkgconfig" \
     -name '*.pc' 2>/dev/null | while IFS= read -r f; do
  sed "s|^prefix=.*|prefix=$INSTALL_ROOT/usr/local|" "$f" > "$BUILD_PC/$(basename "$f")"
done
export PKG_CONFIG_PATH="$BUILD_PC:${PKG_CONFIG_PATH:-}"
if [ ! -f "$INSTALL_ROOT/usr/local/lib/pkgconfig/rockchip_mpp.pc" ]; then
  echo "断言失败: 上一个 step 应该已编好 MPP, 但 $INSTALL_ROOT 里没有 .pc"
  echo "  两个 step 共用同一个 MPP, 检查 step 顺序是否被改动"
  exit 1
fi
echo "复用上一个 step 编好的 MPP: $(pkg-config --modversion rockchip_mpp 2>/dev/null || echo '?')"

# 钉死 commit 而不是跟 default 分支: 这个仓库没有 tag, default 分支
# 一动, 镜像里的编解码能力就跟着变, 而 CI 不会告诉你。
GST_MPP_URL=https://github.com/BoxCloudIRL/gstreamer-rockchip.git
GST_MPP_COMMIT="$(git ls-remote "$GST_MPP_URL" HEAD | cut -f1)"
echo "gstreamer-rockchip 固定到 commit $GST_MPP_COMMIT"
git clone --depth 1 "$GST_MPP_URL" gst-rockchip
cd gst-rockchip
git fetch -q --depth 1 origin "$GST_MPP_COMMIT"
git checkout -q "$GST_MPP_COMMIT"
# 换了源就必须重新确认那三个解码分支还在。clone 到的是 shallow
# HEAD, 拿到的是哪一版由上面那个 SHA 决定 —— 断言在这里兜底。
DEC_SRC=gst/rockchipmpp/gstmppvideodec.c
for pair in \
  'video/x-h265:MPP_VIDEO_CodingHEVC' \
  'video/x-av1:MPP_VIDEO_CodingAV1' \
  'video/x-vp9:MPP_VIDEO_CodingVP9' ; do
  fmt="${pair%%:*}"; sym="${pair##*:}"
  if ! grep -q "$fmt" "$DEC_SRC" || ! grep -q "$sym" "$DEC_SRC"; then
    echo "断言失败: 解码器缺少 $fmt -> $sym —— 换源后退化回只有 H.264 了"
    exit 1
  fi
  echo "  解码分支在: $fmt -> $sym"
done
grep -n 'video/x-h265\|video/x-av1\|video/x-vp9' "$DEC_SRC" | head -6
# 这份 meson.build 是从 gst-plugins-bad 整份 fork 来的, 不关掉
# auto_features 的话会连着把 bad 插件的几十个无关组件一起编,
# 光那部分就要几十分钟。只要 rockchipmpp 这一个。
# meson_options.txt 与 resi-labs 版逐字相同, 参数直接照搬。
meson setup build \
  -Dauto_features=disabled \
  -Drockchipmpp=enabled \
  -Drkximage=disabled \
  -Dkmssrc=disabled \
  -Drga=disabled \
  -Dvpxalphadec=disabled
meson compile -C build
DESTDIR="$STAGE" meson install -C build
cd "$WORK"

# MPP 别混进 stage (镜像里的 MPP 由 rockchip-multimedia.sh 提供,
# 版本同为 1.1.0)。INSTALL_ROOT 里的 MPP 不动 —— 删掉它的话下一个
# 重试 step 就没得复用了。
find "$STAGE" -name 'librockchip_mpp*' -print -delete || true
find "$STAGE" -name 'rockchip_*.pc' -print -delete || true

# ---- 自检 ------------------------------------------------------
if [ ! -x "$STAGE/root/.local/bin/mpv-handler" ]; then
  echo "断言失败: stage 里没有 mpv-handler"; exit 1
fi
if [ ! -f "$STAGE/root/.config/mpv-handler/config.toml" ]; then
  echo "断言失败: stage 里没有 mpv-handler 的 config.toml"; exit 1
fi
echo "  有: root/.local/bin/mpv-handler"
echo "  有: root/.config/mpv-handler/config.toml"
if ! find "$STAGE" -name 'libgstrockchi*.so' -print -quit | grep -q .; then
  echo "断言失败: stage 里没有 gstreamer rockchipmpp 插件"
  find "$STAGE" -name 'libgst*.so' | head -10
  exit 1
fi
echo "  有: libgstrockchi*.so"
echo "mpv-handler + rockchip-gstreamer-mpp 已备好"

