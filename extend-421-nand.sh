#!/bin/bash
# 在 workflow 的 "Inject nss-dp ethtool fix" 之后、make defconfig 之前调用
# 工作目录: openwrt/      仓库根: $GITHUB_WORKSPACE
#
# 做法：直接扩展底座自带的 421-mtd-rawnand-winbond-...patch，
# 在它已验证可应用的 hunk 里追加 GD5Fx 闪存 ID。等价于社区那个
# 422-add-GD5Fx-nand-support.patch，但不用新补丁文件、不赌行号上下文。
#
# 可用环境变量 NAND_IDS 指定要补的 ID（逗号分隔，十六进制，不带 0x）：
#   NAND_IDS=c841 bash extend-421-nand.sh     # 只补 TTL 实测到的那一颗
# 默认补 3 个常见批次：c841 / c877 / c881
set -euo pipefail

P="target/linux/ipq50xx/patches/421-mtd-rawnand-winbond-add-support-for-W25N01GW.patch"
IDS="${NAND_IDS:-c841,c877,c881}"

echo "==================== [NAND] 扩展 421：补 GD5Fx 闪存 ID ===================="
test -f "$P" || { echo "::error::不是 kkstone 5.4-QSDK 底座（缺 421 补丁）"; exit 1; }
grep -q 'drivers/mtd/nand/raw/nand_ids.c' "$P" \
  || { echo "::error::421 补丁目标不是 nand_ids.c"; exit 1; }

python3 - "$P" "$IDS" <<'PY'
import sys,re
p,ids=sys.argv[1],[x.strip().lower() for x in sys.argv[2].split(',') if x.strip()]
names={'c841':'GD5F1GQ5REYIG','c877':'GD5F1GQ5REYIG-B','c881':'GD5F1GM7REYIG',
       'c821':'GD5F1GQ5REYIH'}
t=open(p,encoding='utf-8').read()
if '0xc8, 0x41' in t and '0xc8, 0x77' in t and '0xc8, 0x81' in t:
    print('  ✓ 已扩展过，幂等跳过'); sys.exit(0)

# 底座 421 里 W25N01GW 的三行新增块，作为插入锚点
anchor=('+\t{"W25N01GW SPI NAND 1.8V 1G-BIT",\n'
        '+\t\t{ .id = {0xef, 0xba} },\n'
        '+\t\tSZ_2K, SZ_128, SZ_128K, 0, 2, 64, NAND_ECC_INFO(4, SZ_512), 0},\n')
assert t.count(anchor)==1, '421 补丁结构变了，锚点不唯一'

add=''
for i in ids:
    assert re.fullmatch(r'[0-9a-f]{4}',i), f'非法 ID: {i}'
    hi,lo=f'0x{i[:2]}',f'0x{i[2:]}'
    if i in ('c821','efba','efbc'):
        print(f'  ::warning:: {i} 底座表里已有，跳过'); continue
    nm=names.get(i,f'GD5F-{i}')
    add+=(f'+\t{{"{nm} SPI NAND 1G 1.8V",\n'
          f'+\t\t{{ .id = {{{hi}, {lo}}} }},\n'
          f'+\t\tSZ_2K, SZ_128, SZ_128K, 0, 2, 64, NAND_ECC_INFO(4, SZ_512), 0}},\n')
n=add.count('\n')
assert n>0,'没有可补的 ID'

t=t.replace(anchor,anchor+add)
# hunk 头：旧 6 行不变，新 9 → 9+n
old=re.search(r'@@ -(\d+),(\d+) \+(\d+),(\d+) @@',t)
assert old,'找不到 hunk 头'
a,b,c,d=old.groups()
t=t[:old.start()]+f'@@ -{a},{b} +{c},{int(d)+n} @@'+t[old.end():]
# diffstat 同步（纯注释性，不影响 patch）
t=re.sub(r'(\| )(\d+) (\++)',lambda m: f'| {int(m.group(2))+n} '+' +'*(int(m.group(2))+n),t,count=1)
t=re.sub(r'1 file changed, (\d+) insertions\(\+\)',
         lambda m:f'1 file changed, {int(m.group(1))+n} insertions(+)',t,count=1)
open(p,'w',encoding='utf-8').write(t)
print(f'  ✓ 追加 {n} 行 / {n//3} 个 ID: {", ".join(ids)}')
print(f'  ✓ hunk 新侧 {d} → {int(d)+n}')
PY

grep -q '0xc8, 0x41' "$P" || grep -qE '0xc8, 0x(41|77|81)' "$P" \
  || { echo "::error::GD ID 没写进 421"; exit 1; }
echo "  ✓ $P 已扩展（内核编译时随 421 一并应用）"
echo "==================== [NAND] 完成 ===================="
echo "  刷机后验收：dmesg | grep -iE 'nand|qpic|ecc' ; cat /proc/mtd"
