-- 把 DMG 窗口排成设计稿的样子：定尺寸、关掉工具栏、铺背景图、按坐标摆图标。
--
-- 几何全部由 build-dmg.sh 传入，与 dmg-background.swift 画出来的画面同源——
-- 改位置只改 build-dmg.sh 一处。
--
-- 两个 Finder 的坑：
-- 1. 卷名按「挂载点最后一段」认，而不是卷名（--mountPoint 挂上来的卷，
--    Finder 认的名字是挂载点末段）；重名时 Finder 会认到别的卷上（比如已经挂着的
--    同名 DMG），所以要求候选名在 Finder 里只对应一个卷，否则不认。
-- 2. 窗口 bounds 含标题栏：想要内容区高 H，bounds 的高得给 H + 标题栏。
--
-- 用法：osascript Scripts/dmg-layout.applescript \
--         <卷名> <备用卷名> <内容宽> <内容高> <标题栏高> <图标尺寸> <文字尺寸> \
--         <appX> <appY> <applicationsX> <applicationsY>
--       第一个名字优先（build-dmg.sh 传的是唯一的挂载点末段），第二个是卷名兜底。
--
-- @author ixxxxoooo
on run argv
	if (count of argv) < 11 then error "参数不足：需要 卷名×2 内容尺寸 标题栏高 图标与文字尺寸 及两个槽位坐标"

	set volName to item 1 of argv
	set altName to item 2 of argv
	set contentW to (item 3 of argv) as integer
	set contentH to (item 4 of argv) as integer
	set titleBar to (item 5 of argv) as integer
	set iconSize to (item 6 of argv) as integer
	set textSize to (item 7 of argv) as integer
	set appPos to {(item 8 of argv) as integer, (item 9 of argv) as integer}
	set appsPos to {(item 10 of argv) as integer, (item 11 of argv) as integer}

	set diskName to ""
	tell application "Finder" to set existingNames to name of every disk
	repeat with candidate in {volName, altName}
		set hits to 0
		repeat with existing in existingNames
			if (existing as text) is (candidate as text) then set hits to hits + 1
		end repeat
		if hits is 1 then
			set diskName to candidate as text
			exit repeat
		end if
	end repeat
	if diskName is "" then error "Finder 里没有唯一匹配的卷：" & volName & " / " & altName

	-- 屏幕居中偏上：比正中更符合视觉重心。
	set originX to 200
	set originY to 160
	tell application "Finder"
		try
			set {dl, dt, dr, db} to bounds of window of desktop
			set originX to dl + (((dr - dl) - contentW) div 2)
			set originY to dt + (((db - dt) - contentH) div 3)
		end try
	end tell

	tell application "Finder"
		tell disk diskName
			open
			delay 0.6
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set the bounds of container window to {originX, originY, originX + contentW, originY + contentH + titleBar}
			set viewOptions to the icon view options of container window
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to iconSize
			set text size of viewOptions to textSize
			set label position of viewOptions to bottom
			set shows icon preview of viewOptions to true
			-- 背景图放在卷内的隐藏目录里，随镜像一起分发。
			set background picture of viewOptions to file ".background:background.png"
			set position of item "Jietu.app" of container window to appPos
			set position of item "Applications" of container window to appsPos
			update without registering applications
			delay 1
			close container window
		end tell
	end tell
end run
