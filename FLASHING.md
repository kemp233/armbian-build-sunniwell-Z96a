# RKDevTool 刷机指南 — z96a-rk3568-laptop (Armbian 26.5.1 minimal)

## 文件准备

从 release 下载 `.img.xz` → 解压后提取 3 个分区文件：

```bash
# 解压（约 2.7GB 空间）
xz -dk Armbian-unofficial_26.5.1_Z96a-rk3568-laptop_jammy_legacy_5.10.160_minimal.img.xz

# 查看分区偏移
fdisk -lu Armbian-unofficial_26.5.1_Z96a-rk3568-laptop_jammy_legacy_5.10.160_minimal.img

# 提取 bootloader 区（前 16MB，含 idbloader + uboot + trust）
dd if=image.img of=idb_uboot.bin bs=1M count=16

# 提取 boot 分区（通常 256MB，从 fdisk 显示的 boot 分区起始偏移算）
dd if=image.img of=bootfs.img bs=512 skip=59392 count=524288

# 提取 rootfs 分区（从 fdisk 显示的 rootfs 分区起始偏移到末尾）
dd if=image.img of=rootfs.img bs=512 skip=3354624
```

## RKDevTool 配置

### config.ini（放 idb_uboot.bin, bootfs.img, rootfs.img 同目录）

```ini
[CMD]
force=1

[PARAMETER]
FIRMWARE_VER=11.0
MACHINE_MODEL=RK3568
MACHINE_ID=007
MANUFACTURER=RK3568

[LIST_NORMAL]
# 扇区偏移(512B/扇区), 分区名, 文件路径
0x40@idbloader@idb_uboot.bin
0x4000@uboot@idb_uboot.bin
0x8000@trust@idb_uboot.bin
0xe800@boot@bootfs.img
0x333000@rootfs@rootfs.img
```

偏移说明（与 parameter.txt 一致）：
| 分区 | 起始扇区 | 偏移量 | 大小 | 文件 |
|---|---|---|---|---|
| idbloader | 0x40 (64) | 32KB | 16MB | idb_uboot.bin |
| uboot | 0x4000 (16384) | 8MB | (含在 idb_uboot.bin) | idb_uboot.bin |
| trust | 0x8000 (32768) | 16MB | (含在 idb_uboot.bin) | idb_uboot.bin |
| boot | 0xe800 (59392) | ~29MB | 256MB | bootfs.img |
| rootfs | 0x333000 (3354624) | ~1.6GB | 剩余空间 | rootfs.img |

## 刷机步骤

### 1. 设备进入 Loader 模式
- **方法 A**（推荐，有 Recovery 键）：按住 Recovery → 插 USB-C（OTG 口）→ 上电 → 松 Recovery
- **方法 B**（Maskrom 模式）：短接 eMMC CLK 或 EMMC_D0 到 GND → 上电 → 插 USB-C
- **方法 C**（从已有系统进入）：`adb reboot loader` 或 `rkdeveloptool rd`

### 2. RKDevTool 操作
1. 打开 RKDevTool
2. 点 **Advanced Function** 标签
3. 点 **Download Image** 页面
4. 点 **Load Config** → 选中 `config.ini`
5. 确认每个分区文件路径正确
6. 点 **Run** → 进度条走完
7. 设备自动重启（或手动拔电重插）

### 3. 验证
- 串口日志看到 `U-Boot 2017.09-armbian` + 内核启动
- SSH 或 HDMI 进入 Armbian 桌面/终端

## 替代方案：整盘刷（最简单）

不拆分区，直接刷整个镜像：
1. RKDevTool → Advanced → Download Image
2. 只加一行：地址 `0x0`，文件选完整 `.img`
3. 点 Run

## 注意事项
- **rk3568 用 rk3566 的 loader**（`rk3566_spl_loader_v1.14.113.bin`），只需 Maskrom 模式才需要
- USB 线必须插 **OTG 口**（通常是 USB-C 靠近网口那一侧），侧边 USB 口不行
- 如果刷完不启动，检查 dtb 文件名：`BOOT_FDT_FILE="rockchip/rk3568-z96a.dtb"`
```