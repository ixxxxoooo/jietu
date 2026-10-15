#!/usr/bin/env bash
#
# 发版一致性检查：工程里所有 MARKETING_VERSION、CHANGELOG 最新条目、（可选）git tag 必须是同一个版本号。
#
# 用法：
#   bash Scripts/check-release.sh          # 只检查工程版本与 CHANGELOG
#   bash Scripts/check-release.sh v0.0.5   # 同时核对 tag
#
# 成功时在最后一行输出版本号（供 CI 取用）；任何不一致都以非零退出。
set -euo pipefail
cd "$(dirname "$0")/.."

PBXPROJ="Jietu.xcodeproj/project.pbxproj"
CHANGELOG="CHANGELOG.md"

# 工程里每个 configuration 都有一份 MARKETING_VERSION，必须全部相同。
VERSIONS="$(grep -E '^\s*MARKETING_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([^;]+);.*/\1/' | sort -u)"
if [ -z "$VERSIONS" ]; then
    echo "error: $PBXPROJ 里找不到 MARKETING_VERSION" >&2
    exit 1
fi
if [ "$(printf '%s\n' "$VERSIONS" | wc -l | tr -d ' ')" -ne 1 ]; then
    echo "error: MARKETING_VERSION 不一致：" >&2
    printf '  %s\n' $VERSIONS >&2
    exit 1
fi
VERSION="$VERSIONS"

# CHANGELOG 最新（第一条）版本必须与工程一致。
LATEST="$(grep -m1 -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" | sed -E 's/^## \[([^]]+)\].*/\1/')"
if [ "$LATEST" != "$VERSION" ]; then
    echo "error: CHANGELOG 最新条目是 [$LATEST]，工程版本是 $VERSION" >&2
    exit 1
fi

if [ $# -ge 1 ]; then
    TAG="$1"
    if [ "${TAG#v}" != "$VERSION" ]; then
        echo "error: tag $TAG 与工程版本 $VERSION 不一致" >&2
        exit 1
    fi
fi

echo "$VERSION"
