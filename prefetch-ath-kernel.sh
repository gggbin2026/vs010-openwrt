#!/bin/bash
# 预置 ath-kernel tarball，绕开「7 个镜像全 403/404 + git clone packfile TLS 断流」。
#
# 依据：底座 package/kernel/mac80211 的 download.pl 参数是
#   download.pl dl ath-kernel-2021-02-22-b157d227.tar.xz "skip" ""
# hash = skip（不校验），所以只要 dl/ 里有同名、可读、顶层目录正确的 tar.xz，
# download.pl 会直接命中，不会再触发那个跑了 792 秒才断的 git clone。
#
# 三条路线：① 现成镜像 ② GitLab archive 单次 GET（不传 packfile，最不易断）
#          ③ 原版 git clone，但强制 HTTP/1.1 + 3 次重试
set -u

DL="${1:-openwrt/dl}"
NAME="ath-kernel-2021-02-22-b157d227"
OUT="$DL/$NAME.tar.xz"
COMMIT="b157d227636eb4fd9854218c4802e8dab2eadf1b"
REPO="https://git.codelinaro.org/clo/qsdk/kvalo/ath.git"
WEB="https://git.codelinaro.org/clo/qsdk/kvalo/ath"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DL"

finalize() {
  [ -s "$OUT" ] || return 1
  tar -tf "$OUT" > "$TMP/list" 2>/dev/null || return 1
  grep -q "^$NAME/" "$TMP/list" || return 1
  echo "✓ 预置完成: $OUT ($(stat -c%s "$OUT") B)"
  exit 0
}

if [ -s "$OUT" ]; then
  echo "=== 已有 $OUT，先校验 ==="
  finalize || { echo "::warning:: 已有文件不可读，重新预取"; rm -f "$OUT"; }
fi

CURL="curl -fL --connect-timeout 20 --retry 5 --retry-all-errors --retry-delay 3 --max-time 300"

echo "=== [1/3] 现成 tarball 镜像 ==="
for u in \
  "https://sources.openwrt.org/$NAME.tar.xz" \
  "https://mirror2.openwrt.org/sources/$NAME.tar.xz" \
  "https://sources.cdn.openwrt.org/$NAME.tar.xz" \
  "https://sources.immortalwrt.org/$NAME.tar.xz" \
  "https://mirror2.immortalwrt.org/sources/$NAME.tar.xz" \
  "https://sources-cdn.immortalwrt.org/$NAME.tar.xz" \
  "https://mirror.immortalwrt.org/sources/$NAME.tar.xz" ; do
  if $CURL "$u" -o "$TMP/m.tar.xz" 2>/dev/null && [ -s "$TMP/m.tar.xz" ]; then
    mv "$TMP/m.tar.xz" "$OUT"
    if finalize; then :; else
      echo "  镜像 $u 内容不可用，继续"
      rm -f "$OUT"
    fi
  fi
  rm -f "$TMP/m.tar.xz"
done
echo "  7 个镜像未命中（日志里就是全 403/404，预期内）"

echo "=== [2/3] GitLab archive 单次 GET（不传 packfile）==="
if $CURL "$WEB/-/archive/$COMMIT/ath-$COMMIT.tar.gz" -o "$TMP/a.tar.gz" 2>/dev/null \
   && [ -s "$TMP/a.tar.gz" ] \
   && tar -xzf "$TMP/a.tar.gz" -C "$TMP" 2>/dev/null; then
  SRC=$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -1)
  if [ -n "$SRC" ]; then
    mv "$SRC" "$TMP/$NAME"
    # 有 .gitmodules 说明 archive 缺 submodule 内容，主动放弃，退回路线 3
    if [ -s "$TMP/$NAME/.gitmodules" ]; then
      echo "  ::warning:: 仓库含 submodule，archive 不完整，退回 clone"
      rm -rf "$TMP/$NAME"
    else
      ( cd "$TMP" && tar --numeric-owner --owner=0 --group=0 --sort=name \
          -c "$NAME" | xz -zc -7e > "$OUT" )
      finalize || { echo "  archive 产物不可用，继续"; rm -f "$OUT"; }
    fi
  fi
fi

echo "=== [3/3] git clone（HTTP/1.1 + 3 次重试）==="
# curl 56 / GnuTLS recv error (-110) 常见于 HTTP/2 大包传输；强制 HTTP/1.1 是标准解法
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000
git config --global http.lowSpeedLimit 0
git config --global http.lowSpeedTime 999999
git config --global core.compression 0

for i in 1 2 3; do
  rm -rf "$TMP/clone"
  mkdir -p "$TMP/clone"
  if ( cd "$TMP/clone" \
       && git clone --filter=blob:none "$REPO" "$NAME" \
       && cd "$NAME" \
       && git checkout "$COMMIT" \
       && git submodule update --init --recursive ); then
    TS=$(cd "$TMP/clone/$NAME" && git log -1 --format='@%ct')
    rm -rf "$TMP/clone/$NAME/.git"
    ( cd "$TMP/clone" \
      && tar --numeric-owner --owner=0 --group=0 --mode=a-s --sort=name \
           --mtime="$TS" -c "$NAME" | xz -zc -7e > "$OUT" )
    finalize || { echo "  clone 产物不可用，继续"; rm -f "$OUT"; }
  fi
  echo "::warning:: git clone 第 $i 次失败，10s 后重试"
  sleep 10
done

echo "::error:: 无法预置 $NAME.tar.xz —— 立即停止，避免再白跑 1 小时编译"
exit 1
