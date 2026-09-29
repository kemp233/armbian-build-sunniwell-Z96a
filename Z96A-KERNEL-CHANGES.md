# Z96A 内核改动清单

Z96A 对内核的改动分两处存放，不要再往 `patch/kernel/rockchip-rk3568-z96a/legacy/`
里加 `.patch` 了。

## 一、内核代码改动 → 在 linux-rockchip 里

`kemp233/linux-rockchip` 的 **`rk-6.1-rkr7.2`** 分支。板配置
`config/boards/z96a-v2.conf` 的 `KERNELBRANCH='branch:rk-6.1-rkr7.2'` 直接指向
它，所以往那个分支推的东西下一次 CI 自动带进镜像。

并入的提交：**`c16c640e45a9`**（基线 `2d29659b3022`）。

| 原 Armbian 补丁 | 落在内核树的哪个文件 | 修的是什么 |
|---|---|---|
| `0001-wifi-add-rtl8822cs-driver-for-z96a` | `drivers/net/wireless/rockchip_wlan/rkwifi/{Kconfig,Makefile}` | 板载 SDIO RTL8822CS |
| `0002-wifi-add-rtl8852bu-driver-for-z96a` | `drivers/net/wireless/{Kconfig,Makefile}` | USB RTL8852BU（0bda:b832） |
| `0004-dma-buf-downgrade-vmapping-counter-bugon-to-warnon` | `drivers/dma-buf/dma-buf.c` | 计数溢出 BUGON 降级为 WARNON |
| `0005-panel-simple-honor-DT-bus-format` | `drivers/gpu/drm/panel/panel-simple.c` | 读 DT 的 `bus-format` **和 `bpc`** |
| `0006-rockchip-pmu-idle-ack-timeout-non-fatal` | `drivers/soc/rockchip/pm_domains.c` | idle-ack 超时不再致命 |
| `0007-rockchip-battery-z96a-saradc-gauge` | `drivers/power/supply/rk817_battery.c` | SARADC 2S 电量计 |
| `0008-rockchip-charger-sc8886s-builtin` | `drivers/power/supply/{Kconfig,Makefile}` | SC8886S 充电 IC builtin |
| `0009-rknpu-dmabuf-lifetime-fix` | `drivers/rknpu/{rknpu_drv.c,rknpu_mem.c}` | dma_buf 生命周期 |
| `z96a_cec_deadlock` | `drivers/gpu/drm/bridge/synopsys/dw-hdmi.c` | CEC 死锁 |

`build-with-mali.yml` 的 "Verify complete customizations" 里有一条断言守着这个
约定：`legacy/` 下一旦出现 `.patch` 就构建失败。

## 二、板级数据 → 留在本仓库

这些不是补丁，是板数据，通过 `0000.patching_config.yaml` 的
`dts-directories` 机制**原样拷贝**到内核树的 `arch/arm64/boot/dts/rockchip/`。

- `patch/kernel/rockchip-rk3568-z96a/legacy/0000.patching_config.yaml` —— 提供该机制
- `patch/kernel/rockchip-rk3568-z96a/legacy/dt/` —— 五份板级 DTS
- `patch/kernel/rockchip-rk3568-z96a/legacy/drivers/power/supply/sc8886s_charger.c` —— 驱动源文件参考副本
- `config/kernel/linux-rockchip-rk3568-z96a-legacy.config` —— 内核配置
- `config/boards/*.conf` —— 板配置（`custom/config/boards/` 那份是历史死副本，`build-with-mali.yml` 不取）

`0003-gmac-rxid-delay-grf-order.patch.disabled` 和
`otp-clock-names-fix.patch.disabled` 是历史上就没启用的，保持原样。

## 三、为什么改这个存放位置

补丁方式已经出过两次"补丁干净地打进去、干净地没生效"的事故：

- `0008` 的 hunk 头写 `@@ -0,0 +1,424 @@` 而正文 426 行，`git apply` 静默丢掉
  `MODULE_DESCRIPTION` / `MODULE_LICENSE`，补丁里的文件和真正的源文件对不上。
- `0005` 的前提是错的——以为 Z96A 的 eDP encoder 是 analogix_dp（会取
  `display_info.bus_formats[0]`），实际是 rockchip DP core，它的
  `cdn_dp_encoder_atomic_check()` 只 `switch (display_info.bpc)`。补丁打得
  干干净净，一点作用没有。

并进内核树之后只剩一份代码，不存在"补丁没打上"这种中间态。
代价是：将来换内核分支时，这 9 处要手工 port 一次。换分支本来也要把 9 个补丁
重新验一遍，所以这个代价是持平的。

## 四、换内核分支时

1. 新分支建好后，把上面表格里的 9 处改动在新分支上重做一遍（`git cherry-pick
   c16c640e45a9` 大概率会冲突，因为这些文件在新分支上也会动）。
2. 更新所有 `config/boards/*.conf` 里的 `KERNELBRANCH`。
3. 更新 `patch/kernel/rockchip-rk3568-z96a/legacy/dt/` 里的 DTS。
4. 本文件第一节的基线 commit 要跟着更新。
