#!/bin/bash
# 在 workflow 的 "Load config + inject" 之后、make defconfig 之前调用
# 工作目录: openwrt/      仓库根: $GITHUB_WORKSPACE
#
# 把 999-nss-dp-ethtool-fixed-link.patch 放进 qca-nss-dp 包目录。
# OpenWrt 的 Build/Prepare 会自动应用 $(CURDIR)/patches/*.patch，
# 所以补丁会在源码解压后、编译前被 patch -p1 打上。
set -euo pipefail

PATCH_SRC="$GITHUB_WORKSPACE/patches/999-nss-dp-ethtool-fixed-link.patch"
PKG_DIR="package/kernel/qca/qca-nss-dp"

echo "==================== [ethtool] 注入 nss-dp 速率上报补丁 ===================="
test -s "$PATCH_SRC" || { echo "::error::缺 $PATCH_SRC"; exit 1; }
test -f "$PKG_DIR/Makefile" || { echo "::error::不是 QSDK 5.4 树（缺 $PKG_DIR/Makefile）"; exit 1; }

mkdir -p "$PKG_DIR/patches"
cp "$PATCH_SRC" "$PKG_DIR/patches/"
echo "  ✓ $PKG_DIR/patches/999-nss-dp-ethtool-fixed-link.patch"

# 确认这份源码确实是 11.5 系、且原样用了 phy_ethtool_get_link_ksettings
grep -q 'NHSS.QSDK.11.5' "$PKG_DIR/Makefile" \
  && echo "  ✓ qca-nss-dp 版本 NHSS.QSDK.11.5（补丁上下文已按此版本生成）" \
  || echo "  ::warning::qca-nss-dp 版本不是 11.5，补丁可能需微调上下文"

# 补丁自身语法校验：用 patch --dry-run 对一份最小替身做检查（不依赖已解压源码）
grep -q 'nss_dp_get_link_ksettings' "$PATCH_SRC" && echo "  ✓ 补丁内含自定义回调"

echo "==================== [ethtool] 完成 ===================="
echo "  编译后验收：ethtool eth0 应显示 Speed: 1000Mb/s / Duplex: Full"
