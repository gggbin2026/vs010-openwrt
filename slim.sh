#!/bin/bash
# 在第一次 `make defconfig` 之后执行（工作目录 = openwrt/）。
# defconfig 会按 target 的 DEFAULT_PACKAGES / 依赖把插件拉回，
# 这里做二次收敛（IPv6 本版编译期关闭），然后再跑一次 defconfig 定型。
set -euo pipefail
[ -f .config ] || { echo "::error::找不到 .config（请在 openwrt/ 目录下运行）"; exit 1; }
cp .config .config.before-slim

awk '
BEGIN {
  # 白名单：能启动 + LuCI + QSDK WiFi + WDS + 验收的最小集
  # VS010 不打包 ipq-wifi-cmcc_rax3000q（那是别的机器 BDF），校准走 0:ART
  split("base-files busybox dropbear netifd procd ubus ubox uci rpcd cgi-io uhttpd " \
        "logd opkg fstools mtd ca-bundle libgcc libc libustream-openssl uclient-fetch urandom-seed urngd " \
        "dnsmasq firewall iptables luci " \
        "ath11k-firmware-ipq5018 ath11k-firmware-qcn6122 " \
        "iw iwinfo wireless-regdb wpad-basic-wolfssl hostapd-common " \
        "qca-nss-fw-ipq50xx-retail swconfig ethtool iperf3 " \
        "MAC80211_MESH MAC80211_DEBUGFS MAC80211_NSS_SUPPORT " \
        "kmod-qca-ssdk-nohnat kmod-qca-nss-dp kmod-qca-nss-drv " \
        "qca-nss-fw-ipq50xx-retail swconfig", a, " ")
  for (i in a) allow[a[i]]=1
}
/^CONFIG_PACKAGE_/ && /=y$/ {
  n=$0; sub(/^CONFIG_PACKAGE_/, "", n); sub(/=y$/, "", n)
  # 内核模块与 LuCI 运行期依赖交给 defconfig 重算
  if (allow[n] || n ~ /^kmod-/ || n ~ /^luci-(base|mod-|theme-|lib-)/) { print; next }
  print "# CONFIG_PACKAGE_" n " is not set"; next
}
/^CONFIG_TARGET_ROOTFS_INITRAMFS=y$/  { print "# CONFIG_TARGET_ROOTFS_INITRAMFS is not set"; next }
{ print }
' .config.before-slim > .config

# 白名单强制 =y（defconfig 若关掉就补回来）
for n in \
  base-files busybox dropbear netifd procd ubus uci rpcd cgi-io uhttpd logd opkg uclient-fetch \
  dnsmasq firewall iptables \
  luci luci-base luci-mod-admin-full luci-mod-network luci-mod-status luci-mod-system luci-theme-bootstrap \
  kmod-ath11k kmod-ath kmod-cfg80211 kmod-mac80211 \
  ath11k-firmware-ipq5018 ath11k-firmware-qcn6122 \
  iw iwinfo wireless-regdb wpad-basic-wolfssl hostapd-common \
  qca-nss-fw-ipq50xx-retail kmod-qca-nss-dp kmod-qca-nss-drv \
  swconfig ethtool iperf3 luci-theme-argon \
  kmod-qca-ssdk-nohnat kmod-qca-nss-dp kmod-qca-nss-drv \
  qca-nss-fw-ipq50xx-retail ; do
  k="CONFIG_PACKAGE_$n"
  if grep -q "^# $k is not set" .config; then sed -i "s|^# $k is not set|$k=y|" .config
  elif ! grep -q "^$k=y" .config; then echo "$k=y" >> .config; fi
done

# 清掉历史畸形行（=y is not set），避免 Kconfig 后写覆盖时残留
sed -i '/^# CONFIG_PACKAGE_MAC80211_MESH=y is not set$/d' .config

# 全局关键开关
for kv in \
  "CONFIG_ATH11K_MEM_PROFILE_256M=y" \
  "CONFIG_ATH11K_NSS_SUPPORT=y" \
  "CONFIG_PACKAGE_MAC80211_NSS_SUPPORT=y" \
  "CONFIG_PACKAGE_MAC80211_DEBUGFS=y" \
  "CONFIG_PACKAGE_MAC80211_MESH=y" \
  "CONFIG_TARGET_ROOTFS_SQUASHFS=y" \
  "CONFIG_PACKAGE_luci-theme-argon=y" \
  "CONFIG_PACKAGE_kmod-qca-ssdk-nohnat=y" \
  "CONFIG_PACKAGE_kmod-qca-nss-dp=y" \
  "CONFIG_PACKAGE_kmod-qca-nss-drv=y" \
  "CONFIG_PACKAGE_qca-nss-fw-ipq50xx-retail=y" \
  "CONFIG_PACKAGE_swconfig=y" \
  "CONFIG_TARGET_ipq50xx_arm_DEVICE_cucc_vs010=y" ; do
  k=${kv%%=*}
  if grep -q "^# $k is not set" .config; then sed -i "s|^# $k is not set|$kv|" .config
  elif ! grep -q "^$kv$" .config; then echo "$kv" >> .config; fi
done
# 明确排除 RAX3000Q 的 BDF
if grep -q '^CONFIG_PACKAGE_ipq-wifi-cmcc_rax3000q=y' .config; then
  sed -i 's|^CONFIG_PACKAGE_ipq-wifi-cmcc_rax3000q=y|# CONFIG_PACKAGE_ipq-wifi-cmcc_rax3000q is not set|' .config
fi

# ── 强制关闭 IPv6 编译期栈 ─────────────────────────────────────
# 2026-11-21：开启 CONFIG_IPV6 + ip6tables/nat6/conntrack6 后，
# QSDK 5.4 的 qca-nss-ecm 在首次开机约 30s 触发 BUG_ON（e7f001f2）
# → Kernel panic → 3 秒后自动重启，无限循环。回到已验证可启动的配置。
for k in CONFIG_IPV6 CONFIG_KERNEL_IPV6; do
  sed -i "s|^$k=y$|# $k is not set|" .config
  grep -q "^# $k is not set$" .config || echo "# $k is not set" >> .config
done

echo "[slim] 精简前 =y 包: $(grep -c '^CONFIG_PACKAGE_.*=y$' .config.before-slim || true)"
echo "[slim] 精简后 =y 包: $(grep -c '^CONFIG_PACKAGE_.*=y$' .config || true)"
echo "[slim] IPv6: 编译期关闭 (CONFIG_IPV6 / CONFIG_KERNEL_IPV6 均 not set)"
echo "[slim] luci-app =y: $(grep -c '^CONFIG_PACKAGE_luci-app-.*=y$' .config || true)"

# ── 网卡/交换驱动兜底（加固）────────────────────────────────────
# 这 5 个是 QCA8337 + NSS-DP 的全部依赖，任一被 defconfig 摁掉，
# ess-switch 就不会 probe：ip link 无 ethX、swconfig list 空、四个口全不通。
for k in kmod-qca-ssdk-nohnat kmod-qca-nss-dp kmod-qca-nss-drv \
         qca-nss-fw-ipq50xx-retail swconfig ; do
  key="CONFIG_PACKAGE_$k"
  if grep -q "^# $key is not set" .config; then
    sed -i "s|^# $key is not set|$key=y|" .config
  elif ! grep -q "^$key=y" .config; then
    echo "$key=y" >> .config
  fi
done
echo "[slim] 网卡驱动锁定: $(grep -cE '^CONFIG_PACKAGE_(kmod-qca-ssdk-nohnat|kmod-qca-nss-dp|kmod-qca-nss-drv|qca-nss-fw-ipq50xx-retail|swconfig)=y$' .config || true)/5"
