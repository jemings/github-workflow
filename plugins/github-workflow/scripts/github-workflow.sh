# shellcheck shell=bash
# GitHub Issue 기반 워크플로우 함수 모음 (github-workflow 스킬의 함수 SSOT).
#
# 사용법 (플러그인 설치 환경):
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/github-workflow.sh"
# 또는 로컬 체크아웃:
#   source scripts/github-workflow.sh
#
# 설계·정책 설명은 docs/github-integration.md 를 참고.
# 이 파일은 함수 본문만 담는 단일 source of truth 다.
#
# 사전 조건:
#   - gh CLI 인증 완료 + 'project' 스코프 포함 (gh auth refresh -s project)
#   - jq 설치
#   - bash 4+ · git
#   - 현재 디렉토리가 대상 Git 저장소 루트(또는 워크트리)
#   - Project 보드 설정: CLAUDE_PROJECT_OWNER / CLAUDE_PROJECT_NUMBER (아래 참고)

# ────────────────────────────────────────────────────────────────────
# Project 보드 공용 설정 (사용자별)
# 조직 범위(organization scope) GitHub Project 의 소유자(=org login)·번호.
# 이 스킬은 org-scoped Project 를 가정한다 (모든 GraphQL 이 organization(login)).
# Status 필드 옵션은 Backlog / Ready / In progress / In review / Approved / Done.
# Issue와 PR은 독립 트랙으로 동작한다:
#   - Issue: Backlog → In progress(claude-start-issue) → Done(머지 시 자동)
#   - PR:    → In review(claude-close-issue) → Approved(빌트인) → Done(머지 시 자동)
# 상세: docs/github-integration.md — Project 보드 상태 전환 정책
#
# 설정 우선순위 (먼저 정해진 값이 이김):
#   1) 이미 export 된 환경변수 CLAUDE_PROJECT_OWNER / CLAUDE_PROJECT_NUMBER
#   2) 설정 파일 — $CLAUDE_GW_CONFIG, 없으면 <repo>/.github-workflow.config
#      (이 파일은 bash 로 source 되며 위 두 변수를 지정한다)
#   3) 미설정 → 빈 값. 보드 함수 첫 호출 시 친절한 셋업 안내 후 return 1.
# source 시점에는 절대 실패하지 않는다(순수 헬퍼 테스트 보호). 셋업 가이드:
# docs/board-setup.md · scripts/setup-board.sh.
# ────────────────────────────────────────────────────────────────────
if [[ -z "${CLAUDE_PROJECT_OWNER:-}" || -z "${CLAUDE_PROJECT_NUMBER:-}" ]]; then
  _gw_cfg="${CLAUDE_GW_CONFIG:-${CLAUDE_PROJECT_DIR:-$PWD}/.github-workflow.config}"
  # shellcheck source=/dev/null
  [[ -f "$_gw_cfg" ]] && source "$_gw_cfg"
  unset _gw_cfg
fi
CLAUDE_PROJECT_OWNER="${CLAUDE_PROJECT_OWNER:-}"
CLAUDE_PROJECT_NUMBER="${CLAUDE_PROJECT_NUMBER:-}"

# 보드 설정 가드 — owner/number 미설정 시 친절한 안내 후 비-0.
# 보드/Project API 를 호출하는 함수가 첫 줄에서 호출한다.
_claude-require-project-config() {
  if [[ -z "$CLAUDE_PROJECT_OWNER" || -z "$CLAUDE_PROJECT_NUMBER" ]]; then
    echo "❌ Project 보드 설정 누락: CLAUDE_PROJECT_OWNER / CLAUDE_PROJECT_NUMBER" >&2
    echo "   설정 방법(택1):" >&2
    echo "   1) export CLAUDE_PROJECT_OWNER=<org-login> CLAUDE_PROJECT_NUMBER=<n>" >&2
    echo "   2) <repo>/.github-workflow.config 생성 후 두 변수 지정 (예시: .github-workflow.config.example)" >&2
    echo "   3) bash scripts/setup-board.sh — 보드 생성 + 설정 파일 자동 작성" >&2
    echo "   상세: docs/board-setup.md" >&2
    return 1
  fi
  return 0
}

# ────────────────────────────────────────────────────────────────────
# 보류 라벨 가드 (#233)
# 이 배열의 라벨이 붙은 이슈는 claude-enter-issue 가 worktree spawn 직전에
# 거부한다. 명시적으로 보류된 이슈에 대한 모델 호출/토큰 소비를 원천 차단.
# 다국어 확장 여지를 위해 배열로 관리한다 (현재 한국어 우선).
# ────────────────────────────────────────────────────────────────────
CLAUDE_BLOCKED_LABELS=("보류")

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 세션 선점 판정
# 현재 브랜치가 issue-<N>-... 형식이면 바인딩된 이슈 번호를 echo + return 0.
# 아니면 return 1.
# ────────────────────────────────────────────────────────────────────
claude-session-bound() {
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1

  # BASH_REMATCH[1]에 이슈 번호가 캡처된다.
  # 한글 전용 제목이면 슬러그가 비어 브랜치명이 issue-N으로 끝날 수 있으므로
  # 트레일링 하이픈 또는 줄 끝 양쪽을 모두 허용한다.
  if [[ "$branch" =~ ^issue-([0-9]+)(-|$) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — main worktree 루트 경로
# git worktree list의 첫 엔트리가 main worktree (primary) 이므로 그 경로를 반환.
# 현재 세션이 worktree 내부에서 실행 중이더라도 main worktree 경로를 찾아내야
# .claude/worktrees/issue-<N> 상대 경로를 안정적으로 만들 수 있다.
# ────────────────────────────────────────────────────────────────────
claude-main-worktree-path() {
  git worktree list --porcelain 2>/dev/null \
    | awk '$1=="worktree"{print $2; exit}'
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 이슈 제목 → 브랜치 슬러그
# 사용법: claude-issue-slug <title>
# 출력: 빈 문자열 또는 a-z0-9-로 구성된 최대 40자 슬러그.
# 비ASCII(한글/이모지 등)는 제거되며, 결과적으로 슬러그가 비면 빈 문자열을 반환.
# 호출자는 빈 슬러그일 때 브랜치명을 'issue-N'(트레일링 하이픈 없음)으로 만든다.
# ────────────────────────────────────────────────────────────────────
claude-issue-slug() {
  local title="$1"

  # 파이프라인:
  #   1) 소문자화
  #   2) 공백 → 하이픈
  #   3) [a-z0-9-] 외 모두 제거 (비ASCII는 여기서 사라진다)
  #   4) 연속 하이픈을 단일 하이픈으로 압축
  #   5) 양 끝 하이픈 제거 — 한글-하이픈만 남는 케이스에서 필수
  #   6) 40자 자르기
  #   7) head -c가 하이픈 위치에서 잘렸을 가능성에 대비해 트레일링 하이픈 한 번 더 제거
  local slug
  slug=$(printf '%s' "$title" \
    | tr '[:upper:]' '[:lower:]' \
    | tr ' ' '-' \
    | tr -cd 'a-z0-9-' \
    | tr -s '-' \
    | sed -E 's/^-+//; s/-+$//' \
    | head -c 40)
  printf '%s' "${slug%-}"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — gh 호출 재시도 래퍼 (#26)
# 사용법: _claude-gh-retry gh api ... / _claude-gh-retry gh repo view ...
# 간헐적 네트워크 실패(사내 프록시의 connection reset 등)를 흡수한다.
# 최대 3회, 대기 간격 2s → 5s.
#
# 성공 시 명령어의 stdout을 그대로 출력하고 return 0.
# 실패 시 마지막 시도의 stderr만 호출자에게 전달하고 마지막 종료 코드로 return.
# 중간 시도의 stderr를 숨기는 이유: 재시도 중간에 "connection reset" 같은 에러를
# 호출자 stderr로 내보내면 최종 성공 케이스에서도 사용자가 실패를 의심하게 된다.
# ────────────────────────────────────────────────────────────────────
_claude-gh-retry() {
  local max_attempts=3
  local attempt=1
  local out rc=0 delay
  local tmp_err
  # mktemp 실패(/tmp 공간 부족 등) 시 빈 tmp_err이 다음 리다이렉션/cat에서 엉뚱한
  # 동작을 유발하므로 즉시 조기 반환한다.
  tmp_err=$(mktemp) || return 1

  while (( attempt <= max_attempts )); do
    # 주의: `if cmd; then ... fi` 뒤 $?는 else 블록이 없으면 0이 된다 (Bash spec).
    # 그래서 실패 코드를 잡으려면 반드시 else 안에서 $?를 캡처해야 한다.
    if out=$("$@" 2>"$tmp_err"); then
      printf '%s' "$out"
      rm -f "$tmp_err"
      return 0
    else
      rc=$?
    fi

    if (( attempt < max_attempts )); then
      # #630: 배열 인덱싱은 bash 0-indexed / zsh 1-indexed 차이로 zsh에서 빈
      # 문자열을 반환 (`sleep: invalid time interval ''`). case 문으로 우회한다.
      case $attempt in
        1) delay=2 ;;
        2) delay=5 ;;
        *) delay=5 ;;
      esac
      echo "⚠️  gh 호출 실패(attempt ${attempt}/${max_attempts}), ${delay}s 후 재시도..." >&2
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done

  # 최종 실패: 마지막 시도의 stderr를 호출자에게 전달해 디버깅 가능하게 한다.
  cat "$tmp_err" >&2
  rm -f "$tmp_err"
  return "$rc"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — Project 보드 Status 전환
# 사용법: claude-set-content-status <content-node-id> <status> <label>
# <status>: "Backlog" | "Ready" | "In progress" | "In review" | "Approved" | "Done"
# <label>: 로그에 찍히는 표시용 이름 ("#34", "PR #113" 등).
# content가 Project에 없으면 자동으로 추가 후 상태 설정(idempotent).
# Issue·PR 공통 경로 — 상위 wrapper(claude-set-issue-status / claude-set-pr-status)가
# 각각 node_id를 조회해 이 함수에 넘긴다.
#
# 실패 처리 (#26):
#   - 각 gh 호출은 _claude-gh-retry로 감싸 프록시 RST 등 일시 장애를 흡수한다.
#   - 모든 중간 변수(project_id, item_id 등)에 빈값/null 검증을 적용한다.
#   - 최종 mutation 응답의 projectV2Item.id를 확인한 뒤에만 ✅를 출력한다.
#
# `gh api` 변수 전달 규칙 (#213):
#   - GraphQL `String!` / `ID!` 변수는 `-f`(raw-field)로 강제. `-F`(field)는 순수
#     숫자 값을 정수로 자동 캐스팅해 GraphQL String! 타입과 충돌한다 — 본 프로젝트의
#     `Done` option_id `98236657`는 hex 글자가 없는 순수 숫자라 이 회귀에 노출됐다.
#     다른 옵션(In progress, Approved 등)은 hex 글자 포함이라 그동안 드러나지 않았다.
#   - GraphQL `Int!` 변수(`number` 등)는 `-F` 유지 — 정수 캐스팅이 의도된 동작.
#
# 설계 노트 — set -euo pipefail을 도입하지 않는 이유:
#   이 파일은 사용자 셸에 source되므로 전역 `set -e`는 대화형 셸에 부작용을 남긴다.
#   `local -`/함수 서브셸 방식도 검토했으나, (a) 서브셸은 호출자 변수에 영향을 주지
#   않아 상태 추적이 어렵고 (b) 함수 단위 `local -`로 `errexit`만 켜도 파이프라인
#   중간 실패가 여전히 삼켜지는 경계 케이스가 있다. 대신 각 호출 결과를 명시적
#   `|| return 1` + 빈값 검증으로 막아 동등한 안전성을 확보한다.
# ────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # GraphQL 변수 리터럴 — 셸 확장 의도적 차단 (함수 전체 적용)
#
# 변수명 주의 (#82): 두 번째 인자를 받는 로컬 변수는 `target_status`다.
# zsh에서 `$status`는 `$?` 별칭의 read-only 특수 변수이므로 `local status=...`는
# 함수 본문 파싱 단계에서 'read-only variable: status' 에러를 낸다. bash에는
# 예약되어 있지 않아 bash 단독 환경에선 드러나지 않는 회귀이므로,
# claude-set-issue-status/claude-set-pr-status 등 같은 인자를 받는 함수는
# 모두 `target_status`로 통일한다.
claude-set-content-status() {
  local content_node_id="$1"
  local target_status="$2"
  local label="$3"

  _claude-require-project-config || return 1

  if [[ -z "$content_node_id" || "$content_node_id" == "null" ]]; then
    echo "❌ content_node_id가 비어 있습니다 (${label})." >&2
    return 1
  fi

  # 1) Project 메타데이터 조회: project_id + Status 필드 ID + 옵션 목록.
  local meta
  meta=$(_claude-gh-retry gh api graphql -f query='
    query($owner: String!, $number: Int!) {
      organization(login: $owner) {
        projectV2(number: $number) {
          id
          field(name: "Status") {
            ... on ProjectV2SingleSelectField {
              id
              options { id name }
            }
          }
        }
      }
    }' \
    -f owner="$CLAUDE_PROJECT_OWNER" \
    -F number="$CLAUDE_PROJECT_NUMBER") || {
      echo "❌ Project 메타데이터 조회 실패 (네트워크 또는 권한)." >&2
      return 1
    }

  local project_id field_id option_id
  project_id=$(printf '%s' "$meta" | jq -r '.data.organization.projectV2.id')
  field_id=$(printf '%s' "$meta" | jq -r '.data.organization.projectV2.field.id')

  # project_id=null → 메타 쿼리 자체가 실패. 'project' 스코프 누락이나 소유자/번호
  # 오기입이 가장 흔한 원인이므로, 맥락 없는 GraphQL 최종 오류를 맞기 전에 조기 return.
  # 이 가드는 option_id 추출(아래 .options[]) 전에 수행해야 한다 — project_id/field_id가
  # null이면 jq가 'Cannot iterate over null'을 stderr에 먼저 쏟아내 UX가 깨진다.
  if [[ -z "$project_id" || "$project_id" == "null" ]]; then
    echo "❌ Project 메타데이터 조회 실패 (project_id=null)." >&2
    echo "   가능한 원인:" >&2
    echo "   1) gh 토큰에 'project' 스코프 없음 → gh auth refresh -s project" >&2
    echo "      (README §전제조건 참고)" >&2
    echo "   2) CLAUDE_PROJECT_OWNER/CLAUDE_PROJECT_NUMBER 불일치 → .github-workflow.config 또는 환경변수 확인 (docs/board-setup.md)" >&2
    return 1
  fi

  # field_id=null → Project는 접근 가능하나 'Status' 필드가 없음/이름이 다름.
  if [[ -z "$field_id" || "$field_id" == "null" ]]; then
    echo "❌ Project에 'Status' 필드(ProjectV2SingleSelectField)가 없습니다." >&2
    echo "   Project 설정에서 Status 필드를 먼저 생성하세요." >&2
    return 1
  fi

  option_id=$(printf '%s' "$meta" | jq -r --arg s "$target_status" \
    '.data.organization.projectV2.field.options[] | select(.name==$s) | .id')

  if [[ -z "$option_id" || "$option_id" == "null" ]]; then
    echo "❌ Status 옵션 '$target_status'을 Project에서 찾을 수 없습니다." >&2
    return 1
  fi

  # 2) content를 Project에 추가(이미 있으면 기존 item 반환 — idempotent).
  local item_id
  item_id=$(_claude-gh-retry gh api graphql -f query='
    mutation($project: ID!, $content: ID!) {
      addProjectV2ItemById(input: {projectId: $project, contentId: $content}) {
        item { id }
      }
    }' \
    -f project="$project_id" \
    -f content="$content_node_id" \
    --jq '.data.addProjectV2ItemById.item.id') || {
      echo "❌ Project에 ${label} 추가 실패." >&2
      return 1
    }
  if [[ -z "$item_id" || "$item_id" == "null" ]]; then
    echo "❌ Project 아이템 ID를 받지 못했습니다 (addProjectV2ItemById)." >&2
    return 1
  fi

  # 3) Status 필드 값 업데이트. 응답을 버리지 않고 캡처해 projectV2Item.id를 검증한다
  #    — 이 검증이 없으면 mutation이 GraphQL 에러를 돌려줘도 '✅' 거짓말이 나간다 (#26).
  local update_response updated_id
  update_response=$(_claude-gh-retry gh api graphql -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $project, itemId: $item, fieldId: $field,
        value: {singleSelectOptionId: $option}
      }) { projectV2Item { id } }
    }' \
    -f project="$project_id" \
    -f item="$item_id" \
    -f field="$field_id" \
    -f option="$option_id") || {
      echo "❌ Status 업데이트 mutation 실패." >&2
      return 1
    }

  updated_id=$(printf '%s' "$update_response" | jq -r '.data.updateProjectV2ItemFieldValue.projectV2Item.id // empty')
  if [[ -z "$updated_id" ]]; then
    echo "❌ Status 업데이트가 성공 응답을 반환하지 않았습니다." >&2
    echo "   응답: $update_response" >&2
    return 1
  fi

  echo "✅ ${label} → ${target_status}"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — repos/<owner/repo>/{issues|pulls}/<N>에서 GraphQL node_id 조회.
# 사용법: _claude-content-node-id <type> <number>
#   <type>: "issues" | "pulls"
# ────────────────────────────────────────────────────────────────────
_claude-content-node-id() {
  local type="$1"
  local number="$2"
  # type 오기입(예: "issue" 단수형) 시 REST API가 404를 돌려주고 맥락 없는 에러가
  # 남으므로 명시적 가드로 조기 차단한다.
  case "$type" in
    issues|pulls) ;;
    *)
      echo "❌ _claude-content-node-id: type은 'issues' 또는 'pulls'이어야 합니다 (got='${type}')." >&2
      return 1
      ;;
  esac
  local repo node_id
  repo=$(_claude-gh-retry gh repo view --json nameWithOwner --jq .nameWithOwner) || {
    echo "❌ 저장소 정보 조회 실패 (gh repo view)." >&2
    return 1
  }
  if [[ -z "$repo" || "$repo" == "null" ]]; then
    echo "❌ 저장소 nameWithOwner가 비어 있습니다." >&2
    return 1
  fi
  node_id=$(_claude-gh-retry gh api "repos/${repo}/${type}/${number}" --jq .node_id) || {
    echo "❌ ${type} #${number} node_id 조회 실패 (repo=${repo})." >&2
    return 1
  }
  if [[ -z "$node_id" || "$node_id" == "null" ]]; then
    echo "❌ ${type} #${number}의 node_id가 비어 있습니다." >&2
    return 1
  fi
  printf '%s\n' "$node_id"
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-set-issue-status <issue-number> <status>
# <status>: "Backlog" | "Ready" | "In progress" | "In review" | "Approved" | "Done"
# Issue를 Project 보드의 <status>로 이동 (idempotent).
# content node_id를 조회해 claude-set-content-status에 위임한다.
#
# Issue 트랙: Backlog → Ready → In progress → Done (#34, #104).
# Ready = 다음 마일스톤 Issue 등록 완료 후 claude-set-issue-status <N> "Ready" 로 승격.
# Approved는 PR 카드 전용이지만 헬퍼 자체는
# 입력 status를 검증하지 않으므로 6개 옵션 모두 받을 수 있다.
# ────────────────────────────────────────────────────────────────────
claude-set-issue-status() {
  local issue_number="$1"
  local target_status="$2"

  # CLOSED 가드 (#645): forward-only 상태(Ready/Backlog/In progress) 로 닫힌 이슈를
  # 옮기지 못하도록 fail-closed. Done 은 정상 close 경로이므로 허용하며, In review/
  # Approved 는 Issue 트랙에서 사용되지 않으므로 검사 생략. 상위 함수 가드(#645
  # _claude-post-issue-create) 가 우회된 직접 호출 경로(claude-start-issue,
  # post-pr-create-status hook 등) 까지 차단한다.
  case "$target_status" in
    Ready|Backlog|"In progress")
      local issue_state
      issue_state=$(_claude-gh-retry gh issue view "$issue_number" --json state --jq .state) || {
        echo "❌ #${issue_number}: state 조회 실패 — '${target_status}' 전환 차단 (#645 회귀 가드)." >&2
        return 1
      }
      if [[ "$issue_state" == "CLOSED" ]]; then
        echo "❌ #${issue_number}: 이미 CLOSED — '${target_status}' 전환 차단 (#645 회귀 가드)." >&2
        echo "   닫힌 이슈는 Done 컬럼을 유지해야 합니다. 강제로 옮기려면 'gh issue reopen ${issue_number}' 후 다시 시도하세요." >&2
        return 1
      fi
      ;;
  esac

  # Forward-only 보드 가드 (#671): OPEN 이슈가 이미 보드의 forward 단계
  # (In progress / In review / Approved / Done) 에 있을 때 Ready·Backlog 로
  # 되돌리는 자동화 호출(_claude-post-issue-create 의 milestone 재적용, post-pr-create-status
  # 훅의 URL 오추출 등) 을 fail-closed 로 차단한다. #645 CLOSED 가드의 OPEN-and-past-Ready
  # 동치 확장 — #627 회귀 trigger.
  case "$target_status" in
    Ready|Backlog)
      local current_board_status
      current_board_status=$(_claude-current-board-status "$issue_number" issues) || {
        echo "❌ #${issue_number}: 보드 status 조회 실패 — '${target_status}' 전환 차단 (#671 forward-only 가드)." >&2
        return 1
      }
      case "$current_board_status" in
        "In progress"|"In review"|"Approved"|"Done")
          echo "❌ #${issue_number}: 현재 보드 '${current_board_status}' → '${target_status}' backward 전환 차단 (#671)." >&2
          echo "   forward-only 정책: Ready/Backlog 로의 회귀는 자동화 경로에서 차단됩니다." >&2
          echo "   강제로 옮기려면: 사람이 GitHub 보드에서 직접 드래그." >&2
          return 1
          ;;
      esac
      ;;
  esac

  local node_id
  node_id=$(_claude-content-node-id issues "$issue_number") || return 1
  claude-set-content-status "$node_id" "$target_status" "#${issue_number}"
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-set-pr-status <pr-number> <status>
# <status>: "Backlog" | "Ready" | "In progress" | "In review" | "Approved" | "Done"
# (PR 트랙은 운영상 Backlog/Ready를 사용하지 않음. #104)
# PR 카드를 Project 보드의 <status>로 이동 (idempotent).
# Project 보드는 Issue·PR을 독립 트랙으로 다룬다 (#34):
#   - Issue: Backlog → In progress → Done (In review 미거침)
#   - PR:    In review → Approved → Done (Blocked 시 🚫 Blocked 라벨, In review 유지 #538)
# `claude-close-issue`는 이 함수로 PR을 `In review`로 전환한다.
# CHANGES_REQUESTED · 의존 이슈 open 시 `🚫 Blocked` 라벨만 부착한다 (#747).
# CI 차원은 별도 `🔴 CI fail` 라벨이 담당 (#746) — `🚫 Blocked` 와 직교.
# In progress 이동은 더 이상 운영 컨벤션이 아니다 (#538, github-integration.md).
#
# Approved 가드 (#231):
#   target_status="Approved" 호출은 PR 의 `reviewDecision == APPROVED` 일 때만 통과.
#   외부 자동화가 사람 리뷰 없이 Status 필드만 "Approved" 로 set 하면 보드의
#   "Approved 컬럼 = reviewer 가 Approve 한 PR" 단일 의미가 깨진다 (PR #230 사고).
#   빌트인 워크플로우 "Pull request approved" 가 정상 경로 — 사람이 GitHub 리뷰를
#   Approve 로 제출하면 자동 전환된다.
# ────────────────────────────────────────────────────────────────────
claude-set-pr-status() {
  local pr_number="$1"
  local target_status="$2"

  if [[ "$target_status" == "Approved" ]]; then
    local review_decision
    review_decision=$(_claude-gh-retry gh pr view "$pr_number" --json reviewDecision --jq .reviewDecision) || {
      echo "❌ PR #${pr_number}: reviewDecision 조회 실패 — 'Approved' 전환 차단 (#231)." >&2
      return 1
    }
    if [[ "$review_decision" != "APPROVED" ]]; then
      echo "❌ PR #${pr_number}: reviewDecision='${review_decision:-<empty>}' — 'Approved' 컬럼은 reviewDecision=APPROVED 인 PR 전용 (#231)." >&2
      echo "   사람 reviewer 가 'Approve' 리뷰를 제출하면 빌트인 워크플로우 \"Pull request approved\" 가 자동으로 Approved 컬럼으로 이동시킵니다." >&2
      return 1
    fi
  fi

  local node_id
  node_id=$(_claude-content-node-id pulls "$pr_number") || return 1
  claude-set-content-status "$node_id" "$target_status" "PR #${pr_number}"
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-pr-merge <pr-number> [extra gh pr merge args...]
#
# `gh pr merge` 의 fail-closed wrapper (#269). 본 저장소는 Free plan private repo
# 라 GitHub branch protection / required-reviews 가 사용 불가하므로, "review 통과"
# 강제는 클라이언트 측 가드뿐이다. 권한 보유자가 `gh pr merge` 를 직접 호출하면
# review 없이도 머지가 통과되는 구멍을 막기 위해, 모든 머지 경로를 본 wrapper
# 로 일원화한다.
#
# 가드 (둘 다 통과해야 머지 위임):
#   1) `gh pr view --json reviewDecision` 이 APPROVED 인지 — 사람 reviewer 의
#      Approve 가 등록돼야 함.
#   2) Project 보드 카드 Status 가 'Approved' 인지 — #231 이 reviewDecision 과
#      Status 의 동기화를 보장하므로 두 조건이 동시 성립한다. 두 번 검사하는 이유는
#      mutation 직후 보드가 되돌아가는 경합(#60) 또는 외부 자동화에 의한 컬럼 이동
#      등을 함께 감지하기 위함이다.
#
# 동작:
#   - 두 가드 통과: `gh pr merge <pr> --rebase --auto "$@"` 위임. 추가 인자는
#     호출자가 그대로 넘겨서 `--delete-branch` 등을 선택할 수 있다.
#   - 미통과: stderr 로 차단 사유 출력 후 비-zero 종료. 머지 호출 자체를 하지 않는다.
#
# PR 머지 전략 두 항목(worktree 기반 / 메인 직접 작업)은 모두 본 wrapper
# 호출로 통일된다 (docs/github-integration.md §Issue Resolve).
# ────────────────────────────────────────────────────────────────────
claude-pr-merge() {
  local pr_number="$1"
  shift || true

  if [[ -z "${pr_number:-}" ]]; then
    echo "❌ 사용법: claude-pr-merge <pr-number> [extra gh pr merge args...]" >&2
    return 1
  fi

  # 1) reviewDecision 재조회 (fail-closed).
  local review_decision
  review_decision=$(_claude-gh-retry gh pr view "$pr_number" --json reviewDecision --jq .reviewDecision) || {
    echo "❌ PR #${pr_number}: reviewDecision 조회 실패 — 머지 차단 (#269)." >&2
    return 1
  }
  if [[ "$review_decision" != "APPROVED" ]]; then
    echo "❌ PR #${pr_number}: reviewDecision='${review_decision:-<empty>}' — 머지하려면 reviewer 의 Approve 가 필요합니다 (#269)." >&2
    return 1
  fi

  # 2) 보드 Status == Approved 확인 (#60 의 사후 검증과 동일 GraphQL 경로 재사용).
  local pr_node_id
  pr_node_id=$(_claude-content-node-id pulls "$pr_number") || {
    echo "❌ PR #${pr_number}: node_id 조회 실패 — 머지 차단 (#269)." >&2
    return 1
  }
  if ! claude-verify-content-status "$pr_node_id" "Approved" "PR #${pr_number}" >/dev/null 2>&1; then
    echo "❌ PR #${pr_number}: 보드 Status != 'Approved' — 머지 차단 (#269)." >&2
    echo "   reviewDecision=APPROVED 라도 빌트인 워크플로우 'Pull request approved' 가" >&2
    echo "   카드를 Approved 컬럼으로 옮기지 않은 상태일 수 있습니다 — 컬럼을 확인하세요." >&2
    return 1
  fi

  echo "✅ PR #${pr_number}: 가드 통과 (reviewDecision=APPROVED, 보드=Approved)"
  _claude-gh-retry gh pr merge "$pr_number" --rebase --auto "$@"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — Project 내장 워크플로우 충돌 감사 (#12, #252, #1000)
# 사용법: claude-audit-builtin-workflows
#
# 감사 대상 빌트인 워크플로우가 enabled 상태이면 stderr 로 경고를 출력한다.
# 현재 감사 대상은 두 건 — 둘 다 PR/Issue 트랙 정책을 깨는 GitHub 빌트인이다:
#
#   1) "Pull request linked to issue" (#252)
#      PR ↔ Issue 양방향 status 복사 → `claude-close-issue` 가 PR 카드를
#      In review 로 옮기는 순간 이슈 카드도 In review 로 끌려가 Issue/PR
#      독립 트랙(#34) 이 깨진다.
#
#   2) "Code changes requested" (#1000)
#      CHANGES_REQUESTED 리뷰 제출 시 PR Status 를 In progress 로 자동 이동
#      → "Blocked 시 라벨만 부착하고 In review 유지" 정책(#538) 위반.
#      `🚫 Blocked` 라벨(`review-label.yml`)·`🔴 CI fail` 라벨(`ci-label.yml`)
#      자체는 보드 mutation 을 하지 않으므로 이 빌트인이 회귀의 직접 trigger.
#
# 운영 정책 (#12 / #252 / #1000):
#   - GraphQL 에 enable/disable mutation 이 없으므로 운영자가 UI 에서 수동 비활성화.
#     https://github.com/orgs/<owner>/projects/<n>/workflows
#   - 이 헬퍼는 회귀 감지(soft warn) 만 담당 — 작업 흐름은 차단하지 않는다.
#
# #34 회귀 사고 (#252):
#   #34 가 "Issue/PR 트랙 분리로 경합이 사라졌다" 고 잘못 판단해 본 헬퍼와
#   호출부를 한꺼번에 제거한 적이 있다. 빌트인 워크플로우는 PR 카드 변경을
#   trigger 로 이슈 카드까지 옮기므로, 스크립트가 이슈 status 를 만지지 않더라도
#   경합은 구조적으로 그대로 남아 있다 — 감사가 유일한 회귀 가시화 수단.
# ────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # GraphQL 변수 리터럴 — 셸 확장 의도적 차단
claude-audit-builtin-workflows() {
  _claude-require-project-config || return 1
  # 감사 대상 — `<name>|<위반 사유 한 줄>` 형식. 추후 신규 빌트인 추가 시 행만 늘리면 됨.
  local -a conflicting=(
    "Pull request linked to issue|PR 카드 Status 변경 시 연결 이슈 카드까지 함께 이동 → Issue/PR 독립 트랙(#34) 위반"
    "Code changes requested|CHANGES_REQUESTED 리뷰 시 PR Status 를 In progress 로 자동 이동 → #538 (Blocked PR 은 In review 유지) 위반"
  )

  local nodes
  nodes=$(_claude-gh-retry gh api graphql -f query='
    query($owner: String!, $number: Int!) {
      organization(login: $owner) {
        projectV2(number: $number) {
          workflows(first: 30) { nodes { name enabled } }
        }
      }
    }' \
    -f owner="$CLAUDE_PROJECT_OWNER" \
    -F number="$CLAUDE_PROJECT_NUMBER" \
    | jq -c '.data.organization?.projectV2?.workflows?.nodes // []' 2>/dev/null)

  local entry name reason enabled
  for entry in "${conflicting[@]}"; do
    name="${entry%%|*}"
    reason="${entry#*|}"
    enabled=$(printf '%s' "$nodes" | jq -r --arg n "$name" '.[]? | select(.name==$n) | .enabled' 2>/dev/null)
    if [[ "$enabled" == "true" ]]; then
      echo "⚠️  Project 내장 워크플로우 '$name' 가 활성 상태입니다 (#12, #252, #1000)." >&2
      echo "    $reason." >&2
      echo "    https://github.com/orgs/${CLAUDE_PROJECT_OWNER}/projects/${CLAUDE_PROJECT_NUMBER}/workflows 에서 비활성화하세요." >&2
    fi
  done
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — Project 보드 Status 사후 검증 (#60)
# 사용법: claude-verify-content-status <content-node-id> <expected> <label>
#
# claude-set-content-status 직후의 mutation 응답은 "API가 요청을 수용했음"만
# 의미한다. 실제 보드의 현재 값은 별도 read 쿼리로만 확인 가능하다 — 특히
# Project 자동화(예: "Pull request linked to issue")가 mutation 직후 값을
# 되돌리는 경합 케이스에서 set의 ✅만 신뢰하면 보드와 어긋난다.
#
# 동작:
#   1) 콘텐츠의 projectItems에서 우리 Project 카드를 찾아 Status 필드 읽기.
#   2) expected와 일치하면 ✅ 출력 + return 0.
#   3) 불일치면 1초 대기 후 1회 재조회(eventual consistency 흡수).
#   4) 재시도 후에도 불일치면 ❌ + 현재 값을 stderr에 보고하고 return 1.
#
# 보드에서 카드를 못 찾는 경우(content가 Project에 추가되지 않음)도 실패로 본다.
# 호출 패턴:
#   claude-set-issue-status 60 "In review" && claude-verify-issue-status 60 "In review"
# ────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # GraphQL 변수 리터럴 — 셸 확장 의도적 차단
claude-verify-content-status() {
  local content_node_id="$1"
  local expected="$2"
  local label="$3"

  _claude-require-project-config || return 1

  if [[ -z "$content_node_id" || "$content_node_id" == "null" ]]; then
    echo "❌ content_node_id가 비어 있습니다 (${label})." >&2
    return 1
  fi

  local attempt=1
  local max_attempts=2
  local current=""

  while (( attempt <= max_attempts )); do
    local result
    result=$(_claude-gh-retry gh api graphql -f query='
      query($content: ID!, $owner: String!, $number: Int!) {
        organization(login: $owner) {
          projectV2(number: $number) { id }
        }
        node(id: $content) {
          ... on Issue {
            projectItems(first: 20) {
              nodes {
                project { id }
                status: fieldValueByName(name: "Status") {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
              }
            }
          }
          ... on PullRequest {
            projectItems(first: 20) {
              nodes {
                project { id }
                status: fieldValueByName(name: "Status") {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
              }
            }
          }
        }
      }' \
      -F content="$content_node_id" \
      -F owner="$CLAUDE_PROJECT_OWNER" \
      -F number="$CLAUDE_PROJECT_NUMBER") || {
        echo "❌ 검증 쿼리 실패 (네트워크 또는 권한)." >&2
        return 1
      }

    local project_id
    project_id=$(printf '%s' "$result" | jq -r '.data.organization?.projectV2?.id // empty')
    if [[ -z "$project_id" ]]; then
      echo "❌ Project 메타 조회 실패 — 검증 불가 (${label})." >&2
      return 1
    fi

    # head -n 1: 같은 Project에 콘텐츠가 두 번 들어가는 경우는 없지만, 방어적으로 첫 매치만 사용.
    current=$(printf '%s' "$result" | jq -r --arg pid "$project_id" '
      .data.node?.projectItems?.nodes[]?
      | select(.project?.id == $pid)
      | .status?.name? // empty
    ' | head -n 1)

    if [[ "$current" == "$expected" ]]; then
      echo "✅ ${label} status 검증 통과 (${expected})"
      return 0
    fi

    if (( attempt < max_attempts )); then
      sleep 1
    fi
    attempt=$((attempt + 1))
  done

  if [[ -z "$current" ]]; then
    echo "❌ ${label} 보드 카드/Status를 찾을 수 없습니다 (기대=${expected})." >&2
  else
    echo "❌ ${label} status 불일치 — 기대=${expected}, 현재=${current}" >&2
  fi
  return 1
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-verify-issue-status <issue-number> <expected-status>
# <expected-status>: "Backlog" | "Ready" | "In progress" | "In review" | "Approved" | "Done"
# Issue의 현재 Project Status를 expected와 비교 (#60).
# ────────────────────────────────────────────────────────────────────
claude-verify-issue-status() {
  local issue_number="$1"
  local expected="$2"
  local node_id
  node_id=$(_claude-content-node-id issues "$issue_number") || return 1
  claude-verify-content-status "$node_id" "$expected" "#${issue_number}"
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-verify-pr-status <pr-number> <expected-status>
# <expected-status>: "Backlog" | "Ready" | "In progress" | "In review" | "Approved" | "Done"
# PR 카드의 현재 Project Status를 expected와 비교 (#60).
# ────────────────────────────────────────────────────────────────────
claude-verify-pr-status() {
  local pr_number="$1"
  local expected="$2"
  local node_id
  node_id=$(_claude-content-node-id pulls "$pr_number") || return 1
  claude-verify-content-status "$node_id" "$expected" "PR #${pr_number}"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 현재 보드 Status 조회 (#671)
# 사용법: _claude-current-board-status <number> <issues|pulls>
# 출력: 현재 Status 이름 한 줄 ("In progress" 등). 카드 미등록/Status 미설정이면 빈 줄.
# return 0: 정상 조회 (Status 값은 비어 있어도 OK — 보드 미등록 신규 이슈 케이스).
# return 1: node_id / GraphQL / project 메타 조회 실패. 호출자가 fail-closed 결정.
#
# forward-only 보드 가드(#671) 의 기반 헬퍼. claude-verify-content-status 와 동일한
# GraphQL 패턴을 재사용하되, 단일 호출에서 값을 한 줄로 반환해 case 매칭에 쓰기 좋게 한다.
# ────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # GraphQL 변수 리터럴 — 셸 확장 의도적 차단
_claude-current-board-status() {
  local number="$1"
  local type="$2"  # issues|pulls
  _claude-require-project-config || return 1
  case "$type" in
    issues|pulls) ;;
    *)
      echo "❌ _claude-current-board-status: type은 'issues' 또는 'pulls' (got='${type}')." >&2
      return 1
      ;;
  esac

  local node_id
  node_id=$(_claude-content-node-id "$type" "$number") || return 1

  local result
  result=$(_claude-gh-retry gh api graphql -f query='
    query($content: ID!, $owner: String!, $number: Int!) {
      organization(login: $owner) { projectV2(number: $number) { id } }
      node(id: $content) {
        ... on Issue {
          projectItems(first: 20) {
            nodes {
              project { id }
              status: fieldValueByName(name: "Status") {
                ... on ProjectV2ItemFieldSingleSelectValue { name }
              }
            }
          }
        }
        ... on PullRequest {
          projectItems(first: 20) {
            nodes {
              project { id }
              status: fieldValueByName(name: "Status") {
                ... on ProjectV2ItemFieldSingleSelectValue { name }
              }
            }
          }
        }
      }
    }' \
    -F content="$node_id" \
    -F owner="$CLAUDE_PROJECT_OWNER" \
    -F number="$CLAUDE_PROJECT_NUMBER") || return 1

  local project_id
  project_id=$(printf '%s' "$result" | jq -r '.data.organization?.projectV2?.id // empty')
  if [[ -z "$project_id" ]]; then
    return 1
  fi

  # head -n 1: 동일 Project 에 콘텐츠가 두 번 들어가는 경우는 없지만 방어적 첫 매치.
  printf '%s' "$result" | jq -r --arg pid "$project_id" '
    .data.node?.projectItems?.nodes[]?
    | select(.project?.id == $pid)
    | .status?.name? // empty
  ' | head -n 1
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-board-status [--all | <status>...]
#   (인자 없음)          Done 제외 — 활성 아이템만
#   --all                전체 (Done 포함)
#   <status> [<status>…] 지정한 상태만 (예: "In review" "Approved")
# 출력: "status | type | #number | title" (status 기준 정렬)
#
# gh project item-list --limit N은 N개를 초과하면 누락이 발생한다 (#150).
# afterCursor 루프로 전체를 순회하므로 누락이 없다.
# ────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # GraphQL 변수 리터럴 — 셸 확장 의도적 차단
claude-board-status() {
  _claude-require-project-config || return 1
  # 인자 파싱: --all / 상태명 목록 / 없음
  local mode="default"   # default | all | filter
  local -a filter_statuses=()

  for arg in "$@"; do
    if [[ "$arg" == "--all" ]]; then
      mode="all"
    else
      mode="filter"
      filter_statuses+=("$arg")
    fi
  done

  local cursor="null"
  local has_next="true"
  local buf=""

  while [[ "$has_next" == "true" ]]; do
    local result
    result=$(_claude-gh-retry gh api graphql \
      -f query='
        query($owner: String!, $number: Int!, $cursor: String) {
          organization(login: $owner) {
            projectV2(number: $number) {
              items(first: 100, after: $cursor) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  status: fieldValueByName(name: "Status") {
                    ... on ProjectV2ItemFieldSingleSelectValue { name }
                  }
                  content {
                    ... on Issue { number title __typename }
                    ... on PullRequest { number title __typename }
                  }
                }
              }
            }
          }
        }' \
      -F owner="$CLAUDE_PROJECT_OWNER" \
      -F number="$CLAUDE_PROJECT_NUMBER" \
      -F cursor="$cursor") || {
        echo "❌ 보드 조회 실패" >&2
        return 1
      }

    local page_out
    page_out=$(printf '%s' "$result" | jq -r '
      .data.organization.projectV2.items.nodes[] |
      select(.content != null) |
      (.status.name? // "N/A") + " | " +
      (.content.__typename) + " | #" +
      (.content.number | tostring) + " | " +
      .content.title
    ')

    case "$mode" in
      default)
        page_out=$(printf '%s\n' "$page_out" | grep -v '^Done |') ;;
      filter)
        local grep_args=()
        for s in "${filter_statuses[@]}"; do
          grep_args+=(-e "^${s} |")
        done
        page_out=$(printf '%s\n' "$page_out" | grep "${grep_args[@]}") ;;
    esac

    [[ -n "$page_out" ]] && buf+="${page_out}"$'\n'

    has_next=$(printf '%s' "$result" | jq -r '.data.organization.projectV2.items.pageInfo.hasNextPage')
    cursor=$(printf '%s' "$result" | jq -r '.data.organization.projectV2.items.pageInfo.endCursor')
    [[ "$cursor" == "null" || -z "$cursor" ]] && break
  done

  printf '%s' "$buf" | grep -v '^$' | sort
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-find-similar-issues <keyword> [<keyword>…]
# 출력: JSON 배열 — 각 항목 {number, title, status, score, url}, score 내림차순
# 검색 범위: Project 보드의 Issue 카드 중 Status가 Backlog/Ready이고 state=OPEN인 것만.
#
# 매칭 규칙:
#   - title + body를 lowercase로 합쳐 hay-stack 구성
#   - 각 키워드도 lowercase로 변환 후 substring 포함 여부 검사
#   - 매칭된 키워드 개수 = score (>=1만 결과에 포함)
#
# 의도(#171):
#   /gh-issue 스킬이 새 이슈를 만들기 전에 "이미 백로그에 비슷한 게 있는가?"를
#   한 번 검사할 수 있게 한다. 검색 정책이 스킬과 사용자 사이에 분기되지 않도록
#   여기 한 곳에만 둔다.
#
# 검색 범위가 Backlog/Ready로 한정된 이유:
#   In progress 이상은 이미 누가 손대고 있는 작업 → 합치면 단일 이슈 원칙 위반.
#   PR(__typename=PullRequest)은 분리해야 같은 키워드의 PR 카드가 잡음으로 섞이지 않는다.
# ────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # GraphQL 변수 리터럴 — 셸 확장 의도적 차단
claude-find-similar-issues() {
  if [[ $# -eq 0 ]]; then
    echo "❌ 사용법: claude-find-similar-issues <keyword> [<keyword>…]" >&2
    return 1
  fi

  _claude-require-project-config || return 1

  # 인자 → JSON 배열. jq --args로 위치 인자를 그대로 받아 인자 내부 개행/특수문자에
  # 영향받지 않게 한다. 동시에 ascii_downcase / 빈 문자열 필터 / unique를 미리 적용해
  # 매칭 루프 내부 중복 연산과 동일 키워드 score 인플레이션을 방지한다 (PR #172 리뷰).
  local keywords_json
  keywords_json=$(jq -n '$ARGS.positional | map(ascii_downcase | select(length > 0)) | unique' --args "$@") || return 1

  local cursor="null"
  local has_next="true"
  local all_items="[]"

  while [[ "$has_next" == "true" ]]; do
    local result
    result=$(_claude-gh-retry gh api graphql \
      -f query='
        query($owner: String!, $number: Int!, $cursor: String) {
          organization(login: $owner) {
            projectV2(number: $number) {
              items(first: 100, after: $cursor) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  status: fieldValueByName(name: "Status") {
                    ... on ProjectV2ItemFieldSingleSelectValue { name }
                  }
                  content {
                    ... on Issue {
                      number title body url state __typename
                    }
                  }
                }
              }
            }
          }
        }' \
      -F owner="$CLAUDE_PROJECT_OWNER" \
      -F number="$CLAUDE_PROJECT_NUMBER" \
      -F cursor="$cursor") || {
        echo "❌ 보드 조회 실패" >&2
        return 1
      }

    # 페이지별 결과를 jq로 필터·스코어링.
    # __typename 가드: Issue가 아닌 노드(PR / DraftIssue)는 .content.__typename이
    # 누락되거나 다른 값이라 select에서 떨어진다.
    local page_items
    page_items=$(printf '%s' "$result" | jq --argjson keywords "$keywords_json" '
      [.data.organization.projectV2.items.nodes[]
       | select(.content != null)
       | select(.content.__typename == "Issue")
       | select(.status.name? == "Backlog" or .status.name? == "Ready")
       | select(.content.state == "OPEN")
       | . as $item
       | (($item.content.title // "") + " " + ($item.content.body // "") | ascii_downcase) as $hay
       | ($keywords | map(select(. as $k | $hay | contains($k))) | length) as $score
       | select($score > 0)
       | {number: $item.content.number,
          title: $item.content.title,
          status: $item.status.name,
          score: $score,
          url: $item.content.url}]
    ') || return 1

    all_items=$(jq -n --argjson a "$all_items" --argjson b "$page_items" '$a + $b') || return 1

    has_next=$(printf '%s' "$result" | jq -r '.data.organization.projectV2.items.pageInfo.hasNextPage')
    cursor=$(printf '%s' "$result" | jq -r '.data.organization.projectV2.items.pageInfo.endCursor')
    [[ "$cursor" == "null" || -z "$cursor" ]] && break
  done

  # score 내림차순 → 동점이면 number 내림차순(최신 이슈 우선).
  printf '%s' "$all_items" | jq 'sort_by(-.score, -.number)'
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-register-related-issue "<title>" [keyword…]
# 기능: 현재 세션 이슈의 마일스톤을 자동 감지해 관련 이슈를 생성하고 Ready로 승격.
# 흐름:
#   1. claude-session-bound → 현재 이슈 번호 확인
#   2. gh issue view → 마일스톤 감지
#   3. claude-find-similar-issues → Backlog/Ready 중복 검사 (github-integration.md §Backlog 중복 검사 의무)
#   4. gh issue create --milestone → 이슈 생성 (중복 score≥2 이면 코멘트만 추가)
#   5. claude-set-issue-status "Ready" → 마일스톤 달성 이슈로 함께 관리
# 이슈 스코프 격리 (#133): 생성된 이슈의 구현은 현재 브랜치에 커밋하지 않는다.
# ────────────────────────────────────────────────────────────────────
claude-register-related-issue() {
  if [[ $# -lt 1 ]]; then
    echo "❌ 사용법: claude-register-related-issue \"<title>\" [keyword…]" >&2
    echo "   title   이슈 제목 (필수)" >&2
    echo "   keyword 중복 검사용 키워드 (생략 시 title 단어 사용)" >&2
    return 1
  fi

  local title="$1"; shift
  local keywords=("$@")
  if [[ ${#keywords[@]} -eq 0 ]]; then
    # title을 공백 분리해 키워드로 사용 (단어 5개 이하로 제한)
    read -ra keywords <<< "$title"
    keywords=("${keywords[@]:0:5}")
  fi

  # 1. 현재 세션 이슈 확인
  local bound_issue
  if ! bound_issue=$(claude-session-bound); then
    echo "❌ 이슈 worktree 세션이 아닙니다. claude-enter-issue <N>으로 진입 후 사용하세요." >&2
    return 1
  fi

  # 2. 현재 이슈의 마일스톤 감지
  local issue_json milestone_title
  issue_json=$(gh issue view "$bound_issue" --json milestone) || {
    echo "❌ 이슈 #${bound_issue} 조회 실패" >&2
    return 1
  }
  milestone_title=$(printf '%s' "$issue_json" | jq -r '.milestone.title // empty')

  if [[ -z "$milestone_title" ]]; then
    echo "⚠️  이슈 #${bound_issue}에 마일스톤이 없습니다. 마일스톤 없이 이슈를 생성하고 Ready로 승격합니다." >&2
  fi

  # 3. Backlog/Ready 중복 검사
  local similar top_score top_number top_title
  similar=$(claude-find-similar-issues "${keywords[@]}" 2>/dev/null) || similar="[]"
  top_score=$(printf '%s' "$similar" | jq -r 'if length > 0 then .[0].score else 0 end')
  top_number=$(printf '%s' "$similar" | jq -r 'if length > 0 then .[0].number else "" end')
  top_title=$(printf '%s' "$similar" | jq -r 'if length > 0 then .[0].title else "" end')

  if [[ "$top_score" -ge 2 ]] && [[ -n "$top_number" ]]; then
    echo "⚠️  강한 유사 이슈 (score=${top_score}): #${top_number} — ${top_title}" >&2
    echo "   → 새 이슈 대신 기존 이슈에 컨텍스트를 추가합니다." >&2
    _claude-gh-retry gh issue comment "$top_number" \
      --body "_#${bound_issue} 세션 중 발견. 제목 후보: \"${title}\"_" || {
        echo "❌ #${top_number} 코멘트 추가 실패 (네트워크 또는 권한 문제)." >&2
        echo "   수동으로 보정하세요: gh issue comment ${top_number} --body \"_#${bound_issue} 세션 중 발견. 제목 후보: \\\"${title}\\\"_\"" >&2
        return 1
      }
    echo "✅ #${top_number}에 컨텍스트 추가 완료. 기존 이슈 상태(마일스톤·Ready)는 유지됩니다." >&2
    return 0
  fi

  # 4. 이슈 생성
  local create_args=(--title "$title")
  [[ -n "$milestone_title" ]] && create_args+=(--milestone "$milestone_title")

  local body="_#${bound_issue} 세션 중 발견._"
  if [[ "$top_score" -eq 1 ]] && [[ -n "$top_number" ]]; then
    echo "ℹ️  애매한 유사 이슈 (score=1): #${top_number} — ${top_title} → Related 링크 추가" >&2
    body="Related: #${top_number}

${body}"
  fi
  create_args+=(--body "$body")

  local new_url
  new_url=$(gh issue create "${create_args[@]}") || {
    echo "❌ 이슈 생성 실패" >&2
    return 1
  }

  local new_number
  new_number=$(printf '%s' "$new_url" | sed -E 's|.*/issues/([0-9]+).*|\1|')
  if [[ ! "$new_number" =~ ^[0-9]+$ ]]; then
    echo "⚠️  이슈 번호 파싱 실패 (url=${new_url})." >&2
    echo "   이슈는 생성되었으나 Status 전환이 누락되었습니다. 수동으로 보정하세요:" >&2
    echo "     claude-set-issue-status <이슈-번호> \"Ready\"" >&2
    return 1
  fi
  echo "✅ 이슈 #${new_number} 생성: ${new_url}"
  [[ -n "$milestone_title" ]] && echo "   마일스톤: ${milestone_title}"

  # 5. 사후 처리 (마일스톤·Ready·체크리스트) — _claude-post-issue-create 단일 진입점 (#527)
  _claude-post-issue-create "$new_number"

  echo ""
  echo "⚠️  이슈 스코프 격리 (#133): #${new_number} 구현은 현재 브랜치(#${bound_issue})에 커밋하지 마세요."
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 현재 활성 마일스톤 감지 (#527, #544)
# 사용법: _claude-current-milestone
# 출력: 마일스톤 title (없으면 빈 문자열). 항상 return 0.
#
# 우선순위:
#   1) 이슈 worktree 세션이면 bound 이슈의 마일스톤 (claude-register-related-issue 와 동일 정책)
#   2) 그 외엔 OPEN 마일스톤 중 number 가 가장 작은 것 (가장 먼저 생성된 = 현재 진행)
#   3) 둘 다 비어 있으면 빈 문자열 — 마일스톤 적용을 건너뛰는 신호
#
# Priority 2 정책 (#544): 워크플로우상 마일스톤은 완료 시점에
# `claude-check-milestone --close` 로 닫힌다. 따라서 OPEN 으로 남은 것 중
# number 가 가장 작은 것이 "현재 진행 중인 마일스톤" 이다. 가장 큰 것을
# 고르면 미래에 미리 등록한 계획용 마일스톤(M5, Phase 2 등) 이 잡혀
# 신규 이슈 분류·체크리스트 append 가 잘못된 마일스톤으로 향한다.
# ────────────────────────────────────────────────────────────────────
_claude-current-milestone() {
  local bound mt
  if bound=$(claude-session-bound 2>/dev/null); then
    mt=$(_claude-gh-retry gh issue view "$bound" --json milestone --jq '.milestone.title // empty' 2>/dev/null) || mt=""
    if [[ -n "$mt" ]]; then
      printf '%s' "$mt"
      return 0
    fi
  fi

  local repo
  repo=$(_claude-gh-retry gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || return 0
  [[ -z "$repo" ]] && return 0

  _claude-gh-retry gh api "repos/${repo}/milestones?state=open&per_page=100" 2>/dev/null \
    | jq -r 'sort_by(.number) | .[0].title // empty' 2>/dev/null
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 마일스톤 체크리스트 이슈에 새 이슈 라인 append (#527)
# 사용법: _claude-append-checklist-item <milestone-title> <issue-number> <issue-title>
#
# 동작:
#   1) 마일스톤 number resolve
#   2) 체크리스트 이슈 [Milestone] <m> 완료 체크리스트 검색
#   3) 체크리스트 이슈가 없으면 안내 후 return 0 (강제 생성 ❌)
#   4) 본문에 '- [ ] #<N> ' 또는 '- [x] #<N> ' 가 이미 있으면 멱등 skip
#   5) 본문 끝에 '- [ ] #<N> <title>' 한 줄 append
#
# 동시 수정 충돌:
#   gh issue edit --body 는 본문 전체 교체. 두 호출이 같은 시점에 fetch 후 PUT 하면
#   두 번째가 첫 번째를 덮어쓸 수 있다 (#527 Open Question). 멱등 가드가 같은 번호의
#   중복 라인은 막지만, 서로 다른 번호의 동시 추가는 한 쪽이 누락될 수 있다.
#   현실적으로 이슈 생성은 직렬화되므로 수용 가능 — 누락 발견 시 수동 재실행으로 보정.
# ────────────────────────────────────────────────────────────────────
_claude-append-checklist-item() {
  local milestone_title="$1"
  local issue_number="$2"
  local issue_title="$3"

  if [[ -z "$milestone_title" || -z "$issue_number" || -z "$issue_title" ]]; then
    return 0
  fi

  local milestone_number
  milestone_number=$(_claude-milestone-number "$milestone_title" 2>/dev/null) || return 0

  local checklist_title="[Milestone] ${milestone_title} 완료 체크리스트"
  local search_json
  search_json=$(_claude-gh-retry gh issue list \
    --milestone "$milestone_number" \
    --state open \
    --search "in:title 완료 체크리스트" \
    --json number,title,body \
    --limit 50 2>/dev/null) || return 0

  local checklist_number checklist_body
  checklist_number=$(printf '%s' "$search_json" \
    | jq -r --arg t "$checklist_title" '.[] | select(.title == $t) | .number' \
    | head -n 1)

  if [[ -z "$checklist_number" ]]; then
    echo "ℹ️  마일스톤 '${milestone_title}' 의 체크리스트 이슈가 없어 #${issue_number} 자동 등록 건너뜀." >&2
    return 0
  fi

  checklist_body=$(printf '%s' "$search_json" \
    | jq -r --argjson n "$checklist_number" '.[] | select(.number == $n) | .body')

  # 멱등 가드: 같은 번호가 이미 체크리스트 라인으로 등록돼 있으면 skip.
  if printf '%s\n' "$checklist_body" | grep -qE "^- \[[ x]\] #${issue_number}([[:space:]]|$)"; then
    return 0
  fi

  # body-file 경유로 newline/quote 안전 PUT.
  local body_tmp
  body_tmp=$(mktemp) || return 0
  {
    printf '%s\n' "$checklist_body"
    printf '%s\n' "- [ ] #${issue_number} ${issue_title}"
  } >"$body_tmp"

  if _claude-gh-retry gh issue edit "$checklist_number" --body-file "$body_tmp" >/dev/null 2>&1; then
    echo "✅ #${checklist_number} 체크리스트에 #${issue_number} 등록"
  else
    echo "⚠️  체크리스트 #${checklist_number} 본문 업데이트 실패 — 수동 보정 필요." >&2
  fi
  rm -f "$body_tmp"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 신규 이슈 사후 처리 단일 진입점 (#527, #544)
# 사용법: _claude-post-issue-create <issue-number>
#
# 동작 (모두 idempotent — 중복 호출 안전):
#   1) 이슈 현재 마일스톤 조회
#   2) 마일스톤 미설정이면 _claude-current-milestone 으로 자동 적용 시도
#   3) Project 보드 Status 라우팅 (#544):
#        - 명시된 마일스톤 number > 현재 활성 마일스톤 number → Backlog
#        - 그 외(미지정·자동 적용·과거·현재 마일스톤) → Ready
#      (docs/github-integration.md "Kanban 상태 규칙" 준수)
#   4) 마일스톤이 결정됐으면 체크리스트 이슈에 라인 append
#
# 호출자:
#   - claude-create-issue (new wrapper)
#   - claude-register-related-issue
#   - (선택) raw `gh issue create` 안전망 PostToolUse 훅을 둔다면 그 훅에서도 호출 가능
# ────────────────────────────────────────────────────────────────────
_claude-post-issue-create() {
  local issue_number="$1"
  if [[ -z "$issue_number" || ! "$issue_number" =~ ^[0-9]+$ ]]; then
    echo "❌ _claude-post-issue-create: 이슈 번호가 잘못됐습니다 ('${issue_number}')." >&2
    return 1
  fi

  local issue_json
  issue_json=$(_claude-gh-retry gh issue view "$issue_number" --json title,milestone,state 2>/dev/null) || {
    echo "⚠️  #${issue_number} 조회 실패 — Ready 승격/체크리스트 반영 건너뜀." >&2
    return 0
  }

  local issue_title milestone_title milestone_was_explicit=0 issue_state
  issue_title=$(printf '%s' "$issue_json" | jq -r '.title // empty')
  milestone_title=$(printf '%s' "$issue_json" | jq -r '.milestone.title // empty')
  issue_state=$(printf '%s' "$issue_json" | jq -r '.state // empty')

  # CLOSED 가드 (#645): 본 함수는 Ready/Backlog (forward-only) 만 라우팅하므로
  # 닫힌 이슈에 대해서는 무조건 조기 종료한다. 그렇지 않으면 잘못된 인자(예: 닫힌
  # 이슈 번호) 호출이 보드 카드를 Done → Ready/Backlog 로 회귀시킨다 (#607·#608·#609).
  if [[ "$issue_state" == "CLOSED" ]]; then
    echo "⚠️  #${issue_number} 는 이미 CLOSED — Ready/Backlog 라우팅 차단 (#645 회귀 가드)." >&2
    return 0
  fi

  # Forward-only 보드 가드 (#671): OPEN 이슈가 이미 보드의 forward 단계
  # (In progress / In review / Approved / Done) 에 진입했으면 milestone 재적용 /
  # Ready·Backlog 라우팅 모두 early-return. #627 회귀 trigger — #645 의 CLOSED 가드
  # 옆에 동치 확장으로 배치한다. 본 함수는 best-effort 사후 처리 경로이므로
  # 보드 조회 실패도 soft (return 0) 로 abort — 다만 stderr 에는 fail-closed 사유를 남긴다.
  # 보드에 카드가 아직 등록되지 않은 신규 이슈는 current_board_status="" 가 되어
  # case 매칭이 떨어지고 그대로 Ready/Backlog 라우팅이 진행된다.
  local current_board_status
  if ! current_board_status=$(_claude-current-board-status "$issue_number" issues); then
    echo "⚠️  #${issue_number}: 보드 status 조회 실패 — Ready/Backlog 라우팅 차단 (#671 forward-only 가드, fail-closed)." >&2
    return 0
  fi
  case "$current_board_status" in
    "In progress"|"In review"|"Approved"|"Done")
      echo "⚠️  #${issue_number} 는 이미 '${current_board_status}' — Ready/Backlog 라우팅 차단 (#671 forward-only 가드)." >&2
      return 0
      ;;
  esac

  if [[ -n "$milestone_title" ]]; then
    milestone_was_explicit=1
  else
    milestone_title=$(_claude-current-milestone)
    if [[ -n "$milestone_title" ]]; then
      if _claude-gh-retry gh issue edit "$issue_number" --milestone "$milestone_title" >/dev/null 2>&1; then
        echo "✅ #${issue_number} 마일스톤 '${milestone_title}' 자동 적용"
      else
        echo "⚠️  #${issue_number} 마일스톤 '${milestone_title}' 적용 실패 — 수동 보정 필요." >&2
        milestone_title=""
      fi
    fi
  fi

  # Status 라우팅 (#544): 명시된 미래 마일스톤이면 Backlog, 그 외엔 Ready.
  # 자동 적용 경로(milestone_was_explicit=0)는 정의상 현재 마일스톤이므로 비교 생략.
  local target_status="Ready"
  if [[ "$milestone_was_explicit" -eq 1 ]]; then
    local current_milestone_title
    current_milestone_title=$(_claude-current-milestone)
    if [[ -n "$current_milestone_title" && "$milestone_title" != "$current_milestone_title" ]]; then
      # 마일스톤 목록은 한 번만 조회해 두 번호를 함께 추출 (PR #551 리뷰).
      local repo milestones_json issue_ms_number current_ms_number
      repo=$(_claude-gh-retry gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
      if [[ -n "$repo" ]]; then
        milestones_json=$(_claude-gh-retry gh api "repos/${repo}/milestones?state=all&per_page=100" 2>/dev/null)
        if [[ -n "$milestones_json" ]]; then
          issue_ms_number=$(printf '%s' "$milestones_json" \
            | jq -r --arg t "$milestone_title" '.[] | select(.title == $t) | .number' \
            | head -n 1)
          current_ms_number=$(printf '%s' "$milestones_json" \
            | jq -r --arg t "$current_milestone_title" '.[] | select(.title == $t) | .number' \
            | head -n 1)
          if [[ "$issue_ms_number" =~ ^[0-9]+$ ]] \
            && [[ "$current_ms_number" =~ ^[0-9]+$ ]] \
            && [[ "$issue_ms_number" -gt "$current_ms_number" ]]; then
            target_status="Backlog"
          fi
        fi
      fi
    fi
  fi

  if claude-set-issue-status "$issue_number" "$target_status" >/dev/null 2>&1; then
    echo "✅ #${issue_number} → ${target_status} 라우팅"
  else
    echo "⚠️  #${issue_number} ${target_status} 라우팅 실패 — 수동으로 claude-set-issue-status ${issue_number} \"${target_status}\" 필요." >&2
  fi

  if [[ -n "$milestone_title" && -n "$issue_title" ]]; then
    _claude-append-checklist-item "$milestone_title" "$issue_number" "$issue_title"
  fi
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-create-issue [gh issue create 옵션...]
# 동작 (#527):
#   1) 호출자가 --milestone 을 명시하지 않았으면 _claude-current-milestone 자동 주입
#   2) gh issue create 위임
#   3) 생성된 이슈 번호 → _claude-post-issue-create 로 Ready·체크리스트 반영
#
# 사용 예:
#   claude-create-issue --title "Foo" --body "Bar"
#   claude-create-issue --title "Foo" --body-file body.md --milestone "M0c"
#
# 비교:
#   - claude-register-related-issue: 이슈 worktree 세션 전용 (Backlog 중복 검사 + Related 본문)
#   - claude-create-issue: 모든 컨텍스트 (main worktree, /gh-issue 스킬 포함). 중복 검사 없음.
# ────────────────────────────────────────────────────────────────────
claude-create-issue() {
  if [[ $# -eq 0 ]]; then
    echo "❌ 사용법: claude-create-issue [gh issue create 옵션...]" >&2
    echo "   예: claude-create-issue --title \"<제목>\" --body \"<본문>\"" >&2
    return 1
  fi

  local has_milestone=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --milestone|--milestone=*|-M) has_milestone=1; break ;;
    esac
  done

  local -a args=("$@")
  if [[ $has_milestone -eq 0 ]]; then
    local mt
    mt=$(_claude-current-milestone)
    if [[ -n "$mt" ]]; then
      args+=(--milestone "$mt")
    fi
  fi

  local new_url
  new_url=$(gh issue create "${args[@]}") || {
    echo "❌ 이슈 생성 실패." >&2
    return 1
  }

  local new_number
  new_number=$(printf '%s' "$new_url" | sed -E 's|.*/issues/([0-9]+).*|\1|')
  if [[ ! "$new_number" =~ ^[0-9]+$ ]]; then
    echo "⚠️  이슈 번호 파싱 실패 (url=${new_url}). 사후 처리 건너뜀." >&2
    printf '%s\n' "$new_url"
    return 0
  fi

  printf '%s\n' "$new_url"
  _claude-post-issue-create "$new_number"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — PR 본문 REST PATCH 우회 (#35)
# 사용법: claude-pr-set-body <pr_num>  (본문은 stdin으로 전달)
#
# gh pr edit --body 는 GraphQL updatePullRequest mutation 응답에서
# repository.pullRequest.projectCards 필드를 조회하는데, GitHub이
# Projects classic deprecation 에러를 강제 적용하면서 mutation 전체가
# 거부된다. REST PATCH 경로는 이 필드를 사용하지 않아 정상 동작한다.
#
# 사용 예:
#   echo "Closes #42" | claude-pr-set-body 99
#   claude-pr-set-body 99 < body.md
# ────────────────────────────────────────────────────────────────────
claude-pr-set-body() {
  local pr_num="$1"
  if [[ -z "$pr_num" ]]; then
    echo "사용법: claude-pr-set-body <pr_num>" >&2
    return 1
  fi

  local repo
  repo=$(_claude-gh-retry gh repo view --json nameWithOwner -q .nameWithOwner) || {
    echo "❌ repo 조회 실패." >&2
    return 1
  }

  # stdin을 임시 파일로 먼저 받아 JSON 인코딩 후 전달.
  # 파이프로 직접 넘기면 _claude-gh-retry 내부 재시도 시 stdin이 이미 소비되어
  # 두 번째 시도부터 본문이 빈 채로 PATCH된다.
  local tmp_json
  tmp_json=$(mktemp) || return 1
  jq -Rs '{body: .}' > "$tmp_json"
  _claude-gh-retry gh api --method PATCH "repos/${repo}/pulls/${pr_num}" \
    --input "$tmp_json" > /dev/null
  local rc=$?
  rm -f "$tmp_json"
  [[ $rc -eq 0 ]] && echo "✅ PR #${pr_num} 본문 업데이트 완료"
  return "$rc"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 이슈 severity 라벨 조회 (#173)
# 사용법: claude-issue-severity <issue_num> [<issue_num>...]
# 출력: 닫는 이슈들의 severity 라벨 중 가장 높은 한 개. 없으면 빈 출력.
# 우선순위: 🔥 Critical > ⚡ High > 🔼 Medium.
#
# docs/github-integration.md §"이슈→PR severity 전파 의무" 정책의
# 단일 severity 조회 지점. claude-apply-pr-labels(#1486)가 이 헬퍼를 호출해 PR 이
# 닫는 이슈와 동일 severity 를 PR 라벨에 부착한다 (구 PostToolUse 훅의 후신).
#
# 다중 이슈를 닫는 PR이라도 "한 카드에 severity 최대 1개" 정책을 유지하기
# 위해 모든 입력 이슈를 훑고 가장 높은 severity 한 개만 반환한다.
#
# 실패 처리 (soft fail):
#   - 인자 0개 → 사용법 안내 + return 1.
#   - 비숫자 인자 → stderr 경고 후 해당 인자 무시, 나머지 진행.
#   - 특정 이슈의 gh 호출 실패 → stderr 경고 1줄, 해당 이슈는 무시.
#     PR 생성을 막지 않는다 — 라벨은 기존 라벨 루프 정책처럼 누락 허용.
#   - 모든 이슈에서 severity 없음 → 빈 출력 + return 0.
# ────────────────────────────────────────────────────────────────────
claude-issue-severity() {
  if (( $# == 0 )); then
    echo "사용법: claude-issue-severity <issue_num> [<issue_num>...]" >&2
    return 1
  fi

  # rank 1=Critical, 2=High, 3=Medium. 999는 sentinel(아직 매칭 없음).
  local highest_rank=999
  local highest_label=""
  local issue rank label labels_out

  for issue in "$@"; do
    if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
      echo "⚠️  '${issue}'는 이슈 번호가 아닙니다(숫자만 허용). 건너뜁니다." >&2
      continue
    fi

    if ! labels_out=$(_claude-gh-retry gh issue view "$issue" --json labels --jq '.labels[].name'); then
      echo "⚠️  이슈 #${issue} 라벨 조회 실패. severity 전파에서 제외합니다." >&2
      continue
    fi

    # 라벨이 0개인 이슈 가드 — Bash here-string(`<<<`)은 빈 변수에도 트레일링
    # 뉴라인을 붙여 `read`가 빈 문자열 1행을 읽는다. 본 케이스에선 빈 label이
    # case의 *) 분기에서 continue로 흡수돼 결과는 정확하지만, 불필요한 1회
    # 반복을 피하고자 입력 자체를 조기 차단한다 (gemini PR #174 리뷰).
    [[ -z "$labels_out" ]] && continue

    while IFS= read -r label; do
      case "$label" in
        '🔥 Critical') rank=1 ;;
        '⚡ High')     rank=2 ;;
        '🔼 Medium')   rank=3 ;;
        *)              continue ;;
      esac
      if (( rank < highest_rank )); then
        highest_rank=$rank
        highest_label=$label
      fi
    done <<<"$labels_out"
  done

  [[ -n "$highest_label" ]] && printf '%s\n' "$highest_label"
  return 0
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — stacked PR `Closes` 합산 누락 audit (#129, detection-only)
# 사용법: claude-audit-stacked-closes <parent-pr>
# 출력: 누락 1건당 한 줄 — `PR #<parent>: missing closes for issue #<n> from stacked PR #<child>`
#       누락 없으면 `✅ PR #<parent>: 모든 stacked closes가 합산되어 있음`
# 항상 return 0 — audit는 보조 도구라 실패 종료로 호출자 흐름을 끊지 않는다.
#
# Why (#129):
#   GitHub은 PR이 default branch가 아닌 base에 머지되면 `Closes #N` 자동 close 트리거를
#   발화하지 않는다. 따라서 stacked PR의 자식이 base에 머지되면, 그 자식이 닫는 이슈는
#   부모 PR이 main에 머지될 때 close되어야 한다 — 그러려면 부모 본문 `### Closes` 섹션에
#   `Closes #<n> (via stacked PR #<child>)` 줄이 합산돼 있어야 한다.
#   이 합산 누락이 한 건이라도 발생하면 자동 close가 깨지므로 부모 PR 머지 직전에 호출해
#   누락을 사전에 검출하는 detection-only 도구.
#
# 정책 (이슈 #129 결정 코멘트):
#   - 1단 stack만 지원. 자식 본문에 `(via stacked PR #X)` 패턴 검출 시 audit 경고 + 합산 보류.
#   - closing keyword variant 9종 case-insensitive 인식 (close[sd]? / fix(es|ed)? / resolve[sd]?).
#   - cross-repo closing(`owner/repo#N`)은 무시 — `(?<![\w/])` 가드로 차단.
#   - `closingIssuesReferences`(PR 측 인덱스)가 비어 있으면 자식 본문 정규식 fallback.
#     stacked 자식은 base != default라 PR 측 인덱스가 비어 있는 경우가 흔하다.
#
# 후속 이슈로 분리됨 (#129 분할 진행):
#   - 트랙 1: claude-close-issue 인자 확장으로 자식 PR 생성 자동화.
#   - 트랙 2 자동 patch: GitHub Actions workflow가 자식 머지 시점에 부모 본문 자동 patch.
# ────────────────────────────────────────────────────────────────────
claude-audit-stacked-closes() {
  if (( $# == 0 )); then
    echo "사용법: claude-audit-stacked-closes <parent-pr>" >&2
    return 1
  fi
  local parent_pr="$1"
  if ! [[ "$parent_pr" =~ ^[0-9]+$ ]]; then
    echo "❌ parent-pr은 숫자여야 합니다 (got='${parent_pr}')." >&2
    return 1
  fi

  # 1) parent PR head + body 조회.
  local parent_data parent_head parent_body
  parent_data=$(_claude-gh-retry gh pr view "$parent_pr" --json headRefName,body) || {
    echo "❌ parent PR #${parent_pr} 조회 실패." >&2
    return 1
  }
  parent_head=$(printf '%s' "$parent_data" | jq -r '.headRefName // empty')
  parent_body=$(printf '%s' "$parent_data" | jq -r '.body // ""')
  if [[ -z "$parent_head" ]]; then
    echo "❌ parent PR #${parent_pr} headRefName이 비어 있습니다." >&2
    return 1
  fi

  # 2) head를 base로 한 자식 PR 목록 (open + merged 모두).
  #    state=all로 조회한 뒤 본 audit는 OPEN/MERGED만 의미가 있으므로 CLOSED-not-merged는 jq에서 제외.
  local children
  children=$(_claude-gh-retry gh pr list --base "$parent_head" --state all --limit 100 \
    --json number,state,body,closingIssuesReferences) || {
    echo "❌ stacked 자식 PR 조회 실패 (base=${parent_head})." >&2
    return 1
  }

  local child_count
  child_count=$(printf '%s' "$children" | jq 'map(select(.state == "OPEN" or .state == "MERGED")) | length')
  if (( child_count == 0 )); then
    echo "✅ PR #${parent_pr}: stacked 자식 PR 없음 (head=${parent_head})"
    return 0
  fi

  # closing keyword 9종 정규식 + cross-repo 가드(앞에 \w 또는 / 가 오면 매치 안 함).
  # GNU grep -P (PCRE) 사용. \K로 매치 시작점을 #뒤 숫자로 리셋.
  local pcre='(?<![\w/])(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?)\s+#\K[0-9]+'

  local count_missing=0
  local i=0
  # 자식 PR을 OPEN/MERGED만 추린 배열로 재구성.
  local filtered
  filtered=$(printf '%s' "$children" | jq '[.[] | select(.state == "OPEN" or .state == "MERGED")]')

  while (( i < child_count )); do
    local child_num child_body closing_nums
    child_num=$(printf '%s' "$filtered" | jq -r ".[$i].number")
    child_body=$(printf '%s' "$filtered" | jq -r ".[$i].body // \"\"")

    # 다단 stack 검출 — 자식 본문에 이미 `(via stacked PR #X)` 줄이 있으면
    # 그것은 자식의 자식이 합산해둔 줄(다단)이다. 1단 한정 정책에 따라 경고만 출력.
    if printf '%s' "$child_body" | grep -qE '\(via stacked PR #[0-9]+\)'; then
      echo "⚠️  PR #${child_num}: 다단 stack 패턴 검출 — 합산 audit 보류 (1단 한정 정책)" >&2
      i=$((i+1)); continue
    fi

    # closing issue 추출 — closingIssuesReferences(PR 측 인덱스) 우선.
    closing_nums=$(printf '%s' "$filtered" | jq -r ".[$i].closingIssuesReferences[]?.number // empty" 2>/dev/null)
    # 비어 있으면 본문 정규식 fallback (stacked 자식의 흔한 케이스).
    if [[ -z "$closing_nums" ]]; then
      closing_nums=$(printf '%s' "$child_body" | grep -oiP "$pcre" 2>/dev/null)
    fi

    if [[ -z "$closing_nums" ]]; then
      # 자식이 closing issue를 갖지 않는 경우(refactor 등) — no-op.
      i=$((i+1)); continue
    fi

    while IFS= read -r issue_num; do
      [[ -z "$issue_num" ]] && continue
      # 멱등 검사: 합산 줄이 이미 부모 본문에 있으면 누락 아님.
      local expected="Closes #${issue_num} (via stacked PR #${child_num})"
      if printf '%s' "$parent_body" | grep -qF "$expected"; then
        continue
      fi
      printf 'PR #%s: missing closes for issue #%s from stacked PR #%s\n' \
        "$parent_pr" "$issue_num" "$child_num"
      count_missing=$((count_missing+1))
    done <<<"$closing_nums"

    i=$((i+1))
  done

  if (( count_missing == 0 )); then
    echo "✅ PR #${parent_pr}: 모든 stacked closes가 합산되어 있음"
  fi
  return 0
}

# ────────────────────────────────────────────────────────────────────
# 1단계 — 다음 이슈 선택
# 사용법: claude-next-issue [pro|max]
# 세션 선점 가드: 이미 바인딩된 세션이면 새 이슈를 반환하지 않는다.
# ────────────────────────────────────────────────────────────────────
claude-next-issue() {
  # 세션 선점 체크: 단일 세션 단일 이슈 원칙을 강제한다.
  local bound_issue
  if bound_issue=$(claude-session-bound); then
    echo "⚠️  이 세션은 이미 이슈 #${bound_issue}에 바인딩되어 있습니다 (브랜치: $(git rev-parse --abbrev-ref HEAD))."
    echo "    단일 세션 단일 이슈 원칙에 따라 새 이슈를 가져오지 않습니다."
    echo "    새 이슈가 필요하면 현재 세션을 종료(claude-close-issue)하고 새 세션을 여세요."
    gh issue view "$bound_issue" --json number,title,state,labels,milestone
    return 1
  fi

  local tier="${1:-pro}"
  local -a label_filter=()

  # pro: pro-friendly 라벨로 범위 제한. max: 전체.
  if [[ "$tier" == "pro" ]]; then
    label_filter=(--label "pro-friendly")
  fi

  # 마일스톤 제목 기준 정렬 → 가장 가까운 릴리즈 이슈가 자연스럽게 상위로 온다.
  # .milestone? : 마일스톤이 null인 이슈(Pre-Planning)에서 안전하게 통과.
  # // "zzzz"   : 마일스톤 없는 이슈의 정렬 키를 맨 뒤로 밀기 위한 sentinel 값.
  # .[0] // empty : 결과가 비었을 때 "null" 문자열 대신 아무것도 출력하지 않는다.
  gh issue list --assignee @me --state open \
    "${label_filter[@]}" \
    --json number,title,milestone,labels \
    --jq 'sort_by(.milestone?.title // "zzzz") | .[0] // empty'
}

# ────────────────────────────────────────────────────────────────────
# 2단계 — 의존성 확인
# 사용법: claude-check-deps <issue-number>
# 이슈 body의 "Depends on #N" 패턴을 수집해 의존 이슈가 모두 CLOSED인지 확인.
# ────────────────────────────────────────────────────────────────────
claude-check-deps() {
  local issue_number="$1"
  local body
  body=$(gh issue view "$issue_number" --json body --jq '.body')

  # grep -oP의 \K는 매치 시작점을 리셋하는 PCRE 기능.
  # "Depends on #"는 버리고 숫자만 캡처한다.
  local -a deps=()
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && deps+=("$dep")
  done < <(echo "$body" | grep -oP 'Depends on #\K\d+')

  if [[ ${#deps[@]} -eq 0 ]]; then
    echo "✅ 의존성 없음"
    return 0
  fi

  # 첫 실패에서 바로 return하지 않고 전체 의존 이슈를 다 보여준다.
  local all_closed=true
  for dep in "${deps[@]}"; do
    local state
    state=$(gh issue view "$dep" --json state --jq '.state')
    # #1008: gh issue view 는 PR 번호도 받아주지만 state 는 MERGED 를 반환 — CLOSED 와 동치 통과.
    if [[ "$state" != "CLOSED" && "$state" != "MERGED" ]]; then
      echo "❌ #${dep} 아직 열려 있음 (${state})"
      all_closed=false
    elif [[ "$state" == "MERGED" ]]; then
      echo "✅ #${dep} merged"
    else
      echo "✅ #${dep} closed"
    fi
  done

  if [[ "$all_closed" == "false" ]]; then
    echo ""
    echo "⚠️  의존성 미충족. 다른 이슈를 선택하거나 의존 이슈를 먼저 처리하세요."
    return 1
  fi
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — milestone title → number resolve (#509)
# 사용법: _claude-milestone-number <milestone-title>
# 출력: milestone number (정수, stdout) + return 0
# 미존재 시 stderr 안내 + return 1.
#
# REST `repos/.../milestones?state=all&per_page=100` 응답에서 title 정확 일치만
# 채택한다. 100개 초과 마일스톤은 본 프로젝트 운용상 비현실적이므로 추가
# pagination 은 의도적으로 생략 — 필요해지면 본 헬퍼만 확장하면 된다.
#
# title 매칭은 `gh api --jq` 가 아닌 외부 jq 파이프로 수행한다. `--jq` 인라인
# 필터에 셸 변수를 끼워넣으면 따옴표/특수문자(공백·콜론) 가 든 milestone 명에서
# 안전하지 않다. `jq --arg` 로 받으면 raw string 로 전달돼 회피된다.
# ────────────────────────────────────────────────────────────────────
_claude-milestone-number() {
  local milestone_title="$1"
  if [[ -z "$milestone_title" ]]; then
    echo "❌ _claude-milestone-number: milestone title 이 비었습니다." >&2
    return 1
  fi

  local repo
  repo=$(_claude-gh-retry gh repo view --json nameWithOwner --jq .nameWithOwner) || {
    echo "❌ 저장소 정보 조회 실패 (gh repo view)." >&2
    return 1
  }

  local milestone_json number
  milestone_json=$(_claude-gh-retry gh api "repos/${repo}/milestones?state=all&per_page=100") || {
    echo "❌ Milestone 목록 조회 실패." >&2
    return 1
  }

  number=$(printf '%s' "$milestone_json" \
    | jq -r --arg title "$milestone_title" '.[] | select(.title == $title) | .number' \
    | head -n 1)

  if [[ -z "$number" ]]; then
    echo "❌ Milestone '${milestone_title}' 을 찾을 수 없습니다 (state=all)." >&2
    return 1
  fi

  printf '%s' "$number"
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-create-milestone-checklist <milestone-title>
# 동작:
#   1. milestone title → number resolve (state=all 검색)
#   2. 해당 milestone 의 모든 이슈 조회 (state=all)
#   3. 체크리스트 본문 + 완료 조건 + Wrap-up 액션을 합쳐 이슈 본문 작성
#   4. gh issue create (생성된 체크리스트 이슈도 같은 milestone 에 묶음)
#   5. claude-set-issue-status <N> "Ready" 로 즉시 승격
#
# 설계 원칙 (#509):
#   체크리스트 이슈 = 가시성(범위 문서). 실제 완료 판정은 claude-check-milestone
#   이 GitHub API 로 직접 수행. 체크박스 자동 업데이트는 본문 덮어쓰기 충돌
#   회피 차원에서 의도적으로 미지원 — 사람이 진행상황 확인용으로만 갱신.
#
# 동일 제목 체크리스트 이슈 중복 검출:
#   `gh issue list --milestone <number> --search "in:title 완료 체크리스트"` 로
#   사전 검사 후 발견 시 stderr 경고 + return 1. milestone title 만으로는
#   재호출/idempotent 판정 기준이 모호하므로, 강제 재생성이 필요한 경우는
#   기존 체크리스트 이슈를 사용자가 직접 close 한 후 재호출한다.
# ────────────────────────────────────────────────────────────────────
claude-create-milestone-checklist() {
  local milestone_title="${1:-}"
  if [[ -z "$milestone_title" ]]; then
    echo "❌ 사용법: claude-create-milestone-checklist <milestone-title>" >&2
    return 1
  fi

  local milestone_number
  milestone_number=$(_claude-milestone-number "$milestone_title") || return 1

  # 중복 체크리스트 가드 — 동일 milestone 내에 OPEN 상태의 "완료 체크리스트"
  # 제목이 이미 있으면 거부. close 후 재호출 동선을 강제해 본문 덮어쓰기 충돌을
  # 원천 차단.
  local checklist_title="[Milestone] ${milestone_title} 완료 체크리스트"
  local existing
  existing=$(_claude-gh-retry gh issue list \
    --milestone "$milestone_number" \
    --state open \
    --search "in:title 완료 체크리스트" \
    --json number,title \
    --limit 50 2>/dev/null) || existing="[]"
  local existing_number
  existing_number=$(printf '%s' "$existing" \
    | jq -r --arg t "$checklist_title" '.[] | select(.title == $t) | .number' \
    | head -n 1)
  if [[ -n "$existing_number" ]]; then
    echo "⚠️  동일 제목의 체크리스트 이슈가 이미 OPEN 입니다: #${existing_number}" >&2
    echo "   재생성하려면 먼저 close 후 다시 실행하세요:" >&2
    echo "     gh issue close ${existing_number}" >&2
    return 1
  fi

  # 마일스톤 범위 이슈 목록 조회. state=all 로 closed 도 포함해 진행률을
  # 본문에 박제. checklist 자체는 매번 재생성하지 않으므로 시점 스냅샷으로 충분.
  local issues_json
  issues_json=$(_claude-gh-retry gh issue list \
    --milestone "$milestone_number" \
    --state all \
    --json number,title,state \
    --limit 200) || {
      echo "❌ Milestone 이슈 목록 조회 실패." >&2
      return 1
    }

  # 체크리스트 라인. 이미 closed 인 이슈는 - [x] 로 표기해 시작 시점 진행률을 표시.
  local issue_lines
  issue_lines=$(printf '%s' "$issues_json" | jq -r '
    sort_by(.number)[]
    | (if .state == "CLOSED" then "- [x]" else "- [ ]" end)
      + " #" + (.number | tostring) + " " + .title
  ')

  if [[ -z "$issue_lines" ]]; then
    echo "⚠️  Milestone '${milestone_title}' 에 이슈가 하나도 없습니다." >&2
    echo "   체크리스트 이슈를 그대로 생성하시려면 먼저 마일스톤에 이슈를 1개 이상 등록하세요." >&2
    return 1
  fi

  # heredoc 내부에서 ${...} 가 셸 확장되도록 `EOF` (unquoted) 사용.
  # 이슈 본문에 들어가는 백틱은 \` 로 escape 하지 않는다 — heredoc 내부에서 백틱은
  # 명령 치환을 일으키지 않고 그대로 들어간다 (다만 `$()` 형태는 치환되니 주의).
  local body
  body=$(cat <<EOF
## 마일스톤 완료 체크리스트: ${milestone_title}

### 이슈 완료 현황
<!-- claude-check-milestone 이 실제 closed 여부를 판정한다. 아래는 범위 문서. -->
${issue_lines}

### 완료 조건
- [ ] 해당 마일스톤 Issue 모두 closed
- [ ] 주요 기능 integration test 작성 및 통과 (해당하는 경우) _(AI 수행 의무 — 각 이슈 \`claude-close-issue\` 직전 test 작성 + CI 통과 확인)_
- [ ] UI/UX 자동화 검증 게이트 통과 (해당 마일스톤 기준) _(AI 수행 의무 — Playwright smoke+a11y·Storybook CI 준비 및 실행, UI 작업 없는 마일스톤은 해당 없음)_

### Wrap-up 액션
<!-- 1번 조건만 게이트로 남는다. 2·3번은 각 이슈 종료 시점에 AI 가 수행·보장. -->
1. claude-check-milestone "${milestone_title}" --close 실행
2. 다음 마일스톤 Issue 등록
3. claude-set-issue-status <N> "Ready"
EOF
)

  local issue_url
  issue_url=$(_claude-gh-retry gh issue create \
    --title "$checklist_title" \
    --body "$body" \
    --milestone "$milestone_title" \
    --label "milestone") || {
      echo "❌ 체크리스트 이슈 생성 실패." >&2
      return 1
    }

  local issue_number
  issue_number=$(printf '%s' "$issue_url" | sed -E 's|.*/issues/([0-9]+).*|\1|')
  if [[ -z "$issue_number" ]]; then
    echo "⚠️  체크리스트 이슈 번호 파싱 실패 (url=${issue_url})." >&2
    echo "   이슈는 생성됐습니다. Ready 승격은 수동으로 보정하세요:" >&2
    echo "     claude-set-issue-status <N> \"Ready\"" >&2
    return 1
  fi

  echo "✅ 체크리스트 이슈 생성: #${issue_number} (${issue_url})"

  # Ready 즉시 승격 — claude-register-related-issue 와 동일 정책.
  claude-set-issue-status "$issue_number" "Ready"
}

# ────────────────────────────────────────────────────────────────────
# 사용법: _claude-sync-phase1-milestones-doc <milestone-title>
# 인자:
#   milestone-title — `M0a — Scaffold & Tooling` 형식. claude-check-milestone
#     --close 가 PATCH state=closed 성공 직후에 전달.
# 동작:
#   1. <repo-root>/docs/planning/phase1-milestones.md 가 존재하면 진행.
#      없으면 ℹ️ 안내 후 return 0 (다른 저장소엔 이 파일이 없을 수 있음).
#   2. §헤더 `### <title> (N)` 라인에 ` — CLOSED <yyyy-mm-dd>` 마커 부착.
#      이미 `CLOSED` 마커 보유 시 idempotent skip.
#   3. §"마일스톤 체크리스트 이슈" 표에서 `| <title>` row 의 상태 컬럼을
#      `OPEN   ` → `CLOSED ` 로 치환 (컬럼 폭 보존).
# 실패 정책:
#   sync 실패는 마일스톤 close 자체의 성공/실패에 영향 없음 — stderr 경고
#   + return 0 (best-effort 자동화). #745 issue body §D "SSOT 충돌 방지"
#   정책에 따라 GitHub 측이 정본이며 본 문서는 마지막 동기화 스냅샷.
# ────────────────────────────────────────────────────────────────────
_claude-sync-phase1-milestones-doc() {
  local milestone_title="${1:-}"
  if [[ -z "$milestone_title" ]]; then
    echo "⚠️  _claude-sync-phase1-milestones-doc: milestone_title 누락 — skip" >&2
    return 0
  fi

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "⚠️  phase1-milestones.md 동기화: git repo 외부 — skip" >&2
    return 0
  }

  local doc_path="${repo_root}/docs/planning/phase1-milestones.md"
  if [[ ! -f "$doc_path" ]]; then
    echo "ℹ️  phase1-milestones.md 없음 — 상태 스냅샷 동기화 skip"
    return 0
  fi

  local close_date
  close_date=$(date -u +%Y-%m-%d)

  local tmp
  tmp=$(mktemp) || {
    echo "⚠️  phase1-milestones.md 동기화 실패 (mktemp) — skip" >&2
    return 0
  }

  if ! awk -v title="$milestone_title" -v date="$close_date" '
    BEGIN { hdr_changed=0; row_changed=0 }
    {
      # §헤더: ### <title> (N) → ### <title> (N) — CLOSED <date>
      # 이미 CLOSED 마커가 있으면 skip (idempotent).
      hdr_pattern = "^### " title " \\([0-9]+\\)$"
      if ($0 ~ hdr_pattern) {
        print $0 " — CLOSED " date
        hdr_changed=1
        next
      }

      # §체크리스트 표 row: | <title>...| #N...| OPEN   |
      # 폭 보존 — `OPEN   ` (7자) ↔ `CLOSED ` (7자) 치환.
      row_pattern = "^\\| " title "[[:space:]]+\\| #[0-9]+[[:space:]]+\\| OPEN[[:space:]]+\\|"
      if ($0 ~ row_pattern) {
        gsub(/\| OPEN   \|/, "| CLOSED |", $0)
        row_changed=1
      }
      print
    }
    END {
      # awk 종료 코드로 변경 여부 보고: 0=변경, 1=헤더만, 2=row만, 3=둘 다 미변경.
      exit (hdr_changed?0:1) + (row_changed?0:2)
    }
  ' "$doc_path" > "$tmp"; then
    : # awk 가 변경 카운트를 exit code 로 반환하므로 비-0 도 정상.
  fi

  if ! mv "$tmp" "$doc_path" 2>/dev/null; then
    echo "⚠️  phase1-milestones.md 동기화 실패 (mv) — skip" >&2
    rm -f "$tmp"
    return 0
  fi

  if grep -qE "^### ${milestone_title} \([0-9]+\) — CLOSED ${close_date}$" "$doc_path"; then
    echo "✅ phase1-milestones.md §헤더 '${milestone_title}' — CLOSED ${close_date} 마커 부착"
  else
    echo "ℹ️  phase1-milestones.md §헤더 '${milestone_title}' 변경 없음 (idempotent 또는 미발견)"
  fi
  return 0
}

# ────────────────────────────────────────────────────────────────────
# 사용법: _claude-ensure-next-milestone-checklist [repo]
# 인자:
#   repo (선택) — `owner/name`. 호출자(claude-check-milestone)가 이미
#     조회한 값을 재사용해 `gh repo view` 중복 호출을 피한다 (PR #712 review).
#     누락 시 본 함수가 직접 조회.
# 동작:
#   1. OPEN 마일스톤 중 number 가 가장 작은 것을 다음 마일스톤으로 선택.
#   2. 해당 마일스톤에 OPEN `milestone` 라벨 이슈가 있으면 skip (idempotent).
#   3. 없으면 claude-create-milestone-checklist <title> 위임.
# 호출 위치:
#   claude-check-milestone --close 가 PATCH state=closed 에 성공한 직후 (#704).
# 실패 정책:
#   체크리스트 자동 생성 실패는 마일스톤 close 자체의 성공/실패에 영향 없음.
#   stderr 경고 + return 0 (best-effort 자동화). 마일스톤 진입 시점에 체크리스트가
#   누락되는 것은 사람이 즉시 인지 가능하지만, close 가 실패로 보고되면 보드/
#   메타데이터가 일관되지 않아 더 큰 혼란을 부른다.
# ────────────────────────────────────────────────────────────────────
_claude-ensure-next-milestone-checklist() {
  local repo="${1:-}"
  if [[ -z "$repo" ]]; then
    repo=$(_claude-gh-retry gh repo view --json nameWithOwner --jq .nameWithOwner) || {
      echo "⚠️  다음 마일스톤 자동 체크리스트: 저장소 정보 조회 실패 — skip" >&2
      return 0
    }
  fi

  local open_ms_json
  open_ms_json=$(_claude-gh-retry gh api "repos/${repo}/milestones?state=open&per_page=100" 2>/dev/null) || {
    echo "⚠️  다음 마일스톤 자동 체크리스트: OPEN 마일스톤 목록 조회 실패 — skip" >&2
    return 0
  }

  local next_title next_number
  next_title=$(printf '%s' "$open_ms_json" \
    | jq -r 'sort_by(.number) | .[0].title // empty')
  next_number=$(printf '%s' "$open_ms_json" \
    | jq -r 'sort_by(.number) | .[0].number // empty')

  if [[ -z "$next_title" || -z "$next_number" ]]; then
    echo "ℹ️  다음 OPEN 마일스톤 없음 — 자동 체크리스트 생성 skip"
    return 0
  fi

  # idempotent — milestone 라벨 OPEN 이슈가 이미 있으면 skip.
  local existing_json existing_number
  existing_json=$(_claude-gh-retry gh issue list \
    --milestone "$next_number" \
    --label milestone \
    --state open \
    --json number \
    --limit 5 2>/dev/null) || existing_json="[]"
  existing_number=$(printf '%s' "$existing_json" | jq -r '.[0].number // empty')
  if [[ -n "$existing_number" ]]; then
    echo "ℹ️  다음 마일스톤 '${next_title}' 체크리스트 이슈 존재 (#${existing_number}) — skip"
    return 0
  fi

  echo "▶ 다음 마일스톤 '${next_title}' 체크리스트 자동 생성"
  if ! claude-create-milestone-checklist "$next_title"; then
    echo "⚠️  다음 마일스톤 '${next_title}' 체크리스트 자동 생성 실패 — 수동 보정 필요 (claude-create-milestone-checklist \"${next_title}\")" >&2
  fi
  return 0
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-check-milestone <milestone-title> [--close]
# 동작:
#   1. milestone title → number resolve
#   2. open 상태 이슈 조회
#   3. open 잔존 → [FAIL] + 잔여 목록 출력 + return 1
#   4. 모두 closed → [PASS] + return 0
#   5. --close 플래그가 켜지면 PATCH /repos/.../milestones/<n> state=closed
#   6. --close 성공 직후 _claude-ensure-next-milestone-checklist 호출 — 다음
#      OPEN 마일스톤의 체크리스트 이슈가 누락되어 있으면 자동 생성 (#704).
#
# 의도(#509, #524):
#   `docs/github-integration.md §마일스톤 완료 절차` 의 1번 조건(전체 이슈 closed) 을
#   API 로 직접 확인하는 단일 게이트. 2/3번 조건(integration test, UI/UX
#   자동화 게이트) 은 AI 수행 의무 — 각 이슈 `claude-close-issue` 종료 시점에
#   integration test 작성 + CI 통과, UI 변경 시 Playwright smoke+a11y·Storybook
#   CI 준비/실행을 AI 가 직접 보장한다. 따라서 마일스톤 마감 시점에는 1번만
#   게이트로 남고, 본 함수의 PASS 가 곧 마일스톤 종료 가능 여부를 결정한다.
#
# `--close` 처리:
#   PATCH 는 `gh api -X PATCH ... -f state=closed` 패턴. `state` 는 String! 이
#   아닌 REST 필드라 `-f` / `-F` 차이가 결과에 영향을 주지 않지만, 문자열 값에는
#   `-f` 로 통일한다 (#213 정책 외부 적용).
# ────────────────────────────────────────────────────────────────────
claude-check-milestone() {
  local milestone_title=""
  local close_flag=false
  local arg
  for arg in "$@"; do
    case "$arg" in
      --close) close_flag=true ;;
      --*)
        echo "❌ claude-check-milestone: 알 수 없는 옵션 '${arg}'" >&2
        return 1
        ;;
      *)
        if [[ -n "$milestone_title" ]]; then
          echo "❌ claude-check-milestone: milestone title 인자가 중복됐습니다." >&2
          return 1
        fi
        milestone_title="$arg"
        ;;
    esac
  done

  if [[ -z "$milestone_title" ]]; then
    echo "❌ 사용법: claude-check-milestone <milestone-title> [--close]" >&2
    return 1
  fi

  local milestone_number
  milestone_number=$(_claude-milestone-number "$milestone_title") || return 1

  local repo
  repo=$(_claude-gh-retry gh repo view --json nameWithOwner --jq .nameWithOwner) || {
    echo "❌ 저장소 정보 조회 실패 (gh repo view)." >&2
    return 1
  }

  # open 이슈만 조회. 합계는 milestone 메타데이터의 open_issues + closed_issues
  # 로 별도 산출 — `gh issue list` 두 번 호출은 page limit 위험과 토큰 낭비.
  local meta
  meta=$(_claude-gh-retry gh api "repos/${repo}/milestones/${milestone_number}") || {
    echo "❌ Milestone 메타데이터 조회 실패." >&2
    return 1
  }
  local open_count closed_count total
  open_count=$(printf '%s' "$meta" | jq -r '.open_issues // 0')
  closed_count=$(printf '%s' "$meta" | jq -r '.closed_issues // 0')
  total=$((open_count + closed_count))

  if [[ "$open_count" -gt 0 ]]; then
    echo "[FAIL] Milestone \"${milestone_title}\" — open 이슈 ${open_count}개 잔여"
    local open_list
    open_list=$(_claude-gh-retry gh issue list \
      --milestone "$milestone_number" \
      --state open \
      --json number,title \
      --limit 200) || open_list="[]"
    printf '%s' "$open_list" | jq -r 'sort_by(.number)[] | "  ❌ #\(.number) \(.title) (open)"'
    return 1
  fi

  echo "[PASS] Milestone \"${milestone_title}\" — 전체 ${total}개 이슈 모두 closed"

  if [[ "$close_flag" == "true" ]]; then
    if ! _claude-gh-retry gh api -X PATCH "repos/${repo}/milestones/${milestone_number}" \
        -f state=closed >/dev/null; then
      echo "❌ Milestone close 처리 실패." >&2
      return 1
    fi
    echo "✅ Milestone closed 처리 완료"
    # #704: 다음 마일스톤 체크리스트 자동 생성 (idempotent · best-effort).
    # PR #712 리뷰 — 이미 확보한 $repo 를 재사용해 gh repo view 중복 호출 방지.
    _claude-ensure-next-milestone-checklist "$repo"
    # #745: docs/planning/phase1-milestones.md 상태 스냅샷 동기화 (best-effort).
    _claude-sync-phase1-milestones-doc "$milestone_title"
  fi

  return 0
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 보류 라벨 가드 (#233)
# 사용법: _claude-check-blocked-labels <labels-json> <issue-number>
# labels-json 은 `gh issue view --json labels --jq '.labels'` 의 출력
# (라벨 객체 배열). CLAUDE_BLOCKED_LABELS 의 라벨이 하나라도 매치되면
# stderr 안내 메시지를 출력하고 return 1, 매치 없으면 조용히 return 0.
#
# claude-enter-issue 가 worktree/브랜치 생성 직전에 호출해 명시적으로 보류된
# 이슈의 모델 호출/토큰 소비를 원천 차단한다. 진입 시점 1회 검사만 수행하고
# 실행 중 abort 는 하지 않는다 (이슈 #233 §엣지 케이스 정책).
# ────────────────────────────────────────────────────────────────────
_claude-check-blocked-labels() {
  local labels_json="$1"
  local issue_number="$2"
  local labels matched=""

  labels=$(printf '%s' "$labels_json" | jq -r '.[].name' 2>/dev/null) || return 0

  local blocked
  for blocked in "${CLAUDE_BLOCKED_LABELS[@]}"; do
    if printf '%s\n' "$labels" | grep -Fxq -- "$blocked"; then
      matched="$blocked"
      break
    fi
  done

  if [[ -z "$matched" ]]; then
    return 0
  fi

  cat >&2 <<EOF
✋ Issue #${issue_number} has the "${matched}" label — claude-enter-issue refuses to start.

Reason: this issue is intentionally on hold (see issue body / comments).
Re-running on it will waste model tokens and may produce unwanted code changes.

To proceed:
  1. Read the issue and its comments to confirm the hold is lifted.
  2. Remove the hold label:  claude-unhold-issue ${issue_number}
  3. Re-run claude-enter-issue ${issue_number}.
EOF
  return 1
}

# ────────────────────────────────────────────────────────────────────
# 보류 라벨 해제 — claude-enter-issue 가 거부한 이슈를 다시 진행 가능하게 함 (#233)
# 사용법: claude-unhold-issue <issue-number>
# 실행 위치: 제약 없음 (라벨 제거 mutation 1건 — main / worktree 무관).
#
# 이슈 라벨을 먼저 조회해 실제 부착된 CLAUDE_BLOCKED_LABELS 만 제거한다 → idempotent:
# 라벨이 이미 없으면 DELETE 자체를 건너뛰어, 없는 라벨에 DELETE 했을 때의 404 +
# _claude-gh-retry 3회 재시도(7s 낭비)를 피한다. 조회와 DELETE 사이 레이스로 라벨이
# 사라진 경우(DELETE 가 404)도 성공으로 처리해 idempotency 를 무조건 보장한다.
#
# `gh issue edit --remove-label` 대신 REST DELETE 를 쓰는 이유: classic Projects
# 가 활성화된 repo 에서 `gh issue edit --remove-label` 이 silent-fail 하는 사례가
# 있다 (#35, #595). REST `DELETE .../labels/<name>` 은 이 환경에서도 확정적으로
# 동작한다. 라벨명은 비ASCII(한글 '보류')·공백을 포함할 수 있어 @uri 인코딩한다.
# ────────────────────────────────────────────────────────────────────
claude-unhold-issue() {
  # set -u 환경에서도 안전하도록 인자 미지정 시 빈 문자열로 폴백.
  local issue_number="${1:-}"

  if [[ -z "$issue_number" || ! "$issue_number" =~ ^[0-9]+$ ]]; then
    echo "❌ 사용법: claude-unhold-issue <issue-number> (숫자)" >&2
    return 1
  fi

  local repo
  repo=$(_claude-gh-retry gh repo view --json nameWithOwner --jq .nameWithOwner) || {
    echo "❌ repo 정보를 가져오지 못했습니다." >&2
    return 1
  }

  # 부착된 라벨을 먼저 조회 — 없는 라벨에 대한 불필요한 DELETE/재시도를 피한다.
  local labels
  labels=$(_claude-gh-retry gh issue view "$issue_number" --json labels --jq '.labels[].name') || {
    echo "❌ #${issue_number} 라벨 정보를 가져오지 못했습니다." >&2
    return 1
  }

  local blocked enc err rc removed_any=0
  for blocked in "${CLAUDE_BLOCKED_LABELS[@]}"; do
    # 부착되지 않은 라벨은 건너뛴다 (정확 일치만 — grep -Fxq).
    printf '%s\n' "$labels" | grep -Fxq -- "$blocked" || continue

    enc=$(printf %s "$blocked" | jq -sRr @uri)

    # gh stdout(잔여 라벨 JSON)은 버리고 stderr 만 캡처해 404(레이스) 판별에 쓴다.
    err=$(_claude-gh-retry gh api -X DELETE \
      "repos/${repo}/issues/${issue_number}/labels/${enc}" 2>&1 >/dev/null)
    rc=$?

    if (( rc == 0 )); then
      echo "✅ #${issue_number} '${blocked}' 라벨 제거" >&2
      removed_any=1
    elif printf '%s' "$err" | grep -q '404\|Not Found'; then
      : # 조회~DELETE 레이스로 이미 제거됨 — idempotent.
    else
      echo "❌ #${issue_number} '${blocked}' 라벨 제거 실패:" >&2
      printf '%s\n' "$err" >&2
      return 1
    fi
  done

  if (( removed_any == 0 )); then
    echo "ℹ️  #${issue_number} 에 제거할 보류 라벨이 없습니다 (이미 해제됨)." >&2
  fi
  return 0
}

# ────────────────────────────────────────────────────────────────────
# 3-a단계 — main에서 이슈 전용 worktree 생성 (진입 준비)
# 사용법: claude-enter-issue <issue-number> [parent]
# 실행 위치: main worktree의 main 브랜치에서만 허용.
#
# 책임:
#   1) 동시 작업 가드 (assignee · 원격 브랜치)
#   2) self-assign (@me)
#   3) base ref(기본 origin/main, parent 지정 시 부모) 기반으로
#      .claude/worktrees/issue-<N> worktree + 브랜치 생성
#   4) 다음 단계 안내 — Claude Code 세션은 harness EnterWorktree 로 자동 진입,
#      그 외 클라이언트는 수동 cd + 새 세션 fallback (#195)
#
# 2번째 인자 [parent] (#333 — stacked PR 진입 지원):
#   없음          → base=origin/main 동작 (기존).
#   숫자          → 부모 PR 번호. `gh pr view <PR> --json state,headRefName` 로
#                   검증 — state == OPEN 이어야 하며, headRefName 을 base ref 로
#                   사용한다 (claude-close-issue 의 stacked 4번째 인자와 짝).
#   비숫자        → 원격 브랜치명. `git ls-remote --heads origin <branch>` 로
#                   존재 확인 후 base ref 로 사용한다.
#
# Status 전환(In progress)은 이 단계에서 수행하지 않는다 — 실제 작업 세션이
# worktree 안에서 열릴 때 claude-start-issue가 담당한다. worktree만 만들고
# 방치된 "좀비 worktree" 상태와 "실제 작업 중" 상태를 Project 보드에서 구분할
# 수 있게 하는 의도.
# ────────────────────────────────────────────────────────────────────
claude-enter-issue() {
  local issue_number="$1"
  # set -u 환경에서도 안전하도록 옵션 인자에 기본값 처리 (#333).
  local parent="${2:-}"

  if [[ -z "$issue_number" ]]; then
    echo "❌ 사용법: claude-enter-issue <issue-number> [parent]" >&2
    return 1
  fi

  # 가드 1: 이미 이슈에 바인딩된 세션이면 새 worktree 생성을 거부.
  local bound_issue
  if bound_issue=$(claude-session-bound); then
    echo "⚠️  이 세션은 이미 이슈 #${bound_issue}에 바인딩되어 있습니다 (브랜치: $(git rev-parse --abbrev-ref HEAD))." >&2
    echo "    새 이슈 worktree는 main worktree에서 새로 열어 생성하세요." >&2
    return 1
  fi

  # 가드 2: main 브랜치 위에서만 허용. worktree 경로 결정의 기준점이 되기 때문.
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [[ "$branch" != "main" ]]; then
    echo "❌ claude-enter-issue는 main 브랜치에서만 실행 가능합니다 (현재: ${branch})." >&2
    echo "   main worktree로 돌아간 뒤 다시 시도하세요." >&2
    return 1
  fi

  # 가드 3: worktree 경로 선점. 이미 존재하면 이전 세션 잔재일 가능성이 높으므로
  # 조용히 재사용하지 않고 명시적으로 정리를 요구한다.
  local worktree_path=".claude/worktrees/issue-${issue_number}"
  if [[ -e "$worktree_path" ]]; then
    echo "❌ ${worktree_path} 가 이미 존재합니다." >&2
    echo "   이전 세션이 정리되지 않았을 가능성이 높습니다. 정리 후 재시도:" >&2
    echo "     claude-cleanup-worktree ${issue_number}" >&2
    return 1
  fi

  # 사전 체크 1: Assignee 충돌.
  # 본인 외 다른 사람이 이미 assigned면 abort. (본인만 있거나 비어있으면 통과.)
  # issue_data에 assignees·title·labels를 함께 담아 보류 라벨 가드(#233)와
  # 뒤쪽 slug 생성 단계에서 재사용한다 (gh issue view 호출을 한 번으로 절감).
  local me issue_data current_assignees other_assignees labels_json
  me=$(gh api user --jq .login)
  issue_data=$(gh issue view "$issue_number" --json assignees,title,labels)

  # 사전 체크 1-a: 보류 라벨 가드 (#233).
  # assignee/원격 브랜치 검사보다 먼저 실행 — 보류 이슈는 다른 검사 결과와 무관하게
  # 차단되어야 한다. self-assign(첫 mutation) 이전에 두어 보류 이슈에 우연히
  # @me 가 붙는 부수효과를 막는다.
  labels_json=$(printf '%s' "$issue_data" | jq -c '.labels')
  _claude-check-blocked-labels "$labels_json" "$issue_number" || return 1

  current_assignees=$(printf '%s' "$issue_data" | jq -c '[.assignees[].login]')
  other_assignees=$(printf '%s' "$current_assignees" | jq -r --arg me "$me" '[.[] | select(. != $me)] | join(", ")')
  if [[ -n "$other_assignees" ]]; then
    echo "❌ #${issue_number}는 이미 ${other_assignees}에게 할당되어 있습니다." >&2
    echo "   다른 이슈를 선택하거나, 담당자와 핸드오프를 조율한 뒤 수동으로 assignee를 교체하세요." >&2
    return 1
  fi

  # 사전 체크 2: 원격 브랜치 충돌.
  # 본 저장소의 브랜치 컨벤션 두 가지를 모두 커버: issue-<N>-<slug>, wt/issue-<N>/<n>.
  # [^0-9] 경계로 issue-87과 issue-870을 구분한다. grep 매치 없음은 실패 종료코드지만
  # || true로 흡수해 set -e 환경에서도 안전.
  local existing_branches
  existing_branches=$(git ls-remote --heads origin 2>/dev/null \
    | awk '{print $2}' \
    | grep -E "refs/heads/.*issue[-/]${issue_number}([^0-9]|$)" || true)
  if [[ -n "$existing_branches" ]]; then
    echo "❌ #${issue_number} 관련 원격 브랜치가 이미 존재합니다:" >&2
    echo "$existing_branches" | sed 's|refs/heads/|  - |' >&2
    echo "   다른 사람이 작업 중일 가능성이 높습니다. 다른 이슈를 선택하세요." >&2
    return 1
  fi

  # base ref 결정: parent 빈값이면 main, 숫자면 부모 PR head, 그 외엔
  # 원격 브랜치명. mutation(self-assign·worktree) 진입 전 마지막 read-only
  # 게이트로 두어 검증 실패 시 어떤 상태도 변경되지 않도록 한다 (#333).
  local base_ref="main"
  if [[ -n "$parent" ]]; then
    if [[ "$parent" =~ ^[0-9]+$ ]]; then
      local parent_meta parent_state parent_head
      if ! parent_meta=$(_claude-gh-retry gh pr view "$parent" --json headRefName,state); then
        echo "❌ 부모 PR #${parent} 조회 실패." >&2
        return 1
      fi
      parent_state=$(printf '%s' "$parent_meta" | jq -r '.state // empty')
      parent_head=$(printf '%s' "$parent_meta" | jq -r '.headRefName // empty')
      if [[ "$parent_state" != "OPEN" ]]; then
        echo "❌ 부모 PR #${parent}이 OPEN 상태가 아닙니다 (state=${parent_state})." >&2
        echo "   stacked PR 진입은 부모가 OPEN인 동안에만 가능합니다." >&2
        return 1
      fi
      if [[ -z "$parent_head" ]]; then
        echo "❌ 부모 PR #${parent}의 headRefName을 가져오지 못했습니다." >&2
        return 1
      fi
      base_ref="$parent_head"
      echo "🪜 stacked 모드: 부모 PR #${parent} (head=${base_ref})"
    else
      # 비숫자 → 원격 브랜치명. _claude-gh-retry 로 간헐적 프록시 절단을
      # 흡수해 네트워크 오류와 "브랜치 미존재"를 분리한다 (PR #336 review).
      local ls_out
      if ! ls_out=$(_claude-gh-retry git ls-remote --heads origin "$parent"); then
        return 1
      fi
      if [[ -z "$ls_out" ]]; then
        echo "❌ origin에 브랜치 '${parent}' 가 존재하지 않습니다." >&2
        return 1
      fi
      base_ref="$parent"
      echo "🪜 stacked 모드: 부모 브랜치 ${base_ref}"
    fi
  fi

  # 사전 체크 통과 → self-assign (첫 번째 mutation).
  # 이후 단계(worktree 생성)가 실패하더라도 assignee는 남아 "내가 손댄 이슈"
  # 신호가 유지된다.
  gh issue edit "$issue_number" --add-assignee @me > /dev/null
  echo "✅ #${issue_number} self-assigned (@${me})"

  # 브랜치명 결정 — 한글 전용 제목은 빈 슬러그, 그 경우 'issue-N'으로 폴백.
  local title slug branch_name
  title=$(printf '%s' "$issue_data" | jq -r '.title')
  slug=$(claude-issue-slug "$title")
  if [[ -z "$slug" ]]; then
    branch_name="issue-${issue_number}"
  else
    branch_name="issue-${issue_number}-${slug}"
  fi

  # base_ref(기본 main, parent 지정 시 부모 head/branch) 기반으로 worktree +
  # 브랜치를 한번에 생성한다. `git worktree add -b` 는 대상 경로가 없을 때만
  # 성공하므로 가드 3과 짝을 이룬다. fetch 는 _claude-gh-retry 로 간헐적
  # 프록시 절단을 흡수한다 (PR #336 review).
  mkdir -p .claude/worktrees || return 1
  _claude-gh-retry git fetch origin "$base_ref" --quiet || return 1
  git worktree add "$worktree_path" -b "$branch_name" "origin/${base_ref}" || return 1
  echo "✅ worktree 생성: ${worktree_path} (브랜치: ${branch_name})"

  # 다음 단계 안내 — Claude Code 세션은 harness EnterWorktree 로 같은 세션을
  # worktree 컨텍스트로 자동 전환하고 claude-start-issue 를 연쇄 호출한다 (#195).
  # EnterWorktree 가 없는 클라이언트(웹/IDE)는 수동 cd + 새 세션 fallback.
  cat <<EOF

다음 단계 (Claude Code 세션 — 권장):
  Claude 가 EnterWorktree 도구로 ${worktree_path} 컨텍스트로 자동 전환합니다.
  그 직후 claude-start-issue ${issue_number} 가 자동 호출되어 Status 가 In progress 로 넘어갑니다.

다른 클라이언트 (EnterWorktree 미지원) — fallback:
  1. cd ${worktree_path}
  2. claude                                # 해당 worktree에서 새 Claude 세션 시작
  3. claude-start-issue ${issue_number}    # 세션 내부에서 이슈 컨텍스트 로드 + Status 전환
EOF
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — claude-adopt-worktree 의 타깃 경로/브랜치 이름 파생 (순수 함수)
# 사용법: _claude-adopt-names <issue> <branch> <title>
# 출력: "<target-path><TAB><branch>" (성공 시 return 0). trivial 모드에서
#       슬러그가 비면 출력 없이 return 1 (fail-closed).
#
# claude-adopt-worktree 에서 분리한 이유는 단위 테스트 seam 확보 — 실제
# git worktree 조작 없이 이름 파생 로직만 검증할 수 있게 한다.
#
# 모드:
#   이슈 모드(<issue> 비어있지 않음): 경로 .claude/worktrees/issue-<N>,
#     브랜치 issue-<N>-<slug> (claude-cleanup-worktree/claude-session-bound
#     완전 호환). slug 는 제목 우선, 비면 현재 브랜치를 소스로(<title|branch>),
#     그래도 비면 'issue-<N>'.
#   trivial 모드(<issue> 비어있음):
#     - feature 브랜치: 브랜치명 유지, 경로 .claude/worktrees/<slug(branch)>.
#     - main 위: 새 브랜치가 필요하므로 <slug(title)> 로 브랜치/경로 생성.
#       title 도 없어 슬러그가 비면 return 1.
# ────────────────────────────────────────────────────────────────────
_claude-adopt-names() {
  local issue="${1:-}"
  local branch="${2:-}"
  local title="${3:-}"
  local slug target new_branch

  if [[ -n "$issue" ]]; then
    slug=$(claude-issue-slug "${title:-$branch}")
    if [[ -z "$slug" ]]; then
      new_branch="issue-${issue}"
    else
      new_branch="issue-${issue}-${slug}"
    fi
    target=".claude/worktrees/issue-${issue}"
  elif [[ -n "$branch" && "$branch" != "main" ]]; then
    # trivial 모드 — 이미 feature 브랜치: 브랜치명은 유지하고 경로만 슬러그화.
    slug=$(claude-issue-slug "$branch")
    if [[ -z "$slug" ]]; then
      return 1
    fi
    new_branch="$branch"
    target=".claude/worktrees/${slug}"
  else
    # trivial 모드 — main 위: title 슬러그로 새 브랜치/경로. 빈 슬러그면 fail.
    slug=$(claude-issue-slug "$title")
    if [[ -z "$slug" ]]; then
      return 1
    fi
    new_branch="$slug"
    target=".claude/worktrees/${slug}"
  fi

  printf '%s\t%s\n' "$target" "$new_branch"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — claude-adopt-worktree 실패 시 stash 복원 (비파괴 실패 보장)
# 사용법: _claude-adopt-unstash <stashed-flag>
# stashed-flag 가 "1" 일 때만 동작. pop 실패 시 변경은 stash 에 보존된다.
# ────────────────────────────────────────────────────────────────────
_claude-adopt-unstash() {
  local stashed="${1:-0}"
  [[ "$stashed" == "1" ]] || return 0
  if git stash pop >/dev/null 2>&1; then
    echo "ℹ️  실패로 중단 — stash 한 변경을 main worktree 에 복원했습니다." >&2
  else
    echo "⚠️  stash 복원(pop) 실패 — 변경은 stash 에 보존돼 있습니다: git stash list / git stash pop" >&2
  fi
}

# ────────────────────────────────────────────────────────────────────
# 보조 — gh-pr 의 in-place 브랜치를 격리 worktree 로 마이그레이션
# 사용법: claude-adopt-worktree [<issue-number>] [<title>]
# 실행 위치: main worktree (worktree 내부면 no-op). gh-pr 스킬 전용.
#
# `/gh-pr` 는 main worktree 에서 feature 브랜치를 만들어 in-place 로 PR 을
# 올린다 — github-workflow 의 "이슈 작업은 항상 격리 트리에서" 원칙과 어긋난다.
# 본 함수는 PR 생성 직전(Step 4.5)에 현재 브랜치의 커밋/미커밋 변경을 격리
# worktree 로 옮기고 main worktree 를 clean default branch 로 되돌린다.
#
# 멱등성: worktree 내부에서 호출되면 ℹ️ 안내 후 return 0 — gh-pr 가 무조건
# 호출해도 안전하다. 마이그레이션할 변경이 없어도(clean·ahead=0) return 0.
#
# 반환값:
#   0 = 마이그레이션 완료 / no-op (worktree 내부 · clean·ahead=0)
#   1 = 가드 실패 (경로 충돌 · 로컬 브랜치 충돌 · 이름 파생 실패 · git 오류)
#   3 = stash pop 충돌 — 변경은 stash 에 보존, 마커 미출력 (스킬이 중단)
#
# 성공 시 stdout 마지막에 기계 파싱용 마커 `ADOPTED_WORKTREE=<path>` 를 출력 —
# 스킬은 이 줄을 보고 EnterWorktree 로 전환한다.
# ────────────────────────────────────────────────────────────────────
claude-adopt-worktree() {
  local issue_number="${1:-}"
  local title="${2:-}"

  # ── 1. worktree 내부 가드 (멱등 no-op) ──
  # git-common-dir 과 git-dir 의 절대경로 비교 (shgwt_in_main_repo 와 동일 기법,
  # 의존성 없이 인라인). 둘이 다르면 worktree 내부 → 이미 격리됨.
  local common dir common_abs dir_abs
  if ! common=$(git rev-parse --git-common-dir 2>/dev/null) \
    || ! dir=$(git rev-parse --git-dir 2>/dev/null); then
    echo "❌ git 저장소 안에서 실행하세요." >&2
    return 1
  fi
  common_abs=$(cd "$common" 2>/dev/null && pwd -P) || return 1
  dir_abs=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  if [[ "$common_abs" != "$dir_abs" ]]; then
    echo "ℹ️  이미 worktree 내부입니다 — 마이그레이션 불필요 (idempotent no-op)."
    return 0
  fi

  # ── 2. 상태 캡처 ──
  local branch base dirty ahead
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  base=$(_claude-gh-retry gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
  [[ -z "$base" ]] && base="main"
  dirty=$(git status --porcelain 2>/dev/null)
  ahead=$(git rev-list --count "origin/${base}..HEAD" 2>/dev/null || echo 0)

  # ── 3. 마이그레이션 불요 가드 ──
  if [[ -z "$dirty" && "${ahead:-0}" -eq 0 ]]; then
    if [[ "$branch" == "$base" ]]; then
      # main + clean + ahead=0 → gh-pr Step 1 의 "nothing to PR" stop-condition
      # 이 처리하므로 본 함수는 조용히 통과 (삼키지 않음).
      return 0
    fi
    echo "ℹ️  마이그레이션할 변경이 없습니다 (clean · ahead=0)."
    return 0
  fi

  # ── 4. 타깃 경로/브랜치 결정 ──
  local names target new_branch
  if ! names=$(_claude-adopt-names "$issue_number" "$branch" "$title"); then
    echo "❌ 브랜치/경로 이름을 만들 수 없습니다 (제목·브랜치 모두 슬러그가 비었습니다)." >&2
    echo "   trivial 모드는 의미 있는 제목이 필요합니다: claude-adopt-worktree \"\" \"<title>\"" >&2
    return 1
  fi
  target="${names%%$'\t'*}"
  new_branch="${names#*$'\t'}"

  # 이슈 모드에서 현재 브랜치가 이미 그 이슈에 바인딩돼 있으면 브랜치명을 유지한다
  # (issue-<N>-<old-slug> 의 불필요한 재명명 방지).
  if [[ -n "$issue_number" ]]; then
    local bound_issue
    if bound_issue=$(claude-session-bound 2>/dev/null) && [[ "$bound_issue" == "$issue_number" ]]; then
      new_branch="$branch"
    fi
  fi

  # ── 5. 경로 충돌 가드 ──
  if [[ -e "$target" ]]; then
    echo "❌ ${target} 가 이미 존재합니다." >&2
    echo "   이전 세션 잔재일 수 있습니다. 정리 후 재시도하세요." >&2
    return 1
  fi

  # ── 6. rename 충돌 가드 ──
  if [[ "$new_branch" != "$branch" ]]; then
    if git show-ref --verify --quiet "refs/heads/${new_branch}"; then
      echo "❌ 로컬 브랜치 '${new_branch}' 가 이미 존재합니다 — 충돌로 중단합니다." >&2
      return 1
    fi
    if git ls-remote --exit-code --heads origin "$new_branch" >/dev/null 2>&1; then
      echo "⚠️  원격 'origin/${new_branch}' 가 이미 존재합니다 — 재실행 멱등성으로 진행합니다." >&2
    fi
  fi

  # ── 7. dirty 면 stash (untracked 포함) ──
  local stashed=0
  if [[ -n "$dirty" ]]; then
    if ! git stash push -u -m "claude-adopt-worktree:${branch}" >/dev/null; then
      echo "❌ git stash 실패 — 변경을 안전하게 옮길 수 없습니다." >&2
      return 1
    fi
    stashed=1
  fi

  # ── 8. worktree 생성 → main 복귀 (순서가 핵심 — 커밋 유실 방지) ──
  if ! mkdir -p .claude/worktrees; then
    echo "❌ .claude/worktrees 생성 실패." >&2
    _claude-adopt-unstash "$stashed"
    return 1
  fi

  if [[ "$branch" == "$base" ]]; then
    # main 위 + ahead>0: HEAD 로 worktree 새 브랜치 생성 → 성공한 뒤에만 main 리셋.
    if ! git worktree add -b "$new_branch" "$target" HEAD; then
      echo "❌ worktree 생성 실패." >&2
      _claude-adopt-unstash "$stashed"
      return 1
    fi
    if ! git reset --hard "origin/${base}"; then
      echo "⚠️  worktree 는 생성됐으나 ${base} 를 origin/${base} 로 되돌리지 못했습니다 — 수동 확인:" >&2
      echo "     git reset --hard origin/${base}" >&2
    fi
  else
    # feature 브랜치: HEAD SHA 캡처 → base 체크아웃 → worktree 생성.
    local head_sha
    head_sha=$(git rev-parse HEAD)
    if ! git checkout "$base" 2>/dev/null \
      && ! git checkout -b "$base" "origin/${base}" 2>/dev/null; then
      echo "❌ ${base} 체크아웃 실패 — main 복귀 불가." >&2
      _claude-adopt-unstash "$stashed"
      return 1
    fi
    if [[ "$new_branch" != "$branch" ]]; then
      if ! git worktree add -b "$new_branch" "$target" "$head_sha"; then
        echo "❌ worktree 생성 실패." >&2
        git checkout "$branch" 2>/dev/null
        _claude-adopt-unstash "$stashed"
        return 1
      fi
      # 옛 로컬 브랜치 제거 — 로컬만. 원격에 push 돼 있으면 orphan 안내만 하고
      # 원격 브랜치는 삭제하지 않는다.
      if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
        echo "ℹ️  원격 'origin/${branch}' 는 그대로 둡니다 (orphan — 필요 시 수동 삭제)."
      fi
      git branch -D "$branch" >/dev/null 2>&1
    else
      if ! git worktree add "$target" "$branch"; then
        echo "❌ worktree 생성 실패." >&2
        git checkout "$branch" 2>/dev/null
        _claude-adopt-unstash "$stashed"
        return 1
      fi
    fi
  fi

  # ── 9. stash 했으면 worktree 안으로 pop (cleanup-worktree 서브셸 패턴) ──
  if [[ "$stashed" == "1" ]]; then
    if ! ( cd "$target" && git stash pop ); then
      echo "⚠️  worktree 로 stash pop 중 충돌 — 변경은 stash 에 보존돼 있습니다." >&2
      echo "   수동 복구:" >&2
      echo "     cd ${target} && git stash pop   # 충돌 해결 후 계속" >&2
      return 3
    fi
  fi

  # ── 10. 성공 출력 + 기계 파싱 마커 ──
  echo "✅ worktree 마이그레이션 완료: ${target} (브랜치: ${new_branch})"
  echo "ADOPTED_WORKTREE=${target}"
  cat <<EOF

다음 단계:
  Claude 가 EnterWorktree 도구로 ${target} 컨텍스트로 전환한 뒤 PR 생성을 계속합니다.
EOF
}

# ────────────────────────────────────────────────────────────────────
# 3-b단계 — worktree 내부에서 이슈 작업 시작
# 사용법: claude-start-issue <issue-number>
# 실행 위치: issue-<N>-... 브랜치를 체크아웃한 worktree 내부에서만 허용.
#
# 책임:
#   1) 위치 가드 (main 차단, 바인딩 브랜치 강제, 번호 일치 확인)
#   2) Project 보드 Status: Backlog / Ready → In progress
#   3) 이슈 컨텍스트 출력 (작업 세션 시작 시점의 스냅샷)
#
# 브랜치 생성·self-assign은 claude-enter-issue(main)에서 이미 수행됨.
# ────────────────────────────────────────────────────────────────────
claude-start-issue() {
  local issue_number="$1"

  if [[ -z "$issue_number" ]]; then
    echo "❌ 사용법: claude-start-issue <issue-number>" >&2
    return 1
  fi

  # 가드 1: main에서 호출되면 worktree 흐름을 안내하고 차단.
  # 이 정책(worktree에서만 claude-start-issue 허용)은 "이슈 작업은 항상 격리된
  # 트리에서"라는 본 저장소의 원칙을 강제한다.
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [[ "$branch" == "main" ]]; then
    echo "❌ main에서는 claude-start-issue를 실행할 수 없습니다." >&2
    echo "   이슈 전용 worktree를 먼저 만드세요:" >&2
    echo "     claude-enter-issue ${issue_number}" >&2
    return 1
  fi

  # 가드 2: 브랜치가 issue-<N>-... 형식이어야 한다 (세션 바인딩 필수).
  local bound_issue
  if ! bound_issue=$(claude-session-bound); then
    echo "❌ 현재 브랜치가 issue-<N>-<slug> 형식이 아닙니다 (현재: ${branch})." >&2
    echo "   claude-start-issue는 이슈 전용 worktree에서만 실행 가능합니다." >&2
    echo "   main으로 돌아가 claude-enter-issue ${issue_number}를 먼저 실행하세요." >&2
    return 1
  fi

  # 가드 3: 바인딩된 이슈와 인자가 일치해야 한다 — 엉뚱한 worktree에서
  # 다른 이슈의 Status가 전환되는 사고 방지.
  if [[ "$bound_issue" != "$issue_number" ]]; then
    echo "❌ 현재 worktree는 #${bound_issue}에 바인딩되어 있는데 #${issue_number}로 시작 시도 중입니다." >&2
    echo "   올바른 worktree로 이동하거나 인자를 수정하세요." >&2
    return 1
  fi

  # Project 보드 상태 전환: Backlog / Ready → In progress.
  claude-set-issue-status "$issue_number" "In progress"

  # 이슈 컨텍스트 스냅샷 — 세션 시작 시점의 body/labels/milestone을 출력.
  gh issue view "$issue_number" --json number,title,body,labels,milestone
}

# ────────────────────────────────────────────────────────────────────
# 보조 — 이슈 worktree 정리
# 사용법: claude-cleanup-worktree <issue-number|pr-number>
# 실행 위치: main worktree (자기 자신 내부에서는 제거 불가).
#
# claude-close-issue가 PR을 생성하면 해당 worktree의 코드 작업은 끝났지만
# Claude 세션은 여전히 worktree 안에서 실행 중이므로, 세션 종료 후 main에서
# 이 명령을 실행해 디스크를 정리한다.
#
# 인자 디스패치 (#115): 이슈 번호와 PR 번호 둘 다 받는다. 이슈 → PR 순서로
# 시도해 기존 호출자(이슈 번호 직접 입력)의 행동을 보존한다. PR 인자가 들어오면
# headRefName 의 issue-<N> 패턴에서 이슈 번호를 역추출해 같은 worktree 경로로
# 진행한다 — 리뷰/머지 직후 "이 PR 의 worktree 정리해야지" 흐름에서 사용자가
# PR→이슈 번호로 수동 역변환하지 않게 한다.
#
# 정리 위임 (#144): 실제 worktree 제거 + main ff-only 동기화 + 브랜치 삭제는
# `shgwt teardown` 으로 위임한다. PR 머지 명령에서 `--delete-branch` 를 뺀
# 이유(#121 worktree 충돌 방지)에 맞춰, 브랜치 삭제 책임이 본 함수로 옮겨왔다.
# `shgwt teardown` 은 미커밋·미푸시 양쪽을 한 번에 검사하므로 사용자가 모르고
# 작업을 날릴 위험은 그대로 차단된다 (`--force` 미사용 정책 유지).
# ────────────────────────────────────────────────────────────────────
claude-cleanup-worktree() {
  local arg="${1:-}"

  if [[ -z "$arg" ]]; then
    echo "❌ 사용법: claude-cleanup-worktree <issue-number|pr-number>" >&2
    return 1
  fi

  # 가드: main 브랜치에서만 허용. worktree가 자기 자신을 제거할 수 없으므로
  # 실수로 worktree 내부에서 호출하는 케이스를 차단한다.
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [[ "$branch" != "main" ]]; then
    echo "❌ claude-cleanup-worktree는 main 브랜치에서 실행하세요 (현재: ${branch})." >&2
    echo "   worktree 내부에서는 자기 자신을 제거할 수 없습니다." >&2
    return 1
  fi

  # PR → 이슈 순서로 디스패치. `gh issue view <PR#>` 도 GitHub CLI 에서 성공 응답을
  # 반환하므로(이슈/PR 공유 number 공간) 이슈를 먼저 확인하면 PR 인자가 그대로
  # issue_number 로 들어가 worktree 경로(.claude/worktrees/issue-<N>) 가 빗나간다.
  # PR 분기를 먼저 시도해 headRefName 에서 진짜 이슈 번호를 역추출한다 (PR #178 review).
  local issue_number
  local ref
  if ref=$(gh pr view "$arg" --json headRefName -q .headRefName 2>/dev/null); then
    if [[ "$ref" =~ ^issue-([0-9]+)(-|$) ]]; then
      issue_number="${BASH_REMATCH[1]}"
      echo "ℹ️  PR #${arg} → issue #${issue_number} (브랜치: ${ref})"
    else
      echo "❌ PR #${arg} 의 브랜치(${ref})가 issue-<N> 형식이 아닙니다." >&2
      echo "   worktree 경로를 자동 추론할 수 없습니다 — git worktree list 로 직접 확인하세요." >&2
      return 1
    fi
  elif gh issue view "$arg" --json number >/dev/null 2>&1; then
    issue_number="$arg"
  else
    echo "❌ #${arg} 는 이슈도 PR도 아닙니다." >&2
    return 1
  fi

  local worktree_path=".claude/worktrees/issue-${issue_number}"
  if [[ ! -e "$worktree_path" ]]; then
    echo "ℹ️  ${worktree_path} 가 이미 없습니다 — 정리 불필요."
    return 0
  fi

  # shgwt teardown 위임 — worktree 제거 + main ff-only 동기화 + 브랜치 삭제까지
  # 한 트랜잭션으로 처리. shgwt 는 워크트리 내부에서 자기 자신을 정리하는 형태로
  # 호출해야 하므로 서브셸 cd 후 실행한다 (호출자 PWD 보존).
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  if ! ( cd "$worktree_path" && bash "${script_dir}/shgwt.sh" teardown ); then
    echo "❌ shgwt teardown 실패: ${worktree_path}" >&2
    echo "   확인:    cd ${worktree_path} && git status" >&2
    echo "   강제정리: cd ${worktree_path} && bash \"${script_dir}/shgwt.sh\" teardown --force" >&2
    return 1
  fi

  echo "✅ worktree 정리 완료: ${worktree_path}"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 로컬 CI 게이트 (pluggable)
# 사용법: _claude-run-ci-gate [base_ref] [--with-ui|--with-visual]
#
# PR push 직전 claude-close-issue / claude-ref-issue 흐름이 호출한다. 프로젝트마다
# 빌드·테스트 스택이 다르므로, 실제 검사 명령은 사용자가 끼우는 훅으로 위임한다.
#
# 훅 해석 순서 (먼저 발견되는 것 사용):
#   1) 환경변수 CLAUDE_LOCAL_CI_CMD — bash 로 평가될 명령 문자열
#   2) <repo>/.github-workflow/local-ci.sh — 있으면 bash 로 실행 (실행권한 불요)
#   3) 둘 다 없음 → no-op (정보성 통과). 로컬 게이트 없이 원격 CI 에 위임한다.
#
# 훅에 전달되는 환경 (모두 export):
#   GW_CI_BASE_REF — 비교 기준 ref (기본 main)
#   GW_CI_CHANGED  — 변경 파일 목록(개행 구분, origin/base..HEAD + staged + unstaged).
#                    훅이 이 목록으로 path-filter 해 필요한 잡만 돌리면 된다.
#   GW_CI_WITH_UI  — --with-ui/--with-visual 전달 시 1, 아니면 0.
# 훅이 비-0 종료하면 게이트 실패(return 1)로 push 를 막는다. 예시: docs/configuration.md.
# ────────────────────────────────────────────────────────────────────
_claude-run-ci-gate() {
  local base_ref="main" with_ui=0
  while (( $# > 0 )); do
    case "$1" in
      --with-ui|--with-visual) with_ui=1 ;;
      --) shift; break ;;
      -*) echo "❌ _claude-run-ci-gate: 알 수 없는 옵션 '$1'" >&2; return 2 ;;
      *)  base_ref="$1" ;;
    esac
    shift
  done

  # 변경 파일 수집: origin/base_ref 대비 committed + staged + unstaged 전체.
  local changed_files
  changed_files=$(
    {
      git diff --name-only "origin/${base_ref}" HEAD 2>/dev/null
      git diff --name-only HEAD 2>/dev/null
      git diff --name-only --cached 2>/dev/null
    } | sort -u | grep -v '^$' || true
  )

  # 훅 해석.
  local repo_root hook=""
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
  if [[ -n "${CLAUDE_LOCAL_CI_CMD:-}" ]]; then
    hook="cmd"
  elif [[ -f "${repo_root}/.github-workflow/local-ci.sh" ]]; then
    hook="file"
  fi

  if [[ -z "$hook" ]]; then
    echo "ℹ️  로컬 CI 게이트: 훅 미설정 — 건너뜀 (원격 CI 에 위임)."
    echo "    push 전 빌드/테스트를 돌리려면 CLAUDE_LOCAL_CI_CMD 또는"
    echo "    .github-workflow/local-ci.sh 를 추가하세요 (docs/configuration.md §로컬 CI 훅)."
    return 0
  fi

  echo "🔍 로컬 CI 게이트: 변경 범위 분석 (base: origin/${base_ref}, 훅: ${hook})..."
  export GW_CI_BASE_REF="$base_ref"
  export GW_CI_CHANGED="$changed_files"
  export GW_CI_WITH_UI="$with_ui"

  local rc=0
  if [[ "$hook" == "cmd" ]]; then
    bash -c "$CLAUDE_LOCAL_CI_CMD" || rc=$?
  else
    bash "${repo_root}/.github-workflow/local-ci.sh" || rc=$?
  fi

  if (( rc != 0 )); then
    echo "❌ 로컬 CI 게이트 실패 (exit ${rc})" >&2
    return 1
  fi
  echo "✅ 로컬 CI 게이트 통과"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — Conventional Commits type 이 test 계열인지 판정 (#546 AC2)
# 사용법: _claude-is-test-type <type>
#
# `claude-close-issue` 의 첫 인자(type)가 test, test(unit), test(integration),
# test(e2e), test(a11y), test(visual), test(perf) 등 scope 유무 무관하게
# `test` 로 시작하는 conventional-commits type 인지 검사한다.
#
# 반환: 0=test 타입, 1=비-test.
# ────────────────────────────────────────────────────────────────────
_claude-is-test-type() {
  local t="${1:-}"
  [[ "$t" =~ ^test(\([a-zA-Z0-9_-]+\))?$ ]]
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 마일스톤이 UI 게이트 skip 대상인지 판정 (#546 AC3)
# 사용법: _claude-milestone-skip-ui-gate <milestone-title>
#
# 기본 skip 목록: M0a, M1, M3, M4 (백엔드/배포 중심으로 UI 작업이 없는 마일스톤).
# `CLAUDE_UI_GATE_SKIP_MILESTONES` 환경변수(공백 구분)로 재정의 가능.
#
# 매칭 규칙: 정확 일치 또는 마일스톤 타이틀이 `<key>` 다음 비-영숫자 문자(공백,
# em-dash 등)가 오는 prefix 일치. 예) "M0a — Scaffold" 는 `M0a` 로 매치되지만
# "M0aPlus — ..." 는 매치되지 않는다.
#
# 빈 마일스톤 → 1(apply, 안전한 기본값). 마일스톤 정보가 없으면 게이트를 건다.
#
# 반환: 0=skip(해당 없음), 1=apply(게이트 검사).
# ────────────────────────────────────────────────────────────────────
_claude-milestone-skip-ui-gate() {
  local title="${1:-}"
  [[ -z "$title" ]] && return 1

  local skip_list="${CLAUDE_UI_GATE_SKIP_MILESTONES:-M0a M1 M3 M4}"
  local ms
  for ms in $skip_list; do
    if [[ "$title" == "$ms" ]] || [[ "$title" =~ ^${ms}[^A-Za-z0-9] ]]; then
      return 0
    fi
  done
  return 1
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 원격 CI run 상태 검증 (#546 AC1)
# 사용법: _claude-check-remote-ci-status <branch> <sha> <wait_seconds> [skip_ui]
#
# `gh run list --branch <branch> --commit <sha>` 로 해당 commit 의 모든 워크플로우
# run 을 조회한다. wait_seconds 동안 polling 하며 모든 run 의 status==completed +
# conclusion in {success, skipped} 를 기다린다.
#
# `skip_ui=1` 이면 워크플로우 이름에 `ui|playwright|lighthouse|storybook`
# (대소문자 무시) 가 포함된 run 은 평가에서 제외한다 — UI 작업 없는 마일스톤용
# (#546 AC3). 현재 CI 에는 UI 워크플로우가 없으므로 보통 no-op 이지만, M2 도입
# 시점에 자동으로 활성화된다.
#
# 반환:
#   0 — 모든 (필터 적용 후) run 이 완료되었고 실패 없음. 또는 run 자체가 0건
#       (CI 트리거 누락 — fail-open).
#   1 — 1건 이상 실패 (success/skipped 외 conclusion).
#   2 — wait_seconds 내 미완료 run 이 남아있음 (실패는 없으나 미정).
#
# gh 호출 자체가 실패하면 fail-open(0). 네트워크 장애로 정상 흐름을 막지
# 않는다 — AC 가드/보류 라벨 가드와 동일 정책.
# ────────────────────────────────────────────────────────────────────
_claude-check-remote-ci-status() {
  local branch="${1:-}"
  local sha="${2:-}"
  local wait_seconds="${3:-0}"
  local skip_ui="${4:-0}"

  if [[ -z "$branch" || -z "$sha" ]]; then
    echo "⚠️  _claude-check-remote-ci-status: branch/sha 누락 — fail-open" >&2
    return 0
  fi

  local poll_interval="${CLAUDE_CI_POLL_INTERVAL:-15}"
  local elapsed=0
  local runs_json filter_jq
  if [[ "$skip_ui" == "1" ]]; then
    filter_jq='[.[] | select(((.name // "") | test("ui|playwright|lighthouse|storybook"; "i")) | not)]'
  else
    filter_jq='.'
  fi

  while :; do
    if ! runs_json=$(gh run list --branch "$branch" --commit "$sha" --limit 20 \
        --json status,conclusion,name,databaseId,url 2>/dev/null); then
      echo "⚠️  gh run list 실패 — 원격 CI 게이트 fail-open" >&2
      return 0
    fi

    if ! runs_json=$(printf '%s' "$runs_json" | jq "$filter_jq" 2>/dev/null); then
      echo "⚠️  jq 필터 실패 — 원격 CI 게이트 fail-open" >&2
      return 0
    fi

    local total
    total=$(printf '%s' "$runs_json" | jq 'length' 2>/dev/null) || total=0

    if [[ "$total" == "0" ]]; then
      if (( elapsed >= wait_seconds )); then
        echo "ℹ️  commit ${sha:0:7} 에 대한 원격 CI run 없음 — 게이트 skip (fail-open)" >&2
        return 0
      fi
      sleep "$poll_interval"; elapsed=$((elapsed + poll_interval)); continue
    fi

    local failed
    failed=$(printf '%s' "$runs_json" \
      | jq '[.[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped")] | length' 2>/dev/null) || failed=0

    if (( failed > 0 )); then
      echo "❌ 원격 CI 실패 (${failed}건):" >&2
      printf '%s' "$runs_json" \
        | jq -r '.[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped") | "   ❌ \(.name) — \(.conclusion) → \(.url)"' >&2
      return 1
    fi

    local incomplete
    incomplete=$(printf '%s' "$runs_json" \
      | jq '[.[] | select(.status != "completed")] | length' 2>/dev/null) || incomplete=0

    if (( incomplete > 0 )); then
      if (( elapsed >= wait_seconds )); then
        echo "⏳ 원격 CI 진행 중 (${incomplete}/${total}건 미완료) — 대기 시간(${wait_seconds}s) 초과" >&2
        return 2
      fi
      printf '⏳ 원격 CI 대기 중 — %d/%d 미완료 (%ds/%ds)\n' \
        "$incomplete" "$total" "$elapsed" "$wait_seconds" >&2
      sleep "$poll_interval"; elapsed=$((elapsed + poll_interval)); continue
    fi

    echo "✅ 원격 CI 전체 통과 (${total}건)" >&2
    return 0
  done
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — push 직전 로컬 lint 가드 (#120)
# 사용법: _claude-lint-guard
#
# CI 실패가 PR 리뷰 단계에서 드러나는 노이즈(#113)를 막기 위해 push 전에 같은
# 검사를 로컬에서 먼저 돌린다. 옵션은 .github/workflows/ 와 정확히 동일하게
# 맞춘다 — CI와 어긋나면 "로컬은 통과했는데 CI는 떨어지는" 더 큰 혼란이 생긴다.
#
# 정책:
#   - shellcheck: 필수. 미설치면 즉시 실패하고 설치 안내. CI와 동일하게 -x -S warning.
#   - actionlint: 선택. 미설치면 warning만 찍고 통과. CI는 라벨로만 트리거되어
#     설치 강제까지 갈 가치는 없다.
# ────────────────────────────────────────────────────────────────────
_claude-lint-guard() {
  # 셸 스크립트가 추적되는 레포에서만 shellcheck, 워크플로우가 있으면 actionlint.
  # 둘 다 best-effort: 대상 부재 시 조용히 스킵, 도구 미설치 시 경고 후 스킵.
  # 강제 lint 가 필요하면 로컬 CI 훅(CLAUDE_LOCAL_CI_CMD)에서 직접 돌리세요.
  local -a sh_files=()
  mapfile -t sh_files < <(git ls-files '*.sh' '*.bash' 2>/dev/null || true)

  if (( ${#sh_files[@]} > 0 )); then
    if command -v shellcheck >/dev/null 2>&1; then
      echo "🔍 shellcheck 실행 중 (-x -S warning, ${#sh_files[@]} files)..."
      if ! shellcheck -x -S warning "${sh_files[@]}"; then
        echo "❌ shellcheck 위반. push/PR 생성을 중단합니다." >&2
        return 1
      fi
      echo "✅ shellcheck 통과"
    else
      echo "⚠️  shellcheck 미설치 — 셸 스크립트 lint 스킵 (apt/brew install shellcheck)"
    fi
  fi

  if command -v actionlint >/dev/null 2>&1; then
    echo "🔍 actionlint 실행 중..."
    if ! actionlint; then
      echo "❌ actionlint 위반. push/PR 생성을 중단합니다." >&2
      return 1
    fi
    echo "✅ actionlint 통과"
  fi
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 브랜치 커밋 메시지의 #N 일치 감사 (#184)
# 사용법: claude-audit-commit-issue-refs <session-issue-number>
#
# `git log origin/main..HEAD --pretty=%B`로 브랜치의 모든 커밋 메시지를 모아
# `#(\d+)` 패턴을 추출하고, 세션 이슈 번호와 다른 N이 발견되면 stderr로
# soft warning만 출력한다. return은 항상 0 — 진행을 막지 않는다.
#
# 의도(#184):
#   브랜치 이름은 issue-<N>-... 인데 커밋 메시지에 다른 이슈 번호가 섞이면
#   PR 머지 시 `Closes #N` 키워드가 의도치 않은 이슈를 close하거나 보드 상태가
#   엇갈릴 위험이 있다 (#133 사례 — 한 브랜치에 #34/#127/#31/#29 커밋 혼재).
#   이 함수는 push 직전에 그 상황을 사용자에게 표시한다.
#
# soft warn 정책 이유:
#   "Refs #34", "see #29", blog draft 인용 등 의도된 cross-reference도 있어
#   hard fail은 false positive가 많다. `Closes/Fixes/Resolves` 키워드만
#   검사하는 안도 있었지만, #133 사례의 `feat: #127 ...` 같은 type 접두사
#   메시지를 놓친다. 단순 `#(\d+)` 추출 + 경고-only가 양쪽을 균형 잡는다.
# ────────────────────────────────────────────────────────────────────
claude-audit-commit-issue-refs() {
  # set -u 환경(테스트 러너)에서도 인자 누락 시 unbound 에러 없이 통과하도록 기본값 처리.
  local session_issue="${1:-}"
  [[ -z "$session_issue" ]] && return 0

  local messages refs other_refs
  # git log 실패(예: origin/main 미존재, git 자체 오류)는 감사 불가로 보고 조용히 통과.
  messages=$(git log origin/main..HEAD --pretty=%B 2>/dev/null) || return 0

  # `grep -oP '#\K\d+'` — '#' 다음 숫자만 추출 (\K는 매치 시작 리셋).
  # `sort -un` — 숫자 정렬 + 중복 제거. 매치 0건이면 grep이 1을 반환하므로 || true.
  refs=$(printf '%s' "$messages" | grep -oP '#\K\d+' | sort -un || true)

  # 세션 이슈 자신은 제거. grep -v 매치 0건일 때도 1을 반환하므로 || true.
  # printf '%s\n' ""는 빈 줄 1개를 만들어 grep -v를 통과할 수 있으므로 추가 필터링.
  other_refs=$(printf '%s\n' "$refs" \
    | grep -v "^${session_issue}\$" \
    | grep -v '^$' || true)

  if [[ -n "$other_refs" ]]; then
    echo "⚠️  세션 이슈 #${session_issue} 외 다른 이슈 번호가 커밋 메시지에 있습니다:" >&2
    while IFS= read -r ref; do
      [[ -n "$ref" ]] && echo "   #${ref}" >&2
    done <<<"$other_refs"
    echo "   의도된 cross-reference(Refs #N, see #N 등)라면 그대로 두세요." >&2
    echo "   실수라면 git rebase -i로 메시지를 수정한 뒤 재실행하세요." >&2
  fi

  return 0
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — close 시점 이슈 status fallback 보정 (#1289)
# 사용법: _claude-reconcile-issue-status-on-close <issue-number>
#
# claude-close-issue 가 PR 생성 + PR 카드 In review 전환을 끝낸 직후 호출된다.
# close-issue 가 도중 fail 했다가 수동 재완료되거나, main 에서 직접
# `git checkout -b issue-<N>` 으로 우회 진입해 claude-start-issue 를 건너뛴 경우,
# 이슈가 Backlog/Ready 에 머문 채 PR 만 In review 로 생성되는 정책 위반이 만들어진다
# (정책 SSOT L21: Issue 는 In progress 여야 하고, PR 이 In review 인 동안 이슈는
# In progress 다). 이 헬퍼가 그 어긋남을 PR 생성 시점에 자동 정렬한다.
#
# 보정 규칙 (forward-only 준수):
#   - 현재 보드 status 가 Backlog / Ready → In progress 로 보정 + verify.
#   - In progress / In review / Approved / Done → 그대로 둠 (회귀 금지).
#   - 보드 카드 미등록(빈 문자열) → 보정 대상 아님 (skip).
# 정상 흐름(claude-start-issue 가 이미 In progress 로 전환)에서는 발화하지 않는다.
#
# best-effort 보정이라 보드 status 조회 실패는 이미 성공한 PR 생성을 깨지 않고
# soft skip(return 0) 한다 — 호출자(claude-close-issue)는 반환값으로 분기하지 않는다.
# ────────────────────────────────────────────────────────────────────
_claude-reconcile-issue-status-on-close() {
  local issue_number="$1"

  local board_status
  if ! board_status=$(_claude-current-board-status "$issue_number" issues); then
    echo "⚠️  이슈 #${issue_number} 보드 status 조회 실패 — In progress 보정 skip (#1289)." >&2
    return 0
  fi

  case "$board_status" in
    Backlog | Ready)
      echo "ℹ️  이슈 #${issue_number} ${board_status} → In progress 보정 (PR 생성 시점 자동 정렬)"
      claude-set-issue-status "$issue_number" "In progress" &&
        claude-verify-issue-status "$issue_number" "In progress"
      ;;
  esac

  # best-effort 보정이므로 set/verify 실패해도 호출자(claude-close-issue)로 비영 종료를
  # 전파하지 않는다 — set -e 환경 안전. 실패는 set/verify 가 stderr 로 이미 보고. (PR #1484 review)
  return 0
}

# ────────────────────────────────────────────────────────────────────
# 순수 매핑 — conventional commit subject(stdin, 한 줄당 1개)를 후보 라벨로 변환 (#1486)
# 출력: dedup 된 후보 라벨 (한 줄당 1개, 첫 등장 순서 보존). 네트워크/git 비의존이라
#       test-github-workflow.sh 가 단위 검증한다 — claude-apply-pr-labels 의 매핑 SSOT.
# 비-conventional subject 와 매핑 없는 타입은 조용히 건너뛴다.
# ────────────────────────────────────────────────────────────────────
_claude-commit-types-to-labels() {
  local subject type label seen=""
  # `type` 또는 `type(scope)` (+ 선택적 breaking `!`) 뒤 `:` 만 conventional 로 인식.
  # regex 는 변수로 분리 — `[^)]` 의 `)` 를 [[ ]] 안에 직접 쓰면 bash 파서가
  # 조건식 닫는 토큰으로 오인해 syntax error 를 낸다.
  local re='^[[:space:]]*([a-zA-Z]+)(\([^)]*\))?!?:'
  # 대소문자 정규화는 스트림 단위 1회 — subject 마다 printf|tr 서브셸을 스폰하지
  # 않는다 (PR #1487 리뷰). 라벨은 case 분기 산출이라 입력 전체 소문자화는 무해하다.
  tr '[:upper:]' '[:lower:]' | while IFS= read -r subject; do
    if [[ "$subject" =~ $re ]]; then
      type="${BASH_REMATCH[1]}"
    else
      continue
    fi
    case "$type" in
      feat)     label="enhancement" ;;
      fix)      label="bug" ;;
      docs)     label="documentation" ;;
      refactor) label="refactor" ;;
      style)    label="style" ;;
      perf)     label="performance" ;;
      test)     label="test" ;;
      chore)    label="chore" ;;
      ci)       label="ci" ;;
      build)    label="build" ;;
      *)        continue ;;
    esac
    # dedup — 구분자로 감싼 누적 문자열에서 이미 출력한 라벨이면 건너뛴다.
    case "$seen" in
      *"|${label}|"*) continue ;;
    esac
    seen="${seen}|${label}|"
    printf '%s\n' "$label"
  done
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — PR 라벨 부착 (type + severity 통합 SSOT, #1486)
# 사용법: claude-apply-pr-labels <base-ref> <pr-number>
#
# gh-pr·close-issue·ref-issue 가 공유하는 PR emit 후처리. 세 가지를 한다:
#   1) base..HEAD conventional commit 타입 → 후보 라벨 (_claude-commit-types-to-labels).
#   2) severity 전파(#173, #1266 갭 복구): 범위 커밋 + PR 본문의 Closes/Fixes/Resolves
#      #N 추출 → claude-issue-severity 로 최고 severity 1개 → 후보에 추가.
#      제거된 PostToolUse 훅 post-pr-create-severity.sh 의 살아있는 후신 — 같은 로직.
#   3) safe-apply: repo 에 이미 존재하는 라벨만 부착. 신규 라벨 생성 금지 (없으면 silent skip).
#
# judgment scope 라벨(skill 등)은 함수가 정하지 못한다 — 호출 LLM 이 별도
# `gh pr edit --add-label` 한 줄로 추가한다.
#
# 항상 best-effort(return 0): 라벨 부착 실패는 PR 생성 성공을 파괴하지 않는다.
# range 결정: origin/<base> 가 있으면 그것을 우선(close-issue rebase·gh-pr fetch 직후
# 정확), 없으면 로컬 <base> ref 로 폴백.
# ────────────────────────────────────────────────────────────────────
claude-apply-pr-labels() {
  local base_ref="${1:-}"
  local pr_number="${2:-}"
  if [[ -z "$base_ref" || -z "$pr_number" ]]; then
    echo "❌ 사용법: claude-apply-pr-labels <base-ref> <pr-number>" >&2
    return 1
  fi

  local range_base="$base_ref"
  if git rev-parse --verify --quiet "origin/${base_ref}" >/dev/null 2>&1; then
    range_base="origin/${base_ref}"
  fi

  # 1) type 라벨 후보.
  local candidates
  candidates=$(git log --format=%s "${range_base}..HEAD" 2>/dev/null | _claude-commit-types-to-labels)

  # 2) severity 전파 — 범위 커밋 + PR 본문에서 closing keyword #N 추출.
  #    cross-repo `owner/repo#N` 은 `(?<![\w/])` 가드로 제외 (zombie 훅과 동일 regex).
  local closing_src pr_body closing_issues sev
  closing_src=$(git log --format=%B "${range_base}..HEAD" 2>/dev/null)
  if pr_body=$(_claude-gh-retry gh pr view "$pr_number" --json body --jq '.body // ""'); then
    closing_src="${closing_src}"$'\n'"${pr_body}"
  fi
  closing_issues=$(printf '%s' "$closing_src" \
    | grep -oiP '(?<![\w/])(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?)\s+#\K[0-9]+' 2>/dev/null \
    | sort -u)
  if [[ -n "$closing_issues" ]]; then
    local -a closing_arr=()
    local _n
    while IFS= read -r _n; do
      [[ -n "$_n" ]] && closing_arr+=("$_n")
    done <<<"$closing_issues"
    if (( ${#closing_arr[@]} > 0 )); then
      sev=$(claude-issue-severity "${closing_arr[@]}" 2>/dev/null)
      [[ -n "$sev" ]] && candidates="${candidates}"$'\n'"${sev}"
    fi
  fi

  candidates=$(printf '%s\n' "$candidates" | grep -v '^[[:space:]]*$' | sort -u)
  if [[ -z "$candidates" ]]; then
    echo "ℹ️  PR #${pr_number}: 부착할 라벨 후보 없음."
    return 0
  fi

  # 3) safe-apply — repo 에 존재하는 라벨만. 조회 실패는 soft skip.
  local existing
  if ! existing=$(_claude-gh-retry gh label list --limit 200 --json name --jq '.[].name'); then
    echo "⚠️  라벨 목록 조회 실패 — 라벨 부착 스킵 (PR 은 정상)." >&2
    return 0
  fi

  local -a to_add=()
  local label
  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    if printf '%s\n' "$existing" | grep -Fxq "$label"; then
      to_add+=("$label")
    fi
  done <<<"$candidates"

  if (( ${#to_add[@]} == 0 )); then
    echo "ℹ️  PR #${pr_number}: 존재하는 매칭 라벨 없음."
    return 0
  fi

  # gh pr edit --add-label 은 콤마 구분을 허용 — 단일 호출로 부착.
  local joined
  joined=$(IFS=,; printf '%s' "${to_add[*]}")
  if _claude-gh-retry gh pr edit "$pr_number" --add-label "$joined" >/dev/null; then
    echo "🏷️  PR #${pr_number}: 라벨 부착 — ${joined}"
  else
    echo "⚠️  PR #${pr_number}: 라벨 부착 실패 (비치명)." >&2
  fi
  return 0
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — PR 생성 (본문 파일 기반 SSOT, #1486)
# 사용법: claude-pr-create-from-body <base> <title> <body-file> [--assign-self]
# 출력: 생성된 PR URL (stdout 한 줄). gh-pr·close-issue·ref-issue 공유 create 경로.
#
# `--draft`/`--reviewer` 미설정. `--assign-self` 시 `--assignee @me` 부착.
# gh pr create 는 _claude-gh-retry 로 감싸지 않는다 — 재시도가 중복 PR 을 만들
# 위험이 있어 create 는 단발 호출이 안전하다 (기존 close-issue 정책과 동일).
# ────────────────────────────────────────────────────────────────────
claude-pr-create-from-body() {
  local base="${1:-}"
  local title="${2:-}"
  local body_file="${3:-}"
  local assign_flag="${4:-}"

  if [[ -z "$base" || -z "$title" || -z "$body_file" ]]; then
    echo "❌ 사용법: claude-pr-create-from-body <base> <title> <body-file> [--assign-self]" >&2
    return 1
  fi
  if [[ ! -f "$body_file" ]]; then
    echo "❌ body-file 을 찾을 수 없습니다: ${body_file}" >&2
    return 1
  fi

  local -a create_args=(--base "$base" --title "$title" --body-file "$body_file")
  if [[ "$assign_flag" == "--assign-self" ]]; then
    create_args+=(--assignee @me)
  elif [[ -n "$assign_flag" ]]; then
    echo "❌ 알 수 없는 옵션: ${assign_flag} (지원: --assign-self)" >&2
    return 1
  fi

  gh pr create "${create_args[@]}"
}

# ────────────────────────────────────────────────────────────────────
# 내부 헬퍼 — gh-pr 전용 push (#1486)
# 원격 동일명 브랜치 존재/관계에 따라 분기:
#   - 원격 브랜치 없음            → git push -u origin HEAD            (return 0)
#   - 존재 + 로컬이 ahead         → git push origin HEAD              (return 0)
#   - 존재 + up-to-date/behind만  → no-op                            (return 0)
#   - 존재 + diverged             → return 3 (호출 LLM 이 force-push 승인 요청으로 중단)
#   - 비교/push 실패              → return 1
#
# upstream(@{u}) 대신 origin/<branch> 존재 여부로 판정한다 — claude-enter-issue 가
# worktree 브랜치 upstream 을 origin/main 으로 세팅하는 케이스 때문에 bare `git push`
# 는 main 으로 push 할 수 있다. ahead 케이스도 `git push origin HEAD` 로 동일명 원격
# 브랜치에만 push 한다 (Step 6 force-push 금지 원칙 보존).
#
# close-issue 의 push(`git push -u`)는 "항상 새 브랜치" 전제 + push↔create 사이 #546
# 게이트가 끼어 있어 통합하지 않는다 — 별도 유지.
# ────────────────────────────────────────────────────────────────────
_claude-push-pr-branch() {
  local branch
  if ! branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    echo "❌ 현재 브랜치 확인 실패 (detached HEAD?)." >&2
    return 1
  fi

  git fetch origin >/dev/null 2>&1

  if ! git rev-parse --verify --quiet "refs/remotes/origin/${branch}" >/dev/null 2>&1; then
    git push -u origin HEAD || return 1
    return 0
  fi

  local counts behind ahead
  if ! counts=$(git rev-list --left-right --count "origin/${branch}...HEAD" 2>/dev/null); then
    echo "❌ origin/${branch} 와 비교 실패." >&2
    return 1
  fi
  # 내장 read 로 분리 — 두 숫자를 쪼개는 데 awk 2회 스폰을 피한다 (PR #1487 리뷰).
  read -r behind ahead <<<"$counts"

  if (( behind > 0 && ahead > 0 )); then
    echo "⚠️  로컬과 origin/${branch} 이 diverged (ahead ${ahead}, behind ${behind}) — force-push 필요." >&2
    echo "   사용자 승인 없이 force-push 하지 않습니다." >&2
    return 3
  fi
  if (( ahead > 0 )); then
    git push origin HEAD || return 1
    return 0
  fi
  echo "ℹ️  origin/${branch} 과 동기화됨 — push 할 신규 커밋 없음."
  return 0
}

# ────────────────────────────────────────────────────────────────────
# 4단계 — 테스트 → 커밋 → base sync → 로컬 lint → 커밋 메시지 감사 → PR + PR 카드를 "In review"로 이동
# 사용법: claude-close-issue [--force] <issue-number> <type> <description> [parent-pr]
# type: Conventional Commits 타입 (feat, fix, docs, style, refactor, test, chore, perf, ci, build)
#
# `--force` (#440): AC 미체크 가드를 우회한다. 위치 무관 (어느 인자 사이에든
#   넣어도 동일). 가드가 차단된 상황에서도 의도적으로 PR을 만들어야 할 때만
#   사용. 일반 흐름에서는 모든 AC 가 체크된 후 호출하도록 운영한다.
#
# 4번째 인자 [parent-pr] (#186 — stacked PR 지원):
#   없음        → base=main 동작 (기존). origin/main rebase + PR base=main.
#   PR 번호 지정 → 부모 PR 위에 자식 PR을 올리는 stacked 모드.
#                 부모는 OPEN 상태여야 하며 (`gh pr view`로 검증), 부모의
#                 headRefName을 자식의 rebase 대상 + PR --base로 사용한다.
#                 PR 본문에 `Depends on #<parent-pr>` 줄이 자동 추가된다.
#
# 보드 상태 전환 정책 (#34):
#   - Issue는 In progress에 머무른다. PR 머지 시 "Closes #N"으로 이슈가 close되면
#     GitHub이 In progress → Done으로 자동 전환한다.
#   - PR 카드만 In review로 전환된다. 이후 Approved → Done 트랙은 PR 카드가 담당.
#
# 빌트인 워크플로우 회귀 감사 (#12, #252):
#   "Pull request linked to issue" 빌트인 워크플로우는 PR 카드 Status 변경을
#   trigger 로 이슈 카드까지 함께 옮긴다 — Issue/PR 트랙 분리만으로는 경합이
#   사라지지 않는다. push 직후 claude-audit-builtin-workflows 로 활성 여부를
#   확인해 회귀 시 stderr 경고를 띄운다 (작업 흐름은 차단하지 않음).
#
# PR 생성 전 base sync 정책:
#   PR을 만들기 전 브랜치를 base ref(main 또는 부모 head)에 rebase한다. 이유는
#   머지 시 예상치 못한 충돌을 PR 리뷰 단계가 아닌 로컬에서 먼저 드러내기
#   위해서다. rebase 충돌이 발생하면 push/PR 생성을 중단하고 사용자가 수동으로
#   해결하도록 abort한다.
#
# PR 생성 전 로컬 lint 정책 (#120):
#   rebase 통과 직후, push 직전에 _claude-lint-guard로 shellcheck(필수)·actionlint
#   (선택)를 돌린다. CI가 떨어질 변경을 PR 단계에서 드러내면 리뷰어 시간을 낭비하므로,
#   같은 검사를 push 전에 미리 돌려 차단한다. 위반 시 push·PR 생성 모두 진입 금지.
#
# 원격 CI 하드 게이트 (#546):
#   push 직후, gh pr create 직전에 _claude-check-remote-ci-status 로 commit 의
#   원격 워크플로우 run 상태를 검증한다. 어떤 run 이라도 success/skipped 외
#   conclusion 으로 끝나면 PR 생성을 중단한다. test 타입(test, test(unit) 등)은
#   미완료 run 이 모두 끝날 때까지 CLAUDE_CI_WAIT_TIMEOUT (default 900s) 까지
#   대기. 비-test 타입은 CLAUDE_CI_PRECHECK_WINDOW (default 30s) 만 대기 후
#   미완료여도 진행. UI 작업 없는 마일스톤(M0a/M1/M3/M4 default — env
#   CLAUDE_UI_GATE_SKIP_MILESTONES 로 재정의) 은 ui|playwright|lighthouse|
#   storybook 워크플로우를 평가에서 제외. `lighthouse` 는 과거 run 호환 필터다. --force 또는
#   CLAUDE_SKIP_REMOTE_CI_CHECK=1 로 우회 가능 (#440 의 --force 와 동일 플래그).
#
# 커밋 메시지 감사 정책 (#184):
#   lint 통과 후 claude-audit-commit-issue-refs로 브랜치의 모든 커밋 메시지에서
#   세션 이슈 외 다른 #N 참조가 섞였는지 확인한다. soft warn — 출력만 하고
#   진행을 막지 않는다. 의도된 cross-reference(Refs/see #N)와 실수를 구분하는
#   판단은 사용자에게 맡긴다.
#
# 부모 머지 후 base 재타게팅:
#   부모 PR이 main에 머지되면 GitHub이 자식 PR의 base를 자동으로 main으로
#   재타게팅한다 (built-in 동작). 작성자가 수동 개입할 필요 없음.
# ────────────────────────────────────────────────────────────────────
claude-close-issue() {
  # `--force` 는 위치 무관 — 모든 인자를 한 번 훑어 분리한다 (#440).
  local force=0
  local -a _ci_args=()
  local _ci_arg
  for _ci_arg in "$@"; do
    if [[ "$_ci_arg" == "--force" ]]; then
      force=1
    else
      _ci_args+=("$_ci_arg")
    fi
  done
  set -- "${_ci_args[@]}"

  if [[ -z "${1:-}" || -z "${2:-}" || -z "${3:-}" ]]; then
    echo "❌ 사용법: claude-close-issue [--force] <issue-number> <type> \"<description>\" [parent-pr]" >&2
    return 1
  fi

  local issue_number="$1"
  local type="$2"
  local description="$3"
  # set -u 환경에서도 안전하도록 옵션 인자에 기본값 처리 (#186).
  local parent_pr="${4:-}"

  # 세션 선점 체크: 바인딩된 이슈와 인자가 다르면 엉뚱한 이슈로 PR이 생성되는 것을 차단.
  # 브랜치가 issue-<N>-... 형식이 아니면(바인딩 없음) 가드를 건너뛴다.
  local bound_issue
  if bound_issue=$(claude-session-bound); then
    if [[ "$bound_issue" != "$issue_number" ]]; then
      echo "⚠️  현재 브랜치는 #${bound_issue}에 바인딩되어 있는데 #${issue_number}로 close 시도 중입니다." >&2
      return 1
    fi
  fi

  # AC 미체크 가드 (#440 — Defense 1).
  # PR 머지가 `Closes #N` 으로 이슈를 자동 close 시키므로, AC 가 모두 체크돼야만
  # close 가 정당하다. body 의 `- [ ]` 패턴 항목 수를 카운트해 1개 이상이면 차단.
  # `--force` 로 우회 가능 (의도적 close 일 때만). gh 호출 실패는 가드 fail-open
  # — 네트워크 잡음으로 정상 흐름을 막지 않는다 (#233 보류 라벨 가드와 동일 정책).
  # GFM 표준 task-list 마커 `-`/`*`/`+` 모두 인식 (PR #444 gemini medium).
  local issue_body unchecked
  if issue_body=$(_claude-gh-retry gh issue view "$issue_number" --json body --jq .body); then
    unchecked=$(printf '%s\n' "$issue_body" | grep -c '^[[:space:]]*[-*+] \[ \]' || true)
    if (( unchecked > 0 )); then
      if (( force == 1 )); then
        echo "⚠️  #${issue_number} AC 미체크 ${unchecked}건 — --force 로 우회 진행." >&2
      else
        echo "❌ #${issue_number} AC 미체크 ${unchecked}건. 모든 AC 충족 후 다시 실행하거나 --force 로 우회하세요." >&2
        printf '%s\n' "$issue_body" | grep '^[[:space:]]*[-*+] \[ \]' >&2
        echo "   중간 작업이라면 claude-close-issue 대신 claude-ref-issue 로 PR 을 만드세요 (Refs only)." >&2
        return 1
      fi
    fi
  else
    echo "⚠️  이슈 #${issue_number} body 조회 실패 — AC 가드 스킵 (fail-open)." >&2
  fi

  # base ref 결정: parent_pr 빈값이면 main, 아니면 부모 PR의 head 브랜치 (#186).
  # 부모 PR이 OPEN 상태가 아니면 stacked 의미가 사라지므로 즉시 fail.
  local base_ref="main"
  if [[ -n "$parent_pr" ]]; then
    if ! [[ "$parent_pr" =~ ^[0-9]+$ ]]; then
      echo "❌ parent-pr은 숫자여야 합니다 (got='${parent_pr}')." >&2
      return 1
    fi
    local parent_meta parent_state parent_head
    if ! parent_meta=$(_claude-gh-retry gh pr view "$parent_pr" --json headRefName,state); then
      echo "❌ 부모 PR #${parent_pr} 조회 실패." >&2
      return 1
    fi
    parent_state=$(printf '%s' "$parent_meta" | jq -r '.state // empty')
    parent_head=$(printf '%s' "$parent_meta" | jq -r '.headRefName // empty')
    if [[ "$parent_state" != "OPEN" ]]; then
      echo "❌ 부모 PR #${parent_pr}이 OPEN 상태가 아닙니다 (state=${parent_state})." >&2
      echo "   stacked PR 작업은 부모가 OPEN인 동안에만 가능합니다." >&2
      return 1
    fi
    if [[ -z "$parent_head" ]]; then
      echo "❌ 부모 PR #${parent_pr}의 headRefName을 가져오지 못했습니다." >&2
      return 1
    fi
    base_ref="$parent_head"
    echo "🪜 stacked 모드: 부모 PR #${parent_pr} (head=${base_ref})"
  fi

  # CI 게이트 (#545, #744): CI와 동등한 체크를 커밋 전에 로컬에서 모두 통과시킨다.
  # 변경 파일 범위(web/worker/prettier/storybook)에 따라 해당 job만 선택 실행.
  # close-issue 는 PR 생성 직전 경로이므로 --with-ui 로 e2e smoke+a11y 까지 검증한다.
  # visual regression 과 Lighthouse 는 PR 필수 게이트에서 제외한다.
  if ! _claude-run-ci-gate "$base_ref" --with-ui; then
    return 1
  fi

  # 커밋 메시지에 "#N"을 넣으면 GitHub이 커밋-이슈를 자동 연결한다.
  git add -A
  git commit -m "${type}: #${issue_number} ${description}" || return 1

  # base sync: 커밋 후, push 전에 base ref(main 또는 부모 head)를 rebase한다.
  # 충돌 시 rebase를 자동으로 abort하고 사용자에게 수동 해결을 안내한다.
  echo "🔄 origin/${base_ref} 동기화 중..."
  if ! git fetch origin "$base_ref"; then
    echo "❌ origin/${base_ref} fetch 실패. 네트워크 상태를 확인하세요." >&2
    return 1
  fi
  if ! git rebase "origin/${base_ref}"; then
    git rebase --abort 2>/dev/null
    echo "❌ origin/${base_ref} 과 rebase 충돌. 수동으로 해결한 뒤 재실행하세요:" >&2
    echo "   git rebase origin/${base_ref}" >&2
    echo "   # 충돌 해결 후 git add / git rebase --continue" >&2
    # description에 공백/특수문자가 섞여도 사용자가 그대로 복사-붙여넣기 가능하도록
    # printf %q로 셸 이스케이프 (bash builtin).
    if [[ -n "$parent_pr" ]]; then
      printf "   # 그 다음 다시 claude-close-issue %q %q %q %q\n" "$issue_number" "$type" "$description" "$parent_pr" >&2
    else
      printf "   # 그 다음 다시 claude-close-issue %q %q %q\n" "$issue_number" "$type" "$description" >&2
    fi
    return 1
  fi

  # 로컬 lint 가드 (#120): rebase 통과 후 push 전 마지막 관문.
  if ! _claude-lint-guard; then
    return 1
  fi

  # 커밋 메시지 감사: 세션 이슈 외 다른 #N 참조가 섞였는지 검사 (#184).
  # soft warn — 출력만 하고 진행을 막지 않는다. PR 본문의 `Closes #N`은
  # claude-close-issue가 직접 채우므로 의도치 않은 close는 발생하지 않지만,
  # 머지 시점에 GitHub이 커밋 메시지의 다른 이슈도 cross-link하므로 사용자가
  # 알아챌 기회를 준다.
  claude-audit-commit-issue-refs "$issue_number"

  # 빌트인 워크플로우 회귀 감사 (#12, #252) — "Pull request linked to issue" 가
  # enabled 면 stderr 경고. PR 생성 직후 이슈 카드가 In review 로 끌려가는
  # 회귀를 작성자/리뷰어가 즉시 인지하도록 push 전에 띄운다 (소프트 가드).
  claude-audit-builtin-workflows

  git push -u origin HEAD

  # ────────────────────────────────────────────────────────────────────
  # 원격 CI 하드 게이트 (#546)
  # ────────────────────────────────────────────────────────────────────
  # AC1 — 이슈 닫기 전 최근 CI run 결과를 확인해 실패 시 PR 생성 중단.
  # AC2 — test 타입(test, test(unit), test(integration) 등)은 CI green 필수
  #        (`CLAUDE_CI_WAIT_TIMEOUT` 까지 대기, default 900s).
  # AC3 — UI 작업 없는 마일스톤(M0a/M1/M3/M4 default)은 UI 워크플로우 필터.
  # AC4 — `--force` 또는 `CLAUDE_SKIP_REMOTE_CI_CHECK=1` 로 우회.
  if (( force == 1 )); then
    if _claude-is-test-type "$type"; then
      echo "⚠️  [#546] test 타입(${type})인데 --force 로 원격 CI 검증을 우회합니다. 머지 전 CI 확인 책임은 작성자에게." >&2
    else
      echo "⚠️  [#546] --force — 원격 CI 검증 스킵." >&2
    fi
  elif [[ "${CLAUDE_SKIP_REMOTE_CI_CHECK:-0}" == "1" ]]; then
    echo "⚠️  [#546] CLAUDE_SKIP_REMOTE_CI_CHECK=1 — 원격 CI 검증 스킵." >&2
  else
    local _ci_branch _ci_sha _ci_wait _ci_skip_ui=0 _ci_milestone="" _ci_rc=0

    _ci_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || _ci_branch=""
    _ci_sha=$(git rev-parse HEAD 2>/dev/null) || _ci_sha=""

    if _claude-is-test-type "$type"; then
      _ci_wait="${CLAUDE_CI_WAIT_TIMEOUT:-900}"
      echo "🔍 [#546] test 타입(${type}) — 원격 CI 완료 대기 (max ${_ci_wait}s)..." >&2
    else
      _ci_wait="${CLAUDE_CI_PRECHECK_WINDOW:-30}"
      echo "🔍 [#546] 원격 CI 사전 확인 (max ${_ci_wait}s)..." >&2
    fi

    if _ci_milestone=$(_claude-gh-retry gh issue view "$issue_number" --json milestone --jq '.milestone.title // ""' 2>/dev/null); then
      if _claude-milestone-skip-ui-gate "$_ci_milestone"; then
        echo "ℹ️  [#546] milestone '${_ci_milestone}' — UI 게이트 skip" >&2
        _ci_skip_ui=1
      fi
    fi

    _claude-check-remote-ci-status "$_ci_branch" "$_ci_sha" "$_ci_wait" "$_ci_skip_ui" \
      || _ci_rc=$?

    if (( _ci_rc == 1 )); then
      echo "❌ #${issue_number} 원격 CI 실패 — PR 생성 중단." >&2
      echo "   재시도: 실패 원인을 수정한 뒤 다시 claude-close-issue 호출." >&2
      printf "   우회: claude-close-issue --force %q %q %q\n" "$issue_number" "$type" "$description" >&2
      return 1
    elif (( _ci_rc == 2 )); then
      if _claude-is-test-type "$type"; then
        echo "❌ #${issue_number} test 타입(${type})인데 CI 미완료(timeout) — PR 생성 중단." >&2
        echo "   대기 시간 늘리기: CLAUDE_CI_WAIT_TIMEOUT=1800 claude-close-issue ..." >&2
        echo "   우회: --force 추가" >&2
        return 1
      fi
      echo "⚠️  [#546] 원격 CI 미완료 — 비-test 타입이라 PR 생성은 진행 (머지 전 CI 확인 권장)" >&2
    fi
  fi

  # PR body 구성: stacked 모드면 `Depends on #<parent>` 줄을 추가 (#186).
  # `Closes #N`은 GitHub 자동 close 키워드 — base가 default branch가 아닐 때는
  # 부모가 main에 머지되어야 발화하지만, 본문에 박아두는 것 자체는 항상 옳다.
  local pr_body="Closes #${issue_number}"
  if [[ -n "$parent_pr" ]]; then
    pr_body+=$'\n\nDepends on #'"${parent_pr}"
  fi

  # 본문을 임시 파일로 넘겨 공유 create wrapper(#1486)에 위임한다 — base(stacked 포함)는
  # wrapper 가 항상 명시 전달하며 self-assign(--assign-self)도 일관 적용한다. URL 한 줄을
  # 캡처해 번호 추출 → PR 카드를 In review 로 전환한다 (#34). gh pr create 는 stdout 에
  # PR URL 한 줄만 찍는다고 가정한다(부수 메시지는 stderr).
  local body_file
  body_file=$(mktemp) || { echo "❌ 임시 파일 생성 실패." >&2; return 1; }
  printf '%s\n' "$pr_body" > "$body_file"

  local pr_url pr_number _create_rc
  pr_url=$(claude-pr-create-from-body "$base_ref" "${type}: #${issue_number} ${description}" "$body_file" --assign-self)
  _create_rc=$?
  rm -f "$body_file"
  if (( _create_rc != 0 )); then
    echo "❌ PR 생성 실패." >&2
    return 1
  fi
  echo "$pr_url"
  echo "✅ PR 생성 완료"

  # `${pr_url##*/}` 단순 분리 대신 `/pull/<N>` 패턴을 정확히 매칭한다 — 향후 gh가
  # `?expand=1` 같은 쿼리 파라미터/트레일링 슬래시가 붙은 URL을 찍어도 견고하게
  # N만 추출하기 위함 (PR #121 리뷰 #3138783769).
  pr_number=$(printf '%s' "$pr_url" | sed -E 's|.*/pull/([0-9]+).*|\1|')
  if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
    # PR 자체는 이미 push·생성이 완료된 상태. Status 전환만 누락되므로 사용자에게
    # 수동 보정 경로를 안내한다. return 1은 유지해 호출자가 실패를 인지하게 한다.
    echo "⚠️  PR 번호 파싱 실패 (url=${pr_url})." >&2
    echo "   PR은 이미 생성됐습니다. Status 전환만 누락됐으니 수동으로 보정하세요:" >&2
    echo "     claude-set-pr-status <pr-번호> \"In review\"" >&2
    return 1
  fi

  # 라벨 부착 (#1486): type + severity 전파. best-effort — 실패해도 PR 흐름 유지.
  claude-apply-pr-labels "$base_ref" "$pr_number"

  # Project 보드 상태 전환: PR 카드 → In review.
  # Issue는 In progress에 머물며, 머지 시 "Closes #N"으로 GitHub이 Done으로 자동 전환.
  claude-set-pr-status "$pr_number" "In review"

  # 이슈 status fallback 보정 (#1289): 우회 진입(main 에서 git checkout -b issue-<N>)
  # 이나 부분 fail 후 수동 재완료로 이슈가 Backlog/Ready 에 머문 채 PR 만 In review 가
  # 된 정책 위반을 PR 생성 시점에 정렬한다. 정상 흐름에서는 이미 In progress 라
  # 발화하지 않으며, forward 단계(In progress 이상)는 회귀 없이 그대로 둔다.
  _claude-reconcile-issue-status-on-close "$issue_number"

  # worktree 정리 안내 — 이 세션 자신은 worktree 내부에서 실행 중이라 스스로
  # 제거할 수 없으므로, 세션 종료 후 main에서 claude-cleanup-worktree를 호출하게 안내.
  cat <<EOF

다음 단계:
  1. 이 Claude 세션을 종료하고 main worktree로 돌아가세요
  2. main에서 실행: claude-cleanup-worktree ${issue_number}
EOF
}

# ────────────────────────────────────────────────────────────────────
# 사용법: claude-ref-issue <issue-number> <type> "<description>"
# type: Conventional Commits 타입 (feat, fix, docs, style, refactor, test, chore, perf, ci, build)
#
# 중간 작업용 PR 생성 함수 (#440 — Defense 2).
#
# `claude-close-issue` 와의 차이:
#   - PR 본문 키워드 = `Refs #N` (자동 close 발화 안 함)
#   - `claude-set-pr-status` 미호출 → 함수 자체는 보드 Status 를 변경하지 않음
#   - stacked PR 미지원 (중간 작업은 main 직진 흐름만 다룬다)
#
# 사용 시나리오:
#   - 전략 문서 / 설계 / 부분 구현 등 AC 가 미체크 상태로 남아 있는 작업.
#   - `claude-close-issue` 의 AC 가드(#440)에 막혔지만 중간 산출물을 PR 로 올려야
#     리뷰가 가능한 경우 (`--force` 대신 본 함수를 쓰는 게 정도).
#   - 본 PR 머지 후에도 이슈는 OPEN 으로 남고, 후속 PR 이 `Closes #N` 으로 close.
#
# 보드 동작:
#   본 함수는 의도적으로 PR 카드 Status 를 변경하지 않는다(보드 미변경).
#   (선택) `gh pr create` 직후 카드를 In review 로 옮기는 PostToolUse 훅을 따로
#   두면 그 훅이 PR 카드를 이동시킬 수 있다 — 이슈 카드는 어느 경우든 변동 없음.
# ────────────────────────────────────────────────────────────────────
claude-ref-issue() {
  # set -u 환경에서 인자 누락 시 unbound 에러를 피하기 위해 default 처리.
  local issue_number="${1:-}"
  local type="${2:-}"
  local description="${3:-}"

  if [[ -z "$issue_number" || -z "$type" || -z "$description" ]]; then
    echo "❌ 사용법: claude-ref-issue <issue-number> <type> \"<description>\"" >&2
    return 1
  fi

  # 세션 선점 체크 — close-issue 와 동일.
  local bound_issue
  if bound_issue=$(claude-session-bound); then
    if [[ "$bound_issue" != "$issue_number" ]]; then
      echo "⚠️  현재 브랜치는 #${bound_issue}에 바인딩되어 있는데 #${issue_number}로 ref 시도 중입니다." >&2
      return 1
    fi
  fi

  # CI 게이트 (#545): close-issue 와 동일 정책 (main 직진).
  if ! _claude-run-ci-gate "main"; then
    return 1
  fi

  git add -A
  git commit -m "${type}: #${issue_number} ${description}" || return 1

  # base sync — main 직진만 지원.
  echo "🔄 origin/main 동기화 중..."
  if ! git fetch origin main; then
    echo "❌ origin/main fetch 실패. 네트워크 상태를 확인하세요." >&2
    return 1
  fi
  if ! git rebase origin/main; then
    git rebase --abort 2>/dev/null
    echo "❌ origin/main 과 rebase 충돌. 수동으로 해결한 뒤 재실행하세요:" >&2
    echo "   git rebase origin/main" >&2
    echo "   # 충돌 해결 후 git add / git rebase --continue" >&2
    printf "   # 그 다음 다시 claude-ref-issue %q %q %q\n" "$issue_number" "$type" "$description" >&2
    return 1
  fi

  # 로컬 lint 가드 — close-issue 와 동일.
  if ! _claude-lint-guard; then
    return 1
  fi

  # 커밋 메시지 감사 + 빌트인 워크플로우 감사 — close-issue 와 동일 (soft warn).
  claude-audit-commit-issue-refs "$issue_number"
  claude-audit-builtin-workflows

  git push -u origin HEAD

  # PR 본문 = `Refs #N`. `Closes` 키워드 미사용 → 머지 시 GitHub 이 이슈를 자동
  # close 하지 않는다. 본문을 임시 파일로 넘겨 공유 create wrapper(#1486)에 위임 —
  # base=main·self-assign 일관 적용. set-pr-status 는 기존대로 미호출(보드 미변경).
  local pr_body="Refs #${issue_number}"
  local body_file
  body_file=$(mktemp) || { echo "❌ 임시 파일 생성 실패." >&2; return 1; }
  printf '%s\n' "$pr_body" > "$body_file"

  local pr_url pr_number _create_rc
  pr_url=$(claude-pr-create-from-body "main" "${type}: #${issue_number} ${description}" "$body_file" --assign-self)
  _create_rc=$?
  rm -f "$body_file"
  if (( _create_rc != 0 )); then
    echo "❌ PR 생성 실패." >&2
    return 1
  fi
  echo "$pr_url"

  # 라벨 부착 (#1486): type + severity 전파. best-effort — 실패해도 PR 흐름 유지.
  # PR 번호는 라벨 부착에만 필요하므로 파싱 실패해도 PR 성공은 유지한다.
  pr_number=$(printf '%s' "$pr_url" | sed -E 's|.*/pull/([0-9]+).*|\1|')
  if [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    claude-apply-pr-labels "main" "$pr_number"
  else
    echo "⚠️  PR 번호 파싱 실패 (url=${pr_url}) — 라벨 부착 스킵." >&2
  fi
  echo "✅ PR 생성 완료 (Refs only — 이슈는 close 되지 않음)"
}

# ────────────────────────────────────────────────────────────────────
# 6.5단계 — 봇 리뷰 대기 (SSOT)
# 사용법: claude-wait-bot-review <pr-number>
#
# gemini-code-assist / sourcery-ai / copilot 봇이 PR 리뷰를 남길 때까지
# 30초 간격으로 최대 10회 폴링한다 (마지막 회는 sleep 생략 — 총 9×30s 대기).
#
# 반환값:
#   0 = 봇 리뷰 감지
#   1 = 타임아웃 (10회 폴링 동안 리뷰 미도착)
#   2 = 인자 누락 또는 저장소 조회 실패
#
# gh-pr Step 9 의 인라인 폴링 루프를 충실히 추출한 SSOT — gh-pr 와
# github-workflow(close-issue·ref-issue) 양쪽이 동일 정책을 공유한다.
# 봇 로그인 매칭 regex 는 gh-pr Step 9 와 byte-for-byte 동일하게 유지한다.
# sleep 이 함수 내부에 있으므로 호출자는 "단일 Bash 호출" 가이드를 유지할 수 있다.
#
# 본 함수는 감지/타임아웃 신호만 반환한다 — 감지 시 gh-pr-reply 자동 실행은
# 호출하는 스킬의 책임이다.
# ────────────────────────────────────────────────────────────────────
claude-wait-bot-review() {
  local pr_number="${1:-}"
  if [[ -z "$pr_number" ]]; then
    echo "❌ 사용법: claude-wait-bot-review <pr-number>" >&2
    return 2
  fi

  local nwo
  if ! nwo=$(_claude-gh-retry gh repo view --json nameWithOwner -q .nameWithOwner) || [[ -z "$nwo" ]]; then
    echo "❌ 저장소(nameWithOwner) 조회 실패." >&2
    return 2
  fi

  local i count
  for i in $(seq 1 10); do
    echo "[${i}/10] 봇 리뷰 대기 중... (30s)"
    count=$(gh api "repos/${nwo}/pulls/${pr_number}/reviews" \
      --jq '[.[] | select(.user.login | test("^(gemini-code-assist|sourcery-ai|copilot)"; "i"))] | length' 2>/dev/null)
    if [[ "${count:-0}" -ge 1 ]]; then
      echo "✅ 봇 리뷰 감지 (${count}건)"
      return 0
    fi
    [[ "$i" -lt 10 ]] && sleep 30
  done
  echo "ℹ️  리뷰 미도착 (10×30s 타임아웃) — /gh-pr-reply ${pr_number} 로 수동 확인하세요."
  return 1
}
