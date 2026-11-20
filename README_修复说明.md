# VS010 极简 WDS 网桥修复说明

完整操作清单请看 **`README_最终操作清单.md`**，这里只记技术结论。

## 底座判断

仓库 `gggbin2026/vs010-openwrt` 虽然 fork 自 `xiangye277/vs010-openwrt`，但**当前已上传的是 QSDK 5.4 修复包**（`kkstone/immortalwrt-ipq50xx @ openwrt-21.02`），不是 xiangye277 那套 OpenWrt main 6.12 + DSA。判断依据：

- `.config` 里是 `CONFIG_TARGET_ipq50xx_arm_DEVICE_cucc_vs010=y`
- `diy-part2.sh` 往 `target/linux/ipq50xx/dts/` 注入 QSDK 风格 DTS
- workflow 的 `REPO_URL` 指向 `kkstone/immortalwrt-ipq50xx`

**这个底座是对的**：256MB 内存跑主线 ath11k 会 OOM（上游 PZ-L8 / RAX3000Q 的 DTS 直接把 wifi 置 `status = "disabled"`），QSDK 闭源 WiFi + `CONFIG_ATH11K_MEM_PROFILE_256M` 才能开 WiFi；而且 QSDK 树自带 `149` / `211-002` / `216` / `330` 四个 WDS offload 补丁，NSS 硬件转发与 4addr 是配套设计，比主线更适合做无线网桥。

**所以不要换回 DSA 路线**。仓库里 xiangye277 残留的根目录 `ipq5018-vs010.dts`（6121 B）和 `.github/workflows/build.yml` 是另一套交换栈，混进 QSDK 树必编译失败。

## 这次改了什么

| 项 | 改前 | 改后 |
|---|---|---|
| 包数 | 330（42 个 luci-app） | 137，0 个 luci-app |
| IPv6 | 内核 + 用户态全开 | `include/target.mk` 源头删 `ipv6helper` + `slim.sh` 二次收敛 + 配置面清 RA/DHCPv6 + workflow 硬校验 |
| initramfs | 开 | 关，只出 squashfs |
| WDS | 补丁在树里，桥没配 | 四项补丁校验 + STP + 防火墙全放行 + `wpad-basic-wolfssl` |
| 网口速率显示 | 占位符「半双工 / 速率 —」 | `nss-dp` ethtool 补丁 |
| workflow | 单次 defconfig、release 两步、无 permissions | 三段 defconfig + 5 项硬校验 + 编译后确认补丁 + 产物强校验 |

WiFi / NSS / 256M profile / BDF 路线（`0:ART` caldata，不打包 `ipq-wifi-cmcc_rax3000q`）**一个没动**。

## 网口速率的精确根因

`qca-nss-dp`（`NHSS.QSDK.11.5.0.5`）的 `nss_dp_ethtools.c`：

```c
.get_link_ksettings = phy_ethtool_get_link_ksettings,
```

这个内核辅助函数取 `netdev->phydev`，而 nss-dp 把 PHY 存在 `dp_priv->phydev`，`netdev->phydev` 为 NULL；CPU 口更是 `fixed-link`、没有 PHY → 返回 `-ENODEV` → `ethtool` 报 `Unknown!` → LuCI 回显占位符。**物理链路一直是 1000M 全双工**。

补丁换成读 `dp_priv->phydev` 的自定义 `nss_dp_get_link_ksettings()`，无 PHY 的 fixed-link 口填 `SPEED_1000 / DUPLEX_FULL`。只改上报回调，不动数据路径。VS010 与 RAX3000Q 共用同一个 `qca-nss-dp` 包，补丁完全通用。

补丁基于 11.5.0.5 真实源码生成、`patch -p1 --dry-run` 通过；`qca-nss-dp/Makefile` 没有覆盖 `Build/Prepare`，OpenWrt 会自动应用 `patches/*.patch`；workflow 第 14 步在编译后 grep `nss_dp_get_link_ksettings` 确认真编进去了。

## WiFi 速率显示修不了，但速率本来就没问题

QSDK 走 NSS offload 快路径，`iw station dump` 的 `tx/rx bitrate` 常不更新或为 0，是统计没回灌 mac80211，不是协商速率低。改这个要动 ath11k 统计路径，风险高且无验证，本包不给补丁。**统一用 `iperf3` 看真值**；`portstat` 把 `swconfig` 的真实 `1000baseT full-duplex`、关联状态、4addr 一次打印出来。

## VS010 与 RAX3000Q 的差异（都已在本包处理）

- 设备符号 / `board_name`：`cucc,vs010`（不是 `cmcc,rax3000q`，更不是 DSA 版的 `unicom,vs010`）
- BDF：VS010 走 `11-ath11k-caldata` 从 `0:ART` 提取，**不打包** `ipq-wifi-cmcc_rax3000q`；workflow 有硬校验防止误打包
- 端口映射：`"6u@eth1" "3u@eth0" "1:lan:3" "2:lan:2" "3:lan:1" "4:wan"`，按 PZ-L8 / xiangye277 推的初值，首刷需 `swconfig dev switch1 show` 实测
- 分区：VS010 是单分区 `rootfs @0x900000`（`0x6e00000` = 110 MiB），与 PZ-L8/RAX3000Q 双分区不同，U-Boot 变量语义不一样
- 刷机：QSDK U-Boot `192.168.1.8` + LAN1；原厂 Web API `192.168.2.1`（.img）；NWRT TTL `192.168.2.2`。三套别混
- DTS 二选一：`use_nwrt_dump_dts=false` 用 QSDK 风格改写版（编译成功率最高），`true` 用 NWRT 反编译硬件真值兜底

## 边界

- 未跑真实 `make`（本会话 362MB 磁盘 / 2.4GB 内存 / 2 核，缺 toolchain）。脚本语法、注入链路、slim 收敛、补丁 dry-run、YAML 均已本地验证，**编译通过要你在 Actions 点一次**。
- 补丁只修显示；`iperf3` 只有 100M 且 CRC 涨是真 PHY 问题，跟补丁无关。
- 校准偏移暂借 RAX3000Q 的 `0x1000` / `0x26800`；`oem_extract/qcn6122_bdwlan.bin` 只有 50 字节、是 404 页面，**不能当 BDF**。
- WDS 4addr 跨两台实机仍需实测；不通按 `WDS网桥配置.md` 退到 `relayd` / `GRETAP`。
