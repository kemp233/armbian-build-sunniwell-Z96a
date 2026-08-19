# Z96A U-Boot 2026.01

Source of truth: kemp233/u-boot-1 @ rockchip-v2026.01

Recovery/download key:
- Factory = SARADC **ch0** adc-keys ("volume up" / "Recovery"), pressed ~0V
- Do **not** use ch1 raw 0..30 (idle false reboot after vref fix)
- Implemented in rockchip_dnl_key_pressed() via BUTTON + ch0 raw<=40

No local broken unidiff here (Armbian patch apply is fragile). Tree pulls u-boot-1.
