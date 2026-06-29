#!/usr/bin/env bash
# scripts/github-workflow.sh의 순수 함수 단위 테스트.
#
# 실행:
#   bash scripts/test-github-workflow.sh
#
# gh API에 의존하지 않는 헬퍼만 검증한다 (claude-issue-slug, claude-session-bound).
# Project 보드와 GitHub 호출이 필요한 함수는 통합 환경에서 수동으로 검증한다.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

# 보드 설정 픽스처 — 제네릭화 후 owner/number 는 소스 시 빈 값이므로, 모든 테스트가
# _claude-require-project-config 가드를 통과하도록 소스 직후 고정한다.
# gh API 호출은 _claude-gh-retry stub 으로 가로채므로 값 자체는 임의 fixture 다.
CLAUDE_PROJECT_OWNER="${CLAUDE_PROJECT_OWNER:-example-org}"
CLAUDE_PROJECT_NUMBER="${CLAUDE_PROJECT_NUMBER:-10}"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf '  ✅ %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '  ❌ %s\n     expected: %q\n     actual:   %q\n' "$desc" "$expected" "$actual"
  fi
}

echo "── claude-issue-slug ──────────────────────────────────────"

# 회귀 방지: 영문 제목은 기존 동작을 그대로 유지한다.
assert_eq "ASCII 제목" \
  "docs-setup-readme" \
  "$(claude-issue-slug 'docs: setup readme')"

assert_eq "콜론과 대문자 처리" \
  "feat-add-new-feature" \
  "$(claude-issue-slug 'Feat: Add New Feature')"

# 이슈 #9 핵심 케이스: 한글이 섞이면 트레일링 하이픈이 남던 문제.
assert_eq "한영 혼합 제목 — 트레일링 하이픈 제거" \
  "chore-wsl-gh-cli" \
  "$(claude-issue-slug 'chore: WSL용 gh CLI 설치')"

assert_eq "한글 단어 사이 다중 하이픈 압축" \
  "fix" \
  "$(claude-issue-slug 'fix: 한글만 있는 제목')"

# 한글 전용 제목 → 빈 슬러그. 호출자(claude-start-issue)가 'issue-N'으로 폴백한다.
assert_eq "한글 전용 제목 → 빈 슬러그" \
  "" \
  "$(claude-issue-slug '한글로만 작성된 제목')"

assert_eq "이모지 전용 제목 → 빈 슬러그" \
  "" \
  "$(claude-issue-slug '🚀 ✨ 🎉')"

# 40자 경계: head -c가 하이픈 위치에서 잘리지 않도록 트레일링 하이픈을 한 번 더 제거.
assert_eq "40자 초과 — 트레일링 하이픈 없이 잘림" \
  "abcdef-ghijkl-mnopqr-stuvwx-yzaaaa-bbbbb" \
  "$(claude-issue-slug 'abcdef ghijkl mnopqr stuvwx yzaaaa bbbbb cccccc')"

# #89: 40번째 문자가 '-'인 케이스 — ${slug%-} 제거 로직을 실제로 트리거.
assert_eq "40번째 문자가 하이픈 — 트레일링 하이픈 제거" \
  "abcdef-ghijkl-mnopqr-stuvwx-yzaaaa-bbbb" \
  "$(claude-issue-slug 'abcdef ghijkl mnopqr stuvwx yzaaaa bbbb cccccc')"

assert_eq "선행 공백/특수문자 — 리딩 하이픈 제거" \
  "hello-world" \
  "$(claude-issue-slug '   :::hello world')"

echo ""
echo "── claude-session-bound 정규식 ────────────────────────────"

# 정규식만 분리해서 검증. 실제 git 호출은 하지 않는다.
match_branch() {
  local b="$1"
  if [[ "$b" =~ ^issue-([0-9]+)(-|$) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "NO_MATCH"
  fi
}

assert_eq "issue-9-foo → 9" "9" "$(match_branch 'issue-9-foo')"
assert_eq "issue-42 (트레일링 하이픈 없음) → 42" "42" "$(match_branch 'issue-42')"
assert_eq "issue-9- (트레일링 하이픈만) → 9" "9" "$(match_branch 'issue-9-')"
assert_eq "main → NO_MATCH" "NO_MATCH" "$(match_branch 'main')"
assert_eq "feature-issue-9 → NO_MATCH" "NO_MATCH" "$(match_branch 'feature-issue-9')"
assert_eq "issue-abc → NO_MATCH" "NO_MATCH" "$(match_branch 'issue-abc')"

echo ""
echo "── _claude-gh-retry ───────────────────────────────────────"

# sleep은 실제 대기 없이 통과시켜 테스트 런타임을 유지한다.
# _claude-gh-retry 내부의 sleep 호출은 함수 해석 시점이 아니라 실행 시점에
# lookup되므로 여기서 함수로 override하면 바로 반영된다.
sleep() { :; }

# 호출 카운트 파일. 3개 경로에서 공유되므로 각 경로 시작에 0으로 초기화한다.
MOCK_COUNT_FILE=$(mktemp)
export MOCK_COUNT_FILE

_mock_always_succeed() {
  printf 'immediate-success'
}

_mock_fail_then_succeed() {
  local count
  count=$(cat "$MOCK_COUNT_FILE" 2>/dev/null || echo 0)
  count=$((count + 1))
  echo "$count" > "$MOCK_COUNT_FILE"
  if (( count < 2 )); then
    echo "transient failure" >&2
    return 1
  fi
  printf 'recovered-output'
}

_mock_always_fail() {
  echo "permanent failure" >&2
  return 1
}

# 1) 첫 시도 성공 — stdout 전달, return 0.
out=$(_claude-gh-retry _mock_always_succeed 2>/dev/null)
rc=$?
assert_eq "첫 시도 성공 — stdout 전달" "immediate-success" "$out"
assert_eq "첫 시도 성공 — return 0" "0" "$rc"

# 2) 1회 실패 후 성공 — 재시도 후 최종 stdout 전달.
echo 0 > "$MOCK_COUNT_FILE"
out=$(_claude-gh-retry _mock_fail_then_succeed 2>/dev/null)
rc=$?
assert_eq "재시도 후 성공 — stdout 전달" "recovered-output" "$out"
assert_eq "재시도 후 성공 — return 0" "0" "$rc"
assert_eq "재시도 후 성공 — 호출 횟수 2" "2" "$(cat "$MOCK_COUNT_FILE")"

# 3) 3회 모두 실패 — non-zero 반환, stdout은 비어 있어야 한다.
out=$(_claude-gh-retry _mock_always_fail 2>/dev/null)
rc=$?
assert_eq "최종 실패 — stdout 비어 있음" "" "$out"
# rc는 mock의 종료 코드(1) 또는 그 이상의 non-zero. 정확히 1인지 확인해 회귀 감지.
assert_eq "최종 실패 — return 1" "1" "$rc"

# 4) #630 회귀 가드 — sleep에 빈 인자가 전달되지 않는지 검증.
#    zsh 사용자가 source하면 array 1-indexed로 인해 `delays[0]`이 빈 문자열로
#    조회돼 `sleep ""`이 호출되며 `sleep: invalid time interval ''` 가 노출됐다.
#    case 문으로 우회한 fix가 양 셸에서 모두 정수 delay를 사용하는지 확인한다.
unset -f sleep
SLEEP_ARGS_FILE=$(mktemp)
export SLEEP_ARGS_FILE
sleep() { printf '%s\n' "$1" >>"$SLEEP_ARGS_FILE"; }
out=$(_claude-gh-retry _mock_always_fail 2>/dev/null)
# max_attempts=3 → attempt 1·2 에서 sleep, attempt 3 후엔 sleep 없음 → 2회.
assert_eq "#630 — sleep 호출 횟수 (max_attempts-1)" "2" "$(wc -l <"$SLEEP_ARGS_FILE" | tr -d ' ')"
assert_eq "#630 — sleep 인자 모두 정수 (빈 문자열 회귀 가드)" "2 5" "$(tr '\n' ' ' <"$SLEEP_ARGS_FILE" | sed 's/ $//')"
rm -f "$SLEEP_ARGS_FILE"
unset SLEEP_ARGS_FILE

rm -f "$MOCK_COUNT_FILE"
unset -f sleep

echo ""
echo "── claude-set-issue-status / claude-set-pr-status 라우팅 ──"

# wrapper들이 _claude-content-node-id에 올바른 type(issues|pulls)을 넘기고,
# 그 결과를 claude-set-content-status에 올바른 label과 함께 위임하는지 검증.
# #34의 Issue·PR 독립 트랙 정책에서 가장 회귀 위험이 큰 인터페이스 지점이다.
_claude-content-node-id() {
  printf 'mock-node-%s-%s\n' "$1" "$2"
}
claude-set-content-status() {
  printf 'node=%s status=%s label=%s\n' "$1" "$2" "$3"
}
# #645 CLOSED 가드가 forward-only 상태에서 gh issue view --json state 를 호출하므로
# 라우팅 테스트도 _claude-gh-retry 를 mock 해야 한다. 기본은 OPEN 반환.
_claude-gh-retry() {
  case "$*" in
    *"gh issue view"*"--json state"*) printf 'OPEN\n' ;;
    *) "$@" ;;
  esac
}

assert_eq "claude-set-issue-status → issues 경로 + #N label" \
  "node=mock-node-issues-34 status=In progress label=#34" \
  "$(claude-set-issue-status 34 'In progress')"

assert_eq "claude-set-pr-status → pulls 경로 + PR #N label" \
  "node=mock-node-pulls-113 status=In review label=PR #113" \
  "$(claude-set-pr-status 113 'In review')"

unset -f _claude-gh-retry

echo ""
echo "── #645: claude-set-issue-status CLOSED 가드 ─────────────"

# Fix 2 가드 — 닫힌 이슈가 Ready/Backlog/In progress (forward-only) 로 회귀하지 못하게
# fail-closed 차단한다. Done 은 정상 close 경로이므로 통과해야 한다.
# 라우팅 mock(_claude-content-node-id / claude-set-content-status) 재사용.

# #645 가드는 #671 forward-only 보드 가드 보다 먼저 실행되지만, OPEN 경로(Case 5) 는
# #671 가드까지 도달한다. 그 케이스가 실제 GraphQL 을 타지 않도록 헬퍼를 stub 한다
# (기본: 보드 미등록 = 빈 문자열 = 가드 미트리거).
_claude-current-board-status() {
  printf ''
  return 0
}

_claude-gh-retry() {
  case "$*" in
    *"gh issue view"*"--json state"*) printf 'CLOSED\n' ;;
    *) "$@" ;;
  esac
}

# Case 1: CLOSED + 'Ready' → 차단 + return 1.
out=$(claude-set-issue-status 607 'Ready' 2>&1)
rc=$?
assert_eq "#645 — CLOSED + Ready → return 1 (fail-closed)" "1" "$rc"
case "$out" in
  *"이미 CLOSED"*"Ready"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — Ready 차단 메시지 (회귀 가드)";;
  *)                         FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "Ready 차단 메시지 누락" "$out";;
esac
case "$out" in
  *"node=mock-node-issues-607"*) FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "차단 시 라우팅 미진입해야 함" "$out";;
  *)                              PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — CLOSED 차단 시 라우팅 미진입";;
esac

# Case 2: CLOSED + 'Backlog' → 동일 차단.
out=$(claude-set-issue-status 608 'Backlog' 2>&1)
rc=$?
assert_eq "#645 — CLOSED + Backlog → return 1" "1" "$rc"
case "$out" in
  *"이미 CLOSED"*"Backlog"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — Backlog 차단 메시지";;
  *)                           FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "Backlog 차단 메시지 누락" "$out";;
esac

# Case 3: CLOSED + 'In progress' → 동일 차단.
out=$(claude-set-issue-status 609 'In progress' 2>&1)
rc=$?
assert_eq "#645 — CLOSED + In progress → return 1" "1" "$rc"
case "$out" in
  *"이미 CLOSED"*"In progress"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — In progress 차단 메시지";;
  *)                                FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "In progress 차단 메시지 누락" "$out";;
esac

# Case 4: CLOSED + 'Done' → 가드 미트리거 (정상 close 경로) → 라우팅 진입.
out=$(claude-set-issue-status 610 'Done' 2>&1)
rc=$?
assert_eq "#645 — CLOSED + Done → return 0 (가드 미트리거)" "0" "$rc"
case "$out" in
  *"node=mock-node-issues-610 status=Done label=#610"*)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — Done 은 CLOSED 라도 통과";;
  *)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "Done 통과 실패" "$out";;
esac

# Case 5: OPEN + 'Ready' → 정상 통과 → 라우팅 진입.
_claude-gh-retry() {
  case "$*" in
    *"gh issue view"*"--json state"*) printf 'OPEN\n' ;;
    *) "$@" ;;
  esac
}
out=$(claude-set-issue-status 611 'Ready' 2>&1)
rc=$?
assert_eq "#645 — OPEN + Ready → return 0" "0" "$rc"
case "$out" in
  *"node=mock-node-issues-611 status=Ready label=#611"*)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — OPEN 은 forward-only 상태 통과";;
  *)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "OPEN Ready 라우팅 실패" "$out";;
esac

# Case 6: state 조회 실패 (네트워크/권한) + forward-only → fail-closed.
_claude-gh-retry() {
  case "$*" in
    *"gh issue view"*"--json state"*) return 1 ;;
    *) "$@" ;;
  esac
}
out=$(claude-set-issue-status 612 'In progress' 2>&1)
rc=$?
assert_eq "#645 — state 조회 실패 + forward-only → return 1 (fail-closed)" "1" "$rc"
case "$out" in
  *"state 조회 실패"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — 조회 실패 메시지 포함";;
  *)                    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "조회 실패 메시지 누락" "$out";;
esac

# Case 7: state 조회 자체가 'Done' 에서는 트리거되지 않아야 한다 (불필요한 API 호출 방지).
_claude-gh-retry() {
  case "$*" in
    *"gh issue view"*"--json state"*)
      echo "GUARD_LEAKED: gh issue view state should not run for Done" >&2
      return 1
      ;;
    *) "$@" ;;
  esac
}
out=$(claude-set-issue-status 613 'Done' 2>&1)
rc=$?
assert_eq "#645 — Done 은 state 조회 미트리거" "0" "$rc"
case "$out" in
  *"GUARD_LEAKED"*) FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "Done 에서 state 조회됨 (불필요)" "$out";;
  *)                 PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — Done 분기는 state 조회 미트리거";;
esac

unset -f _claude-gh-retry _claude-current-board-status

echo ""
echo "── #671: claude-set-issue-status forward-only 보드 가드 ────────"

# Fix 1 가드 — OPEN 이슈가 이미 보드 forward 단계(In progress/In review/Approved/Done)
# 에 있을 때 Ready/Backlog 로의 backward 호출을 fail-closed 차단. #627 회귀 trigger.
# 라우팅 mock(_claude-content-node-id / claude-set-content-status) 재사용.
# state 조회는 OPEN 으로 고정해 #645 가드는 통과시킨 뒤 #671 가드만 검증한다.

_claude-gh-retry() {
  case "$*" in
    *"gh issue view"*"--json state"*) printf 'OPEN\n' ;;
    *) "$@" ;;
  esac
}

# Mock 가능한 단일 helper — 실제 GraphQL 경로 대신 이 함수를 오버라이드.
_BOARD_STATUS=""
_claude-current-board-status() {
  printf '%s' "$_BOARD_STATUS"
}

# Case 1: Ready × 현재 보드 = In progress → return 1.
_BOARD_STATUS="In progress"
out=$(claude-set-issue-status 627 'Ready' 2>&1)
rc=$?
assert_eq "#671 — Ready × In progress → return 1 (fail-closed)" "1" "$rc"
case "$out" in
  *"In progress"*"Ready"*"backward"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — Ready × In progress 차단 메시지";;
  *)                                    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "차단 메시지 누락" "$out";;
esac
case "$out" in
  *"node=mock-node-issues-627"*) FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "차단 시 라우팅 미진입해야 함" "$out";;
  *)                              PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — 차단 시 라우팅 미진입";;
esac

# Case 2: Ready × 현재 보드 = In review → return 1.
_BOARD_STATUS="In review"
out=$(claude-set-issue-status 627 'Ready' 2>&1)
rc=$?
assert_eq "#671 — Ready × In review → return 1" "1" "$rc"
case "$out" in
  *"In review"*"Ready"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — Ready × In review 차단 메시지";;
  *)                      FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "차단 메시지 누락" "$out";;
esac

# Case 3: Ready × 현재 보드 = Approved → return 1.
_BOARD_STATUS="Approved"
out=$(claude-set-issue-status 627 'Ready' 2>&1)
rc=$?
assert_eq "#671 — Ready × Approved → return 1" "1" "$rc"
case "$out" in
  *"Approved"*"Ready"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — Ready × Approved 차단 메시지";;
  *)                     FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "차단 메시지 누락" "$out";;
esac

# Case 3b: Ready × 현재 보드 = Done → return 1 (Done 도 forward 단계).
_BOARD_STATUS="Done"
out=$(claude-set-issue-status 627 'Ready' 2>&1)
rc=$?
assert_eq "#671 — Ready × Done → return 1" "1" "$rc"
case "$out" in
  *"Done"*"Ready"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — Ready × Done 차단 메시지";;
  *)                 FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "차단 메시지 누락" "$out";;
esac

# Case 3c: Backlog × 현재 보드 = In progress → return 1 (Backlog 도 backward 대상).
_BOARD_STATUS="In progress"
out=$(claude-set-issue-status 627 'Backlog' 2>&1)
rc=$?
assert_eq "#671 — Backlog × In progress → return 1" "1" "$rc"
case "$out" in
  *"In progress"*"Backlog"*"backward"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — Backlog × In progress 차단 메시지";;
  *)                                      FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "차단 메시지 누락" "$out";;
esac

# Case 4: Done × 현재 보드 = In progress → 가드 미트리거 (Done 은 정상 close 경로).
_BOARD_STATUS="In progress"
out=$(claude-set-issue-status 627 'Done' 2>&1)
rc=$?
assert_eq "#671 — Done × In progress → return 0 (가드 미트리거)" "0" "$rc"
case "$out" in
  *"node=mock-node-issues-627 status=Done label=#627"*)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — Done 은 forward-only 가드 미트리거";;
  *)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "Done 통과 실패" "$out";;
esac

# Case 5: In progress × 현재 보드 = Backlog → 가드 미트리거 (정상 forward).
_BOARD_STATUS="Backlog"
out=$(claude-set-issue-status 627 'In progress' 2>&1)
rc=$?
assert_eq "#671 — In progress × Backlog → return 0 (정상 forward)" "0" "$rc"
case "$out" in
  *"node=mock-node-issues-627 status=In progress label=#627"*)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — In progress 는 forward-only 가드 미트리거";;
  *)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "In progress forward 실패" "$out";;
esac

# Case 5b: Ready × 현재 보드 = Ready → 가드 미트리거 (멱등 통과).
_BOARD_STATUS="Ready"
out=$(claude-set-issue-status 627 'Ready' 2>&1)
rc=$?
assert_eq "#671 — Ready × Ready → return 0 (멱등 통과)" "0" "$rc"
case "$out" in
  *"node=mock-node-issues-627 status=Ready label=#627"*)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — 같은 상태로의 호출은 멱등 통과";;
  *)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "Ready 멱등 라우팅 실패" "$out";;
esac

# Case 5c: Ready × 현재 보드 = "" (보드 카드 미등록) → 가드 미트리거 (신규 이슈 케이스).
_BOARD_STATUS=""
out=$(claude-set-issue-status 627 'Ready' 2>&1)
rc=$?
assert_eq "#671 — Ready × empty board → return 0 (신규 이슈)" "0" "$rc"
case "$out" in
  *"node=mock-node-issues-627 status=Ready label=#627"*)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — 보드 카드 미등록 시 라우팅 통과";;
  *)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "신규 이슈 Ready 라우팅 실패" "$out";;
esac

# Case 6: 보드 status 조회 실패 (Ready/Backlog 타깃) → fail-closed (return 1).
_claude-current-board-status() {
  return 1
}
out=$(claude-set-issue-status 627 'Ready' 2>&1)
rc=$?
assert_eq "#671 — 보드 조회 실패 + Ready → return 1 (fail-closed)" "1" "$rc"
case "$out" in
  *"보드 status 조회 실패"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — 조회 실패 메시지 포함";;
  *)                          FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "조회 실패 메시지 누락" "$out";;
esac

# Case 7: 보드 status 조회는 'In progress' / 'Done' 타깃에서는 트리거되지 않아야 한다
#         (#671 가드는 Ready/Backlog 타깃 전용).
_claude-current-board-status() {
  echo "GUARD_LEAKED: _claude-current-board-status should not run for In progress" >&2
  return 1
}
out=$(claude-set-issue-status 627 'In progress' 2>&1)
rc=$?
assert_eq "#671 — In progress 타깃은 보드 조회 미트리거" "0" "$rc"
case "$out" in
  *"GUARD_LEAKED"*) FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "In progress 에서 보드 조회됨 (불필요)" "$out";;
  *)                 PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — In progress 타깃은 #671 가드 미트리거";;
esac

unset -f _claude-gh-retry _claude-current-board-status
unset _BOARD_STATUS

echo ""
echo "── #1289: _claude-reconcile-issue-status-on-close 보정 path ──"

# claude-close-issue 가 PR 생성 직후 호출하는 fallback 보정 헬퍼. 우회 진입(main 에서
# git checkout -b issue-<N>)·부분 fail 후 수동 재완료로 이슈가 Backlog/Ready 에 머문 채
# PR 만 In review 가 된 정책 위반을 정렬한다. forward-only 회귀 가드:
#   (1) Backlog/Ready 에서만 보정이 발화하고
#   (2) mutation 타깃은 항상 "In progress" (backward 타깃으로 내보내지 않음)
#   (3) forward 단계(In progress 이상)·미등록 카드·조회 실패에서는 mutation 미발화.
# set/verify 를 레코더로 mock 해 실제 보드 호출 대신 인자만 캡처한다. 두 함수는
# 실제 구현이라 이어지는 라우팅 테스트(L662 등)가 진짜 함수를 호출한다 — 전체
# re-source 는 위 라우팅 mock(_claude-content-node-id)을 깨므로, 이 블록이 클로버한
# 두 함수만 declare -f 로 보존했다가 끝에서 복원한다.
_RECON_REAL_SET=$(declare -f claude-set-issue-status)
_RECON_REAL_VERIFY=$(declare -f claude-verify-issue-status)
claude-set-issue-status() { printf 'SET:%s:%s\n' "$1" "$2"; }
claude-verify-issue-status() { printf 'VERIFY:%s:%s\n' "$1" "$2"; }
_RECON_BOARD=""
_claude-current-board-status() { printf '%s' "$_RECON_BOARD"; }

# Case 1: 현재 보드 = Ready → In progress 보정 발화 (mutation 타깃 = In progress).
_RECON_BOARD="Ready"
out=$(_claude-reconcile-issue-status-on-close 1289 2>&1)
rc=$?
assert_eq "#1289 — Ready → return 0" "0" "$rc"
case "$out" in
  *"SET:1289:In progress"*"VERIFY:1289:In progress"*)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#1289 — Ready 보정: set+verify 타깃 In progress";;
  *)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "Ready 보정 set/verify 누락" "$out";;
esac
case "$out" in
  *"이슈 #1289 Ready → In progress 보정 (PR 생성 시점 자동 정렬)"*)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#1289 — Ready 보정 알림 메시지 (AC3)";;
  *)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "Ready 보정 알림 메시지 누락" "$out";;
esac

# Case 2: 현재 보드 = Backlog → In progress 보정 발화 + backward 타깃 금지 가드.
_RECON_BOARD="Backlog"
out=$(_claude-reconcile-issue-status-on-close 1289 2>&1)
case "$out" in
  *"SET:1289:In progress"*)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#1289 — Backlog 보정: mutation 타깃 In progress";;
  *)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "Backlog 보정 mutation 누락" "$out";;
esac
case "$out" in
  *"SET:1289:Backlog"* | *"SET:1289:Ready"*)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "보정이 backward 타깃으로 mutation (forward-only 위반)" "$out";;
  *)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#1289 — 보정 mutation 은 backward(Ready/Backlog) 타깃 아님";;
esac

# Case 3~6: forward 단계(In progress/In review/Approved/Done) → mutation 미발화 (회귀 금지).
for st in "In progress" "In review" "Approved" "Done"; do
  _RECON_BOARD="$st"
  out=$(_claude-reconcile-issue-status-on-close 1289 2>&1)
  case "$out" in
    *SET:* | *VERIFY:*)
      FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "#1289 — ${st} 에서 mutation 발화 (forward-only 위반)" "$out";;
    *)
      PASS=$((PASS + 1)); printf '  ✅ %s\n' "#1289 — ${st} 는 보정 미발화 (forward-only)";;
  esac
done

# Case 7: 보드 카드 미등록(빈 문자열) → mutation 미발화 (신규/미등록 케이스).
_RECON_BOARD=""
out=$(_claude-reconcile-issue-status-on-close 1289 2>&1)
case "$out" in
  *SET:* | *VERIFY:*)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "미등록 카드에서 mutation 발화" "$out";;
  *)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#1289 — 보드 카드 미등록은 보정 미발화";;
esac

# Case 8: 보드 status 조회 실패 → soft skip (return 0, mutation 미발화).
_claude-current-board-status() { return 1; }
out=$(_claude-reconcile-issue-status-on-close 1289 2>&1)
rc=$?
assert_eq "#1289 — 보드 조회 실패 → return 0 (soft skip, PR 성공 미파괴)" "0" "$rc"
case "$out" in
  *SET:* | *VERIFY:*)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "조회 실패 시 mutation 발화 (best-effort 위반)" "$out";;
  *"보드 status 조회 실패"*)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#1289 — 조회 실패 soft skip 메시지";;
  *)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "조회 실패 메시지 누락" "$out";;
esac

# mock 제거 + 실제 구현 복원 — 이어지는 라우팅 테스트가 진짜 함수를 호출해야 한다.
# _claude-current-board-status 는 이 블록 진입 시점에도 unset(#671 블록 끝에서 제거)
# 이었으므로 mock 만 걷어내고 복원하지 않는다.
eval "$_RECON_REAL_SET"
eval "$_RECON_REAL_VERIFY"
unset -f _claude-current-board-status
unset _RECON_BOARD _RECON_REAL_SET _RECON_REAL_VERIFY

echo ""
echo "── #231: claude-set-pr-status \"Approved\" reviewDecision 가드 ──"

# 가드 시나리오: 외부 자동화가 사람 Approve 없이 Status 만 "Approved" 로 set 하는 케이스
# (PR #230 사고). claude-set-pr-status 가 target_status="Approved" 일 때만
# reviewDecision 을 조회해 APPROVED 가 아니면 거부해야 한다.
#
# 위 라우팅 블록의 _claude-content-node-id / claude-set-content-status mock 을
# 그대로 재사용 — claude-set-pr-status 가 "Approved" 분기에서 가드 통과 시에만
# 라우팅으로 진입함을 확인한다.

# Case A: reviewDecision=APPROVED → 가드 통과 → 기존 라우팅 그대로 실행.
_claude-gh-retry() {
  case "$*" in
    *"gh pr view"*) printf 'APPROVED\n' ;;
    *) "$@" ;;
  esac
}
out=$(claude-set-pr-status 230 'Approved' 2>&1)
rc=$?
assert_eq "Approved + reviewDecision=APPROVED → 가드 통과 → 라우팅 진입" \
  "node=mock-node-pulls-230 status=Approved label=PR #230" \
  "$out"
assert_eq "Approved + reviewDecision=APPROVED → return 0" "0" "$rc"

# Case B: reviewDecision=REVIEW_REQUIRED → 가드 차단 → 라우팅 미진입 + 비-zero 반환.
_claude-gh-retry() {
  case "$*" in
    *"gh pr view"*) printf 'REVIEW_REQUIRED\n' ;;
    *) "$@" ;;
  esac
}
out=$(claude-set-pr-status 230 'Approved' 2>&1)
rc=$?
assert_eq "Approved + reviewDecision=REVIEW_REQUIRED → return 1" "1" "$rc"
case "$out" in
  *"reviewDecision='REVIEW_REQUIRED'"*) assert_eq "에러 메시지에 reviewDecision 포함" "ok" "ok" ;;
  *)                                     assert_eq "에러 메시지에 reviewDecision 포함" "ok" "missing: $out" ;;
esac
case "$out" in
  *"node=mock-node-pulls-230"*) assert_eq "차단 시 라우팅 미진입" "ok" "leaked: $out" ;;
  *)                            assert_eq "차단 시 라우팅 미진입" "ok" "ok" ;;
esac

# Case C: reviewDecision=CHANGES_REQUESTED → 동일하게 차단.
_claude-gh-retry() {
  case "$*" in
    *"gh pr view"*) printf 'CHANGES_REQUESTED\n' ;;
    *) "$@" ;;
  esac
}
out=$(claude-set-pr-status 230 'Approved' 2>&1)
rc=$?
assert_eq "Approved + reviewDecision=CHANGES_REQUESTED → return 1" "1" "$rc"
case "$out" in
  *"reviewDecision='CHANGES_REQUESTED'"*) assert_eq "CHANGES_REQUESTED 메시지 포함" "ok" "ok" ;;
  *)                                       assert_eq "CHANGES_REQUESTED 메시지 포함" "ok" "missing: $out" ;;
esac

# Case D: gh pr view 실패 (네트워크/권한) → 가드 차단 (fail-closed).
_claude-gh-retry() {
  case "$*" in
    *"gh pr view"*) return 1 ;;
    *) "$@" ;;
  esac
}
out=$(claude-set-pr-status 230 'Approved' 2>&1)
rc=$?
assert_eq "Approved + gh pr view 실패 → return 1 (fail-closed)" "1" "$rc"
case "$out" in
  *"reviewDecision 조회 실패"*) assert_eq "조회 실패 메시지 포함" "ok" "ok" ;;
  *)                              assert_eq "조회 실패 메시지 포함" "ok" "missing: $out" ;;
esac

# Case E: 다른 status 는 reviewDecision 조회 자체를 트리거하지 않아야 한다.
# gh pr view 호출 시 명시적으로 실패시켜도 "In review" 분기는 통과해야 함.
_claude-gh-retry() {
  case "$*" in
    *"gh pr view"*)
      echo "GUARD_LEAKED: gh pr view should not run for non-Approved" >&2
      return 1
      ;;
    *) "$@" ;;
  esac
}
out=$(claude-set-pr-status 230 'In review' 2>&1)
assert_eq "In review 는 reviewDecision 조회 미트리거" \
  "node=mock-node-pulls-230 status=In review label=PR #230" \
  "$out"
out=$(claude-set-pr-status 230 'In progress' 2>&1)
assert_eq "In progress 는 reviewDecision 조회 미트리거" \
  "node=mock-node-pulls-230 status=In progress label=PR #230" \
  "$out"
out=$(claude-set-pr-status 230 'Done' 2>&1)
assert_eq "Done 는 reviewDecision 조회 미트리거" \
  "node=mock-node-pulls-230 status=Done label=PR #230" \
  "$out"

unset -f _claude-gh-retry

echo ""
echo "── claude-verify-issue-status / claude-verify-pr-status 라우팅 ──"

# verify wrapper도 set wrapper와 동일한 type/label 라우팅을 따라야 한다 (#60).
# _claude-content-node-id 모의는 위에서 이미 설정됨. claude-verify-content-status만
# 별도로 모킹해 인자 전달을 검증한다.
claude-verify-content-status() {
  printf 'node=%s expected=%s label=%s\n' "$1" "$2" "$3"
}

assert_eq "claude-verify-issue-status → issues 경로 + #N label" \
  "node=mock-node-issues-34 expected=In progress label=#34" \
  "$(claude-verify-issue-status 34 'In progress')"

assert_eq "claude-verify-pr-status → pulls 경로 + PR #N label" \
  "node=mock-node-pulls-113 expected=In review label=PR #113" \
  "$(claude-verify-pr-status 113 'In review')"

# mock을 제거하고 실제 구현을 복원 — 이어지는 테스트가 진짜 함수를 호출해야 한다.
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

echo ""
echo "── #213: claude-set-content-status -F→-f Done 회귀 가드 ──"

# 회귀 시나리오: Done의 option_id "98236657"가 순수 숫자라 `-F option=98236657`이
# 정수로 캐스팅돼 GraphQL `String!` 타입과 충돌하던 버그 (#213).
# `_claude-gh-retry`를 stub으로 대체해 mutation 호출 인자를 캡처하고,
# `-f option=`(raw-field, 문자열 강제)로 전달되는지 검증한다.

_GH_ARGS_LOG=$(mktemp)
_claude-gh-retry() {
  printf '%s\n' "$*" >> "$_GH_ARGS_LOG"
  # 매칭은 따옴표가 없는 unique 토큰으로 한다 — case glob에서 따옴표 escape가
  # 까다로워 false-negative가 잘 난다. updateProjectV2ItemFieldValue를 먼저
  # 매칭해야 한다 (mutation 본문에 projectV2 substring이 포함되어 메타 쿼리
  # 패턴과 충돌할 수 있음).
  case "$*" in
    *updateProjectV2ItemFieldValue*)
      printf '%s' '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_x"}}}}'
      ;;
    *addProjectV2ItemById*)
      # --jq로 .item.id가 추출되는 호출 — raw id 한 줄만 반환.
      printf 'PVTI_x'
      ;;
    *projectV2*)
      # 메타 쿼리 응답 — Done 옵션을 포함해 option_id 추출이 가능하도록.
      printf '%s' '{"data":{"organization":{"projectV2":{"id":"PVT_x","field":{"id":"PVTSSF_x","options":[{"id":"98236657","name":"Done"}]}}}}}'
      ;;
  esac
}

# 호출 — Done 전환 경로를 통과시킨다.
out=$(claude-set-content-status "I_mock_node" "Done" "#test-213" 2>&1)

assert_eq "Done 경로 전체 성공" "✅ #test-213 → Done" "$out"

# mutation의 option 인자가 -f(raw-field)로 전달되었는지. -F였다면 회귀.
if grep -q -- '-f option=98236657' "$_GH_ARGS_LOG"; then
  PASS=$((PASS + 1))
  printf '  ✅ %s\n' "updateProjectV2ItemFieldValue mutation에 -f option=98236657 (숫자 캐스팅 차단)"
else
  FAIL=$((FAIL + 1))
  printf '  ❌ %s\n     captured args:\n%s\n' \
    "Done option이 -f로 전달되지 않음 (#213 회귀)" "$(cat "$_GH_ARGS_LOG")"
fi

# 방어적: ID! 타입 변수(project, item, field, content)도 -f로 통일됐는지 확인.
for var in project item field content; do
  if grep -q -- "-f ${var}=" "$_GH_ARGS_LOG"; then
    PASS=$((PASS + 1))
    printf '  ✅ %s\n' "ID! 변수 ${var}는 -f로 전달"
  else
    FAIL=$((FAIL + 1))
    printf '  ❌ %s\n' "ID! 변수 ${var}가 -f로 전달되지 않음"
  fi
done

# Int! 변수(number)는 -F 유지 — 정수 캐스팅이 의도된 동작.
if grep -q -- '-F number=' "$_GH_ARGS_LOG"; then
  PASS=$((PASS + 1))
  printf '  ✅ %s\n' "Int! 변수 number는 -F 유지 (정수 캐스팅 의도)"
else
  FAIL=$((FAIL + 1))
  printf '  ❌ %s\n' "number가 -F로 전달되지 않음 (Int! 타입과 불일치 위험)"
fi

rm -f "$_GH_ARGS_LOG"
unset -f _claude-gh-retry
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

echo ""
echo "── _claude-content-node-id type 가드 ─────────────────────"

# _claude-content-node-id는 REST API 경로를 type 인자로 분기한다.
# 오기입(예: "issue" 단수형) 시 gh를 부르기 전에 조기 차단되는지 확인한다.
# gh 자체는 호출되지 않아야 하므로 mock 없이도 검증 가능 (가드가 먼저 실패).
out=$(_claude-content-node-id issue 34 2>&1)
rc=$?
assert_eq "잘못된 type='issue' (단수) → 비-zero 반환" "1" "$rc"
case "$out" in
  *"type은 'issues' 또는 'pulls'"*) assert_eq "가드 메시지 포함" "ok" "ok" ;;
  *)                                 assert_eq "가드 메시지 포함" "ok" "missing: $out" ;;
esac

echo ""
echo "── PR URL → 번호 파싱 ────────────────────────────────────"

# claude-close-issue는 `gh pr create` 출력 URL에서 `/pull/<N>` 패턴으로 PR 번호를
# 추출해 claude-set-pr-status에 넘긴다. 이 파싱이 깨지면 Status 전환 단계가
# "⚠️ PR 번호 파싱 실패"로 스킵되어 보드가 비대칭 상태로 남는다 (#34).
# 실제 스크립트와 동일하게 sed로 `/pull/(\d+)` 매칭 — 쿼리 파라미터/트레일링
# 슬래시가 섞인 변형 URL까지 견고하게 처리 (PR #121 리뷰 #3138783793).
_parse_pr_number() {
  local url="$1"
  local num
  num=$(printf '%s' "$url" | sed -E 's|.*/pull/([0-9]+).*|\1|')
  [[ "$num" =~ ^[0-9]+$ ]] && printf '%s\n' "$num"
}

assert_eq "표준 PR URL" "113" "$(_parse_pr_number 'https://github.com/example-org/example-repo/pull/113')"
assert_eq "쿼리 파라미터 포함 URL" "113" "$(_parse_pr_number 'https://github.com/example-org/example-repo/pull/113?expand=1')"
assert_eq "fragment 포함 URL" "113" "$(_parse_pr_number 'https://github.com/example-org/example-repo/pull/113#issuecomment-1')"
assert_eq "enterprise host PR URL" "42" "$(_parse_pr_number 'https://gh.example.com/acme/app/pull/42')"
assert_eq "빈 URL → 빈 값" "" "$(_parse_pr_number '')"
assert_eq "trailing slash → 빈 값" "" "$(_parse_pr_number 'https://github.com/a/b/pull/')"
assert_eq "숫자 아닌 꼬리 → 빈 값" "" "$(_parse_pr_number 'https://github.com/a/b/pull/not-a-number')"

echo ""
echo "── claude-main-worktree-path 파싱 ─────────────────────────"

# git worktree list --porcelain 형식은 worktree/HEAD/branch 블록이 빈 줄로
# 구분되고, 첫 블록의 worktree 항목이 primary(main worktree)이다.
# 실제 git 호출 없이 awk 파싱 로직만 검증.
parse_first_worktree() {
  local input="$1"
  printf '%s\n' "$input" | awk '$1=="worktree"{print $2; exit}'
}

# 단일 worktree 케이스
assert_eq "단일 worktree" \
  "/home/user/repo" \
  "$(parse_first_worktree 'worktree /home/user/repo
HEAD abc123
branch refs/heads/main')"

# 다중 worktree — 첫 엔트리만 반환
assert_eq "다중 worktree — primary만 반환" \
  "/home/user/repo" \
  "$(parse_first_worktree 'worktree /home/user/repo
HEAD abc123
branch refs/heads/main

worktree /home/user/repo/.claude/worktrees/issue-42
HEAD def456
branch refs/heads/issue-42-foo')"

# 빈 입력 → 빈 문자열
assert_eq "빈 입력" "" "$(parse_first_worktree '')"

echo ""
echo "── claude-board-status 필터링 ─────────────────────────────"

# claude-board-status는 API 호출을 _claude-gh-retry로 감싸므로,
# 해당 함수만 목킹해 고정 JSON을 반환하도록 한다.
# 검증 대상: 기본(Done 제외) / --all / 단일 상태 / 복수 상태 필터.
_MOCK_BOARD_JSON='{
  "data": {
    "organization": {
      "projectV2": {
        "items": {
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "nodes": [
            {"status": {"name": "In progress"}, "content": {"number": 1, "title": "Issue A", "__typename": "Issue"}},
            {"status": {"name": "In review"},   "content": {"number": 2, "title": "PR B",    "__typename": "PullRequest"}},
            {"status": {"name": "Done"},         "content": {"number": 3, "title": "Issue C", "__typename": "Issue"}},
            {"status": {"name": "Approved"},     "content": {"number": 4, "title": "PR D",    "__typename": "PullRequest"}}
          ]
        }
      }
    }
  }
}'
_claude-gh-retry() { printf '%s\n' "$_MOCK_BOARD_JSON"; }

assert_eq "기본 — Done 제외" \
  "$(printf '%s\n' \
    'Approved | PullRequest | #4 | PR D' \
    'In progress | Issue | #1 | Issue A' \
    'In review | PullRequest | #2 | PR B')" \
  "$(claude-board-status)"

assert_eq "--all — Done 포함 전체" \
  "$(printf '%s\n' \
    'Approved | PullRequest | #4 | PR D' \
    'Done | Issue | #3 | Issue C' \
    'In progress | Issue | #1 | Issue A' \
    'In review | PullRequest | #2 | PR B')" \
  "$(claude-board-status --all)"

assert_eq "단일 상태 필터 — In review만" \
  "In review | PullRequest | #2 | PR B" \
  "$(claude-board-status "In review")"

assert_eq "복수 상태 필터 — In progress + Approved" \
  "$(printf '%s\n' \
    'Approved | PullRequest | #4 | PR D' \
    'In progress | Issue | #1 | Issue A')" \
  "$(claude-board-status "In progress" "Approved")"

assert_eq "매칭 없는 상태 — 빈 출력" \
  "" \
  "$(claude-board-status "Backlog")"

unset -f _claude-gh-retry
unset _MOCK_BOARD_JSON
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

echo ""
echo "── claude-board-status 페이지네이션 루프 (#160) ───────────"

# #150이 도입한 GraphQL afterCursor 루프는 단일 페이지 mock(위 섹션)으로는
# 검증되지 않는다 — hasNextPage=false인 첫 페이지에서 즉시 종료되므로,
# cursor 전파·페이지 누적·종료 조건 어느 것도 회귀 보호가 없다.
#
# 본 섹션은 호출 횟수에 따라 다른 페이지를 반환하는 mock으로 교체해
# 다음 세 가지를 검증한다:
#   1) 모든 페이지의 노드가 출력에 누적되는가
#   2) 호출 횟수가 정확히 2회인가 (3회 이상이면 종료 조건 누락)
#   3) 두 번째 호출에 첫 페이지의 endCursor가 cursor 인자로 전파되는가
#      (변수 오타나 off-by-one 시 파라미터가 "null"로 굳어져 누락 발생)
_MOCK_BOARD_PAGE1='{
  "data": {
    "organization": {
      "projectV2": {
        "items": {
          "pageInfo": {"hasNextPage": true, "endCursor": "PAGE2_CURSOR"},
          "nodes": [
            {"status": {"name": "In progress"}, "content": {"number": 1, "title": "Page1 A", "__typename": "Issue"}},
            {"status": {"name": "In review"},   "content": {"number": 2, "title": "Page1 B", "__typename": "PullRequest"}}
          ]
        }
      }
    }
  }
}'
_MOCK_BOARD_PAGE2='{
  "data": {
    "organization": {
      "projectV2": {
        "items": {
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "nodes": [
            {"status": {"name": "Approved"}, "content": {"number": 3, "title": "Page2 C", "__typename": "PullRequest"}},
            {"status": {"name": "Backlog"},  "content": {"number": 4, "title": "Page2 D", "__typename": "Issue"}}
          ]
        }
      }
    }
  }
}'

# 호출 횟수·cursor 인자 캡처를 임시 파일에 저장 — claude-board-status 결과는
# $()로 서브셸을 만들어 호출하므로 셸 변수로는 외부에 카운트가 새어 나오지 않는다
# (#81 fixture와 동일한 백킹 전략).
_PAGE_CALLS_FILE=$(mktemp)
_CURSOR_LOG_FILE=$(mktemp)
printf '0\n' > "$_PAGE_CALLS_FILE"
: > "$_CURSOR_LOG_FILE"

_claude-gh-retry() {
  local n
  n=$(cat "$_PAGE_CALLS_FILE")
  n=$((n + 1))
  printf '%d\n' "$n" > "$_PAGE_CALLS_FILE"

  # gh api graphql 호출 인자 중 `cursor=<value>` 토큰을 추출해 호출별로 누적 기록.
  local arg
  for arg in "$@"; do
    case "$arg" in
      cursor=*) printf '%s\n' "${arg#cursor=}" >> "$_CURSOR_LOG_FILE" ;;
    esac
  done

  case "$n" in
    1) printf '%s\n' "$_MOCK_BOARD_PAGE1" ;;
    *) printf '%s\n' "$_MOCK_BOARD_PAGE2" ;;
  esac
}

# --all 로 모든 상태 포함시켜 두 페이지의 모든 노드를 출력 검증 대상으로 삼는다.
_pagination_out=$(claude-board-status --all)
_pagination_calls=$(cat "$_PAGE_CALLS_FILE")
_pagination_cursors=$(cat "$_CURSOR_LOG_FILE")

assert_eq "두 페이지 노드 모두 출력 (4건, status 정렬)" \
  "$(printf '%s\n' \
    'Approved | PullRequest | #3 | Page2 C' \
    'Backlog | Issue | #4 | Page2 D' \
    'In progress | Issue | #1 | Page1 A' \
    'In review | PullRequest | #2 | Page1 B')" \
  "$_pagination_out"

assert_eq "호출 횟수 정확히 2회 (3회+면 종료 조건 누락)" \
  "2" \
  "$_pagination_calls"

# 1회차는 초기값 "null", 2회차는 page1의 endCursor "PAGE2_CURSOR"가 와야 한다.
# 두 호출 모두 "null"이면 cursor 전파 변수가 끊긴 회귀.
assert_eq "cursor 전파 — null → 'PAGE2_CURSOR'" \
  "$(printf '%s\n' 'null' 'PAGE2_CURSOR')" \
  "$_pagination_cursors"

rm -f "$_PAGE_CALLS_FILE" "$_CURSOR_LOG_FILE"
unset -f _claude-gh-retry
unset _MOCK_BOARD_PAGE1 _MOCK_BOARD_PAGE2 _PAGE_CALLS_FILE _CURSOR_LOG_FILE
unset _pagination_out _pagination_calls _pagination_cursors
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

echo ""
echo "── zsh 호환성 회귀 가드 (#82) ─────────────────────────────"

# zsh에서 $status는 $? 별칭의 read-only 특수 변수다. 어떤 함수든 `local`로 status를
# 선언하면(할당 유무·플래그·다중 변수 모두) zsh가 함수 본문 파싱 단계에서
# 'read-only variable: status' 에러를 낸다. bash는 같은 코드를 잘 받아들이므로
# zsh 미설치 환경에선 회귀가 조용히 들어온다. zsh 미설치 CI에서도 잡기 위해
# 정적 검사로 차단한다.
#
# 회귀 패턴 커버리지 (#169 review):
#   local status=foo        → status 뒤 `=` 매치
#   local status            → status 뒤 줄 끝 매치
#   local status = 1        → status 뒤 공백+= 매치 (실제 셸 문법은 무효이지만 안전망)
#   local -a status=()      → 선행 토큰(`-a `) 매치
#   local x status          → 선행 토큰(`x `) 매치
#   local status;           → status 뒤 `;` 매치
# 비매치 (정상):
#   local status_code=...   → status 뒤가 `_`라 어느 후행 패턴도 매치하지 않음
#   local target_status=... → `target_`은 공백으로 끝나지 않아 선행 토큰 그룹이 매치 안됨
zsh_unsafe=$(grep -nE '^[[:space:]]*local[[:space:]]+([^;]*[[:space:]])?status([[:space:]]*=|;|[[:space:]]|$)' "${SCRIPT_DIR}/github-workflow.sh" || true)
if [[ -z "$zsh_unsafe" ]]; then
  PASS=$((PASS + 1))
  printf '  ✅ %s\n' "github-workflow.sh에 'local status' 변수 미사용 (zsh read-only 충돌 방지)"
else
  FAIL=$((FAIL + 1))
  printf '  ❌ %s\n     발견:\n%s\n' \
    "github-workflow.sh에 'local status'가 재도입됨 — zsh에서 'read-only variable: status' 에러 발생" \
    "$zsh_unsafe"
fi

echo ""
echo "── claude-find-similar-issues 매칭/필터링 ─────────────────"

# 검색 대상은 Project 보드 Issue 카드 중 Status가 Backlog/Ready이고 state=OPEN인 것.
# PR / In progress / Closed는 제외되어야 한다.
_MOCK_FIND_JSON='{
  "data": {
    "organization": {
      "projectV2": {
        "items": {
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "nodes": [
            {"status": {"name": "Backlog"},     "content": {"__typename": "Issue", "number": 10, "title": "Add Backlog dedup helper", "body": "improve gh-issue skill", "url": "u10", "state": "OPEN"}},
            {"status": {"name": "Ready"},        "content": {"__typename": "Issue", "number": 11, "title": "skill cleanup",          "body": "no related keyword",     "url": "u11", "state": "OPEN"}},
            {"status": {"name": "In progress"}, "content": {"__typename": "Issue", "number": 12, "title": "skill in progress",      "body": "backlog dedup mention", "url": "u12", "state": "OPEN"}},
            {"status": {"name": "Backlog"},     "content": {"__typename": "PullRequest", "number": 13, "title": "PR backlog dedup", "body": "x", "url": "u13", "state": "OPEN"}},
            {"status": {"name": "Backlog"},     "content": {"__typename": "Issue", "number": 14, "title": "closed backlog issue",  "body": "backlog dedup",         "url": "u14", "state": "CLOSED"}},
            {"status": {"name": "Backlog"},     "content": {"__typename": "Issue", "number": 15, "title": "BACKLOG keyword caps",  "body": "Dedup case-insensitive", "url": "u15", "state": "OPEN"}}
          ]
        }
      }
    }
  }
}'
# shellcheck disable=SC2317  # 함수는 바로 아래에서 호출됨
_claude-gh-retry() { printf '%s\n' "$_MOCK_FIND_JSON"; }

# 1) 인자 없으면 에러 + non-zero return.
out=$(claude-find-similar-issues 2>&1)
rc=$?
assert_eq "인자 없음 → return 1" "1" "$rc"
case "$out" in
  *"사용법: claude-find-similar-issues"*) assert_eq "사용법 메시지 포함" "ok" "ok" ;;
  *)                                       assert_eq "사용법 메시지 포함" "ok" "missing: $out" ;;
esac

# 2) 단일 키워드 "backlog" — Backlog/Ready · Issue · OPEN만 매칭.
#    #10(Backlog title 매칭) / #15(BACKLOG title — case-insensitive 매칭) 통과.
#    #14(CLOSED, body에 backlog 있어도 제외) / #13(PR 제외) / #12(In progress 제외) / #11(매칭 0) 탈락.
out=$(claude-find-similar-issues "backlog")
matched_numbers=$(printf '%s' "$out" | jq -r '[.[] | .number] | sort | tostring')
assert_eq "단일 키워드 — #10·#15만 (PR/Closed/In progress 제외, case-insensitive)" \
  "[10,15]" "$matched_numbers"

# 3) 다중 키워드 — score는 매칭된 키워드 개수.
#    #10 hay = "add backlog dedup helper improve gh-issue skill" → backlog/dedup/helper 모두 → 3
#    #15 hay = "backlog keyword caps dedup case-insensitive" → backlog/dedup → 2
out=$(claude-find-similar-issues "backlog" "dedup" "helper")
score_10=$(printf '%s' "$out" | jq -r '.[] | select(.number==10) | .score')
score_15=$(printf '%s' "$out" | jq -r '.[] | select(.number==15) | .score')
assert_eq "다중 키워드 — #10 score=3" "3" "$score_10"
assert_eq "다중 키워드 — #15 score=2 (helper 미매칭)" "2" "$score_15"

# 4) 정렬 — score 내림차순 → 동점이면 number 내림차순.
#    "skill" 키워드: #10(score=1), #11(score=1), #15(매칭 0 → 제외)
#    → #11이 먼저(번호 큼), #10이 다음.
#    Wait: #10 body "improve gh-issue skill" — 매칭. #11 title "skill cleanup" — 매칭.
#    동점이므로 number 내림차순 → #11, #10.
out=$(claude-find-similar-issues "skill")
ordered=$(printf '%s' "$out" | jq -r '[.[] | .number] | tostring')
assert_eq "정렬 — score 동점 시 number 내림차순" "[11,10]" "$ordered"

# 5) 매칭 없음 → 빈 배열.
out=$(claude-find-similar-issues "completely-absent-token-xyzzy")
assert_eq "매칭 없음 → 빈 배열" "[]" "$out"

# 6) 출력 스키마 확인 — 첫 항목에 number/title/status/score/url 필드 모두 존재.
out=$(claude-find-similar-issues "backlog")
keys=$(printf '%s' "$out" | jq -r '.[0] | keys | tostring')
assert_eq "출력 스키마 — number/title/status/score/url" \
  '["number","score","status","title","url"]' "$keys"

unset -f _claude-gh-retry
unset _MOCK_FIND_JSON

# 7) 페이지네이션 — 멀티 페이지 항목 누적 + cursor 전달 검증 (#176).
# 단일 페이지 mock(hasNextPage=false)만으로는 다음 회귀를 잡지 못한다:
#   - cursor가 다음 호출에 전달되지 않아 같은 페이지를 반복 fetch
#   - endCursor 처리 누락으로 2페이지 이후 항목 유실
#   - all_items 누적 시 페이지 경계 jq concat 오류
_MOCK_PAGE_1='{"data":{"organization":{"projectV2":{"items":{
  "pageInfo":{"hasNextPage":true,"endCursor":"CURSOR_P1"},
  "nodes":[{"status":{"name":"Backlog"},"content":{"__typename":"Issue","number":100,"title":"page1 backlog dedup","body":"","url":"u100","state":"OPEN"}}]
}}}}}'
_MOCK_PAGE_2='{"data":{"organization":{"projectV2":{"items":{
  "pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":[{"status":{"name":"Ready"},"content":{"__typename":"Issue","number":101,"title":"page2 backlog dedup","body":"","url":"u101","state":"OPEN"}}]
}}}}}'

# 호출 횟수와 두 번째 호출에 전달된 cursor 인자를 임시 파일에 기록.
# 변수 카운트는 `out=$(...)` 서브셸에서 외부로 전파되지 않으므로 파일 백킹.
_PAGE_CALL_FILE=$(mktemp)
_PAGE_CURSOR_FILE=$(mktemp)
printf '0\n' > "$_PAGE_CALL_FILE"

_claude-gh-retry() {
  local count
  count=$(cat "$_PAGE_CALL_FILE")
  count=$((count + 1))
  printf '%d\n' "$count" > "$_PAGE_CALL_FILE"

  # 인자 중 cursor=... 토큰을 찾아 두 번째 호출분만 기록.
  # 실제 호출은 `_claude-gh-retry gh api graphql ... -F cursor="$cursor"` 형태이므로
  # cursor 값이 별도 토큰으로 들어온다.
  if (( count == 2 )); then
    local arg cursor_val=""
    for arg in "$@"; do
      case "$arg" in
        cursor=*)        cursor_val="${arg#cursor=}"; break ;;
      esac
    done
    printf '%s' "$cursor_val" > "$_PAGE_CURSOR_FILE"
  fi

  if (( count == 1 )); then
    printf '%s\n' "$_MOCK_PAGE_1"
  else
    printf '%s\n' "$_MOCK_PAGE_2"
  fi
}

# "backlog dedup" 키워드는 양쪽 페이지 모두 매칭되도록 의도된 hay-stack.
out=$(claude-find-similar-issues "backlog" "dedup")
matched=$(printf '%s' "$out" | jq -r '[.[] | .number] | sort | tostring')
assert_eq "페이지네이션 — 두 페이지 항목 모두 누적" "[100,101]" "$matched"

call_count=$(cat "$_PAGE_CALL_FILE")
assert_eq "페이지네이션 — _claude-gh-retry 정확히 2회 호출" "2" "$call_count"

second_cursor=$(cat "$_PAGE_CURSOR_FILE")
assert_eq "페이지네이션 — 두 번째 호출에 page1의 endCursor 전달" "CURSOR_P1" "$second_cursor"

rm -f "$_PAGE_CALL_FILE" "$_PAGE_CURSOR_FILE"
unset -f _claude-gh-retry
unset _MOCK_PAGE_1 _MOCK_PAGE_2 _PAGE_CALL_FILE _PAGE_CURSOR_FILE

echo ""
echo "── claude-verify-content-status 동작 ──────────────────────"

# 사후 검증 함수의 핵심 책임은 (1) 우리 Project 카드를 골라내 (2) Status가
# expected와 일치하는지 확인하는 것. _claude-gh-retry를 모킹해 set 단계 직후
# 보드 상태를 시뮬레이션한다.
sleep() { :; }

CLAUDE_PROJECT_OWNER="${CLAUDE_PROJECT_OWNER:-example-org}"
CLAUDE_PROJECT_NUMBER="${CLAUDE_PROJECT_NUMBER:-10}"

_make_board_json() {
  local status="$1"
  cat <<EOF
{
  "data": {
    "organization": { "projectV2": { "id": "PROJ_OUR" } },
    "node": {
      "projectItems": {
        "nodes": [
          { "project": { "id": "PROJ_OTHER" }, "status": { "name": "Backlog" } },
          { "project": { "id": "PROJ_OUR" }, "status": { "name": "${status}" } }
        ]
      }
    }
  }
}
EOF
}

# 1) 일치 — 첫 시도에 통과.
_claude-gh-retry() { _make_board_json "In review"; }
out=$(claude-verify-content-status "ISSUE_NODE" "In review" "#60" 2>&1)
rc=$?
assert_eq "일치 — return 0" "0" "$rc"
case "$out" in
  *"검증 통과"*) assert_eq "일치 — ✅ 메시지" "ok" "ok" ;;
  *)             assert_eq "일치 — ✅ 메시지" "ok" "missing: $out" ;;
esac

# 2) 불일치 — return 1, 현재값을 stderr에 보고.
_claude-gh-retry() { _make_board_json "In progress"; }
out=$(claude-verify-content-status "ISSUE_NODE" "In review" "#60" 2>&1)
rc=$?
assert_eq "불일치 — return 1" "1" "$rc"
case "$out" in
  *"불일치"*"기대=In review"*"현재=In progress"*)
    assert_eq "불일치 — 진단 메시지" "ok" "ok" ;;
  *)
    assert_eq "불일치 — 진단 메시지" "ok" "missing: $out" ;;
esac

# 3) 다른 프로젝트의 카드만 있는 경우 — 우리 보드에 없음으로 간주, 실패.
_claude-gh-retry() {
  cat <<'EOF'
{
  "data": {
    "organization": { "projectV2": { "id": "PROJ_OUR" } },
    "node": {
      "projectItems": {
        "nodes": [
          { "project": { "id": "PROJ_OTHER" }, "status": { "name": "Backlog" } }
        ]
      }
    }
  }
}
EOF
}
out=$(claude-verify-content-status "ISSUE_NODE" "In review" "#60" 2>&1)
rc=$?
assert_eq "보드에 카드 없음 — return 1" "1" "$rc"
case "$out" in
  *"보드 카드/Status를 찾을 수 없습니다"*) assert_eq "카드 없음 — 진단 메시지" "ok" "ok" ;;
  *)                                       assert_eq "카드 없음 — 진단 메시지" "ok" "missing: $out" ;;
esac

# 4) 빈 content_node_id 가드 — gh 호출 전에 조기 차단.
out=$(claude-verify-content-status "" "In review" "#60" 2>&1)
rc=$?
assert_eq "빈 node_id — return 1" "1" "$rc"

unset -f _claude-gh-retry _make_board_json sleep

echo ""
echo "── claude-issue-severity ──────────────────────────────────"

# 정책: PR이 닫는 이슈에 severity 라벨이 부착돼 있으면 PR에도 동일 severity를
# 자동 전파한다 (.claude/github-integration.md §"이슈→PR severity 전파 의무").
# 이 함수는 gh issue view 호출을 _claude-gh-retry로 감싸므로 mock으로 검증.
#
# Mock 테이블: <issue>=<labels;...> 형식. 라벨 사이는 ';'로 구분.
# - 100: severity 없음
# - 101: 🔥 Critical (+ 다른 라벨)
# - 102: ⚡ High
# - 103: 🔼 Medium
# - 999: 미정의 (실패 케이스용)
_MOCK_LABELS_FILE=$(mktemp)
{
  printf '100=enhancement;documentation\n'
  printf '101=🔥 Critical;pro-friendly\n'
  printf '102=⚡ High\n'
  printf '103=🔼 Medium\n'
} > "$_MOCK_LABELS_FILE"

_claude-gh-retry() {
  # 호출 형태: _claude-gh-retry gh issue view <N> --json labels --jq '.labels[].name'
  # `view` 토큰 다음 인자가 이슈 번호.
  local issue=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "view" ]]; then
      shift
      issue="$1"
      break
    fi
    shift
  done

  if grep -q "^${issue}=" "$_MOCK_LABELS_FILE" 2>/dev/null; then
    grep "^${issue}=" "$_MOCK_LABELS_FILE" | sed -E 's/^[0-9]+=//' | tr ';' '\n'
    return 0
  fi
  return 1
}

# (a) 인자 없음 → return 1, 빈 출력.
out=$(claude-issue-severity 2>/dev/null)
rc=$?
assert_eq "인자 없음 — return 1" "1" "$rc"
assert_eq "인자 없음 — stdout 비어 있음" "" "$out"

# (b) 이슈 1개, severity 없음 → 빈 출력 + return 0.
out=$(claude-issue-severity 100 2>/dev/null)
rc=$?
assert_eq "severity 없음 — 빈 출력" "" "$out"
assert_eq "severity 없음 — return 0" "0" "$rc"

# (c) 이슈 1개, Critical → "🔥 Critical".
assert_eq "Critical 단일 이슈" \
  "🔥 Critical" \
  "$(claude-issue-severity 101 2>/dev/null)"

# (d) Critical + Medium → 가장 높은 Critical만.
assert_eq "Critical + Medium → Critical" \
  "🔥 Critical" \
  "$(claude-issue-severity 101 103 2>/dev/null)"

# (e) High + Medium → High만.
assert_eq "High + Medium → High" \
  "⚡ High" \
  "$(claude-issue-severity 102 103 2>/dev/null)"

# (f) 존재하지 않는 이슈 → soft fail (return 0, stderr 경고, 빈 출력).
out=$(claude-issue-severity 999 2>/dev/null)
rc=$?
assert_eq "존재하지 않는 이슈 — soft fail return 0" "0" "$rc"
assert_eq "존재하지 않는 이슈 — 빈 출력" "" "$out"

# (보너스) 비숫자 인자는 무시되고 유효 인자만 처리.
assert_eq "비숫자 인자 혼합 — 유효 인자만 사용" \
  "🔥 Critical" \
  "$(claude-issue-severity abc 101 2>/dev/null)"

# (보너스) 실패 이슈와 성공 이슈 혼합 → 성공 이슈만 반영.
assert_eq "조회 실패 + Medium → Medium 그대로 반환" \
  "🔼 Medium" \
  "$(claude-issue-severity 999 103 2>/dev/null)"

rm -f "$_MOCK_LABELS_FILE"
unset -f _claude-gh-retry
unset _MOCK_LABELS_FILE
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

echo ""
echo "── claude-audit-commit-issue-refs (#184) ──────────────────"

# 함수는 git log 출력에만 의존한다 — git 자체를 stub으로 대체해 격리.
# 경고는 stderr로 나가므로 2>&1로 캡처.

# 0) 빈 인자 → return 0, 출력 없음 (가드 조기 반환).
out=$(claude-audit-commit-issue-refs 2>&1)
rc=$?
assert_eq "빈 인자 — return 0" "0" "$rc"
assert_eq "빈 인자 — 출력 없음" "" "$out"

# 1) 세션 이슈 번호만 등장 → 경고 없음.
git() {
  if [[ "${1:-}" == "log" ]]; then
    printf 'feat: #184 add audit helper\n\nbody only mentions self\n'
    return 0
  fi
  return 0
}
out=$(claude-audit-commit-issue-refs 184 2>&1)
rc=$?
assert_eq "세션 이슈만 — return 0" "0" "$rc"
assert_eq "세션 이슈만 — 경고 없음" "" "$out"

# 2) 다른 이슈 번호 섞임 → 경고 (soft warn, return 0).
git() {
  printf 'feat: #184 audit helper\n\nfeat: #127 unrelated\n\nfix: #29 another\n'
  return 0
}
out=$(claude-audit-commit-issue-refs 184 2>&1)
rc=$?
assert_eq "cross-ref — return 0 (soft warn)" "0" "$rc"
case "$out" in
  *"⚠️"*"#184"*) assert_eq "cross-ref — 경고 헤더에 세션 #184 포함" "ok" "ok" ;;
  *)              assert_eq "cross-ref — 경고 헤더에 세션 #184 포함" "ok" "missing: $out" ;;
esac
case "$out" in
  *"#127"*) assert_eq "cross-ref — #127 보고" "ok" "ok" ;;
  *)        assert_eq "cross-ref — #127 보고" "ok" "missing: $out" ;;
esac
case "$out" in
  *"#29"*) assert_eq "cross-ref — #29 보고" "ok" "ok" ;;
  *)       assert_eq "cross-ref — #29 보고" "ok" "missing: $out" ;;
esac

# 3) 같은 #N이 여러 번 등장 → 한 번만 보고 (sort -u).
git() {
  printf 'feat: #184\nfix: #127 first\nrefactor: #127 again\n'
  return 0
}
out=$(claude-audit-commit-issue-refs 184 2>&1)
count=$(printf '%s' "$out" | grep -c '#127')
assert_eq "중복 #127 — 한 번만 보고" "1" "$count"

# 4) git log 빈 출력 → 경고 없음.
git() { return 0; }
out=$(claude-audit-commit-issue-refs 184 2>&1)
rc=$?
assert_eq "빈 log — return 0" "0" "$rc"
assert_eq "빈 log — 경고 없음" "" "$out"

# 5) git log 자체 실패 (return 1) → 감사 불가, 조용히 통과.
git() { return 1; }
out=$(claude-audit-commit-issue-refs 184 2>&1)
rc=$?
assert_eq "git log 실패 — return 0 (조용한 통과)" "0" "$rc"
assert_eq "git log 실패 — 출력 없음" "" "$out"

# 6) 본문에 # 마커 없음 → 경고 없음.
git() {
  printf 'feat: add helper\n\nNo issue references in body.\n'
  return 0
}
out=$(claude-audit-commit-issue-refs 184 2>&1)
rc=$?
assert_eq "# 마커 없음 — return 0" "0" "$rc"
assert_eq "# 마커 없음 — 경고 없음" "" "$out"

unset -f git

echo ""
echo "── claude-close-issue: gh pr create 실패 가드 (#81) ───────"

# `gh pr create`가 네트워크 오류 등으로 실패해도 종료 코드를 검증하지 않으면
# "✅ PR 생성 완료"가 거짓으로 찍히고 후속 claude-set-pr-status가 실행되어
# PR 없이 보드 Status만 In review로 드리프트한다. 이슈 #81의 회귀 가드.
#
# git/gh/bun/jq 와 협력 함수를 모두 stub으로 대체해 부작용 없이 가드 흐름만 격리.
# 호출 횟수 카운터는 임시 파일을 백킹으로 쓴다 — `out=$(claude-close-issue ...)` 가
# 내부 서브셸을 만들기 때문에 변수로 카운트하면 증분이 외부로 나오지 않아
# regression이 발생해도 0으로 보인다 (PR #168 gemini 리뷰).
_close_issue_failure_probe=$(
  claude-session-bound() { printf '999\n'; return 0; }
  git()  { return 0; }
  bun()  { return 0; }
  jq()   { return 1; }  # .scripts.test 검사 실패 → 테스트 가드 스킵 경로
  # #120: lint 가드는 별도 케이스로 검증한다 — 본 fixture는 gh pr create 실패만 격리.
  _claude-lint-guard() { return 0; }
  gh() {
    if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then return 1; fi
    return 0
  }
  _spy_calls_file=$(mktemp)
  printf '0\n' > "$_spy_calls_file"
  claude-set-pr-status() {
    local c
    c=$(cat "$_spy_calls_file")
    printf '%d\n' "$((c + 1))" > "$_spy_calls_file"
  }

  out=$(claude-close-issue 999 fix "probe" 2>&1)
  rc=$?
  calls=$(cat "$_spy_calls_file")
  rm -f "$_spy_calls_file"
  printf '%d\n%d\n%s' "$rc" "$calls" "$out"
)
_probe_rc=$(printf '%s\n' "$_close_issue_failure_probe" | sed -n '1p')
_probe_calls=$(printf '%s\n' "$_close_issue_failure_probe" | sed -n '2p')
_probe_out=$(printf '%s\n' "$_close_issue_failure_probe" | sed -n '3,$p')

assert_eq "실패 시 비영(non-zero) 종료" "1" "$_probe_rc"
assert_eq "실패 시 claude-set-pr-status 미호출" "0" "$_probe_calls"
case "$_probe_out" in
  *"✅ PR 생성 완료"*) assert_eq "실패 시 ✅ 메시지 미출력" "ok" "leaked: $_probe_out" ;;
  *)                   assert_eq "실패 시 ✅ 메시지 미출력" "ok" "ok" ;;
esac
case "$_probe_out" in
  *"❌ PR 생성 실패"*) assert_eq "실패 시 에러 메시지 출력" "ok" "ok" ;;
  *)                   assert_eq "실패 시 에러 메시지 출력" "ok" "missing: $_probe_out" ;;
esac

unset _close_issue_failure_probe _probe_rc _probe_calls _probe_out

echo ""
echo "── claude-close-issue: AC 미체크 가드 (#440) ──────────────"

# Defense 1 회귀 가드: 이슈 본문에 `- [ ]` 미체크 항목이 있으면 PR 생성 차단.
# `--force` 로 명시 우회 가능. body 조회 실패는 fail-open (가드 스킵).
#
# fixture 전략: gh issue view --json body 만 mock 하여 다양한 body 를 주입한다.
# git/bun/jq/_claude-lint-guard 는 close-issue #81 fixture 와 동일하게 stub 으로
# 통과시키되, gh pr create 호출 여부를 spy 파일에 기록해 가드 발화 여부 검증.
_run_ac_probe() {
  # $1: spy 파일, $2: --force 인자 ("" 또는 "--force"), $3: body 내용 (raw)
  # $4: gh issue view 종료 코드 (0=성공, 1=실패 → fail-open)
  local _PROBE_SPY="$1" _PROBE_FORCE="$2" _PROBE_BODY="$3" _PROBE_VIEW_RC="$4"
  (
    claude-session-bound() { printf '777\n'; return 0; }
    git() { return 0; }
    bun() { return 0; }
    jq() {
      case "$*" in
        *".scripts.test"*) return 1 ;;
      esac
      command jq "$@"
    }
    _claude-lint-guard() { return 0; }
    claude-audit-commit-issue-refs() { return 0; }
    claude-audit-builtin-workflows() { return 0; }

    # _claude-gh-retry 는 첫 인자가 'gh' 이고 'issue view' 라면 body 를 stdout 으로
    # 흘리고 _PROBE_VIEW_RC 로 반환. 그 외는 그대로 위임.
    _claude-gh-retry() {
      if [[ "${1:-}" == "gh" && "${2:-}" == "issue" && "${3:-}" == "view" ]]; then
        printf '%s\n' "$_PROBE_BODY"
        return "$_PROBE_VIEW_RC"
      fi
      "$@"
    }

    gh() {
      printf 'gh %s\n' "$*" >> "$_PROBE_SPY"
      case "${1:-} ${2:-}" in
        "pr create") printf 'https://github.com/example-org/example-repo/pull/9999\n' ;;
      esac
      return 0
    }
    claude-set-pr-status() { printf 'set-pr-status %s\n' "$*" >> "$_PROBE_SPY"; }

    if [[ -n "$_PROBE_FORCE" ]]; then
      claude-close-issue "$_PROBE_FORCE" 777 feat "ac probe" >/dev/null 2>>"$_PROBE_SPY"
    else
      claude-close-issue 777 feat "ac probe" >/dev/null 2>>"$_PROBE_SPY"
    fi
    printf 'rc=%d\n' "$?" >> "$_PROBE_SPY"
  )
}

# Case 1: 미체크 1건 + --force 없음 → return 1, gh pr create 미호출.
_spy=$(mktemp)
_run_ac_probe "$_spy" "" $'## AC\n- [ ] 첫 항목\n- [x] 완료된 항목\n' "0"
_log=$(cat "$_spy")
case "$_log" in
  *"rc=1"*) assert_eq "AC 미체크 + force 미사용 → return 1" "ok" "ok" ;;
  *)         assert_eq "AC 미체크 + force 미사용 → return 1" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"gh pr create"*) assert_eq "AC 미체크 → gh pr create 미호출" "ok" "leaked: $_log" ;;
  *)                 assert_eq "AC 미체크 → gh pr create 미호출" "ok" "ok" ;;
esac
case "$_log" in
  *"AC 미체크 1건"*) assert_eq "AC 미체크 → 차단 메시지 카운트 표시" "ok" "ok" ;;
  *)                  assert_eq "AC 미체크 → 차단 메시지 카운트 표시" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"claude-ref-issue"*) assert_eq "차단 메시지에 ref-issue 대안 안내" "ok" "ok" ;;
  *)                     assert_eq "차단 메시지에 ref-issue 대안 안내" "ok" "missing: $_log" ;;
esac
rm -f "$_spy"

# Case 2: 미체크 0건 → 정상 진행 (gh pr create 호출).
_spy=$(mktemp)
_run_ac_probe "$_spy" "" $'## AC\n- [x] 모두 체크\n- [x] 두 번째도 체크\n' "0"
_log=$(cat "$_spy")
case "$_log" in
  *"rc=0"*) assert_eq "AC 모두 체크 → return 0 (정상 진행)" "ok" "ok" ;;
  *)         assert_eq "AC 모두 체크 → return 0 (정상 진행)" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"gh pr create"*) assert_eq "AC 모두 체크 → gh pr create 호출" "ok" "ok" ;;
  *)                 assert_eq "AC 모두 체크 → gh pr create 호출" "ok" "missing: $_log" ;;
esac
rm -f "$_spy"

# Case 2-bis: GFM 표준 task-list 마커 `*` / `+` 도 인식 (PR #444 gemini medium).
# 미체크 마커가 `-` 가 아니어도 가드가 발화해야 한다.
_spy=$(mktemp)
_run_ac_probe "$_spy" "" $'* [ ] 별표 미체크\n+ [ ] 플러스 미체크\n- [x] 하이픈 체크\n' "0"
_log=$(cat "$_spy")
case "$_log" in
  *"rc=1"*) assert_eq "GFM star/plus 마커 → 가드 발화" "ok" "ok" ;;
  *)         assert_eq "GFM star/plus 마커 → 가드 발화" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"AC 미체크 2건"*) assert_eq "GFM star/plus 마커 → 카운트 정확" "ok" "ok" ;;
  *)                  assert_eq "GFM star/plus 마커 → 카운트 정확" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"gh pr create"*) assert_eq "GFM star/plus 마커 → gh pr create 미호출" "ok" "leaked: $_log" ;;
  *)                 assert_eq "GFM star/plus 마커 → gh pr create 미호출" "ok" "ok" ;;
esac
rm -f "$_spy"

# Case 3: 미체크 2건 + --force → 우회 진행 (gh pr create 호출, stderr 경고).
_spy=$(mktemp)
_run_ac_probe "$_spy" "--force" $'- [ ] 첫\n- [ ] 둘\n- [x] 셋\n' "0"
_log=$(cat "$_spy")
case "$_log" in
  *"rc=0"*) assert_eq "--force → return 0 (우회 진행)" "ok" "ok" ;;
  *)         assert_eq "--force → return 0 (우회 진행)" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"gh pr create"*) assert_eq "--force → gh pr create 호출" "ok" "ok" ;;
  *)                 assert_eq "--force → gh pr create 호출" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"--force 로 우회 진행"*) assert_eq "--force → 우회 경고 메시지 출력" "ok" "ok" ;;
  *)                          assert_eq "--force → 우회 경고 메시지 출력" "ok" "missing: $_log" ;;
esac
rm -f "$_spy"

# Case 4: gh issue view body 조회 실패 → fail-open (가드 스킵 + 경고).
_spy=$(mktemp)
_run_ac_probe "$_spy" "" "" "1"
_log=$(cat "$_spy")
case "$_log" in
  *"rc=0"*) assert_eq "body 조회 실패 → fail-open (정상 진행)" "ok" "ok" ;;
  *)         assert_eq "body 조회 실패 → fail-open (정상 진행)" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"AC 가드 스킵"*) assert_eq "body 조회 실패 → 스킵 경고 출력" "ok" "ok" ;;
  *)                  assert_eq "body 조회 실패 → 스킵 경고 출력" "ok" "missing: $_log" ;;
esac
rm -f "$_spy"

# Case 5: --force 가 위치 무관임을 검증 (마지막 인자로 와도 인식).
_spy=$(mktemp)
(
  claude-session-bound() { printf '777\n'; return 0; }
  git() { return 0; }
  bun() { return 0; }
  jq() {
    case "$*" in
      *".scripts.test"*) return 1 ;;
    esac
    command jq "$@"
  }
  _claude-lint-guard() { return 0; }
  claude-audit-commit-issue-refs() { return 0; }
  claude-audit-builtin-workflows() { return 0; }
  _claude-gh-retry() {
    if [[ "${1:-}" == "gh" && "${2:-}" == "issue" && "${3:-}" == "view" ]]; then
      printf '%s\n' $'- [ ] 미체크\n'
      return 0
    fi
    "$@"
  }
  gh() {
    printf 'gh %s\n' "$*" >> "$_spy"
    case "${1:-} ${2:-}" in
      "pr create") printf 'https://github.com/example-org/example-repo/pull/9999\n' ;;
    esac
    return 0
  }
  claude-set-pr-status() { return 0; }

  # --force 가 type/description 사이에 와도 분리되어야 한다.
  claude-close-issue 777 feat "trailing force" --force >/dev/null 2>>"$_spy"
  printf 'rc=%d\n' "$?" >> "$_spy"
) || true
_log=$(cat "$_spy")
case "$_log" in
  *"rc=0"*) assert_eq "--force 위치 무관 — 끝에 와도 분리" "ok" "ok" ;;
  *)         assert_eq "--force 위치 무관 — 끝에 와도 분리" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"gh pr create"*) assert_eq "--force 위치 무관 — gh pr create 도달" "ok" "ok" ;;
  *)                 assert_eq "--force 위치 무관 — gh pr create 도달" "ok" "missing: $_log" ;;
esac
rm -f "$_spy"

unset -f _run_ac_probe

# Case 6: 필수 인자 누락 → return 1 + 사용법 출력 (PR #444 gemini medium).
# --force 분리 후 positional 이 비면 즉시 차단.
_spy=$(mktemp)
(
  claude-session-bound() { return 1; }  # 바인딩 가드는 통과 — 실제 차단은 args 검증.
  claude-close-issue 2>>"$_spy"
  printf 'rc=%d\n' "$?" >> "$_spy"
) || true
_log=$(cat "$_spy")
case "$_log" in
  *"rc=1"*) assert_eq "claude-close-issue 인자 누락 → return 1" "ok" "ok" ;;
  *)         assert_eq "claude-close-issue 인자 누락 → return 1" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"사용법"*) assert_eq "claude-close-issue 인자 누락 → 사용법 출력" "ok" "ok" ;;
  *)            assert_eq "claude-close-issue 인자 누락 → 사용법 출력" "ok" "missing: $_log" ;;
esac
rm -f "$_spy"

echo ""
echo "── claude-ref-issue: Refs 키워드 + 보드 미변경 (#440) ─────"

# Defense 2 회귀 가드: claude-ref-issue 는 PR 본문에 Refs 만 삽입하고
# claude-set-pr-status 를 호출하지 않는다 (이슈 카드 변동 없음).
#
# fixture 전략: gh pr create 호출 인자를 그대로 spy 파일에 기록해 --body 의
# 본문 키워드와 claude-set-pr-status 호출 여부를 검증한다.
_run_ref_probe() {
  # $1: spy 파일, $2: 인자 prefix ("" 또는 "missing-arg" 등 케이스명)
  local _PROBE_SPY="$1" _PROBE_CASE="$2"
  (
    claude-session-bound() { printf '777\n'; return 0; }
    git() { return 0; }
    bun() { return 0; }
    jq() {
      case "$*" in
        *".scripts.test"*) return 1 ;;
      esac
      command jq "$@"
    }
    _claude-lint-guard() { return 0; }
    claude-audit-commit-issue-refs() { return 0; }
    claude-audit-builtin-workflows() { return 0; }
    gh() {
      printf 'gh %s\n' "$*" >> "$_PROBE_SPY"
      # --body-file 은 create 직후 삭제되는 임시 파일 — 호출 시점에 본문을
      # spy 로 복사해 본문 키워드 어서션을 유지한다 (#1486 body-file 전환).
      local _a _prev=""
      for _a in "$@"; do
        if [[ "$_prev" == "--body-file" ]]; then
          cat "$_a" >> "$_PROBE_SPY" 2>/dev/null
        fi
        _prev="$_a"
      done
      return 0
    }
    claude-set-pr-status() {
      printf 'set-pr-status %s\n' "$*" >> "$_PROBE_SPY"
    }

    case "$_PROBE_CASE" in
      "normal")    claude-ref-issue 777 docs "intermediate work" >/dev/null 2>>"$_PROBE_SPY" ;;
      "wrong-id")  claude-ref-issue 999 docs "wrong issue" >/dev/null 2>>"$_PROBE_SPY" ;;
      "no-args")   claude-ref-issue 2>>"$_PROBE_SPY" ;;
    esac
    printf 'rc=%d\n' "$?" >> "$_PROBE_SPY"
  )
}

# Case 1: 정상 호출 → PR body 에 `Refs #777` 포함, `Closes` 미포함, set-pr-status 미호출.
_spy=$(mktemp)
_run_ref_probe "$_spy" "normal"
_log=$(cat "$_spy")
case "$_log" in
  *"rc=0"*) assert_eq "ref-issue 정상 호출 → return 0" "ok" "ok" ;;
  *)         assert_eq "ref-issue 정상 호출 → return 0" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"Refs #777"*) assert_eq "ref-issue → PR 본문에 Refs #777 포함" "ok" "ok" ;;
  *)              assert_eq "ref-issue → PR 본문에 Refs #777 포함" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"Closes #777"*) assert_eq "ref-issue → PR 본문에 Closes 미포함" "ok" "leaked: $_log" ;;
  *)                assert_eq "ref-issue → PR 본문에 Closes 미포함" "ok" "ok" ;;
esac
case "$_log" in
  *"set-pr-status"*) assert_eq "ref-issue → claude-set-pr-status 미호출" "ok" "leaked: $_log" ;;
  *)                  assert_eq "ref-issue → claude-set-pr-status 미호출" "ok" "ok" ;;
esac
rm -f "$_spy"

# Case 2: 세션 바인딩 충돌 (브랜치=#777 인데 인자=999) → return 1, gh pr create 미호출.
_spy=$(mktemp)
_run_ref_probe "$_spy" "wrong-id"
_log=$(cat "$_spy")
case "$_log" in
  *"rc=1"*) assert_eq "ref-issue 세션 충돌 → return 1" "ok" "ok" ;;
  *)         assert_eq "ref-issue 세션 충돌 → return 1" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"gh pr create"*) assert_eq "ref-issue 세션 충돌 → gh pr create 미호출" "ok" "leaked: $_log" ;;
  *)                 assert_eq "ref-issue 세션 충돌 → gh pr create 미호출" "ok" "ok" ;;
esac
rm -f "$_spy"

# Case 3: 인자 누락 → return 1.
_spy=$(mktemp)
_run_ref_probe "$_spy" "no-args"
_log=$(cat "$_spy")
case "$_log" in
  *"rc=1"*) assert_eq "ref-issue 인자 누락 → return 1" "ok" "ok" ;;
  *)         assert_eq "ref-issue 인자 누락 → return 1" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"사용법"*) assert_eq "ref-issue 인자 누락 → 사용법 출력" "ok" "ok" ;;
  *)            assert_eq "ref-issue 인자 누락 → 사용법 출력" "ok" "missing: $_log" ;;
esac
rm -f "$_spy"

unset -f _run_ref_probe

echo ""
echo "── claude-cleanup-worktree: PR/이슈 인자 디스패치 (#115) ──"

# claude-cleanup-worktree <arg> 는 인자를 이슈 → PR 순서로 시도해야 한다.
# 이 가드가 깨지면 사용자가 PR 번호로 호출했을 때 worktree 가 정리되지 않거나,
# 이슈 인자(레거시) 호환성이 깨진다.
#
# 전략: gh / git 을 서브셸 내부에서 모킹하고, 임시 cwd 로 진입해 worktree 경로가
# 존재하지 않게 만든다. 함수는 "이미 없습니다" 분기에서 일찍 return 0 하지만,
# 그 메시지의 경로(.claude/worktrees/issue-<N>) 에 환산된 이슈 번호가 박혀 있어
# dispatch 결과를 검증할 수 있다. PR/이슈 둘 다 실패하는 경로는 return 1 + 진단
# 메시지로 별도 검증한다.

_cleanup_dispatch_probe=$(
  cd "$(mktemp -d)" || exit 1
  git() {
    case "${1:-} ${2:-}" in
      "rev-parse --abbrev-ref") printf 'main\n'; return 0 ;;
      *) return 0 ;;
    esac
  }

  # 1) 이슈 인자 — gh pr view 실패(이슈는 PR 이 아님), gh issue view 성공 → 인자 그대로.
  #    실제 gh 행동: 이슈 번호로 `gh pr view --json headRefName` 호출 시 GraphQL 에러.
  gh() {
    [[ "${1:-}" == "pr" && "${2:-}" == "view" ]] && return 1
    [[ "${1:-}" == "issue" && "${2:-}" == "view" ]] && return 0
    return 1
  }
  out_issue=$(claude-cleanup-worktree 42 2>&1)

  # 2) PR 인자 — 핵심 회귀 가드. 실제 gh 에서 `gh issue view <PR#>` 도 성공하므로
  #    이슈 분기를 먼저 시도하면 PR 번호가 그대로 issue_number 로 들어가 worktree
  #    경로가 빗나간다(원 버그, gemini-code-assist PR #178 리뷰). PR 분기를 우선
  #    시도하고 headRefName 에서 추출하는 동작을 잠근다.
  gh() {
    if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
      printf 'issue-115-feat-foo\n'; return 0
    fi
    [[ "${1:-}" == "issue" && "${2:-}" == "view" ]] && return 0
    return 1
  }
  out_pr=$(claude-cleanup-worktree 168 2>&1)

  # 3) PR 인자, 비표준 headRefName — return 1 + 진단 메시지.
  gh() {
    if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
      printf 'feature/foo\n'; return 0
    fi
    [[ "${1:-}" == "issue" && "${2:-}" == "view" ]] && return 0
    return 1
  }
  out_pr_bad=$(claude-cleanup-worktree 200 2>&1); rc_bad=$?

  # 4) 이슈도 PR도 아님 — return 1 + 진단 메시지.
  gh() { return 1; }
  out_neither=$(claude-cleanup-worktree 9999 2>&1); rc_neither=$?

  printf '###issue###\n%s\n###pr###\n%s\n###pr_bad###\n%s\n[rc_bad=%d]\n###neither###\n%s\n[rc_neither=%d]\n' \
    "$out_issue" "$out_pr" "$out_pr_bad" "$rc_bad" "$out_neither" "$rc_neither"
)

case "$_cleanup_dispatch_probe" in
  *".claude/worktrees/issue-42"*) assert_eq "이슈 인자 → 그대로 이슈 번호 (회귀)" "ok" "ok" ;;
  *)                                assert_eq "이슈 인자 → 그대로 이슈 번호 (회귀)" "ok" "missing in: $_cleanup_dispatch_probe" ;;
esac

case "$_cleanup_dispatch_probe" in
  *"PR #168 → issue #115"*) assert_eq "PR 인자 → 이슈 번호 환산 안내" "ok" "ok" ;;
  *)                          assert_eq "PR 인자 → 이슈 번호 환산 안내" "ok" "missing in: $_cleanup_dispatch_probe" ;;
esac

case "$_cleanup_dispatch_probe" in
  *".claude/worktrees/issue-115"*) assert_eq "PR 인자 → issue-115 worktree 경로" "ok" "ok" ;;
  *)                                assert_eq "PR 인자 → issue-115 worktree 경로" "ok" "missing in: $_cleanup_dispatch_probe" ;;
esac

case "$_cleanup_dispatch_probe" in
  *"[rc_bad=1]"*) assert_eq "PR 비표준 브랜치 — return 1" "ok" "ok" ;;
  *)              assert_eq "PR 비표준 브랜치 — return 1" "ok" "missing in: $_cleanup_dispatch_probe" ;;
esac
case "$_cleanup_dispatch_probe" in
  *"issue-<N> 형식이 아닙니다"*) assert_eq "PR 비표준 브랜치 — 진단 메시지" "ok" "ok" ;;
  *)                              assert_eq "PR 비표준 브랜치 — 진단 메시지" "ok" "missing in: $_cleanup_dispatch_probe" ;;
esac

case "$_cleanup_dispatch_probe" in
  *"[rc_neither=1]"*) assert_eq "이슈도 PR도 아님 — return 1" "ok" "ok" ;;
  *)                   assert_eq "이슈도 PR도 아님 — return 1" "ok" "missing in: $_cleanup_dispatch_probe" ;;
esac
case "$_cleanup_dispatch_probe" in
  *"는 이슈도 PR도 아닙니다"*) assert_eq "이슈도 PR도 아님 — 진단 메시지" "ok" "ok" ;;
  *)                            assert_eq "이슈도 PR도 아님 — 진단 메시지" "ok" "missing in: $_cleanup_dispatch_probe" ;;
esac

unset _cleanup_dispatch_probe

echo ""
echo "── claude-cleanup-worktree: shgwt teardown 위임 (#144) ──"

# 워크트리 경로가 존재하면 본 함수는 worktree 제거를 직접 하지 않고
# `bash scripts/shgwt.sh teardown` 으로 위임해야 한다 (PR 머지 명령에서
# `--delete-branch` 가 빠진 후 정리 책임이 cleanup 단계로 옮겨왔다).
#
# 위임 자체를 검증하기 위해 mktemp 안에 가짜 worktree 디렉토리만 만들고
# git rev-parse --abbrev-ref 만 모킹한다. shgwt 는 별도 bash 프로세스로
# 실행되므로 셸 함수 mock 을 상속받지 않고 실제 git 을 호출 → mktemp 가
# git 저장소가 아니라 즉시 거부 → 본 함수는 "shgwt teardown 실패" 진단을
# 출력하고 return 1 해야 한다. 위임 호출이 빠지면 이 경로 자체가 실행되지
# 않아 진단 메시지가 누락된다.

_cleanup_delegate_probe=$(
  cd "$(mktemp -d)" || exit 1
  mkdir -p ".claude/worktrees/issue-555" || exit 1

  git() {
    case "${1:-} ${2:-}" in
      "rev-parse --abbrev-ref") printf 'main\n'; return 0 ;;
      *) return 0 ;;
    esac
  }
  gh() {
    [[ "${1:-}" == "pr" && "${2:-}" == "view" ]] && return 1
    [[ "${1:-}" == "issue" && "${2:-}" == "view" ]] && return 0
    return 1
  }

  out=$(claude-cleanup-worktree 555 2>&1); rc=$?
  printf '%s\n[rc=%d]\n' "$out" "$rc"
)

case "$_cleanup_delegate_probe" in
  *"shgwt teardown 실패"*) assert_eq "위임 실패 시 진단 메시지" "ok" "ok" ;;
  *)                       assert_eq "위임 실패 시 진단 메시지" "ok" "missing in: $_cleanup_delegate_probe" ;;
esac

case "$_cleanup_delegate_probe" in
  *"[rc=1]"*) assert_eq "위임 실패 시 return 1" "ok" "ok" ;;
  *)          assert_eq "위임 실패 시 return 1" "ok" "missing in: $_cleanup_delegate_probe" ;;
esac

case "$_cleanup_delegate_probe" in
  *"teardown --force"*) assert_eq "강제정리 안내 메시지" "ok" "ok" ;;
  *)                    assert_eq "강제정리 안내 메시지" "ok" "missing in: $_cleanup_delegate_probe" ;;
esac

unset _cleanup_delegate_probe

echo ""
echo "── _claude-lint-guard (#120) ──────────────────────────────"

# 제네릭화: git ls-files 로 셸 스크립트를 찾고, 있으면 shellcheck(있을 때)·있으면
# actionlint 를 best-effort 로 돈다. 셸 스크립트가 없거나 도구가 없으면 스킵(통과).
# git ls-files / command -v / shellcheck / actionlint 를 서브셸 mock 으로 격리한다.
_lint_guard_probe() {
  local mock_sh_files="$1"   # 1=git ls-files 가 .sh 1개 반환, 0=없음
  local mock_sc_present="$2" # mock: shellcheck 설치 여부
  local mock_sc_rc="$3"      # mock: shellcheck stub exit code
  local mock_al_present="$4" # mock: actionlint 설치 여부
  local mock_al_rc="$5"      # mock: actionlint stub exit code

  # NOTE: 서브셸이라 외부 함수 정의에 영향 없음.
  (
    git() {
      if [[ "${1:-}" == "ls-files" ]]; then
        [[ "$mock_sh_files" == 1 ]] && echo "scripts/example.sh"
        return 0
      fi
      builtin command git "$@"
    }
    command() {
      if [[ "${1:-}" == "-v" ]]; then
        case "${2:-}" in
          shellcheck) [[ "$mock_sc_present" == 1 ]] && { echo shellcheck; return 0; } || return 1 ;;
          actionlint) [[ "$mock_al_present" == 1 ]] && { echo actionlint; return 0; } || return 1 ;;
        esac
      fi
      builtin command "$@"
    }
    shellcheck() { return "$mock_sc_rc"; }
    actionlint() { return "$mock_al_rc"; }
    _claude-lint-guard >/dev/null 2>&1
    echo $?
  )
}

# 셸 스크립트 없음 → shellcheck 스킵 (도구 유무 무관), actionlint 없음 → 통과.
assert_eq "셸 스크립트 없음 → 통과" \
  "0" "$(_lint_guard_probe 0 0 0 0 0)"

# 셸 스크립트 있음 + shellcheck 미설치 → 경고 후 스킵(통과), 더 이상 fail-closed 아님.
assert_eq "셸 스크립트 있음 + shellcheck 미설치 → 통과(warn)" \
  "0" "$(_lint_guard_probe 1 0 0 0 0)"

# 셸 스크립트 있음 + shellcheck 위반 → 실패.
assert_eq "셸 스크립트 있음 + shellcheck 위반 → 실패" \
  "1" "$(_lint_guard_probe 1 1 1 0 0)"

# (shellcheck 통과) + actionlint 미설치 → 통과.
assert_eq "shellcheck 통과 + actionlint 미설치 → 통과" \
  "0" "$(_lint_guard_probe 1 1 0 0 0)"

# (shellcheck 통과) + actionlint 위반 → 실패.
assert_eq "shellcheck 통과 + actionlint 위반 → 실패" \
  "1" "$(_lint_guard_probe 1 1 0 1 1)"

# (shellcheck 통과) + actionlint 통과 → 통과.
assert_eq "shellcheck 통과 + actionlint 통과 → 통과" \
  "0" "$(_lint_guard_probe 1 1 0 1 0)"

unset -f _lint_guard_probe

echo ""
echo "── claude-audit-stacked-closes (#129) ────────────────────"

# detection-only 헬퍼 — 부모 PR 본문에 stacked 자식들의 `Closes` 가 모두
# 합산돼 있는지 검증. 누락만 stdout에 보고하고 실패 종료하지 않는다.
#
# Mock 전략: _claude-gh-retry 를 함수로 오버라이드해 두 호출 패턴만 분기.
#   - gh pr view <parent> --json headRefName,body  → $_AUDIT_PARENT_FILE 내용 출력
#   - gh pr list --base <head> --state all --json ... → $_AUDIT_CHILDREN_FILE 내용 출력
# 각 테스트 케이스 전에 두 파일을 새 fixture로 덮어써 시나리오를 격리한다.

_AUDIT_PARENT_FILE=$(mktemp)
_AUDIT_CHILDREN_FILE=$(mktemp)

_claude-gh-retry() {
  # 호출은 항상 `_claude-gh-retry gh pr <view|list> ...` 형태.
  if [[ "${2:-}" == "pr" && "${3:-}" == "view" ]]; then
    cat "$_AUDIT_PARENT_FILE"
    return 0
  fi
  if [[ "${2:-}" == "pr" && "${3:-}" == "list" ]]; then
    cat "$_AUDIT_CHILDREN_FILE"
    return 0
  fi
  return 1
}

# (a) 인자 없음 → return 1, 사용법 안내.
out=$(claude-audit-stacked-closes 2>&1)
rc=$?
assert_eq "audit: 인자 없음 — return 1" "1" "$rc"
case "$out" in
  *"사용법:"*) assert_eq "audit: 인자 없음 — 사용법" "ok" "ok" ;;
  *)           assert_eq "audit: 인자 없음 — 사용법" "ok" "missing: $out" ;;
esac

# (b) 비숫자 인자 → return 1.
out=$(claude-audit-stacked-closes abc 2>&1)
rc=$?
assert_eq "audit: 비숫자 인자 — return 1" "1" "$rc"

# (c) 자식 0개 → ✅ + return 0.
printf '{"headRefName":"feature-x","body":"## 관계\\n### Closes\\n- Closes #1"}' > "$_AUDIT_PARENT_FILE"
printf '[]' > "$_AUDIT_CHILDREN_FILE"
out=$(claude-audit-stacked-closes 100 2>&1)
rc=$?
assert_eq "audit: 자식 0개 — return 0" "0" "$rc"
case "$out" in
  *"stacked 자식 PR 없음"*) assert_eq "audit: 자식 0개 — ✅ 메시지" "ok" "ok" ;;
  *)                          assert_eq "audit: 자식 0개 — ✅ 메시지" "ok" "missing: $out" ;;
esac

# (d) 자식 1개, closingIssuesReferences로 #29 닫음, 부모에 합산 있음 → 누락 0.
printf '{"headRefName":"feature-x","body":"### Closes\\n- Closes #1\\n- Closes #29 (via stacked PR #200)\\n"}' > "$_AUDIT_PARENT_FILE"
printf '[{"number":200,"state":"MERGED","body":"Closes #29","closingIssuesReferences":[{"number":29}]}]' > "$_AUDIT_CHILDREN_FILE"
out=$(claude-audit-stacked-closes 100 2>&1)
rc=$?
assert_eq "audit: 합산 있음 — return 0" "0" "$rc"
case "$out" in
  *"missing closes"*) assert_eq "audit: 합산 있음 — 누락 보고 없음" "ok" "leaked: $out" ;;
  *)                  assert_eq "audit: 합산 있음 — 누락 보고 없음" "ok" "ok" ;;
esac

# (e) 자식 1개, closing #42 누락 → 한 줄 보고.
printf '{"headRefName":"feature-x","body":"### Closes\\n- Closes #1\\n"}' > "$_AUDIT_PARENT_FILE"
printf '[{"number":201,"state":"MERGED","body":"Closes #42","closingIssuesReferences":[{"number":42}]}]' > "$_AUDIT_CHILDREN_FILE"
out=$(claude-audit-stacked-closes 100 2>&1)
case "$out" in
  *"PR #100: missing closes for issue #42 from stacked PR #201"*)
    assert_eq "audit: 누락 검출 — 보고 줄" "ok" "ok" ;;
  *)
    assert_eq "audit: 누락 검출 — 보고 줄" "ok" "missing: $out" ;;
esac

# (f) closingIssuesReferences 비어 있고 본문 fallback (9종 keyword) — `Fixes #50`.
printf '{"headRefName":"feature-x","body":"### Closes\\n"}' > "$_AUDIT_PARENT_FILE"
printf '[{"number":202,"state":"OPEN","body":"Fixes #50 — bug","closingIssuesReferences":[]}]' > "$_AUDIT_CHILDREN_FILE"
out=$(claude-audit-stacked-closes 100 2>&1)
case "$out" in
  *"missing closes for issue #50 from stacked PR #202"*)
    assert_eq "audit: 본문 fallback (Fixes) — 검출" "ok" "ok" ;;
  *)
    assert_eq "audit: 본문 fallback (Fixes) — 검출" "ok" "missing: $out" ;;
esac

# (g) cross-repo 형태(`owner/repo#N`)는 무시 — 본문에 `foo/bar#99` 만 있을 때 검출 0.
printf '{"headRefName":"feature-x","body":"### Closes\\n"}' > "$_AUDIT_PARENT_FILE"
printf '[{"number":203,"state":"OPEN","body":"Closes foo/bar#99","closingIssuesReferences":[]}]' > "$_AUDIT_CHILDREN_FILE"
out=$(claude-audit-stacked-closes 100 2>&1)
case "$out" in
  *"missing closes"*) assert_eq "audit: cross-repo 무시" "ok" "leaked: $out" ;;
  *)                  assert_eq "audit: cross-repo 무시" "ok" "ok" ;;
esac

# (h) 다단 stack — 자식 본문에 `(via stacked PR #X)` 패턴 → 경고 + 합산 보류.
printf '{"headRefName":"feature-x","body":"### Closes\\n"}' > "$_AUDIT_PARENT_FILE"
printf '[{"number":204,"state":"MERGED","body":"Closes #60\\n- Closes #61 (via stacked PR #205)","closingIssuesReferences":[{"number":60}]}]' > "$_AUDIT_CHILDREN_FILE"
out=$(claude-audit-stacked-closes 100 2>&1)
case "$out" in
  *"다단 stack 패턴 검출"*) assert_eq "audit: 다단 stack — 경고" "ok" "ok" ;;
  *)                          assert_eq "audit: 다단 stack — 경고" "ok" "missing: $out" ;;
esac
case "$out" in
  *"missing closes for issue #60"*)
    assert_eq "audit: 다단 stack — 합산 보류" "ok" "leaked: $out" ;;
  *)
    assert_eq "audit: 다단 stack — 합산 보류" "ok" "ok" ;;
esac

# (i) 자식이 closing issue 없음 (refactor PR) → no-op, ✅.
printf '{"headRefName":"feature-x","body":"### Closes\\n"}' > "$_AUDIT_PARENT_FILE"
printf '[{"number":206,"state":"MERGED","body":"refactor: rename helper","closingIssuesReferences":[]}]' > "$_AUDIT_CHILDREN_FILE"
out=$(claude-audit-stacked-closes 100 2>&1)
rc=$?
assert_eq "audit: refactor 자식 — return 0" "0" "$rc"
case "$out" in
  *"missing closes"*) assert_eq "audit: refactor 자식 — no-op" "ok" "leaked: $out" ;;
  *)                  assert_eq "audit: refactor 자식 — no-op" "ok" "ok" ;;
esac

rm -f "$_AUDIT_PARENT_FILE" "$_AUDIT_CHILDREN_FILE"
unset -f _claude-gh-retry
unset _AUDIT_PARENT_FILE _AUDIT_CHILDREN_FILE
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

echo ""
echo "── claude-close-issue: stacked PR 4번째 인자 라우팅 (#186) ──"

# 3개 케이스: parent 없음 → main 경로 / parent OPEN → 부모 head 경로 / parent OPEN 아님 → 가드.
# git·gh 호출을 임시 파일에 기록해 어떤 인자로 호출됐는지 사후 검증.

_run_close_probe() {
  # $1: spy 출력을 모을 파일, $2: parent_pr 인자 ("" 또는 숫자), $3: 부모 PR state ("OPEN"/"CLOSED")
  # 변수명 _PROBE_*: bash dynamic scoping에서 claude-close-issue의 local 변수
  # (parent_state, parent_pr 등)와 충돌하지 않도록 prefix를 분리한다.
  local _PROBE_SPY="$1" _PROBE_PARENT="$2" _PROBE_STATE="$3"
  (
    claude-session-bound() { printf '777\n'; return 0; }
    bun() { return 0; }
    # jq는 .scripts.test 검사에서만 false를 돌려 테스트 가드를 스킵해야 한다.
    # 부모 PR 메타 파싱(jq -r)은 정상 동작해야 하므로 입력 패턴으로 분기.
    jq() {
      case "$*" in
        *".scripts.test"*) return 1 ;;
      esac
      command jq "$@"
    }
    git() {
      printf 'git %s\n' "$*" >> "$_PROBE_SPY"
      return 0
    }
    gh() {
      printf 'gh %s\n' "$*" >> "$_PROBE_SPY"
      case "${1:-}" in
        pr)
          case "${2:-}" in
            view)
              # 부모 PR 메타데이터: state는 가변, headRefName은 고정.
              printf '{"headRefName":"issue-34-foo","state":"%s"}\n' "$_PROBE_STATE"
              return 0
              ;;
            create)
              # --body-file 은 create 직후 삭제되는 임시 파일 — 호출 시점에 본문을
              # spy 로 복사해 본문 키워드 어서션을 유지한다 (#1486 body-file 전환).
              local _a _prev=""
              for _a in "$@"; do
                if [[ "$_prev" == "--body-file" ]]; then
                  cat "$_a" >> "$_PROBE_SPY" 2>/dev/null
                fi
                _prev="$_a"
              done
              # claude-close-issue가 기대하는 stdout: PR URL 한 줄.
              printf 'https://github.com/example-org/example-repo/pull/9999\n'
              return 0
              ;;
          esac
          ;;
      esac
      return 0
    }
    claude-set-pr-status() { printf 'set-pr-status %s\n' "$*" >> "$_PROBE_SPY"; }

    if [[ -n "$_PROBE_PARENT" ]]; then
      claude-close-issue 777 feat "stacked test" "$_PROBE_PARENT" >/dev/null 2>&1
    else
      claude-close-issue 777 feat "main test" >/dev/null 2>&1
    fi
    printf '%d\n' "$?" >> "$_PROBE_SPY"
  )
}

# Case 1: parent 없음 → 기존 main 경로.
#   - 부모 PR 메타(--json headRefName,state) 미조회 — 라벨 함수의 `gh pr view
#     <pr#> --json body` 는 별개 호출이라 메타 시그니처로 좁혀 검증한다 (#1486)
#   - git fetch/rebase 대상이 origin/main
#   - gh pr create에 --base main 명시 (#1486 wrapper 는 base 를 항상 전달)
#   - PR 본문에 Depends on 미포함
_spy=$(mktemp)
_run_close_probe "$_spy" "" "OPEN"
_log=$(cat "$_spy")

case "$_log" in
  *"--json headRefName,state"*) assert_eq "main 경로 — 부모 PR 메타 미조회" "ok" "leaked: $_log" ;;
  *)                             assert_eq "main 경로 — 부모 PR 메타 미조회" "ok" "ok" ;;
esac
case "$_log" in
  *"git fetch origin main"*) assert_eq "main 경로 — git fetch origin main" "ok" "ok" ;;
  *)                          assert_eq "main 경로 — git fetch origin main" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"git rebase origin/main"*) assert_eq "main 경로 — git rebase origin/main" "ok" "ok" ;;
  *)                            assert_eq "main 경로 — git rebase origin/main" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"--base main"*) assert_eq "main 경로 — gh pr create --base main 명시 (#1486)" "ok" "ok" ;;
  *)               assert_eq "main 경로 — gh pr create --base main 명시 (#1486)" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"Depends on"*) assert_eq "main 경로 — body에 Depends on 미포함" "ok" "leaked: $_log" ;;
  *)              assert_eq "main 경로 — body에 Depends on 미포함" "ok" "ok" ;;
esac
rm -f "$_spy"

# Case 2: parent OPEN → 부모 head 경로.
#   - gh pr view 121 호출 (부모 메타 조회)
#   - git fetch/rebase 대상이 origin/issue-34-foo
#   - gh pr create에 --base issue-34-foo 포함
#   - PR 본문에 Depends on #121 포함
_spy=$(mktemp)
_run_close_probe "$_spy" "121" "OPEN"
_log=$(cat "$_spy")

case "$_log" in
  *"gh pr view 121"*) assert_eq "stacked — gh pr view 121 호출" "ok" "ok" ;;
  *)                   assert_eq "stacked — gh pr view 121 호출" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"git fetch origin issue-34-foo"*) assert_eq "stacked — git fetch origin issue-34-foo" "ok" "ok" ;;
  *)                                    assert_eq "stacked — git fetch origin issue-34-foo" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"git rebase origin/issue-34-foo"*) assert_eq "stacked — git rebase origin/issue-34-foo" "ok" "ok" ;;
  *)                                    assert_eq "stacked — git rebase origin/issue-34-foo" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"--base issue-34-foo"*) assert_eq "stacked — gh pr create --base issue-34-foo" "ok" "ok" ;;
  *)                         assert_eq "stacked — gh pr create --base issue-34-foo" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"Depends on #121"*) assert_eq "stacked — body에 Depends on #121 포함" "ok" "ok" ;;
  *)                    assert_eq "stacked — body에 Depends on #121 포함" "ok" "missing: $_log" ;;
esac
rm -f "$_spy"

# Case 3: parent state != OPEN → 가드 fail, gh pr create 절대 호출되지 않음.
_spy=$(mktemp)
_run_close_probe "$_spy" "121" "CLOSED"
_log=$(cat "$_spy")
_rc=$(printf '%s\n' "$_log" | tail -n 1)

assert_eq "stacked CLOSED — return 1" "1" "$_rc"
case "$_log" in
  *"gh pr create"*) assert_eq "stacked CLOSED — gh pr create 미호출" "ok" "leaked: $_log" ;;
  *)                 assert_eq "stacked CLOSED — gh pr create 미호출" "ok" "ok" ;;
esac
case "$_log" in
  *"git commit"*) assert_eq "stacked CLOSED — git commit 미진행" "ok" "leaked: $_log" ;;
  *)              assert_eq "stacked CLOSED — git commit 미진행" "ok" "ok" ;;
esac
rm -f "$_spy"

# Case 4: parent_pr이 비숫자 → 즉시 가드 fail.
_spy=$(mktemp)
_run_close_probe "$_spy" "abc" "OPEN"
_log=$(cat "$_spy")
_rc=$(printf '%s\n' "$_log" | tail -n 1)
assert_eq "비숫자 parent — return 1" "1" "$_rc"
case "$_log" in
  *"gh pr view"*) assert_eq "비숫자 parent — gh pr view 미호출" "ok" "leaked: $_log" ;;
  *)              assert_eq "비숫자 parent — gh pr view 미호출" "ok" "ok" ;;
esac
rm -f "$_spy"

unset -f _run_close_probe

echo ""
echo "── claude-enter-issue: stacked PR 진입 parent 라우팅 (#333) ──"

# 5개 케이스: parent 없음 → main 경로 / parent OPEN → 부모 head 경로 /
# parent 숫자 CLOSED → 가드 / parent 브랜치 존재 → 브랜치 경로 /
# parent 브랜치 미존재 → 가드. claude-close-issue 의 stacked 4번째 인자(#186)
# 검증과 짝을 이루며, mutation(self-assign·worktree 생성) 진입 전에 모든
# 검증이 끝나는지를 확인한다.

_run_enter_probe() {
  # $1: spy 출력 파일, $2: parent 인자 (""·숫자·브랜치명),
  # $3: 부모 PR state ("OPEN"/"CLOSED"·숫자 케이스에서만 의미),
  # $4: ls-remote 시 부모 브랜치 존재 여부 ("1"=존재, ""=없음·문자열 케이스에서만).
  local _PROBE_SPY="$1" _PROBE_PARENT="$2" _PROBE_STATE="$3" _PROBE_BRANCH_EXISTS="$4"
  (
    # 가드 통과를 위한 스텁: 세션 미바인딩, main 브랜치 위치.
    claude-session-bound() { return 1; }
    # mkdir 은 실제 fs 변형이 일어나지 않도록 차단.
    mkdir() { printf 'mkdir %s\n' "$*" >> "$_PROBE_SPY"; return 0; }

    git() {
      printf 'git %s\n' "$*" >> "$_PROBE_SPY"
      case "${1:-}" in
        rev-parse)
          # `git rev-parse --abbrev-ref HEAD` → main 브랜치 가드 통과.
          if [[ "${2:-}" == "--abbrev-ref" && "${3:-}" == "HEAD" ]]; then
            printf 'main\n'
            return 0
          fi
          return 0
          ;;
        ls-remote)
          # 두 가지 호출을 인자 개수로 구분:
          #   - 이슈 브랜치 충돌 스캔: `ls-remote --heads origin`         ($#=3)
          #   - 부모 브랜치 존재 확인:  `ls-remote --heads origin <name>` ($#=4)
          if [[ "$#" -ge 4 ]]; then
            if [[ "$_PROBE_BRANCH_EXISTS" == "1" ]]; then
              printf 'abc123\trefs/heads/%s\n' "${4}"
            fi
            return 0
          fi
          return 0
          ;;
        worktree|fetch) return 0 ;;
      esac
      return 0
    }

    gh() {
      printf 'gh %s\n' "$*" >> "$_PROBE_SPY"
      case "${1:-}" in
        api)
          # `gh api user --jq .login` 만 사용됨.
          if [[ "${2:-}" == "user" ]]; then
            printf 'tester\n'
            return 0
          fi
          return 0
          ;;
        issue)
          if [[ "${2:-}" == "view" ]]; then
            printf '{"assignees":[],"title":"feat: probe"}\n'
            return 0
          fi
          # `gh issue edit ... --add-assignee @me` — mutation 발생 신호.
          return 0
          ;;
        pr)
          if [[ "${2:-}" == "view" ]]; then
            printf '{"headRefName":"issue-34-foo","state":"%s"}\n' "$_PROBE_STATE"
            return 0
          fi
          ;;
      esac
      return 0
    }

    if [[ -n "$_PROBE_PARENT" ]]; then
      claude-enter-issue 777 "$_PROBE_PARENT" >/dev/null 2>&1
    else
      claude-enter-issue 777 >/dev/null 2>&1
    fi
    printf '%d\n' "$?" >> "$_PROBE_SPY"
  )
}

# Case 1: parent 없음 → 기존 main 경로.
#   - gh pr view 미호출 (부모 검증 없음)
#   - ls-remote 부모 브랜치 검증 미호출
#   - git fetch / worktree add 대상이 origin/main
_spy=$(mktemp)
_run_enter_probe "$_spy" "" "OPEN" ""
_log=$(cat "$_spy")
case "$_log" in
  *"gh pr view"*) assert_eq "enter main 경로 — gh pr view 미호출" "ok" "leaked: $_log" ;;
  *)              assert_eq "enter main 경로 — gh pr view 미호출" "ok" "ok" ;;
esac
case "$_log" in
  *"git fetch origin main"*) assert_eq "enter main 경로 — git fetch origin main" "ok" "ok" ;;
  *)                          assert_eq "enter main 경로 — git fetch origin main" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"worktree add"*"origin/main"*) assert_eq "enter main 경로 — worktree add origin/main" "ok" "ok" ;;
  *)                                assert_eq "enter main 경로 — worktree add origin/main" "ok" "missing: $_log" ;;
esac
rm -f "$_spy"

# Case 2: parent 숫자 OPEN → 부모 PR head 경로.
#   - gh pr view 121 호출
#   - git fetch / worktree add 대상이 origin/issue-34-foo
_spy=$(mktemp)
_run_enter_probe "$_spy" "121" "OPEN" ""
_log=$(cat "$_spy")
case "$_log" in
  *"gh pr view 121"*) assert_eq "enter stacked PR — gh pr view 121 호출" "ok" "ok" ;;
  *)                   assert_eq "enter stacked PR — gh pr view 121 호출" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"git fetch origin issue-34-foo"*) assert_eq "enter stacked PR — git fetch origin issue-34-foo" "ok" "ok" ;;
  *)                                    assert_eq "enter stacked PR — git fetch origin issue-34-foo" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"worktree add"*"origin/issue-34-foo"*) assert_eq "enter stacked PR — worktree add origin/issue-34-foo" "ok" "ok" ;;
  *)                                        assert_eq "enter stacked PR — worktree add origin/issue-34-foo" "ok" "missing: $_log" ;;
esac
rm -f "$_spy"

# Case 3: parent 숫자 CLOSED → 가드 fail.
#   - gh issue edit (self-assign), git worktree add 모두 미진행
_spy=$(mktemp)
_run_enter_probe "$_spy" "121" "CLOSED" ""
_log=$(cat "$_spy")
_rc=$(printf '%s\n' "$_log" | tail -n 1)
assert_eq "enter stacked CLOSED — return 1" "1" "$_rc"
case "$_log" in
  *"gh issue edit"*) assert_eq "enter stacked CLOSED — self-assign 미호출" "ok" "leaked: $_log" ;;
  *)                  assert_eq "enter stacked CLOSED — self-assign 미호출" "ok" "ok" ;;
esac
case "$_log" in
  *"git worktree add"*) assert_eq "enter stacked CLOSED — worktree add 미호출" "ok" "leaked: $_log" ;;
  *)                     assert_eq "enter stacked CLOSED — worktree add 미호출" "ok" "ok" ;;
esac
rm -f "$_spy"

# Case 4: parent 브랜치 존재 → 부모 브랜치 경로.
#   - ls-remote 로 브랜치 확인
#   - git fetch / worktree add 대상이 origin/feature-x
_spy=$(mktemp)
_run_enter_probe "$_spy" "feature-x" "" "1"
_log=$(cat "$_spy")
case "$_log" in
  *"git ls-remote --heads origin feature-x"*) assert_eq "enter stacked branch — ls-remote 호출" "ok" "ok" ;;
  *)                                            assert_eq "enter stacked branch — ls-remote 호출" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"git fetch origin feature-x"*) assert_eq "enter stacked branch — git fetch origin feature-x" "ok" "ok" ;;
  *)                                assert_eq "enter stacked branch — git fetch origin feature-x" "ok" "missing: $_log" ;;
esac
case "$_log" in
  *"worktree add"*"origin/feature-x"*) assert_eq "enter stacked branch — worktree add origin/feature-x" "ok" "ok" ;;
  *)                                     assert_eq "enter stacked branch — worktree add origin/feature-x" "ok" "missing: $_log" ;;
esac
rm -f "$_spy"

# Case 5: parent 브랜치 미존재 → 가드 fail.
#   - gh pr view 미호출 (비숫자라 PR 경로 미진입)
#   - gh issue edit (self-assign), git worktree add 모두 미진행
_spy=$(mktemp)
_run_enter_probe "$_spy" "missing-branch" "" ""
_log=$(cat "$_spy")
_rc=$(printf '%s\n' "$_log" | tail -n 1)
assert_eq "enter stacked branch missing — return 1" "1" "$_rc"
case "$_log" in
  *"gh pr view"*) assert_eq "enter stacked branch missing — gh pr view 미호출" "ok" "leaked: $_log" ;;
  *)              assert_eq "enter stacked branch missing — gh pr view 미호출" "ok" "ok" ;;
esac
case "$_log" in
  *"gh issue edit"*) assert_eq "enter stacked branch missing — self-assign 미호출" "ok" "leaked: $_log" ;;
  *)                  assert_eq "enter stacked branch missing — self-assign 미호출" "ok" "ok" ;;
esac
case "$_log" in
  *"git worktree add"*) assert_eq "enter stacked branch missing — worktree add 미호출" "ok" "leaked: $_log" ;;
  *)                     assert_eq "enter stacked branch missing — worktree add 미호출" "ok" "ok" ;;
esac
rm -f "$_spy"

unset -f _run_enter_probe

echo ""
echo "── claude-audit-builtin-workflows (#12, #252, #1000) ─────────────"

# 감사 대상 빌트인 두 건 — 둘 다 PR/Issue 트랙 정책을 깨는 GitHub 빌트인이다:
#   1) "Pull request linked to issue" (#252) — PR↔Issue 양방향 status 복사
#   2) "Code changes requested"        (#1000) — CHANGES_REQUESTED 리뷰 시
#                                                PR 을 In progress 로 자동 이동 (#538 위반)
# UI 비활성화가 운영 정책이고, 이 헬퍼는 enabled 시 stderr soft warn 만 담당.

# Case 1: 두 빌트인 모두 enabled=true → 두 경고 출력
_claude-gh-retry() {
  printf '%s' '{"data":{"organization":{"projectV2":{"workflows":{"nodes":[
    {"name":"Pull request linked to issue","enabled":true},
    {"name":"Code changes requested","enabled":true},
    {"name":"Auto-add to project","enabled":true}
  ]}}}}}'
}
out=$(claude-audit-builtin-workflows 2>&1 >/dev/null)
case "$out" in
  *"Pull request linked to issue"*"활성"*) assert_eq "Case1 — 'Pull request linked to issue' 경고" "ok" "ok" ;;
  *)                                         assert_eq "Case1 — 'Pull request linked to issue' 경고" "ok" "missing: $out" ;;
esac
case "$out" in
  *"Code changes requested"*"활성"*) assert_eq "Case1 — 'Code changes requested' 경고" "ok" "ok" ;;
  *)                                   assert_eq "Case1 — 'Code changes requested' 경고" "ok" "missing: $out" ;;
esac
case "$out" in
  *"비활성화"*) assert_eq "Case1 — 경고에 비활성화 안내 포함" "ok" "ok" ;;
  *)            assert_eq "Case1 — 경고에 비활성화 안내 포함" "ok" "missing: $out" ;;
esac

# Case 1-b: 회귀 trigger 만 enabled → 해당 경고 하나만 (#1000)
_claude-gh-retry() {
  printf '%s' '{"data":{"organization":{"projectV2":{"workflows":{"nodes":[
    {"name":"Pull request linked to issue","enabled":false},
    {"name":"Code changes requested","enabled":true}
  ]}}}}}'
}
out=$(claude-audit-builtin-workflows 2>&1 >/dev/null)
case "$out" in
  *"Code changes requested"*"활성"*) assert_eq "Case1-b — 'Code changes requested' 만 enabled" "ok" "ok" ;;
  *)                                   assert_eq "Case1-b — 'Code changes requested' 만 enabled" "ok" "missing: $out" ;;
esac
case "$out" in
  *"Pull request linked to issue"*) assert_eq "Case1-b — 'Pull request linked to issue' 경고 없음" "ok" "leaked: $out" ;;
  *)                                  assert_eq "Case1-b — 'Pull request linked to issue' 경고 없음" "ok" "ok" ;;
esac

# Case 2: 두 빌트인 모두 enabled=false → 무음
_claude-gh-retry() {
  printf '%s' '{"data":{"organization":{"projectV2":{"workflows":{"nodes":[
    {"name":"Pull request linked to issue","enabled":false},
    {"name":"Code changes requested","enabled":false}
  ]}}}}}'
}
out=$(claude-audit-builtin-workflows 2>&1)
assert_eq "Case2 — 두 빌트인 모두 disabled → 무음" "" "$out"

# Case 3: 워크플로우 응답이 빈 배열 → 무음 (jq optional iteration 가드)
_claude-gh-retry() {
  printf '%s' '{"data":{"organization":{"projectV2":{"workflows":{"nodes":[]}}}}}'
}
out=$(claude-audit-builtin-workflows 2>&1)
assert_eq "Case3 — 워크플로우 부재 → 무음" "" "$out"

unset -f _claude-gh-retry
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

# Case 4: 정적 회귀 가드 — claude-close-issue 본문에 호출이 살아있는지.
# #34 가 같은 호출을 한 번 잘못 제거한 적이 있다 (#252).
if grep -q -E '^[[:space:]]+claude-audit-builtin-workflows([[:space:]]|$)' "${SCRIPT_DIR}/github-workflow.sh"; then
  PASS=$((PASS + 1))
  printf '  ✅ %s\n' "claude-close-issue 가 claude-audit-builtin-workflows 를 호출"
else
  FAIL=$((FAIL + 1))
  printf '  ❌ %s\n' "claude-audit-builtin-workflows 호출이 사라짐 (#252 회귀)"
fi

echo ""
echo "── #269: claude-pr-merge fail-closed 가드 ─────────────────"

# claude-pr-merge 는 두 조건 (reviewDecision==APPROVED + 보드 Status==Approved)
# 모두 통과한 경우에만 `gh pr merge` 위임을 한다. 어느 한 가드라도 실패하면
# 머지 호출 자체가 발생하지 않아야 한다. 본 블록에서는 _claude-gh-retry /
# _claude-content-node-id / claude-verify-content-status 를 mock 으로 갈아
# 4개 시나리오를 검증한다.

# 머지 위임이 발생했는지 추적하기 위한 sentinel.
MERGE_CALL_FILE=$(mktemp)
export MERGE_CALL_FILE

# `gh pr merge` 호출만 sentinel 파일에 기록하고 그 외 `gh pr view` 는
# reviewDecision mock 으로 처리한다. 호출자가 _claude-gh-retry 를 한 번만
# 거치므로 여기서 분기하면 두 경로 모두 mock 가능.
_claude-content-node-id() {
  printf 'mock-pr-node-%s\n' "$2"
}

# Case A: reviewDecision=APPROVED + 보드=Approved → 머지 위임 발생.
echo 0 > "$MERGE_CALL_FILE"
_claude-gh-retry() {
  case "$*" in
    *"gh pr view"*"reviewDecision"*) printf 'APPROVED\n' ;;
    *"gh pr merge"*) echo 1 > "$MERGE_CALL_FILE"; printf 'merged\n' ;;
    *) "$@" ;;
  esac
}
claude-verify-content-status() { return 0; }
out=$(claude-pr-merge 269 2>&1)
rc=$?
assert_eq "APPROVED + 보드=Approved → return 0" "0" "$rc"
assert_eq "APPROVED + 보드=Approved → 머지 위임 발생" "1" "$(cat "$MERGE_CALL_FILE")"

# Case B: reviewDecision=REVIEW_REQUIRED → 머지 위임 미발생.
echo 0 > "$MERGE_CALL_FILE"
_claude-gh-retry() {
  case "$*" in
    *"gh pr view"*"reviewDecision"*) printf 'REVIEW_REQUIRED\n' ;;
    *"gh pr merge"*) echo 1 > "$MERGE_CALL_FILE"; printf 'merged\n' ;;
    *) "$@" ;;
  esac
}
claude-verify-content-status() { return 0; }
out=$(claude-pr-merge 269 2>&1)
rc=$?
assert_eq "REVIEW_REQUIRED → return 1 (차단)" "1" "$rc"
assert_eq "REVIEW_REQUIRED → 머지 위임 미발생" "0" "$(cat "$MERGE_CALL_FILE")"
case "$out" in
  *"reviewDecision='REVIEW_REQUIRED'"*) assert_eq "차단 메시지에 reviewDecision 포함" "ok" "ok" ;;
  *)                                      assert_eq "차단 메시지에 reviewDecision 포함" "ok" "missing: $out" ;;
esac

# Case C: reviewDecision=CHANGES_REQUESTED → 머지 위임 미발생.
echo 0 > "$MERGE_CALL_FILE"
_claude-gh-retry() {
  case "$*" in
    *"gh pr view"*"reviewDecision"*) printf 'CHANGES_REQUESTED\n' ;;
    *"gh pr merge"*) echo 1 > "$MERGE_CALL_FILE"; printf 'merged\n' ;;
    *) "$@" ;;
  esac
}
claude-verify-content-status() { return 0; }
out=$(claude-pr-merge 269 2>&1)
rc=$?
assert_eq "CHANGES_REQUESTED → return 1 (차단)" "1" "$rc"
assert_eq "CHANGES_REQUESTED → 머지 위임 미발생" "0" "$(cat "$MERGE_CALL_FILE")"

# Case D: reviewDecision=APPROVED 인데 보드 Status != Approved → 머지 차단.
# (예: 빌트인 워크플로우가 카드를 Approved 컬럼으로 옮기지 않은 경우.)
echo 0 > "$MERGE_CALL_FILE"
_claude-gh-retry() {
  case "$*" in
    *"gh pr view"*"reviewDecision"*) printf 'APPROVED\n' ;;
    *"gh pr merge"*) echo 1 > "$MERGE_CALL_FILE"; printf 'merged\n' ;;
    *) "$@" ;;
  esac
}
claude-verify-content-status() { return 1; }
out=$(claude-pr-merge 269 2>&1)
rc=$?
assert_eq "APPROVED + 보드 != Approved → return 1 (차단)" "1" "$rc"
assert_eq "APPROVED + 보드 != Approved → 머지 위임 미발생" "0" "$(cat "$MERGE_CALL_FILE")"
case "$out" in
  *"보드 Status != 'Approved'"*) assert_eq "차단 메시지에 보드 불일치 표시" "ok" "ok" ;;
  *)                                assert_eq "차단 메시지에 보드 불일치 표시" "ok" "missing: $out" ;;
esac

# Case E: reviewDecision 조회 실패 → fail-closed.
echo 0 > "$MERGE_CALL_FILE"
_claude-gh-retry() {
  case "$*" in
    *"gh pr view"*"reviewDecision"*) return 1 ;;
    *"gh pr merge"*) echo 1 > "$MERGE_CALL_FILE"; printf 'merged\n' ;;
    *) "$@" ;;
  esac
}
claude-verify-content-status() { return 0; }
out=$(claude-pr-merge 269 2>&1)
rc=$?
assert_eq "reviewDecision 조회 실패 → return 1 (fail-closed)" "1" "$rc"
assert_eq "reviewDecision 조회 실패 → 머지 위임 미발생" "0" "$(cat "$MERGE_CALL_FILE")"

# Case F: 인자 누락 → return 1.
out=$(claude-pr-merge 2>&1)
rc=$?
assert_eq "인자 누락 → return 1" "1" "$rc"

rm -f "$MERGE_CALL_FILE"
unset -f _claude-gh-retry _claude-content-node-id claude-verify-content-status
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

echo ""
echo "── _claude-check-blocked-labels (#233) ────────────────────"

# 보류 라벨 가드 — labels JSON 만 인자로 받는 순수 함수라 mock 없이 검증 가능.
# CLAUDE_BLOCKED_LABELS 배열의 라벨이 매치되면 stderr + return 1, 아니면 return 0.

# Case 1: 보류 라벨 매치 → return 1, stderr 안내 메시지 포함.
out=$(_claude-check-blocked-labels \
  '[{"name":"enhancement"},{"name":"보류"}]' 187 2>&1 >/dev/null)
rc=$?
assert_eq "보류 라벨 매치 → return 1" "1" "$rc"
case "$out" in
  *"187"*"보류"*"refuses to start"*) assert_eq "stderr 안내 메시지 포함" "ok" "ok" ;;
  *) assert_eq "stderr 안내 메시지 포함" "ok" "missing: $out" ;;
esac
case "$out" in
  *'claude-unhold-issue 187'*)
    assert_eq "라벨 제거 명령 안내 — claude-unhold-issue (#597)" "ok" "ok" ;;
  *)
    assert_eq "라벨 제거 명령 안내 — claude-unhold-issue (#597)" "ok" "missing: $out" ;;
esac
# #597 회귀 가드 — `gh issue edit --remove-label` silent-fail 패턴 재발 방지.
case "$out" in
  *"--remove-label"*)
    assert_eq "안내에 --remove-label 미포함 (#597 회귀 가드)" "absent" "present: $out" ;;
  *)
    assert_eq "안내에 --remove-label 미포함 (#597 회귀 가드)" "absent" "absent" ;;
esac

# Case 2: 보류 라벨 부재 → return 0, 출력 없음 (regression baseline).
out=$(_claude-check-blocked-labels \
  '[{"name":"enhancement"},{"name":"⚡ High"}]' 100 2>&1)
rc=$?
assert_eq "보류 라벨 부재 → return 0" "0" "$rc"
assert_eq "보류 라벨 부재 → 출력 없음" "" "$out"

# Case 3: 빈 라벨 배열 → return 0.
out=$(_claude-check-blocked-labels '[]' 42 2>&1)
rc=$?
assert_eq "빈 라벨 배열 → return 0" "0" "$rc"
assert_eq "빈 라벨 배열 → 출력 없음" "" "$out"

# Case 4: 부분 일치는 차단하지 않음 — "보류중" 같은 다른 라벨이 부착돼도
# CLAUDE_BLOCKED_LABELS 의 정확 일치(grep -Fxq)만 차단해야 한다.
out=$(_claude-check-blocked-labels \
  '[{"name":"보류중"},{"name":"보류 검토"}]' 50 2>&1)
rc=$?
assert_eq "부분 일치 라벨 → 차단 안 함" "0" "$rc"

# Case 5: 다국어 확장 시뮬레이션 — CLAUDE_BLOCKED_LABELS 에 항목 추가 시
# 새 라벨도 차단되는지. (서브셸에서 격리.)
# shellcheck disable=SC2034
# 함수 _claude-check-blocked-labels 가 동적으로 참조하므로 정적 분석에는 unused 로 보인다.
rc=$(
  CLAUDE_BLOCKED_LABELS=("보류" "on-hold")
  _claude-check-blocked-labels '[{"name":"on-hold"}]' 99 >/dev/null 2>&1
  echo $?
)
assert_eq "확장된 BLOCKED_LABELS 에 새 라벨 추가 → 차단" "1" "$rc"

# Case 6: 잘못된 JSON → 조용히 통과 (jq 실패 시 라벨 없음으로 간주).
# 라벨 가드 자체가 fail-open 인 이유: GitHub API 응답 변형/네트워크 잡음으로
# 정상 이슈가 차단되는 사고를 막기 위함. 보류 라벨이 실수로 떼였을 때만 위험하고,
# 그건 라벨 운용 자체의 문제이지 가드의 책임은 아니다.
out=$(_claude-check-blocked-labels 'not-json' 1 2>&1)
rc=$?
assert_eq "잘못된 JSON → return 0 (fail-open)" "0" "$rc"

# 정적 회귀 가드 — claude-enter-issue 본문이 _claude-check-blocked-labels 를
# 호출하는지. 함수가 살아 있어도 호출이 빠지면 가드 효과 0.
if grep -q -E '_claude-check-blocked-labels[[:space:]]+"\$labels_json"' "${SCRIPT_DIR}/github-workflow.sh"; then
  PASS=$((PASS + 1))
  printf '  ✅ %s\n' "claude-enter-issue 가 _claude-check-blocked-labels 를 호출"
else
  FAIL=$((FAIL + 1))
  printf '  ❌ %s\n' "claude-enter-issue 에서 보류 라벨 가드 호출이 사라짐 (#233 회귀)"
fi

# 정적 회귀 가드 — gh issue view 가 labels 필드를 가져오는지. labels 없이
# jq 로 .labels 를 추출하면 빈 배열이 돼 가드가 작동하지 않는다.
if grep -q -E "gh issue view .* --json assignees,title,labels" "${SCRIPT_DIR}/github-workflow.sh"; then
  PASS=$((PASS + 1))
  printf '  ✅ %s\n' "claude-enter-issue 가 labels 필드를 fetch"
else
  FAIL=$((FAIL + 1))
  printf '  ❌ %s\n' "claude-enter-issue 가 labels 필드를 fetch 하지 않음 (#233 회귀)"
fi

echo ""
echo "── #1471: claude-unhold-issue ─────────────────────────────"

# 인자 검증 — gh 호출 없이 즉시 fail.
out=$(claude-unhold-issue 2>&1)
rc=$?
assert_eq "claude-unhold-issue — 인자 없음 → return 1" "1" "$rc"
case "$out" in *"사용법: claude-unhold-issue"*)
  assert_eq "claude-unhold-issue — 사용법 stderr 노출" "ok" "ok" ;;
*)
  assert_eq "claude-unhold-issue — 사용법 stderr 노출" "ok" "missing: $out" ;;
esac

out=$(claude-unhold-issue abc 2>&1)
rc=$?
assert_eq "claude-unhold-issue — 비숫자 → return 1" "1" "$rc"

# 라벨 부착됨 → DELETE 성공. issue view 가 '보류' 를 반환하도록 mock (pre-check 통과).
out=$(
  _claude-gh-retry() {
    case "$*" in
      *"repo view"*) printf 'owner/repo'; return 0 ;;
      *"issue view"*) printf '보류\n'; return 0 ;;
      *) return 0 ;;
    esac
  }
  claude-unhold-issue 187 2>&1
)
rc=$?
assert_eq "claude-unhold-issue — 라벨 제거 성공 → return 0" "0" "$rc"
case "$out" in *"'보류' 라벨 제거"*)
  assert_eq "claude-unhold-issue — 제거 ✅ 메시지" "ok" "ok" ;;
*)
  assert_eq "claude-unhold-issue — 제거 ✅ 메시지" "ok" "missing: $out" ;;
esac

# 라벨 미부착(pre-check) → DELETE 호출 없이 idempotent return 0, "없습니다" 안내.
# DELETE mock 이 호출되면 의도와 다르므로 명시적으로 실패시켜 회귀를 잡는다.
out=$(
  _claude-gh-retry() {
    case "$*" in
      *"repo view"*) printf 'owner/repo'; return 0 ;;
      *"issue view"*) printf 'enhancement\n'; return 0 ;;
      *"-X DELETE"*) echo "DELETE 호출되면 안 됨" >&2; return 1 ;;
      *) return 0 ;;
    esac
  }
  claude-unhold-issue 187 2>&1
)
rc=$?
assert_eq "claude-unhold-issue — 라벨 미부착 → DELETE 생략·return 0" "0" "$rc"
case "$out" in *"제거할 보류 라벨이 없습니다"*)
  assert_eq "claude-unhold-issue — 미부착 시 이미 해제 안내" "ok" "ok" ;;
*)
  assert_eq "claude-unhold-issue — 미부착 시 이미 해제 안내" "ok" "missing: $out" ;;
esac

# TOCTOU 레이스 — 조회 시점엔 '보류' 가 있었으나 DELETE 가 404 → idempotent return 0.
out=$(
  _claude-gh-retry() {
    case "$*" in
      *"repo view"*) printf 'owner/repo'; return 0 ;;
      *"issue view"*) printf '보류\n'; return 0 ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
    esac
  }
  claude-unhold-issue 187 2>&1
)
rc=$?
assert_eq "claude-unhold-issue — DELETE 404 레이스 → idempotent return 0" "0" "$rc"

# 비404 실패 (예: 500) → fail-closed return 1.
out=$(
  _claude-gh-retry() {
    case "$*" in
      *"repo view"*) printf 'owner/repo'; return 0 ;;
      *"issue view"*) printf '보류\n'; return 0 ;;
      *) echo "gh: Server Error (HTTP 500)" >&2; return 1 ;;
    esac
  }
  claude-unhold-issue 187 2>&1
)
rc=$?
assert_eq "claude-unhold-issue — 비404 실패 → return 1" "1" "$rc"

# repo 조회 실패 → return 1.
out=$(
  _claude-gh-retry() {
    case "$*" in
      *"repo view"*) return 1 ;;
      *) return 0 ;;
    esac
  }
  claude-unhold-issue 187 2>&1
)
rc=$?
assert_eq "claude-unhold-issue — repo 조회 실패 → return 1" "1" "$rc"

# 라벨 조회(issue view) 실패 → return 1.
out=$(
  _claude-gh-retry() {
    case "$*" in
      *"repo view"*) printf 'owner/repo'; return 0 ;;
      *"issue view"*) echo "gh: Server Error (HTTP 500)" >&2; return 1 ;;
      *) return 0 ;;
    esac
  }
  claude-unhold-issue 187 2>&1
)
rc=$?
assert_eq "claude-unhold-issue — 라벨 조회 실패 → return 1" "1" "$rc"

unset -f _claude-gh-retry
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

echo ""
echo "── #509: claude-check-milestone / claude-create-milestone-checklist ──"

# 인자 검증 — title 누락은 즉시 fail.
out=$(claude-check-milestone 2>&1)
rc=$?
assert_eq "claude-check-milestone — 인자 없음 → return 1" "1" "$rc"
case "$out" in *"사용법: claude-check-milestone"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-check-milestone — 사용법 stderr 노출";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "사용법 메시지 누락" "$out";;
esac

out=$(claude-create-milestone-checklist 2>&1)
rc=$?
assert_eq "claude-create-milestone-checklist — 인자 없음 → return 1" "1" "$rc"

# 알 수 없는 옵션 거부 (--close 외 플래그).
out=$(claude-check-milestone "Phase 1" --bogus 2>&1)
rc=$?
assert_eq "claude-check-milestone — 알 수 없는 플래그 거부" "1" "$rc"

# title 인자 중복 거부.
out=$(claude-check-milestone "A" "B" 2>&1)
rc=$?
assert_eq "claude-check-milestone — title 중복 거부" "1" "$rc"

# mock 경로 — _claude-gh-retry 를 캡처/재정의해 PASS/FAIL 분기를 검증한다.
# #213 회귀 가드와 동일 패턴: 호출 인자를 임시 파일에 기록하고, 호출 본문의
# 토큰을 case glob 으로 매칭해 응답을 구성한다.
_GH_ARGS_LOG=$(mktemp)
_MS_OPEN=0
_MS_CLOSED=0
_MS_ALL_ISSUES_JSON='[]'
_MS_OPEN_ISSUES_JSON='[]'
_claude-gh-retry() {
  printf '%s\n' "$*" >> "$_GH_ARGS_LOG"
  case "$*" in
    *"gh repo view"*)
      printf 'example-org/example-repo' ;;
    *"milestones?state=all"*)
      printf '[{"title":"Phase 1","number":42},{"title":"Phase 2","number":43}]' ;;
    *"milestones/42"*)
      printf '{"open_issues":%d,"closed_issues":%d}' "$_MS_OPEN" "$_MS_CLOSED" ;;
    *"gh issue list"*"--state open"*)
      printf '%s' "$_MS_OPEN_ISSUES_JSON" ;;
    *"gh issue list"*"--state all"*)
      printf '%s' "$_MS_ALL_ISSUES_JSON" ;;
    *"gh issue list"*"in:title 완료 체크리스트"*)
      printf '[]' ;;
    *)
      printf '' ;;
  esac
}

# Case 1: 모두 closed → [PASS] + return 0.
_MS_OPEN=0
_MS_CLOSED=12
out=$(claude-check-milestone "Phase 1" 2>&1)
rc=$?
assert_eq "claude-check-milestone — 전체 closed → return 0" "0" "$rc"
case "$out" in *'[PASS] Milestone "Phase 1"'*'12개 이슈 모두 closed'*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-check-milestone — [PASS] 라인 + 합계 출력";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "[PASS] 출력 누락" "$out";;
esac

# Case 2: open 잔존 → [FAIL] + 잔여 목록 + return 1.
_MS_OPEN=2
_MS_CLOSED=10
_MS_OPEN_ISSUES_JSON='[{"number":487,"title":"DB 스키마 마이그레이션"},{"number":492,"title":"E2E 통합 테스트"}]'
out=$(claude-check-milestone "Phase 1" 2>&1)
rc=$?
assert_eq "claude-check-milestone — open 잔존 → return 1" "1" "$rc"
case "$out" in *'[FAIL] Milestone "Phase 1"'*'open 이슈 2개 잔여'*'#487'*'#492'*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-check-milestone — [FAIL] + 잔여 이슈 목록 출력";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "[FAIL] 출력/목록 누락" "$out";;
esac

# Case 3: --close 플래그가 PATCH mutation 까지 흘러가는지.
: > "$_GH_ARGS_LOG"
_MS_OPEN=0
_MS_CLOSED=5
out=$(claude-check-milestone "Phase 1" --close 2>&1)
rc=$?
assert_eq "claude-check-milestone --close — return 0" "0" "$rc"
if grep -q -E '\-X PATCH .*milestones/42' "$_GH_ARGS_LOG" \
   && grep -q -- '-f state=closed' "$_GH_ARGS_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-check-milestone --close — PATCH milestones/<n> + -f state=closed"
else
  FAIL=$((FAIL + 1))
  printf '  ❌ %s\n     captured args:\n%s\n' "PATCH 호출 누락 또는 -f state=closed 미사용" "$(cat "$_GH_ARGS_LOG")"
fi
case "$out" in *'Milestone closed 처리 완료'*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-check-milestone --close — 완료 메시지 출력";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "--close 완료 메시지 누락" "$out";;
esac

# Case 4: 미존재 milestone → return 1.
: > "$_GH_ARGS_LOG"
out=$(claude-check-milestone "Nonexistent" 2>&1)
rc=$?
assert_eq "claude-check-milestone — 미존재 milestone → return 1" "1" "$rc"
case "$out" in *"Milestone 'Nonexistent' 을 찾을 수 없습니다"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-check-milestone — 미존재 안내 출력";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "미존재 안내 누락" "$out";;
esac

# Case 5: claude-create-milestone-checklist — _claude-gh-retry gh issue create 에 --label milestone 자동 부착 (#553).
# _claude-gh-retry 경유이므로 gh() mock 대신 _claude-gh-retry 를 재정의해 캡처한다.
_MS_ALL_ISSUES_JSON='[{"number":100,"title":"첫 번째 이슈","state":"OPEN"}]'
_GH_CREATE_LOG=$(mktemp)
_claude-gh-retry() {
  printf '%s\n' "$*" >> "$_GH_CREATE_LOG"
  case "$*" in
    *"gh issue create"*)
      printf 'https://github.com/example-org/example-repo/issues/999\n' ;;
    *"milestones?state=all"*)
      printf '[{"title":"Phase 1","number":42}]' ;;
    *"gh issue list"*"in:title 완료 체크리스트"*)
      printf '[]' ;;
    *"gh issue list"*"--state all"*)
      printf '%s' "$_MS_ALL_ISSUES_JSON" ;;
    *)
      printf '' ;;
  esac
}
# shellcheck disable=SC2218  # 함수는 sourced github-workflow.sh 에서 제공; 본 파일 후반의 #704 stub 은 별도 컨텍스트.
claude-create-milestone-checklist "Phase 1" >/dev/null 2>&1
if grep -q -- "--label milestone" "$_GH_CREATE_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-create-milestone-checklist — --label milestone 자동 부착 (#553)"
else
  FAIL=$((FAIL + 1))
  printf '  ❌ %s\n     captured: %s\n' "--label milestone 누락 (#553 회귀)" "$(cat "$_GH_CREATE_LOG")"
fi
rm -f "$_GH_CREATE_LOG"

rm -f "$_GH_ARGS_LOG"
unset -f _claude-gh-retry
unset _MS_OPEN _MS_CLOSED _MS_ALL_ISSUES_JSON _MS_OPEN_ISSUES_JSON
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

# 정적 회귀 가드 — 두 함수가 스크립트에 정의되어 있는지.
for fn in claude-create-milestone-checklist claude-check-milestone _claude-milestone-number; do
  if grep -q -E "^${fn}\(\) \{" "${SCRIPT_DIR}/github-workflow.sh"; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "${fn} 정의 존재 (#509)"
  else
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "${fn} 정의 누락 (#509 회귀)"
  fi
done

echo ""
echo "── #704: _claude-ensure-next-milestone-checklist (claude-check-milestone --close 자동 트리거) ──"

# 정적 회귀 가드 — 함수 정의 + claude-check-milestone 본문이 호출하는지.
if grep -q -E '^_claude-ensure-next-milestone-checklist\(\) \{' "${SCRIPT_DIR}/github-workflow.sh"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-ensure-next-milestone-checklist 정의 존재 (#704)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "_claude-ensure-next-milestone-checklist 정의 누락 (#704 회귀)"
fi

# claude-check-milestone 의 --close 분기에서 호출되는지 (정적 grep).
# `awk` 로 함수 본문 범위만 추출해, 다른 함수에서 호출하더라도 회귀로 잡히지 않게 한다.
fn_body=$(awk '/^claude-check-milestone\(\) \{/{flag=1} flag{print} flag && /^\}/{exit}' \
  "${SCRIPT_DIR}/github-workflow.sh")
if printf '%s' "$fn_body" | grep -q "_claude-ensure-next-milestone-checklist"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-check-milestone 가 자동 트리거를 호출 (#704)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "claude-check-milestone 본문에서 자동 트리거 호출 누락 (#704 회귀)"
fi
unset fn_body

# 동적 mock — 3 케이스: idempotent skip / next 없음 / 신규 생성.
_GH_704_LOG=$(mktemp)
_NEXT_MS_JSON='[{"title":"Phase 2","number":43}]'
_NEXT_CHECKLIST_JSON='[]'
_claude-gh-retry() {
  printf '%s\n' "$*" >> "$_GH_704_LOG"
  case "$*" in
    *"gh repo view"*)
      printf 'example-org/example-repo' ;;
    *"milestones?state=open"*)
      printf '%s' "$_NEXT_MS_JSON" ;;
    *"gh issue list"*"--label milestone"*"--state open"*)
      printf '%s' "$_NEXT_CHECKLIST_JSON" ;;
    *)
      printf '' ;;
  esac
}

# Case A: idempotent — 다음 마일스톤에 milestone 라벨 OPEN 이슈가 이미 있으면 skip.
: > "$_GH_704_LOG"
_NEXT_CHECKLIST_JSON='[{"number":777}]'
out=$(_claude-ensure-next-milestone-checklist 2>&1)
rc=$?
assert_eq "idempotent skip — return 0" "0" "$rc"
case "$out" in *"체크리스트 이슈 존재 (#777)"*"skip"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_ensure-next-milestone-checklist — 체크리스트 존재 시 skip (idempotent, #704)";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "idempotent skip 메시지 누락" "$out";;
esac
# claude-create-milestone-checklist 가 호출되지 않았는지 (gh issue create 미발화).
if grep -q "gh issue create" "$_GH_704_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     captured:\n%s\n' "skip 경로에서 gh issue create 가 호출됨" "$(cat "$_GH_704_LOG")"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_ensure-next-milestone-checklist — skip 경로에서 gh issue create 미발화 (#704)"
fi

# Case B: OPEN 마일스톤이 없으면 skip.
: > "$_GH_704_LOG"
_NEXT_MS_JSON='[]'
out=$(_claude-ensure-next-milestone-checklist 2>&1)
rc=$?
assert_eq "no next milestone — return 0" "0" "$rc"
case "$out" in *"다음 OPEN 마일스톤 없음"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_ensure-next-milestone-checklist — OPEN 마일스톤 없음 시 skip (#704)";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "다음 OPEN 마일스톤 없음 메시지 누락" "$out";;
esac

# Case C: 다음 마일스톤 + 체크리스트 부재 → claude-create-milestone-checklist 호출.
# claude-create-milestone-checklist 호출 여부는 stub 함수로 가로채 검증.
# 본체 함수는 subshell ( $(...) ) 안에서 실행되므로 변수 캡처 대신 tempfile 에 기록.
: > "$_GH_704_LOG"
_NEXT_MS_JSON='[{"title":"Phase 3","number":44},{"title":"Phase 4","number":45}]'
_NEXT_CHECKLIST_JSON='[]'
_CREATE_CALL_LOG=$(mktemp)
# shellcheck disable=SC2218  # 위 Case 5 의 sourced 호출은 본 stub 보다 앞서므로 안전.
claude-create-milestone-checklist() {
  printf '%s\n' "$1" >> "$_CREATE_CALL_LOG"
  return 0
}
out=$(_claude-ensure-next-milestone-checklist 2>&1)
rc=$?
assert_eq "next checklist create — return 0" "0" "$rc"
# sort_by(.number) → number 가장 작은 Phase 3 (44) 우선.
_CREATE_CALLED_WITH=$(head -n 1 "$_CREATE_CALL_LOG")
assert_eq "next milestone — number 최소값 선택 (Phase 3)" "Phase 3" "$_CREATE_CALLED_WITH"
case "$out" in *"다음 마일스톤 'Phase 3' 체크리스트 자동 생성"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_ensure-next-milestone-checklist — 신규 생성 안내 출력 (#704)";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "신규 생성 안내 누락" "$out";;
esac
rm -f "$_CREATE_CALL_LOG"
unset -f claude-create-milestone-checklist
unset _CREATE_CALL_LOG _CREATE_CALLED_WITH

# Case D: claude-check-milestone --close 가 PATCH 성공 직후 자동 트리거를 호출하는지
# end-to-end 로 확인. --close PATCH 와 _claude-ensure-next-milestone-checklist 의
# `milestones?state=open` 호출이 동일 args log 에 함께 기록되어야 한다.
: > "$_GH_704_LOG"
_NEXT_MS_JSON='[]'  # 자동 생성 스킵 — close 성공만 검증
_claude-gh-retry() {
  printf '%s\n' "$*" >> "$_GH_704_LOG"
  case "$*" in
    *"gh repo view"*)
      printf 'example-org/example-repo' ;;
    *"milestones?state=all"*)
      printf '[{"title":"Phase 1","number":42}]' ;;
    *"milestones/42"*)
      printf '{"open_issues":0,"closed_issues":3}' ;;
    *"milestones?state=open"*)
      printf '%s' "$_NEXT_MS_JSON" ;;
    *)
      printf '' ;;
  esac
}
out=$(claude-check-milestone "Phase 1" --close 2>&1)
rc=$?
assert_eq "check-milestone --close + 자동 트리거 — return 0" "0" "$rc"
if grep -q "milestones?state=open" "$_GH_704_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-check-milestone --close → 자동 트리거 milestones?state=open 호출 (#704)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     captured:\n%s\n' "자동 트리거 호출 누락" "$(cat "$_GH_704_LOG")"
fi

# PR #712 review — claude-check-milestone 가 이미 확보한 repo 를 자동 트리거에
# 전달해야 한다 (중복 `gh repo view` 호출 방지). _claude-milestone-number 1회 +
# claude-check-milestone 본체 1회 = 총 2회만 허용; 3회 이상이면 회귀.
gh_repo_view_count=$(grep -c "gh repo view" "$_GH_704_LOG" || true)
if [[ "$gh_repo_view_count" -le 2 ]]; then
  PASS=$((PASS + 1)); printf '  ✅ %s (count=%d)\n' "claude-check-milestone --close → 자동 트리거에 repo 인자 전달 (gh repo view 중복 호출 없음, PR #712 review)" "$gh_repo_view_count"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s — gh repo view %d회 호출 (PR #712 review 회귀)\n     captured:\n%s\n' "자동 트리거가 repo 를 재조회" "$gh_repo_view_count" "$(cat "$_GH_704_LOG")"
fi
unset gh_repo_view_count

rm -f "$_GH_704_LOG"
unset -f _claude-gh-retry
unset _NEXT_MS_JSON _NEXT_CHECKLIST_JSON
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

echo ""
echo "── #745: _claude-sync-phase1-milestones-doc (claude-check-milestone --close 자동 트리거) ──"

# 정적 회귀 가드 — 함수 정의 + claude-check-milestone --close 가 호출하는지.
if grep -q -E '^_claude-sync-phase1-milestones-doc\(\) \{' "${SCRIPT_DIR}/github-workflow.sh"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-sync-phase1-milestones-doc 정의 존재 (#745)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "_claude-sync-phase1-milestones-doc 정의 누락 (#745 회귀)"
fi

# claude-check-milestone --close 분기에서 호출되는지 (정적 grep, 함수 본문 범위만).
fn_body=$(awk '/^claude-check-milestone\(\) \{/{flag=1} flag{print} flag && /^\}/{exit}' \
  "${SCRIPT_DIR}/github-workflow.sh")
if printf '%s' "$fn_body" | grep -q "_claude-sync-phase1-milestones-doc"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-check-milestone 가 sync 트리거를 호출 (#745)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "claude-check-milestone 본문에서 sync 트리거 호출 누락 (#745 회귀)"
fi
unset fn_body

# 동적 검증 — 임시 git repo + docs/planning/phase1-milestones.md 픽스처.
_C745_TMP=$(mktemp -d)
mkdir -p "${_C745_TMP}/docs/planning"
(
  cd "$_C745_TMP" || exit 1
  git init -q
  git config user.email "test@example.com"
  git config user.name "test"
)

# 픽스처 — 기존 파일 구조와 동일한 §헤더 + 체크리스트 표.
cat > "${_C745_TMP}/docs/planning/phase1-milestones.md" <<'EOF'
# Phase 1 fixture

| 마일스톤                  | 체크리스트 이슈 | 상태   |
| ------------------------- | --------------- | ------ |
| M0a — Scaffold & Tooling  | #519            | CLOSED |
| M1 — Core Backend         | #707            | OPEN   |

### M0a — Scaffold & Tooling (4) — CLOSED 2026-05-08

내용

### M1 — Core Backend (8)

내용
EOF

# Case A: doc 미존재 → ℹ️ skip + return 0.
out=$(cd "$_C745_TMP" && rm -f docs/planning/phase1-milestones.md && _claude-sync-phase1-milestones-doc "M1 — Core Backend" 2>&1)
rc=$?
assert_eq "doc 미존재 → return 0" "0" "$rc"
case "$out" in *"phase1-milestones.md 없음"*"skip"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_sync-phase1 — doc 미존재 시 skip (#745)";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "doc 미존재 skip 메시지 누락" "$out";;
esac

# Case B: §헤더 마커 부착 + 표 row OPEN → CLOSED.
cat > "${_C745_TMP}/docs/planning/phase1-milestones.md" <<'EOF'
# Phase 1 fixture

| 마일스톤                  | 체크리스트 이슈 | 상태   |
| ------------------------- | --------------- | ------ |
| M0a — Scaffold & Tooling  | #519            | CLOSED |
| M1 — Core Backend         | #707            | OPEN   |

### M0a — Scaffold & Tooling (4) — CLOSED 2026-05-08

내용

### M1 — Core Backend (8)

내용
EOF
out=$(cd "$_C745_TMP" && _claude-sync-phase1-milestones-doc "M1 — Core Backend" 2>&1)
rc=$?
assert_eq "신규 close — return 0" "0" "$rc"
today=$(date -u +%Y-%m-%d)
if grep -q -E "^### M1 — Core Backend \(8\) — CLOSED ${today}$" "${_C745_TMP}/docs/planning/phase1-milestones.md"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_sync-phase1 — §헤더에 — CLOSED <date> 마커 부착 (#745)"
else
  FAIL=$((FAIL + 1))
  printf '  ❌ §헤더 마커 미부착\n     content:\n%s\n' "$(cat "${_C745_TMP}/docs/planning/phase1-milestones.md")"
fi
if grep -qE "^\| M1 — Core Backend[[:space:]]+\| #707[[:space:]]+\| CLOSED \|$" "${_C745_TMP}/docs/planning/phase1-milestones.md"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_sync-phase1 — 표 row OPEN → CLOSED 치환 (#745)"
else
  FAIL=$((FAIL + 1))
  printf '  ❌ 표 row 치환 실패\n     content:\n%s\n' "$(cat "${_C745_TMP}/docs/planning/phase1-milestones.md")"
fi

# Case C: 이미 CLOSED 마커 보유 → idempotent (헤더 변경 없음).
out=$(cd "$_C745_TMP" && _claude-sync-phase1-milestones-doc "M1 — Core Backend" 2>&1)
rc=$?
assert_eq "idempotent close — return 0" "0" "$rc"
hdr_count=$(grep -c -E "^### M1 — Core Backend \(8\) — CLOSED " "${_C745_TMP}/docs/planning/phase1-milestones.md")
assert_eq "_sync-phase1 — idempotent: §헤더 마커 1회만 (#745)" "1" "$hdr_count"

# Case D: 미발견 milestone → 변경 없음 + return 0.
cp "${_C745_TMP}/docs/planning/phase1-milestones.md" "${_C745_TMP}/docs/planning/phase1-milestones.md.before"
out=$(cd "$_C745_TMP" && _claude-sync-phase1-milestones-doc "Mxx — Nonexistent" 2>&1)
rc=$?
assert_eq "미발견 milestone — return 0" "0" "$rc"
if diff -q "${_C745_TMP}/docs/planning/phase1-milestones.md" "${_C745_TMP}/docs/planning/phase1-milestones.md.before" >/dev/null; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_sync-phase1 — 미발견 milestone 시 파일 무변경 (#745)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "미발견 milestone 호출에도 파일이 변경됨 (#745 회귀)"
fi

rm -rf "$_C745_TMP"
unset _C745_TMP today hdr_count

echo ""
echo "── #527: 신규 이슈 사후 처리 (current-milestone / append-checklist / post-create / create-issue) ──"

# 공용 mock 컨테이너.
_C527_LOG=$(mktemp)
_C527_BOUND=""
_C527_BOUND_MILESTONE=""
_C527_OPEN_MILESTONES_JSON='[]'
_C527_NEW_ISSUE_JSON='{"title":"","milestone":null}'
_C527_CHECKLIST_JSON='[]'
_C527_SET_STATUS_RC=0

claude-session-bound() {
  if [[ -n "$_C527_BOUND" ]]; then
    printf '%s' "$_C527_BOUND"
    return 0
  fi
  return 1
}

_claude-gh-retry() {
  printf '%s\n' "$*" >> "$_C527_LOG"
  case "$*" in
    *"gh repo view"*)
      printf 'example-org/example-repo' ;;
    *"gh issue view"*"milestone --jq"*)
      printf '%s' "$_C527_BOUND_MILESTONE" ;;
    *"gh issue view"*"title,milestone"*)
      printf '%s' "$_C527_NEW_ISSUE_JSON" ;;
    *"milestones?state=all"*)
      printf '[{"title":"M0b — Interface 계약 검증","number":42},{"title":"Phase 2","number":43}]' ;;
    *"milestones?state=open"*)
      printf '%s' "$_C527_OPEN_MILESTONES_JSON" ;;
    *"gh issue list"*"in:title 완료 체크리스트"*)
      printf '%s' "$_C527_CHECKLIST_JSON" ;;
    *"gh issue edit"*)
      printf '' ;;
    *)
      printf '' ;;
  esac
}

claude-set-issue-status() {
  printf 'set-status %s %s\n' "$1" "$2" >> "$_C527_LOG"
  return "$_C527_SET_STATUS_RC"
}

# #671 forward-only 가드 mock — 기본값 "" (보드 카드 미등록 = 신규 이슈) 으로 두면
# 기존 케이스(#544, #645 등) 가드 미트리거. 케이스별로 _C527_BOARD_STATUS 또는
# _C527_BOARD_STATUS_RC 를 설정해 forward 단계나 조회 실패를 시뮬레이션.
_C527_BOARD_STATUS=""
_C527_BOARD_STATUS_RC=0
_claude-current-board-status() {
  printf '%s' "$_C527_BOARD_STATUS"
  return "$_C527_BOARD_STATUS_RC"
}

# ── _claude-current-milestone ──
# Case 1: bound 세션 + bound 이슈 마일스톤 → 그것이 우선.
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE="M0b — Interface 계약 검증"
_C527_OPEN_MILESTONES_JSON='[{"title":"Phase 2","number":43}]'
out=$(_claude-current-milestone)
assert_eq "_claude-current-milestone — bound 세션 → bound 이슈 마일스톤" \
  "M0b — Interface 계약 검증" "$out"

# Case 2: bound 세션 + bound 마일스톤 비어 → OPEN number asc 1위(=현재 진행) 폴백 (#544).
# 이전 동작(desc 1위)은 미래 계획용 마일스톤을 반환해 신규 이슈 분류·체크리스트가 잘못된 마일스톤으로 향했다.
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE=""
_C527_OPEN_MILESTONES_JSON='[{"title":"older","number":40},{"title":"M0c","number":52},{"title":"M0d","number":53}]'
out=$(_claude-current-milestone)
assert_eq "_claude-current-milestone — bound 마일스톤 부재 → OPEN number asc 1위 (현재 진행)" \
  "older" "$out"

# Case 3: bound 없음 + OPEN 1개.
: > "$_C527_LOG"
_C527_BOUND=""
_C527_OPEN_MILESTONES_JSON='[{"title":"M0c","number":52}]'
out=$(_claude-current-milestone)
assert_eq "_claude-current-milestone — bound 없음 + OPEN 1개" "M0c" "$out"

# Case 4: bound 없음 + OPEN 0개 → 빈 문자열 (skip 신호).
: > "$_C527_LOG"
_C527_BOUND=""
_C527_OPEN_MILESTONES_JSON='[]'
out=$(_claude-current-milestone)
assert_eq "_claude-current-milestone — 마일스톤 없음 → 빈 문자열" "" "$out"

# ── _claude-append-checklist-item ──
# Case 5: 체크리스트 이슈 부재 → 안내 메시지 + return 0 (강제 생성 ❌).
: > "$_C527_LOG"
_C527_CHECKLIST_JSON='[]'
out=$(_claude-append-checklist-item "M0b — Interface 계약 검증" 600 "테스트 이슈" 2>&1)
rc=$?
assert_eq "_claude-append-checklist-item — 체크리스트 부재 → return 0" "0" "$rc"
case "$out" in *"체크리스트 이슈가 없어"*"#600"*"건너뜀"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-append-checklist-item — 부재 안내 출력";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "부재 안내 메시지 누락" "$out";;
esac
if grep -q "gh issue edit" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "체크리스트 부재인데도 gh issue edit 호출됨"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-append-checklist-item — 부재 시 edit 미호출"
fi

# Case 6: 체크리스트 존재 + 새 번호 → append (gh issue edit --body-file 호출).
: > "$_C527_LOG"
_C527_CHECKLIST_JSON='[{"number":523,"title":"[Milestone] M0b — Interface 계약 검증 완료 체크리스트","body":"## 마일스톤\n\n- [ ] #500 기존 이슈\n- [x] #501 완료 이슈\n\n### 완료 조건\n"}]'
out=$(_claude-append-checklist-item "M0b — Interface 계약 검증" 600 "테스트 이슈" 2>&1)
rc=$?
assert_eq "_claude-append-checklist-item — 새 번호 → return 0" "0" "$rc"
if grep -q -E "gh issue edit 523 --body-file" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-append-checklist-item — gh issue edit --body-file 호출"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "edit --body-file 호출 누락" "$(cat "$_C527_LOG")"
fi
case "$out" in *"#523 체크리스트에 #600 등록"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-append-checklist-item — append 성공 메시지";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "append 메시지 누락" "$out";;
esac

# Case 7: 멱등 — 같은 번호가 이미 체크리스트에 있으면 edit 미호출.
: > "$_C527_LOG"
_C527_CHECKLIST_JSON='[{"number":523,"title":"[Milestone] M0b — Interface 계약 검증 완료 체크리스트","body":"- [ ] #600 이미 등록\n- [x] #501 완료\n"}]'
out=$(_claude-append-checklist-item "M0b — Interface 계약 검증" 600 "테스트 이슈" 2>&1)
rc=$?
assert_eq "_claude-append-checklist-item — 중복 번호 → return 0" "0" "$rc"
if grep -q "gh issue edit" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "중복 번호인데 edit 호출됨 (멱등 위반)" "$(cat "$_C527_LOG")"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-append-checklist-item — 중복 번호 멱등 skip"
fi

# Case 7b: 멱등 가드 — 단어 경계 검증. '#60' 같은 prefix 매칭이 #600 추가를 막으면 안 됨.
: > "$_C527_LOG"
_C527_CHECKLIST_JSON='[{"number":523,"title":"[Milestone] M0b — Interface 계약 검증 완료 체크리스트","body":"- [ ] #60 prefix 이슈\n"}]'
out=$(_claude-append-checklist-item "M0b — Interface 계약 검증" 600 "신규" 2>&1)
if grep -q -E "gh issue edit 523 --body-file" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-append-checklist-item — '#60' 존재 시에도 #600 추가 (단어 경계 가드)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "단어 경계 미검증 — #60 prefix 가 #600 추가를 차단" "$(cat "$_C527_LOG")"
fi

# Case 8: 빈 인자 → no-op return 0.
: > "$_C527_LOG"
out=$(_claude-append-checklist-item "" 600 "x" 2>&1)
rc=$?
assert_eq "_claude-append-checklist-item — 빈 마일스톤 → return 0 (no-op)" "0" "$rc"
if [[ -s "$_C527_LOG" ]]; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "빈 인자인데도 gh 호출됨" "$(cat "$_C527_LOG")"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-append-checklist-item — 빈 인자 시 gh 미호출"
fi

# ── _claude-post-issue-create ──
# Case 9: 마일스톤 미설정 + current 감지 가능 → milestone edit + Ready.
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE="M0b — Interface 계약 검증"
_C527_NEW_ISSUE_JSON='{"title":"신규 이슈","milestone":null}'
_C527_CHECKLIST_JSON='[{"number":523,"title":"[Milestone] M0b — Interface 계약 검증 완료 체크리스트","body":"## 마일스톤\n"}]'
out=$(_claude-post-issue-create 600 2>&1)
rc=$?
assert_eq "_claude-post-issue-create — return 0" "0" "$rc"
if grep -q -E "gh issue edit 600 --milestone M0b" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-post-issue-create — 마일스톤 미설정 → 자동 적용"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "마일스톤 자동 적용 누락" "$(cat "$_C527_LOG")"
fi
if grep -q "set-status 600 Ready" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-post-issue-create — Ready 승격 호출"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "Ready 승격 미호출" "$(cat "$_C527_LOG")"
fi

# Case 10: 마일스톤 이미 설정됨 → milestone edit 안함 + Ready 만 호출.
: > "$_C527_LOG"
_C527_BOUND=""
_C527_NEW_ISSUE_JSON='{"title":"기존 이슈","milestone":{"title":"M0b — Interface 계약 검증"}}'
_C527_CHECKLIST_JSON='[]'
out=$(_claude-post-issue-create 601 2>&1)
rc=$?
assert_eq "_claude-post-issue-create — 마일스톤 기설정 → return 0" "0" "$rc"
if grep -q -E "gh issue edit 601 --milestone" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "이미 설정된 마일스톤을 다시 적용 (멱등 위반)" "$(cat "$_C527_LOG")"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-post-issue-create — 마일스톤 기설정 시 edit skip"
fi
if grep -q "set-status 601 Ready" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-post-issue-create — Ready 승격은 항상 호출"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "Ready 승격 미호출"
fi

# Case 11: 마일스톤 미설정 + current 감지 불가 → Ready 만 호출, milestone edit 미호출.
: > "$_C527_LOG"
_C527_BOUND=""
_C527_OPEN_MILESTONES_JSON='[]'
_C527_NEW_ISSUE_JSON='{"title":"마일스톤 없는 이슈","milestone":null}'
out=$(_claude-post-issue-create 602 2>&1)
rc=$?
assert_eq "_claude-post-issue-create — 마일스톤 감지 불가 → return 0" "0" "$rc"
if grep -q -E "gh issue edit 602 --milestone" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "감지 불가인데 edit 호출됨" "$(cat "$_C527_LOG")"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-post-issue-create — 감지 불가 시 milestone edit skip"
fi

# Case 12: 잘못된 인자 → return 1 + stderr.
out=$(_claude-post-issue-create "abc" 2>&1)
rc=$?
assert_eq "_claude-post-issue-create — 비정상 입력 → return 1" "1" "$rc"
case "$out" in *"이슈 번호가 잘못됐습니다"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-post-issue-create — 입력 검증 안내";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "입력 검증 메시지 누락" "$out";;
esac

# ── #645: _claude-post-issue-create CLOSED 가드 ──
# Fix 1 — CLOSED 이슈가 forward-only 라우팅(Ready/Backlog) 으로 회귀하지 못하게 차단.
# 잘못된 인자로 닫힌 이슈 번호를 받은 경우의 fail-closed soft abort (return 0 + warn).

# Case 12e: CLOSED 이슈 + 마일스톤 미설정 → Ready 라우팅 미호출 + milestone edit 미호출.
: > "$_C527_LOG"
_C527_BOUND=""
_C527_NEW_ISSUE_JSON='{"title":"닫힌 이슈","milestone":null,"state":"CLOSED"}'
out=$(_claude-post-issue-create 607 2>&1)
rc=$?
assert_eq "#645 — _claude-post-issue-create CLOSED → return 0 (soft abort)" "0" "$rc"
case "$out" in
  *"이미 CLOSED"*"#645"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — CLOSED 경고 메시지 출력";;
  *)                       FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "CLOSED 경고 누락" "$out";;
esac
if grep -q "set-status 607" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "#645 — CLOSED 이슈인데 set-status 호출됨 (회귀)" "$(cat "$_C527_LOG")"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — CLOSED 시 set-status 미호출"
fi
if grep -q -E "gh issue edit 607 --milestone" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "#645 — CLOSED 인데 milestone edit 호출됨" "$(cat "$_C527_LOG")"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — CLOSED 시 milestone edit 미호출"
fi

# Case 12f: OPEN 이슈 (state 명시) → 기존 경로 유지 (Ready 라우팅 발생).
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE="M0b — Interface 계약 검증"
_C527_NEW_ISSUE_JSON='{"title":"열린 이슈","milestone":null,"state":"OPEN"}'
_C527_CHECKLIST_JSON='[]'
out=$(_claude-post-issue-create 606 2>&1)
rc=$?
assert_eq "#645 — _claude-post-issue-create OPEN → return 0" "0" "$rc"
if grep -q "set-status 606 Ready" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — OPEN 이슈 정상 라우팅 유지"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "OPEN 이슈 Ready 라우팅 누락" "$(cat "$_C527_LOG")"
fi

# Case 12g: 정적 회귀 가드 — _claude-post-issue-create 가 state 필드를 조회하는지.
if grep -q -E "gh issue view .* --json title,milestone,state" "${SCRIPT_DIR}/github-workflow.sh"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#645 — _claude-post-issue-create state 필드 조회 (정적 가드)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "#645 — _claude-post-issue-create state 필드 미조회 (회귀)"
fi

# ── #671: _claude-post-issue-create forward-only 보드 가드 ──
# Fix 2 — OPEN 이슈가 이미 보드 forward 단계에 있을 때 milestone 재적용/Ready 라우팅
# 모두 early-return (soft abort, return 0). #627 회귀 trigger 의 정본 차단 경로.
# 위 C527 mock 의 _C527_BOARD_STATUS / _claude-current-board-status 재사용.

# Case 12h: OPEN + 보드 = In progress → milestone edit / set-status 모두 미호출.
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE="M0b — Interface 계약 검증"
_C527_NEW_ISSUE_JSON='{"title":"진행 중 이슈","milestone":null,"state":"OPEN"}'
_C527_BOARD_STATUS="In progress"
_C527_BOARD_STATUS_RC=0
out=$(_claude-post-issue-create 627 2>&1)
rc=$?
assert_eq "#671 — In progress 보드 → return 0 (soft abort)" "0" "$rc"
case "$out" in
  *"In progress"*"#671"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — forward-only 경고 메시지 출력";;
  *)                       FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "forward-only 경고 누락" "$out";;
esac
if grep -q "set-status 627" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "#671 — In progress 인데 set-status 호출됨 (회귀)" "$(cat "$_C527_LOG")"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — In progress 보드 시 set-status 미호출"
fi
if grep -q -E "gh issue edit 627 --milestone" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "#671 — In progress 인데 milestone edit 호출됨" "$(cat "$_C527_LOG")"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — In progress 보드 시 milestone edit 미호출"
fi

# Case 12i: OPEN + 보드 = In review → 동일 차단.
: > "$_C527_LOG"
_C527_BOARD_STATUS="In review"
out=$(_claude-post-issue-create 627 2>&1)
rc=$?
assert_eq "#671 — In review 보드 → return 0 (soft abort)" "0" "$rc"
if grep -q "set-status 627" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "#671 — In review 인데 set-status 호출됨"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — In review 보드 시 set-status 미호출"
fi

# Case 12j: OPEN + 보드 = Approved → 동일 차단.
: > "$_C527_LOG"
_C527_BOARD_STATUS="Approved"
out=$(_claude-post-issue-create 627 2>&1)
rc=$?
assert_eq "#671 — Approved 보드 → return 0 (soft abort)" "0" "$rc"
if grep -q "set-status 627" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "#671 — Approved 인데 set-status 호출됨"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — Approved 보드 시 set-status 미호출"
fi

# Case 12k: OPEN + 보드 = Done → 동일 차단 (Done 도 forward 단계).
: > "$_C527_LOG"
_C527_BOARD_STATUS="Done"
out=$(_claude-post-issue-create 627 2>&1)
rc=$?
assert_eq "#671 — Done 보드 → return 0 (soft abort)" "0" "$rc"
if grep -q "set-status 627" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "#671 — Done 인데 set-status 호출됨"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — Done 보드 시 set-status 미호출"
fi

# Case 12l: 보드 status 조회 실패 → fail-closed (soft abort + warn).
: > "$_C527_LOG"
_C527_BOARD_STATUS=""
_C527_BOARD_STATUS_RC=1
out=$(_claude-post-issue-create 627 2>&1)
rc=$?
assert_eq "#671 — 보드 조회 실패 → return 0 (soft fail-closed)" "0" "$rc"
case "$out" in
  *"보드 status 조회 실패"*"fail-closed"*)
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — 조회 실패 시 fail-closed 메시지 출력";;
  *)
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "조회 실패 메시지 누락" "$out";;
esac
if grep -q "set-status 627" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "#671 — 조회 실패인데 set-status 호출됨 (fail-closed 위반)"
else
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — 조회 실패 시 set-status 미호출"
fi
_C527_BOARD_STATUS_RC=0  # 후속 케이스 영향 방지.

# Case 12m: OPEN + 보드 = "" (신규 이슈, 보드 카드 미등록) → 정상 Ready 라우팅.
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE="M0b — Interface 계약 검증"
_C527_NEW_ISSUE_JSON='{"title":"신규 이슈","milestone":null,"state":"OPEN"}'
_C527_BOARD_STATUS=""
out=$(_claude-post-issue-create 628 2>&1)
rc=$?
assert_eq "#671 — empty 보드 (신규) → return 0 + 정상 라우팅" "0" "$rc"
if grep -q "set-status 628 Ready" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — 보드 미등록 신규 이슈는 정상 Ready 라우팅"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "Ready 라우팅 누락 (신규 이슈 경로)" "$(cat "$_C527_LOG")"
fi

# Case 12n: 정적 회귀 가드 — _claude-current-board-status 헬퍼가 스크립트에 정의되어 있는지.
if grep -q -E "^_claude-current-board-status\(\) \{" "${SCRIPT_DIR}/github-workflow.sh"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "#671 — _claude-current-board-status 정의 존재 (정적 가드)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "#671 — _claude-current-board-status 정의 누락 (회귀)"
fi

# ── #544: Status 라우팅 (미래 마일스톤 → Backlog) ──
# 마일스톤 번호 mock: M0b=42, Phase 2=43 (state=all 응답에 정의됨).

# Case 12a: 명시된 미래 마일스톤(Phase 2, 43) > 현재(M0b, 42) → Backlog 승격.
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE="M0b — Interface 계약 검증"
_C527_NEW_ISSUE_JSON='{"title":"미래 마일스톤 이슈","milestone":{"title":"Phase 2"}}'
_C527_CHECKLIST_JSON='[]'
out=$(_claude-post-issue-create 800 2>&1)
rc=$?
assert_eq "_claude-post-issue-create — 미래 마일스톤 → return 0" "0" "$rc"
if grep -q "set-status 800 Backlog" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-post-issue-create — 미래 마일스톤 명시 → Backlog 라우팅 (#544)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "Backlog 라우팅 누락 (#544)" "$(cat "$_C527_LOG")"
fi
if grep -q "set-status 800 Ready" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "미래 마일스톤인데 Ready 승격됨 (#544 회귀)"
fi

# Case 12b: 명시된 현재 마일스톤(M0b == bound) → Ready 유지.
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE="M0b — Interface 계약 검증"
_C527_NEW_ISSUE_JSON='{"title":"현재 마일스톤 이슈","milestone":{"title":"M0b — Interface 계약 검증"}}'
_C527_CHECKLIST_JSON='[]'
out=$(_claude-post-issue-create 801 2>&1)
rc=$?
assert_eq "_claude-post-issue-create — 현재 마일스톤 → return 0" "0" "$rc"
if grep -q "set-status 801 Ready" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-post-issue-create — 현재 마일스톤 명시 → Ready 유지 (#544)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "현재 마일스톤인데 Ready 미호출" "$(cat "$_C527_LOG")"
fi

# Case 12c: 명시된 과거 마일스톤(M0b, 42) < 현재(Phase 2, 43, bound) → Ready (Backlog 아님).
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE="Phase 2"
_C527_NEW_ISSUE_JSON='{"title":"과거 마일스톤 이슈","milestone":{"title":"M0b — Interface 계약 검증"}}'
_C527_CHECKLIST_JSON='[]'
out=$(_claude-post-issue-create 802 2>&1)
rc=$?
assert_eq "_claude-post-issue-create — 과거 마일스톤 → return 0" "0" "$rc"
if grep -q "set-status 802 Ready" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-post-issue-create — 과거 마일스톤 명시 → Ready (Backlog 아님)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "과거 마일스톤인데 Ready 미호출" "$(cat "$_C527_LOG")"
fi
if grep -q "set-status 802 Backlog" "$_C527_LOG"; then
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "과거 마일스톤인데 Backlog 라우팅됨 (오작동)"
fi

# Case 12d: 자동 적용 경로(milestone unset → current 자동 적용) → 비교 생략하고 Ready (#544).
# 자동 적용된 마일스톤은 정의상 현재 마일스톤이므로 미래 비교가 불필요.
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE="Phase 2"
_C527_NEW_ISSUE_JSON='{"title":"미설정 이슈","milestone":null}'
_C527_CHECKLIST_JSON='[]'
out=$(_claude-post-issue-create 803 2>&1)
rc=$?
assert_eq "_claude-post-issue-create — 자동 적용 경로 → return 0" "0" "$rc"
if grep -q "set-status 803 Ready" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "_claude-post-issue-create — 자동 적용 마일스톤 → Ready (비교 생략)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "자동 적용 경로인데 Ready 미호출" "$(cat "$_C527_LOG")"
fi

# ── claude-create-issue (gh issue create wrapper) ──
# `gh()` 별도 mock — claude-create-issue 가 직접 호출하므로 _claude-gh-retry 우회.
gh() {
  printf '%s\n' "gh $*" >> "$_C527_LOG"
  case "$*" in
    "issue create"*)
      printf 'https://github.com/example-org/example-repo/issues/700\n' ;;
    *)
      printf '' ;;
  esac
}

# 헬퍼 — 로그에서 'gh issue create ...' 라인만 추출 (post-flow 의 다른 gh 호출과 분리).
_create_line() {
  grep -E "^gh issue create " "$_C527_LOG" || true
}

# Case 13: --milestone 미지정 + bound 마일스톤 → 자동 주입.
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE="M0b — Interface 계약 검증"
_C527_NEW_ISSUE_JSON='{"title":"래퍼 테스트","milestone":null}'
_C527_CHECKLIST_JSON='[]'
out=$(claude-create-issue --title "래퍼 테스트" --body "본문" 2>&1)
rc=$?
assert_eq "claude-create-issue — 정상 종료 return 0" "0" "$rc"
create_line=$(_create_line)
case "$create_line" in *"--milestone M0b — Interface 계약 검증"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-create-issue — --milestone 자동 주입";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     create line: %s\n' "--milestone 자동 주입 누락" "$create_line";;
esac
case "$out" in *"https://github.com/example-org/example-repo/issues/700"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-create-issue — URL 출력";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "URL 출력 누락" "$out";;
esac
if grep -q "set-status 700 Ready" "$_C527_LOG"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-create-issue — 사후 처리(Ready) 위임"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     log: %s\n' "사후 처리 위임 누락" "$(cat "$_C527_LOG")"
fi

# Case 14: --milestone 명시 → 자동 주입 안함.
# 검증 범위는 'gh issue create ...' 그 한 줄에 한정 — post-flow 가 추가로 호출하는
# gh issue list --milestone <number> / gh issue edit --milestone <title> 은 별개.
: > "$_C527_LOG"
_C527_BOUND="500"
_C527_BOUND_MILESTONE="M0b — Interface 계약 검증"
_C527_NEW_ISSUE_JSON='{"title":"명시","milestone":{"title":"Phase 2"}}'
out=$(claude-create-issue --title "명시" --milestone "Phase 2" --body "x" 2>&1)
create_line=$(_create_line)
mc_count=$(printf '%s\n' "$create_line" | grep -o -- "--milestone" | wc -l | tr -d '[:space:]')
assert_eq "claude-create-issue — gh issue create 라인의 --milestone 정확히 1개" "1" "$mc_count"
case "$create_line" in *"--milestone Phase 2"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-create-issue — 명시 인자 'Phase 2' 보존";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     create line: %s\n' "Phase 2 인자 누락" "$create_line";;
esac
case "$create_line" in *"M0b"*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     create line: %s\n' "bound 마일스톤이 자동 주입됨 (덮어쓰기 위험)" "$create_line";;
*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-create-issue — bound 마일스톤 자동 주입 안함";;
esac

# Case 15: 인자 0개 → return 1 + 사용법 stderr.
: > "$_C527_LOG"
out=$(claude-create-issue 2>&1)
rc=$?
assert_eq "claude-create-issue — 인자 없음 → return 1" "1" "$rc"
case "$out" in *"사용법: claude-create-issue"*)
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-create-issue — 사용법 안내";;
*)
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "사용법 안내 누락" "$out";;
esac

unset -f gh claude-session-bound _claude-gh-retry claude-set-issue-status
rm -f "$_C527_LOG"
unset _C527_LOG _C527_BOUND _C527_BOUND_MILESTONE _C527_OPEN_MILESTONES_JSON _C527_NEW_ISSUE_JSON _C527_CHECKLIST_JSON _C527_SET_STATUS_RC
# shellcheck source=./github-workflow.sh
source "${SCRIPT_DIR}/github-workflow.sh"

# 정적 회귀 가드 — 신규 함수가 정의되어 있는지 (#527).
for fn in _claude-current-milestone _claude-append-checklist-item _claude-post-issue-create claude-create-issue; do
  if grep -q -E "^${fn}\(\) \{" "${SCRIPT_DIR}/github-workflow.sh"; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "${fn} 정의 존재 (#527)"
  else
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "${fn} 정의 누락 (#527 회귀)"
  fi
done

# 정적 회귀 가드 — claude-register-related-issue 가 _claude-post-issue-create 를 호출하는지.
# 호출이 빠지면 #527 의 핵심 통합(공유 헬퍼) 가 깨진다.
if grep -q -E "_claude-post-issue-create[[:space:]]+\"\\\$new_number\"" "${SCRIPT_DIR}/github-workflow.sh"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-register-related-issue 가 _claude-post-issue-create 위임 (#527)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "claude-register-related-issue 의 사후 처리 위임 누락 (#527 회귀)"
fi

# (PostToolUse 훅 파일 존재 검증은 제거됨 — 훅은 스킬 필수 의존성이 아니라
#  사용자가 선택적으로 둘 수 있는 안전망이므로 본 배포에 번들하지 않는다.)

echo ""
echo "── _claude-run-ci-gate (pluggable local CI hook) ───────────"

# 제네릭화: 실제 빌드/테스트는 CLAUDE_LOCAL_CI_CMD 환경변수 또는
# <repo>/.github-workflow/local-ci.sh 훅으로 위임한다. git 은 stub 으로 가로채고
# rev-parse --show-toplevel 로 repo_root 를 제어한다.

# (1) 훅 미설정 → 0 반환 + 건너뜀 메시지.
_cg=$(
  _root=$(mktemp -d)
  git() { case "$*" in *"rev-parse --show-toplevel"*) echo "$_root";; esac; return 0; }
  unset CLAUDE_LOCAL_CI_CMD
  out=$(_claude-run-ci-gate "main" 2>&1); rc=$?
  rm -rf "$_root"
  printf '%d\n%s' "$rc" "$out"
)
_cg_rc=$(printf '%s\n' "$_cg" | sed -n '1p')
_cg_out=$(printf '%s\n' "$_cg" | sed -n '2,$p')
assert_eq "훅 미설정 → 0 반환" "0" "$_cg_rc"
case "$_cg_out" in
  *"건너뜀"*) assert_eq "훅 미설정 → 건너뜀 메시지" "ok" "ok" ;;
  *)          assert_eq "훅 미설정 → 건너뜀 메시지" "ok" "missing: $_cg_out" ;;
esac
unset _cg _cg_rc _cg_out

# (2) CLAUDE_LOCAL_CI_CMD 성공(exit 0) → 0 반환.
_cg=$(
  _root=$(mktemp -d)
  git() { case "$*" in *"rev-parse --show-toplevel"*) echo "$_root";; esac; return 0; }
  export CLAUDE_LOCAL_CI_CMD="exit 0"
  out=$(_claude-run-ci-gate "main" 2>&1); rc=$?
  rm -rf "$_root"
  printf '%d' "$rc"
)
assert_eq "CLAUDE_LOCAL_CI_CMD 성공 → 0 반환" "0" "$_cg"
unset _cg

# (3) CLAUDE_LOCAL_CI_CMD 실패(exit 3) → 1 반환 + 실패 메시지.
_cg=$(
  _root=$(mktemp -d)
  git() { case "$*" in *"rev-parse --show-toplevel"*) echo "$_root";; esac; return 0; }
  export CLAUDE_LOCAL_CI_CMD="exit 3"
  out=$(_claude-run-ci-gate "main" 2>&1); rc=$?
  rm -rf "$_root"
  printf '%d\n%s' "$rc" "$out"
)
_cg_rc=$(printf '%s\n' "$_cg" | sed -n '1p')
_cg_out=$(printf '%s\n' "$_cg" | sed -n '2,$p')
assert_eq "CLAUDE_LOCAL_CI_CMD 실패 → 1 반환" "1" "$_cg_rc"
case "$_cg_out" in
  *"실패"*) assert_eq "CLAUDE_LOCAL_CI_CMD 실패 → 실패 메시지" "ok" "ok" ;;
  *)        assert_eq "CLAUDE_LOCAL_CI_CMD 실패 → 실패 메시지" "ok" "missing: $_cg_out" ;;
esac
unset _cg _cg_rc _cg_out

# (4) 훅에 GW_CI_BASE_REF / GW_CI_CHANGED 환경 전달.
_cg=$(
  _root=$(mktemp -d)
  git() {
    case "$*" in
      *"rev-parse --show-toplevel"*) echo "$_root"; return 0 ;;
      *"diff --name-only"*) printf 'src/a.py\n'; return 0 ;;
    esac
    return 0
  }
  export CLAUDE_LOCAL_CI_CMD='echo "ref=$GW_CI_BASE_REF changed=$GW_CI_CHANGED"'
  _claude-run-ci-gate "develop" 2>&1
  rm -rf "$_root"
)
case "$_cg" in
  *"ref=develop"*"changed=src/a.py"*) assert_eq "훅에 base_ref/changed 환경 전달" "ok" "ok" ;;
  *)                                  assert_eq "훅에 base_ref/changed 환경 전달" "ok" "missing: $_cg" ;;
esac
unset _cg

# (5) .github-workflow/local-ci.sh 파일 훅 — 존재 시 실행, exit code 전파.
_cg=$(
  _root=$(mktemp -d)
  mkdir -p "$_root/.github-workflow"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$_root/.github-workflow/local-ci.sh"
  git() { case "$*" in *"rev-parse --show-toplevel"*) echo "$_root";; esac; return 0; }
  unset CLAUDE_LOCAL_CI_CMD
  _claude-run-ci-gate "main" >/dev/null 2>&1; rc=$?
  rm -rf "$_root"
  printf '%d' "$rc"
)
assert_eq ".github-workflow/local-ci.sh 실패(exit 7) → 1 반환" "1" "$_cg"
unset _cg

# (6) env 훅이 파일 훅보다 우선.
_cg=$(
  _root=$(mktemp -d)
  mkdir -p "$_root/.github-workflow"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$_root/.github-workflow/local-ci.sh"
  git() { case "$*" in *"rev-parse --show-toplevel"*) echo "$_root";; esac; return 0; }
  export CLAUDE_LOCAL_CI_CMD="exit 0"
  _claude-run-ci-gate "main" >/dev/null 2>&1; rc=$?
  rm -rf "$_root"
  printf '%d' "$rc"
)
assert_eq "env 훅이 파일 훅보다 우선 → 0 반환" "0" "$_cg"
unset _cg

# 정적 가드 — claude-close-issue 가 _claude-run-ci-gate 를 호출하는지.
# awk 로 함수 본문 범위만 추출해 false-positive(다른 함수에서의 호출/정의만 존재)를 막는다.
_close_issue_body=$(awk '/^claude-close-issue\(\) \{/{flag=1} flag{print} flag && /^\}/{exit}' "${SCRIPT_DIR}/github-workflow.sh")
if printf '%s' "$_close_issue_body" | grep -q "_claude-run-ci-gate"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "claude-close-issue 본문에서 _claude-run-ci-gate 호출"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "_claude-run-ci-gate 호출 누락 (회귀)"
fi
unset _close_issue_body

echo ""
echo "── _claude-is-test-type (#546 AC2) ─────────────────────────"

# test 타입 매칭: scope 유무 무관.
for _t in test "test(unit)" "test(integration)" "test(e2e)" "test(a11y)" "test(visual)" "test(perf)"; do
  if _claude-is-test-type "$_t"; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "test 타입 매칭: ${_t}"
  else
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "test 타입 매칭 누락: ${_t}"
  fi
done
unset _t

# 비-test 타입은 매칭되지 않는다.
for _t in feat fix chore docs refactor "test-utils" "fixtest" "" "test()" "test(unit"; do
  if ! _claude-is-test-type "$_t"; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "비-test 타입 거부: ${_t:-<empty>}"
  else
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "비-test 타입 오매칭: ${_t:-<empty>}"
  fi
done
unset _t

echo ""
echo "── _claude-milestone-skip-ui-gate (#546 AC3) ───────────────"

# 기본 skip 목록 (M0a / M1 / M3 / M4) 매칭.
for _m in "M0a" "M0a — Scaffold & Tooling" "M1" "M1 — Core Backend" "M3" "M3 — Integration & Polish" "M4" "M4 — Deployment"; do
  if _claude-milestone-skip-ui-gate "$_m"; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "UI 게이트 skip: ${_m}"
  else
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "UI 게이트 skip 누락: ${_m}"
  fi
done
unset _m

# 기본 skip 외 마일스톤은 적용 (UI 게이트 검사).
for _m in "M0b" "M0b — Interface 계약 검증" "M2a" "M2a — Auth & Layout" "M2b" "M2c" "M5"; do
  if ! _claude-milestone-skip-ui-gate "$_m"; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "UI 게이트 적용: ${_m}"
  else
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "UI 게이트 부적절 skip: ${_m}"
  fi
done
unset _m

# 빈 마일스톤 → 적용 (안전한 기본값).
if ! _claude-milestone-skip-ui-gate ""; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "빈 마일스톤 → UI 게이트 적용 (안전 기본값)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "빈 마일스톤이 부적절하게 skip 됨"
fi

# prefix 충돌 회피: "M0aPlus" 는 "M0a" 와 매치되지 않아야 한다.
if ! _claude-milestone-skip-ui-gate "M0aPlus — Future"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "prefix 충돌 회피: M0aPlus 는 M0a 와 다름"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "prefix 오매칭: M0aPlus 가 M0a 로 처리됨"
fi

# CLAUDE_UI_GATE_SKIP_MILESTONES 환경변수 재정의.
_claude_msg_override=$(
  export CLAUDE_UI_GATE_SKIP_MILESTONES="MX MY"
  if _claude-milestone-skip-ui-gate "MX — Test"; then echo "skip-mx"; else echo "apply-mx"; fi
  if _claude-milestone-skip-ui-gate "M0a"; then echo "skip-m0a"; else echo "apply-m0a"; fi
)
case "$_claude_msg_override" in
  *"skip-mx"*) assert_eq "env override — MX 매칭" "ok" "ok" ;;
  *)           assert_eq "env override — MX 매칭" "ok" "missing: $_claude_msg_override" ;;
esac
case "$_claude_msg_override" in
  *"apply-m0a"*) assert_eq "env override — M0a 더는 skip 안 됨" "ok" "ok" ;;
  *)             assert_eq "env override — M0a 더는 skip 안 됨" "ok" "missing: $_claude_msg_override" ;;
esac
unset _claude_msg_override

echo ""
echo "── _claude-check-remote-ci-status (#546 AC1) ───────────────"

# branch/sha 누락 → fail-open (rc=0).
_ci_check_missing=$(
  out=$(_claude-check-remote-ci-status "" "" 0 0 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "branch/sha 누락 → fail-open(0)" "0" "$(printf '%s\n' "$_ci_check_missing" | sed -n '1p')"
unset _ci_check_missing

# gh run list 실패 → fail-open (rc=0).
_ci_check_gh_fail=$(
  gh() { return 1; }
  out=$(_claude-check-remote-ci-status "wt/issue-546/1" "abcdef0" 0 0 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "gh 실패 → fail-open(0)" "0" "$(printf '%s\n' "$_ci_check_gh_fail" | sed -n '1p')"
unset _ci_check_gh_fail

# 모든 run 성공 → rc=0.
_ci_check_all_pass=$(
  gh() {
    if [[ "$1" == "run" && "$2" == "list" ]]; then
      printf '%s' '[{"name":"web","status":"completed","conclusion":"success","databaseId":1,"url":"u1"},{"name":"worker","status":"completed","conclusion":"success","databaseId":2,"url":"u2"}]'
      return 0
    fi
    return 0
  }
  out=$(_claude-check-remote-ci-status "wt/issue-546/1" "abcdef0" 0 0 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "전체 success → rc=0" "0" "$(printf '%s\n' "$_ci_check_all_pass" | sed -n '1p')"
case "$_ci_check_all_pass" in
  *"전체 통과"*) assert_eq "성공 메시지 출력" "ok" "ok" ;;
  *)              assert_eq "성공 메시지 출력" "ok" "missing: $_ci_check_all_pass" ;;
esac
unset _ci_check_all_pass

# 1건 실패 → rc=1, URL 노출.
_ci_check_failed=$(
  gh() {
    if [[ "$1" == "run" && "$2" == "list" ]]; then
      printf '%s' '[{"name":"web","status":"completed","conclusion":"success","databaseId":1,"url":"u1"},{"name":"worker","status":"completed","conclusion":"failure","databaseId":2,"url":"https://example/run/2"}]'
      return 0
    fi
    return 0
  }
  out=$(_claude-check-remote-ci-status "wt/issue-546/1" "abcdef0" 0 0 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "실패 1건 → rc=1" "1" "$(printf '%s\n' "$_ci_check_failed" | sed -n '1p')"
case "$_ci_check_failed" in
  *"https://example/run/2"*) assert_eq "실패 URL 노출" "ok" "ok" ;;
  *)                          assert_eq "실패 URL 노출" "ok" "missing: $_ci_check_failed" ;;
esac
unset _ci_check_failed

# skipped conclusion 은 실패로 보지 않는다.
_ci_check_skipped=$(
  gh() {
    if [[ "$1" == "run" && "$2" == "list" ]]; then
      printf '%s' '[{"name":"web","status":"completed","conclusion":"success","databaseId":1,"url":"u1"},{"name":"prettier","status":"completed","conclusion":"skipped","databaseId":2,"url":"u2"}]'
      return 0
    fi
    return 0
  }
  out=$(_claude-check-remote-ci-status "wt/issue-546/1" "abcdef0" 0 0 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "skipped conclusion → rc=0" "0" "$(printf '%s\n' "$_ci_check_skipped" | sed -n '1p')"
unset _ci_check_skipped

# UI 워크플로우 skip 필터 — playwright run 이 실패해도 skip_ui=1 이면 rc=0.
_ci_check_ui_filter=$(
  gh() {
    if [[ "$1" == "run" && "$2" == "list" ]]; then
      printf '%s' '[{"name":"web","status":"completed","conclusion":"success","databaseId":1,"url":"u1"},{"name":"playwright e2e","status":"completed","conclusion":"failure","databaseId":2,"url":"u2"},{"name":"lighthouse-ci","status":"completed","conclusion":"failure","databaseId":3,"url":"u3"}]'
      return 0
    fi
    return 0
  }
  out=$(_claude-check-remote-ci-status "wt/issue-546/1" "abcdef0" 0 1 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "skip_ui=1 → playwright/legacy lighthouse 실패 무시 (rc=0)" "0" "$(printf '%s\n' "$_ci_check_ui_filter" | sed -n '1p')"
unset _ci_check_ui_filter

# skip_ui=0 (default) → playwright 실패 → rc=1.
_ci_check_ui_no_filter=$(
  gh() {
    if [[ "$1" == "run" && "$2" == "list" ]]; then
      printf '%s' '[{"name":"web","status":"completed","conclusion":"success","databaseId":1,"url":"u1"},{"name":"playwright e2e","status":"completed","conclusion":"failure","databaseId":2,"url":"u2"}]'
      return 0
    fi
    return 0
  }
  out=$(_claude-check-remote-ci-status "wt/issue-546/1" "abcdef0" 0 0 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "skip_ui=0 → playwright 실패 → rc=1" "1" "$(printf '%s\n' "$_ci_check_ui_no_filter" | sed -n '1p')"
unset _ci_check_ui_no_filter

# 빈 결과 + wait=0 → fail-open (rc=0).
_ci_check_empty=$(
  gh() {
    if [[ "$1" == "run" && "$2" == "list" ]]; then
      printf '%s' '[]'
      return 0
    fi
    return 0
  }
  out=$(_claude-check-remote-ci-status "wt/issue-546/1" "abcdef0" 0 0 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "빈 결과 + wait=0 → fail-open(0)" "0" "$(printf '%s\n' "$_ci_check_empty" | sed -n '1p')"
unset _ci_check_empty

# in_progress + wait=0 → rc=2 (미완료, 실패는 아님).
_ci_check_in_progress=$(
  gh() {
    if [[ "$1" == "run" && "$2" == "list" ]]; then
      printf '%s' '[{"name":"web","status":"in_progress","conclusion":null,"databaseId":1,"url":"u1"}]'
      return 0
    fi
    return 0
  }
  out=$(_claude-check-remote-ci-status "wt/issue-546/1" "abcdef0" 0 0 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "in_progress + wait=0 → rc=2" "2" "$(printf '%s\n' "$_ci_check_in_progress" | sed -n '1p')"
unset _ci_check_in_progress

# 정적 가드 — claude-close-issue 가 #546 가드 helpers 를 호출하는지.
for _fn in "_claude-check-remote-ci-status" "_claude-is-test-type" "_claude-milestone-skip-ui-gate"; do
  if grep -q "$_fn" "${SCRIPT_DIR}/github-workflow.sh"; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "github-workflow.sh 에 ${_fn} 등록 (#546)"
  else
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "${_fn} 누락 (#546 회귀)"
  fi
done
unset _fn

# 정적 가드 — claude-close-issue 본문에 --force / CLAUDE_SKIP_REMOTE_CI_CHECK 우회 분기가 살아있는지.
if grep -q "CLAUDE_SKIP_REMOTE_CI_CHECK" "${SCRIPT_DIR}/github-workflow.sh"; then
  PASS=$((PASS + 1)); printf '  ✅ %s\n' "CLAUDE_SKIP_REMOTE_CI_CHECK 우회 분기 등록 (#546 AC4)"
else
  FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "CLAUDE_SKIP_REMOTE_CI_CHECK 우회 분기 누락 (#546 AC4)"
fi

echo ""
echo "── #1008: claude-check-deps PR MERGED 동치 처리 ───────────"

# claude-check-deps 는 _claude-gh-retry 미경유 — gh() 자체를 서브쉘에서 shadow.

# Case 1 (핵심 회귀): dep = MERGED PR → 통과.
_deps_merged=$(
  gh() {
    case "$*" in
      "issue view 9001 --json body --jq .body") printf 'Depends on #9002\n' ;;
      "issue view 9002 --json state --jq .state") printf 'MERGED\n' ;;
      *) return 1 ;;
    esac
  }
  out=$(claude-check-deps 9001 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "#1008 — MERGED 의존성 → return 0" "0" "$(printf '%s\n' "$_deps_merged" | sed -n '1p')"
case "$_deps_merged" in
  *"✅ #9002 merged"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#1008 — MERGED dep PASS 메시지";;
  *)                    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "MERGED PASS 메시지 누락" "$_deps_merged";;
esac
unset _deps_merged

# Case 2 (기존 동작 회귀 가드): dep = CLOSED issue → 통과.
_deps_closed=$(
  gh() {
    case "$*" in
      "issue view 9003 --json body --jq .body") printf 'Depends on #9004\n' ;;
      "issue view 9004 --json state --jq .state") printf 'CLOSED\n' ;;
      *) return 1 ;;
    esac
  }
  out=$(claude-check-deps 9003 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "#1008 — CLOSED 의존성 → return 0 (기존 동작)" "0" "$(printf '%s\n' "$_deps_closed" | sed -n '1p')"
case "$_deps_closed" in
  *"✅ #9004 closed"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#1008 — CLOSED dep PASS 메시지 유지";;
  *)                    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "CLOSED PASS 메시지 변형" "$_deps_closed";;
esac
unset _deps_closed

# Case 3 (회귀 가드): dep = OPEN → 차단.
_deps_open=$(
  gh() {
    case "$*" in
      "issue view 9005 --json body --jq .body") printf 'Depends on #9006\n' ;;
      "issue view 9006 --json state --jq .state") printf 'OPEN\n' ;;
      *) return 1 ;;
    esac
  }
  out=$(claude-check-deps 9005 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "#1008 — OPEN 의존성 → return 1" "1" "$(printf '%s\n' "$_deps_open" | sed -n '1p')"
case "$_deps_open" in
  *"❌ #9006"*"OPEN"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#1008 — OPEN 차단 메시지";;
  *)                    FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "OPEN 차단 메시지 누락" "$_deps_open";;
esac
unset _deps_open

# Case 4: CLOSED + MERGED 혼합 → 통과 (둘 다 동치이므로 all_closed=true 유지).
_deps_mixed=$(
  gh() {
    case "$*" in
      "issue view 9007 --json body --jq .body") printf 'Depends on #9008\nDepends on #9009\n' ;;
      "issue view 9008 --json state --jq .state") printf 'CLOSED\n' ;;
      "issue view 9009 --json state --jq .state") printf 'MERGED\n' ;;
      *) return 1 ;;
    esac
  }
  out=$(claude-check-deps 9007 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "#1008 — CLOSED + MERGED 혼합 → return 0" "0" "$(printf '%s\n' "$_deps_mixed" | sed -n '1p')"
unset _deps_mixed

# Case 5: MERGED + OPEN 혼합 → 차단 (한 건이라도 미해결이면 fail).
_deps_partial=$(
  gh() {
    case "$*" in
      "issue view 9010 --json body --jq .body") printf 'Depends on #9011\nDepends on #9012\n' ;;
      "issue view 9011 --json state --jq .state") printf 'MERGED\n' ;;
      "issue view 9012 --json state --jq .state") printf 'OPEN\n' ;;
      *) return 1 ;;
    esac
  }
  out=$(claude-check-deps 9010 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "#1008 — MERGED + OPEN 혼합 → return 1" "1" "$(printf '%s\n' "$_deps_partial" | sed -n '1p')"
unset _deps_partial

echo ""
echo "── #1467: 봇 리뷰 regex (jq 필터) ─────────────────────────"

# claude-wait-bot-review 의 jq 필터와 byte-for-byte 동일. i-플래그/매치/미매치 검증.
_bot_filter='[.[] | select(.user.login | test("^(gemini-code-assist|sourcery-ai|copilot)"; "i"))] | length'

assert_eq "#1467 — Copilot(대문자)+gemini 매치 / 사람 미매치 → 2" "2" \
  "$(printf '%s' '[{"user":{"login":"Copilot"}},{"user":{"login":"gemini-code-assist[bot]"}},{"user":{"login":"jemings"}}]' | jq "$_bot_filter")"
assert_eq "#1467 — Copilot 단독 (i-플래그 대문자) → 1" "1" \
  "$(printf '%s' '[{"user":{"login":"Copilot"}}]' | jq "$_bot_filter")"
assert_eq "#1467 — gemini-code-assist[bot] → 1" "1" \
  "$(printf '%s' '[{"user":{"login":"gemini-code-assist[bot]"}}]' | jq "$_bot_filter")"
assert_eq "#1467 — sourcery-ai[bot] → 1" "1" \
  "$(printf '%s' '[{"user":{"login":"sourcery-ai[bot]"}}]' | jq "$_bot_filter")"
assert_eq "#1467 — 사람 로그인만 → 0" "0" \
  "$(printf '%s' '[{"user":{"login":"jemings"}},{"user":{"login":"octocat"}}]' | jq "$_bot_filter")"
unset _bot_filter

echo ""
echo "── #1467: claude-wait-bot-review ──────────────────────────"

# 1) 인자 없음 → return 2.
out=$(claude-wait-bot-review 2>&1)
rc=$?
assert_eq "#1467 — 인자 없음 → return 2" "2" "$rc"
case "$out" in
  *"사용법: claude-wait-bot-review"*) PASS=$((PASS + 1)); printf '  ✅ %s\n' "#1467 — 사용법 stderr 노출";;
  *)                                   FAIL=$((FAIL + 1)); printf '  ❌ %s\n     out: %s\n' "사용법 메시지 누락" "$out";;
esac

# 2) 봇 리뷰 존재(reviews=1) → return 0. sleep 무력화로 즉시 종료.
_wait_detect=$(
  gh() {
    case "$*" in
      "repo view --json nameWithOwner -q .nameWithOwner") printf 'owner/repo\n' ;;
      "api repos/owner/repo/pulls/99/reviews --jq"*) printf '1\n' ;;
      *) return 1 ;;
    esac
  }
  sleep() { :; }
  out=$(claude-wait-bot-review 99 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "#1467 — 봇 리뷰 감지 → return 0" "0" "$(printf '%s\n' "$_wait_detect" | sed -n '1p')"
unset _wait_detect

# 3) 봇 리뷰 0건 고정 → return 1 (10회 폴링 타임아웃). sleep 무력화로 즉시 종료.
_wait_timeout=$(
  gh() {
    case "$*" in
      "repo view --json nameWithOwner -q .nameWithOwner") printf 'owner/repo\n' ;;
      "api repos/owner/repo/pulls/99/reviews --jq"*) printf '0\n' ;;
      *) return 1 ;;
    esac
  }
  sleep() { :; }
  out=$(claude-wait-bot-review 99 2>&1)
  rc=$?
  printf '%d\n%s' "$rc" "$out"
)
assert_eq "#1467 — 봇 리뷰 미도착 → return 1" "1" "$(printf '%s\n' "$_wait_timeout" | sed -n '1p')"
unset _wait_timeout

echo ""
echo "── #1467: _claude-adopt-names ─────────────────────────────"

# 탭 구분 출력은 printf 로 만들어 소스에 리터럴 탭을 박지 않는다.
assert_eq "#1467 — 이슈 모드: 경로 + issue-N-slug 브랜치" \
  "$(printf '.claude/worktrees/issue-5\tissue-5-add-foo-bar')" \
  "$(_claude-adopt-names 5 main 'Add Foo Bar')"
assert_eq "#1467 — 이슈 모드: 한글 제목 → issue-N 폴백" \
  "$(printf '.claude/worktrees/issue-5\tissue-5')" \
  "$(_claude-adopt-names 5 main '한글 제목')"
assert_eq "#1467 — trivial 모드: feature 브랜치명 유지 + 슬러그 경로" \
  "$(printf '.claude/worktrees/quick-fix\tquick-fix')" \
  "$(_claude-adopt-names '' quick-fix '')"
out=$(_claude-adopt-names '' main '' 2>&1)
rc=$?
assert_eq "#1467 — trivial 모드: main + 빈 슬러그 → return 1 (fail-closed)" "1" "$rc"

echo ""
echo "── #1467: claude-adopt-worktree 정적 가드 ─────────────────"

# #213 스타일 정적 회귀 가드 — claude-adopt-worktree 본문에 멱등성을 보장하는
# git-common-dir 비교가 살아있는지. 빠지면 worktree 내부 재호출이 main 동작을
# 수행해 위험하다. git worktree add / reset --hard / stash 의 실전 동작은 단위
# 테스트로 검증하지 않으며(이 파일 :7 방침), #1467 본문의 "adopt-worktree 통합
# 검증" 절차(임시 브랜치 → shgwt.sh teardown)로 수동 수행한다.
if grep -q -- '--git-common-dir' "${SCRIPT_DIR}/github-workflow.sh"; then
  PASS=$((PASS + 1))
  printf '  ✅ %s\n' "claude-adopt-worktree 가 git-common-dir 멱등 가드를 포함 (#1467)"
else
  FAIL=$((FAIL + 1))
  printf '  ❌ %s\n' "claude-adopt-worktree 의 git-common-dir 멱등 가드가 사라짐 (#1467 회귀)"
fi

echo ""
echo "── #1486: _claude-commit-types-to-labels (순수 매핑) ───────"

# claude-apply-pr-labels 의 type→라벨 매핑 SSOT. stdin 으로 commit subject 를 받아
# dedup 된 후보 라벨을 출력한다 — 네트워크/git 비의존이라 여기서 단위 검증한다.

# 1) 10개 타입 전수 매핑.
assert_eq "#1486 — feat → enhancement" "enhancement" \
  "$(printf 'feat: add thing\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — fix → bug" "bug" \
  "$(printf 'fix: broken thing\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — docs → documentation" "documentation" \
  "$(printf 'docs: update readme\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — refactor → refactor" "refactor" \
  "$(printf 'refactor: cleanup\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — style → style" "style" \
  "$(printf 'style: format\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — perf → performance" "performance" \
  "$(printf 'perf: speed up\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — test → test" "test" \
  "$(printf 'test: add tests\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — chore → chore" "chore" \
  "$(printf 'chore: bump dep\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — ci → ci" "ci" \
  "$(printf 'ci: tweak workflow\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — build → build" "build" \
  "$(printf 'build: update config\n' | _claude-commit-types-to-labels)"

# 2) scope/breaking 변형 — `type(scope):`, `type!:`, `type(scope)!:` 모두 인식.
assert_eq "#1486 — scope 포함: fix(review) → bug" "bug" \
  "$(printf 'fix(review): correct step\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — breaking: feat! → enhancement" "enhancement" \
  "$(printf 'feat!: breaking change\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — scope+breaking: feat(api)! → enhancement" "enhancement" \
  "$(printf 'feat(api)!: breaking change\n' | _claude-commit-types-to-labels)"

# 3) 대소문자 무시 — `Feat:` 도 enhancement.
assert_eq "#1486 — 대문자 타입 Feat → enhancement" "enhancement" \
  "$(printf 'Feat: Add New Feature\n' | _claude-commit-types-to-labels)"

# 4) dedup + 첫 등장 순서 보존 — feat,fix,feat → enhancement,bug (1회씩).
assert_eq "#1486 — dedup + 등장 순서 보존" \
  "$(printf 'enhancement\nbug')" \
  "$(printf 'feat: a\nfix: b\nfeat: c\n' | _claude-commit-types-to-labels)"

# 5) 비-conventional subject / 매핑 없는 타입은 조용히 건너뜀.
assert_eq "#1486 — 비-conventional subject → 빈 출력" "" \
  "$(printf 'Merge branch main\nupdate stuff\n' | _claude-commit-types-to-labels)"
assert_eq "#1486 — 매핑 없는 타입(wip) → 빈 출력" "" \
  "$(printf 'wip: experiment\n' | _claude-commit-types-to-labels)"

# 6) 빈 입력 → 빈 출력 (행 없음).
assert_eq "#1486 — 빈 입력 → 빈 출력" "" \
  "$(printf '' | _claude-commit-types-to-labels)"

# 7) 혼합 스트림 — conventional 만 추려 매핑 (close-issue 커밋 형식 `type: #N desc` 포함).
assert_eq "#1486 — 혼합 스트림: conventional 만 매핑" \
  "$(printf 'bug\ndocumentation')" \
  "$(printf 'fix: #1486 close-issue style\nMerge pull request #99\ndocs: #1486 update guide\n' | _claude-commit-types-to-labels)"

echo ""
echo "── #1486: closing keyword regex (severity 추출 필터) ──────"

# claude-apply-pr-labels 의 grep 필터와 byte-for-byte 동일 — 구 post-pr-create-severity
# 훅 테스트(#273, #1486 에서 삭제)의 regex 커버리지 후신. keyword variant +
# cross-repo(`owner/repo#N`) 제외를 검증한다 (#1467 봇 regex 테스트와 동일 패턴).
_closing_re='(?<![\w/])(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?)\s+#\K[0-9]+'
_extract_closing() {
  grep -oiP "$_closing_re" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//'
}

assert_eq "#1486 — Closes #10 → 10" "10" "$(printf 'Closes #10' | _extract_closing)"
assert_eq "#1486 — 변형+대소문자: FIXES/Resolved" "11 12" \
  "$(printf 'FIXES #11\nResolved #12' | _extract_closing)"
assert_eq "#1486 — cross-repo owner/repo#N 제외" "60" \
  "$(printf 'Fixes owner/repo#99 and Closes #60' | _extract_closing)"
assert_eq "#1486 — 단어 내 키워드(prefixes) 미추출" "" \
  "$(printf 'prefixes #5' | _extract_closing)"
assert_eq "#1486 — Refs 미추출 (ref-issue 본문 보호)" "" \
  "$(printf 'Refs #777' | _extract_closing)"
assert_eq "#1486 — 키워드 없는 #N 미추출 (커밋 제목 형식)" "" \
  "$(printf 'feat: #777 desc' | _extract_closing)"
unset -f _extract_closing
unset _closing_re

echo ""
echo "── #1486: PR 후처리 공유 함수 정적 가드 ────────────────────"

# #213/#1467 스타일 정적 회귀 가드 — close-issue/ref-issue 가 공유 wrapper 를
# 경유하는지. 직접 `gh pr create` 호출로 되돌아가면 self-assign·라벨 SSOT 가 깨진다.
# (claude-pr-create-from-body 함수 본문 안의 1회 호출만 허용. 패턴은 인자 따옴표가
# 따라붙는 실제 호출 형태 `gh pr create "` 로 좁혀 주석 언급을 제외한다.)
_direct_create_count=$(grep -c 'gh pr create "' "${SCRIPT_DIR}/github-workflow.sh")
assert_eq "#1486 — 직접 gh pr create 호출은 wrapper 내부 1곳뿐" "1" "$_direct_create_count"
unset _direct_create_count

for _fn in claude-apply-pr-labels claude-pr-create-from-body _claude-push-pr-branch; do
  if grep -q "^${_fn}()" "${SCRIPT_DIR}/github-workflow.sh"; then
    PASS=$((PASS + 1)); printf '  ✅ %s\n' "github-workflow.sh 에 ${_fn} 등록 (#1486)"
  else
    FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "${_fn} 누락 (#1486 회귀)"
  fi
done

echo ""
echo "── 결과 ───────────────────────────────────────────────────"
echo "  통과: $PASS / 실패: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
