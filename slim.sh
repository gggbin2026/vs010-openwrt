#!/bin/bash
# 在第一次 `make defconfig` 之后执行（工作目录 = openwrt/）。
# defconfig 会按 target 的 DEFAULT_PACKAGES / 依赖把 IPv6 和插件拉回，
# 这里做二次收敛，然后再跑一次 defconfig 定型。
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
        "qca-nss-fw-ipq50xx-retail swconfig ethtool iperf3", a, " ")
  for (i in a) allow[a[i]]=1
}
/^CONFIG_PACKAGE_/ && /=y$/ {
  n=$0; sub(/^CONFIG_PACKAGE_/, "", n); sub(/=y$/, "", n)
  # 内核模块与 LuCI 运行期依赖交给 defconfig 重算
  if (allow[n] || n ~ /^kmod-/ || n ~ /^luci-(base|mod-|theme-|lib-)/) { print; next }
  print "# CONFIG_PACKAGE_" n " is not set"; next
}
/^CONFIG_IPV6=y$/                     { print "# CONFIG_IPV6 is not set"; next }
/^CONFIG_KERNEL_IPV6=y$/              { print "# CONFIG_KERNEL_IPV6 is not set"; next }
/^CONFIG_KERNEL_IPV6_.*=y$/           { k=$0; sub(/=.*/,"",k); print "# " k " is not set"; next }
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
  swconfig ethtool iperf3 ; do
  k="CONFIG_PACKAGE_$n"
  if grep -q "^# $k is not set" .config; then sed -i "s|^# $k is not set|$k=y|" .config
  elif ! grep -q "^$k=y" .config; then echo "$k=y" >> .config; fi
done

# 全局关键开关
for kv in \
  "CONFIG_ATH11K_MEM_PROFILE_256M=y" \
  "CONFIG_ATH11K_NSS_SUPPORT=y" \
  "CONFIG_PACKAGE_MAC80211_NSS_SUPPORT=y" \
  "CONFIG_PACKAGE_MAC80211_DEBUGFS=y" \
  "CONFIG_TARGET_ROOTFS_SQUASHFS=y" \
  "CONFIG_TARGET_ipq50xx_arm_DEVICE_cucc_vs010=y" ; do
  k=${kv%%=*}
  if grep -q "^# $k is not set" .config; then sed -i "s|^# $k is not set|$kv|" .config
  elif ! grep -q "^$kv$" .config; then echo "$kv" >> .config; fi
done
# 明确排除 RAX3000Q 的 BDF
if grep -q '^CONFIG_PACKAGE_ipq-wifi-cmcc_rax3000q=y' .config; then
  sed -i 's|^CONFIG_PACKAGE_ipq-wifi-cmcc_rax3000q=y|# CONFIG_PACKAGE_ipq-wifi-cmcc_rax3000q is not set|' .config
fi

echo "[slim] 精简前 =y 包: $(grep -c '^CONFIG_PACKAGE_.*=y$' .config.before-slim || true)"
echo "[slim] 精简后 =y 包: $(grep -c '^CONFIG_PACKAGE_.*=y$' .config || true)"
echo "[slim] IPv6 相关包 =y: $(grep -cE '^CONFIG_PACKAGE_.*(ipv6|odhcp|6in4|6to4|6rd|natmap).*=y$' .config || true)"
echo "[slim] luci-app =y: $(grep -c '^CONFIG_PACKAGE_luci-app-.*=y$' .config || true)"
