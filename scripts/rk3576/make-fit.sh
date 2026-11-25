#!/usr/bin/env bash
# Rebuild the validated RK3576 U-Boot FIT from small blobs + freshly built u-boot.bin.
set -euo pipefail
DIR="$1"          # blob directory (packages/blobs/rockchip/rk3576)
UBOOT="$2"        # freshly built u-boot.bin
OUT="$3"          # output .itb
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Pre-extracted raw payloads from the validated vendor FIT.
cp "$DIR/atf-1.bin" "$WORK/atf-1.bin"
cp "$DIR/tee.bin" "$WORK/optee.bin"
cp "$DIR/atf-2.bin" "$WORK/atf-2.bin"
cp "$DIR/atf-3.bin" "$WORK/atf-3.bin"
cp "$DIR/fdt.dtb" "$WORK/fdt.dtb"
cp "$UBOOT" "$WORK/u-boot.bin"

cat > "$WORK/rk3576.its" <<'ITS'
/dts-v1/;
/ {
    description = "RK3576 mainline U-Boot with vendor secure firmware";
    #address-cells = <1>;
    images {
        uboot {
            description = "Mainline U-Boot";
            data = /incbin/("u-boot.bin");
            type = "standalone";
            arch = "arm64";
            os = "u-boot";
            compression = "none";
            load = <0x40200000>;
            entry = <0x40200000>;
            hash { algo = "sha256"; };
        };
        atf-1 {
            description = "ARM Trusted Firmware primary";
            data = /incbin/("atf-1.bin");
            type = "firmware";
            arch = "arm64";
            os = "arm-trusted-firmware";
            compression = "none";
            load = <0x40060000>;
            entry = <0x40060000>;
            hash { algo = "sha256"; };
        };
        atf-2 {
            description = "ARM Trusted Firmware secondary";
            data = /incbin/("atf-2.bin");
            type = "firmware";
            arch = "arm64";
            os = "arm-trusted-firmware";
            compression = "none";
            load = <0x400f0000>;
            hash { algo = "sha256"; };
        };
        atf-3 {
            description = "ARM Trusted Firmware PM";
            data = /incbin/("atf-3.bin");
            type = "firmware";
            arch = "arm64";
            os = "arm-trusted-firmware";
            compression = "none";
            load = <0x3fe70000>;
            hash { algo = "sha256"; };
        };
        optee {
            description = "OP-TEE";
            data = /incbin/("optee.bin");
            type = "firmware";
            arch = "arm64";
            os = "tee";
            compression = "none";
            load = <0x48400000>;
            entry = <0x48400000>;
            hash { algo = "sha256"; };
        };
        fdt {
            description = "RK3576 DTB";
            data = /incbin/("fdt.dtb");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            hash { algo = "sha256"; };
        };
    };
    configurations {
        default = "conf";
        conf {
            description = "RK3576 mainline U-Boot";
            firmware = "atf-1";
            loadables = "uboot", "atf-2", "atf-3", "optee";
            fdt = "fdt";
        };
    };
};
ITS

mkimage -f "$WORK/rk3576.its" -A arm64 -T rksd -n rk3576-dev "$OUT"
echo "Built FIT: $OUT ($(stat -c %s "$OUT") bytes)"
sha256sum "$OUT"
