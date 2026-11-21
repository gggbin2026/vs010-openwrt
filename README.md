# CUCC VS010 · QSDK 5.4 极简 WDS 网桥固件

> **开机即桥**：两台刷同一份固件，自动分成 AP-WDS 主端 / STA-WDS 客户端，纯二层透传。
> 不是路由模式，不是 airOS，**不含 TDMA**。
> GitHub Actions 自动编译，成功后固件自动发布到本仓库 **Releases**（永久保留、按时间戳存档）。

## 一眼看懂

| 项 | 值 |
|---|---|
| 适用机型 | 中国联通 **CUCC VS010**（Unicom AX3000） |
| 设备标识 | `cucc_vs010`（底座没有此机型，由本仓库 `diy-part2.sh` 注入） |
| 固件文件 | `QSDK-...-squashfs-nand-factory.ubi`（刷机 / 救砖）；`...-sysupgrade.bin` 用于系统内升级 |
| **管理 IP** | **AP 主端 `192.168.1.2` / STA 客户端 `192.168.1.3`**，`/24`，挂在 `br-lan` |
| 角色分配 | MAC 尾数奇数 = AP、偶数 = STA；`bridge-role ap` / `bridge-role sta` 可改 |
| DHCP | 默认**开**（池 `192.168.1.100–199` / 12h）；`bridge-dhcp off` 关回纯透传 |
| IPv6 | 默认**开**（LAN ULA + RA / DHCPv6）；`bridge-ipv6 off` 关 |
| 默认 WiFi | SSID `QSDK-BRIDGE` / 密钥 `bridge-500m-change-me`（**多对链路务必改 SSID 与密钥**） |
| 默认账号 | `root` / 空密码（首次登录请设密码） |
| 时区 · 无线国别 | `Asia/Shanghai`（CST-8）· **全部射频 `country=CN`** |
| 内核 | **Linux 5.4**（QSDK 5.4 分支，实测 `5.4.164`） |
| QSDK 基线 | **NHSS.QSDK.11.5.0.5** |
| 架构 | 32 位 ARM（`arm_cortex-a7+neon-vfpv4`） |
| 版本标识 | 无 `v1.0` 式版本号，以 Release tag `fw-YYYYMMDD-HHMMSS-rN`（上海时间）为准 |
| 开源性 | **混合：构建源码开源，但含高通闭源二进制**（见下） |

> 容易混淆的地址：`192.168.1.8` 是刷机时**电脑**该设的 IP（部分 U-Boot）；`192.168.2.1` 是 **VS010 原厂固件**的页面，不是本固件地址；`192.168.1.1` 是本固件早期版本默认地址，已不再使用。

## 机器硬件

| 部件 | 型号 |
|---|---|
| SoC | Qualcomm **IPQ5018** 双核 A53 @ 1 GHz |
| 内存 | 256 MB DDR3L |
| 闪存 | 128 MB SPI-NAND（**F5D01G41LB**） |
| 5G WiFi | QCN6102 2×2，802.11ax |
| 2.4G WiFi | IPQ5018 内置 |
| 交换芯片 | **QCA8337-AL3C**（QSDK `qca-ssdk` / `ess-switch`，非主线 DSA） |
| 网口 | 1×WAN + 3×LAN 千兆 |

固件只把 LAN 口并进 `br-lan`；**WAN 口闲置，未并入桥**。
VS010 的 `02_network` 端口映射是参照 PZ-L8 推的初值，**首刷请四个 RJ45 口逐个插线核对**。

## 这个固件做了什么

1. **开机自动成桥**：按 MAC 尾数分 AP / STA，写死管理 IP `.2` / `.3`，不做 NAT、防火墙全放行、`br-lan` 开 STP。
2. **WDS 4addr + NSS 硬件转发**：保留底座 4 个 QSDK WDS offload 补丁（149 / 211-002 / 216 / 330）；5G 锁 `ch149`、WPA2-AES、`wds=1`、`distance=550`。
3. **补上底座缺失的 VS010 设备层**：注入 `Device/cucc_vs010`（插在 `BuildImage` 之前，否则 Kconfig 设备符号会丢）、DTS、`02_network`、`11-ath11k-caldata`（从本机 `0:ART` 提校准，不用别的机器 BDF）。
4. **修网口 probe（本机型关键）**：`use_nwrt_dump_dts` 默认 `true`，使用从 VS010 实物 `/sys/firmware/fdt` 反编译的硬件真值 DTS —— 含 **22 个 `clock-names` + 6 个 `reset-names`**，缺了它们 `ess-switch` 不 probe，表现就是「能进系统但 `ip link` 无 ethX、四个网口插哪个都没反应」。
5. **修网口速率显示**：自写 `nss-dp` 的 `get_link_ksettings` 补丁（已修掉早期 `cmd->base.mdix` 字段错误），`ethtool eth0` 报 `1000Mb/s / Full`。
6. **NAND 兼容 / 编译期修复**：扩展底座 `421` 补丁补 GD5Fx ID；打开 `MAC80211_DEBUGFS` + `MAC80211_MESH`；预取 `ath-kernel` 私有 tarball 防下载断流；锁死 `kmod-qca-ssdk-nohnat` 等 5 个网卡驱动并在编译期硬校验。
7. **运行期自检**：`nic-guard` 开机把 `ip link` / `swconfig list` / `dmesg` 真因打到串口，`br-lan` 起不来时给 `ethX` 临时配 `192.168.1.9/24` 供 SSH 急救。
8. **本地化与发布**：上海时区、全射频 CN、固件名统一 `QSDK-` 前缀、每次编译自动建带时间戳的 Release（默认全部永久保留，至少 5 次）。

## 开源还是闭源

**混合，不是纯开源固件，也不是官方固件。**

- **开源部分**：OpenWrt / ImmortalWrt 用户态、Linux 内核主体、本仓库全部 `.config`、脚本、`vs010/` DTS、`files/`、workflow，按 GPL-2.0 / MIT 风格公开，可自行编译复现。
- **闭源二进制**：高通 QSDK 的 WiFi 驱动（ath11k QSDK 分支）、NSS 固件 `qca-nss-fw-ipq50xx-retail`、QCA8337 交换相关初始化数据、从本机 `0:ART` 提取的射频校准 BDF —— 以 blob 形式随底座引入，**没有源码**。

所以能自己编译、能改配置，但**无法 100% 从源码重建相同二进制**。本仓库 fork 自 `xiangye277/vs010-openwrt`（那是 6.x + DSA 路线），现已改为 5.4-QSDK + swconfig 路线，两套交换栈互斥；仓库里若残留旧 `firmware/`、`oem_extract/`、根目录 DSA 版 DTS，**都不参与本编译**，尤其 `qcn6122_bdwlan.bin` 只有几十字节是 404 页面，别当 BDF 用。

## 版本号与内核

- 没有语义化版本号。每次成功编译生成一个独立 Release，例如 `fw-20261121-140642-r8` = 上海时间 2026-11-21 14:06:42、第 8 次 run；所有 Release 永久保留。
- 系统内查真实值：`uname -r`、`cat /etc/openwrt_release`。
- 底座 `kkstone/immortalwrt-ipq50xx @ openwrt-21.02`，内核 **Linux 5.4 / QSDK 5.4（5.4.164）**，QSDK **NHSS.11.5.0.5**，32 位 ARM。
- 与恩山那类 **OpenWrt 25.12 / Linux 6.12 + 开源 NSS** 固件是不同路线：那个要 64 位不死 U-Boot、默认 `20.0.0.1`，且**目前没有 VS010 适配**，不能与本固件互刷。

## 刷机与验收

**刷机**：用 `QSDK-*-nand-factory.ubi` 进不死 U-Boot web 刷。
TTL 串口只接 **TX / RX / GND，别碰 1.8V**；动手前**先备份 `0:ART`**。
`192.168.2.1` 是原厂固件页面（原厂 `.img` 走 Web API），不代表能刷本 UBI；首次刷建议 TTL 在手。开机等 1–3 分钟。

```sh
nic-guard                                 # 网卡 / 交换芯片自检，VS010 必看
swconfig list                             # 空 = 交换芯片没注册
ip link                                   # 不带 grep，别漏掉 eth2 / eth3
bridge-status                             # 角色 / 4addr / STP / 管理 IP
date                                      # 应显示 CST
uci show wireless | grep country          # 每个射频都是 CN
ethtool eth0 | grep -E 'Speed|Duplex'     # 1000Mb/s / Full
iperf3 -c <对端PC> -P 4 -t 60 -O 3        # 900M+ 才是真千兆
```

**若 `nic-guard` 报「内核里没有任何 ethX」**：这是交换驱动 probe 失败（DTS 缺时钟 / 复位），用户态命令修不了。确认 workflow 里 `use_nwrt_dump_dts = true` 后重编。
**TTL 还能敲命令 = 没砖**，U-Boot web 仍可重刷 `factory.ubi`；别拆机、别上编程器。

- 两端在同一广播域时**只留一个 DHCP**（`bridge-dhcp off` 关掉副端）；上游已有主路由发地址则两端都关。
- WiFi 的 `iw station dump` bitrate 可能显示 N/A（NSS offload 不回灌统计），**以 `iperf3` 为准**。

## 历史 Release 差异（重要）

本仓库 2026-11-21 早的 `fw-...-r8` 等旧固件与当前源码**不同**：

| | 旧 Release（r8 等） | 当前源码 |
|---|---|---|
| 固件名前缀 | `immortalwrt-` | **`QSDK-`** |
| IPv6 / DHCP | 全关，电脑需手动设 `192.168.1.10` | 默认开，可用命令关 |
| VS010 DTS | QSDK 模板改写版（缺时钟/复位） | **NWRT 硬件真值 DTS，默认启用** |
| 网卡加固 / 自检 | 无 | 有（锁 5 驱动 + `nic-guard`） |
| 管理 IP | 同为 `.2` / `.3` | 同为 `.2` / `.3` |

> 旧版刷进去后「能进系统但插网线没反应」就是 DTS 那一行造成的；**重编后重刷即可，机器没坏**。

## 风险与边界

- 非官方固件，首次刷有变砖风险；TTL 与 `0:ART` 备份是底线。
- **不含 TDMA / airMAX / 对准灯 / 一键配对**；TDMA 是 UBNT 私有 MAC 协议，无法编进本套 5.4-QSDK 开源栈，且 500 m 单跳点对点开 TDMA 反而掉吞吐。
- 多台同时开机时默认 SSID / 密钥相同会让 STA 乱关联 —— 改密钥、多对链路各用不同 SSID，或给客户端锁 `bssid`。
- 跨机型（VS010 ↔ RAX3000Q）混搭 WDS 未实测；建议同型号成对使用。
- 端口 → RJ45 丝印映射是推的初值，**首刷逐个插线核对**；若 `swconfig list` 显示的设备名不是 `switch1`，`02_network` 要按实际名字改。

## 相关命令速查

```sh
bridge-role ap|sta          # 改主端 / 客户端
bridge-dhcp on|off|status   # DHCP 开关
bridge-ipv6 on|off|status   # IPv6 RA / DHCPv6 开关
bridge-distance 550         # 改 ACK 距离
bridge-status               # 一屏看全
portstat                    # swconfig 真实端口状态
nic-guard                   # 网卡自检 + 急救地址
```
