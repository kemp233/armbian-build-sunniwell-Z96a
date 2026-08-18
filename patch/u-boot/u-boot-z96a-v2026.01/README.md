# Z96A U-Boot 2026.01 (kemp233/u-boot-1)

Source: https://github.com/kemp233/u-boot-1 branch `rockchip-v2026.01`

Board (V2):
- defconfig: `z96a-rk3568-laptop-v2_defconfig`
- DT: `rockchip/rk3568-z96a-laptop-v2.dts`
- u-boot dtsi: `rk3568-z96a-laptop-v2-u-boot.dtsi`

Armbian packaging (binman, like nanopi-r5s):
```
ROCKCHIP_TPL=$RKBIN/$DDR_BLOB BL31=$RKBIN/$BL31_BLOB \
  make spl/u-boot-spl u-boot.bin flash.bin
# package artifacts: idbloader.img u-boot.itb
```

Not radxa 2017.09. Linux DTB remains `rk3568-z96a-laptop-v2.dtb` from kernel.
