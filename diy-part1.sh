#!/bin/bash
#
# P3TERX/Actions-OpenWrt — DIY script part 1 (Before Update feeds)
# 在 ./scripts/feeds update -a 之前执行，工作目录为 openwrt/
#
# QSDK 21.02 底座的 feeds.conf.default 已由仓库根目录的 feeds.conf.default 覆盖，
# 里面四个源都 pin 在 openwrt-21.02 分支，与 5.4 内核匹配。这里无需额外改动。
#
# 若后续要加第三方插件源，请在这里用 sed 打开，例如：
#   sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default
#
set -e
echo "[diy-part1] QSDK 5.4 底座，使用仓库自带的 feeds.conf.default（21.02 分支）"
cat feeds.conf.default
