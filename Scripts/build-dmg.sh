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
#   Jietu.app                   主程序
#   Applications                软链，拖进去就是安装
#   安装说明.txt                  解隔离命令的**可复制**副本（背景图上的字选不中）
#   .background/                窗口背景图：安装说明直接画在图上
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
SLOT_APP="200,185"
SLOT_APPLICATIONS="460,185"
# 第三个槽位：安装说明。背景图上的命令是画出来的，选不中也复制不了，
# 所以那份命令必须再给一份真文件，用户打开就能全选复制。
SLOT_COMMAND="200,320"
COMMAND_FILE_NAME="安装说明.txt"
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
# 签名身份必须**稳定**，TCC（屏幕录制等）把授权记在 App 的代码签名身份上：
#   · 证书「Jietu」签名 → 要求是 `identifier + certificate leaf`，重装 / 升级都认同一份授权；
#   · ad-hoc 签名 → 要求退化成 `cdhash`（就是「这一个二进制」的指纹），
#     **每构建一次就换一个身份**，用户每次升级都得重新授权一遍——而且这时把 App
#     重拖进系统设置也没用，那一行早就在列表里了。
# 所以 ad-hoc 只能显式降级：设 JIETU_ALLOW_ADHOC=1（默认拒绝，见 2/6 的身份守门）。
#
# 检测证书时不带 -v：自签名证书通常是 CSSMERR_TP_NOT_TRUSTED（未受系统信任），
# 带 -v 只列「有效」证书会漏掉它，导致本地也退回 ad-hoc，签名身份变了 TCC 授权就丢了。
# 也不能用 CODE_SIGNING_ALLOWED=NO：产物没有签名身份，TCC 直接认不出来。
SIGN_OVERRIDES=""
if security find-identity -p codesigning 2>/dev/null | grep -q '"Jietu"'; then
    :
elif [ "${JIETU_ALLOW_ADHOC:-}" = "1" ]; then
    echo "    ⚠️  JIETU_ALLOW_ADHOC=1 → 改用 ad-hoc 签名"
    echo "        这份 DMG 的签名身份每次构建都会变，用户升级后要重新授权屏幕录制。"
    SIGN_OVERRIDES="CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Automatic"
else
    echo "找不到自签名证书「Jietu」，拒绝产出 ad-hoc 签名的 DMG：" >&2
    echo "  该签名的身份会随每次构建变化，用户升级一次就要重新授权一次屏幕录制。" >&2
    echo "  · CI：把证书导出成 .p12 配进仓库 secrets（见 AGENTS.md「发布」一节）" >&2
    echo "  · 本机：钥匙串登录项里应有「Jietu」证书（security find-identity -p codesigning）" >&2
    echo "  · 只想验打包流程：JIETU_ALLOW_ADHOC=1 bash Scripts/build-dmg.sh" >&2
    exit 1
fi
LOG="$(mktemp -t jietu-release)"
# $SIGN_OVERRIDES 故意不加引号：要把两条 build setting 拆成两个参数传给 xcodebuild。
# shellcheck disable=SC2086
if ! xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration "$CONFIG" \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" $SIGN_OVERRIDES build > "$LOG" 2>&1; then
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
SIGN_AUTHORITY="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
# 设计要求（designated requirement）＝ TCC 认 App 的那把「钥匙」。
# 带 certificate leaf 才是稳定身份；只剩 cdhash 就是 ad-hoc（每次构建都换）。
DESIGNATED_REQ="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
echo "    签名 ${SIGN_AUTHORITY:-ad-hoc}"
echo "    身份 ${DESIGNATED_REQ}"
case "$DESIGNATED_REQ" in
    *cdhash*)
        if [ "${JIETU_ALLOW_ADHOC:-}" = "1" ]; then
            echo "    ⚠️  身份是 cdhash（ad-hoc）：用户升级后要重新授权屏幕录制"
        else
            echo "身份是 cdhash（ad-hoc）：每次构建都换签名身份，用户升级后要重新授权屏幕录制" >&2
            echo "（真要用这份产物试打包，加 JIETU_ALLOW_ADHOC=1）" >&2
            exit 1
        fi
        ;;
    "") echo "取不到设计要求，拒绝继续：$APP" >&2; exit 1 ;;
esac

# ---------- 3/6 暂存 ----------
echo "==> 3/6 暂存"
TMP="$(mktemp -d -t jietu-dmg)"
STAGE="$TMP/stage"
RW="$TMP/Jietu-rw"
# 挂载点的最后一段就是 Finder 认的卷名，所以带上 pid 保证唯一——
# 重名时 Finder 会认到另一个同名卷（比如已经挂着的同名 DMG）上，版式就白排了。
MNT="$TMP/mnt-$$"
VERIFY_MNT="$TMP/verify"
MOUNTED=0
VERIFY_MOUNTED=0
cleanup() {
    [ "$VERIFY_MOUNTED" -eq 1 ] && detach_mount "$VERIFY_MNT" || true
    [ "$MOUNTED" -eq 1 ] && detach_mount "$MNT" || true
    rm -rf "$TMP"
}
trap cleanup EXIT

# ---------- 镜像工具 ----------
# macOS 26 起 hdiutil 已废弃（每次调用都警告），优先用 diskutil image；
# CI 的 macOS 15 runner 上还没有这个子命令，回退 hdiutil。
# 两条路都要留着：本地新系统走 diskutil，runner 走 hdiutil。
# 可用 JIETU_IMAGE_TOOL=diskutil|hdiutil 强制，便于在两种系统上验证同一条路径。
IMAGE_TOOL="${JIETU_IMAGE_TOOL:-}"
if [ -z "$IMAGE_TOOL" ]; then
    if diskutil image create blank --help > /dev/null 2>&1; then
        IMAGE_TOOL="diskutil"
    else
        IMAGE_TOOL="hdiutil"
    fi
fi
# ASIF（稀疏镜像）也是新系统才有；同样大小的逻辑卷，它落盘只有十几 MB。
RW_SUFFIX=".dmg"
RW_FORMAT="UDRW"
if [ "$IMAGE_TOOL" = "diskutil" ]; then
    RW_SUFFIX=".asif"
    RW_FORMAT="RAW"
    diskutil image create blank --help 2>&1 | grep -q ASIF && RW_FORMAT="ASIF"
fi
RW="$TMP/Jietu-rw$RW_SUFFIX"

# 最终镜像用 LZMA（ULMO）而不是 zlib（UDZO）：同样内容实测 4238KB → 3489KB（小 18%），
# 画面、版式、图标位置逐像素不变（比对过）。app 部署目标就是 macOS 26，
# 不存在「旧系统打不开 LZMA 镜像」的问题。
IMAGE_FORMAT="ULMO"

create_rw_image() {  # $1 路径  $2 卷名
    # 两边都用「从暂存目录建可写镜像」这一形式：
    # hdiutil 在 macOS 26 起不再接受「空白镜像 + -format」（要求 -format 必须配 -srcfolder），
    # 而带 -srcfolder 的老写法在新旧系统上都能用。
    if [ "$IMAGE_TOOL" = "diskutil" ]; then
        diskutil image create from "$STAGE" --volumeName "$2" --format "$RW_FORMAT" "$1" > /dev/null
    else
        hdiutil create -srcfolder "$STAGE" -volname "$2" -fs APFS -format UDRW -ov "$1" > /dev/null
    fi
}

attach_image() {  # $1 镜像  $2 挂载点  $3 只读(1/0)
    if [ "$IMAGE_TOOL" = "diskutil" ]; then
        if [ "$3" -eq 1 ]; then
            diskutil image attach --readOnly --nobrowse --mountPoint "$2" "$1" > /dev/null
        else
            # 不能加 --nobrowse：排版那步要让 Finder 看见这个卷。
            diskutil image attach --mountPoint "$2" "$1" > /dev/null
        fi
    else
        if [ "$3" -eq 1 ]; then
            hdiutil attach "$1" -readonly -nobrowse -mountpoint "$2" > /dev/null
        else
            hdiutil attach "$1" -nobrowse -mountpoint "$2" > /dev/null
        fi
    fi
}

detach_mount() {  # $1 挂载点
    diskutil eject "$1" > /dev/null 2>&1 || hdiutil detach "$1" > /dev/null 2>&1 || true
}

convert_image() {  # $1 源镜像  $2 目标  $3 卷名
    if [ "$IMAGE_TOOL" = "diskutil" ]; then
        diskutil image create from "$1" --format "$IMAGE_FORMAT" --volumeName "$3" "$2" > /dev/null
    else
        hdiutil convert "$1" -format "$IMAGE_FORMAT" -o "$2" > /dev/null
    fi
}

# Finder 能不能被脚本指挥：CI / 没有图形会话时拿不到自动化授权，
# 那种环境跳过版式（DMG 照样能用，只是回到系统默认版式），但要显眼地说出来。
FINDER_OK=0
osascript -e 'tell application "Finder" to get name of startup disk' > /dev/null 2>&1 && FINDER_OK=1

mkdir -p "$STAGE"
# ditto 比 cp -R 更能保真地带上资源分叉 / 扩展属性 / 权限位。
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# 预先清除主 App 上可能残留的隔离属性。构建产物通常不带，但用户曾手动
# 拷贝过、或 Xcode 偶尔从网络缓存恢复时可能沾上；装进 DMG 前清干净，
# 这样用户从 DMG 拖出来时自身不带隔离（DMG 外壳的隔离由用户用命令行移除）。
xattr -dr com.apple.quarantine "$STAGE/$APP_NAME.app" 2>/dev/null || true

# 安装说明：**背景图上的命令选不中也复制不了**（那是一片 PNG 像素），
# 所以同一份命令必须以真文件随镜像发一份，用户打开就能全选复制。
# 只有纯文本能这么干：`.command` / `.app` 从「下载来的 DMG」里第一次打开会被
# Gatekeeper 拦掉——「解隔离的小工具自己也被隔离」就是这么来的（已经踩过两次）。
# 内容保持最短：授权那套流程 App 自己的引导页会讲，这里只说「打开前做什么」。
cat > "$STAGE/$COMMAND_FILE_NAME" <<EOF
Jietu 首次打开前，把这行复制到「终端」回车（只需一次）：

xattr -dr com.apple.quarantine /Applications/$APP_NAME.app


它只去掉这个 App 上「从网上下载」的隔离标记。不做的话，第一次打开会被 Gatekeeper
拦住（提示「无法验证开发者」或「已损坏」）；右键 $APP_NAME.app →「打开」→ 再点
「打开」，效果一样。

Before the first launch, copy the line above into Terminal and run it once.
It only clears the "downloaded from the internet" quarantine flag; without it
Gatekeeper blocks the first launch. Right-click the app → Open → Open also works.
EOF

# 窗口背景图：安装说明画在上面（可复制的命令在上面那份 txt 里）。
echo "    渲染窗口背景图"
mkdir -p "$STAGE/.background"
swift Scripts/dmg-background.swift \
    --out "$STAGE/.background" \
    --size "${DMG_W}x${DMG_H}" \
    --bleed "${BLEED_X},${BLEED_Y}" \
    --app "$SLOT_APP" \
    --applications "$SLOT_APPLICATIONS" \
    --command "$SLOT_COMMAND" \
    --name "$APP_NAME" \
    --version "$VERSION" \
    --repo "$REPO_URL" \
    || { echo "背景图渲染失败"; exit 1; }

# 守门：背景图必须是「2 倍像素 + 144dpi + 不带 alpha」。前两条是为了清晰度——
# Finder 只加载被指定的这个 PNG，同目录的 background@2x.png 它不认，一旦退回 1x
# Retina 上字就会发虚（踩过一次）；第三条是因为画面整幅不透明，带 alpha 白占约 180KB。
ART_INFO="$(sips -g pixelWidth -g pixelHeight -g dpiWidth -g hasAlpha \
    "$STAGE/.background/background.png" 2>/dev/null)"
ART_PX_W="$(printf '%s\n' "$ART_INFO" | sed -n 's/.*pixelWidth: //p')"
ART_PX_H="$(printf '%s\n' "$ART_INFO" | sed -n 's/.*pixelHeight: //p')"
ART_DPI="$(printf '%s\n' "$ART_INFO" | sed -n 's/.*dpiWidth: //p')"
ART_ALPHA="$(printf '%s\n' "$ART_INFO" | sed -n 's/.*hasAlpha: //p')"
EXPECT_PX_W=$(( (DMG_W + BLEED_X) * 2 ))
EXPECT_PX_H=$(( (DMG_H + BLEED_Y) * 2 ))
if [ "$ART_PX_W" != "$EXPECT_PX_W" ] || [ "$ART_PX_H" != "$EXPECT_PX_H" ]; then
    echo "背景图像素尺寸是 ${ART_PX_W}x${ART_PX_H}，应为 ${EXPECT_PX_W}x${EXPECT_PX_H}（2 倍像素）"; exit 1
fi
case "$ART_DPI" in
    144*) ;;
    *) echo "背景图不是 144dpi（当前 ${ART_DPI}），Finder 会放大成 1x 画质"; exit 1 ;;
esac
[ "$ART_ALPHA" = "no" ] || { echo "背景图带 alpha 通道（白占约 180KB），应为 RGB"; exit 1; }

# ---------- 4/6 排版并入镜像 ----------
echo "==> 4/6 排版"
mkdir -p "$DIST" "$MNT"
rm -f "$DMG"
# 先建一个可写镜像：Finder 的版式只能写进可写的卷里，写完再转成压缩镜像。
# 内容在建镜像时就从暂存目录拷进去了，不用再 ditto 一遍。
echo "    镜像工具 ${IMAGE_TOOL}（${RW_FORMAT}）"
create_rw_image "$RW" "$VOLNAME" || { echo "创建可写镜像失败"; exit 1; }
attach_image "$RW" "$MNT" 0 || { echo "挂载可写镜像失败"; exit 1; }
MOUNTED=1
[ -d "$MNT/$APP_NAME.app" ] || { echo "可写镜像里没有 $APP_NAME.app"; exit 1; }
[ -L "$MNT/Applications" ] || { echo "可写镜像里没有 Applications 软链"; exit 1; }
[ -f "$MNT/$COMMAND_FILE_NAME" ] || { echo "可写镜像里没有 $COMMAND_FILE_NAME"; exit 1; }

# Finder 排版：背景图、窗口尺寸、图标位置都靠这一步落到 .DS_Store。
# Finder 写 .DS_Store 是异步的，偶尔要等一下才落盘，所以失败就重试几次。
if [ "$FINDER_OK" -eq 1 ]; then
    LAYOUT_LOG="$TMP/layout.log"
    LAYOUT_OK=0
    for attempt in 1 2 3; do
        if osascript Scripts/dmg-layout.applescript \
            "$(basename "$MNT")" "$VOLNAME" \
            "$DMG_W" "$DMG_H" "$TITLEBAR" "$ICON_SIZE" "$TEXT_SIZE" \
            "$COMMAND_FILE_NAME" \
            ${SLOT_APP//,/ } ${SLOT_APPLICATIONS//,/ } ${SLOT_COMMAND//,/ } \
            > "$LAYOUT_LOG" 2>&1 && [ -f "$MNT/.DS_Store" ]; then
            LAYOUT_OK=1
            break
        fi
        [ "$attempt" -lt 3 ] && { echo "    第 ${attempt} 次排版没落盘，重试…"; sleep 2; }
    done

    if [ "$LAYOUT_OK" -eq 1 ]; then
        echo "    版式已写入（$((DMG_W + BLEED_X))x$((DMG_H + BLEED_Y)) 出血，图标 ${ICON_SIZE}px）"
    else
        # Finder 明明可用却排不上：这是真 bug（比如卷名撞车把版式写到别的卷上），别放过去。
        echo "排版失败，最后一次的输出如下："
        sed -n '1,10p' "$LAYOUT_LOG" | sed 's/^/      /'
        exit 1
    fi
else
    # CI / 无图形会话：拿不到 Finder 自动化授权，版式只能降级，但不该拦住发布。
    echo "::warning::Finder 不可用（无图形会话或未授予自动化权限），跳过 DMG 窗口版式，本次用系统默认版式"
fi

sync
sleep 1
detach_mount "$MNT" || { echo "卸载可写镜像失败"; exit 1; }
MOUNTED=0

convert_image "$RW" "$DMG" "$VOLNAME" || { echo "转换压缩镜像失败"; exit 1; }
rm -f "$RW"

# ---------- 5/6 挂载复验 ----------
echo "==> 5/6 挂载复验"
mkdir -p "$VERIFY_MNT"
attach_image "$DMG" "$VERIFY_MNT" 1 || { echo "复验挂载失败：$DMG"; exit 1; }
VERIFY_MOUNTED=1

[ -d "$VERIFY_MNT/$APP_NAME.app" ] || { echo "镜像里没有 $APP_NAME.app"; exit 1; }
[ -L "$VERIFY_MNT/Applications" ] || { echo "镜像里没有 Applications 软链"; exit 1; }
# 可复制的命令必须真的在镜像里，否则用户只剩背景图上那行选不中的字。
[ -f "$VERIFY_MNT/$COMMAND_FILE_NAME" ] || { echo "镜像里没有 ${COMMAND_FILE_NAME}（可复制的安装命令）"; exit 1; }
# 老那份 txt 已经废弃（说明改画在背景图上），再出现就是这脚本漏改。
[ ! -e "$VERIFY_MNT/00-请先读我.txt" ] || { echo "镜像里还留着 00-请先读我.txt"; exit 1; }
[ -f "$VERIFY_MNT/.background/background.png" ] || { echo "镜像里没有窗口背景图"; exit 1; }
if [ "$FINDER_OK" -eq 1 ]; then
    [ -f "$VERIFY_MNT/.DS_Store" ] || { echo "镜像里没有 .DS_Store，版式会丢"; exit 1; }
fi
# 挂载后再验一次签名：能同时挡住「镜像损坏」和「拷贝过程改了文件」。
codesign --verify --deep --strict "$VERIFY_MNT/$APP_NAME.app" || { echo "镜像内签名校验不通过"; exit 1; }
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$VERIFY_MNT/$APP_NAME.app/Contents/Info.plist")"
[ "$INSTALLED_VERSION" = "$VERSION" ] || { echo "镜像内版本($INSTALLED_VERSION) 与构建($VERSION) 不一致"; exit 1; }

# 压缩格式退回 zlib 会白涨约 750KB，容易在改脚本时被顺手改回去，盯一下。
SHIPPED_FORMAT="$(hdiutil imageinfo "$DMG" 2>/dev/null | sed -n 's/^Format: //p' | head -1)"
[ "$SHIPPED_FORMAT" = "$IMAGE_FORMAT" ] \
    || { echo "镜像压缩格式是 ${SHIPPED_FORMAT}，应为 ${IMAGE_FORMAT}"; exit 1; }

detach_mount "$VERIFY_MNT"
VERIFY_MOUNTED=0

# ---------- 6/6 输出 ----------
echo
echo "==> 6/6 OK  $(pwd)/$DMG"
echo "    大小   $(du -h "$DMG" | cut -f1)"
echo "    sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "注：自签名证书未受系统信任，别人下载后首次打开前需在终端执行下面这条"
echo "    （镜像里的「${COMMAND_FILE_NAME}」也有一份，可直接复制）："
echo "    xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
