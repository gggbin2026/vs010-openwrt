# 用 RAX3000Q 的编译材料，修好 VS010 的编译材料

## 0. 先说最关键的发现：你之前那几个"幽灵包"，其实不是幽灵

这一轮把两个仓库的真实文件都拉下来核对后，前面几轮的困惑全部闭环了：

| | `gggbin2026/vs010-openwrt`（你现在的） | `gggbin2026/Actions-OpenWrt-RAX3000Q` |
|---|---|---|
| 底座 | `openwrt/openwrt` **main**，内核 **6.12.94** | `kkstone/immortalwrt-ipq50xx` **openwrt-21.02**，内核 **5.4-QSDK** |
| 交换栈 | 主线 **DSA**（`qca,qca8337` + `phy-handle` + `label`） | QSDK **swconfig**（`qcom,ess-switch-qca83xx` + `switch_*_bmp`） |
| 维护状态 | 8 commits，最后一跑是 **37MB 失败日志**，无 Releases | **304 commits**，2026-10-02 仍在更新 |
| WiFi | 开源 ath11k，**256MB 内存下上游直接把 wifi 置 disabled** | QSDK 闭源 WiFi + **Wi-Fi NSS / NAT NSS** + `CONFIG_ATH11K_MEM_PROFILE_256M=y` |
| 设备定义 | workflow 里临时追加 `unicom_vs010` | 树里正式带 `cmcc_rax3000q` / `redmi_ax3000` / `xiaomi_cr881x` |

**`kmod-qca-nss-dp` / `kmod-qca-nss-drv` / `kmod-qca-wifi-qsdk` 这些包，在 QSDK 21.02 树里是真实存在的**（RAX3000Q 的 `.config` 里 `CONFIG_PACKAGE_kmod-qca-nss-dp=y`、`CONFIG_ATH11K_NSS_SUPPORT=y` 全都有）。之前报"Package not found / empty variable name"，是因为把 QSDK 系的设备定义塞进了 OpenWrt main 6.12 树——**底座错了，不是包错了**。

所以你的思路是对的：**VS010 该用 RAX3000Q 这套 5.4-QSDK 底座来编**，理由有三：

1. 256MB 内存跑主线 ath11k 会 OOM，上游 RAX3000Q 的 DTS 里注释写死 `//256M RAM is too small for ath11k, so WiFi is disabled`；QSDK 闭源 WiFi + 256M MEM_PROFILE 反而能开 WiFi。
2. VS010 原厂/NWRT 就是 QSDK 系，前几轮那份从 NWRT 反编译出来的 2321 行 DTS（`qcom,port_phyinfo` / `switch_lan_bmp`）**正好就是这套树的语法**，而 xiangye277 的 DSA DTS 在这里根本编不了。
3. NSS 硬件转发能补上 IPQ5018 双核 A53 软转发弱的短板。

⚠️ **但只能借底座和工程骨架，不能整套照搬固件**：上一轮已经核实过，RAX3000Q 固件直接刷 VS010 会因 RESET GPIO（23 vs 33）、端口映射、校准变体、ART 布局全不同而变砖。这次做的是"换底座 + 换设备层"，不是"刷 RAX3000Q 固件"。

---

## 1. 你现在的仓库为什么编不出来

`gggbin2026/vs010-openwrt` 与上游 `xiangye277/vs010-openwrt` **逐字节一致**（8 commits，最新 `7242549 · Jun 26 2026`，状态 failure）。`firmware/` 里两份都是失败日志：

- `vs010-openwrt-firmware.zip` → `Makefile:41: *** empty variable name. Stop.`
- `build.log`（37.5MB）→ `cc1: fatal error: ../dts/ipq5018-vs010.dts: No such file or directory` → `ERROR: target/linux failed to build.`

外加 `make ... | tee` 没开 pipefail 导致 step 假成功。这些在上一轮 `xiangye277_修复包` 里已逐条诊断过。

而换 QSDK 底座后，`IMAGE_SIZE := 59392k`（照抄 PZ-L8，超 VS010 的 `0x2840000=41472k`）、5G 频限砍掉 ch149~165、25 个插件塞进 256MB 这些问题**大部分自然消失**——QSDK 树用 UBI 自动按分区出镜像，闭源 WiFi 也不读 `ieee80211-freq-limit`。

---

## 2. 交付文件与覆盖方法

| 包内文件 | 覆盖到你的仓库 | 说明 |
|---|---|---|
| `.github/workflows/build-openwrt.yml` | **新增** | QSDK 底座版 workflow（P3TERX 骨架） |
| `.config` | 覆盖 | 7267 行完整配置，从 RAX3000Q 版精确改设备符号 |
| `diy-part1.sh` | 覆盖 | feeds 前置，保持 21.02 分支 |
| `diy-part2.sh` | 覆盖 | **核心**：注入 VS010 的 DTS / 设备定义 / 02_network / caldata |
| `feeds.conf.default` | 覆盖 | QSDK 树原版（4 个源全部 pin `openwrt-21.02`） |
| `vs010/ipq5018-vs010.dts` | 新增 | QSDK 风格改写版（主选） |
| `vs010/ipq5018-vs010-nwrt-dump.dts` | 新增 | NWRT 反编译硬件真值（兜底） |
| `vs010/README_DTS.md` | 新增 | 两份 DTS 怎么切、三项待实测 |

**必做一步**：把仓库里旧的 `.github/workflows/build.yml` **删掉或改名成 `build.yml.disabled`**。那份 clone 的是 OpenWrt main 6.12，和这套 QSDK 树不共存；两个 workflow 都在 `main` 分支 push 时触发会互相污染。`build-openwrt.yml` 已改成只 `workflow_dispatch` 手动触发。

然后：**Fork → Actions → Build VS010 (QSDK 5.4) → Run workflow**，`use_nwrt_dump_dts` 首次留 `false`。

预期产物（Artifact `VS010_QSDK_firmware_*`）：

```
*-cucc_vs010-squashfs-nand-factory.ubi     ← 首刷用这个
*-cucc_vs010-squashfs-nand-sysupgrade.bin  ← 后续升级
*-cucc_vs010-fit-uImage.itb
```

---

## 3. 相对 RAX3000Q 原件，改了哪些

| 位置 | RAX3000Q 原值 | VS010 修复值 |
|---|---|---|
| `.config` | `DEVICE_cmcc_rax3000q=y` | `DEVICE_cucc_vs010=y` |
| `.config` | `CONFIG_TARGET_PROFILE="DEVICE_cmcc_rax3000q"` | `"DEVICE_cucc_vs010"` |
| `.config` | `ipq-wifi-cmcc_rax3000q=y` | **注释掉**（RAX3000Q 的 BDF 刷进 VS010，5G 校准必错）；改由 `11-ath11k-caldata` 从本机 `0:ART` 提取 |
| `.config` | — | 加 `CONFIG_PACKAGE_iperf3=y` 便于验收 |
| `.config` | `CONFIG_ATH11K_MEM_PROFILE_256M=y` / NSS 三项 | **保留**（正是这套底座的价值） |
| workflow | `release_tag=RAX3000Q-...` | `VS010-...`；`UPLOAD_RELEASE=false` 首次不自动发版 |
| workflow | `make -j$(nproc) \|\| make -j1 \|\| make -j1 V=s` | 改 `set -euo pipefail` + `tee build.log`，失败即停并传日志 |
| workflow | golang/nodejs/natmap/ddns-go/frp/turboacc 一堆 Dropbox 外链 | **移除**（首次编译易碎）；只保留 QSDK 5.4 内核 tarball 兜底且允许失败 |
| workflow | — | 加底座结构自检、`make defconfig` 后校验 `DEVICE_cucc_vs010` 是否真进 `.config` |
| `image/Makefile` | 树里只有 3 台设备 | `diy-part2.sh` 追加 `define Device/cucc_vs010` |
| DTS | `ipq5000-rax3000q.dts` | `ipq5018-vs010.dts`：GPIO 23→33、LED 3 色→1 颗 GPIO35、位图 `0x48/0x34/0x02`→`0x40/0x1e/0x00`、删 mesh 键 |
| `02_network` | swconfig 三个 case | 追加 `cucc,vs010` case |
| `11-ath11k-caldata` | 三个 board | 两处 case 都加 `cucc,vs010` |

**为什么 `.config` 里不加 `IMAGE_SIZE`**：QSDK 树的 `cmcc_rax3000q` 定义本身就没有 `IMAGE_SIZE`，`Device/UbiFit` 用 `append-ubi` 按 DTS 的 SMEM 分区自动出镜像。但 **首刷前务必检查 `nand-factory.ubi` ≤ 0x2840000（41472k）**；超了就在 `diy-part2.sh` 的 `define Device/cucc_vs010` 里补一行 `IMAGE_SIZE := 41472k`。

---

## 4. 三项必须首刷实测（诚实边界）

这套修复解决的是**「让 Actions 真的编出 VS010 专用镜像」**，以下三项社区没有公开定论，不能替你打包票：

1. **端口 ↔ RJ45 映射**：`02_network` 用的是按 `switch_lan_bmp=0x1e` 推的初值。首刷跑 `swconfig dev switch1 show` 逐个插网线确认，再改 `diy-part2.sh` 里那段。
2. **ART 校准偏移**：借用 RAX3000Q 的 `0x1000` / `0x26800`。5G 起不来就用 `oem_extract/` 的 128K bdwlan 比对或调偏移。⚠️ `qcn6122_bdwlan.bin` 只有 50 字节、是 404 页面，**不能用**。
3. **`board_id` 0x24 / 0x60**：沿用 RAX3000Q。ath11k 报找不到 board-2.bin 时按 `10-ath11k-board_id` 规则改。

详见 `vs010/README_DTS.md`。若主选 DTS 网口不对，在 Actions 里把 `use_nwrt_dump_dts` 勾 `true` 换成 NWRT 反编译的硬件真值版。

---

## 5. 刷机参数（和前面几轮都不同，别混）

| 体系 | 参数 |
|---|---|
| **本套 QSDK U-Boot** | 电脑设 `192.168.1.8`，**用 LAN1 口**（README 原文：`Set computer ip to:192.168.1.8, use LAN1 port.`） |
| xiangye277 的 Web API | `http://192.168.2.1`，密码 `mzxgfwlpt00` base64 → stok → `/api/;stok=.../admin/advance/upgrade`，字段 `file` + `size` |
| xiangye277 的 TTL | `10.1.1.1` / `10.1.1.2`，`tftpboot 0x44000000 firmware.img` → `flash rootfs 0x44000000 0xSIZE` |
| NWRT TTL | `192.168.2.2`，`flash 0:MIBIB` / `0:APPSBL` / `flash rootfs` → `bootipq` |

**铁律**：TTL 115200 8N1，**只接 TX/RX/GND，别碰 1.8V**；刷前备份全部分区，**特别是 `0:ART`**（射频校准丢了 5G 救不回来）；绝不刷 `0:MIBIB` / `0:APPSBL` 全分区包（RESET GPIO 不同会无限重启，只能编程器救）。2021 年 V2.0 板最稳，新批次有刷完无 5G 的案例。

---

## 6. 两条互斥的路线，选一条别混

- **本包（QSDK 5.4 + NSS）**：WiFi/转发最可能可用，内存友好；代价是 swconfig 下 `ethtool` 仍可能不上报速率（**只是显示问题**，`swconfig`/iperf3 才是准的），且端口映射要实测。
- **上一轮 `xiangye277_修复包`（OpenWrt main 6.12 + DSA）**：网口能正确上报速率，但 256MB 下 ath11k 有 OOM 风险、上游自己都把 WiFi 禁了，还有 #25975 以太网回归。

**不要**把上一轮的 DSA DTS 塞进这套 QSDK 树，也不要把本包的 `.config` 拿去给 main 树用——这正是前几轮反复报错的根源。

---

## 7. 最后一句

如果只是要把那条 **500 米网桥**跑起来：RAX3000M 官方 OpenWrt 免 TTL、前面的 WDS 脚本现成能用，仍然比修 VS010 省事得多。VS010 这套更适合当"把 QSDK 树玩通"的练手——30 块的板子，坏了不心疼。

`diy-part2.sh` 已在本地模拟的 QSDK 源码树上实跑过：4 处注入全部成功，`02_network` / `11-ath11k-caldata` 均通过 `sh -n`，生成 DTS 的 `{}` / `<>` / `#ifndef~#endif` 全部配平。但**真实 `make` 仍需你在 Actions 里跑一次**——当前会话只有 362MB 磁盘 / 2.4GB 内存 / 2 核，且缺 flex/bison/dtc 等依赖，跑不了全量编译。
