#!/usr/bin/env bash
# 自己署名のコード署名証明書を1回だけ作る。
#
# なぜ必要か:
#   ad-hoc 署名 ("-") だとリビルドの度に実行ファイルの cdhash が変わり、
#   macOS が「別のアプリ」とみなして TCC (マイク / 音声認識 / システム音声録音)
#   の許可を毎回訊いてくる。固定の署名 ID を使えばこれが起きなくなる。
#
# 使い方 (1回だけ):
#   ./scripts/sign_identity.sh
#   その後は:  CODESIGN_IDENTITY="AudioRec Dev" make build
#   あるいは:  echo 'export CODESIGN_IDENTITY="AudioRec Dev"' >> ~/.zshrc
#
# 途中で管理者パスワードの入力を求められる (証明書を信頼するため)。
set -euo pipefail

CN="${1:-AudioRec Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "証明書 '$CN' は既に存在します。"
  echo "次のように使ってください:  CODESIGN_IDENTITY=\"$CN\" make build"
  exit 0
fi

echo "[1/4] 自己署名証明書を生成中 (CN=$CN)..."
cat > "$WORK/cert.conf" <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3

[ dn ]
CN = $CN

[ v3 ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -config "$WORK/cert.conf" 2>/dev/null

openssl pkcs12 -export -legacy \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/cert.p12" -passout pass: 2>/dev/null

echo "[2/4] キーチェーンに取り込み中..."
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "" \
  -T /usr/bin/codesign -T /usr/bin/security

echo "[3/4] コード署名用に信頼設定中 (管理者パスワードを求められます)..."
sudo security add-trusted-cert -d -r trustRoot \
  -p codeSign -k /Library/Keychains/System.keychain "$WORK/cert.pem"

echo "[4/4] codesign から鍵を使えるように許可中..."
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo ""
echo "完了。これ以降は次のようにビルドしてください:"
echo "  CODESIGN_IDENTITY=\"$CN\" make build"
