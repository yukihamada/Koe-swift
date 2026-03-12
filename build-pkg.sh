#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="Koe.app"
PKG="Koe.pkg"
VERSION=$(defaults read "$(pwd)/$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.1")
IDENTIFIER="com.yuki.koe"
SIGN_ID="F1EFBA93D51A3F2204A9E25679E1D77BA22DC59C"

echo "==> Building Koe.app..."
bash build.sh --no-launch 2>/dev/null || true

echo "==> Creating installer package (v$VERSION)..."

# --- Prepare payload ---
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$STAGING/payload/Applications"
cp -R "$APP" "$STAGING/payload/Applications/"

# --- Preinstall script (kill running Koe) ---
mkdir -p "$STAGING/scripts"
cat > "$STAGING/scripts/preinstall" << 'SCRIPT'
#!/bin/bash
pkill -9 Koe 2>/dev/null || true
exit 0
SCRIPT

# --- Postinstall script (remove quarantine, launch) ---
cat > "$STAGING/scripts/postinstall" << 'SCRIPT'
#!/bin/bash
xattr -dr com.apple.quarantine /Applications/Koe.app 2>/dev/null || true
# Open after a short delay so the installer finishes cleanly
(sleep 2 && open /Applications/Koe.app) &
exit 0
SCRIPT

chmod +x "$STAGING/scripts/preinstall" "$STAGING/scripts/postinstall"

# --- Build component pkg ---
pkgbuild \
  --root "$STAGING/payload" \
  --scripts "$STAGING/scripts" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  "$STAGING/koe-component.pkg"

# --- Distribution XML for better installer UI ---
cat > "$STAGING/distribution.xml" << DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Koe (声) — 日本語音声入力</title>
    <welcome language="ja" mime-type="text/html"><![CDATA[
        <html><head><meta charset="utf-8"></head><body style="font-family:-apple-system,sans-serif;padding:20px">
        <h1 style="font-size:28px">声 Koe</h1>
        <p style="font-size:16px;color:#555">Mac で最も速い日本語音声入力</p>
        <br>
        <ul style="font-size:14px;color:#333;line-height:2">
            <li>whisper.cpp + Metal GPU で 0.5秒以内に認識</li>
            <li>完全ローカル — 音声データは一切クラウドへ送信しない</li>
            <li>ウェイクワード「ヘイこえ」でハンズフリー</li>
            <li>アプリ別プロファイルで最適化</li>
        </ul>
        <br>
        <p style="font-size:12px;color:#999">v${VERSION} · macOS 13+ · MIT License</p>
        </body></html>
    ]]></welcome>
    <conclusion language="ja" mime-type="text/html"><![CDATA[
        <html><head><meta charset="utf-8"></head><body style="font-family:-apple-system,sans-serif;padding:20px">
        <h1 style="font-size:28px">✓ インストール完了</h1>
        <p style="font-size:16px;color:#555">Koe が自動的に起動します。</p>

        <h2 style="font-size:18px;margin-top:24px;color:#333">初回セットアップ (2ステップ)</h2>
        <table style="font-size:14px;color:#333;border-collapse:collapse;margin-top:8px;width:100%">
            <tr style="border-bottom:1px solid #eee">
                <td style="padding:8px 0;width:30px;vertical-align:top;color:#ff3b30;font-weight:bold">1.</td>
                <td style="padding:8px 0"><strong>権限を許可</strong><br>
                    初回起動時にダイアログが表示されます:<br>
                    ・<strong>マイク</strong> → 「OK」(音声入力に必須)<br>
                    ・<strong>アクセシビリティ</strong> → システム設定で許可 (テキスト入力に必須)</td>
            </tr>
            <tr>
                <td style="padding:8px 0;vertical-align:top;color:#ff3b30;font-weight:bold">2.</td>
                <td style="padding:8px 0"><strong>音声認識モデル</strong><br>
                    初回起動時にダウンロードダイアログが表示されます (約1.5GB)。<br>
                    「ダウンロード」を押して完了を待つだけでOKです。</td>
            </tr>
        </table>

        <h2 style="font-size:18px;margin-top:24px;color:#333">使い方</h2>
        <table style="font-size:14px;color:#333;border-collapse:collapse;margin-top:8px;width:100%">
            <tr style="border-bottom:1px solid #eee">
                <td style="padding:6px 0;width:140px"><strong>⌥⌘V 長押し</strong></td>
                <td style="padding:6px 0">押している間だけ録音 → 離すと変換</td>
            </tr>
            <tr style="border-bottom:1px solid #eee">
                <td style="padding:6px 0"><strong>⌥⌘V 2回</strong></td>
                <td style="padding:6px 0">1回目で録音開始 → 2回目で変換 (トグル)</td>
            </tr>
            <tr style="border-bottom:1px solid #eee">
                <td style="padding:6px 0"><strong>「ヘイこえ」</strong></td>
                <td style="padding:6px 0">ウェイクワードで録音開始 (設定で有効化)</td>
            </tr>
            <tr>
                <td style="padding:6px 0"><strong>自動停止</strong></td>
                <td style="padding:6px 0">話し終わると0.85秒の無音で自動変換</td>
            </tr>
        </table>

        <p style="font-size:13px;color:#888;margin-top:20px">メニューバーの波形アイコン → 「設定…」から詳細設定を変更できます。</p>
        </body></html>
    ]]></conclusion>
    <options customize="never" require-scripts="false"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="Koe.app">
        <pkg-ref id="${IDENTIFIER}"/>
    </choice>
    <pkg-ref id="${IDENTIFIER}" version="${VERSION}" onConclusion="none">koe-component.pkg</pkg-ref>
    <os-version min="13.0"/>
</installer-gui-script>
DIST

# --- Build product pkg ---
productbuild \
  --distribution "$STAGING/distribution.xml" \
  --package-path "$STAGING" \
  "$STAGING/$PKG"

# --- Sign the pkg (requires Developer ID Installer cert) ---
INSTALLER_ID=$(security find-identity -v -p basic | grep "Developer ID Installer" | head -1 | awk -F'"' '{print $2}')
if [[ -n "$INSTALLER_ID" ]]; then
  productsign --sign "$INSTALLER_ID" "$STAGING/$PKG" "$PKG"
  echo "✓ Signed $PKG"
else
  cp "$STAGING/$PKG" "$PKG"
  echo "⚠ Unsigned $PKG (Developer ID Installer 証明書なし)"
fi

# --- Notarize ---
if xcrun notarytool history --keychain-profile "notary" >/dev/null 2>&1; then
  echo "==> Notarizing $PKG..."
  xcrun notarytool submit "$PKG" --keychain-profile "notary" --wait
  xcrun stapler staple "$PKG"
  echo "✓ Notarized $PKG"
else
  echo "⚠ Skipping notarization (run: xcrun notarytool store-credentials \"notary\")"
fi

echo ""
echo "✓ Created $PKG ($(du -h "$PKG" | cut -f1))"
echo "  → ダブルクリックでインストール"
echo "  → GitHub Releases にアップロードしてください"
