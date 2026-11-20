# RAX3000Q 又失败：这次不是代码问题，是 `ath-kernel` 源码包没下下来

## 一句话结论

**前两次的修复全生效了。** mdix 补丁已修正（`qca-nss-dp` 编过了）、设备符号没问题、IPv6 关闭版也没问题（`qca-nss-ecm` 这次完整编出来了）。这次挂在**纯粹的下载**：`ath-kernel-2021-02-22-b157d227.tar.xz` 七个镜像全 403/404，兜底 `git clone` 跑了 792 秒后 TLS 断流。

```
104141: error: RPC failed; curl 56 GnuTLS recv error (-110): The TLS connection was non-properly terminated.
104142: fatal: expected 'packfile'
104143: make[3]: *** [Makefile:520: .../dl/ath-kernel-2021-02-22-b157d227.tar.xz] Error 128
104146:     ERROR: package/kernel/mac80211 failed to build (build variant: regular).
104151: make: *** [include/toplevel.mk:230: world] Error 2
```

`time: package/kernel/mac80211/regular/compile#0.38#0.12#792.34` —— CPU 只用了 0.38 秒，**792 秒全花在下载重试上**，一行编译都没跑。

## 完整因果链（日志逐字可查）

103158 行给出了底座的下载命令：

```
download.pl dl ath-kernel-2021-02-22-b157d227.tar.xz "skip" ""
   || git clone --filter=blob:none https://git.codelinaro.org/clo/qsdk/kvalo/ath.git ...
      && git checkout b157d227636eb4fd9854218c4802e8dab2eadf1b
      && git submodule update --init --recursive
      && tar ... | xz -zc -7e > dl/ath-kernel-2021-02-22-b157d227.tar.xz
```

1. 103162 / 103200 / 103268 / 103300 / 103344 / 103374 / 103417：**7 个镜像依次 403 / 404**
2. 103475 `Checking out files from the git repository...` → 103476 `Cloning into 'ath-kernel-...'`
3. 104141：GnuTLS 连接被非正常终止，`expected 'packfile'`（大 packfile 走 HTTP/2 时常见）
4. mac80211 是 WDS/hostapd 的依赖，它挂了 `world` 就停

**关键**：`download.pl` 第三个参数是 `"skip"` —— 这个包 **不校验 hash**。只要 `openwrt/dl/` 里有一个同名、可读、顶层目录为 `ath-kernel-2021-02-22-b157d227/` 的 tar.xz，`download.pl` 就直接命中，根本不会再去 clone。

## 这次日志里其它"像错误"的，都不是失败点

| 行 | 内容 | 判定 |
|---|---|---|
| 开头 26 条 | `dependency ... does not exist` WARNING | QSDK 树声明了当前 5 个 feed 没有的可选依赖，defconfig 扫描忽略项 |
| 72769 | `cc1: error: no include path ... stdc-predef.h` | GCC 8.4 自举探测宏列表，后续几万行交叉编译器正常 |
| 93505 / 94047 | util-linux 镜像 404/403 | 换源兜住了，末尾编译成功 |
| 101164 | `configure.ac:27: error: Autoconf version 2.71 or higher is required` | 某个包的 autoreconf 输出，后面 101170~101180 的 `./configure` 正常继续，没有跟 `make ***` |
| 101167 | `aclocal.real: error: echo failed` | 同上，不在失败链 |
| 多条 `Error 1 (ignored)` / `Broken pipe` / `static EXPORT_SYMBOL` | 显式忽略或并行收尾 | 无害 |
| **104140** | `qca-nss-ecm/standard/compile#10.22#1.33#11.65` | **ECM 完整编出来了** —— 我上上轮「关 IPv6 会挂 ECM」的推测彻底作废，IPv6 关闭版是对的，别用那个已撤回的保守包 |

整份 104076 行日志**只有 104141 一条真致命错误**。

## 修法：预置 tarball，三层兜底

新增 `prefetch-ath-kernel.sh`，插在 `Download` 步骤之前：

| 路线 | 做法 |
|---|---|
| ① | 7 个官方镜像 `curl --retry 5 --retry-all-errors`，命中且 `tar -tf` 可读即用 |
| ② | **`git.codelinaro.org` 的 GitLab archive 端点**：单次 HTTP GET 拿 `.tar.gz`，不传 packfile，最不容易断；本地重打包成期望的 `.tar.xz`。若解包发现 `.gitmodules` 则主动放弃（archive 不含 submodule 内容），退回路线 ③ |
| ③ | 原版 `git clone`，但强制 **`http.version HTTP/1.1`** + `postBuffer 512M` + 低速超时放宽 + **3 次重试** |

三条都失败会 `::error::` **立即停**，不再白跑一小时编译。

> 沙盒里探测这些源被统一 403（沙盒网络策略，不是源本身已死）；但日志证明 runner 能连上 `git.codelinaro.org`（clone 连上了、只是 packfile 传输断），所以路线 ②/③ 在 runner 上是可行的。脚本不依赖任何单一源。

## 你要做的（最小改动：只覆盖 3 个文件）

```
prefetch-ath-kernel.sh                    → 两个仓库根目录各放一份
.github/workflows/build-openwrt.yml        → 两个仓库各自同名覆盖（已插入 Prefetch 步骤）
```

**其它一律别动**：`.config` / `slim.sh` / `diy-part2.sh` / `inject-ethtool-patch.sh` / `patches/` / `files/` / `feeds.conf.default` / `vs010/`。mdix 修正补丁和设备符号修复都保留。

然后 Actions → 对应 workflow → Run workflow，`ssh` / `use_nwrt_dump_dts` 留 `false`。

**也可以只点 Re-run 不覆盖**：这是偶发网络抖动，重跑有概率一次过。但风险是又烧 1 小时才在最后断；覆盖脚本后即使网络再抽，也会在编译前的第 12 步就明确报出来。

## 顺带：VS010 也要一起覆盖

它用的是同一套 `kkstone/immortalwrt-ipq50xx @ openwrt-21.02`、同一个 `package/kernel/mac80211`、同一个 commit `b157d227`。之前 VS010 挂在更早的 `qca-nss-dp`，没走到 mac80211；mdix 修好后**一定会撞上同一个下载坑**。两个包都已包含这个预取步骤。

## 交付物说明

`UBNT_RAX3000Q.zip` / `UBNT_VS010.zip` 已同步更新，除本次 3 个文件外，还含：
- 2348 B 的 mdix 修正版 ethtool 补丁（两仓库线上旧版 2328 B 必须替换）
- VS010 的 `BuildImage` 锚定版 `diy-part2.sh`（修设备符号丢失）
- 上一轮的 UBNT 开机成桥脚本（`99-zz-bridge-role` 等 9 个 files）

所以直接整包覆盖也行，会把「开机即桥」一起装上，与本次下载修复不冲突。日志里 `bridge-status` / `99-zz-bridge-role` 命中 0 条，说明你这次还没上传那份，覆盖后顺带补上。

## 验证到什么程度

已验证：`bash -n` 通过；模拟已预置 tarball 时 `finalize()` 的「已有文件→校验顶层目录→跳过」分支正确返回；两个 workflow YAML 解析出 19 步，`Prefetch` 都排在第 12 步、`Download` 之前；脚本插入锚点唯一。

**没跑真实 `make`**（本会话缺 toolchain / 磁盘 / 内存），也没法在沙盒里验证 runner 到 codelinaro 的连通性。三层兜底 + 立即失败保护能保证「不再无声地烧掉一小时」，但实际命中哪条路线要 Actions 日志说话。跑完把 `RAX3000Q_build_log` 最后 100 行发我，我按真实结果收口。
