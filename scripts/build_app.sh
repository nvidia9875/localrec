#!/usr/bin/env bash
# SwiftPM でビルドし、.app バンドルを手組みして署名する。
#
# 使い方:
#   ./scripts/build_app.sh            # release ビルド
#   CONFIG=debug ./scripts/build_app.sh
#
# 署名 ID は環境変数 CODESIGN_IDENTITY で差し替えられる。
# 既定は ad-hoc 署名 ("-")。リビルドの度に TCC (マイク等) の許可を
# 訊かれて煩わしくなったら scripts/sign_identity.sh で固定 ID を作る。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"

# 署名 ID を自動で選ぶ。
#
# ad-hoc 署名 ("-") だとリビルドの度に cdhash が変わり、macOS が「別のアプリ」と
# みなして TCC (マイク / 音声認識 / システムオーディオ録音) の許可を毎回訊き直す。
# 開発中はこれが非常に煩わしいので、安定した ID があればそちらを使う。
#
# 優先順:
#   1. 環境変数 CODESIGN_IDENTITY
#   2. scripts/sign_identity.sh で作った自己署名証明書
#   3. キーチェーンにある Apple Development 証明書（sudo 不要でそのまま使える）
#   4. ad-hoc
if [[ "$IDENTITY" == "-" ]]; then
  available="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if grep -q "AudioRec Dev" <<< "$available"; then
    IDENTITY="AudioRec Dev"
  else
    apple_dev="$(grep -o '"Apple Development: [^"]*"' <<< "$available" | head -1 | tr -d '"')"
    if [[ -n "$apple_dev" ]]; then
      IDENTITY="$apple_dev"
    fi
  fi
fi

APP_NAME="AudioRec"
BUILD_DIR="$ROOT/app/.build/$CONFIG"
DIST="$ROOT/dist"
BUNDLE="$DIST/$APP_NAME.app"

echo "[1/4] SwiftPM ビルド ($CONFIG)..."
swift build --package-path "$ROOT/app" -c "$CONFIG" --product "$APP_NAME"

BIN="$BUILD_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "エラー: 実行ファイルが見つかりません: $BIN" >&2
  exit 1
fi

echo "[2/4] .app バンドルを組み立て中..."
# 署名済みバンドルは差分更新すると署名が壊れるので毎回作り直す
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/app/Support/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# アイコン。コードから描き起こせるので、無ければその場で作る
ICON="$ROOT/app/Support/AudioRec.icns"
if [[ ! -f "$ICON" ]]; then
  echo "      アイコンが無いので生成します"
  (cd "$ROOT" && swift scripts/make_icon.swift)
fi
cp "$ICON" "$BUNDLE/Contents/Resources/AudioRec.icns"

# SwiftPM がリソースバンドルを吐いていれば取り込む
for rb in "$BUILD_DIR"/*.bundle; do
  [[ -e "$rb" ]] || continue
  cp -R "$rb" "$BUNDLE/Contents/Resources/"
done

echo "[3/4] 署名中 (identity: $IDENTITY)..."
codesign --force --deep \
  --sign "$IDENTITY" \
  --entitlements "$ROOT/app/Support/AudioRec.entitlements" \
  --timestamp=none \
  "$BUNDLE"

echo "[4/4] 署名を検証中..."
codesign --verify --verbose=2 "$BUNDLE" 2>&1 | sed 's/^/      /'

echo ""
echo "完成: $BUNDLE"
