#!/bin/bash
#
# P3TERX/Actions-OpenWrt — DIY script part 2 (After Load .config, before make defconfig)
# 工作目录：openwrt/    仓库根目录：$GITHUB_WORKSPACE
#
# QSDK 21.02 树里只有 cmcc_rax3000q / redmi_ax3000 / xiaomi_cr881x 三台设备，
# 完全没有 VS010。这里把 VS010 的 4 处设备层定义全部注入：
#   1) DTS
#   2) image/Makefile 的 Device 定义
#   3) 02_network 的 swconfig 端口映射
#   4) 11-ath11k-caldata 的 ART 校准提取
# 全部在 make defconfig 之前完成，否则 .config 里的 DEVICE_cucc_vs010 会被丢掉。
#
set -euo pipefail

ROOT="$GITHUB_WORKSPACE"
TGT="target/linux/ipq50xx"

echo "==================== [diy-part2] VS010 注入开始 ===================="

# ─────────────────────────── 1. DTS ───────────────────────────
DTS_DIR="$TGT/dts"
test -d "$DTS_DIR" || { echo "::error::缺 $DTS_DIR"; exit 1; }

if [ "${USE_NWRT_DTS:-false}" = "true" ]; then
  # 硬件真值兜底：从 NWRT 固件 /sys/firmware/fdt 反编译出来的 2321 行完整 DTS
  # 优点：GPIO / 端口 / 分区 / 校准 100% 是 VS010 实物
  # 缺点：数值 phandle、machid、MP_256 等 QSDK 展开写法，个别 dtc 版本会报警
  cp "$ROOT/vs010/ipq5018-vs010-nwrt-dump.dts" "$DTS_DIR/ipq5018-vs010.dts"
  echo "[diy-part2] DTS = NWRT 反编译原件（硬件真值兜底）"
else
  # 主选：以 QSDK 树 ipq5000-rax3000q.dts 为模板改写的 VS010 版
  # 符号与 5.4-QSDK 树 100% 匹配，编译成功率最高
  cp "$ROOT/vs010/ipq5018-vs010.dts" "$DTS_DIR/ipq5018-vs010.dts"
  echo "[diy-part2] DTS = QSDK 风格改写版"
fi
test -s "$DTS_DIR/ipq5018-vs010.dts" || { echo "::error::DTS 注入失败"; exit 1; }

# ─────────────────── 2. image/Makefile 设备定义 ───────────────────
IMG="$TGT/image/Makefile"
# 防重复（同一 job 里重跑时）
sed -i '/^# ── CUCC \/ Unicom VS010/,/^TARGET_DEVICES += cucc_vs010/d' "$IMG"

cat >> "$IMG" <<'MKEOF'

# ── CUCC / Unicom VS010 ───────────────────────────────────────────
# 与 cmcc_rax3000q 同平台（IPQ5018 + QCN6102 + QCA8337），但：
#   * DTS 换成 VS010（RESET GPIO33 / LED GPIO35 / switch 位图不同）
#   * 不打包 ipq-wifi-cmcc_rax3000q（那是 RAX3000Q 的 BDF，刷进来 5G 校准必错）
#     校准改由 11-ath11k-caldata 从本机 0:ART 分区提取
#   * 不覆盖 IMAGES，保留 UbiFit 的 nand-factory.ubi + nand-sysupgrade.bin
define Device/cucc_vs010
  $(call Device/FitImage)
  $(call Device/UbiFit)
  SOC := ipq5018
  DEVICE_DTS := ipq5018-vs010
  DEVICE_VENDOR := CUCC
  DEVICE_MODEL := VS010
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  DEVICE_DTS_CONFIG := config@mp02.1
  DEVICE_PACKAGES := \
	ath11k-firmware-ipq5018 \
	ath11k-firmware-qcn6122 \
	iperf3
endef
TARGET_DEVICES += cucc_vs010
MKEOF

grep -q '^TARGET_DEVICES += cucc_vs010' "$IMG" || { echo "::error::设备定义注入失败"; exit 1; }
echo "[diy-part2] Device/cucc_vs010 已追加"

# ─────────────────────── 3. 02_network（swconfig） ───────────────────────
# 【PZ-L8 借鉴 · 2026-11-20 核实】
#   主线 target/linux/qualcommax/dts/ipq5018-pz-l8.dts 与 xiangye277 的
#   VS010 DTS 相似度 81.2%，后者本就是 PZ-L8 改编。两个独立来源一致：
#     qca8337 phy0 -> lan3 / phy1 -> lan2 / phy2 -> lan1 / phy3 -> wan
#     phy4 -> IPQ5018 GE Phy (gmac0)，port0 -> SGMII (gmac1)
#   原版按 NWRT 的 switch_lan_bmp=0x1e 推成「4 个口全是 lan」，
#   与 PZ-L8 / xiangye277 冲突，这里改回带独立 wan 的映射。
#   ⚠️ 首刷仍需 `swconfig dev switch1 show` 逐个插线确认 RJ45 对应。
#
#   PZ-L8 只在 OpenWrt main / qualcommax (6.12 + DSA) 受官方支持；
#   本仓库的 kkstone QSDK 21.02 树没有 PZ-L8，故只借「参数真值」，
#   不换底座、不套 DSA DTS（两套交换栈互斥）。
NET="$TGT/base-files/etc/board.d/02_network"
sed -i '/cucc,vs010)/,/^[[:space:]]*;;/d' "$NET"
# 在 case 第一个分支前插入 VS010 分支
sed -i '/^[[:space:]]*case \$board in/a\		cucc,vs010)\
			# PHY 顺序借鉴 CMCC PZ-L8 / xiangye277 VS010 DTS\
			# CPU 位图仍用 NWRT fdt dump: cpu=0x40(port6) lan=0x1e；RJ45 对应需实测\
			ucidef_add_switch "switch1" \\\
				"6u@eth1" "3u@eth0" \\\
				"1:lan:3" "2:lan:2" "3:lan:1" "4:wan"\
			;;' "$NET"
grep -q 'cucc,vs010)' "$NET" || { echo "::error::02_network 注入失败"; exit 1; }
echo "[diy-part2] 02_network 已注入 cucc,vs010（PZ-L8 PHY 顺序，swconfig）"

# ──────────────── 4. 11-ath11k-caldata（ART 校准） ────────────────
CAL="$TGT/base-files/etc/hotplug.d/firmware/11-ath11k-caldata"
sed -i '/^[[:space:]]*cucc,vs010|\\$/d' "$CAL"
# 两处 case 的 cmcc,rax3000q 前都加上 cucc,vs010
sed -i 's/^\([[:space:]]*\)cmcc,rax3000q|\\$/\1cucc,vs010|\\\n\1cmcc,rax3000q|\\/' "$CAL"
CNT=$(grep -c 'cucc,vs010|\\' "$CAL" || true)
[ "$CNT" -ge 2 ] || { echo "::error::caldata 注入失败（应命中 2 处，实际 $CNT）"; exit 1; }
echo "[diy-part2] 11-ath11k-caldata 已注入 cucc,vs010（命中 $CNT 处）"

# 5G 频限：QSDK 闭源 WiFi 不走 ieee80211-freq-limit，这里无需改；
# 但仍检查一下，避免有人把 DSA 版 DTS 混进来
if grep -q 'ieee80211-freq-limit' "$DTS_DIR/ipq5018-vs010.dts"; then
  sed -i 's/ieee80211-freq-limit = <5150000 5730000>/ieee80211-freq-limit = <5150000 5895000>/' "$DTS_DIR/ipq5018-vs010.dts"
  echo "[diy-part2] 已把 5G 频限上限放宽到 5895000（保住 ch149~165）"
fi

# ─────────────────────────── 校验 ───────────────────────────
echo "==================== [diy-part2] 注入校验 ===================="
ls -l "$DTS_DIR/ipq5018-vs010.dts"
grep -nE 'model|compatible = "cucc|tlmm 33|tlmm 35|switch_(lan|wan|cpu)_bmp' "$DTS_DIR/ipq5018-vs010.dts" | head -12
echo "--- image/Makefile ---"
grep -nE -A14 '^define Device/cucc_vs010' "$IMG"
echo "--- 02_network ---"
grep -nE -A6 'cucc,vs010)' "$NET"
echo "--- caldata ---"
grep -nE 'cucc,vs010|caldata_extract' "$CAL"
echo "==================== [diy-part2] 完成 ===================="
