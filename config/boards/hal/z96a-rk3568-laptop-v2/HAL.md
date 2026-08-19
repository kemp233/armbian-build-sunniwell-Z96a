# Z96A V2 HAL contract (single source of truth)

U-Boot (`kemp233/u-boot-1`) and Kernel (`linux-rockchip`) are **different git trees**.
Without enforcement they drift (e.g. Recovery thr `9` vs `1750` / `0x6d6`).

## Board
- SoC: RK3568
- PMIC: RK809-5 on i2c0@20 (driver may log as rk808, chip id 0x8090)
- Silkscreen Recovery = SARADC **ch0** volume-up (not Android recovery partition)

## Must-match fields

| Item | Value |
|------|--------|
| adc-keys channel | saradc **0** |
| label | `volume up` |
| linux,code | KEY_VOLUMEUP (0x73) |
| press-threshold-microvolt | **9** |
| keyup-threshold-microvolt | **1800000** |
| CPU clocks | SCMI `protocol@14` clock 0 (`<&scmi_clk 0>` / phandle clocks = <0x02 0>) |
| cpu-supply | **vdd_logic** (RK809 DCDC_REG1) — no separate vdd_cpu rail on V2 |
| GPU mali-supply / NPU supply | **vdd_gpu** (DCDC_REG2) when enabled |
| SCMI voltage protocol 0x16 | **not required** (ATF often inactive); regulators via RK809 |
| SCMI sensor protocol 0x11 | **not required**; SoC temp = TSADC MMIO |

## Roles
- **U-Boot DT**: early ADC key → download/Maskrom; minimal bus bring-up
- **Kernel DT**: full SoC graph; must not contradict HAL key/clock/supply
- **boot.cmd**: last-resort fdt set for SCMI cpu clocks if tree regresses

## Sync mechanism
1. Files under `config/boards/hal/z96a-rk3568-laptop-v2/` are canonical.
2. Family hooks copy U-Boot DT into the U-Boot build tree before compile.
3. Kernel edge/legacy board DTS must include the same adc-keys + SCMI cpu clocks.
4. CI `scripts/check-hal-sync.sh` **fails the build** on mismatch.
