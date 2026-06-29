---
name: github-workflow
license: Apache-2.0
description: "Claude Code 세션에서 GitHub Issue 기반 작업을 시작·마무리할 때 쓰는 워크플로우 Skill. '다음에 뭐 할까', '이슈 잡아줘', '새 작업 시작하자', '세션 시작', 'PR 만들자', '작업 끝났어', '커밋하고 PR', '세션 마무리'처럼 이슈 기반 작업의 시작·종료를 암시하면 트리거하라. GitHub Issue 번호, 브랜치 생성, 의존성 이슈(Depends on #N), PR 생성, 커밋 메시지 규약, pro-friendly 라벨, 마일스톤 순서를 언급하는 대화에서도 적용한다. '워크플로우'를 명시하지 않아도 이슈 기반 작업 흐름이 암시되면 즉시 적용하라."
---

# GitHub Workflow

이슈 기반 작업 세션의 시작·종료 워크플로우. 함수 구현: `${CLAUDE_PLUGIN_ROOT}/scripts/github-workflow.sh`.

**정책 SSOT**: `${CLAUDE_PLUGIN_ROOT}/docs/github-integration.md` — 보드 상태 전환 / Severity·Status·Type 라벨 / worktree 격리 / 세션 선점 / Closing keyword.

**사전 조건**: `gh`(+`project` 스코프) · `jq` · `git` · `bash`. Project 보드 설정(`CLAUDE_PROJECT_OWNER`/`CLAUDE_PROJECT_NUMBER`)이 환경변수 또는 `<repo>/.github-workflow.config` 로 지정돼 있어야 한다 (설치·셋업: 플러그인 README + `${CLAUDE_PLUGIN_ROOT}/docs/board-setup.md`). 각 세션 첫 호출 전 1회 함수를 로드한다:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/github-workflow.sh"
```

## 세션 흐름

```
─── main worktree (supervisor) ─────────────────────────────
1. claude-next-issue [pro|max]       → 다음 이슈 선택 (세션 선점 가드)
2. claude-check-deps <N>             → Depends on #N 의존 이슈/PR CLOSED/MERGED 확인
3. claude-enter-issue <N> [parent]   → 보류 라벨·assignee·원격 브랜치 가드 → self-assign
                                       → .claude/worktrees/issue-<N> + 브랜치 생성
                                       → parent(PR 번호|원격 브랜치) 지정 시 stacked base

4. EnterWorktree → claude-start-issue <N>  → 세션을 worktree 로 전환 + Status In progress (자동 연쇄)

─── 이슈 worktree ───────────────────────────────────────────
5. (작업 수행)
6-A. claude-close-issue [--force] <N> <type> "<desc>" [parent-pr]
     → AC 가드 → 테스트 → 커밋 → origin/<base> rebase → lint → push → PR(Closes #N) + 카드 In review
     → parent-pr 지정 시 stacked: base=부모 head + 본문 Depends on #<parent-pr> 자동
6-B. claude-ref-issue <N> <type> "<desc>"  → 중간 작업용. PR 본문 Refs #N · 보드 Status 미변경
6.5. (close/ref-issue 가 PR URL 의 /pull/<N> 로 claude-wait-bot-review 자동 실행)

─── main worktree ──────────────────────────────────────────
7. claude-cleanup-worktree <N|PR#>   → worktree 디스크 정리 (uncommitted 있으면 fail)
```

- **2단계 의존성 미충족** → 3 진행 금지, 1로 복귀해 다른 이슈 선택.
- **6단계 rebase 충돌** → 스크립트가 `git rebase --abort` 후 중단. 수동 해결 뒤 `claude-close-issue` 재호출.
- **6단계 lint guard** → push 직전 best-effort: 추적된 `*.sh`/`*.bash` 가 있으면 `shellcheck -x -S warning`(미설치 시 경고 후 스킵), 워크플로우가 있으면 `actionlint`. 빌드/테스트는 별도 로컬 CI 훅(`CLAUDE_LOCAL_CI_CMD` 또는 `.github-workflow/local-ci.sh`)으로 위임 — `docs/configuration.md` 참고.

## API 레퍼런스

세션 흐름 함수는 위 다이어그램 참조. 아래는 직접 호출하는 보조 public 함수.

| 함수                                                                    | 역할                                                                         |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `claude-set-issue-status` / `claude-set-pr-status`                      | Project Status 전환 (idempotent)                                             |
| `claude-verify-issue-status` / `claude-verify-pr-status`                | 전환 사후 검증 (eventual consistency 흡수)                                   |
| `claude-board-status [--all \| <status>…]`                              | 보드 조회 (인자 없음=Done 제외)                                              |
| `claude-find-similar-issues <kw…>`                                      | Backlog/Ready 유사 이슈 검색                                                 |
| `claude-create-issue [gh 옵션…]`                                        | 신규 이슈 단일 진입점 — 마일스톤+Ready+체크리스트 자동. `--repo` 미지원      |
| `claude-register-related-issue "<title>" [kw…]`                         | worktree 세션 전용 — 중복 검사 + `Related: #N`                               |
| `claude-create-milestone-checklist <title>`                             | 마일스톤 체크리스트 이슈 생성 + Ready 승격                                   |
| `claude-check-milestone <title> [--close]`                              | 마일스톤 완료 게이트 — open 0 검증 → close + 다음 체크리스트 자동            |
| `claude-unhold-issue <N>`                                               | 보류 라벨 제거 (REST DELETE, idempotent)                                     |
| `claude-audit-stacked-closes <parent-pr>`                               | stacked 자식 `Closes` 합산 audit                                             |
| `claude-audit-commit-issue-refs <N>`                                    | 커밋의 타 이슈 `#M` soft warn                                                |
| `claude-adopt-worktree [<N>] [<title>]`                                 | gh-pr 전용 — in-place 브랜치 → 격리 worktree 마이그레이션                    |
| `claude-pr-create-from-body <base> <title> <body-file> [--assign-self]` | PR 생성 SSOT — base 명시·self-assign. URL stdout. gh-pr·close/ref-issue 공유 |
| `claude-apply-pr-labels <base-ref> <pr-number>`                         | PR 라벨 SSOT — type(커밋) + severity(#1486 갭 복구) safe-apply. 존재 라벨만  |

내부 `_claude-*` 헬퍼·로컬 CI 훅 연동 세부는 `${CLAUDE_PLUGIN_ROOT}/scripts/github-workflow.sh` 참조. 순수 헬퍼는 `bash "${CLAUDE_PLUGIN_ROOT}/scripts/test-github-workflow.sh"` 로 검증.

## AI 행동 룰

**1. 수동 `claude-set-pr-status` 호출 시 verify 페어** — Project 자동화가 mutation 직후 값을 되돌리는 경합이 있어 set 의 ✅ 만 믿으면 보드와 어긋난다. `claude-set-pr-status <n> "In review" && claude-verify-pr-status <n> "In review"`.

**2. Stacked PR 부모 본문 `Closes` 합산** — GitHub 은 default branch 가 아닌 base 에 머지되면 `Closes #N` 을 발화하지 않는다. 자식이 닫는 이슈는 부모 본문 `### Closes` 에 `- Closes #<n> (via stacked PR #<child>)` 로 합산되어야 하며, 자식 머지 시 `stacked-closes-rollup.yml` 이 자동 patch(멱등). workflow 보류 케이스(다단 stack·open parent 다중)는 부모 머지 직전 `claude-audit-stacked-closes <parent-pr>` 로 점검 후 수동 보정. 합산 검증은 이슈 측 `closedByPullRequestsReferences` 단독(PR 측 인덱스는 수식어 형태에서 지연/누락).

**3. `gh api` String!/ID! 변수는 `-f` 강제** — `-F` 는 순수 숫자를 정수로 캐스팅하므로 `String!`/`ID!` 에 넘기면 타입 mismatch 로 mutation 실패. `Done` option_id 가 이 패턴. **`String!`/`ID!` → `-f`, `Int!` → `-F`**.

**4. 보류 라벨 이슈는 `claude-enter-issue` 가 거부** — self-assign/worktree/모델 호출 차단 + return 1. 본문·코멘트로 사유 해소 확인 후 `claude-unhold-issue <N>` 로 라벨 제거 뒤 재실행. escape hatch 없음. 보류 라벨 이름은 `CLAUDE_BLOCKED_LABELS`(기본 `보류`)로 설정. SSOT: `${CLAUDE_PLUGIN_ROOT}/docs/github-integration.md` — 보류 라벨.

**5. `claude-wait-bot-review` 는 신호만, 자동 응답은 스킬 책임** — 함수는 봇 리뷰 감지(0)/타임아웃(1)/오류(2) 신호만 반환. return 0 이면 close/ref-issue 흐름이 사용자 확인 없이 `gh-pr-reply` 스킬 Steps 1–7 을 즉시 실행하고, return 1 이면 자동 실행 금지·`/gh-pr-reply <pr#>` 수동 안내만 한다.

## PR 가드

### 이슈 없는 PR 가드 (exception-track)

연결 이슈가 없고 `<base>..HEAD` 커밋이 **3개 이상**이면 PR 생성을 차단한다(1–2개는 통과). 우회: `--force-no-issue` 또는 `GH_PR_SKIP_ISSUE_GUARD=1`.

### Stale rebase 회귀 탐지

CI fail 이 **(1)** PR head 가 base 대비 stale 이고 **(2)** fail 한 check 가 손댄 파일이 PR diff 파일과 파일 단위로 완전 disjoint — 두 조건을 모두 충족하면 BLOCKER 가 아니라 정보성 노티(rebase 권장 코멘트만, approve/request-changes 생략)로 강등한다. 하나라도 미충족이면 BLOCKER 유지.

### unit test 누락

로직 경로(함수·클래스·API 핸들러·스크립트 분기)를 추가·변경했는데 이를 검증하는 unit test 가 같은 PR 에 없으면 **BLOCKER** — FOLLOW-UP 강등 불가. 예외(단독 변경 시): 순수 문서(`docs/**`·`*.md`), 설정 파일(`*.json`/`*.yaml`/`*.toml`), shell bootstrap 스크립트.
