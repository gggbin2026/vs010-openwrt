# VS010 最终一键包：按 RAX3000Q 那套标准修好

**目标**：极简、关 IPv6、能正常启动、WiFi 正常、能 WDS 无线桥接、网口速率显示正确。
**底座**：你仓库里已有的 `kkstone/immortalwrt-ipq50xx @ openwrt-21.02`（5.4-QSDK + swconfig + NSS），**不换 DSA、不换主线**。

---

## 0. 先说清楚：你贴的页面是旧快照，仓库实际已经变过

你贴的 GitHub 页面显示「forked from xiangye277、8 commits、只有 `ipq5018-vs010.dts` + `flash.py`」——那是 **fork 时的旧状态**。我按 GitHub API 拉了当前文件树（`pushed_at 2026-11-20 07:47`，最新 commit `e805148 Update diy-part2.sh`）：

```
.config                       280671   ← 已上传的 QSDK 修复包
.github/workflows/build-openwrt.yml  8378  ← Build VS010 (QSDK 5.4)
diy-part1.sh / diy-part2.sh / feeds.conf.default
README_修复说明.md
vs010/ 三份 DTS（QSDK 风格改写版 + NWRT 反编译原件 + 说明）
--- 以下仍是 xiangye277 的残留 ---
ipq5018-vs010.dts（6121 B，DSA 老版） / firmware/ 37MB 失败日志 / oem_extract/ / FLASHING.md
```

也就是说：**上一轮那个 VS010_QSDK_修复包你已经传上去了**，但它是"能编出 VS010 专用镜像"的版本，还没做你这次要的极简 / IPv6 / WDS 就绪 / ethtool 修复。当前 `.config` 仍是 **330 包、42 个 luci-app、`CONFIG_IPV6=y`**。

另外你贴的 `README.md` 里那句「此固件基于 CMCC PZ-L8 设备树改编」是 **xiangye277 的旧 README**；现在实际走的是 QSDK 5.4 路线，PZ-L8 只借了 PHY 顺序参数，不借底座。

---

## 1. 这个包改了什么（对照 RAX3000Q 最终一键包）

| 项 | 你现在仓库 | 本包 |
|---|---|---|
| 包数 | 330（42 个 luci-app：passwall / smartdns / adblock / SQM / WG…） | **137**，0 个 luci-app |
| IPv6 | `CONFIG_IPV6=y` + `CONFIG_KERNEL_IPV6=y` + ipv6helper/odhcp6c/6in4/natmap | **全关**：`include/target.mk` 源头删 + `slim.sh` 二次收敛 + 配置面 `99-bridge-ready` 清 RA/DHCPv6 + workflow 硬校验 |
| initramfs | 开（多编一份） | 关，只出 squashfs |
| WiFi | QSDK 闭源 + 256M profile + NSS（**保留，一个没动**） | 同左 |
| WDS | 补丁在树里但没配桥 | `149/211-002/216/330` 四项校验 + STP / 防火墙全放行 / `wpad-basic-wolfssl` |
| 网口速率显示 | 「半双工 / 速率 —」占位符 | **nss-dp ethtool 补丁**（与 RAX3000Q 完全同一个 `qca-nss-dp` 包，补丁通用） |
| workflow | 无 permissions、release 两步、单次 defconfig | 加 permissions、删 release、`defconfig → slim → defconfig` 三段 + 5 项硬校验、编译后确认补丁真编进去、产物强校验 |

**为什么 ethtool 补丁能直接复用**：VS010 和 RAX3000Q 用的是**同一套 QSDK 底座、同一个 `package/kernel/qca/qca-nss-dp`**，根因也一模一样——`.get_link_ksettings = phy_ethtool_get_link_ksettings` 取 `netdev->phydev`，而 PHY 实际在 `dp_priv->phydev`，返回 `-ENODEV`，LuCI 就回显占位符。物理链路一直是 1000M 全双工。补丁只改上报回调，不动数据路径。

**WiFi 速率显示**：`iw station dump` 的 `tx/rx bitrate` 在 NSS offload 下常不更新，是统计没回灌 mac80211，不是速率低。这个我不给未编译验证的内核补丁，**用 `iperf3` 看真值**。

---

## 2. 你要做的（只有一步）

把 `VS010_最终一键包/` 里的文件**按原路径覆盖 / 新增**：

| 文件 | 动作 |
|---|---|
| `.github/workflows/build-openwrt.yml` | **覆盖**（18 步，已合并全部修复） |
| `.config` | **覆盖**（137 包 / IPv6 全关） |
| `diy-part1.sh` / `diy-part2.sh` | **覆盖**（diy-part2 保留 VS010 四段注入，追加三段校验） |
| `slim.sh` | **新增** |
| `inject-ethtool-patch.sh` | **新增** |
| `patches/999-nss-dp-ethtool-fixed-link.patch` | **新增** |
| `files/etc/uci-defaults/99-bridge-ready` | **新增** |
| `files/usr/sbin/portstat` | **新增** |
| `vs010/` 三份 DTS | **保持**（若仓库已有且未改动可不动；包内是已核对过的版本） |
| `feeds.conf.default` | 覆盖（4 个官方源，pin 21.02） |
| `WDS网桥配置.md` / `README_修复说明.md` / 本清单 | 参考，不参与编译 |

**必须删掉（否则会互相污染）**：

```
.github/workflows/build.yml        ← xiangye277 那份跑 OpenWrt main 6.12 + DSA 的旧 workflow
ipq5018-vs010.dts                  ← 根目录那份 DSA 老版（6121 B），diy-part2.sh 从 vs010/ 取，留着容易手工拿错
```

**建议删（只让仓库变胖，不参与编译）**：`firmware/`（37MB 失败日志 + 534 B 假固件 zip）、`oem_extract/`（尤其 `qcn6122_bdwlan.bin` 只有 50 字节、内容是 `<h1>Not Found</h1>`，**千万别当 BDF 用**）。`FLASHING.md` / `flash.py` / `poll_build.py` 留着做刷机参考无妨。

然后 **Actions → `Build VS010 slim WDS (QSDK 5.4)` → Run workflow**：
- `ssh` 留 `false`
- `use_nwrt_dump_dts` 首次留 `false`（用 QSDK 风格改写版 DTS，编译成功率最高）；网口不对再勾 `true`

产物 Artifact `VS010_slim_WDS_*` 只收 `*vs010*`：
```
*-cucc_vs010-squashfs-nand-factory.ubi        ← 首刷
*-cucc_vs010-squashfs-nand-sysupgrade.bin     ← 后续升级
*-cucc_vs010-fit-uImage.itb
```

---

## 3. 刷机参数（三套别混）

| 来源 | 参数 |
|---|---|
| **本包 QSDK U-Boot**（推荐首刷用 initramfs 验证） | 电脑 `192.168.1.8`，**LAN1 口**，`tftpboot` → `flash rootfs` |
| 原厂 Web API | `192.168.2.1`，密码 base64 提交 `/api` 取 stok，POST multipart 到 `/api/;stok=TOKEN/admin/advance/upgrade`，字段 `file` + `size`，**格式 .img** |
| NWRT TTL | `192.168.2.2`，`flash 0:MIBIB` / `0:APPSBL` / `flash rootfs` → `bootipq` |

TTL **115200 8N1，只接 TX/RX/GND，别碰 1.8V**。刷前备份全部分区，**特别是 `0:ART`**（射频校准丢了 WiFi 救不回来）。绝不刷 `0:MIBIB` / `0:APPSBL` 全分区包。

⚠️ VS010 是**单分区** `rootfs @0x900000` 大小 `0x6e00000`（110 MiB），和 RAX3000Q / PZ-L8 的双分区不同，U-Boot 的 `dual_boot` / `boot_part` / `rootfs_num` 变量语义不一样。QSDK 树用 UBI 按 SMEM 分区自动出镜像，不写死 `IMAGE_SIZE`，但仍建议首刷前 `cat /proc/mtd` 复核。

---

## 4. 刷完验收

```sh
cat /tmp/sysinfo/board_name                     # cucc,vs010
ethtool eth0 | grep -E 'Speed|Duplex|Link detected'   # 1000Mb/s / Full
portstat                                       # swconfig 真值 + 关联 + 4addr
iperf3 -c <对端有线PC> -P 4 -t 60               # 900M+ 才是真千兆
```

WDS 双端命令见 `WDS网桥配置.md`（A: AP-WDS 保留 DHCP；B: STA-WDS 关 DHCP + 同网段静态 IP；两端 `wds=1`、`psk2+ccmp`、锁 ch149 HE80）。**决定性验收**：B 端下挂 PC 能否从 A 端 DHCP 拿到地址且保留真实 MAC。

---

## 5. 边界（必须说清）

1. **没跑过真实 `make`**：本会话 362MB 磁盘 / 2.4GB 内存 / 2 核，缺 toolchain。已验证：workflow YAML 解析正常（18 步）；6 个脚本语法全过；`diy-part2.sh` 在模拟 QSDK 源码树上按真实顺序实跑（DTS/Device/02_network/caldata 四段注入 + target.mk 精简 + WDS 四项校验 + files 校验全通过）；`slim.sh` 从 330 收敛到 137 且幂等；ethtool 补丁对 `NHSS.QSDK.11.5.0.5` 真实源码 `patch -p1 --dry-run` 通过；注入脚本实跑。**编译通过要你在 Actions 点一次**，失败看 `VS010_build_log_*`。
2. **补丁只修显示**，不改转发行为。若 `iperf3` 只有 100M 且 CRC/冲突涨，那是真 PHY 协商问题（换线、换口、`swconfig dev switch1 show`），跟补丁无关。
3. **关 `CONFIG_KERNEL_IPV6`** 是最彻底做法，个别 QSDK 包若有未加 `#ifdef` 的 IPv6 引用会在编译期报错；真遇到就退一步只关 `CONFIG_IPV6`。
4. **校准偏移是借的**：`11-ath11k-caldata` 暂用 RAX3000Q 的 `0x1000` / `0x26800` 从 VS010 的 `0:ART` 提取。5G 起不来先看 `dmesg | grep -i ath11k`，别拿 `oem_extract` 里那个 50 字节 404 页面当 BDF。
5. **端口映射是初值**：`"1:lan:3" "2:lan:2" "3:lan:1" "4:wan"` 按 PZ-L8 / xiangye277 两个来源推的，首刷逐个插线核对；网口不对就勾 `use_nwrt_dump_dts=true` 换硬件真值 DTS 再编。
6. **WDS 4addr 跨两台实机仍需实测**：补丁齐、netifd 支持齐，但没在真机验证过关联。不通按 `WDS网桥配置.md` 退到 `relayd` / `GRETAP`。
7. **残留混杂风险**：仓库是 fork 自 xiangye277 的，旧的 DSA 文件还在。只要按第 2 节删掉 `build.yml` 和根目录 `ipq5018-vs010.dts`，就不会混进 QSDK 树（两套交换栈互斥，混了必编译失败）。

---

一句话收口：**这个包把 RAX3000Q 那套「137 包 / IPv6 全关 / WiFi+NSS 不动 / WDS 就绪 / ethtool 补丁」原样搬到 VS010，只把设备符号、BDF 路线（改走 `0:ART`）、端口映射和刷机参数换成 VS010 的；你覆盖文件、删两个残留、点 Run，不用再改任何代码。**
