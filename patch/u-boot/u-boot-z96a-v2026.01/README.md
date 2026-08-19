# Z96A U-Boot 2026.01 (kemp233/u-boot-1 @ rockchip-v2026.01)

Board: z96a-rk3568-laptop-v2_defconfig / rk3568-z96a-laptop-v2.dts

Already in upstream branch (no extra patches required here):
- gpio3/4 usable (mainline tree)
- factory adc-keys + vcca_1v8 saradc vref (757e34dc)
- dnl-key false-positive reboot disabled (5c2c1142)

Do not add a boot_mode.c patch here — source already has the fix; a
stale unidiff will fail apply ("Hunk is longer than expected").
