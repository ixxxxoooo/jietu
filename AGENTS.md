# AGENTS.md

## 修改后必做的三步

每次改动代码后，按顺序完成：**重新构建 → 重启 App → 提交 git**。

```bash
# 1. 构建（产物固定落在 .build，勿用 DerivedData）
xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build build

# 2. 重启（先杀旧进程，再从 .build 启动新产物）
pkill -f "jietu/.build/Build/Products/Debug/Jietu.app"; sleep 1
open "/Users/liwenjiao/jietu/.build/Build/Products/Debug/Jietu.app"

# 3. 提交
git add -A && git commit -m "<type>: <描述>"
```

- 构建必须成功（`** BUILD SUCCEEDED **`）才能提交。
- 签名保持默认的自签名证书 `Jietu`，不要加 `CODE_SIGNING_ALLOWED=NO`，否则重签名会丢「屏幕录制」授权。
- 提交信息沿用仓库风格：`feat:` / `fix:` / `change:` / `docs:` 等前缀。
