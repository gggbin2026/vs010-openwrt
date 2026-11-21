# CUCC VS010 · QSDK 5.4 极简 WDS 网桥固件

> **开机即桥**：两台刷同一份固件，自动分成 AP-WDS 主端 / STA-WDS 客户端，纯二层透传。
> 不是路由模式，不是 airOS，**不含 TDMA**。
> GitHub Actions 自动编译，成功后固件自动发布到本仓库 **Releases**（永久保留、按时间戳存档）。

## 一眼看懂

| 项 | 值 |
|---|---|
| 适用机型 | 中国联通 **CUCC VS010**（Unicom AX3000） |
| 设备标识 | `cucc_vs010`（底座没有此机型，由本仓库 `diy-part2.sh` 注入） |
| 固件文件 | **`Nwrt-QSDK12.2-...-squashfs-nand-factory.ubi`**（刷机 / 救砖）；`...-sysupgrade.bin` 用于系统内升级 |
| **管理 IP** | **`192.168.1.241`** / `/24`，挂在 `br-lan`；**两台成对用时第二台改成 `192.168.1.242`**（见下方警告） |
| 角色分配 | MAC 尾数奇数 = AP、偶数 = STA；`bridge-role ap` / `bridge-role sta` 可改 |
| DHCP | 默认**开**（池 `192.168.1.100–199` / 12h）；`bridge-dhcp off` 关回纯透传 |
| IPv6 | **编译期关闭**（内核无 IPv6 栈、`WAN6` 已删除、无 RA/DHCPv6/NDP/ULA）；`bridge-ipv6` 只能查状态 |
| 默认 WiFi | WDS 链路 SSID **`WDS_AP`** / 密钥 **`WDS123456`**（5G ch149 / WPA2-AES / `wds=1`） |
| 默认账号 | **`root` / `admin`**（首次开机即生效，LuCI 不再提示未设置密码） |
| 时区 · 无线国别 | `Asia/Shanghai`（CST-8）· **全部射频 `country=CN`** |
| 内核 | **Linux 5.4**（QSDK 5.4 分支，实测 `5.4.164`） |
| QSDK 基线 | **NHSS.QSDK.11.5.0.5** |
| 架构 | 32 位 ARM（`arm_cortex-a7+neon-vfpv4`） |
| 版本标识 | 无 `v1.0` 式版本号，以 Release tag `fw-YYYYMMDD-HHMMSS-rN`（上海时间）为准 |
| 主题 / 时间 | **ARGON（已启用并硬校验）**；`SOURCE_DATE_EPOCH` = 本次编译真实时刻，写入 `/etc/compile_time` 与登录 banner；NTP 开机同步 |
| STP | **开启**（`network.lan.stp=1`） |
| ICMP 重定向 | **关闭发送与接受**（`net.ipv4.conf.*.send_redirects/accept_redirects=0`） |
| 命名说明 | `Nwrt-QSDK12.2-` 仅为文件名前缀，实际基线仍是 **Linux 5.4 / NHSS.11.5.0.5**，不是 QSDK 12.2 |
| 改动日志 | [CHANGELOG.md](CHANGELOG.md)（每次修复）· [BUILD_HISTORY.md](BUILD_HISTORY.md)（每次编译自动追加） |
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

**有线口已修**：关闭 VLAN、`WAN`/`WAN6` 段删除、`eth0` 与 `eth1` 一并并入 `br-lan`（傻交换桥），四个 RJ45 口都能拿 DHCP。修复了「无线能拿地址、有线插上没反应」。
VS010 的 `02_network` 端口映射是参照 PZ-L8 推的初值，**首刷请四个 RJ45 口逐个插线核对**。

## 这个固件做了什么

1. **开机自动成桥**：按 MAC 尾数分 AP / STA，固定管理 IP `192.168.1.241`，不做 NAT、防火墙全放行、`br-lan` 开 STP；`bridge-dhcp off` 关掉 DHCP 后即为纯二层透传。
2. **WDS 4addr + NSS 硬件转发**：保留底座 4 个 QSDK WDS offload 补丁（149 / 211-002 / 216 / 330）；5G 锁 `ch149`、WPA2-AES、`wds=1`、`distance=550`。
3. **补上底座缺失的 VS010 设备层**：注入 `Device/cucc_vs010`（插在 `BuildImage` 之前，否则 Kconfig 设备符号会丢）、DTS、`02_network`、`11-ath11k-caldata`（从本机 `0:ART` 提校准，不用别的机器 BDF）。
4. **修网口 probe（本机型关键）**：`use_nwrt_dump_dts` 默认 `true`，使用从 VS010 实物 `/sys/firmware/fdt` 反编译的硬件真值 DTS —— 含 **22 个 `clock-names` + 6 个 `reset-names`**，缺了它们 `ess-switch` 不 probe，表现就是「能进系统但 `ip link` 无 ethX、四个网口插哪个都没反应」。
5. **修网口速率显示**：自写 `nss-dp` 的 `get_link_ksettings` 补丁（已修掉早期 `cmd->base.mdix` 字段错误），`ethtool eth0` 报 `1000Mb/s / Full`。
6. **NAND 兼容 / 编译期修复**：扩展底座 `421` 补丁补 GD5Fx ID；打开 `MAC80211_DEBUGFS` + `MAC80211_MESH`；预取 `ath-kernel` 私有 tarball 防下载断流；锁死 `kmod-qca-ssdk-nohnat` 等 5 个网卡驱动并在编译期硬校验。
7. **运行期自检**：`nic-guard` 开机把 `ip link` / `swconfig list` / `dmesg` 真因打到串口，`br-lan` 起不来时给 `ethX` 临时配 `192.168.1.9/24` 供 SSH 急救。
8. **本地化与发布**：上海时区、全射频 CN、ARGON 主题、固件名统一 `Nwrt-QSDK12.2-` 前缀、每次编译自动建带时间戳的 Release（永久保留 ≥5 次），并把构建记录写回 `BUILD_HISTORY.md`。

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

## 本版定制参数（2026-11-21）

| 项 | 值 |
|---|---|
| 管理 IP | `192.168.1.241` / `255.255.255.0` |
| 账号密码 | `root` / `admin` |
| WDS SSID / 密钥 | `WDS_AP` / `WDS123456` |
| WDS 射频 | 5G `ch149` / WPA2-AES / `wds=1`(4addr) / `distance=550` |
| STP | 开 |
| 主题 | ARGON（`luci-theme-argon`，中文） |
| 时区 | `Asia/Shanghai`（CST-8）+ NTP 同步；编译时刻写进 `/etc/compile_time` |
| IPv6 | 编译期关闭，`WAN6` 删除 |
| ICMP 重定向 | 关闭发送 / 接受 |
| DHCP | 默认开（池 `192.168.1.100–199` / 12h） |

> ⚠️ **两台成对做 WDS 时 IP 会冲突**：本版按要求把两端都写死 `192.168.1.241`。
> 第二台刷完、能 SSH 后马上改一次，否则 ARP 混乱、管理页面时好时坏：
> ```sh
> uci set network.lan.ipaddr='192.168.1.242'
> uci commit network && /etc/init.d/network restart
> ```

### 有线口为什么之前不通，这版怎么修

LuCI 交换机页显示 `switch1 - QCA AR8337`、VLAN 1 配置也正确，但
`ip link` 里 `eth1` 没 UP、`eth0` 是 `wan/proto=none` 不进桥 —— 无线 VAP
直接挂 `br-lan` 所以能拿 DHCP，有线帧却进不了桥。

本版三处一起改（配置层 + 运行层双保险）：

1. `99-bridge-ready`：删 `network.wan` / `wan6`、`switch.enable_vlan=0`、
   `br-lan` 的 ports 设为 `eth0 eth1`
2. `nic-guard`：开机等 `switch1` 注册后重放「关 VLAN → 拉起 eth0/eth1 → 并入 br-lan」
3. 两个 CPU 口都进桥，**不管 RAX3000Q / VS010 的 GMAC 映射正反都通**

纯二层 WDS 桥本来就不需要 WAN/LAN 隔离，关 VLAN 当傻交换用更稳。

### 编译时间

workflow 把 `SOURCE_DATE_EPOCH` 设为**本次编译的真实时刻**（不再是底座固定旧日期），
同时写 `openwrt/files/etc/compile_time`；首次开机把它追加到 `/etc/banner`，
`cat /etc/compile_time` 可查。开机后 `sysntpd` 用国内 NTP 把系统时间同步到当前。

## 刷机与验收

**刷机**：用 `Nwrt-QSDK12.2-*-nand-factory.ubi` 进不死 U-Boot web 刷。
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
| 固件名前缀 | `immortalwrt-` | **`Nwrt-QSDK12.2-`** |
| IPv6 / DHCP | 全关，电脑需手动设 `192.168.1.10` | IPv6 编译期关 / DHCP 默认开，可关 |
| VS010 DTS | QSDK 模板改写版（缺时钟/复位） | **模板 DTS 默认 `false`（实测稳定）；真值 DTS 为实验开关** |
| 网卡加固 / 自检 | 无 | 有（锁 5 驱动 + `nic-guard`） |
| 管理 IP | 同为 `.2` / `.3` | 固定 `.241`（第二台改 `.242`） |

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
bridge-ipv6 status          # IPv6 状态提示（本版编译期关闭，无法开启）
bridge-distance 550         # 改 ACK 距离
bridge-status               # 一屏看全
portstat                    # swconfig 真实端口状态
nic-guard                   # 网卡自检 + 急救地址
```
