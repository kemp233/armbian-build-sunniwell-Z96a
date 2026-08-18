# Z96a power / GPU rail policy (from board bring-up)

## Finding
- Main idle heat source when DVFS/idle work: **RK809 `vdd_gpu` (DCDC_REG2)** left always-on.
- Mali/panfrost stacks enable `vdd_gpu` for GPU PM; DT `regulator-always-on` prevents real power-off.
- Do **not** disable `vdd_logic` / `vcc_ddr` / `vdda_0v9` (system hang: `vcc_ddr: disabling`).

## DT policy applied in tree
- `vdd_gpu` (`DCDC_REG2`): **remove `regulator-always-on` / `regulator-boot-on`** (GPU can still probe; runtime can drop rail).
- CPU `clocks`: **`scmi_clk 0`** (not `cru 0`) so `rockchip-cpufreq`/`cpufreq-dt` get clock.
- `gpu-thermal`: must include **trips** or rockchip-thermal probe fails for sensor id=1.
- Thermal trips default safe: passive ~75/85°C, critical ~115°C.

## Kernel
- Edge: `CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y`, `CONFIG_ARM_ROCKCHIP_CPUFREQ=y`, `CONFIG_REGULATOR_RK808=y`, `CONFIG_ROCKCHIP_THERMAL=y`.
- 5.10 vendor image analysis: Mali modules explicitly `enable vdd_gpu` + OPP/devfreq; same DT always-on issue.

## U-Boot
- Avoid boot.cmd MMIO/gpio force of USB VBUS enable pins for thermal baselines (re-enables 5V rails).
