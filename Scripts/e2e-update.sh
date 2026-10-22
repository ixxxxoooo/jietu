#!/bin/bash
# 在线更新端到端回归：真 App、真 HTTP、真安装脚本，不碰 GitHub。
#
# 做法：把当前 Debug 构建复制成「旧版」，再复制一份把版本改成 9.9.9 当「新版」，
# 本地起一个 HTTP 服务当假的 `releases/latest`，让旧版带 `--update-now` 去更新。
# 三个场景：
#   1. 正常：同一张证书签名、摘要正确 → 必须被替换成 9.9.9，设计要求不变，并自动重启；
#   2. 摘要被篡改 → 必须拒绝，旧版原封不动；
#   3. 新包换成 ad-hoc 签名（身份不同）、摘要正确 → 必须拒绝，旧版原封不动。
#
# 前置：已构建 Debug（bash Scripts/restart-dev.sh）、本机有自签名证书 `Jietu`、有桌面会话。
# 注意：会先退出正在运行的 Jietu Dev；结束后重新拉起正式的 Debug 构建。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=".build/Build/Products/Debug/Jietu Dev.app"
APP_NAME="Jietu Dev.app"
E2E="$(mktemp -d /tmp/jietu-e2e.XXXXXX)"
PORT=8765
LOG="$HOME/Library/Logs/Jietu/update.log"
SERVER_PID=""
FAILS=0

cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    pkill -f "$E2E/Applications" 2>/dev/null || true
    rm -rf "$E2E"
}
trap cleanup EXIT

[ -d "$SRC" ] || { echo "先构建 Debug：bash Scripts/restart-dev.sh" >&2; exit 1; }
plist_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }
design_req() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
check() { # check "说明" 条件命令...
    local msg="$1"; shift
    if "$@"; then echo "    ✅ $msg"; else echo "    ❌ $msg"; FAILS=$((FAILS + 1)); fi
}

pkill -f "Jietu Dev.app/Contents/MacOS" 2>/dev/null || true
sleep 1

# 起假发布服务：$1 = 目录
start_server() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    (cd "$1" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >"$E2E/http.log" 2>&1) &
    SERVER_PID=$!
    for _ in $(seq 1 30); do
        curl -s -o /dev/null "http://127.0.0.1:$PORT/latest.json" && return 0
        sleep 0.2
    done
    echo "假发布服务没起来" >&2; exit 1
}

# 造「新版」：$1 = 场景目录，$2 = 签名身份（Jietu 或 -），$3 = 写进 JSON 的摘要（空 = 用真实摘要）
make_release() {
    local dir="$1" identity="$2" digest="$3"
    mkdir -p "$dir/server" "$dir/new"
    ditto "$SRC" "$dir/new/$APP_NAME"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" -c "Set :CFBundleVersion 999" \
        "$dir/new/$APP_NAME/Contents/Info.plist"
    codesign --force --deep --sign "$identity" "$dir/new/$APP_NAME" >/dev/null 2>&1
    local zip="$dir/server/Jietu-9.9.9-macOS.zip"
    ditto -c -k --keepParent "$dir/new/$APP_NAME" "$zip"
    local sha; sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
    cat >"$dir/server/latest.json" <<JSON
{"tag_name":"v9.9.9","name":"Jietu 9.9.9 (e2e)","body":"- e2e","draft":false,"prerelease":false,
 "html_url":"https://example.com/r","published_at":"2026-10-16T08:00:00Z",
 "assets":[{"name":"Jietu-9.9.9-macOS.zip","size":$(stat -f%z "$zip"),
 "browser_download_url":"http://127.0.0.1:$PORT/Jietu-9.9.9-macOS.zip","digest":"sha256:${digest:-$sha}"}]}
JSON
}

# 跑旧版：$1 = 场景目录；返回时旧版进程已退出（成功更新则是新版已被拉起）
run_old() {
    local dir="$1"
    mkdir -p "$dir/Applications"
    ditto "$SRC" "$dir/Applications/$APP_NAME"
    rm -rf "$HOME/Library/Caches/com.ixxxxoooo.jietu/Updates" "$LOG"
    open "$dir/Applications/$APP_NAME" --env "JIETU_UPDATE_API=http://127.0.0.1:$PORT/latest.json" \
        --args --update-now
    # 最多等 40 秒：版本变了（成功）或旧进程退出（被拒绝）。
    for _ in $(seq 1 80); do
        sleep 0.5
        [ "$(plist_version "$dir/Applications/$APP_NAME")" = "9.9.9" ] && break
        pgrep -f "$dir/Applications/$APP_NAME/Contents/MacOS" >/dev/null || break
    done
    sleep 3
}

app_running() { pgrep -f "$1/Contents/MacOS" >/dev/null; }
instance_count() { pgrep -f "$1/Contents/MacOS" | wc -l | tr -d ' '; }

OLD_REQ="$(design_req "$SRC")"
echo "旧版设计要求：$OLD_REQ"

echo "==> 场景 1 / 3：正常更新（同证书、摘要正确）"
D1="$E2E/s1"; make_release "$D1" Jietu ""; start_server "$D1/server"; run_old "$D1"
APP1="$D1/Applications/$APP_NAME"
check "版本变成 9.9.9"                   test "$(plist_version "$APP1")" = "9.9.9"
check "签名自洽"                         codesign --verify --deep --strict "$APP1"
check "设计要求不变（授权可延续）"       test "$(design_req "$APP1")" = "$OLD_REQ"
check "新版已自动重启且只有一个实例"     test "$(instance_count "$APP1")" = "1"
check "安装日志记录了完成"               grep -q "update done" "$LOG"
check "目录里没有暂存 / 备份残留"        test "$(ls -A "$D1/Applications" | wc -l | tr -d ' ')" = "1"
pkill -f "$D1/Applications" 2>/dev/null || true; sleep 1

echo "==> 场景 2 / 3：摘要被篡改"
D2="$E2E/s2"; make_release "$D2" Jietu "$(printf '0%.0s' $(seq 1 64))"; start_server "$D2/server"; run_old "$D2"
APP2="$D2/Applications/$APP_NAME"
check "版本保持不变"                     test "$(plist_version "$APP2")" != "9.9.9"
check "没有触发安装脚本"                 test ! -f "$LOG"
check "旧版进程已收工（被拒绝后退出）"   test "$(instance_count "$APP2")" = "0"

echo "==> 场景 3 / 3：新包身份不同（ad-hoc 签名）"
D3="$E2E/s3"; make_release "$D3" - ""; start_server "$D3/server"; run_old "$D3"
APP3="$D3/Applications/$APP_NAME"
check "版本保持不变"                     test "$(plist_version "$APP3")" != "9.9.9"
check "没有触发安装脚本"                 test ! -f "$LOG"
check "旧版进程已收工（被拒绝后退出）"   test "$(instance_count "$APP3")" = "0"

pkill -f "$E2E/" 2>/dev/null || true
echo
if [ "$FAILS" -eq 0 ]; then echo "e2e-update：全部通过"; else echo "e2e-update：$FAILS 项失败" >&2; fi
# 把正式的 Debug 构建拉回来，保持「跑的就是刚构建的那个」。
bash Scripts/restart-dev.sh >/dev/null 2>&1 || true
[ "$FAILS" -eq 0 ]
