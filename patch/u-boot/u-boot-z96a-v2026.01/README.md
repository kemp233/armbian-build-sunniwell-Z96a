# U-Boot z96a v2026.01 notes

Source: https://github.com/kemp233/u-boot-1 branch rockchip-v2026.01

Board files (V2):
- configs/z96a-rk3568-laptop-v2_defconfig
- dts: rockchip/rk3568-z96a-laptop-v2.dts
- u-boot dtsi: rk3568-z96a-laptop-v2-u-boot.dtsi

Armbian:
- BOOTCONFIG=z96a-rk3568-laptop-v2_defconfig
- Linux BOOT_FDT_FILE=rockchip/rk3568-z96a-laptop-v2.dtb (kernel DTB, separate)
