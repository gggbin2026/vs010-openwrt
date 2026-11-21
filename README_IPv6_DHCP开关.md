# 本版改动：IPv6 / DHCP 默认全开 + 可随手关

## 先说重点（别误判）

**开 IPv6 / DHCP 修不了网口不通。** 上一台 VS010 串口里
`ip link` 没有 eth0/eth1/br-lan、`swconfig` 报 Failed to connect，
那是内核交换驱动没 probe（DTS 时钟/复位不全），属于二层数据面；
IPv6 是三层协议栈、DHCP 是用户态服务，都管不到 netdev 存不存在。

所以本包**同时**把 VS010 的 `use_nwrt_dump_dts` 默认改成 `true`，
用 NWRT 反编译的硬件真值 DTS 重编 —— 那才是修网口的动作。
IPv6/DHCP 只是按你的要求把变量排除掉。

## 改了什么

| 层 | 上一版 | 本版 |
|---|---|---|
| `CONFIG_IPV6` / `CONFIG_KERNEL_IPV6` | not set | **=y** |
| 用户态 | odhcp6c / odhcpd-ipv6only / luci-proto-ipv6 / ip6tables / kmod-ip6tables / kmod-nf-conntrack6 / kmod-nf-nat6 | **全 =y** |
| `dhcp.lan.ignore` | 1（不发地址） | **0**，池 100~199 / 12h |
| RA / DHCPv6 / NDP | disabled | **server** |
| dnsmasq / odhcpd | disable | **enable + restart** |
| 管理 IP | AP `192.168.1.2` / STA `192.168.1.3` | 不变（不在 DHCP 池内，不冲突） |
| WDS / 4addr / ch149 / CN / 上海时区 / STP | 全保留 | 全保留 |

IPv6 只开在 **LAN 侧**（ULA + RA/DHCPv6），`wan` 仍是 `proto=none`，
不做 IPv6 上网、不做 NAT —— 这台还是纯二层 WDS 桥。

## 随手关（不用重编、不用重刷）

```sh
bridge-dhcp off      # 关本机 DHCP，回到纯透传
bridge-dhcp on       # 再开（池 100~199）
bridge-dhcp status

bridge-ipv6 off      # 关 RA/DHCPv6/NDP，回到纯 IPv4 桥
bridge-ipv6 on
bridge-ipv6 status
```

⚠️ **两台同广播域都开 DHCP 会抢地址**。建议只在主端留一个 DHCP：
副端刷完执行 `bridge-dhcp off`。上游已有主路由发地址时，两端都 off。

> 内核 IPv6 栈是编译期开的，`bridge-ipv6 off` 只关地址发放，不会把栈卸载。
> 要连内核栈都不要，得改 `.config` 重编。

## 覆盖哪些文件

```
.config
slim.sh
.github/workflows/build-openwrt.yml
files/etc/uci-defaults/99-bridge-ready
files/usr/lib/bridge/role.sh
files/usr/sbin/bridge-dhcp
files/usr/sbin/bridge-ipv6          ← 新增
README_IPv6_DHCP开关.md            ← 新增（本文档，不参与编译）
```

其余（`diy-part2.sh`、`prefetch-ath-kernel.sh`、`extend-421-nand.sh`、
`patches/`、`inject-ethtool-patch.sh`、`vs010/`、feeds）一个都不用动。

## 跑

RAX3000Q → `Build RAX3000Q slim WDS`
VS010   → `Build VS010 slim WDS (QSDK 5.4)`

VS010 的 `use_nwrt_dump_dts` 现在**默认 true**，直接点 Run 即可；
想回退到旧模板 DTS 才手动勾 false。`ssh` 留 false，两台错峰跑。

## 边界

- 开 IPv6 后 QSDK `qca-nss-ecm` 会走 `ECM_IPV6_ENABLE=y`（这是 QSDK 原生路径），
  但**本版没跑过真实 make**，编译结果要 Actions 点一次才知道；失败把 build.log 末尾发我。
- VS010 的 NWRT dump DTS 是第一次实编（之前一直用模板 DTS），
  若 dtc 报 phandle / 数值属性警告，把日志发我，我按行收口。
- uci-defaults 只在**首次开机**跑一次。sysupgrade 勾了「保留配置」时旧配置会留着，
  手动 `bridge-dhcp on` / `bridge-ipv6 on` 一次即可。
