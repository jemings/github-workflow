#!/usr/bin/env bash
# scripts/install.sh 의 통합 테스트 — 실제 ~/.claude 는 건드리지 않고
# CLAUDE_HUD_DEST 로 mktemp 디렉터리에 격리해 실행한다.
#
# 실행:
#   bash skills/hud/scripts/test-install.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${SCRIPT_DIR}/install.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_zero() {
  local desc="$1" actual="$2"
  if [[ "$actual" == 0 ]]; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "$desc"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc")
    printf '  ❌ %s — expected rc=0, got %s\n' "$desc" "$actual"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "$desc"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc")
    printf '  ❌ %s — expected %s, got %s\n' "$desc" "$expected" "$actual"
  fi
}

DEST="$(mktemp -d)"
trap 'rm -rf "$DEST"' EXIT

# 최초 설치: 파일 배치 + settings.json 생성 + 샘플 렌더 성공.
CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" >/dev/null
assert_zero "최초 설치 exit=0" $?
assert_zero "statusline-command.sh 배치됨" "$([ -x "$DEST/statusline-command.sh" ]; echo $?)"
assert_zero "statusline-tokens.sh 배치됨" "$([ -x "$DEST/statusline-tokens.sh" ]; echo $?)"
assert_eq "settings.json 에 statusLine 등록" "bash ~/.claude/statusline-command.sh" \
  "$(jq -r '.statusLine.command' "$DEST/settings.json")"

# 기존 settings.json 필드는 보존.
echo '{"theme":"dark","hooks":{"x":1}}' >"$DEST/settings.json"
CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" >/dev/null
assert_eq "기존 theme 보존" "dark" "$(jq -r '.theme' "$DEST/settings.json")"
assert_eq "기존 hooks 보존" "1" "$(jq -r '.hooks.x' "$DEST/settings.json")"

# 재실행(파일 동일) — idempotent, exit=0.
CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" >/dev/null
assert_zero "재실행 idempotent" $?

# 기존 스크립트가 달라도 경고(stderr diff) 후 덮어씀 — 차단하지 않음.
echo 'echo custom' >"$DEST/statusline-command.sh"
STDERR_OUT="$(CLAUDE_HUD_DEST="$DEST" bash "$INSTALL" 2>&1 1>/dev/null)"
assert_zero "커스터마이즈 있어도 설치 exit=0" $?
assert_zero "덮어쓴 후 원본과 동일" "$(diff -q "$DEST/statusline-command.sh" "$SCRIPT_DIR/statusline-command.sh" >/dev/null; echo $?)"
assert_zero "덮어쓸 때 경고 출력" "$([[ "$STDERR_OUT" == *"경고"* ]]; echo $?)"

echo ""
echo "── 결과 ───────────────────────────────────────────────────"
echo "  통과: $PASS / 실패: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  printf '\n실패한 테스트:\n'
  for t in "${FAILED_TESTS[@]}"; do
    printf '  - %s\n' "$t"
  done
  exit 1
fi
