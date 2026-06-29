---
name: gh-triage
license: Apache-2.0
description: >-
  Review and route Backlog issues — promote ready ones, enhance with code
  exploration, split clear sub-items, or post a clarification comment when
  decisions are needed. Run with no argument for the whole Backlog, or `<N>`
  for a single issue. Use when the user runs /gh-triage, /gh:triage, or asks
  "Backlog 정리해줘", "Backlog 검토해서 Ready 올려", "#1221 triage".
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent
---

# gh:triage — Backlog 이슈 검토 + 라우팅

## Role

Backlog 에 누적된, 사람이 빠르게 적어둔 이슈를 검토해 4 가지 분기(READY-AS-IS
/ ENHANCE / SPLIT / CLARIFY — Step 2.3 정의)로 라우팅한다. **원칙: 무리하게
Ready 로 끌어올리지 않는다** — 모호하면 사용자에게 결정을 돌려준다. 추측으로
박은 AC 가 CLARIFY 코멘트보다 비싸다.

## Arguments

| Position | Name  | Default | Description                                                      |
| -------- | ----- | ------- | ---------------------------------------------------------------- |
| 1        | `<N>` | (없음)  | 인자 없으면 Backlog 전체 순회. 숫자 인자면 해당 이슈 1건만 처리. |

## Step 0: Load Workflow Functions

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/github-workflow.sh"
```

`claude-set-issue-status` / `claude-verify-issue-status` /
`claude-create-issue` / `claude-board-status` / `claude-check-deps` /
`_claude-current-milestone` 를 모두 여기서 가져온다. 새 스크립트 추가 금지.

## Step 1: Resolve Target Set

- 인자 없음 → `claude-board-status Backlog` 로 OPEN + Backlog 이슈 번호 전체
  수집. 출력 형식은 `<status> | <type> | #<number> | <title>` — `| Issue |`
  패턴으로 필터링해 PR 행 제거.
- 인자 `<N>` → 해당 이슈 1건. `gh issue view <N> --json
number,state,projectItems` 로 보드 status 가 Backlog 인지 확인. 아니면
  `SKIP (already <status>)` 한 줄 보고하고 종료.

## Step 2: Per-Issue Routing

각 이슈에 대해 아래 단계를 순서대로 수행. 한 분기에 들어가면 그 분기로
끝난다.

### Step 2.1: Load Metadata

```bash
gh issue view <N> --json number,title,body,labels,milestone,state,projectItems,url
```

### Step 2.2: SKIP Guards

다음 중 하나라도 해당하면 본문/상태 변경 없이 `SKIP` 한 줄 보고:

- `state != "OPEN"` → `SKIP (state=<state>)`
- 보드 status 가 이미 `In progress / In review / Approved / Done` →
  `SKIP (already <status>, forward-only)`
  (`_claude-post-issue-create` forward-only 가드)
- 라벨에 보류 라벨(`CLAUDE_BLOCKED_LABELS`, 기본 `보류`) 포함 → `SKIP (blocked label)`
  (`${CLAUDE_PLUGIN_ROOT}/docs/github-integration.md` — 보류 라벨)
- 라벨에 `milestone` 포함 → `SKIP (milestone checklist, different lifecycle)`
- 본문에 `Depends on #<M>` 패턴이 있을 때 의존 이슈 중 OPEN 인 게 하나라도
  있으면 → `SKIP (depends on open #<M>)`. 검증은 `claude-check-deps <N>` 의
  종료 코드(비-0 = 미충족)로 판단 — stdout 파싱 금지
- 마일스톤이 명시되어 있고 `_claude-current-milestone` 결과보다 미래
  (number 가 더 큼) → `SKIP (future milestone <name>)`. 번호 비교는
  `_claude-milestone-number <title>` 로 title → number 변환 후 수행.

### Step 2.3: Classify the Body

본문을 읽고 다음 4 분기 중 하나로 분류:

- **READY-AS-IS** — 본문이 다음을 모두 만족:
  - Acceptance Criteria 또는 명시적 작업 체크리스트(`- [ ]` 또는 번호 목록) 존재
  - 영향 파일/모듈에 대한 단서가 본문 내 또는 인용된 이슈/PR 링크에 존재
  - 모호 표현(`?`, `... 필요`, `논의 필요`, `확인 필요`, `... 등`) 부재
  - 사용자 결정이 선행되어야 하는 항목(인프라 선택, 정책 결정, UX 명세 부재 등) 없음
- **ENHANCE** — READY-AS-IS 미충족이지만 본문에 등장하는 키워드/경로로 코드
  탐색 시 (a) file:line 수준 식별이 가능하고 (b) AC 를 합리적으로 추론할
  수 있는 경우.
- **SPLIT** — 본문이 여러 항목을 나열하는데 일부는 ENHANCE 가능하고
  나머지는 CLARIFY 필요할 때.
- **CLARIFY** — 코드 탐색으로도 작업 가능 수준 정의 불가능. 신규 인프라
  결정·재현 경로 부재·정책 결정 부재 등.

분류 휴리스틱:

- 단일 이슈 처리(인자 `<N>` 있음) 또는 본문 키워드가 명확하면 Explore
  서브에이전트 1개로 코드 탐색 후 분기 결정. **추측 비중이 30% 를 넘으면
  ENHANCE 가 아니라 CLARIFY 로 떨어뜨려라** — 잘못된 AC 비용 > 코멘트 비용.
- Backlog 전체 순회 중에는 본문이 1~2 줄로 빈약한 항목은 코드 탐색을
  생략하고 바로 CLARIFY 분기로 보내라. 토큰/시간 예산을 SPLIT/ENHANCE
  후보에 집중.

### Step 2.4: Apply Branch

모든 본문 작성은 `mktemp` 임시 파일 경유 (셸 escape 안전).

#### READY-AS-IS

본문/코멘트 추가 없이 상태만 전환.

```bash
claude-set-issue-status <N> "Ready" && claude-verify-issue-status <N> "Ready"
```

#### ENHANCE → READY

원문 보존 + 아래 템플릿 append. **검증된 사실만** 적는다. 모호한 추론은
`추측:` 접두로 표시.

```markdown
<원문 그대로>

---

## Context (코드 탐색 보강)

(file:line 단서. 추측은 "추측:" 으로 표시)

## Acceptance Criteria

- [ ] ...

## Out of scope

- ...
```

```bash
BODY=$(mktemp) && trap 'rm -f "$BODY"' EXIT
# write enhanced body to "$BODY"
gh issue edit <N> --body-file "$BODY"
claude-set-issue-status <N> "Ready" && claude-verify-issue-status <N> "Ready"
```

#### SPLIT

명확한 항목을 별도 이슈로 분리. `claude-create-issue` 가 자동 Ready 승격 +
마일스톤 체크리스트 등록까지 해준다. 직접 `gh issue create` 금지.

```bash
BODY=$(mktemp) && trap 'rm -f "$BODY"' EXIT
# write split-out issue body to "$BODY" — must include "Related: #<N>"
OUT=$(claude-create-issue --title "<title> (#<N> 분리)" --body-file "$BODY")
# 첫 줄(URL)만 안전 추출 — 후속 줄에 ✅ 라우팅 로그가 다른 #번호를 포함할 수 있다
M=$(echo "$OUT" | head -n 1 | sed -E 's|.*/issues/([0-9]+).*|\1|')
```

캡처한 `<M>` 으로 부모 이슈에 코멘트:

```markdown
원문 검토 후 항목별 처리 결과:

## ✂️ 별도 이슈로 분리됨

- **"<항목>"** → #<M> 로 분리 (Ready 승격 완료).

## ❓ 결정 보류

(잔여 모호 항목 + 결정 필요 사항)
```

```bash
gh issue comment <N> --body-file "$BODY"
```

부모 이슈는 Backlog 유지 (status 변경 없음).

#### CLARIFY

본문 보존, 결정 필요 항목을 정리한 코멘트만:

```markdown
원문 검토 결과 다음 결정이 선행되어야 작업 가능합니다.

(항목별 현재 코드 상태 — 부재한 인프라 / 누락된 정책 / 불명확한 재현 경로 등)

→ 결정 필요:

1. ...
2. ...
```

```bash
gh issue comment <N> --body-file "$BODY"
```

Backlog 유지.

## Step 3: Report

표 형태로 한 줄씩:

```
gh-triage processed N issues:
  #1221  ENHANCE → Ready    https://github.com/owner/repo/issues/1221
  #1222  SPLIT (→ #1283)    Backlog (clarification posted)
  #1223  CLARIFY             Backlog (decisions needed)
  #1245  READY-AS-IS         Backlog → Ready
  #1265  SKIP                future milestone M5
```

## Constraints

- **원문 보존** — ENHANCE 는 항상 `<원문> + --- + 보강 섹션` append, 덮어쓰기
  금지.
- 분리 이슈 생성은 `claude-create-issue` 만 (마일스톤/Ready/체크리스트 자동화
  일관성). 직접 `gh issue create` 금지.
- `claude-set-issue-status` 뒤엔 반드시 `claude-verify-issue-status` 페어 —
  Project 자동화 race 흡수 (github-workflow 스킬 §AI 행동 룰 1).
- 보류 라벨 이슈는 어떤 분기에서도 처리 금지 — SKIP 만.
- 본 스킬 실행이 곧 동의 — "Ready 올려도 될까요?" 식 사전 확인 금지. 단
  SPLIT/CLARIFY 코멘트로 사용자 결정을 요청하는 것은 OK.
