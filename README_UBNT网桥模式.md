# 开机即 UBNT 式网桥 —— 两仓库通用说明

适用：
- `gggbin2026/Actions-OpenWrt-RAX3000Q` → 用 `UBNT_RAX3000Q.zip`
- `gggbin2026/vs010-openwrt` → 用 `UBNT_VS010.zip`

两个 zip 都是**全量覆盖包**，已经把之前所有修复合并好了，覆盖完直接 Run workflow 即可。

---

## ⚠️ 第一件事：这包顺手修好了编译失败

你之前两份日志都挂在同一个地方：

```
nss_dp_ethtools.c:130:11: error: 'struct ethtool_link_settings' has no member named 'mdix'
cmd->base.mdix = ETH_TP_MDI_INVALID;
```

包里的 `patches/999-nss-dp-ethtool-fixed-link.patch` 已换成修正版（2348 B，**不含 `cmd->base.mdix`**），`inject-ethtool-patch.sh` 也带旧补丁防呆。两个仓库线上目前仍是 2328 B 的旧版，**必须覆盖**，否则这一轮还是会白跑一小时。

`UBNT_VS010.zip` 里还带了设备符号修复版 `diy-part2.sh`（`TARGET_DEVICES += cucc_vs010` 插到 `BuildImage` 之前）。RAX3000Q 不需要这个，保持原样。

---

## 刷完是什么状态

**插电开机就是桥，不用 SSH 配**：

| 项 | 值 |
|---|---|
| 分角色 | 按 MAC 尾数自动：奇数 → **AP-WDS**，偶数 → **STA-WDS** |
| 管理 IP | AP `192.168.1.2` / STA `192.168.1.3`，掩码 /24 |
| 桥 | `br-lan` = LAN 口 + 5G WDS 无线；开 STP |
| DHCP | **两端都不发**（`dhcp.lan.ignore=1`），地址由上游透传 |
| NAT / WAN | 不做 NAT，`wan` 设 `proto=none` 不取地址 |
| IPv6 | 内核、配置面、RA/DHCPv6/NDP 全关 |
| 无线 | SSID `QSDK-BRIDGE`、WPA2-AES、ch149、`wds=1`(4addr) |
| 距离 / 功率 | `distance=550`、`txpower=20`（原装天线） |
| 插件 | 121 / 137 个包，0 个 luci-app |

开机脚本是 `files/etc/uci-defaults/99-zz-bridge-role`，只跑一次然后自删；原有的 `99-bridge-ready` 先跑，负责清 IPv6、开 STP、防火墙全放行，两者不冲突（字母序 `99-b` 在 `99-z` 前）。

### 和真 UBNT airOS 的区别（说清楚，别误会）

行为等价，**不是 airOS**：没有 airMAX TDMA、没有 UNMS/手机 App、没有信号对准灯和一键配对、没有频谱扫描。它就是 OpenWrt/QSDK 上的纯二层 WDS 桥，靠 `bridge-status` 和 `iperf3` 验收。500 米这种距离本来也不需要 TDMA，专用协议给不了额外收益。

---

## 覆盖步骤

1. 解压对应 zip，**包内文件按原路径全部覆盖 + 新增的照加**
2. 确认 `.github/workflows/` 里只有一个 `build-openwrt.yml`（旧的 `build.yml` 要删）
3. VS010 建议顺手清掉 `firmware/`、`oem_extract/`、根目录 `ipq5018-vs010.dts` 这些 DSA 老残留
4. Actions → `Build RAX3000Q slim WDS` / `Build VS010 slim WDS (QSDK 5.4)` → Run workflow
   - `ssh` 留 `false`，`use_nwrt_dump_dts` 留 `false`
5. 刷机：QSDK U-Boot 电脑设 `192.168.1.8` + **LAN1 口**；TTL 只接 TX/RX/GND 别碰 1.8V；**先备份 `0:ART`**

---

## 刷完必做三件（很重要）

### 1. 改密钥，多台机器别撞

```sh
uci set wireless.@wifi-iface[1].key='你自己的密码'
uci set wireless.@wifi-iface[1].ssid='BRIDGE-A'   # 多对链路各用不同 SSID
uci commit wireless; wifi reload
```

同一份固件刷到多台 3000Q，**默认 SSID 和密钥全一样**，同时开机 STA 会随便关联到某个 AP。要么成对使用、其余断电，要么每对改不同 SSID。

### 2. 确认两台角色是一 AP 一 STA

```sh
bridge-status                 # 看角色
bridge-role sta               # 两台都是 ap/都是 sta 时，改其中一台
bridge-role ap
bridge-role show              # 只看不改
```

MAC 尾数同奇偶会分到同一角色，这时必须手动改一台。

### 3. 上游没有 DHCP 时

UBNT bridge 模式默认本机不发地址，靠上游主路由透传。若链路上游没有 DHCP，在 **AP 端**开一个：

```sh
bridge-dhcp on      # 关掉用 bridge-dhcp off
```

---

## 常用命令

| 命令 | 作用 |
|---|---|
| `bridge-status` | 角色 / IP / SSID / 关联 / 端口真值 / 4addr 一屏看完 |
| `bridge-role {ap\|sta\|auto\|show}` | 改角色；`auto` 恢复按 MAC 自动分 |
| `bridge-distance 550` | 按实际距离×1.1 设 ACK 超时，两端都要设 |
| `bridge-radio radio0` | 极少数机器 5G 不是 `radio1` 时手动指定 |
| `portstat` | `swconfig` 的真实 `1000baseT full-duplex` |
| `iperf3 -P 4 -t 60` | 真吞吐，别看 LuCI 格子 |

**决定性验收**：STA 端下挂 PC 能否从上游 DHCP 拿到地址且保留真实 MAC —— 拿到就说明 4addr 二层透传通了。

---

## 网口速率这次能正常显示了吗

能。修正版 ethtool 补丁把 `.get_link_ksettings` 从取 `netdev->phydev`（一直是 NULL）的 `phy_ethtool_*` 换成读 `dp_priv->phydev` 的自定义回调，fixed-link CPU 口填 `1000Mb/s / Full`，刷完 `ethtool eth0` 应报 `1000Mb/s / Full`，LuCI 格子跟着正常。

**但 `iw station dump` 里的 WiFi `tx/rx bitrate` 仍可能是 N/A** —— QSDK NSS offload 下统计不回灌 mac80211，不是速率低。用 `iperf3` 看真值。

---

## 边界（不打包票的部分）

- **没有跑过真实 `make`**：本会话缺 toolchain / 磁盘 / 内存。已验证：6 个 shell 脚本 `sh -n` 全过、模拟 uci 环境下开机分角色跑了两轮（奇→ap / 偶→sta，IP、WDS、ch149、DHCP ignore、wan proto=none 全部落位且幂等）、手动 `bridge-role sta` 生效、ethtool 补丁对 `NHSS.QSDK.11.5.0.5` 源码 dry-run 通过、注入脚本实跑通过。**编译通过要你在 Actions 点一次。**
- **WAN 口没并进桥**：QSDK swconfig 的端口/VLAN 映射在 VS010 上还是推的初值、没实测，乱改会把机器搞成不通。所以这版是「LAN 口 + 无线」进桥，WAN 口闲置。确认映射后再按需合并。
- **ethtool 补丁只改查询返回，不动数据路径**；若 `iperf3` 只有 100M 且 CRC 涨，那是线材/端口物理问题，跟补丁无关。
- 5G 射频默认按 `radio1` 识别（先按 channel>36 / band 探测）。个别机器不是的话用 `bridge-radio` 改。
- VS010 的 ART 校准偏移暂借 RAX3000Q 的 `0x1000`/`0x26800`，5G 异常先看 `dmesg | grep -i ath11k`。
