# Z96A U-Boot 2026.01 patches

Source: kemp233/u-boot-1 @ rockchip-v2026.01

- 0001-disable-dnl-key-false-positive-reboot.patch
  After adc vref fix, SARADC ch1 idle false-triggers download mode reset loop.
  Disables rockchip_dnl_key_pressed() default heuristic.

Board DT in u-boot-1 already has:
- vcca_1v8 + saradc vref-supply
- factory adc-keys (volume up / Recovery) on ch0
