#!/bin/bash
# 在 workflow 的 "Load config + inject" 之后、make defconfig 之前调用
# 工作目录: openwrt/      仓库根: $GITHUB_WORKSPACE
#
# 把 999-nss-dp-ethtool-fixed-link.patch 放进 qca-nss-dp 包目录。
# OpenWrt 的 Build/Prepare 会自动应用 $(CURDIR)/patches/*.patch。
set -euo pipefail

PATCH_SRC="$GITHUB_WORKSPACE/patches/999-nss-dp-ethtool-fixed-link.patch"
PKG_DIR="package/kernel/qca/qca-nss-dp"

echo "==================== [ethtool] 注入 nss-dp 速率上报补丁 ===================="
test -s "$PATCH_SRC" || { echo "::error::缺 $PATCH_SRC"; exit 1; }
test -f "$PKG_DIR/Makefile" || { echo "::error::不是 QSDK 5.4 树（缺 $PKG_DIR/Makefile）"; exit 1; }

# 防呆：run #1 的失败补丁用了 Linux 5.4 不存在的 base.mdix 字段。
# 若仓库里还是旧补丁，直接拦下，不要让它进编译。
if grep -qE '^\+.*cmd->base\.(mdix|eth_tp_mdix)' "$PATCH_SRC"; then
  echo "::error::补丁仍含 5.4 不存在的 mdix 字段（run #1 的编译错误）；请覆盖成修正版"
  grep -nE '^\+.*cmd->base\.(mdix|eth_tp_mdix)' "$PATCH_SRC"
  exit 1
fi

grep -q 'nss_dp_get_link_ksettings' "$PATCH_SRC" \
  || { echo "::error::补丁里没有自定义回调，文件可能传错"; exit 1; }

mkdir -p "$PKG_DIR/patches"
cp "$PATCH_SRC" "$PKG_DIR/patches/"
echo "  ✓ $PKG_DIR/patches/999-nss-dp-ethtool-fixed-link.patch"
echo "  ✓ 已确认补丁不含 base.mdix / base.eth_tp_mdix（5.4 编译兼容）"

grep -q 'NHSS.QSDK.11.5' "$PKG_DIR/Makefile" \
  && echo "  ✓ qca-nss-dp 版本 NHSS.QSDK.11.5（补丁上下文已按此版本生成）" \
  || echo "  ::warning::qca-nss-dp 版本不是 11.5，补丁可能需微调上下文"

echo "==================== [ethtool] 完成 ===================="
echo "  编译后验收：ethtool eth0 应显示 Speed: 1000Mb/s / Duplex: Full"
