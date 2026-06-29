#!/usr/bin/env bash
# scripts/shgwt.sh 의 단위/통합 테스트 (#110).
#
# 실행:
#   bash scripts/test-shgwt.sh
#
# 단위 — shgwt.sh 를 source 해서 헬퍼 함수만 검증.
# 통합 — mktemp 로 origin.git(bare) + work(clone) 픽스처를 만들고
#         spawn → teardown 흐름을 끝까지 돌려본다.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHGWT="${SCRIPT_DIR}/shgwt.sh"

# shellcheck source=./shgwt.sh
source "${SHGWT}"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_zero() {
  local desc="$1" actual="$2"
  if [[ "$actual" == 0 ]]; then
    PASS=$((PASS + 1))
    printf '  ✅ %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$desc")
    printf '  ❌ %s — expected rc=0, got %s\n' "$desc" "$actual"
  fi
}

assert_nonzero() {
  local desc="$1" actual="$2"
  if [[ "$actual" != 0 ]]; then
    PASS=$((PASS + 1))
    printf '  ✅ %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$desc")
    printf '  ❌ %s — expected non-zero, got 0\n' "$desc"
  fi
}

assert_true() {
  local desc="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
    printf '  ✅ %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$desc")
    printf '  ❌ %s\n' "$desc"
  fi
}

# ───── 단위: shgwt_validate_name ─────────────────────────────────
echo "── shgwt_validate_name ────────────────────────────────────"

shgwt_validate_name "issue-110" >/dev/null 2>&1; assert_zero "유효 이름 'issue-110'" $?
shgwt_validate_name "feature_x" >/dev/null 2>&1; assert_zero "유효 이름 'feature_x'" $?
shgwt_validate_name "" >/dev/null 2>&1; assert_nonzero "빈 이름 거부" $?
shgwt_validate_name "-leading" >/dev/null 2>&1; assert_nonzero "선행 '-' 거부" $?
shgwt_validate_name "with/slash" >/dev/null 2>&1; assert_nonzero "'/' 포함 거부" $?
shgwt_validate_name "with space" >/dev/null 2>&1; assert_nonzero "공백 포함 거부" $?
shgwt_validate_name "issue"     >/dev/null 2>&1; assert_nonzero "예약어 'issue' 거부" $?

# ───── 통합 픽스처 ─────────────────────────────────────────────────
setup_fixture() {
  local root="$1"
  mkdir -p "${root}/origin.git" "${root}/work"
  ( cd "${root}/origin.git" && git init --bare -q --initial-branch=main )
  (
    cd "${root}/work" || exit 1
    git init -q --initial-branch=main
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "hello" > README.md
    git add README.md
    git commit -q -m "init"
    git remote add origin "${root}/origin.git"
    git push -q -u origin main
  )
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

setup_fixture "$TMPROOT"
WORK="${TMPROOT}/work"

run_in() {
  local dir="$1"; shift
  ( cd "$dir" && "$@" )
}

run_shgwt_in() {
  local dir="$1"; shift
  ( cd "$dir" && bash "$SHGWT" "$@" >/dev/null 2>&1 )
}

# ───── spawn ──────────────────────────────────────────────────────
echo ""
echo "── 통합: spawn ────────────────────────────────────────────"

run_shgwt_in "$WORK" spawn issue-1; assert_zero "spawn issue-1" $?
assert_true "워크트리 .claude/worktrees/issue-1-1 존재" test -d "$WORK/.claude/worktrees/issue-1-1"
assert_true "브랜치 wt/issue-1/1 존재" \
  bash -c "cd '$WORK' && git rev-parse --verify --quiet wt/issue-1/1 >/dev/null"

run_shgwt_in "$WORK" spawn issue-1; assert_zero "spawn issue-1 두 번째 실행" $?
assert_true "워크트리 .claude/worktrees/issue-1-2 존재 (인덱스 증가)" test -d "$WORK/.claude/worktrees/issue-1-2"

run_shgwt_in "$WORK/.claude/worktrees/issue-1-1" spawn issue-2
assert_nonzero "워크트리 안에서 spawn 거부" $?

run_shgwt_in "$WORK" spawn "bad/name"; assert_nonzero "잘못된 이름 ('/') 거부" $?
run_shgwt_in "$WORK" spawn ""; assert_nonzero "빈 이름 거부" $?

# ───── teardown ───────────────────────────────────────────────────
echo ""
echo "── 통합: teardown ─────────────────────────────────────────"

# 깨끗한 워크트리는 teardown 통과
run_shgwt_in "$WORK/.claude/worktrees/issue-1-2" teardown; assert_zero "깨끗한 워크트리 teardown" $?
assert_true ".claude/worktrees/issue-1-2 제거됨" bash -c "[[ ! -d '$WORK/.claude/worktrees/issue-1-2' ]]"
assert_true "wt/issue-1/2 브랜치 삭제됨" \
  bash -c "cd '$WORK' && ! git rev-parse --verify --quiet wt/issue-1/2 >/dev/null 2>&1"

# 미커밋 변경 → 거부
echo "uncommitted" > "$WORK/.claude/worktrees/issue-1-1/dirty.txt"
run_shgwt_in "$WORK/.claude/worktrees/issue-1-1" teardown
assert_nonzero "미커밋 변경 시 teardown 거부" $?

# --force 로 무시
run_shgwt_in "$WORK/.claude/worktrees/issue-1-1" teardown --force; assert_zero "--force teardown" $?
assert_true "강제 teardown 후 .claude/worktrees/issue-1-1 제거됨" \
  bash -c "[[ ! -d '$WORK/.claude/worktrees/issue-1-1' ]]"

# 메인 레포에서 teardown → 거부
run_shgwt_in "$WORK" teardown
assert_nonzero "메인 레포에서 teardown 거부" $?

# 미푸시 커밋 → 거부
run_shgwt_in "$WORK" spawn issue-9
(
  cd "$WORK/.claude/worktrees/issue-9-1" || exit 1
  echo "new" > new.txt
  git add new.txt
  git -c user.email=t@e.com -c user.name=T commit -q -m "unpushed"
)
run_shgwt_in "$WORK/.claude/worktrees/issue-9-1" teardown
assert_nonzero "미푸시 커밋 시 teardown 거부" $?

# --force 로 미푸시 폐기
run_shgwt_in "$WORK/.claude/worktrees/issue-9-1" teardown --force; assert_zero "미푸시 + --force teardown" $?

# --keep-branch
run_shgwt_in "$WORK" spawn issue-keep
run_shgwt_in "$WORK/.claude/worktrees/issue-keep-1" teardown --keep-branch
assert_zero "--keep-branch teardown" $?
assert_true "--keep-branch 후 wt/issue-keep/1 보존" \
  bash -c "cd '$WORK' && git rev-parse --verify --quiet wt/issue-keep/1 >/dev/null"

# 보호 브랜치 자기 보호: detached HEAD 워크트리(branch == "HEAD")는 거부.
# main/master 도 동일 case 로 묶여 있어 본 케이스로 회귀 방지를 대체한다.
# (실제 사용에서는 spawn 이 항상 wt/<name>/<N> 분기를 만들어 발생하지 않지만,
# 보호 분기 로직 자체는 검증해야 함.)
git -C "$WORK" worktree add --detach "$WORK/.claude/worktrees/detached" >/dev/null 2>&1
run_shgwt_in "$WORK/.claude/worktrees/detached" teardown
assert_nonzero "detached HEAD 워크트리 teardown 거부 (보호 브랜치)" $?
git -C "$WORK" worktree remove --force "$WORK/.claude/worktrees/detached" 2>/dev/null || true

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
