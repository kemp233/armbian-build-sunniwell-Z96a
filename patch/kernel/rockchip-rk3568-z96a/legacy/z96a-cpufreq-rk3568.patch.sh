#!/bin/bash
set -e
FILE="drivers/cpufreq/rockchip-cpufreq.c"

if grep -q 'rockchip,rk3568' "$FILE"; then
  echo "rk3568 already present, skipping"
  exit 0
fi

# Add rk3568_cpu_opp_data before rv1126_cpu_opp_data
sed -i '/^static const struct rockchip_opp_data rv1126_cpu_opp_data/i\
static const struct rockchip_opp_data rk3568_cpu_opp_data = {\
\t/* rk3568: no special soc info needed */\
};' "$FILE"

# Add rk3568 to of_match table before rv1109 entry
sed -i '/\.compatible = "rockchip,rv1109",/i\
\t{\
\t\t.compatible = "rockchip,rk3568",\
\t\t.data = (void *)\&rk3568_cpu_opp_data,\
\t},' "$FILE"

echo "Added rk3568 to rockchip_cpufreq_of_match"
