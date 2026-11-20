# 两份 DTS 怎么选

## 主选：`ipq5018-vs010.dts`（530 行，QSDK 风格改写版）

以 QSDK 树自带的 `ipq5000-rax3000q.dts` 为模板，只替换 VS010 与 RAX3000Q 的硬件差异，**其余所有 QSDK 专有节点原样保留**，所以与 `kkstone/immortalwrt-ipq50xx@openwrt-21.02` 的 5.4 内核、mac80211 补丁、`nss-dp` 驱动、`ipq5018.dtsi` 100% 匹配，编译成功率最高。

改了这 8 处：

| 项 | RAX3000Q | VS010 | 依据 |
|---|---|---|---|
| `model` | `CMCC RAX3000Q` | `CUCC VS010` | — |
| `compatible` | `cmcc,rax3000q` | `cucc,vs010` | board_name 必须匹配 02_network / caldata |
| RESET GPIO | tlmm **23** | tlmm **33** | xiangye277 DSA DTS；刷错会一直提示"复位键被按下" |
| LED | 3 颗 RGB（24/19/17） | 1 颗 GPIO **35** | xiangye277 DSA DTS |
| `switch_cpu_bmp` | `0x48` (3,6) | `0x40` (6) | NWRT `/sys/firmware/fdt` 反编译 |
| `switch_lan_bmp` | `0x34` (2,4,5) | `0x1e` (1,2,3,4) | 同上 |
| `switch_wan_bmp` | `0x02` (1) | `0x00` | 同上：VS010 的 WAN 走 dp1 GE PHY，不在 switch 位图内 |
| mesh/WPS 按键 | gpio38 | 删除 | VS010 无此键 |

保留不动的（同 IPQ5018 + QCN6102 + QCA8337，可共用）：`q6v5_wcss` 整套 remoteproc、`&wifi0` / `&wifi1` 的 `board_id`（0x24 / 0x60）与 `bdf-addr`、`qca,ar8327-initvals`、MAC0/MAC1 的 `nss-dp` 节点、`mdio0/1` PHY 地址表、`reserved-memory` 的 256M 宏分支。

## 兜底：`ipq5018-vs010-nwrt-dump.dts`（2321 行，硬件真值）

从机器实际运行的 NWRT 固件里 dump 出 `/sys/firmware/fdt` 反编译而来。**GPIO、端口位图、MTD 分区表、校准、时钟全部是 VS010 实物值**，没有任何推测成分。

在 Actions 里勾选 `use_nwrt_dump_dts = true` 即可切换；或手动把这份覆盖成 `ipq5018-vs010.dts`。

⚠️ 代价：它是 dtc 反编译产物，带 85 处数值 `phandle = <>`、`machid`、`MP_256;`、`compatible = "cucc,vs010\0qcom,..."` 这类 QSDK 展开写法，**没有 `#include "ipq5018.dtsi"`**（内容全展开了）。多数 dtc 能吃，个别版本会对 `\0` 转义或 `MP_256;` 报警。所以只在主选版出现"网口不对 / 起不来"时再换。

## 三项必须首刷实测

两份 DTS 都还给不出 100% 确定的答案，因为社区没有公开的 VS010 完整 QSDK 板级配置：

1. **端口编号 ↔ RJ45 对应关系**
   主选版 `02_network` 用的是按位图推的初值（`"1:lan:1" "2:lan:2" "3:lan:3" "4:lan:4"`）。首刷后跑：
   ```sh
   swconfig dev switch1 show       # 看各 port 的 link/速度
   ip -d link show
   ```
   逐个插网线看哪个 port 亮，再回来改 `diy-part2.sh` 里那段 `ucidef_add_switch`。
   已知线索：刷 NWRT 后 **LAN3 变成 WAN**；xiangye277 的 DSA DTS 把 `label="wan"` 挂在 `qca8337_3`，`port@5` 连 `&dp1`。

2. **ART 校准偏移**
   `11-ath11k-caldata` 里给 VS010 借用了 RAX3000Q 的值：`IPQ5018/hw1.0/caldata.bin` 从 `0:ART` 的 `0x1000` 取 0x20000，`qcn6122/hw1.0/caldata_1.bin` 从 `0x26800` 取 0x20000。同平台同 QSDK 布局，大概率通用，但若 5G 起不来或速率异常，先用 `oem_extract/` 里的 bdwlan 比对，或调整偏移。
   ⚠️ `oem_extract/qcn6122_bdwlan.bin` 只有 **50 字节**，内容是 `<h1>Not Found</h1>`（抓取失败），别拿它当 BDF；`bdwlan.bin` 和 `qcn6102_bdwlan.bin` 是 128K 真实数据。

3. **`board_id`（0x24 / 0x60）**
   沿用 RAX3000Q。若 ath11k 报 `board-2.bin` 找不到对应 board id，需要按 `10-ath11k-board_id` 的规则改。

## 顺带：5G 频限

xiangye277 那份 DSA DTS 写死 `ieee80211-freq-limit = <5150000 5730000>`，会把国内 ch149~165 整段砍掉——**那只在 OpenWrt main / mac80211 体系里生效**。这套 QSDK 5.4 闭源 WiFi 不走该属性，无需处理；`diy-part2.sh` 里仍留了 sed 兜底，防止有人把 DSA 版 DTS 混进来。
