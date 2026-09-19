#!/usr/bin/env bash
#
# 构建 Release 渠道 → 校验签名 → 打成可直接分发的 DMG。
#
# 与 `restart-dev.sh` 的分工：那条跑 Debug（开发渠道，Jietu Dev.app），
# 这条跑 Release（正式渠道，Jietu.app，通用二进制），产物落在 dist/。
#
# 用法：bash Scripts/build-dmg.sh
#
# 输出：dist/Jietu-<版本>.dmg（内含 Jietu.app 与 /Applications 软链）
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Jietu"
CONFIG="Release"
DERIVED=".build"
APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
DIST="dist"

# ---------- 1/5 构建 ----------
echo "==> 1/5 构建（${CONFIG}）"
LOG="$(mktemp -t jietu-release)"
if ! xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration "$CONFIG" \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" build > "$LOG" 2>&1; then
    echo "构建失败，错误如下（完整日志：${LOG}）："
    grep -E "error:" "$LOG" | head -20 || tail -30 "$LOG"
    exit 1
fi
grep -E "error:" "$LOG" | head -5 || true
rm -f "$LOG"
[ -d "$APP" ] || { echo "构建成功但找不到产物：$APP"; exit 1; }

# ---------- 2/5 校验产物 ----------
echo "==> 2/5 校验签名与版本"
# 自签名证书没有 Developer ID，但签名必须自洽——否则装到别人机器上会被 TCC 拒掉。
codesign --verify --deep --strict "$APP" || { echo "签名校验不通过：$APP"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
# Debug 渠道的 bundle id 带 .dev，混进来就是打错渠道了。
case "$BUNDLE_ID" in
    *".dev") echo "产物是 Debug 渠道（${BUNDLE_ID}），拒绝打包"; exit 1 ;;
esac

DMG="$DIST/$APP_NAME-$VERSION.dmg"
echo "    版本 $VERSION ($BUILD)  标识 $BUNDLE_ID"
echo "    架构 $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
echo "    签名 $(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

# ---------- 3/5 暂存 ----------
echo "==> 3/5 暂存"
STAGE="$(mktemp -d -t jietu-dmg)"
trap 'rm -rf "$STAGE"' EXIT
# ditto 比 cp -R 更能保真地带上资源分叉 / 扩展属性 / 权限位。
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# 在 DMG 内放安装说明 +「移除隔离」小工具。
#
# 注意：从网上下载的 DMG 里，任何可执行文件（.command / .app）第一次都会被
# Gatekeeper 拦截——这正是「解除隔离」工具自己也打不开的原因。
# 正确用法是：右键 → 打开（与打开自签名 Jietu.app 同一套流程）。
cat > "$STAGE/00-请先读我.txt" <<'INSTALL'
=== Jietu 安装说明 / Installation ===

1. 把 Jietu.app 拖到右边的 Applications（应用程序）文件夹。

2. 移除隔离（二选一）
   【推荐】右键点击「Fix Gatekeeper.app」→ 打开 → 再点「打开」
            （双击会被系统拦截，这是正常的，必须右键打开一次）
   【或】在「终端」执行：
            xattr -dr com.apple.quarantine /Applications/Jietu.app
   【或】右键 Jietu.app → 打开 → 打开

3. 授权
   • 屏幕录制（必需）：系统设置 › 隐私与安全性 › 屏幕录制 → 添加 Jietu → 重启 App
   • 辅助功能（可选，滚动长图自动滚）：系统设置 › 隐私与安全性 › 辅助功能
   • 通知（可选）：允许横幅，保存后才有系统通知

更多：https://github.com/ixxxxoooo/jietu
INSTALL

# 用 AppleScript 打成 .app，并签上与主 App 相同的「Jietu」证书。
HELPER_SCRIPT="$(mktemp -t jietu-fix-gatekeeper).applescript"
cat > "$HELPER_SCRIPT" <<'OSA'
-- 移除 /Applications/Jietu.app 的隔离属性。
-- 首次从下载的 DMG 打开时：请右键 → 打开（双击会被 Gatekeeper 拦）。
-- @author ygw
on run
	set appPath to "/Applications/Jietu.app"
	try
		do shell script "test -d " & quoted form of appPath
	on error
		display dialog "请先把 Jietu.app 拖到「应用程序」文件夹，再运行本工具。" & return & return & "Please drag Jietu.app into Applications first." buttons {"OK"} default button 1 with title "Jietu" with icon caution
		return
	end try
	try
		do shell script "xattr -dr com.apple.quarantine " & quoted form of appPath
		display dialog "已移除隔离属性，现在可以正常打开 Jietu。" & return & return & "Quarantine removed. You can open Jietu normally now." buttons {"OK"} default button 1 with title "Jietu"
	on error errMsg
		display dialog "失败 / Failed：" & return & errMsg buttons {"OK"} default button 1 with title "Jietu" with icon stop
	end try
end run
OSA

HELPER_APP="$STAGE/Fix Gatekeeper.app"
rm -rf "$HELPER_APP"
osacompile -o "$HELPER_APP" "$HELPER_SCRIPT"
rm -f "$HELPER_SCRIPT"
# 与主 App 同一自签名身份，用户对证书信任后体验更一致。
codesign --force --sign "Jietu" --timestamp=none "$HELPER_APP" 2>/dev/null \
	|| codesign --force --sign - "$HELPER_APP"
# 确认可执行入口在。
[ -d "$HELPER_APP" ] || { echo "未能生成 Fix Gatekeeper.app"; exit 1; }

# ---------- 4/5 打包 ----------
echo "==> 4/5 打包"
mkdir -p "$DIST"
rm -f "$DMG"
# 用 diskutil image：hdiutil 在 macOS 26 起已废弃，每次都会打警告。
if ! OUT="$(diskutil image create from \
    --format UDZO \
    --volumeName "$APP_NAME $VERSION" \
    "$STAGE" "$DMG" 2>&1)"; then
    echo "$OUT" | tail -20
    exit 1
fi

# ---------- 5/5 挂载复验 ----------
echo "==> 5/5 挂载复验"
MNT="$(mktemp -d -t jietu-mnt)"
MNT_USED=0
cleanup_mnt() {
    [ "$MNT_USED" -eq 1 ] && diskutil eject "$MNT" > /dev/null 2>&1 || true
    rmdir "$MNT" 2>/dev/null || true
}
trap 'cleanup_mnt; rm -rf "$STAGE"' EXIT

if ! OUT="$(diskutil image attach --readOnly --nobrowse --mountPoint "$MNT" "$DMG" 2>&1)"; then
    echo "$OUT" | tail -20
    exit 1
fi
MNT_USED=1

[ -d "$MNT/$APP_NAME.app" ] || { echo "镜像里没有 $APP_NAME.app"; exit 1; }
[ -L "$MNT/Applications" ] || { echo "镜像里没有 Applications 软链"; exit 1; }
# 挂载后再验一次签名：能同时挡住「镜像损坏」和「拷贝过程改了文件」。
codesign --verify --deep --strict "$MNT/$APP_NAME.app" || { echo "镜像内签名校验不通过"; exit 1; }
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$MNT/$APP_NAME.app/Contents/Info.plist")"
[ "$INSTALLED_VERSION" = "$VERSION" ] || { echo "镜像内版本($INSTALLED_VERSION) 与构建($VERSION) 不一致"; exit 1; }

cleanup_mnt
MNT_USED=0

echo
echo "OK  $(pwd)/$DMG"
echo "    大小   $(du -h "$DMG" | cut -f1)"
echo "    sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "注：自签名证书未受系统信任，别人下载后首次打开需右键「打开」，"
echo "    或先执行 xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
