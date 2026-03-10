#!/bin/bash
# Koe (声) — ワンクリックインストーラー
# https://koe.elio.love
#
# Usage: curl -fsSL https://koe.elio.love/install.sh | bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}==>${NC} ${BOLD}$1${NC}"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; exit 1; }

echo ""
echo -e "${BOLD}  声 Koe — Mac で最も速い日本語音声入力${NC}"
echo -e "  whisper.cpp + Metal GPU · 完全ローカル · 無料"
echo ""

# --- Preflight checks ---
[[ "$(uname)" == "Darwin" ]] || fail "macOS 専用です (検出: $(uname))"

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  warn "Apple Silicon (M1以降) を推奨します (検出: $ARCH)"
fi

SW_VER="$(sw_vers -productVersion)"
MAJOR="${SW_VER%%.*}"
if [[ "$MAJOR" -lt 13 ]]; then
  fail "macOS 13 (Ventura) 以降が必要です (検出: macOS $SW_VER)"
fi
ok "macOS $SW_VER ($ARCH)"

# --- Step 1: whisper.cpp ---
info "whisper.cpp をチェック中..."
if command -v whisper-cpp &>/dev/null || command -v whisper-server &>/dev/null; then
  ok "whisper.cpp は既にインストール済み"
else
  if command -v brew &>/dev/null; then
    info "whisper.cpp をインストール中..."
    brew install whisper-cpp
    ok "whisper.cpp インストール完了"
  else
    warn "Homebrew が見つかりません。whisper.cpp を手動でインストールしてください:"
    echo "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    echo "    brew install whisper-cpp"
  fi
fi

# --- Step 2: Whisper model ---
# モデルはアプリ内で自動ダウンロード（デフォルト: Kotoba Whisper v2.0 日本語特化）
MODEL_DIR="$HOME/Library/Application Support/whisper"
MODEL_FILE="$MODEL_DIR/ggml-kotoba-whisper-v2.0-q5_0.bin"

info "音声認識モデルをチェック中..."
if [[ -f "$MODEL_FILE" ]]; then
  ok "モデルは既にダウンロード済み ($(du -h "$MODEL_FILE" | cut -f1))"
else
  info "Kotoba Whisper v2.0 (日本語特化) をダウンロード中 (~538MB)..."
  mkdir -p "$MODEL_DIR"
  curl -L --progress-bar \
    "https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/ggml-kotoba-whisper-v2.0-q5_0.bin" \
    -o "$MODEL_FILE"
  ok "モデルダウンロード完了 (アプリ内で他モデルにも切替可能)"
fi

# --- Step 3: Koe.app ---
info "Koe.app をインストール中..."
TMPDIR_SAFE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SAFE"' EXIT

RELEASE_URL="https://github.com/yukihamada/Koe-swift/releases/latest/download/Koe.app.zip"
curl -fSL --progress-bar -o "$TMPDIR_SAFE/Koe.zip" "$RELEASE_URL"
ok "ダウンロード完了"

unzip -qo "$TMPDIR_SAFE/Koe.zip" -d "$TMPDIR_SAFE"

# Find Koe.app (might be at root or inside a subdirectory)
KOE_APP="$(find "$TMPDIR_SAFE" -maxdepth 2 -name 'Koe.app' -type d | head -1)"
if [[ -z "$KOE_APP" ]]; then
  fail "Koe.app が ZIP 内に見つかりません"
fi

# Verify codesign if possible
if codesign -v "$KOE_APP" 2>/dev/null; then
  ok "コード署名を検証済み"
else
  warn "コード署名なし (開発版)"
fi

# Install to /Applications
if [[ -d "/Applications/Koe.app" ]]; then
  warn "既存の Koe.app を置き換えます"
  rm -rf "/Applications/Koe.app"
fi
mv "$KOE_APP" /Applications/
ok "Koe.app を /Applications にインストール完了"

# Remove quarantine attribute
xattr -dr com.apple.quarantine /Applications/Koe.app 2>/dev/null || true

echo ""
echo -e "${GREEN}${BOLD}  ✓ インストール完了！${NC}"
echo ""
echo "  起動方法:"
echo "    open /Applications/Koe.app"
echo ""
echo "  使い方:"
echo "    ⌥⌘V を押している間 → 録音"
echo "    話し終わると自動で変換・入力"
echo ""
echo -e "  初回起動時に${YELLOW}マイク${NC}と${YELLOW}アクセシビリティ${NC}の権限を許可してください"
echo ""

# --- Launch ---
read -rp "  今すぐ Koe を起動しますか? [Y/n] " answer
answer="${answer:-Y}"
if [[ "$answer" =~ ^[Yy]$ ]]; then
  open /Applications/Koe.app
  ok "Koe を起動しました"
fi

echo ""
echo -e "  ${CYAN}https://koe.elio.love${NC}"
echo ""
