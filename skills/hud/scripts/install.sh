#!/usr/bin/env bash
# hud 스킬 설치: 두 statusline 스크립트 배치 + settings.json statusLine 병합 + 동작 확인.
# 기존 스크립트가 있고 내용이 다르면 diff 를 경고로 stderr에 출력한 뒤 덮어쓴다.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${CLAUDE_HUD_DEST:-$HOME/.claude}"

command -v jq >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 || {
  echo "jq/bash 가 필요합니다." >&2
  exit 1
}

mkdir -p "$DEST"
for f in statusline-command.sh statusline-tokens.sh; do
  if [ -f "$DEST/$f" ] && ! diff -q "$SRC/$f" "$DEST/$f" >/dev/null 2>&1; then
    echo "경고: 기존 $DEST/$f 를 아래 내용으로 덮어씁니다:" >&2
    diff -u "$DEST/$f" "$SRC/$f" >&2 || true
  fi
done

cp "$SRC/statusline-command.sh" "$DEST/statusline-command.sh"
cp "$SRC/statusline-tokens.sh" "$DEST/statusline-tokens.sh"
chmod +x "$DEST/statusline-command.sh" "$DEST/statusline-tokens.sh"

SETTINGS="$DEST/settings.json"
[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
if jq '.statusLine = {"type":"command","command":"bash ~/.claude/statusline-command.sh"}' "$SETTINGS" >"$TMP"; then
  mv "$TMP" "$SETTINGS"
else
  echo "settings.json 병합 실패 (원본 보존됨)" >&2
  exit 2
fi

echo '{"model":{"display_name":"Sonnet 5"},"cwd":"'"$HOME"'","context_window":{"used_percentage":12}}' | bash "$DEST/statusline-command.sh"
echo
