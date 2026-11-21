#!/bin/sh
# bridge_apply_role <ap|sta>
# 把整机刷成 UBNT airOS「Bridge 模式」等价行为：
#   纯二层透明桥（无 NAT）+ 一条 5G WDS(4addr) 链路；固定 IP 192.168.1.241 / IPv6 关闭
# 两端共用这一段，只差 mode 与管理 IP。开机由 99-zz-bridge-role 调用。
. /lib/functions.sh

BRIDGE_SSID='WDS_AP'
BRIDGE_KEY='WDS123456'              # 两端必须一致
BRIDGE_CHAN='149'                    # 非 DFS，5.8G 合规段
BRIDGE_DIST='550'                    # 500 m × 110%；按实际距离用 bridge-distance 改
BRIDGE_TXPWR='20'                    # 原装天线保守值；改 14dBi 平板改 19

bridge_find_5g() {
    # 手动指定优先：bridge-radio radioX
    [ -s /etc/bridge_radio ] && { cat /etc/bridge_radio; return 0; }
    # 其次按信道 / band 找 5G 射频
    for r in radio1 radio0 radio2; do
        uci -q get "wireless.$r" >/dev/null || continue
        c=$(uci -q get "wireless.$r.channel" 2>/dev/null)
        b=$(uci -q get "wireless.$r.band" 2>/dev/null)
        h=$(uci -q get "wireless.$r.hwmode" 2>/dev/null)
        case "$c:$b:$h" in
            *5a*|*11a*|*a:*) echo "$r"; return 0 ;;
        esac
        [ -n "$c" ] && [ "$c" -gt 36 ] 2>/dev/null && { echo "$r"; return 0; }
    done
    # 默认：QSDK 上 radio1 通常是 5G
    uci -q get wireless.radio1 >/dev/null && { echo radio1; return 0; }
    echo radio0
}

bridge_find_iface() {
    # 找挂在 5G 射频上的 wifi-iface，没有就取第一个
    local r="$1" i=0 d
    while uci -q get "wireless.@wifi-iface[$i]" >/dev/null; do
        d=$(uci -q get "wireless.@wifi-iface[$i].device" 2>/dev/null)
        [ "$d" = "$r" ] && { echo "$i"; return 0; }
        i=$((i+1))
    done
    echo 0
}

bridge_apply_role() {
    local role="$1" r idx
    [ "$role" = ap ] || [ "$role" = sta ] || { echo "role 只能是 ap 或 sta" >&2; return 1; }

    # 所有射频（含 2.4G）统一 CN —— 手动 bridge-role 重跑也不会只留 5G 是 CN
    set_cn_all() { uci -q set "wireless.$1.country=CN"; }
    config_load wireless
    config_foreach set_cn_all wifi-device

    r=$(bridge_find_5g)
    idx=$(bridge_find_iface "$r")

    # ── 1. 射频：固定信道 / 国家码 / 距离 / 功率，htmode 保留编译期值 ──
    uci set "wireless.$r.country"='CN'
    uci set "wireless.$r.channel"="$BRIDGE_CHAN"
    uci set "wireless.$r.disabled"='0'
    uci -q get "wireless.$r.htmode" >/dev/null || uci set "wireless.$r.htmode"='HE80'
    uci set "wireless.$r.distance"="$BRIDGE_DIST"
    uci set "wireless.$r.txpower"="$BRIDGE_TXPWR"

    # ── 2. WDS 4addr：两端同 SSID / 同密钥 / WPA2-AES ──
    uci set "wireless.@wifi-iface[$idx].device"="$r"
    uci set "wireless.@wifi-iface[$idx].network"='lan'
    uci set "wireless.@wifi-iface[$idx].mode"="$role"
    uci set "wireless.@wifi-iface[$idx].wds"='1'
    uci set "wireless.@wifi-iface[$idx].ssid"="$BRIDGE_SSID"
    uci set "wireless.@wifi-iface[$idx].encryption"='psk2+ccmp'
    uci set "wireless.@wifi-iface[$idx].key"="$BRIDGE_KEY"
    uci set "wireless.@wifi-iface[$idx].disabled"='0'

    # ── 3. 纯二层桥：LAN 口 + 无线都在 br-lan ──
    # 注意：QSDK swconfig 的端口/VLAN 映射在 VS010 上尚未实测，
    # 这里不擅自把 WAN 口并进桥（乱改会把机器搞成不通）。
    # WAN section 保留但不取地址、不做 NAT，等于闲置口。
    # 【有线修复】删 WAN / WAN6，关 VLAN，两个 CPU 口都进 br-lan（傻交换桥）
    uci -q delete network.wan
    uci -q delete network.wan6
    uci -q delete dhcp.wan
    uci -q delete dhcp.wan6
    uci -q delete network.globals.ula_prefix
    BR=$(uci -q get network.lan.device 2>/dev/null); [ -n "$BR" ] || BR='br-lan'
    j=0
    while uci -q get "network.@device[$j]" >/dev/null 2>&1; do
        [ "$(uci -q get "network.@device[$j].name" 2>/dev/null)" = "$BR" ] && {
            uci -q delete "network.@device[$j].ports"
            uci -q add_list "network.@device[$j].ports"='eth0'
            uci -q add_list "network.@device[$j].ports"='eth1'
            break; }
        j=$((j+1))
    done
    uci -q get network.@switch[0] >/dev/null 2>&1 && {
        uci -q set network.@switch[0].enable_vlan='0'
        uci -q set network.@switch[0].reset='1'; }
    while [ -n "$(uci -q get network.@switch_vlan[0].vlan 2>/dev/null)" ]; do
        uci -q delete network.@switch_vlan[0]
    done
    uci set network.lan.type='bridge'
    uci set network.lan.stp='1'
    uci set network.lan.force_link='1'
    uci set network.lan.proto='static'
    # 固定管理 IP（两台成对使用时，第二台刷完手动改成 192.168.1.242，避免 ARP 冲突）
    uci set network.lan.ipaddr='192.168.1.241'
    uci set network.lan.netmask='255.255.255.0'
    uci -q delete network.lan.gateway
    uci -q delete network.lan.dns

    # ── 4. DHCP 默认开；IPv6 编译期已关闭，配置面全清空 ──
    #     两台同广播域会双 DHCP，在其中一台执行  bridge-dhcp off
    uci set dhcp.lan.ignore='0'
    uci -q set dhcp.lan.start='100'
    uci -q set dhcp.lan.limit='100'
    uci -q set dhcp.lan.leasetime='12h'
    uci -q delete dhcp.lan.ra
    uci -q delete dhcp.lan.dhcpv6
    uci -q delete dhcp.lan.ndp
    uci -q delete network.lan.ip6assign
    uci -q delete network.lan.ipv6
    [ -x /etc/init.d/dnsmasq ] && { /etc/init.d/dnsmasq enable 2>/dev/null || true; /etc/init.d/dnsmasq restart 2>/dev/null || true; }
    [ -x /etc/init.d/odhcpd ] && { /etc/init.d/odhcpd stop 2>/dev/null || true; /etc/init.d/odhcpd disable 2>/dev/null || true; }

    # ── 5. 防火墙全放行，不做 NAT ──
    if uci -q get firewall.@defaults[0] >/dev/null; then
        uci set firewall.@defaults[0].input='ACCEPT'
        uci set firewall.@defaults[0].output='ACCEPT'
        uci set firewall.@defaults[0].forward='ACCEPT'
        uci set firewall.@defaults[0].flow_offloading='0'
        uci set firewall.@defaults[0].flow_offloading_hw='0'
        uci commit firewall
    fi

    uci commit wireless
    uci commit network
    uci commit dhcp

    # 给 bridge-status 留一份可读的运行信息
    printf 'role=%s\nradio=%s\niface=%s\nssid=%s\nchan=%s\ndistance=%s\ntxpower=%s\n' \
        "$role" "$r" "$idx" "$BRIDGE_SSID" "$BRIDGE_CHAN" "$BRIDGE_DIST" "$BRIDGE_TXPWR" \
        > /etc/bridge_info
    printf '%s\n' "$role" > /etc/bridge_role
    echo "  ✓ 角色 $role | 5G=$r | iface=$idx | ch=$BRIDGE_CHAN | WDS/4addr | 纯二层桥"
}
