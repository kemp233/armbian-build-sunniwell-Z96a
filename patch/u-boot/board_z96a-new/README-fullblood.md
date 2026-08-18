# Z96A full-blood U-Boot patches

## Why
Stock Armbian/radxa U-Boot on board only probes **gpio0/1/2** in `rk3568-u-boot.dtsi`.
Result from serial PROBE:
- `gpio set 110/111/106` → not found (GPIO3)
- `gpio set 147+` → not found (GPIO4)
- i2c buses empty (-19)
- `adc` CLI missing (SARADC may still probe)

## Patches
1. `add-full-uboot-commands.patch` — CMD_GPIO/I2C/ADC/DM/REGULATOR/PMIC + BOOTDELAY
2. `enable-gpio3-gpio4-i2c0-saradc.patch` — enable &gpio3 &gpio4 &i2c0 in rk3568-u-boot.dtsi

## Build
GitHub Actions: **Build U-Boot Only (z96a-new)**
- board: z96a-rk3568-laptop-v2
- branch: legacy (or current/edge — same radxa u-boot)
- clean_level: make-uboot (recommended first fullblood build)

## After flash
Expect U-Boot prompt `U-Boot Z96A>` and:
- `gpio status -a` shows gpio3/gpio4 banks
- `gpio set 110` / `gpio set 111` work
- `i2c bus` / `i2c dev 0` / `i2c probe` see 0x20 (RK809), 0x4e (HUSB) if wired
- `adc list` available if CMD_ADC linked
