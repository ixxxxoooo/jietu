#!/usr/bin/env bash
#
# 构建 Release 渠道 → 校验签名 → 排好 DMG 窗口版式 → 打成可直接分发的 DMG。
#
# 与 `restart-dev.sh` 的分工：那条跑 Debug（开发渠道，Jietu Dev.app），
# 这条跑 Release（正式渠道，Jietu.app，通用二进制），产物落在 dist/。
#
# 用法：bash Scripts/build-dmg.sh
#
# 输出：dist/Jietu-<版本>.dmg，里面是
#   Jietu.app            主程序
#   Applications         软链，拖进去就是安装
#   Fix Gatekeeper.app   解除隔离的小工具（首次打开被 Gatekeeper 拦时用）
#   .background/         窗口背景图：安装说明直接画在图上
#
# 窗口版式（背景图 + 图标位置）由 dmg-background.swift 出图、
# dmg-layout.applescript 摆位，几何只在下面的「DMG 版式」一节里写一次。
#
# @author ixxxxoooo
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Jietu"
CONFIG="Release"
DERIVED=".build"
APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
DIST="dist"
REPO_URL="github.com/ixxxxoooo/jietu"

# ---------- DMG 版式 ----------
# 内容区尺寸 = 背景图的设计稿尺寸；槽位坐标是图标中心（设计稿左上角为原点）。
DMG_W=660
DMG_H=420
SLOT_APP="200,170"
SLOT_APPLICATIONS="460,170"
SLOT_HELPER="200,310"
ICON_SIZE=100
TEXT_SIZE=12
# Finder 窗口的 bounds 含标题栏，想要内容区高 DMG_H 就得多给这一截。
TITLEBAR=32
# 背景图的出血：Finder 从 .DS_Store 恢复窗口时内容区会略大一圈，
# 画满就不会在右边 / 下边露白边。
BLEED_X=16
BLEED_Y=12

# ---------- 1/6 构建 ----------
echo "==> 1/6 构建（${CONFIG}）"
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

# ---------- 2/6 校验产物 ----------
echo "==> 2/6 校验签名与版本"
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
VOLNAME="$APP_NAME $VERSION"
echo "    版本 $VERSION ($BUILD)  标识 $BUNDLE_ID"
echo "    架构 $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
echo "    签名 $(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

# ---------- 3/6 暂存 ----------
echo "==> 3/6 暂存"
TMP="$(mktemp -d -t jietu-dmg)"
STAGE="$TMP/stage"
RW="$TMP/Jietu-rw.asif"
# 挂载点的最后一段就是 Finder 认的卷名，所以带上 pid 保证唯一——
# 重名时 Finder 会认到另一个同名卷（比如已经挂着的同名 DMG）上，版式就白排了。
MNT="$TMP/mnt-$$"
VERIFY_MNT="$TMP/verify"
MOUNTED=0
VERIFY_MOUNTED=0
cleanup() {
    [ "$VERIFY_MOUNTED" -eq 1 ] && diskutil eject "$VERIFY_MNT" > /dev/null 2>&1 || true
    [ "$MOUNTED" -eq 1 ] && diskutil eject "$MNT" > /dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$STAGE"
# ditto 比 cp -R 更能保真地带上资源分叉 / 扩展属性 / 权限位。
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# 解除隔离的小工具：从网上下载的 DMG 里，任何可执行文件（.command / .app）第一次
# 都会被 Gatekeeper 拦截——这正是「解除隔离」工具自己也打不开的原因。
# 正确用法是：右键 → 打开（与打开自签名 Jietu.app 同一套流程），说明就画在背景图上。
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
osacompile -o "$HELPER_APP" "$HELPER_SCRIPT"
rm -f "$HELPER_SCRIPT"
# 与主 App 同一自签名身份，用户对证书信任后体验更一致。
codesign --force --sign "Jietu" --timestamp=none "$HELPER_APP" 2>/dev/null \
	|| codesign --force --sign - "$HELPER_APP"
[ -d "$HELPER_APP" ] || { echo "未能生成 Fix Gatekeeper.app"; exit 1; }

# 窗口背景图：安装说明（原来那份 00-请先读我.txt）画在上面。
echo "    渲染窗口背景图"
mkdir -p "$STAGE/.background"
swift Scripts/dmg-background.swift \
    --out "$STAGE/.background" \
    --size "${DMG_W}x${DMG_H}" \
    --bleed "${BLEED_X},${BLEED_Y}" \
    --app "$SLOT_APP" \
    --applications "$SLOT_APPLICATIONS" \
    --helper "$SLOT_HELPER" \
    --name "$APP_NAME" \
    --version "$VERSION" \
    --repo "$REPO_URL" \
    || { echo "背景图渲染失败"; exit 1; }

# 守门：背景图必须是「2 倍像素 + 144dpi」。Finder 只加载被指定的这个 PNG，
# 同目录的 background@2x.png 它不认——一旦退回 1x，Retina 上字就会发虚（踩过一次）。
ART_INFO="$(sips -g pixelWidth -g pixelHeight -g dpiWidth "$STAGE/.background/background.png" 2>/dev/null)"
ART_PX_W="$(printf '%s\n' "$ART_INFO" | sed -n 's/.*pixelWidth: //p')"
ART_PX_H="$(printf '%s\n' "$ART_INFO" | sed -n 's/.*pixelHeight: //p')"
ART_DPI="$(printf '%s\n' "$ART_INFO" | sed -n 's/.*dpiWidth: //p')"
EXPECT_PX_W=$(( (DMG_W + BLEED_X) * 2 ))
EXPECT_PX_H=$(( (DMG_H + BLEED_Y) * 2 ))
if [ "$ART_PX_W" != "$EXPECT_PX_W" ] || [ "$ART_PX_H" != "$EXPECT_PX_H" ]; then
    echo "背景图像素尺寸是 ${ART_PX_W}x${ART_PX_H}，应为 ${EXPECT_PX_W}x${EXPECT_PX_H}（2 倍像素）"; exit 1
fi
case "$ART_DPI" in
    144*) ;;
    *) echo "背景图不是 144dpi（当前 ${ART_DPI}），Finder 会放大成 1x 画质"; exit 1 ;;
esac

# ---------- 4/6 排版并入镜像 ----------
echo "==> 4/6 排版"
mkdir -p "$DIST" "$MNT"
rm -f "$DMG"
# 先建一个可写镜像：Finder 的版式只能写进可写的卷里，写完再转成压缩镜像。
# 用 ASIF（稀疏镜像）而不是 RAW——同样 200MB 的逻辑大小，落盘只有十几 MB。
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 64 ))
diskutil image create blank --size "${SIZE_MB}m" --fs APFS \
    --volumeName "$VOLNAME" --format ASIF "$RW" > /dev/null \
    || { echo "创建可写镜像失败"; exit 1; }
diskutil image attach --mountPoint "$MNT" "$RW" > /dev/null || { echo "挂载可写镜像失败"; exit 1; }
MOUNTED=1

ditto "$STAGE/." "$MNT/"

# Finder 排版：背景图、窗口尺寸、图标位置都靠这一步落到 .DS_Store。
# Finder 写 .DS_Store 是异步的，偶尔要等一下才落盘，所以失败就重试几次。
LAYOUT_LOG="$TMP/layout.log"
LAYOUT_OK=0
for attempt in 1 2 3; do
    if osascript Scripts/dmg-layout.applescript \
        "$(basename "$MNT")" "$VOLNAME" \
        "$DMG_W" "$DMG_H" "$TITLEBAR" "$ICON_SIZE" "$TEXT_SIZE" \
        ${SLOT_APP//,/ } ${SLOT_APPLICATIONS//,/ } ${SLOT_HELPER//,/ } \
        > "$LAYOUT_LOG" 2>&1 && [ -f "$MNT/.DS_Store" ]; then
        LAYOUT_OK=1
        break
    fi
    [ "$attempt" -lt 3 ] && { echo "    第 ${attempt} 次排版没落盘，重试…"; sleep 2; }
done

if [ "$LAYOUT_OK" -eq 1 ]; then
    echo "    版式已写入（$((DMG_W + BLEED_X))x$((DMG_H + BLEED_Y)) 出血，图标 ${ICON_SIZE}px）"
else
    # 没有 .DS_Store 的版本体验差很多（图标堆在左上角、没有背景图），不当成小毛病放过。
    echo "排版失败，最后一次的输出如下："
    sed -n '1,10p' "$LAYOUT_LOG" | sed 's/^/      /'
    exit 1
fi

sync
sleep 1
diskutil eject "$MNT" > /dev/null || { echo "卸载可写镜像失败"; exit 1; }
MOUNTED=0

diskutil image create from "$RW" --format UDZO --volumeName "$VOLNAME" "$DMG" > /dev/null \
    || { echo "转换压缩镜像失败"; exit 1; }
rm -f "$RW"

# ---------- 5/6 挂载复验 ----------
echo "==> 5/6 挂载复验"
mkdir -p "$VERIFY_MNT"
diskutil image attach --readOnly --nobrowse --mountPoint "$VERIFY_MNT" "$DMG" > /dev/null \
    || { echo "复验挂载失败：$DMG"; exit 1; }
VERIFY_MOUNTED=1

[ -d "$VERIFY_MNT/$APP_NAME.app" ] || { echo "镜像里没有 $APP_NAME.app"; exit 1; }
[ -L "$VERIFY_MNT/Applications" ] || { echo "镜像里没有 Applications 软链"; exit 1; }
# 安装说明已经画进背景图，那份 txt 不该再出现——出现了就是这脚本漏改。
[ ! -e "$VERIFY_MNT/00-请先读我.txt" ] || { echo "镜像里还留着 00-请先读我.txt"; exit 1; }
[ -f "$VERIFY_MNT/.background/background.png" ] || { echo "镜像里没有窗口背景图"; exit 1; }
[ -f "$VERIFY_MNT/.DS_Store" ] || { echo "镜像里没有 .DS_Store，版式会丢"; exit 1; }
# 挂载后再验一次签名：能同时挡住「镜像损坏」和「拷贝过程改了文件」。
codesign --verify --deep --strict "$VERIFY_MNT/$APP_NAME.app" || { echo "镜像内签名校验不通过"; exit 1; }
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$VERIFY_MNT/$APP_NAME.app/Contents/Info.plist")"
[ "$INSTALLED_VERSION" = "$VERSION" ] || { echo "镜像内版本($INSTALLED_VERSION) 与构建($VERSION) 不一致"; exit 1; }

diskutil eject "$VERIFY_MNT" > /dev/null || true
VERIFY_MOUNTED=0

# ---------- 6/6 输出 ----------
echo
echo "==> 6/6 OK  $(pwd)/$DMG"
echo "    大小   $(du -h "$DMG" | cut -f1)"
echo "    sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "注：自签名证书未受系统信任，别人下载后首次打开需右键「打开」，"
echo "    或先执行 xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
