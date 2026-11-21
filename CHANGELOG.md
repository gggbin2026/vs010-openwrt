# 修复与改动日志（CHANGELOG）· CUCC VS010

> 本文件记录**每一次修改/修复**：现象 → 根因 → 改了哪些文件 → 验证到什么程度。
> 目的是「防止有问题」——下一轮出状况时能立刻定位是哪次改动引入的，不用从头猜。
> 每次编译的自动记录见 [BUILD_HISTORY.md](BUILD_HISTORY.md)；产物在 Releases（永久保留）。
> 时间均为北京时间（Asia/Shanghai）。**没跑真实 `make` 的轮次都明确标注**。

---

## 当前生效配置速查（先看这张）

| 项 | 值 |
|---|---|
| 固件文件名前缀 | **`Nwrt-QSDK12.2-`**（仅为命名，实际基线 Linux 5.4 / NHSS.11.5.0.5） |
| 内核 | Linux 5.4.164 / QSDK 5.4 / 32 位 ARM |
| 管理 IP | `192.168.1.241` /24（两台成对时第二台改 `.242`） |
| 账号 | `root` / `admin` |
| WDS | SSID `WDS_AP` / 密钥 `WDS123456` / 5G ch149 / WPA2-AES / `wds=1` (4addr) |
| STP | 开 |
| 主题 | **ARGON**（`CONFIG_PACKAGE_luci-theme-argon=y` + `luci.main.mediaurlbase=/luci-static/argon`） |
| IPv6 | **编译期关闭**；`WAN6` 删除，无 ULA / RA / DHCPv6 / NDP |
| ICMP 重定向 | 关闭发送与接受 |
| DHCP | 默认开（池 `192.168.1.100–199` / 12h），`bridge-dhcp off` 可关 |
| 时区 / 国别 | `Asia/Shanghai`（CST-8）+ NTP；全部射频 `country=CN` |
| 有线口 | 关 VLAN，`eth0` + `eth1` 一并进 `br-lan`（傻交换桥） |
| 版本标识 | 无 `v1.0`，以 Release tag `fw-YYYYMMDD-HHMMSS-rN` 为准 |

---

## 时间线

### 2026-11-20 · 起步与第一批失败
| # | 现象 | 根因 | 改动 |
|---|---|---|---|
| 1 | 两个仓库首次编译失败 | 底座设备符号、`nss-dp` ethtool 补丁引用了不存在的 `cmd->base.mdix` 字段 | 修正 ethtool 补丁，去掉 `mdix`；`.config` 补齐设备符号 / 256M / NSS 开关 |
| 2 | 编译到 mac80211 报 `struct ath11k has no member named debug` | `MAC80211_DEBUGFS` 被精简关掉，QSDK 11.5 的 debugfs 代码仍引用 | 打开 `MAC80211_DEBUGFS` |
| 3 | 打开 DEBUGFS 后编不过：`ath11k_nss_mesh_config_path` 未声明、`sta_info` 无 `mesh` 成员 | `MAC80211_MESH` 被 `slim.sh` 精简掉，QSDK 的 `300-ath11k-nss-mesh-offload` 补丁在函数定义/声明处有 `#ifdef CPTCFG_MAC80211_MESH`，调用处没有 | `.config` + `slim.sh` + workflow 三处同时强制 `MAC80211_MESH=y`；DEBUGFS 保持 `=y`。与 WDS 不冲突（编入代码 ≠ 启用 802.11s） |
| 4 | `GnuTLS recv error`、ath-kernel 私有 tarball 下载断流 | QSDK 私有包无官方镜像，靠 codelinaro 现场 clone | 新增 `prefetch-ath-kernel.sh`：镜像 → GitLab archive → git clone 三路线，预置到 `openwrt/dl` |
| 5 | `Prefetch` 步骤报 `No such file or directory` + `Broken pipe` | 脚本里 `OUT` 是相对路径，`( cd "$TMP" && tar ... > "$OUT" )` 子 shell 跳到临时目录后相对路径失效 | `DL` 用 `pwd -P` 绝对化；先写 `$TMP/pack.tar.xz` 再 `mv`；三条路线全挂也只 warning 不阻断 |
| 6 | 一次 run 在 29 分钟 `exit 143` / `Kernel panic` 前被终止 | runner 收到平台侧 shutdown signal（非人为取消、非超时、非代码） | 不改代码；结论：错峰跑、别重复点 Run |

> 验证边界：以上多为编译失败日志定位 + 本地 `bash -n` / 脚本模拟，**真实 `make` 通过以 Actions 成功 run 为准**。

### 2026-11-21 上午 · 首次跑通与发布
| # | 现象 | 根因 | 改动 |
|---|---|---|---|
| 7 | 编译成功但仓库 Releases 为空 | workflow 只保留 `upload-artifact`，原本就没写发布步骤 | 新增 `Publish firmware to Releases`：runner 自带 `gh` CLI，tag = 上海时间戳 + run 号，`KEEP_RELEASES=0` 全部永久保留（硬保底 ≥5），同秒重跑 `--clobber` 兜底 |
| 8 | 成功固件 `r6`(RAX) / `r8`(VS010) 只有 `factory.ubi`，RAX 无 `sysupgrade.bin` | 底座 `image/Makefile` 的 `Device/cmcc_rax3000q` 第 46 行又写了一句 `IMAGES := nand-factory.ubi`，把 `UbiFit` 的两个镜像覆盖掉；VS010 是注入块、没这句所以两个都有 | 提供可选 `sysupgrade补全包`；结论：**刷机仍走 U-Boot web + `factory.ubi`** |
| 9 | 想升级内核到 25.12 / 6.12 | 评估恩山 25.12（qosmio 开源 NSS）后判定与本套 5.4-QSDK 互斥：32→64 位、swconfig→DSA、9 项配置全重做，且 VS010 无 25.12 | **不采用**，保留 5.4；仅记录决策 |

### 2026-11-21 下午 · 运行期问题（最关键的一轮排查）
| # | 现象 | 根因 | 改动 |
|---|---|---|---|
| 10 | 刷完「插网线没反应」，一度误判成砖 | 两端默认不发 DHCP + `wan` 是死口 + STP 收敛 30s + 端口映射推的初值 | 澄清：不是砖；给出手动静态 IP `.10` + 四口轮试 |
| 11 | `ip link` 无 eth0/eth1/br-lan、`swconfig` 报 `Failed to connect` | 当时怀疑 `use_nwrt_dump_dts=true` 的真值 DTS 缺时钟/复位导致 ess-switch 不 probe | 加 5 个驱动编译期锁定、`nic-guard` 开机自检、VS010 真值 DTS 开关 |
| 12 | 30 秒 `BUG()`(`e7f001f2`) → `Kernel panic` → 3 秒重启循环 | 一度归因 IPv6 + ECM；**后来被交叉刷机实测推翻**，真值 DTS 的 q6 预留区 `OVERLAP DETECTED` 嫌疑更大 | 出 IPv6 回退包（保守配置，不伤功能）；VS010 `use_nwrt_dump_dts` 改回 `false` |
| 13 | **VS010 硬件刷 RAX 固件：能起、有无线、无线能拿 DHCP，有线不能** | 翻案：驱动不缺（`swconfig list` 有 `switch0 - QCA MP` + `switch1 - QCA AR8337`）、IPv6 无罪、VLAN 表本身正确（CPU(eth1)+LAN1/2/3 未标记）。真因是 **`eth1` 没 UP、`eth0` 是 `wan/proto=none` 不进桥**，有线帧进不了 `br-lan`（wlan0/1 直接 master br-lan 所以无线通） | 出「有线修复与定制包」：删 WAN/WAN6、`enable_vlan=0`、`br-lan` ports = `eth0 eth1`；`nic-guard` 开机自愈重放（关 VLAN → 拉起双 CPU 口 → 并入桥，含 `brctl` 与 `ip link master` 双兜底） |

### 2026-11-21 晚 · 定制与命名（本包）
| # | 需求 | 改动文件 |
|---|---|---|
| 14 | 关闭 IPv6 / 删 WAN6 / 关 ICMP 重定向 / 主题 ARGON / 编译时间=现在 / IP `192.168.1.241` / `root`+`admin` / WDS `WDS_AP`+`WDS123456` / STP 开 | `.config`、`slim.sh`、`99-bridge-ready`、`role.sh`、`bridge-ipv6`、`nic-guard`、新增 `files/etc/sysctl.d/99-no-icmp-redirect.conf`、两份 README、`build-openwrt.yml`（`SOURCE_DATE_EPOCH` + `/etc/compile_time` + banner + NTP + 4 项硬校验） |
| 15 | 固件前缀 `QSDK-` → **`Nwrt-QSDK12.2-`** | 两仓 workflow 的 Collect 段（大小写不敏感、兼容上一版 `QSDK-` 产物、兜底、旧前缀残留即报错）、Release 说明、README。**只换前缀，后半段一字不改** |
| 16 | 每次修改/修复都要有日志放仓库 | 新增本 `CHANGELOG.md`（人工修复时间线）+ `BUILD_HISTORY.md`（workflow 每次编译自动追加并 commit 回仓库）；README 与 Release 说明都加了链接 |

---

## 每次编译自动记录什么

workflow 第 23 步 `Append build history to repository`：构建时间（上海）、run 号 / attempt、commit SHA、
产物文件名清单、本版关键配置摘要 → 追加到 `BUILD_HISTORY.md` → `git commit` + `push`。
推送失败只 `::warning::`，**不影响固件与 Release**。push 不触发编译（workflow 只有 `workflow_dispatch`）。

## 已知边界与风险（别踩）

- `Nwrt-QSDK12.2-` **只是文件名**，不代表 QSDK 12.2 / 6.12 内核；实际 `uname -r` = 5.4.164。别拿恩山 25.12 的刷法套过来。
- **两台成对 WDS 时 IP 都是 `.241` 会冲突**，第二台刷完改成 `.242`。
- ARGON 主题包必须存在于 feeds：workflow 已加 `CONFIG_PACKAGE_luci-theme-argon=y` 硬校验，若 defconfig 找不到该包会直接停编并报错，不会静默回退到 bootstrap。
- VS010 的 `use_nwrt_dump_dts` 默认 **`false`**（模板 DTS 实测稳定；勾 `true` 那轮出现 30 秒 panic）。
- 有线修复是**配置层 + 运行层**，不动内核、不动 DTS、不动 `.config` 的网络驱动部分。
- uci-defaults 只在**首次开机**跑；已刷旧固件且保留配置升级时不会自动重放，需清 overlay 或进 U-Boot web 重刷 `factory.ubi`。
- 刷机：TTL 只接 TX/RX/GND **别碰 1.8V**，动手前**先备份 `0:ART`**。

## 复现 / 验证方式

- 静态：全部 `sh -n` / `bash -n`、YAML 解析、`slim.sh` 两遍幂等、mock uci 跑开机脚本逐条核对配置、假产物目录实跑重命名与负例。
- 动态：**必须 Actions 点一次 Run workflow**，两仓错峰、`ssh=false`。成功看 Releases 的 `Nwrt-QSDK12.2-*factory.ubi`；失败看 `*_build_log_*` 末尾。
