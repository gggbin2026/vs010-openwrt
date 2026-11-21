# 两个 run 都「失败」了，但其实根本没开始编译 —— 是我给的预取脚本自己写错了路径

## 结论先行

两个仓库的前 12 步**全部 success**，包括最难的那几关：`Clone QSDK source`、`Inject nss-dp ethtool fix`、`defconfig → slim → defconfig` 硬校验（设备符号 / 256M / NSS / IPv6 / DEBUGFS 全绿）。

**失败点是第 13 步 `Prefetch ath-kernel tarball`**，后面的 `Download` / `Compile` / `Verify` 全被 skip。所以：

- 没有产生任何固件
- 没有 `build.log`（`No files were found with the provided path: openwrt/build.log`，`if-no-files-found: ignore` 让上传步显示 success，但 artifact 为 0）
- 总共只跑了 28 分钟，不是编译 1 小时

## 致命的一行（两份日志都一样）

```
RAX 7611 / VS 7693: prefetch-ath-kernel.sh: line 72: openwrt/dl/ath-kernel-2021-02-22-b157d227.tar.xz: No such file or directory
RAX 7740 / VS 7824: prefetch-ath-kernel.sh: line 98: openwrt/dl/ath-kernel-2021-02-22-b157d227.tar.xz: No such file or directory
tar: -: Cannot write: Broken pipe
tar: Error is not recoverable: exiting now
RAX 8004 / VS 8090: ##[error] 无法预置 ... —— 立即停止
```

### 根因：相对路径在 `cd` 之后失效

脚本开头：

```bash
DL="${1:-openwrt/dl}"        # workflow 传的就是 openwrt/dl
OUT="$DL/$NAME.tar.xz"       # → 相对路径 "openwrt/dl/xxx.tar.xz"
mkdir -p "$DL"               # 在 $GITHUB_WORKSPACE 下创建，这步成功了
```

但两处打包都写成：

```bash
( cd "$TMP" && tar ... -c "$NAME" | xz ... > "$OUT" )
```

子 shell 已经 `cd` 到 `mktemp -d` 出来的临时目录，那里**没有 `openwrt/dl` 这个相对目录** → shell 重定向直接失败 → `tar` 的输出写到 `-` → `Broken pipe` → `finalize` 判失败。

**网络其实完全没问题**，三条证据：

| 路线 | 实际结果 |
|---|---|
| ① 7 个镜像 | 全 404/403（预期内，这个 tarball 是 QSDK 私有生成的，官方源没有） |
| ② GitLab archive | **下载并解压成功**（否则不会走到 line 72 的打包），只挂在打包重定向 |
| ③ git clone | **3 次全部 100% 成功**：`Updating files: 100% (53679/53679)`、`HEAD is now at b157d227636e`，每次都挂在同一个 `line 98` |

也就是说 clone 花了三遍 53679 个文件，全被一个路径 bug 白扔了。这是我上一包脚本的 bug，跟你的操作、仓库文件、runner 网络都无关。

## 修复：只覆盖 1 个文件，两个仓库同名

`prefetch-ath-kernel.sh`，两仓内容完全相同。改动 4 处：

1. **`DL="$(cd "$DL" && pwd -P)"`** —— 转绝对路径，`OUT` 跟着变绝对；这是核心
2. 打包改成 **先写 `$TMP/pack.tar.xz` 再 `mv` 到 `$OUT`**，避免半成品/坏文件留在 `dl/`
3. `git config --global http.version HTTP/1.1` 等参数**提前到脚本开头**，即使预置失败，原生 `make download` 也能继承
4. 末尾 `exit 1` → **`::warning::` + `exit 0`**：万一三条路线还是全挂，也不阻断 workflow，交给原生 `download.pl` 兜底（workflow 的 Download 步骤末尾还有 `find dl -size -1024c -exec rm -f` 清坏文件）

**其它文件一律不用动**：`.config`、`slim.sh`、`build-openwrt.yml`、`diy-part2.sh`、`patches/`、`files/`、`feeds.conf.default` 全是对的。

覆盖后 Actions → 对应 workflow → Run workflow，`ssh` / `use_nwrt_dump_dts` 留 `false`。

> 备选（不想传文件也行）：直接把 workflow 里 `Prefetch ath-kernel tarball` 那 5 行整段删掉。本轮日志已证明原生 `git clone` 能成功，但这样就丢了 HTTP/1.1 防断流，不如覆盖脚本稳。

## 这轮日志里其它「像错误」的，都不是失败点

| 现象 | 判定 |
|---|---|
| `tmp/.config-package.in:...:error: recursive dependency detected!`（各 30 条，出现两轮） | **Kconfig 对循环依赖的告警**，会自行断开并继续；`make defconfig` 退出码 0，随后 `✓ 设备 / 256M / NSS / IPv6 全部符合预期` 打印成功。这是 QSDK 老树常见现象，不用修 |
| `启用包数: 176 / 178`（不是静态检查的 122 / 138） | `make defconfig` 按依赖关系把内核模块等重算拉回，`slim.sh` 本来就把 `kmod-*` 交给 defconfig 处理。硬校验全绿即可，数字不是验收标准 |
| VS010 的 `Organize files` failure（8139 行 `cd: openwrt/bin/targets/ipq50xx/arm: No such file`） | **连锁失败**：Compile 被 skip → 没有 `bin/` 目录。修好 Prefetch 后自然消失 |
| `Upload build log` success 但 artifact 0 个 | Compile 被 skip，`build.log` 不存在，`if-no-files-found: ignore` 不报错 |
| `Node.js 20 is deprecated` | warning，`checkout@v4` / `upload-artifact@v4` 被强制跑 Node24，不影响 |
| `Package 'xxx' is not installed, so not removed`（Init environment 几百行） | `apt-get remove ... \|\| true` 的正常输出 |

## 已验证 / 边界

已验证：

- `bash -n` 通过
- **本地复现旧 bug**：用相对 `OUT` + `cd` 到临时目录，得到一模一样的 `No such file or directory` + `Broken pipe`，子 shell 退出码 1、文件不存在
- **本地验证修复**：绝对 `DL` + 先写 TMP 再 `mv`，打包退出码 0，`tar -tf` 列出 `ath-kernel-.../` 顶层目录，`finalize` 的 `grep -q "^$NAME/"` 命中
- 两仓脚本字节一致

**没跑真实 `make`**（本会话缺 toolchain）。但本轮失败发生在编译之前，修复只涉及 shell 路径，不碰任何编译配置。

## 下一轮预期

Prefetch 步骤应打印 `✓ 预置完成: /.../openwrt/dl/ath-kernel-2021-02-22-b157d227.tar.xz (xxxxx B)`，然后 `Download` 直接命中、不再 clone，`Compile` 正常跑 1~2 小时。

重点仍是四个点：`defconfig` 硬校验（已连续两轮全绿）、`Prefetch`、`Compile`、`Verify ethtool patch applied`。跑完把 Artifact 清单或新 `build.log` 最后 100 行发我收口。

刷机前记得：TTL 只接 TX/RX/GND 别碰 1.8V、**先备份 `0:ART`**。
