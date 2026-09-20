#!/usr/bin/env bash
#
# 生成「Jietu」自签名代码签名证书（连同私钥）。
#
# ⚠️  这是**一次性**操作。证书生成后：
#   · 指纹（leaf hash）会写进每个 Release 的 designated requirement；
#   · TCC（屏幕录制 / 辅助功能）按「bundle id + certificate leaf」认 App；
#   · 再生成一张新证书 = 换身份 = 用户升级后要重新授权。
#
# 所以：本机已经有「Jietu」身份时，本脚本**直接拒绝**，请改用
#   bash Scripts/export-signing-cert.sh
# 把现有证书导出给 CI。
#
# 用法：bash Scripts/generate-signing-cert.sh
#
# 产出（默认写到 ~/.config/jietu/，不进 git）：
#   jietu-signing.p12           证书 + 私钥
#   jietu-signing.p12.password  p12 密码
#   jietu-signing.p12.base64    给 GitHub Secret JIETU_CERT_P12_BASE64
#
# @author ygw
set -euo pipefail

IDENTITY_NAME="Jietu"
OUT_DIR="${JIETU_CERT_OUT_DIR:-$HOME/.config/jietu}"
DAYS="${JIETU_CERT_DAYS:-3650}"   # 默认 10 年
COMMON_NAME="$IDENTITY_NAME"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"${IDENTITY_NAME}\""; then
    echo "已经存在代码签名身份「${IDENTITY_NAME}」，拒绝重新生成。" >&2
    echo "" >&2
    echo "重新生成会换掉 certificate leaf，用户升级后屏幕录制授权会丢。" >&2
    echo "要把现有证书交给 CI，请跑：" >&2
    echo "  bash Scripts/export-signing-cert.sh" >&2
    echo "" >&2
    security find-identity -p codesigning 2>/dev/null | grep "\"${IDENTITY_NAME}\"" >&2 || true
    exit 1
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

TMP="$(mktemp -d -t jietu-cert)"
trap 'rm -rf "$TMP"' EXIT

P12_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
KEYCHAIN="$TMP/jietu-gen.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"

echo "==> 1/4 生成自签名证书（CN=${COMMON_NAME}，${DAYS} 天）"
# 专用临时钥匙串：避免污染 login，也方便只导出这一份身份。
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

# openssl 出一对密钥 + 自签证书，再导进钥匙串。
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$TMP/jietu.key" \
    -out "$TMP/jietu.csr" \
    -subj "/CN=${COMMON_NAME}/OU=Local/C=CN" \
    >/dev/null 2>&1

openssl x509 -req -days "$DAYS" \
    -in "$TMP/jietu.csr" \
    -signkey "$TMP/jietu.key" \
    -out "$TMP/jietu.crt" \
    -extfile <(printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n") \
    >/dev/null 2>&1

openssl pkcs12 -export \
    -inkey "$TMP/jietu.key" \
    -in "$TMP/jietu.crt" \
    -out "$TMP/jietu.p12" \
    -name "$IDENTITY_NAME" \
    -passout "pass:${P12_PASSWORD}" \
    >/dev/null 2>&1

echo "==> 2/4 导入登录钥匙串（本机 codesign / Xcode 要用）"
# 也放进 login，方便日常 Debug / 本地 Release。
LOGIN_KC="$(security default-keychain | tr -d '" ')"
security import "$TMP/jietu.p12" -k "$LOGIN_KC" -P "$P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# 允许 codesign 静默用私钥（否则每次构建弹「要使用钥匙串」）。
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$LOGIN_KC" >/dev/null 2>&1 || true

echo "==> 3/4 写出 p12 / 密码 / base64 → ${OUT_DIR}"
cp "$TMP/jietu.p12" "$OUT_DIR/jietu-signing.p12"
printf '%s' "$P12_PASSWORD" > "$OUT_DIR/jietu-signing.p12.password"
base64 -i "$OUT_DIR/jietu-signing.p12" | tr -d '\n' > "$OUT_DIR/jietu-signing.p12.base64"
chmod 600 "$OUT_DIR/jietu-signing.p12" \
    "$OUT_DIR/jietu-signing.p12.password" \
    "$OUT_DIR/jietu-signing.p12.base64"

FINGERPRINT="$(openssl x509 -in "$TMP/jietu.crt" -noout -fingerprint -sha1 | sed 's/^.*=//')"

echo "==> 4/4 校验"
security find-identity -p codesigning 2>/dev/null | grep "\"${IDENTITY_NAME}\"" \
    || { echo "导入后找不到「${IDENTITY_NAME}」" >&2; exit 1; }

cat <<EOF

完成。这张证书从现在起就是 Jietu 的长期签名身份，**不要再跑本脚本**。

  指纹（SHA-1）: ${FINGERPRINT}
  身份名称      : ${IDENTITY_NAME}
  文件目录      : ${OUT_DIR}/
    jietu-signing.p12
    jietu-signing.p12.password
    jietu-signing.p12.base64

下一步（一次性，配到 GitHub）：

  gh secret set JIETU_CERT_P12_BASE64 < ${OUT_DIR}/jietu-signing.p12.base64
  gh secret set JIETU_CERT_P12_PASSWORD < ${OUT_DIR}/jietu-signing.p12.password

或仓库网页：Settings → Secrets and variables → Actions → New repository secret

详见 AGENTS.md「发布」一节。
EOF
