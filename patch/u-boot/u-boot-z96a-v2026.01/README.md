# Z96A U-Boot 2026.01 patches

Source: kemp233/u-boot-1 @ rockchip-v2026.01

## HAL sync (mandatory)
Canonical DT lives in:
`config/boards/hal/z96a-rk3568-laptop-v2/uboot/`

- `rk3568-z96a-laptop-v2.dts` — Recovery **thr=9**, SARADC ch0 volume-up
- Injected by `z96a-hal-inject-dt.patch.sh` and family hook
  `pre_config_uboot_target__z96a_hal_inject_dt`

Do **not** hand-edit thr to 0x6d6/1750. Edit HAL then:
`./config/boards/hal/z96a-rk3568-laptop-v2/scripts/sync-hal-into-trees.sh`
