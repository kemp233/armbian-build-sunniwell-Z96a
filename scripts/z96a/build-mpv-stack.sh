#!/bin/bash
# Z96A 多媒体栈构建 (step 21 的实际执行体)
# 在 debian:bookworm arm64 容器里运行 —— 产物必须链接目标系统 (bookworm,
# glibc 2.36) 的 glibc; 之前在 noble runner (glibc 2.39) 上编的 mpv/ffmpeg
# 拷进 bookworm 镜像后 GLIBC_2.38 not found, 全部跑不起来。
# 由 build-with-mali.yml step 21 以 docker run 挂载 /work 调用。
set -euo pipefail

set -euo pipefail

# 全部在 CI 上编, **不要**回到板子上编。2026-09-29 的教训: 那台
# Z96A 上跑了几个小时的 FFmpeg/mpv 编译把闪存写坏了, initrd 读出来
# 是坏的 (U-Boot 报 "Wrong Ramdisk Image Format"), 整机开不了机,
# 板子上手工打的 mpv 补丁和 shaderc.pc 修正一起没了。这里有原生
# arm64 runner, 没有理由再拿设备当编译机。
#
# 产物进 extensions/z96a-mpv/overlay/, Armbian 构建镜像时会把它
# 铺到 / —— 跟 z96a-desktop-fix/overlay 用的是同一套机制。
STAGE="$PWD/extensions/z96a-mpv/overlay"
mkdir -p "$STAGE"
WORK="$PWD/.mpv-build"
mkdir -p "$WORK"
# 本脚本自带的补丁脚本所在目录。CI 里的调用是
#   bash /work/scripts/z96a/build-mpv-stack.sh
# (build-with-mali.yml), 之后本脚本会 cd 到 $WORK, 所以这里先把
# 绝对路径定下来, 免得后面相对路径失效。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- 构建依赖 -------------------------------------------------
# 包名以 **Debian bookworm (arm64 容器)** 为准 (2026-10-01 从 noble
# 名单迁移; noble 时代注释见 git 历史)。容器里必须先 apt-get update:
#   - `libglslang-dev` 在 noble 不存在, 是 `glslang-dev`
#     (run 36559657755 就死在 "Unable to locate package
#     libglslang-dev", 退出码 100)
#   - `libfreetype6-dev` 在 noble 也没有, 是 `libfreetype-dev`
# 每个包都对着 Launchpad noble/arm64 的索引查过再写进来, 别照搬
# Debian 的名字。
# libplacebo 的依赖最容易漏: 少 libxxf86vm-dev 就在 meson 那里
# "x11present not found", 少 shaderc/glslang 就在链接那里炸。
# fresh 容器没有包索引, 必须先 update (run 36808451716 的教训:
# 没这步所有包都是 "Unable to locate")
apt_update_ok=0
for i in 1 2 3; do
  if apt-get update; then apt_update_ok=1; break; fi
  echo "apt-get update failed, retrying (attempt $i/3)"; sleep 10
done
[ "$apt_update_ok" = 1 ] || exit 1
apt-get install -y --no-install-recommends \
  build-essential nasm yasm meson ninja-build cmake pkg-config git curl ca-certificates \
  libluajit-5.1-dev libpulse-dev libasound2-dev playerctl \
  python3 python3-pip python3-mako python3-jinja2 \
  libssl-dev \
  libvulkan-dev \
  libegl1-mesa-dev libgles2-mesa-dev libgbm-dev libdrm-dev \
  libx11-dev libxrandr-dev libxcb1-dev libxcb-dri2-0-dev \
  libxcb-dri3-dev libxcb-present-dev libxcb-sync-dev \
  libxcb-xfixes0-dev libxxf86vm-dev libxext-dev libxfixes-dev \
  wayland-protocols libxkbcommon-dev libwayland-dev \
  libass-dev libfreetype-dev libharfbuzz-dev libfribidi-dev \
  libvorbis-dev libopus-dev libopusfile-dev \
  libflac-dev libmpg123-dev libspeex-dev \
  hwdata
# hwdata 是自建 libdisplay-info 的**构建期**依赖 (meson.build:24 硬性
# 要求 /usr/share/hwdata/pnp.ids, 缺了直接 ERROR 退出)。
# bookworm 主仓库没有 libdisplay-info, 只有 bookworm-backports 的
# 0.2.0-2~bpo12+1 —— 而 CI 容器是裸 debian:bookworm, 镜像侧也不保证
# 开了 backports, 所以下面的 libdisplay-info 一律自建。
# 镜像**不需要** hwdata: mpv 只用 libdisplay-info 解 EDID
# (video/out/drm_common.c 里的 di_info_parse_edid / di_edid_* /
# di_cta_*), 全是纯计算, 唯一依赖 hwdata 的 di_get_pnp_ids() mpv
# 根本没调。

# ---- meson: 必须比 bookworm 的 1.0.1 新 --------------------------------
# mpv 0.41 的 meson.build:5 写的是 meson_version: '>=1.3.0'。Debian 12
# 的 meson 是 **1.0.1-5**, meson 会在 setup 阶段直接报
#   ERROR: Project requires meson version >= 1.3.0 but Meson version is 1.0.1
# mpv 0.38 的门槛还没这么高, 所以之前几轮 CI (36871702171/36879349652)
# 一直是过的 —— 升 mpv 才把这条线顶出来。
#
# 其余几个的门槛 (都查过上游 meson.build 的 project() 声明):
#   libplacebo v7.360.1     >=0.63   ✓ 1.0.1 本来就够
#   wayland-protocols 1.43  >=0.58   ✓
#   libdisplay-info 0.2.0   >=0.57   ✓
#   mpv v0.41.0             >=1.3.0  ✗
#
# 装法走 pip 而不是 bookworm-backports: backports 里没有可用的 meson
# (查 dists/bookworm-backports/main/binary-arm64/Packages.gz 直接 404),
# 而 pip 装出来是纯 Python 包, 不牵扯发行版打包。
#
# 版本钉 **1.12.1**, 不是"随便一个新版": 这个号正是板子上把
# libplacebo 7.360.1 / mpv 0.41.0 / wayland-protocols 1.43 /
# libdisplay-info 0.2.0 全部编过一遍的那个版本, 也就是除了 FFmpeg
# 之外每个组件都已经在真硬件上验证过。用别的号就是拿 CI 去试
# 没人试过的组合。
#
# 唯一未验证的组合是 FFmpeg(d90e3a1) + meson 1.12.1 —— 它之前一直跑在
# 1.0.1 上。选"全局换新"而不是"只给 mpv 单独塞一个新 meson", 是因为
# 那样换能凑齐 4 个已验证组合, 只留 FFmpeg 一个风险点; 要是只给 mpv
# 换, libplacebo 7 / wayland-protocols 1.43 / libdisplay-info 0.2.0 就全
# 退回未验证的 1.0.1, 变成三个风险点。FFmpeg 那边是活跃维护的 fork,
# 上游自己就用较新的 meson 构建, 风险可接受。
#
# bookworm 有 PEP 668 的 EXTERNALLY-MANAGED 标记, 不加
# --break-system-packages 会被 pip 拒掉。
MESON_PIN=1.12.1
python3 -m pip install --no-cache-dir --break-system-packages "meson==$MESON_PIN"
# pip 把 meson 装到 /usr/local/bin, 但不显式确认的话, 前面 apt 装的
# /usr/bin/meson 1.0.1 随时可能因为 PATH 顺序被挑中 —— 症状是 mpv 的
# setup 阶段报版本不够, 报错位置离真正的原因十万八千里。这里当场验。
export PATH="/usr/local/bin:$PATH"
MESON_BIN=$(command -v meson)
MESON_GOT=$("$MESON_BIN" --version)
if [ "$MESON_GOT" != "$MESON_PIN" ]; then
  echo "断言失败: 实际生效的 meson 是 $MESON_GOT ($MESON_BIN), 期望 $MESON_PIN"
  echo "  PATH=$PATH"
  echo "  mpv 0.41 要求 >= 1.3.0, 拿到旧的 1.0.1 会在 meson setup 直接失败"
  exit 1
fi
# mpv 的硬门槛单独再钉一道: 以后有人改 MESON_PIN 时, 这里先炸,
# 不用等 mpv 报一句语焉不详的 "Project requires meson version"
case "$MESON_GOT" in
  1.[3-9]*|1.[0-9][0-9]*|[2-9]*) : ;;
  *) echo "断言失败: meson $MESON_GOT 低于 mpv 0.41 要求的 1.3.0"; exit 1 ;;
esac
echo "meson: $MESON_GOT ($MESON_BIN)"

# ---- 版本钉死 -------------------------------------------------
# 全部钉到具体 commit/tag, 不用分支头。上游一动这里就炸, 总比
# 悄悄编出一个不同的东西好。
FFMPEG_REPO=https://github.com/nyanmisaka/ffmpeg-rockchip.git
FFMPEG_COMMIT=d90e3a1
LIBPLACEBO_TAG=v7.360.1
MPV_TAG=v0.41.0
# mpv 0.41 的 video/out/wayland_common.c:3293 无条件调
# wp_color_manager_v1_get_version(), 而 color-management-v1 这个协议
# wayland-protocols 要到 **1.41** 才带 —— bookworm 只有 1.31, 于是编译
# 报 "implicit declaration of function wp_color_manager_v1_get_version"
# 直接失败。这是上游没给老 wayland-protocols 留 #ifdef 的 bug, 只能
# 升级协议包绕开。1.41/1.43 要求 wayland-scanner >= 1.20 (libwayland-dev
# 自带 1.21, 够); 再往上 1.48 起要求 scanner >= 1.23, bookworm 满足不了。
# 1.43 是这个 scanner 版本能用的最高版本, 就钉它。
WAYLAND_PROTOCOLS_TAG=1.43
# mpv 0.41 的 video/out/gpu/context_drm.c / drm_common.c 需要
# libdisplay-info >= 0.1.1, 见下面 meson.build:958-962 —— 找到就链进去
# (mpv 二进制的 DT_NEEDED 会多一条 libdisplay-info.so.2)。
# 同样因为 bookworm 主仓库没有, 自建。
LIBDISPLAY_INFO_TAG=0.2.0
YTDLP_URL=https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp

# ---- 安装根: runner 可写, 模拟镜像的 / --------------------------
# run 36578273991 暴露的: GitHub runner 的 /usr/local 是 root 的,
# runner 用户写不了 —— `cmake --install` 报
#   file INSTALL cannot make directory
#   ".../mpp-build-prefix/include/rockchip": No such file or directory
# 中间层 mkdir 被 EACCES 拒掉后, 最后一级才报出误导性的 ENOENT。
# 修法不是 sudo —— sudo 装出来的东西 ownership 一团糟, 而且把构建
# 产物灌进 runner 系统目录本来就脏。统一改成: 一切 configure 仍然
# 用 --prefix=/usr/local (和镜像里的路径一致, .pc 内容不用改), 但
# **安装一律加 DESTDIR=$INSTALL_ROOT**, 落到工作区里; 构建期靠
# PKG_CONFIG_SYSROOT_DIR 把 -I/-L 重定向到 $INSTALL_ROOT 下。
# 这也是镜像布局的真实预演: 装出来的树就是镜像里 /usr/local 的形状。
# 构建期怎么链接到这棵树, 见下面 BUILD_PC 的注释。
INSTALL_ROOT="$PWD/.local-root"
mkdir -p "$INSTALL_ROOT"
# 刻意**不用** PKG_CONFIG_SYSROOT_DIR: 它会无差别重写所有 .pc 的
# 路径, 连系统库 (openssl/libdrm/x11, 都在 /usr) 也被指到
# $INSTALL_ROOT/usr/... 下不存在的地方, ffmpeg 的 configure 检查
# 反而全挂。构建期路径问题用下面的 BUILD_PC 镜像解决。
export CFLAGS="-I$INSTALL_ROOT/usr/local/include ${CFLAGS:-}"
export LDFLAGS="-L$INSTALL_ROOT/usr/local/lib ${LDFLAGS:-}"

# BUILD_PC: INSTALL_ROOT 里 .pc 的构建期镜像。安装树里的 .pc 全是
# prefix=/usr/local (镜像形状, 随镜像走, 一个字不改); 但构建时
# pkg-config 展开成 -L/usr/local/lib 是空的, 链接必炸。镜像一份
# 把 prefix 行重写成 $INSTALL_ROOT/usr/local, 放在 PKG_CONFIG_PATH
# 最前面 —— 系统库不受影响 (它们不在这两个目录里), 自己编的库
# 全部指对。
BUILD_PC="$PWD/.pc-build"
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

cd "$WORK"
# ---- MPP 先行 -------------------------------------------------
# FFmpeg 的 configure 要 pkg-config 找到 rockchip_mpp: nyanmisaka
# 的 rkmpp 硬性要求 "rockchip_mpp >= 1.3.9" (configure:7514), 要头
# 文件 rockchip/rk_mpi.h 和符号 mpp_create / mpp_buffer_sync_begin_f。
# run 36575615110 就死在这里 —— MPP 构建在**下一个** step 里, 顺序
# 反了。板上能编过是因为板上本来就有装好的 MPP, runner 上没有。
# MPP 1.1.0 的 .pc 报 Version: 1.3.10 (pkgconfig/rockchip_mpp.pc.cmake
# 里写死的), 满足 >= 1.3.9。版本钉死成和 rockchip-multimedia.sh
# 一致的 1.1.0, soname 对得上, 下一步不再重编。
if [ ! -f "$INSTALL_ROOT/usr/local/lib/pkgconfig/rockchip_mpp.pc" ]; then
  git clone --depth 1 --branch 1.1.0 \
    https://github.com/rockchip-linux/mpp.git mpp
  # MPP 的 cmake 默认会开一堆我们用不上的东西, 关掉以省时间。
  cmake -S mpp -B mpp/build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_INSTALL_LIBDIR=lib
  cmake --build mpp/build -j"$(nproc)"
  DESTDIR="$INSTALL_ROOT" cmake --install mpp/build
else
  echo "MPP 已就绪, 跳过"
fi
# MPP 的 .pc 刚落地, 必须先刷新 BUILD_PC 再断言 —— run 36590900889
# 的教训: MPP 装得好好的, 断言却找不到, 因为 PKG_CONFIG_PATH 里只有
# step 开头生成的空镜像, 原始 pkgconfig 目录刻意不在搜索路径里。
mkdir -p "$INSTALL_ROOT/usr/local/lib/pkgconfig" \
         "$INSTALL_ROOT/usr/local/lib/aarch64-linux-gnu/pkgconfig"
find "$INSTALL_ROOT/usr/local/lib/pkgconfig" \
     "$INSTALL_ROOT/usr/local/lib/aarch64-linux-gnu/pkgconfig" \
     -name '*.pc' 2>/dev/null | while IFS= read -r f; do
  sed "s|^prefix=.*|prefix=$INSTALL_ROOT/usr/local|" "$f" > "$BUILD_PC/$(basename "$f")"
done
echo "  BUILD_PC 镜像: $(ls "$BUILD_PC" | tr '\n' ' ')"
# FFmpeg configure 靠 pkg-config 找 MPP (版本断言), 头文件和链接
# 路径由上面的 CFLAGS/LDFLAGS + BUILD_PC 镜像提供。
if ! pkg-config --exists 'rockchip_mpp >= 1.3.9'; then
  echo "断言失败: MPP 装完 pkg-config 还是找不到 rockchip_mpp >= 1.3.9"
  find "$INSTALL_ROOT/usr/local" -name 'rockchip_mpp.pc' -o -name 'librockchip_mpp*' | head -10
  exit 1
fi
echo "MPP: pkg-config 报 $(pkg-config --modversion rockchip_mpp), >= 1.3.9 满足"

# ---- FFmpeg 7.1 + rkmpp ---------------------------------------
# --enable-openssl 是**这次修的头号 bug**。之前板上编的 FFmpeg
# 没带 TLS, ffmpeg -protocols 只有 http/httpproxy/ffrtmphttp,
# 于是 Play with MPV 一律报 "https or dtls protocol not found",
# 所有 B站/YouTube 链接都开不了 —— 日志第一行就是这个, 之前一直
# 当成网络问题查, 方向完全错了。
git clone --depth 1 "$FFMPEG_REPO" ffmpeg
cd ffmpeg
# fetch 只认全长 40 位 SHA, 短 SHA 直接报
# "couldn't find remote ref d90e3a1"。之前那条 `|| true` 把这个
# 失败吞了, 然后靠 checkout 短 SHA 碰巧落在本地对象上才没炸 ——
# 那是运气不是逻辑。这里先解析出全长, 解析不到就大声死, 不猜。
FULL_SHA="$(git ls-remote "$FFMPEG_REPO" | grep -m1 "^${FFMPEG_COMMIT}" | cut -f1)"
if [ -z "$FULL_SHA" ]; then
  echo "断言失败: $FFMPEG_COMMIT 在 $FFMPEG_REPO 的任何引用里都找不到"
  echo "  (上游 rebase/revert 过的话短 SHA 会悬空, 换一个有效 commit)"
  exit 1
fi
git fetch --depth 1 origin "$FULL_SHA"
git checkout --detach "$FULL_SHA"
ACTUAL="$(git rev-parse HEAD)"
if [ "$ACTUAL" != "$FULL_SHA" ]; then
  echo "断言失败: 实际 HEAD $ACTUAL != 目标 $FULL_SHA"
  exit 1
fi
echo "FFmpeg 实际 checkout 到: ${ACTUAL:0:7}"
./configure \
  --prefix=/usr/local \
  --enable-gpl --enable-version3 \
  --enable-rkmpp --enable-libdrm \
  --enable-openssl \
  --enable-shared --disable-static \
  --disable-doc --disable-debug
# 这里**不能**加 --disable-programs: run 36593271057 就死在这。
# 关掉 programs 之后 ffmpeg/ffprobe 根本不编, make install 只
# 装库/头文件/.pc (日志里 270 条 INSTALL 全是 libav*/libsw*),
# 于是下面第一条断言 $INSTALL_ROOT/usr/local/bin/ffmpeg 直接
# "No such file or directory"。而这个 step 从头到尾都依赖那两个
# 二进制: 断言 https、断言 rkmpp、拷进 STAGE、自检必须存在、
# 最后逐个 ldd 核对。断言挂在不存在的文件上, 报的还是
# "仍然没有 https 协议" —— https 其实在 configure 摘要里就有。
make -j"$(nproc)"
# DESTDIR 安装进 INSTALL_ROOT (见上面的注释)。ffmpeg 不设 rpath,
# 跑它要靠 LD_LIBRARY_PATH 指进安装树。
make install DESTDIR="$INSTALL_ROOT"

# 立刻验 https 真的通了再往下走 —— 这一条不验, 后面全都白编。
export LD_LIBRARY_PATH="$INSTALL_ROOT/usr/local/lib:${LD_LIBRARY_PATH:-}"
if ! "$INSTALL_ROOT/usr/local/bin/ffmpeg" -hide_banner -protocols 2>/dev/null | tr ' ' '\n' | grep -qx https; then
  echo "断言失败: 编出来的 FFmpeg 仍然没有 https 协议"
  "$INSTALL_ROOT/usr/local/bin/ffmpeg" -hide_banner -protocols 2>&1 | head -20
  exit 1
fi
echo "FFmpeg https 协议: 已启用"
# 同样当场验 rkmpp 真的编进去了
if ! "$INSTALL_ROOT/usr/local/bin/ffmpeg" -hide_banner -hwaccels 2>/dev/null | grep -qx rkmpp; then
  echo "断言失败: 编出来的 FFmpeg 没有 rkmpp 硬解"
  "$INSTALL_ROOT/usr/local/bin/ffmpeg" -hide_banner -hwaccels 2>&1 | head -20
  exit 1
fi
echo "FFmpeg rkmpp 硬解: 已启用"
cd "$WORK"

# ---- shaderc: 容器内自建自包含版 ------------------------------
# Debian bookworm 的 libshaderc.so.1 (2023.2) 不自包含: spvtools 的
# 193 个符号 (含 vtable _ZTVN8spvtools5utils5TimerE) 未定义且无提供者,
# 运行时加载必炸 (release 185 装上板后 mpv 实测: symbol lookup error)。
# noble 的 2023.8 自包含但要 GLIBC_2.38, bookworm 用不了。
# 所以在容器里从上游源码自建: 上游把 glslang/SPIRV-Tools 静态链进
# libshaderc.so, 产物自包含, glibc 2.36 编译即兼容。
SHADERC_TAG=v2023.8
if [ ! -f "$INSTALL_ROOT/usr/local/lib/libshaderc_shared.so.1" ]; then
  git clone --depth 1 --branch "$SHADERC_TAG" https://github.com/google/shaderc.git "$WORK/shaderc-src"
  ( cd "$WORK/shaderc-src" && python3 utils/git-sync-deps )
  cmake -S "$WORK/shaderc-src" -B "$WORK/shaderc-src/build" -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
        -DSHADERC_SKIP_COPYRIGHT_CHECK=ON -DENABLE_GLSLANG_BINARIES=OFF
  cmake --build "$WORK/shaderc-src/build" -j"$(nproc)" --target shaderc_shared
  SO=$(find "$WORK/shaderc-src/build" -name 'libshaderc_shared.so.1*' | head -1)
  [ -n "$SO" ] || { echo "断言失败: shaderc 构建没有产出 libshaderc_shared.so.1"; exit 1; }
  # 自包含当场验证: 未定义符号里不允许再出现 spvtools
  if nm -D --undefined-only "$SO" | grep -q spvtools; then
    echo "断言失败: 自建 libshaderc 仍有未定义的 spvtools 符号"
    exit 1
  fi
  mkdir -p "$INSTALL_ROOT/usr/local/lib" "$INSTALL_ROOT/usr/local/include/shaderc"
  # 必须保留上游的真实 SONAME (libshaderc_shared.so.1): mpv/libplacebo
  # 链接它时 DT_NEEDED 记录的就是 SONAME, 文件改名改不掉 SONAME
  # (release 185 之后 mpv 实测: libshaderc_shared.so.1 => not found)。
  cp "$SO" "$INSTALL_ROOT/usr/local/lib/libshaderc_shared.so.1"
  # 链接期 -lshaderc_shared 找的是**无版本号**的 libshaderc_shared.so,
  # 必须补一条指向 SONAME 的开发软链; 缺了它 gcc/meson 报
  # "cannot find -lshaderc_shared" (run 36853909804 就死在 .pc 链接自检)。
  ln -sf libshaderc_shared.so.1 "$INSTALL_ROOT/usr/local/lib/libshaderc_shared.so"
  cp -r "$WORK/shaderc-src/libshaderc/include/shaderc/." "$INSTALL_ROOT/usr/local/include/shaderc/"
  echo "shaderc 自包含版已就位: $SO"
else
  echo "shaderc 已就绪, 跳过"
fi

# ---- shaderc.pc 与链接自检 ------------------------------------
# libshaderc.so.1 已在上面自建, 这里写 .pc 并当场链接自检。
mkdir -p "$INSTALL_ROOT/usr/local/lib/pkgconfig"
{
  echo 'prefix=/usr/local'
  echo 'exec_prefix=${prefix}'
  echo 'libdir=${prefix}/lib'
  echo 'includedir=${prefix}/include'
  echo ''
  echo 'Name: shaderc'
  echo 'Description: GLSL to SPIR-V compiler (shared, glslang+spvtools 已静态内含)'
  echo 'Version: 2023.8'
  echo 'Libs: -L${libdir} -lshaderc_shared -lpthread -lstdc++ -lm'
  echo 'Cflags: -I${includedir}'
} > "$INSTALL_ROOT/usr/local/lib/pkgconfig/shaderc.pc"
# MPP/ffmpeg 的 DESTDIR 安装发生在上面, 此刻才有 .pc 可镜像 ——
# 刷新 BUILD_PC, 否则链接测试找不到刚装的库。
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
# 用覆盖后的 .pc 实际链接一次, 骗不了人: 找不到符号当场死。
printf 'int main(void){return 0;}\n' > /tmp/shc-test.c
if ! gcc /tmp/shc-test.c $(pkg-config --cflags --libs shaderc) -o /tmp/shc-test 2>/tmp/shc-test.err; then
  echo "断言失败: shaderc.pc 链接测试失败 —— .pc 内容和实际库对不上"
  cat /tmp/shc-test.err | head -15
  exit 1
fi
echo "shaderc.pc 链接测试通过 (BUILD_PC 镜像路径)"

# ---- libplacebo ----------------------------------------------
# shaderc 必须显式 enabled、glslang 必须显式 disabled。两者都是
# auto 的话, 探测结果取决于 meson 找 .pc 的顺序 —— 而 noble 上
# glslang 路线 (spirv.pc Requires SPIRV-Tools) 是断的, 一旦 meson
# 选中它, 死法就是链接时一堆 spvtools 符号未定义。
# --recurse-submodules 不能省。run 36653248728 死在
#   src/opengl/include/glad/meson.build:11: ERROR: glad
#   (required: >= 2.0, found: none) was not found in PYTHONPATH
#   or `3rdparty`
# libplacebo 把 glad (生成 GL loader 用的 python 包) 放在
# 3rdparty/glad 子模块里, 而 --depth 1 的 clone 一个子模块都不带。
# 不用 --shallow-submodules: libplacebo 把 glad/Vulkan-Headers/
# fast_float 都钉在具体 commit 上, shallow 子模块只拉各仓默认
# 分支的 tip, 那个 commit 未必在里面, checkout 会失败。宁可让
# 这几个子模块全量 clone。
git clone --depth 1 --recurse-submodules --branch "$LIBPLACEBO_TAG" \
  https://github.com/haasn/libplacebo.git libplacebo
cd libplacebo
# 子模块到位与否当场断言, 失败信息指到子模块而不是让 meson 抛一句
# "not found in PYTHONPATH" 让人以为是 PYTHONPATH 的问题。
for sm in glad Vulkan-Headers fast_float; do
  if [ ! -e "3rdparty/$sm" ] || [ -z "$(ls -A "3rdparty/$sm" 2>/dev/null)" ]; then
    echo "断言失败: libplacebo 子模块 3rdparty/$sm 是空的 —— clone 没带 --recurse-submodules"
    exit 1
  fi
  echo "  子模块在: 3rdparty/$sm"
done
# 选项名是 demos/tests/**不带 enable_ 前缀**。run 36651322478
# 就死在这: meson 1.3.2 直接报
#   meson.build:1:0: ERROR: Unknown options: "enable_demos, enable_tests"
# enable_ 前缀是 libplacebo v2.x(2021 年前后)的老名字, 连 4.x
# 的 meson_options.txt 都没有 —— 也就是说这两个 flag 从写下来
# 那天起就没对过任何一个 libplacebo 版本, 只是之前几轮都死在
# 到达这一行之前, 从没被 meson 读到过。meson 对未知选项是硬错,
# 不是警告, 所以它一直没能"顺便编过"。
# meson_version 要求 >= 0.63, runner 自带 1.3.2, 够。
meson setup build --buildtype=release -Dtests=false \
  -Ddemos=false \
  -Dshaderc=enabled -Dglslang=disabled
# 装完当场验: shaderc 路线的源文件 spirv_shaderc.c 只有在
# shaderc.found() 时才会进 sources (src/glsl/meson.build), 编出
# 它的 .o 就是"真的走的 shaderc"的铁证。
#
# 通配符必须带前导 `*`。src/glsl/meson.build 里加的是
# sources += 'glsl/spirv_shaderc.c', meson 拿子目录+文件名拼对象
# 名, 于是真名是 `glsl_spirv_shaderc.c.o` 而不是 `spirv_shaderc*.o`
# (本地 ubuntu-24.04 + meson 1.3.2 + v6.338.2 实测确认)。原来的
# 'spirv_shaderc*.o' 永远匹配不上, 而它的失败信息是"libplacebo
# 没有编译 spirv_shaderc —— shaderc 路线没生效", 一句彻底反着的
# 结论: shaderc 恰恰是生效的。
meson compile -C build
if ! find build -name '*spirv_shaderc*.o' | grep -q .; then
  echo "断言失败: libplacebo 没有编译 spirv_shaderc —— shaderc 路线没生效"
  echo "  (glslang 路线在 noble 上是断的: 没有 SPIRV-Tools.pc)"
  echo "  meson-log 里 shaderc/glslang 的探测结果:"
  grep -iE 'shaderc|glslang' build/meson-logs/meson-log.txt | tail -8 || true
  exit 1
fi
echo "libplacebo 走的 shaderc 路线 (spirv_shaderc.o 已编出)"
DESTDIR="$INSTALL_ROOT" meson install -C build
cd "$WORK"
# libplacebo.pc 刚落地, 刷新 BUILD_PC, mpv 才能链接到它。
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

# ---- wayland-protocols: bookworm 的 1.31 编不过 mpv 0.41 --------
# 起因见版本钉死处的注释。这里只做一件事: 装一份 1.43 进
# INSTALL_ROOT, 刷新 BUILD_PC 让 mpv 的 meson 看得见。
# 生成的协议 C 代码是**编进 mpv** 的, 镜像运行时不需要这些 XML, 所以
# 不进 stage —— 它和 libplacebo.pc 一样属于纯构建期输入, 而仓库本来
# 就不往 stage 里拷 multiarch 的 .pc。
#
# -Dtests=false 必须给: 1.41+ 的测试要 wayland-scanner >= 1.20 且
# 需要额外依赖, 而 scanner 是 1.21 的, 测试编不出来。
git clone --depth 1 --branch "$WAYLAND_PROTOCOLS_TAG" \
  https://gitlab.freedesktop.org/wayland/wayland-protocols.git wayland-protocols
meson setup wayland-protocols/build wayland-protocols \
      --prefix=/usr/local --buildtype=release -Dtests=false
DESTDIR="$INSTALL_ROOT" meson install -C wayland-protocols/build
if [ ! -f "$INSTALL_ROOT/usr/local/share/wayland-protocols/staging/color-management/color-management-v1.xml" ]; then
  echo "断言失败: wayland-protocols $WAYLAND_PROTOCOLS_TAG 里没有 color-management-v1.xml"
  echo "  mpv 0.41 的 wayland_common.c 会无条件调它的 C 代码, 缺了编译就挂"
  ls "$INSTALL_ROOT/usr/local/share/wayland-protocols/staging/color-management/" 2>/dev/null || true
  exit 1
fi
echo "wayland-protocols $WAYLAND_PROTOCOLS_TAG 已就位"

# ---- libdisplay-info: 自建, 因为 bookworm 主仓库没有 -----------
# mpv 0.41 meson.build:958-962:
#   libdisplay_info = dependency('libdisplay-info', version: '>= 0.1.1',
#                               required: get_option('drm'))
#   dependencies += [drm, libdisplay_info]
# 找到就链进 mpv 二进制 (DT_NEEDED 多一条 libdisplay-info.so.2), 而且
# **drm 这条 GPU context 直接由它 gate**: 不满足就没有 gpu-context=drm。
# bookworm 只有 bookworm-backports 的 0.2.0, 容器和镜像都不保证有
# backports, 所以自建 (和上面的 shaderc 一个路子)。
#
# 0.2.0 的 meson_options.txt 是空的 —— 传任何 -Dxxx 都会被 meson 判成
# Unknown option 直接失败 (实测: `-Dtests=false` -> "Unknown option:
# \"tests\""), 下面一个选项都不给。
# hwdata 是构建期硬依赖 (meson.build:24 检查 /usr/share/hwdata/pnp.ids),
# 已在 apt 名单里; 运行时不需要, 理由见那里。
git clone --depth 1 --branch "$LIBDISPLAY_INFO_TAG" \
  https://gitlab.freedesktop.org/emersion/libdisplay-info.git libdisplay-info
meson setup libdisplay-info/build libdisplay-info \
      --prefix=/usr/local --buildtype=release
meson compile -C libdisplay-info/build
DESTDIR="$INSTALL_ROOT" meson install -C libdisplay-info/build
# SONAME 是 libdisplay-info.so.2, mpv 的 DT_NEEDED 记的就是它;
# 旁边的 .pc 版本必须是 >= 0.1.1, 否则 mpv 探测阶段就跳过 drm
# -print -quit 而不是 `find … | head -1`: pipefail 下 find 吃到
# SIGPIPE 会返回 141, `set -e` 直接把整个 step 打死, 而失败信息是
# 一个空的命令替换值, 极难往回找 (本 step 开头的注释记过一次同源的坑)。
LDI_PC=$(find "$INSTALL_ROOT/usr/local/lib" -name 'libdisplay-info.pc' -print -quit)
if [ -z "$LDI_PC" ]; then
  echo "断言失败: 自建的 libdisplay-info 没装出 .pc"
  exit 1
fi
if ! grep -qE '^Version: 0\.[2-9]|^Version: [1-9]' "$LDI_PC"; then
  echo "断言失败: libdisplay-info.pc 的版本满足不了 mpv 的 >= 0.1.1"
  grep '^Version' "$LDI_PC"
  exit 1
fi
if ! ls "$INSTALL_ROOT"/usr/local/lib/aarch64-linux-gnu/libdisplay-info.so.2 >/dev/null 2>&1; then
  echo "断言失败: libdisplay-info.so.2 没装到 multiarch 目录"
  find "$INSTALL_ROOT/usr/local/lib" -name 'libdisplay-info*' | head
  exit 1
fi
echo "libdisplay-info $LIBDISPLAY_INFO_TAG 已就位 ($(grep '^Version' "$LDI_PC"))"
cd "$WORK"
# 这两个包的 .pc 刚落地, 刷新 BUILD_PC, mpv 才能探测到它们。
#
# share/pkgconfig 这一项不能少: wayland-protocols 不装到 lib/pkgconfig
# 也不装到 lib/<triplet>/pkgconfig, 而是装到 **share/pkgconfig/**
# (/usr/local/share/pkgconfig/wayland-protocols.pc)。漏掉它的话
# mpv 的 meson 会解析到容器自带的系统那份 1.31, 于是又回到
# "implicit declaration of function wp_color_manager_v1_get_version"
# —— 症状和没装 1.43 一模一样, 很容易误判成 clone 失败或者 meson
# 版本问题, 实际是 .pc 根本没进 PKG_CONFIG_PATH 的搜索路径。
mkdir -p "$INSTALL_ROOT/usr/local/lib/pkgconfig" \
         "$INSTALL_ROOT/usr/local/lib/aarch64-linux-gnu/pkgconfig" \
         "$INSTALL_ROOT/usr/local/share/pkgconfig"
find "$INSTALL_ROOT/usr/local/lib/pkgconfig" \
     "$INSTALL_ROOT/usr/local/lib/aarch64-linux-gnu/pkgconfig" \
     "$INSTALL_ROOT/usr/local/share/pkgconfig" \
     -name '*.pc' 2>/dev/null | while IFS= read -r f; do
  sed "s|^prefix=.*|prefix=$INSTALL_ROOT/usr/local|" "$f" > "$BUILD_PC/$(basename "$f")"
done
# mpv 只要求 wayland-protocols >= 1.31, 所以探测到了"一份"
# wayland-protocols 就算成功 —— 哪怕拿到的是系统那份 1.31。这里必须
# 显式断言版本和路径都对, 否则上面那条 find 少列一个目录, mpv 照样
# 配得起来, 只是编不过, 失败信息还落在几千行之后的 C 报错上。
WP_VER=$(PKG_CONFIG_PATH="$BUILD_PC${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
         pkg-config --modversion wayland-protocols 2>/dev/null || true)
WP_DIR=$(PKG_CONFIG_PATH="$BUILD_PC${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
         pkg-config --variable=pkgdatadir wayland-protocols 2>/dev/null || true)
if [ "$WP_VER" != "$WAYLAND_PROTOCOLS_TAG" ]; then
  echo "断言失败: 解析到的 wayland-protocols 是 '$WP_VER', 期望 '$WAYLAND_PROTOCOLS_TAG'"
  echo "  pkgdatadir=$WP_DIR"
  echo "  BUILD_PC=$BUILD_PC"
  exit 1
fi
if [ ! -f "$WP_DIR/staging/color-management/color-management-v1.xml" ]; then
  echo "断言失败: pkgdatadir 指向的目录里没有 color-management-v1.xml —— $WP_DIR"
  exit 1
fi
echo "  wayland-protocols: $WP_VER (pkgdatadir 落在 INSTALL_ROOT 里)"

# ---- mpv 0.41 -------------------------------------------------
# 三个补丁, 全是 FFmpeg 7.x 的 API 变更, 每一个都断言改了行数 ——
# 上游一变 sed 没匹配上, 必须当场炸, 不能编出个看着成功、
# 实际跑起来才崩的东西。
git clone --depth 1 --branch "$MPV_TAG" https://github.com/mpv-player/mpv.git mpv
cd mpv
# rkmpp 直通补丁: hwdec=rkmpp (非 copy) 时自建 RKMPP 设备。vo=gpu 不注册
# RKMPP 设备, 主线直通路径必然 "Could not create device" 回落软解 ——
# 这个补丁让解码器直出 drmprime, 由 vo/gpu 的 dmabuf-interop-gl 接收
# (mali EGL 导入 NV12 dmabuf 已用探针验证)。回拷消除后 CPU 预期 50%→25%。
if [ -f /work/scripts/z96a/mpv-rkmpp-direct.patch ]; then
  git apply /work/scripts/z96a/mpv-rkmpp-direct.patch \
    && echo "rkmpp 直通补丁已应用" \
    || { echo "断言失败: rkmpp 直通补丁打不上 (mpv 源码变了?)"; exit 1; }
fi
# (1)(2) 原来那两个 FFmpeg 7.x 的 API 补丁 —— mpv 0.41 自己已经不用
# 那两个旧符号了 (ad_spdif.c / demux_mkv.c 里 FF_PROFILE_ 残留 0 处,
# demux_lavf.c 里 av_format_inject_global_side_data 0 处), 所以补丁本身
# 必须撤掉。但不能只是删了事: 删掉就等于放弃了对"上游真的修好了吗"的
# 断言。改成**反向断言** —— 这两个符号哪天重新出现, 说明钉的 mpv 版本
# 和这里以为的不一样, 当场炸, 而不是编出一个行为不明的 mpv。
if grep -l 'FF_PROFILE_' audio/decode/ad_spdif.c demux/demux_mkv.c 2>/dev/null | grep -q .; then
  echo "断言失败: ad_spdif.c / demux_mkv.c 里又出现 FF_PROFILE_ 了 ——"
  echo "  这个 mpv 版本重新需要 FFmpeg 7.x 的改名补丁, 补丁得加回来"
  grep -c 'FF_PROFILE_' audio/decode/ad_spdif.c demux/demux_mkv.c
  exit 1
fi
if grep -q 'av_format_inject_global_side_data' demux/demux_lavf.c; then
  echo "断言失败: demux_lavf.c 里又出现 av_format_inject_global_side_data 了 ——"
  echo "  这个 mpv 版本重新需要删这行的补丁, 补丁得加回来"
  exit 1
fi
echo "  FFmpeg 7.x 的两个 API 补丁: 上游已自带, 不再需要"
# (3) rkmpp 硬解补丁。**必须打**: 不打的话 mpv 0.41 在这块板上会静默
# 退回软解 —— 没有一帧渲染失败, 日志干干净净, 只有 "Using software
# decoding" 一行。起因和机理见补丁文件头。
# 参数是**绝对路径**: 上面第 554 行已经 `cd mpv`, CWD 就是源码根,
# 这里再传个相对的 "mpv" 会被拼成 $WORK/mpv/mpv/... ——
# run 36909362820 就死在这, 报的是
#   FileNotFoundError: 'mpv/video/hwdec.h'
# 看着像补丁脚本本身坏了, 其实只是路径相对错了 CWD。
python3 "$SCRIPT_DIR/patch-mpv-rkmpp-hwdec.py" "$PWD"
# -Dwayland/-Degl-wayland/-Degl-drm/-Dgbm/-Ddrm 必须显式 enabled。
# mpv 的这些是 feature 型选项, 默认 auto —— 探测失败就悄悄关掉, 编出
# 一个 gpu-context 列表里根本没有 wayland/drm 的 mpv, 运行时只会表现为
# "auto 挑了个软 context", 没有任何报错。实测会翻车的地方:
#   meson.build:1035-1052  wayland  <- xkbcommon >= 0.3.0
#   meson.build:956-960    drm     <- libdisplay-info >= 0.1.1
#   meson.build:972-978    gbm     <- features['drm'] + gbm >= 17.1.0
#   meson.build:1248-1254  egl-wayland <- wayland-egl >= 9.0.0
# 依赖齐了的时候 auto 本来就会开, 显式写出来是为了在依赖没齐时炸在
# meson 而不是炸在用户的播放器上。
#
# **不能**动 x11: 强行 -Dx11=enabled 会牵出 libXss/libXpresent
# (meson.build:1089-1091), 容器里没装, 直接 xscrnsaver not found。
# x11 留 auto, 探测不到就关掉, 对这个 Wayland/GNOME 镜像无影响。
meson setup build --buildtype=release \
  -Dprefix=/usr/local \
  -Dgpl=true \
  -Dlibmpv=true \
            -Dlua=luajit \
  -Dtests=false \
  -Dmanpage-build=disabled \
  -Dwayland=enabled \
  -Degl-wayland=enabled \
  -Degl-drm=enabled \
  -Dgbm=enabled \
  -Ddrm=enabled
# -Dmanpage-build 是 feature 型 (enabled/disabled/auto), 传 false 会被
# meson 当非法值拒掉: `Value "false" ... Possible choices
# "enabled","disabled","auto"`。另外 html-build / pdf-build 在 mpv 里
# 默认就是 disabled, 不用管。
# 这里**不能**加 -Dcplayer=false。run 36656011005: libmpv.so.2.3.0
# 编出来装好了, 断言"没编出 mpv" —— cplayer=false 把 mpv 命令行
# 二进制整个关了, 而 stage 自检、ldd 核对、镜像里的 Play with MPV
# (mpv-handler 调的是 mpv 可执行文件, 不是 libmpv) 全都要那个
# 二进制。和 --disable-programs 同一天、同一个 commit 引入的同类
# 矛盾, 也是直到前面的关全过完才第一次被走到。
meson compile -C build
DESTDIR="$INSTALL_ROOT" meson install -C build
# ---- mpv 链接结果的当场断言 ------------------------------------
# 1) libplacebo soname: 6.338.2 是 so.338, 7.360.1 是 so.360。CI 里
#    配错了 mpv/libplacebo 的一对, 镜像上就会在 ld.so.conf.d 都配好、
#    文件也都在的情况下报 "libplacebo.so.XXX: cannot open shared object
#    file"。这里当场钉死, 比在板上查一小时强。
MPV_NEEDED=$(objdump -p "$INSTALL_ROOT/usr/local/bin/mpv" | awk '/NEEDED/{print $2}')
# 用 `grep -qx` 整行精确匹配, **不要**写成
#     case " $MPV_NEEDED " in *" libplacebo.so.360 "*) ;;
# 那种写法看着像在匹配, 其实永远不成立: $MPV_NEEDED 是**多行**字符串
# (mpv 连十几个库), 行与行之间是换行而不是空格, 而那个 pattern 要求
# 目标前后都得是空格。run 36912881289 就是这么炸的 —— 报错说
# "mpv 没有链接 libplacebo.so.360", 紧跟着自己又把
# libplacebo.so.360 打了出来, 自相矛盾。
# 用 here-string 而不是 `printf ... | grep`: 后者在 set -o pipefail 下
# 有 SIGPIPE 141 的坑 (grep -q 命中即退, printf 收 EPIPE)。
if ! grep -qx 'libplacebo\.so\.360' <<< "$MPV_NEEDED"; then
  echo "断言失败: mpv 没有链接 libplacebo.so.360, 实际是:"
  grep -i placebo <<< "$MPV_NEEDED" || echo "  (一条都没链接!)"
  echo "  libplacebo $LIBPLACEBO_TAG 的 soname 应当是 360"
  exit 1
fi
echo "  mpv -> libplacebo.so.360"
# 2) libdisplay-info: 它是 drm GPU context 的唯一 gate
#    (meson.build:958-962), 缺了就没有 gpu-context=drm, 而且
#    mpv 二进制少一条 DT_NEEDED。这条同时兜住上面 wayland-protocols /
#    libdisplay-info 两个新段有没有真的生效。
# 同上一条, 这里也必须是整行精确匹配 —— 换行分隔的多行列表里,
# `case " $MPV_NEEDED "` 那种空格包边的 pattern 同样永远不成立。
if ! grep -qx 'libdisplay-info\.so\.2' <<< "$MPV_NEEDED"; then
  echo "断言失败: mpv 没有链接 libdisplay-info.so.2 —— features['drm'] 没开,"
  echo "  gpu-context=drm 不会有。自建的 libdisplay-info 没被探测到?"
  exit 1
fi
echo "  mpv -> libdisplay-info.so.2 (drm GPU context 已开)"
cd "$WORK"

# ---- 装进 stage -----------------------------------------------
# 全部从 $INSTALL_ROOT/usr/local 取 (一切安装都 DESTDIR 进了那里,
# 见本 step 开头的注释)。树形和镜像里 /usr/local 一模一样。
# 注意 libplacebo 在 aarch64 上是 multiarch 路径, 不是 lib/。
for d in usr/local/bin usr/local/lib usr/local/lib/aarch64-linux-gnu \
         usr/local/lib/pkgconfig root/.config/mpv etc/ld.so.conf.d; do
  mkdir -p "$STAGE/$d"
done

for b in mpv ffmpeg ffprobe; do
  if [ ! -e "$INSTALL_ROOT/usr/local/bin/$b" ]; then
    echo "断言失败: 没编出 $b"
    exit 1
  fi
  cp -a "$INSTALL_ROOT/usr/local/bin/$b" "$STAGE/usr/local/bin/"
done
# 库。注意 tar 保留符号链接 —— libavcodec.so.62 指向 .so.62.x.y,
# 只 cp 一层会断链。MPP 的 librockchip_mpp* 也在 lib/ 里但**不能**
# 带: 镜像里的 MPP 由 rockchip-multimedia.sh 提供, 带过去就是两份。
( cd "$INSTALL_ROOT/usr/local/lib" && find . -maxdepth 1 \
    \( -name 'libav*.so*' -o -name 'libsw*.so*' -o -name 'libshaderc_shared.so*' \) -print0 \
    | tar --null -cf - -T - ) \
  | ( cd "$STAGE/usr/local/lib" && tar xf - )
# 上面那条 libplacebo.so.360 的 NEEDED 断言只能证明"链上了", 不能证明
# "装在哪个目录" —— libplacebo 哪天改了 libdir (不再走 multiarch) 这条
# 也不会炸, 而下面那个 tar 会因为空输入报
#   tar: This does not look like a tar archive
# 报错指向打包, 根因却是装错了地方, 极难查。这里先把目录钉住。
if [ ! -d "$INSTALL_ROOT/usr/local/lib/aarch64-linux-gnu" ]; then
  echo "断言失败: $INSTALL_ROOT/usr/local/lib/aarch64-linux-gnu 不存在"
  echo "  libplacebo / libdisplay-info 没装到 multiarch 路径下 ——"
  echo "  它们改 libdir 了? 下面的 tar 只会报 'not a tar archive'，看不出真因"
  echo "  实际装到哪了:"
  # 不能用 `find ... | head` —— pipefail 下 head 先退、find 收 EPIPE
  # 返回 141, 脚本在 exit 1 之前就被掐掉, 报错正好被截掉。ls -d 无管道。
  ls -d "$INSTALL_ROOT"/usr/local/lib*/libplacebo.so* \
        "$INSTALL_ROOT"/usr/local/lib*/libdisplay-info.so* 2>/dev/null \
    || echo "  (压根没找到 libplacebo / libdisplay-info)"
  exit 1
fi
( cd "$INSTALL_ROOT/usr/local/lib/aarch64-linux-gnu" && find . -maxdepth 1 \
    \( -name 'libplacebo*' -o -name 'libdisplay-info*' \) -print0 | tar --null -cf - -T - ) \
  | ( cd "$STAGE/usr/local/lib/aarch64-linux-gnu" && tar xf - )
# 头文件和 .pc 给将来在板子上重编东西用。.pc 的 prefix 都是
# /usr/local (configure 时定的), 和镜像里的路径一致。MPP 的
# rockchip_*.pc 除外 —— 镜像里的 MPP 有自己的来源。
if [ -d "$INSTALL_ROOT/usr/local/include" ]; then
  cp -a "$INSTALL_ROOT/usr/local/include" "$STAGE/usr/local/"
fi
if [ -d "$INSTALL_ROOT/usr/local/lib/pkgconfig" ]; then
  find "$INSTALL_ROOT/usr/local/lib/pkgconfig" -maxdepth 1 \
       -name '*.pc' ! -name 'rockchip_*' \
       -exec cp -a {} "$STAGE/usr/local/lib/pkgconfig/" \;
fi

# ldconfig 必须知道去这两个地方找, 否则 mpv 一跑就
# "error while loading shared libraries: libplacebo.so.360"
# heredoc 会把 YAML 块标量截断 (heredoc 体顶格 <= 块缩进),
# 所以这里用 echo 组写文件, 全部行都留在 run 块内。
{
  echo '/usr/local/lib'
  echo '/usr/local/lib/aarch64-linux-gnu'
} > "$STAGE/etc/ld.so.conf.d/zz-armbian-local.conf"

# ---- udev 提权规则 -------------------------------------------
# VPU / Mali / HEVC / RGA 的设备节点默认是 root:root 0600, 非 root
# 用户 (video 组成员除外) 一律打不开。桌面会话现在是 root 跑, 所以
# 之前没暴露过; 一旦换成普通用户登录, hwdec 会静默退回软解, 日志里
# 只有一句 dlopen 失败, 极难查。
#
# 为什么不直接靠 packages/bsp/rockchip/: 那个目录下确实有
# 50-vpu.rules / 50-mali.rules / 50-hevc.rules / 60-media.rules,
# 但 packages/bsp/ 下**只有 rockchip 一个目录**, 没有
# rockchip-rk3568-z96a —— 而 BOARDFAMILY 正是后者。Armbian 按
# BOARDFAMILY 找 bsp 包时能不能回落到父家族 rockchip, 没有保证。
# 所以这里显式写一份进 overlay, 不赌那个回落。
mkdir -p "$STAGE/etc/udev/rules.d"
{
  echo '# MPP 视频转译层的服务节点。没有这条, 非 root 用户碰不到 VPU。'
  echo 'KERNEL=="vpu-service", MODE="0660", GROUP="video"'
  echo 'KERNEL=="mpp_service", MODE="0660", GROUP="video"'
  echo '# rkvdec2 走 stateless V4L2 暴露'
  echo 'KERNEL=="video*", MODE="0660", GROUP="video"'
  echo 'KERNEL=="media*", MODE="0660", GROUP="video"'
  echo '# Mali 渲染节点'
  echo 'KERNEL=="mali0", MODE="0660", GROUP="video"'
  echo 'KERNEL=="mali", MODE="0660", GROUP="video"'
  echo '# RGA2 缩放/格式转换'
  echo 'KERNEL=="rga", MODE="0660", GROUP="video"'
  echo '# rkvenc HEVC 编码服务'
  echo 'KERNEL=="hevc-service", MODE="0660", GROUP="video"'
} > "$STAGE/etc/udev/rules.d/50-z96a-multimedia.rules"
cat "$STAGE/etc/udev/rules.d/50-z96a-multimedia.rules"

# ---- yt-dlp ---------------------------------------------------
# 镜像里 apt 装的是 2023.03.04, 那个版本解析不了现在的 B站, 直接报
# "Unable to extract play info"。换官方独立二进制。
curl -fsSL -o "$STAGE/usr/local/bin/yt-dlp" "$YTDLP_URL"
chmod +x "$STAGE/usr/local/bin/yt-dlp"
"$STAGE/usr/local/bin/yt-dlp" --version

# ---- 默认配置 ------------------------------------------------
# hwdec=rkmpp 是零拷贝直通 (mpv-rkmpp-direct.patch): 解码器自建 RKMPP
# 设备, 直出 DRM PRIME, vo=gpu 的 dmabuf-interop-gl 导入 mali 纹理。
# 板上实测 rkvdec 利用率 4~13%, YouTube 播放 mpv CPU 8.9%。
# vo=gpu 走 libplacebo -> EGL -> Mali, gpu-api=opengl 不能换成 vulkan:
# 这台板子上 Vulkan 只有 llvmpipe。
# heredoc 会把 YAML 块标量截断 (heredoc 体顶格 <= 块缩进),
# 所以这里用 echo 组写文件, 全部行都留在 run 块内。
{
  echo '# 板子上实测: rkmpp-copy 硬解 51%, 直通(本补丁)预期 17~25%。'
  echo 'hwdec=rkmpp'
  echo 'gpu-api=opengl'
  echo 'vo=gpu'
  # B站/YouTube 常给 AV1 流, RK3568 无 AV1 硬解; b 只匹配音视频合一
  # 格式 (B站全是分离流, b 直接 "Requested format is not available"),
  # 要用 bv*。优先 avc1 (H.264, rkmpp 硬解实测), 回退排除 av01。
  echo 'ytdl-format=bv*[vcodec^=avc1]+ba/bv*[vcodec^=vp9]+ba/bv*[vcodec!^=av01]+ba/b'
  echo '# ytdl_hook 调 yt-dlp 时不带代理 -- YouTube 直连超时挂死 (板上实测:'
  echo '# yt-dlp 直连 124 失败 / 带 --proxy 0 成功)。写死在配置里兜底。'
  echo 'ytdl-raw-options=proxy=http://192.168.50.211:7893'
} > "$STAGE/root/.config/mpv/mpv.conf"

# pause-firefox.lua: Play with MPV 启动时通过 Firefox 的 MPRIS 接口
# 暂停页内视频, 释放 CPU 给 mpv (Firefox 同屏渲染会让 mpv 冲到 116%);
# mpv 退出时自动恢复播放。mpv 自动加载 ~/.config/mpv/scripts/ 下的 Lua。
mkdir -p "$STAGE/root/.config/mpv/scripts"
cat > "$STAGE/root/.config/mpv/scripts/pause-firefox.lua" << 'LUAEOF'
-- playerctl -a 遍历时对 Firefox 实例可能不生效 (B站页面用内嵌
-- audio 元素), 逐实例指定 -p 实测可靠。mpv 退出时恢复播放。
local utils = require 'mp.utils'

local function set_players(state)
    local r = utils.subprocess({ args = { 'playerctl', '--list-all' },
                                 capture_stdout = true })
    if r.status == 0 then
        for player in string.gmatch(r.stdout or '', '%S+') do
            utils.subprocess({ args = { 'playerctl', '-p', player, state },
                               playback_only = false })
        end
    end
end

mp.add_hook('on_preloaded', function() set_players('pause') end)
mp.register_event('shutdown', function() set_players('play') end)
LUAEOF

# ---- 自检: 产物齐不齐 ----------------------------------------
echo "=== stage 大小 ==="
du -sh "$STAGE"
# lua 必须编进 mpv: ytdl_hook 是 Lua 脚本, Play with MPV 靠它调
# yt-dlp 解析 B站/YouTube 网页。没 lua 的 mpv 直接播 URL 会
# "Failed to recognize file format" (release 200 板上实测)。
# 注意两点: ytdl_hook 的 Lua 源码无论是否启用 lua 都会嵌进二进制
# (strings 必然假阳性); 而在容器里裸跑 mpv 缺 INSTALL_ROOT 的库路径,
# 进程根本起不来 (--list-options 必挂, run 36961354049 的教训)。
# lua 启用与否看动态链接: mpv 链 libluajit = ytdl_hook 会加载。
if ! ldd "$STAGE/usr/local/bin/mpv" | grep -q luajit; then
  echo "断言失败: mpv 没编进 ytdl_hook (lua 缺失) -- Play with MPV 会废"
  exit 1
fi
for must in usr/local/bin/mpv usr/local/bin/ffmpeg usr/local/bin/yt-dlp \
           root/.config/mpv/mpv.conf etc/ld.so.conf.d/zz-armbian-local.conf \
           etc/udev/rules.d/50-z96a-multimedia.rules; do
  if [ ! -e "$STAGE/$must" ]; then
    echo "断言失败: stage 里缺 $must"
    exit 1
  fi
  echo "  有: $must"
done
if ! ls "$STAGE"/usr/local/lib/aarch64-linux-gnu/libplacebo.so* >/dev/null 2>&1; then
  echo "断言失败: stage 里没有 libplacebo"
  exit 1
fi
echo "  有: libplacebo"
if ! ls "$STAGE"/usr/local/lib/aarch64-linux-gnu/libdisplay-info.so.2* >/dev/null 2>&1; then
  echo "断言失败: stage 里没有 libdisplay-info.so.2 —— mpv 会因为找不到它起不来"
  exit 1
fi
echo "  有: libdisplay-info.so.2"
if ! ls "$STAGE"/usr/local/lib/libavcodec.so* >/dev/null 2>&1; then
  echo "断言失败: stage 里没有 libavcodec"
  exit 1
fi
echo "  有: libavcodec"
if [ ! -e "$STAGE/usr/local/lib/libshaderc_shared.so.1" ]; then
  echo "断言失败: stage 里没有 libshaderc_shared.so.1 —— libplacebo 在镜像里会加载失败"
  exit 1
fi
echo "  有: libshaderc_shared.so.1"
# 终极断言: 逐个用 ldd 过一遍会进镜像的动态库和可执行文件,
# 任何 "not found" 都意味着镜像里一跑就挂。镜像里唯一的库路径
# 是 /usr/local/lib + /usr/local/lib/aarch64-linux-gnu
# (zz-armbian-local.conf) 加上发行版自己的库, ldd 在 runner 上
# 解析不了发行版路径之外的, 所以把 STAGE 两个目录也挂进查找路径。
echo "=== ldd 全量核对 ==="
export LD_LIBRARY_PATH="$STAGE/usr/local/lib:$STAGE/usr/local/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}"
for f in "$STAGE"/usr/local/bin/mpv "$STAGE"/usr/local/bin/ffmpeg \
         "$STAGE"/usr/local/lib/aarch64-linux-gnu/libplacebo.so*; do
  MISS=$(ldd "$f" 2>&1 | grep 'not found' || true)
  if [ -n "$MISS" ]; then
    echo "断言失败: $f 有解析不了的动态依赖:"
    echo "$MISS"
    exit 1
  fi
done
echo "  ldd 全部可解析"
echo "mpv/ffmpeg/libplacebo 已备好, 待随镜像装入"

