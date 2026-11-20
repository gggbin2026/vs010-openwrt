# RAX3000Q 编译失败：真正根因（日志已到手）

## 0. 先撤回我上一轮的判断

**上一轮那个 `RAX3000Q_编译失败修复包`（保留内核 IPv6）是误判，请不要上传、不要使用。**

日志证明：关掉 IPv6 完全没问题——`dnsmasq/nodhcpv6`、`qca-ssdk-nohnat`、`wpad-basic-wolfssl`、`openssl`、`util-linux` 全都编过了，整整 99000 行只有 1 个编译错误。我上一轮是因为拿不到 artifact 才推测 ECM/IPv6 冲突，方向错了。

你仓库现在的状态（RAX3000Q `9b9d8a4`、VS010 `6c3f3de`）**基本都是对的，不用动**：极简配置、IPv6 关闭、WDS 补丁、VS010 的设备符号修复，全部保留。

---

## 1. 逐字根因（日志第 99039 / 99088~99099 行）

```
99039: patching file nss_dp_ethtools.c                 ← 补丁成功应用了，注入链路没问题
99080:   CC [M]  .../qca-nss-dp-NHSS.QSDK.11.5.0.5/nss_dp_ethtools.o
99088: .../nss_dp_ethtools.c: In function 'nss_dp_get_link_ksettings':
99089: .../nss_dp_ethtools.c:130:11: error: 'struct ethtool_link_settings' has no member named 'mdix'
99090:   cmd->base.mdix = ETH_TP_MDI_INVALID;
99091:            ^
99092: make[5]: *** [scripts/Makefile.build:297: .../nss_dp_ethtools.o] Error 1
99098:     ERROR: package/kernel/qca/qca-nss-dp failed to build.
99099: make[2]: *** [package/Makefile:120: package/kernel/qca/qca-nss-dp/compile] Error 1
99100: make[2]: *** Waiting for unfinished jobs....
```

后面 101073 / 101075 的 `Error 2` 只是 `make` 向上冒泡的汇总，末尾 `util-linux` 编译成功是并行任务收尾，**不是失败点**。日志里 14 条 `make[] ***` 中，除 99092~99099 这一组外全是 `(ignored)`。

**唯一错误是我给的 ethtool 补丁里写了一个 Linux 5.4 不存在的结构体字段。**

我核对了 Linux 5.4 官方头文件 `include/uapi/linux/ethtool.h`：

```c
struct ethtool_link_settings {
	__u32	cmd;
	__u32	speed;
	__u8	duplex;
	__u8	port;
	__u8	phy_address;
	__u8	autoneg;
	__u8	mdio_support;
	__u8	eth_tp_mdix;        /* ← 正确名字 */
	__u8	eth_tp_mdix_ctrl;   /* ← 正确名字 */
	...
};
```

字段叫 `eth_tp_mdix` / `eth_tp_mdix_ctrl`，**没有 `mdix`**。我写成了 `cmd->base.mdix`，编译器第一个错误就停了。QSDK 5.4 变体还可能动过这个结构体，所以最稳的处理是**两行 mdix 相关赋值全部删掉**——它们对「显示 1000M / Full」本来就毫无必要。

---

## 2. 修好的补丁

新补丁基于 `CodeLinaro-mirror/qsdk_oss_lklm_nss-dp @ NHSS.QSDK.11.5.0.5` 的真实 `nss_dp_ethtools.c` 重新生成：

- 只保留 `speed` / `duplex` / `port` / `phy_address` / `autoneg` 五个在所有 5.4 变体里都稳定的字段
- 删掉 `base.mdix`、`base.eth_tp_mdix_ctrl` 两行
- `.get_link_ksettings` 仍指向自定义 `nss_dp_get_link_ksettings()`
- 读 `dp_priv->phydev` 的真实速率，无 PHY 的 fixed-link CPU 口填 `SPEED_1000 / DUPLEX_FULL`
- **数据路径一行不动**：WiFi、NSS、WDS offload 全部保留

已验证：

| 检查 | 结果 |
|---|---|
| `patch -p1 --dry-run` 对 11.5.0.5 真实源码 | ✅ rc=0 |
| 实际应用后函数内 `cmd->base.*` 字段 | ✅ 仅 `autoneg/duplex/phy_address/port/speed` |
| 补丁内是否还有 `cmd->base.mdix` | ✅ 无 |
| `ops` 指针替换 | ✅ `.get_link_ksettings = &nss_dp_get_link_ksettings,` |
| Linux 5.4 `ethtool_link_ksettings_zero/add_link_mode` 宏 | ✅ 存在于 `include/linux/ethtool.h` |

---

## 3. 你要做的：只覆盖 1 个文件，两个仓库都覆盖

**必需**：把 `patches/999-nss-dp-ethtool-fixed-link.patch` 覆盖到

```
gggbin2026/Actions-OpenWrt-RAX3000Q  →  patches/999-nss-dp-ethtool-fixed-link.patch
gggbin2026/vs010-openwrt             →  patches/999-nss-dp-ethtool-fixed-link.patch
```

**两份内容完全相同**，VS010 不换的话，编到 `qca-nss-dp` 会挂在同一个地方。

**可选**：把 `inject-ethtool-patch.sh` 覆盖到两个仓库根目录。它加了一道防呆：若仓库里还是含 `base.mdix` 的旧补丁，直接在注入阶段 `::error::` 拦下，不会白跑一小时编译。不覆盖也能编（只要补丁文件换对了）。

**一律不要动**：

- `.config` / `slim.sh` —— IPv6 关闭版本是对的
- `diy-part2.sh` —— VS010 的设备符号修复版 `6c3f3de` 保留
- `build-openwrt.yml` —— 原版就行；上一轮那个「保守 IPv6 + 失败日志摘录」的 workflow 别用
- `files/`、`feeds.conf.default`、`diy-part1.sh`

然后：

- RAX3000Q → **`Build RAX3000Q slim WDS`** → Run workflow，`ssh=false`
- VS010 → **`Build VS010 slim WDS (QSDK 5.4)`** → Run workflow，`ssh=false`、`use_nwrt_dump_dts=false`

---

## 4. 顺带解释日志开头那一堆 WARNING

```
WARNING: Makefile '.../qca-nss-ecm/Makefile' has a dependency on
'kmod-shortcut-fe-drv', which does not exist
... 共 26 条
```

这些是 `make defconfig` 扫描 feed 时，QSDK 树里部分包的 Makefile 声明了当前 5 个 feed（immortalwrt packages / luci / routing / telephony / video）里没有的可选依赖。**全部是 `(ignored)` 级别的依赖告警，不是错误**，日志里 99000 行编译都过去了。它们不影响出固件，不用修 feed。

同理 `qca-nss-fw` 那两条 `Error 1 (ignored)` 是打包固件 blob 时的忽略项，也不是失败点。

---

## 5. 修好后验收

```sh
ethtool eth0 | grep -E 'Speed|Duplex'      # 1000Mb/s / Full
portstat                                    # swconfig 真值 + 关联 + 4addr
iperf3 -c <对端有线PC> -P 4 -t 60            # 900M+ 才是真千兆
```

WDS 双端配置不变：A 端 AP-WDS 保留 DHCP，B 端 STA-WDS 关 DHCP + 同网段静态 IP，两端 `wds=1`、`psk2+ccmp`、锁 ch149 HE80。决定性判据是 B 端下挂 PC 从 A 端 DHCP 拿到地址且保留真实 MAC。

**WiFi 的 `iw station dump` bitrate 显示仍然修不了**（NSS offload 统计不回灌 mac80211），用 iperf3 看真值。

---

## 6. 边界

- **没跑真实 `make`**（本会话缺 toolchain / 磁盘内存不足）。已验证的是：补丁基于真实 11.5.0.5 源码生成并 dry-run 通过、实际应用后字段集合正确、Linux 5.4 头文件字段逐一核对、防呆脚本对新旧补丁的判定正确。编译通过要你在 Actions 点一次。
- 这次只修 `nss_dp_ethtools.c` 的字段错误。若下一轮还挂在别的包（例如 `qca-nss-ecm` 这次因并行没轮到），把新的 `build.log` 最后 200 行发我即可。
- 刷机老规矩：TTL 只接 TX/RX/GND 别碰 1.8V，**先备份 `0:ART`**；VS010 首刷还要用 `swconfig dev switch1 show` 逐个插线核对端口映射。
