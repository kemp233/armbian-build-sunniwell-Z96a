#!/usr/bin/env python3
"""给 mpv 打补丁: 恢复 mpv 0.38 的 hwdec 设备查找语义, 否则 rkmpp 硬解静默失效。

用法: patch-mpv-rkmpp-hwdec.py <mpv 源码目录>

背景
----
mpv 0.41 把 video/decode/vd_lavc.c 里挑 hwdec 设备的查找从

    hwdec_devices_get_by_imgfmt(ctx->hwdec_devs, imgfmt)

换成了

    hwdec_devices_get_by_imgfmt_and_type(ctx->hwdec_devs, imgfmt,
                                         hwdec->lavc_device)

并且把 video/hwdec.c 里前一个函数整个删掉了 (v0.38 到现在都没再回来)。
新增的类型过滤是按设备真正创出来的 AVHWDeviceContext.type 匹配的:

    if (dev->hw_imgfmt == hw_imgfmt &&
        (!hw_device_ctx || hw_device_ctx->type == device_type))

rkmpp 这类 hwaccel 在上游**从来没有**专用 wrapper —— video/out/hwdec/
下只有 cuda / vaapi / vulkan / drmprime / drmprime_overlay,
rkmpp 一直是走 FFmpeg 的通用 hwaccel 路径, 设备由 VO 的 drmprime
wrapper 代建。而那个 wrapper 在 0.41 还被标上了

    .device_type = AV_HWDEVICE_TYPE_DRM,     (video/out/hwdec/hwdec_drmprime.c:310)

于是按 RKMPP 去查一个报 DRM 类型的设备必然落空, hwdec_create_dev()
返回 NULL, select_and_set_hwdec() 打印一句

    [vd] Could not create device.

然后 continue 掉 —— 注意它 continue 掉的那一段正是**唯一**会反过来
让 VO 去建设备的 hwdec_imgfmt_request 分支, 所以后面连补救的机会都
没有, 整条路径静默退回软解。

现象 (Z96A, 板载实测, 同一份视频同一组参数, 只换 mpv 版本):
    mpv 0.38 + libplacebo 6.338.2   Using hardware decoding  drm_prime[nv12]
    mpv 0.41 + libplacebo 7.360.1   (无)  Using software decoding  yuv420p
最难查的地方是它**不报错**: 没有一帧渲染失败, 日志干干净净, 只有
"Using software decoding" 一行 —— 板子上 CPU 从 17% 涨到 90%。

补丁
----
把按格式查的函数加回来, 并在按类型查落空时回退用它 —— 也就是恢复
v0.38 的行为。每一处替换都断言匹配数, 上游一变就当场炸, 不会编出
一个看着成功、实际悄悄退回软解的 mpv。

注意没有去放宽 video/hwdec.c 里那个匹配条件: 它还有另外两个调用方
(filters/filter.c:705 和 video/filter/vf_d3d11vpp.c:593), 改了会
连 hwupload 那条链一起放宽, 牵连面比这里大。
"""

import os
import sys


def patch(relpath, old, new, expect=1):
    path = os.path.join(SRC, relpath)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    found = text.count(old)
    if found != expect:
        sys.exit(
            "断言失败: %s 里匹配到 %d 处, 期望 %d 处 —— 上游已经变了, "
            "这个补丁该重新评估 (大概率 rkmpp 的问题上游修了)" % (relpath, found, expect)
        )
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace(old, new))
    print("  %s: 打了 %d 处补丁" % (relpath, found))


if len(sys.argv) != 2:
    sys.exit("用法: %s <mpv 源码目录>" % sys.argv[0])
SRC = os.path.abspath(sys.argv[1])

# 目录本身先验一遍, 别让下面那句 open() 抛裸 traceback。
# run 36909362820 就是这么死的: 调用点在 `cd mpv` 之后, 传进来的
# "mpv" 被拼成 $WORK/mpv/mpv, 于是
#   FileNotFoundError: [Errno 2] No such file or directory: 'mpv/video/hwdec.h'
# 看着像补丁脚本坏了, 其实是调用点传错了路径。顺手把实际 CWD 一起打出来,
# 这种"路径相对谁的 CWD"的错一眼就能看出来。
for _probe in ("meson.build", "video/hwdec.h", "video/hwdec.c",
               "video/decode/vd_lavc.c"):
    if not os.path.isfile(os.path.join(SRC, _probe)):
        sys.exit(
            "不是 mpv 源码目录: %s 下找不到 %s\n"
            "  传入参数 : %s\n"
            "  解析成   : %s\n"
            "  当前 CWD : %s\n"
            "  调用点已经在 `cd mpv` 之后, CWD 就是源码根, 所以这里要传 `.` "
            "或绝对路径; 传相对的 \"mpv\" 会被拼成 <源码根>/mpv/..." % (
                SRC, _probe, sys.argv[1], SRC, os.getcwd(),
            )
        )

# 幂等守卫。三处替换的锚点在打过补丁之后**依然**匹配 (hwdec.c 的插入点
# 在锚点之前, vd_lavc.c 的 old 是 new 的前缀), 所以光靠"匹配数 == 1"
# 拦不住二次应用 —— 实测第二次照样打上, 结果是同一个函数被定义两遍,
# 编译期才炸, 报错信息还指向别处。所以先显式查一遍。
if "hwdec_devices_get_by_imgfmt(" in open(
    os.path.join(SRC, "video/hwdec.h"), encoding="utf-8"
).read():
    sys.exit(
        "这个源码目录已经打过补丁了 (video/hwdec.h 里已有 "
        "hwdec_devices_get_by_imgfmt 的声明)。补丁设计成只对干净的树跑, "
        "重复应用会定义出两个同名函数 —— 先 git checkout 还原再打。"
    )

# 1) 把按格式查的函数加回来 (v0.38 有, v0.41 删了)
patch(
    "video/hwdec.c",
    "\nstruct mp_hwdec_ctx *hwdec_devices_get_by_imgfmt_and_type(",
    """
struct mp_hwdec_ctx *hwdec_devices_get_by_imgfmt(struct mp_hwdec_devices *devs,
                                                 int hw_imgfmt)
{
    struct mp_hwdec_ctx *res = NULL;
    mp_mutex_lock(&devs->lock);
    for (int n = 0; n < devs->num_hwctxs; n++) {
        struct mp_hwdec_ctx *dev = devs->hwctxs[n];
        if (dev->hw_imgfmt == hw_imgfmt) {
            res = dev;
            break;
        }
    }
    mp_mutex_unlock(&devs->lock);
    return res;
}

struct mp_hwdec_ctx *hwdec_devices_get_by_imgfmt_and_type(""",
)

# 2) 补声明
patch(
    "video/hwdec.h",
    "struct mp_hwdec_ctx *hwdec_devices_get_by_imgfmt_and_type(struct mp_hwdec_devices *devs,",
    "struct mp_hwdec_ctx *hwdec_devices_get_by_imgfmt(struct mp_hwdec_devices *devs,\n"
    "                                                 int hw_imgfmt);\n"
    "struct mp_hwdec_ctx *hwdec_devices_get_by_imgfmt_and_type(struct mp_hwdec_devices *devs,",
)

# 3) 调用点回退
patch(
    "video/decode/vd_lavc.c",
    """        const struct mp_hwdec_ctx *hw_ctx =
            hwdec_devices_get_by_imgfmt_and_type(ctx->hwdec_devs, imgfmt,
                                                 hwdec->lavc_device);
""",
    """        const struct mp_hwdec_ctx *hw_ctx =
            hwdec_devices_get_by_imgfmt_and_type(ctx->hwdec_devs, imgfmt,
                                                 hwdec->lavc_device);
        // 上游在 0.41 把这里换成了带类型的查找, 并删掉了按格式查的函数。
        // rkmpp 这类没有专用 wrapper 的 hwaccel 按类型必然匹配不上, 于是
        // "Could not create device." 然后静默退回软解。按格式查兜底,
        // 行为与 mpv 0.38 一致。详见 patch-mpv-rkmpp-hwdec.py 的文件头。
        if (!hw_ctx)
            hw_ctx = hwdec_devices_get_by_imgfmt(ctx->hwdec_devs, imgfmt);
""",
)

print("rkmpp hwdec 补丁打完")