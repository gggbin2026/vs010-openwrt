# 两台 VS010 配 WDS 二层网桥（QSDK 5.4 固件）

固件里的 `99-bridge-ready` 已做完通用部分（关 IPv6 配置面、br-lan 开 STP、防火墙全放行、无线开 CN 区域）。**角色相关的两段只能在各自机器上敲**，别两台都关 DHCP。

## 共同前提

- 两台刷**同一个**固件（同一 commit 产物），`board_name` 应为 `cucc,vs010`
- 5.8G 做桥接，锁**非 DFS 信道 149**，HE80；CN 国家码
- 加密固定 **WPA2-AES / `psk2+ccmp`** —— SAE/WPA3 在 4addr 上易出兼容问题，TKIP 会掉到 11n 速率
- 两端 SSID、密码、信道、频宽**完全一致**
- 5G 两路天线都接好，两端极化轴平行

```sh
cat /tmp/sysinfo/board_name      # 必须输出 cucc,vs010
```

## A 端（AP-WDS，接上游 / 发 DHCP）

```sh
uci set wireless.radio1.country='CN'
uci set wireless.radio1.channel='149'
uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.disabled='0'

# 找到 5G 的 wifi-iface（一般是 @wifi-iface[1]），按实际改
uci set wireless.@wifi-iface[1].device='radio1'
uci set wireless.@wifi-iface[1].mode='ap'
uci set wireless.@wifi-iface[1].network='lan'
uci set wireless.@wifi-iface[1].ssid='VS010-BRIDGE-5G'
uci set wireless.@wifi-iface[1].encryption='psk2+ccmp'
uci set wireless.@wifi-iface[1].key='你的密码'
uci set wireless.@wifi-iface[1].wds='1'

uci set dhcp.lan.ignore='0'
uci set network.lan.ipaddr='192.168.1.1'
uci commit; wifi reload; /etc/init.d/network restart
```

## B 端（STA-WDS，纯透明桥）

```sh
uci set wireless.radio1.country='CN'
uci set wireless.radio1.channel='149'
uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.disabled='0'

uci set wireless.@wifi-iface[1].device='radio1'
uci set wireless.@wifi-iface[1].mode='sta'
uci set wireless.@wifi-iface[1].network='lan'
uci set wireless.@wifi-iface[1].ssid='VS010-BRIDGE-5G'
uci set wireless.@wifi-iface[1].encryption='psk2+ccmp'
uci set wireless.@wifi-iface[1].key='你的密码'
uci set wireless.@wifi-iface[1].wds='1'

uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.1.2'
uci set network.lan.gateway='192.168.1.1'
uci set network.lan.dns='192.168.1.1'
uci set network.lan.stp='1'
uci set dhcp.lan.ignore='1'
uci commit; wifi reload; /etc/init.d/network restart
```

## 验收（QSDK 体系必须这样看）

```sh
portstat                                  # 真实网口速率 + 关联 + 4addr 状态
ethtool eth0 | grep -E 'Speed|Duplex'     # 打了 nss-dp 补丁后应 1000Mb/s / Full
iw dev wlan1 station dump                 # 看 signal / MCS，别只看"已连接"
brctl showstp br-lan                      # 两端都应在 forwarding
dmesg | grep -iE '4addr|wds|nss.*wds'     # QSDK WDS offload 是否正常起
iperf3 -c <对端有线PC> -P 4 -t 60         # 有线千兆应 900M+
iperf3 -c 192.168.1.2 -P 4 -t 60         # WDS 无线侧真实吞吐
```

**判断"通不通"的决定性标志**：B 端下挂的 PC 能否从 **A 端的 DHCP** 拿到地址、且 MAC 是真实 MAC。拿到 = 4addr 二层透传成功；只有 B 自己能上网 = 退化成三层伪桥。

> WiFi 的 `iw station dump` 里 `tx/rx bitrate` 在 QSDK NSS offload 下可能不更新或为 0，是统计没回灌 mac80211，不是协商速率低 —— **用 iperf3 看真值**。

## 关于 distance / ACK

QSDK 5.4 闭源 WiFi 不一定暴露 `option distance`（那是 mac80211 的 `iw phy set distance`）。**500 m 往返传播时延 3.33 µs，远在默认 ACK 窗口内，不设也不掉速**；2 km 以上才需要关注。别为这个参数硬刷主线固件。

## VS010 专属注意

- **端口映射是初值**：`02_network` 里 `"1:lan:3" "2:lan:2" "3:lan:1" "4:wan"` 是按 PZ-L8 / xiangye277 两个来源推的，首刷务必 `swconfig dev switch1 show` 逐个插线核对 RJ45 对应。已知线索：刷 NWRT 后 **LAN3 会变成 WAN**。
- **校准走 `0:ART`**：`11-ath11k-caldata` 从本机 ART 分区提取，偏移暂借 RAX3000Q 的 `0x1000` / `0x26800`。若 5G 起不来或速率异常，先看 `dmesg | grep -i ath11k`，别拿 `oem_extract/qcn6122_bdwlan.bin`（50 字节、404 页面）当 BDF。
- **别打包 `ipq-wifi-cmcc_rax3000q`**：那是 RAX3000Q 的 BDF，刷进 VS010 5G 校准必错。workflow 已硬校验。
- 网口不对时，Actions 里勾 `use_nwrt_dump_dts=true` 换成 NWRT 反编译的硬件真值 DTS 再编一轮。

## 4addr 不通时的退路

这套 QSDK 树自带 `149` / `211-002` / `216` / `330` 四个 WDS offload 补丁，**NSS 与 WDS 是配套设计的，不要关 NSS 硬件加速**（跟主线 ath11k / WED 与 4addr 冲突是两回事）。若仍失败，按顺序查：

1. `uci show wireless | grep -E 'wds|encryption|mode'` —— 两端 `wds=1`、加密一致
2. `iw dev wlan1 station dump` 在 A 端能否看到 B 的真实 MAC
3. 退到 `relayd`（ARP 代理，IPv6 已关无影响），或 `GRETAP` 二层隧道

## 省内存的额外一步（可选）

256MB 上跑两路 ath11k 较紧。若只用 5G 做桥，可以关掉 2.4G 射频：

```sh
uci set wireless.radio0.disabled='1'
uci commit; wifi reload
```
