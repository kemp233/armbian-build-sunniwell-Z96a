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
  python3-mako python3-jinja2 \
  libssl-dev \
  libvulkan-dev \
  libegl1-mesa-dev libgles2-mesa-dev libgbm-dev libdrm-dev \
  libx11-dev libxrandr-dev libxcb1-dev libxcb-dri2-0-dev \
  libxcb-dri3-dev libxcb-present-dev libxcb-sync-dev \
  libxcb-xfixes0-dev libxxf86vm-dev libxext-dev libxfixes-dev \
  wayland-protocols libxkbcommon-dev libwayland-dev \
  libass-dev libfreetype-dev libharfbuzz-dev libfribidi-dev \
  libvorbis-dev libopus-dev libopusfile-dev \
  libflac-dev libmpg123-dev libspeex-dev

# ---- 版本钉死 -------------------------------------------------
# 全部钉到具体 commit/tag, 不用分支头。上游一动这里就炸, 总比
# 悄悄编出一个不同的东西好。
FFMPEG_REPO=https://github.com/nyanmisaka/ffmpeg-rockchip.git
FFMPEG_COMMIT=d90e3a1
LIBPLACEBO_TAG=v6.338.2
MPV_TAG=v0.38.0
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

# ---- mpv 0.38 -------------------------------------------------
# 三个补丁, 全是 FFmpeg 7.x 的 API 变更, 每一个都断言改了行数 ——
# 上游一变 sed 没匹配上, 必须当场炸, 不能编出个看着成功、
# 实际跑起来才崩的东西。
git clone --depth 1 --branch "$MPV_TAG" https://github.com/mpv-player/mpv.git mpv
cd mpv
# (1) FF_PROFILE_* 在 FFmpeg 7 里改名成 AV_PROFILE_*。
for f in audio/decode/ad_spdif.c demux/demux_mkv.c; do
  before=$(grep -c 'FF_PROFILE_' "$f" || true)
  [ "$before" -gt 0 ] || { echo "断言失败: $f 里没有 FF_PROFILE_ 了, 补丁该撤"; exit 1; }
  sed -i 's/\bFF_PROFILE_/AV_PROFILE_/g' "$f"
  echo "  $f: FF_PROFILE_ -> AV_PROFILE_ ($before 处)"
done
# (2) av_format_inject_global_side_data() 连同整个 global side data
#     API 一起被上游删了。mpv 本来就直接从 stream side data 读
#     DoVi 配置, 删掉这行不影响行为。
if grep -q 'av_format_inject_global_side_data' demux/demux_lavf.c; then
  n=$(grep -c 'av_format_inject_global_side_data' demux/demux_lavf.c)
  sed -i '/av_format_inject_global_side_data(avfc);/d' demux/demux_lavf.c
  echo "  demux_lavf.c: 删掉 av_format_inject_global_side_data ($n 处)"
else
  echo "  demux_lavf.c: 上游已经不需要这行了, 跳过"
fi
meson setup build \
  -Dprefix=/usr/local \
  -Dgpl=true \
  -Dlibmpv=true
# 这里**不能**加 -Dcplayer=false。run 36656011005: libmpv.so.2.3.0
# 编出来装好了, 断言"没编出 mpv" —— cplayer=false 把 mpv 命令行
# 二进制整个关了, 而 stage 自检、ldd 核对、镜像里的 Play with MPV
# (mpv-handler 调的是 mpv 可执行文件, 不是 libmpv) 全都要那个
# 二进制。和 --disable-programs 同一天、同一个 commit 引入的同类
# 矛盾, 也是直到前面的关全过完才第一次被走到。
meson compile -C build
DESTDIR="$INSTALL_ROOT" meson install -C build
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
    \( -name 'libav*.so*' -o -name 'libsw*.so*' -o -name 'libshaderc.so*' \) -print0 \
    | tar --null -cf - -T - ) \
  | ( cd "$STAGE/usr/local/lib" && tar xf - )
( cd "$INSTALL_ROOT/usr/local/lib/aarch64-linux-gnu" && find . -maxdepth 1 \
    -name 'libplacebo*' -print0 | tar --null -cf - -T - ) \
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
# "error while loading shared libraries: libplacebo.so.338"
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
# hwdec=rkmpp 是硬解的开关。vo=gpu 走 libplacebo -> EGL -> Mali,
# gpu-api=opengl 不能换成 vulkan: 这台板子上 Vulkan 只有 llvmpipe,
# 换过去反而变软解。
# heredoc 会把 YAML 块标量截断 (heredoc 体顶格 <= 块缩进),
# 所以这里用 echo 组写文件, 全部行都留在 run 块内。
{
  echo '# 板子上实测: 硬解 17.2% CPU, 软解 90.8%。'
  echo 'hwdec=rkmpp'
  echo 'gpu-api=opengl'
  echo 'vo=gpu'
} > "$STAGE/root/.config/mpv/mpv.conf"

# ---- 自检: 产物齐不齐 ----------------------------------------
echo "=== stage 大小 ==="
du -sh "$STAGE"
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
if ! ls "$STAGE"/usr/local/lib/libavcodec.so* >/dev/null 2>&1; then
  echo "断言失败: stage 里没有 libavcodec"
  exit 1
fi
echo "  有: libavcodec"
if [ ! -e "$STAGE/usr/local/lib/libshaderc_shared.so.1" ]; then
  echo "断言失败: stage 里没有 libshaderc_shared.so.1 —— libplacebo 在镜像里会加载失败"
  exit 1
fi
echo "  有: libshaderc.so.1"
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

