# Koe (声) — 音声入力アプリ

## 技術スタック
- **macOS**: Swift (Koe-macOS.xcodeproj) + whisper.cpp Metal GPU
- **Windows**: Windows向けビルド (Koe-windows/)
- **iOS**: 別ターゲット (Koe-iOS/)
- **サイト**: koe.elio.love (site/ ディレクトリ)
- **CI/CD**: release.sh + fastlane (TestFlight / GitHub Releases)

## 主要コマンド
```bash
./build.sh         # macOS ビルド
./build-pkg.sh     # Installer PKG 生成
./build-dmg.sh     # DMG 生成
./release.sh       # リリース (GitHub Releases push)
```

## 重要 gotcha
- **ad-hoc署名でTCC毎回リセット**: rebuild → /Applications に install するたびにマイク/アクセシビリティ権限が失効する。同じ署名済みアプリに replace install が必要 → `feedback_adhoc_signed_app_tcc.md` 参照
- **Kotoba Whisper v2.0**: 初回起動時に自動DL。ローカルモデルパス変更注意
- **arm64 llama.cpp**: Metal ビルドフラグ必須 → `feedback_arm64_llama_cpp_build.md` 参照
- **デプロイ**: 明示指示なしにリリースしない (`release.sh` は GitHub push を行う)

## セキュリティ
- 音声データはクラウドに送らない (ローカル完結)
- APIキー (LLM後処理用) は設定ファイルに保持、コードにハードコード禁止
