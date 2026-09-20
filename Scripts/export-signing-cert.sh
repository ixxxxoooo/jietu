#!/usr/bin/env bash
#
# 把本机已有的「Jietu」代码签名身份导出成 CI 用的 .p12。
#
# 适用场景：证书早就在钥匙串里了（generate-signing-cert.sh 跑过，或手工建过），
# 只差把它塞进 GitHub Secrets。
#
# 用法：
#   bash Scripts/export-signing-cert.sh           # 写出文件
#   bash Scripts/export-signing-cert.sh --upload  # 写出并 gh secret set
#
# 产出（默认 ~/.config/jietu/，不进 git）：
#   jietu-signing.p12 / .password / .base64
#
# @author ygw
set -euo pipefail

IDENTITY_NAME="Jietu"
OUT_DIR="${JIETU_CERT_OUT_DIR:-$HOME/.config/jietu}"
UPLOAD=0
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=1 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "未知参数：$arg（可用 --upload）" >&2; exit 1 ;;
    esac
done

if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"${IDENTITY_NAME}\""; then
    echo "本机找不到代码签名身份「${IDENTITY_NAME}」。" >&2
    echo "若是全新机器，先跑：bash Scripts/generate-signing-cert.sh" >&2
    exit 1
fi

echo "==> 当前「${IDENTITY_NAME}」身份："
security find-identity -p codesigning 2>/dev/null | grep "\"${IDENTITY_NAME}\"" || true

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

TMP="$(mktemp -d -t jietu-export)"
trap 'rm -rf "$TMP"; security delete-keychain "$TMP/filter.keychain-db" 2>/dev/null || true' EXIT

P12_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
LOGIN_KC="$(security default-keychain | tr -d '" ')"

echo "==> 1/3 从默认钥匙串导出 identities"
# 登录串里可能还有别的自签名身份；下一步用临时钥匙串滤到只剩 Jietu。
security export -k "$LOGIN_KC" -t identities -f pkcs12 \
    -o "$TMP/all.p12" -P "$P12_PASSWORD"

FILTER_KC="$TMP/filter.keychain-db"
FILTER_PASS="$(openssl rand -base64 24)"
security create-keychain -p "$FILTER_PASS" "$FILTER_KC"
security set-keychain-settings -lut 3600 "$FILTER_KC"
security unlock-keychain -p "$FILTER_PASS" "$FILTER_KC"
security import "$TMP/all.p12" -k "$FILTER_KC" -P "$P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> 2/3 去掉非「${IDENTITY_NAME}」的身份"
# 列出临时串里所有名字，删掉不是 Jietu 的。
while IFS= read -r line; do
    name="$(printf '%s' "$line" | sed -n 's/.*"\(.*\)".*/\1/p')"
    [ -n "$name" ] || continue
    if [ "$name" != "$IDENTITY_NAME" ]; then
        echo "    删除 $name"
        security delete-certificate -c "$name" "$FILTER_KC" 2>/dev/null || true
    fi
done < <(security find-identity -p codesigning "$FILTER_KC" 2>/dev/null | grep '"')

COUNT="$(security find-identity -p codesigning "$FILTER_KC" 2>/dev/null | grep -c "\"${IDENTITY_NAME}\"" || true)"
if [ "$COUNT" -lt 1 ]; then
    echo "过滤后找不到「${IDENTITY_NAME}」，中止。" >&2
    exit 1
fi

echo "==> 3/3 写出只含「${IDENTITY_NAME}」的 p12"
security export -k "$FILTER_KC" -t identities -f pkcs12 \
    -o "$OUT_DIR/jietu-signing.p12" -P "$P12_PASSWORD"
printf '%s' "$P12_PASSWORD" > "$OUT_DIR/jietu-signing.p12.password"
base64 -i "$OUT_DIR/jietu-signing.p12" | tr -d '\n' > "$OUT_DIR/jietu-signing.p12.base64"
chmod 600 "$OUT_DIR/jietu-signing.p12" \
    "$OUT_DIR/jietu-signing.p12.password" \
    "$OUT_DIR/jietu-signing.p12.base64"

# 复验：导回另一个空串，确认只有 Jietu。
VERIFY_KC="$TMP/verify.keychain-db"
security create-keychain -p "$FILTER_PASS" "$VERIFY_KC"
security unlock-keychain -p "$FILTER_PASS" "$VERIFY_KC"
security import "$OUT_DIR/jietu-signing.p12" -k "$VERIFY_KC" -P "$P12_PASSWORD" >/dev/null
echo "    复验内容："
security find-identity -p codesigning "$VERIFY_KC" 2>/dev/null | grep '"' || true

if [ "$UPLOAD" = "1" ]; then
    echo "==> 上传到 GitHub Actions secrets"
    command -v gh >/dev/null || { echo "需要 gh CLI" >&2; exit 1; }
    gh secret set JIETU_CERT_P12_BASE64 < "$OUT_DIR/jietu-signing.p12.base64"
    gh secret set JIETU_CERT_P12_PASSWORD < "$OUT_DIR/jietu-signing.p12.password"
    echo "    已写入 JIETU_CERT_P12_BASE64 / JIETU_CERT_P12_PASSWORD"
    gh secret list
fi

echo ""
echo "完成。文件在 ${OUT_DIR}/（不要提交进 git）。"
if [ "$UPLOAD" != "1" ]; then
    cat <<EOF
未上传。配到 CI 请再跑：
  bash Scripts/export-signing-cert.sh --upload
或手动：
  gh secret set JIETU_CERT_P12_BASE64 < ${OUT_DIR}/jietu-signing.p12.base64
  gh secret set JIETU_CERT_P12_PASSWORD < ${OUT_DIR}/jietu-signing.p12.password
EOF
fi
