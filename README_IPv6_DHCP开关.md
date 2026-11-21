# IPv6 / DHCP 开关说明（本版）

## IPv6：编译期已关闭，运行时无法开启

本版 `.config` 里 `CONFIG_IPV6` / `CONFIG_KERNEL_IPV6` / `ip6tables` /
`nat6` / `conntrack6` / `odhcpd` 全部未编入；`WAN6` 接口与 ULA / RA /
DHCPv6 / NDP 配置已删除。`slim.sh` 会二次摁回，workflow 发现 `=y` 直接报错停编。

```sh
bridge-ipv6 status      # 只打印状态
bridge-ipv6 on          # 会明确提示：需要改 .config 重新编译
```

## DHCP：默认开，可随手关

```sh
bridge-dhcp status      # dhcp.lan.ignore=0 表示发地址
bridge-dhcp off         # 回纯二层透传（上游主路由发地址时用）
bridge-dhcp on          # 池 192.168.1.100–199 / 12h
```

⚠️ 两台 WDS 成对、同广播域时**只留一台开 DHCP**，另一台执行 `bridge-dhcp off`。

## 管理 IP

固定 `192.168.1.241`。两台成对时第二台改成 `192.168.1.242`（见 README 警告）。
