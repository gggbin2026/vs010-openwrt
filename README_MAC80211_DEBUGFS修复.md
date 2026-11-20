# VS010 又失败：这次不是下载，是 `ath11k` 真编译报错

## 一句话结论

**前几轮的修复全生效了，而且这次网络也争气——`ath-kernel` 下载全过了。** 编译一路跑到 `ath11k/core.c` 才第一次撞上一个真正的源码编译错误：`.config` 把 `CONFIG_PACKAGE_MAC80211_DEBUGFS` 关掉了，而 QSDK 11.5 的 ath11k backports 有个 `#ifdef` 不一致，关掉 DEBUGFS 就必炸。

**两个仓库都要改**，因为 RAX3000Q 的 `.config` 也是关的——它上一轮挂在下载、还没编到这一步，下载修好后一定撞同一个错。

---

## 真实失败点（日志 107465 / 107472）

```
107465: backports-.../drivers/net/wireless/ath/ath11k/core.c:571:32:
        error: 'struct ath11k' has no member named 'debug'
107466:   ath11k_fw_stats_vdevs_free(&ar->debug.fw_stats.vdevs);
107472: backports-.../drivers/net/wireless/ath/ath11k/debugfs.h:199:13:
        error: 'ath11k_debugfs_dbg_mac_filter' defined but not used [-Werror=unused-function]
107475: cc1: all warnings being treated as errors
107476: make[11]: *** [.../ath11k/core.o] Error 1
107601:     ERROR: package/kernel/mac80211 failed to build (build variant: regular).
107606: make: *** [include/toplevel.mk:230: world] Error 2
```

`time: package/kernel/mac80211/regular/compile#39.13#8.42#21.53` —— 这次是真编译（CPU 39 秒），不是上一轮那 792 秒干等下载。

## 根因：QSDK 11.5 的 `#ifdef` 缺陷 + 配置关错

`ath11k_fw_stats_reset()` 在 `core.c` 里**无条件**引用 `ar->debug`，但 `struct ath11k` 的 `debug` 字段被 `#ifdef CPTCFG_ATH11K_DEBUGFS` 包着；`debugfs.h` 里 `ath11k_debugfs_dbg_mac_filter()` 是 `static`，调用点同样只在 DEBUGFS 路径里。于是**关掉 DEBUGFS** 会同时造成：

1. `struct ath11k` 没有 `debug` 成员 → 硬错误
2. static 函数没人调用 → `-Werror=unused-function` → 第二个错误

而 OpenWrt 的 `package/kernel/mac80211/ath.mk` 里写得很清楚：

```make
ifdef CONFIG_PACKAGE_MAC80211_DEBUGFS
  config-y += ATH9K_DEBUGFS ATH9K_HTC_DEBUGFS ATH10K_DEBUGFS \
              ATH11K_DEBUGFS ATH12K_DEBUGFS ...
endif
```

也就是 `CONFIG_PACKAGE_MAC80211_DEBUGFS=y` → `CPTCFG_ATH11K_DEBUGFS=y` → `debug` 字段存在 + static 函数被调用 → **两个错误一起消失**。

你这俩 `.config` 里都是关的：

| 仓库 | 原值 |
|---|---|
| VS010 2780 | `# CONFIG_PACKAGE_MAC80211_DEBUGFS is not set` |
| RAX3000Q 2779 / 7268 | `# CONFIG_PACKAGE_MAC80211_DEBUGFS=y is not set`（畸形行）+ `# ... is not set` |

> 注意：社区有个 issue 说「关 debug 就能编过」，那是指 **64 位**编译时 `debugfs_netdev.c` 的 `incompatible-pointer-types`；同一个帖子里明确写「**编译 32 位不会报错**」。你这套是 `arm_cortex-a7+neon-vfpv4_musl_eabi`（32 位 armv7l），所以**开 DEBUGFS 安全**，不用担心那条。

## 为什么前几轮没撞上

| 轮次 | 挂在 | 有没有编到 core.c |
|---|---|---|
| 设备符号丢失 | defconfig | ❌ |
| `cmd->base.mdix` | qca-nss-dp | ❌ |
| RAX3000Q 下载失败 | mac80211 的 `ath-kernel` 拉取 | ❌ |
| **本轮 VS010** | **ath11k/core.c** | ✅ 第一次 |

上一轮加的 `prefetch-ath-kernel.sh` 这轮**没有触发**（日志里 `RPC failed` / `expected 'packfile'` 均 0 条，38 条 `Checking out files from the git repository` 都成功了）——是 runner 网络好，下载自己过了。脚本仍然是必要的保险，别删。

## 修法：只改 3 个文件，两个仓库都改

| 文件 | 改动 |
|---|---|
| `.config` | `CONFIG_PACKAGE_MAC80211_DEBUGFS=y`（RAX3000Q 那两行合并成一行，清掉畸形注释） |
| `slim.sh` | 「全局关键开关」循环里加 `CONFIG_PACKAGE_MAC80211_DEBUGFS=y`，防 `defconfig` 把它拉回 |
| `.github/workflows/build-openwrt.yml` | 最终硬校验加一条：符号不是 `=y` 就 `::error::` 立即停 |

**这不是装插件**：`MAC80211_DEBUGFS` 是编译期开关，不新增任何软件包，只是把 debugfs 代码编进已有的 `kmod-ath11k`，镜像大几十 KB、内存开销可忽略。`.config` 里 `CONFIG_KERNEL_DEBUG_FS=y` 本来就在，依赖已满足。而且开着还有个好处——刷完能看 `/sys/kernel/debug/ath11k/...` 的 fw_stats，排障更方便。

**一律别动**：`prefetch-ath-kernel.sh`、`patches/999-nss-dp-ethtool-fixed-link.patch`（2348 B mdix 修正版）、`inject-ethtool-patch.sh`、`diy-part2.sh`（VS010 的 BuildImage 锚定修复）、`files/`（UBNT 开机成桥脚本）、`feeds.conf.default`、`vs010/`。

覆盖后 Actions → 对应 workflow → Run workflow，`ssh` / `use_nwrt_dump_dts` 留 `false`。

## 这轮日志里其它「像错误」的，都不是失败点

| 行 | 内容 | 判定 |
|---|---|---|
| 开头 28 条 | `dependency ... does not exist` WARNING | QSDK 树声明了当前 5 个 feed 没有的可选依赖，defconfig 扫描忽略项 |
| 72770 | `cc1: error: no include path ... stdc-predef.h` | GCC 8.4 自举探测宏列表；后面几万行交叉编译器正常 |
| 93023 / 93462 | util-linux 镜像 404 / 403 | 换源兜住，末尾编成 |
| 101045 / 101049 | `Autoconf version 2.71 required` / `aclocal.real: error` | 某个包的 autoreconf 输出，后面 configure 正常继续，不在失败链 |
| 多条 `Error 1 (ignored)` / `Broken pipe` / `static EXPORT_SYMBOL` | 显式忽略或并行收尾 | 无害 |
| **107591** | `qca-nss-ecm/standard/compile#19.04#4.15#24.10` | **ECM 完整编出来了** —— IPv6 关闭版没问题，别翻回那个已撤回的保守包 |
| 98906 | `patching file nss_dp_ethtools.c` | mdix 修正补丁已应用，旧版 `cmd->base.mdix` 命中 0 条 |
| `cucc_vs010 设备符号丢失` | 0 条 | BuildImage 锚定修复生效 |

整份 107539 行日志**只有 107465 和 107472 两条真错误，且同源**。

## 已验证 / 边界

已验证：两个 `.config` 只留 1 行 `=y`；`slim.sh` 用正确解释器实跑两遍幂等（DEBUGFS=1、设备符号=1、256M profile=1、IPv6=0、luci-app=0、包数 122 / 138）；两个 workflow YAML 解析出 19 步，`Prefetch` 仍在第 12 步；硬校验各 1 条。

**没跑真实 `make`**（本会话缺 toolchain / 磁盘 / 内存）。`CONFIG_PACKAGE_MAC80211_DEBUGFS` → `CPTCFG_ATH11K_DEBUGFS` 的映射来自 OpenWrt 官方 `ath.mk`，逻辑闭环，但要 Actions 点一次才算数。

万一（极小概率）开 DEBUGFS 后在 64 位工具链上撞 `debugfs_netdev.c:139 incompatible-pointer-types`，退路是在 `package/kernel/mac80211/Makefile` 的 `EXTRA_CFLAGS` 里加 `-Wno-error=incompatible-pointer-types`——**你现在是 32 位，用不上，别提前加**。

跑完把新 `build.log` 最后 100 行发我，我按实际结果收口。
