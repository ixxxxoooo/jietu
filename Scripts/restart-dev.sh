#!/usr/bin/env bash
#
# 构建 Debug 渠道 → 杀掉旧实例 → 启动新产物 → **校验跑的就是刚构建的那个**。
#
# 为什么要校验：`xcodebuild test` 或任何一次新的构建都会刷新产物的 mtime，
# 而正在跑的进程可能还是上一次构建的；只 `open` 一次也未必能保证新旧一致。
# 这里比较「进程启动时刻」与「产物 mtime」，发现跑旧了就再重启一次。
#
# 用法：bash Scripts/restart-dev.sh
set -uo pipefail
cd "$(dirname "$0")/.."

APP=".build/Build/Products/Debug/Jietu Dev.app"
BIN="$APP/Contents/MacOS/Jietu Dev"
MATCH="Build/Products/Debug/Jietu Dev.app"
PATTERN="MacOS/Jietu Dev"

echo "==> 1/3 构建"
if ! xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath .build build \
    | grep -E "(error:|warning: [A-Z])|BUILD (SUCCEEDED|FAILED)"; then
    :
fi
if [ ! -d "$APP" ]; then
    echo "构建失败：找不到 $APP"; exit 1
fi

echo "==> 2/3 重启"
# 清理可能同时在跑的正式版（避免全局快捷键与全屏遮罩冲突）
RELEASE_PID="$(pgrep -f "/Applications/Jietu.app/Contents/MacOS/Jietu" | head -1 || true)"
if [ -n "$RELEASE_PID" ]; then
    echo "发现运行中的正式版 Jietu (PID: $RELEASE_PID)，自动退出以避免快捷键与遮罩冲突"
    pkill -f "/Applications/Jietu.app/Contents/MacOS/Jietu" >/dev/null 2>&1 || true
fi
pkill -f "$MATCH" >/dev/null 2>&1
sleep 1
open "$APP"
sleep 3

echo "==> 3/3 校验"
count() { pgrep -f "$PATTERN" | wc -l | tr -d ' '; }
if [ "$(count)" -eq 0 ]; then
    echo "没有实例在跑，重试一次"; open "$APP"; sleep 3
fi
PID="$(pgrep -f "$PATTERN" | head -1 || true)"
if [ -z "${PID:-}" ]; then
    echo "启动失败"; exit 1
fi

BIN_EPOCH="$(stat -f %m "$BIN")"
# `ps lstart` 会跟着系统语言本地化，强制 C locale 才能被 date 解析。
START_RAW="$(LC_ALL=C ps -p "$PID" -o lstart= | sed 's/^ *//;s/ *$//')"
START_EPOCH="$(date -j -f "%a %b %d %T %Y" "$START_RAW" +%s 2>/dev/null || echo "")"
if [ -z "$START_EPOCH" ]; then
    echo "（无法解析进程启动时刻 \"$START_RAW\"，跳过新旧校验）"
elif [ "$START_EPOCH" -lt "$BIN_EPOCH" ]; then
    echo "运行实例($START_EPOCH) 比产物($BIN_EPOCH) 旧 → 再重启一次"
    pkill -f "$MATCH" >/dev/null 2>&1
    sleep 1
    open "$APP"
    sleep 3
    PID="$(pgrep -f "$PATTERN" | head -1 || true)"
fi

echo "实例数=$(count)  pid=${PID:-—}"
echo "产物   mtime = $(stat -f '%Sm' "$BIN")"
echo "进程   启动  = $(ps -p "${PID:-1}" -o lstart= 2>/dev/null | sed 's/^ *//' || echo '—')"
echo "路径         = $(ps -p "${PID:-1}" -o comm= 2>/dev/null || echo '—')"
