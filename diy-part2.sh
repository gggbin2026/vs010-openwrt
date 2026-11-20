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
#   5~7) 源头关 IPv6 / WDS 能力校验 / 网桥就绪文件校验（极简网桥版追加）
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
# 【2026-11-20 编译报错修复】
#   旧版用 `cat >> "$IMG"` 把 Device 块追加到文件末尾，但官方 image/Makefile
#   最后一行是 `$(eval $(call BuildImage))`，而 include/image.mk 第 740 行：
#       define BuildImage
#         $(foreach device,$(TARGET_DEVICES),$(call Device,$(device)))
#   TARGET_DEVICES 在 BuildImage 展开那一刻就被消费掉。追加在它之后 →
#   DUMP=1 的 tmp/.targetinfo 里没有 DEVICE_cucc_vs010 profile →
#   target-metadata.pl 不生成 `config TARGET_ipq50xx_arm_DEVICE_cucc_vs010`
#   → make defconfig 把 .config 里的这个未知符号丢掉 → 报"设备符号丢失"。
#
#   修复：与官方 3 个 Device 定义一样，插入到 `$(eval $(call BuildImage))` 之前。
IMG="$TGT/image/Makefile"
test -s "$IMG" || { echo "::error::缺 $IMG"; exit 1; }

python3 - "$IMG" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# 1) 幂等：删掉任何历史注入块（含旧版追加到文件末尾的那一份）
s = re.sub(
    r'\n*# ── CUCC / Unicom VS010.*?\nTARGET_DEVICES \+= cucc_vs010[ \t]*\n',
    '\n', s, flags=re.S)

# 2) 定位 BuildImage 调用
lines = s.splitlines(keepends=True)
idx = next((i for i, l in enumerate(lines)
            if l.startswith('$(eval $(call BuildImage))')), -1)
if idx < 0:
    print('::error::image/Makefile 里找不到行首的 BuildImage 调用，底座可能变了')
    sys.exit(1)

block = """# ── CUCC / Unicom VS010 ───────────────────────────────────────────
# 必须放在文件末尾的 BuildImage 调用之前，否则 TARGET_DEVICES 不会被消费。
# 与 cmcc_rax3000q 同平台；不打包 ipq-wifi-cmcc_rax3000q（那是别的机器 BDF），
# 校准由 11-ath11k-caldata 从本机 0:ART 分区提取。
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
  DEVICE_PACKAGES := \\
	ath11k-firmware-ipq5018 \\
	ath11k-firmware-qcn6122 \\
	iperf3
endef
TARGET_DEVICES += cucc_vs010

"""
lines.insert(idx, block)
open(p, 'w', encoding='utf-8').write(''.join(lines))
PYEOF

# 3) 三重校验：存在 / 唯一 / 位置在 BuildImage 之前
CNT=$(grep -c '^TARGET_DEVICES += cucc_vs010' "$IMG" || true)
[ "$CNT" = "1" ] || { echo "::error::cucc_vs010 设备定义数量异常（$CNT）"; exit 1; }
python3 - "$IMG" <<'PYEOF'
import sys
ls = open(sys.argv[1], encoding='utf-8').read().splitlines()
d = next((i for i, l in enumerate(ls) if l.startswith('TARGET_DEVICES += cucc_vs010')), -1)
b = next((i for i, l in enumerate(ls) if l.startswith('$(eval $(call BuildImage))')), -1)
if not (0 <= d < b):
    print('::error::TARGET_DEVICES 必须在行首的 BuildImage 调用之前 (dev=%d, bi=%d)' % (d, b))
    sys.exit(1)
print('[diy-part2] 位置校验通过: TARGET_DEVICES@行%d < BuildImage@行%d' % (d + 1, b + 1))
PYEOF
echo "[diy-part2] Device/cucc_vs010 已插入到 BuildImage 之前"

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
# ═══════════════════ 5. 源头关闭 IPv6 / 冗余默认包 ═══════════════════
# QSDK 树 include/target.mk 里 DEFAULT_PACKAGES.router 带 ipv6helper、
# tweak 带 10 个插件；make defconfig 会重新写回 .config，必须改 Makefile。
TM="include/target.mk"
test -f "$TM" || { echo "::error::缺 $TM"; exit 1; }
cp "$TM" "$TM.bak"
python3 - "$TM" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
new_router = "DEFAULT_PACKAGES.router:=\\\n\tdnsmasq \\\n\tfirewall \\\n\tiptables\n"
new_tweak  = "DEFAULT_PACKAGES.tweak:=\\\n\tluci\n"
# 幂等：若已精简（ipv6helper 不在）就跳过，避免同一棵树重复跑时误报
if 'ipv6helper' not in s:
    print('[target.mk] 已是精简状态，跳过')
else:
    s, n1 = re.subn(r'DEFAULT_PACKAGES\.router:=\\\n(?:.*\\\n)*?\tppp-mod-pppoe\n', new_router, s, count=1)
    s, n2 = re.subn(r'DEFAULT_PACKAGES\.tweak:=\\\n(?:.*\\\n)*?\tluci-lib-ipkg\n', new_tweak, s, count=1)
    if n1 != 1 or n2 != 1:
        print("::error::target.mk 替换失败 router=%d tweak=%d" % (n1, n2))
        sys.exit(1)
    open(p, 'w', encoding='utf-8').write(s)
PYEOF
grep -q 'ipv6helper' "$TM" && { echo "::error::ipv6helper 仍在 target.mk"; exit 1; } || true
echo "[diy-part2] include/target.mk 已精简（ipv6helper / tweak 插件从源头移除）"

# ═══════════════════ 6. WDS / 4addr 能力校验 ═══════════════════
# QSDK 树自带 4addr + NSS WDS offload 补丁，NSS 与 WDS 是配套设计，
# 不要关硬件加速（这跟主线 ath11k / WED 与 4addr 冲突是两回事）。
SH="package/kernel/mac80211/files/lib/netifd/wireless/mac80211.sh"
grep -q '4addr on' "$SH" || { echo "::error::netifd 缺 4addr 支持"; exit 1; }
for p in \
  "149-ath11k-fix-4addr-tx-failure-AP-STA-modes.patch" \
  "211-002-ath11k-add-WDS-offload-support-on-NSS-offload-for-STA-mode.patch" \
  "216-ath11k-send-multicast-in-4addr.patch" \
  "330-ath11k-sync-wds_ast_entry-updates.patch"; do
  test -f "package/kernel/mac80211/patches/all-ipq50xx/$p" \
    || { echo "::error::缺 WDS 补丁 $p"; exit 1; }
done
echo "[diy-part2] WDS 4addr / NSS offload 四项补丁齐备"
grep -q '^CONFIG_PACKAGE_wpad-basic-wolfssl=y' .config \
  && echo "[diy-part2] wpad-basic-wolfssl 已启用（WDS 不需要完整 hostapd）" \
  || echo "::warning::wpad 未显式启用，defconfig 会按 DEFAULT_PACKAGES 补上"

# ═══════════════════ 7. 网桥就绪文件校验 ═══════════════════
# workflow 的 Load config 步骤会把仓库 files/ 搬到 openwrt/files/
test -s "files/etc/uci-defaults/99-bridge-ready" \
  || { echo "::error::缺 99-bridge-ready（网桥 STP / 关 IPv6 配置面）"; exit 1; }
test -s "files/usr/sbin/portstat" \
  || echo "::warning::缺 portstat（不影响编译，只影响验收）"
echo "[diy-part2] 网桥就绪文件已就位"

# 注：nss-dp 的 ethtool 速率上报补丁由 workflow 的独立 step 注入到
# package/kernel/qca/qca-nss-dp/patches/，这里不重复处理。

echo "==================== [diy-part2] 完成 ===================="
