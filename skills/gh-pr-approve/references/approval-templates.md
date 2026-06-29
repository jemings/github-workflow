# Approval Templates — for gh:pr-approve skill

All three paths write the body to a `mktemp` file first (avoids shell-escaping and concurrent-run collisions), then call `gh`. Match the language dominant in the PR body/comments.

```bash
BODY=$(mktemp) && trap 'rm -f "$BODY"' EXIT
# ... write the drafted body to "$BODY" ...
```

## 6a — Clean LGTM

No findings. Approve with 👍 and 2–4 specific compliments.

### Body template

```markdown
LGTM 👍

### 요약

<한 문단 — 이 PR이 달성한 것, 리뷰 관점의 핵심 포인트>

### 잘 된 점

- <file:path:line 또는 short-sha 근거>로 <왜 좋은지>
- <...>
- <...>

<선택: 이 PR이 프로젝트에 주는 가치를 1줄로>
```

### Command

```bash
gh pr review <N> --repo "$TARGET_REPO" --approve --body-file "$BODY"
```

## 6b — Approve with Follow-up Issues

No BLOCKERs, ≥1 FOLLOW-UP. Three-step sequence — **do them in order**.

### Step 1 — Decide bundling, then create issue(s)

**Bundling decision** (SKILL.md §Step 4 4b 의 묶음 판단 기준 — 본 절이 SSOT):

- **통합 (1 이슈)**: 같은 파일/컴포넌트/기능 범위 + 한 PR 로 처리 자연스러움 + 분리 이득(예: 담당자 분리, 의존성 관리, 모듈별 추적) 없음 — 모두 충족할 때.
- **분리 유지 (N 이슈)**: 담당자 분리(다를 가능성) / 의존성 관리(순서 다름) / 모듈별 추적(다른 모듈) — 하나라도 해당할 때.

판단 결과와 무관하게 동일한 `gh issue create` 호출 형태를 쓰되, 본문과 제목 형식이 다르다.

```bash
ISSUE_BODY=$(mktemp) && trap 'rm -f "$ISSUE_BODY"' EXIT
# ... write the issue body ...
gh issue create \
  --repo "$TARGET_REPO" \
  --title "<title — see templates below>" \
  --body-file "$ISSUE_BODY"
```

#### 통합 이슈 (1 이슈, FOLLOW-UP 다수 묶음)

- **제목 형식**: `<type>: <PR 제목 또는 공통 주제> — N개 후속 개선` (예: `refactor: gh-pr-approve 후속 개선 — 3개 항목`).
  단일 type 이 모든 항목을 대표하지 못하면 `chore:` 사용.
- **본문 템플릿**:

```markdown
## 배경

PR #<PR> 리뷰 중 발견된 후속 개선 항목 N건. 같은 범위(<파일/컴포넌트/기능>)라 하나의 이슈로 묶어 추적합니다.

### Item 1 — <한 줄 제목>

- 위치: `<file>:<line>` 또는 함수/블록 이름
- 현상: <observation>
- 제안: <actionable fix>

### Item 2 — <한 줄 제목>

- 위치: `<file>:<line>`
- 현상: <observation>
- 제안: <actionable fix>

<...Item N...>

## 참고

- Refs #<PR> (리뷰 시점: <short-sha>)
- <optional: 관련 docs/링크>
```

#### 분리 이슈 (N 이슈, FOLLOW-UP 마다 1건)

- **제목 형식**: `<type>: <concise description>`
- **본문 템플릿**:

```markdown
## 배경

PR #<PR> 리뷰 중 발견된 후속 개선 항목.

## 현상

<file:path:line 또는 함수/블록 이름>에서 <observation>.

## 제안

<actionable fix — code snippet or prose>

## 참고

- Refs #<PR> (리뷰 시점: <short-sha>)
- <optional: 관련 docs/링크>
```

Collect each created issue number for Step 2 — 통합 시 1개, 분리 시 N개.

### Step 2 — Post one PR comment linking all follow-ups

```bash
COMMENT_BODY=$(mktemp) && trap 'rm -f "$COMMENT_BODY"' EXIT
# ... write comment body ...
gh pr comment <N> --repo "$TARGET_REPO" --body-file "$COMMENT_BODY"
```

Comment template — 이슈가 1개(통합)이면 단일 라인, N개(분리)면 목록:

```markdown
리뷰하면서 발견한 후속 개선 항목을 이슈로 정리해 두었습니다. 이 PR 머지와 독립적으로 처리해주시면 됩니다.

<!-- 통합 이슈 1건일 때 -->

- #<A> — <한 줄 요약, N개 항목 묶음>

<!-- 또는 분리 이슈 N건일 때 -->

- #<A> — <한 줄 요약>
- #<B> — <한 줄 요약>
- #<C> — <한 줄 요약>

Approve는 별도로 제출합니다 — 아래 리뷰 참고.
```

### Step 3 — Submit approving review

Body template (extends 6a + a follow-up section):

```markdown
LGTM 👍

### 요약

<PR 핵심 요약 1문단>

### 잘 된 점

- <file:line 근거로 왜 좋은지>
- <...>

### 후속 개선

<!-- 통합 이슈 1건일 때 -->

- #<A> — N개 항목 묶음. 본 PR 머지와 독립적으로 추적합니다.

<!-- 또는 분리 이슈 N건일 때 -->

- #<A>, #<B>, #<C> — 본 PR 머지와 독립적으로 추적합니다.
```

```bash
gh pr review <N> --repo "$TARGET_REPO" --approve --body-file "$BODY"
```

## 6c — Request Changes (BLOCKERs present)

Never approve. List each blocker with a `file:line` pointer, the **"왜 BLOCKER 인가"** 한 줄 이유, and the minimal fix expected. Blockers stay on the PR; the author's next push triggers natural re-review.

**FOLLOW-UP 처리** — BLOCKER ≥ 1 인 동안에는 FOLLOW-UP 을 별도 이슈로 생성하지 **않는다**. 같은 리뷰 본문의 `## 💡 Suggestions (non-blocking)` 섹션에 합산해 작성자가 BLOCKER 수정과 함께 한 번에 검토하도록 한다. 재리뷰에서 BLOCKER 가 0 이 된 시점에 남아 있는 FOLLOW-UP 을 §6b 절차(`SKILL.md` **4b** 절차)로 이슈화 후 approve.

### Body template

```markdown
머지 전에 반드시 수정이 필요한 항목이 있어 **Request changes**로 남깁니다.

## 🚫 Blockers

1. **<short title>** — `<file>:<line>`
   - 증상: <what's wrong>
   - 왜 BLOCKER 인가: <한 줄 이유 — 로직 버그 / 보안 취약점 / 실패하는 CI 체크 / 미해결 선행 리뷰 코멘트 / 공식 approve 불가 사례 중 하나에 매핑>
   - 제안: <minimal fix>

2. **<...>** — `<file>:<line>`
   - ...

## 💡 Suggestions (non-blocking)

> 아래는 오류는 아니지만 같이 검토해주시면 좋을 개선 제안입니다. 머지를 막지는 않습니다.

- `<file>:<line>` — <제안>
- `<file>:<line>` — <제안>

## 참고로 잘 된 점

- <1–2 specific compliments so the author knows what to keep>

수정 후 push 주시면 재리뷰하겠습니다.
```

`Suggestions` 섹션은 FOLLOW-UP 이 0 건이면 통째로 생략한다.

### Command

```bash
gh pr review <N> --repo "$TARGET_REPO" --request-changes --body-file "$BODY"
```

## 6d — Comment-only Notice (co-sign / external notice / stale rebase)

Review submission (`--approve` / `--request-changes`) 자체를 생략하고 PR 에 comment 만 남긴다 (PR description 수정이 아니라 PR conversation/review timeline 의 comment). 다음 세 트리거 중 하나에 해당할 때만 사용:

1. **2차 reviewer 의 코드 LGTM 추인** — `reviewDecision` 이 이미 `APPROVED` 이고 추가할 finding (BLOCKER / FOLLOW-UP) 이 없을 때. 새 `--approve` 는 reviewDecision 을 바꾸지 못해 noise 만 쌓이고, `--request-changes` 는 직전 reviewer 의 판단을 뒤집는 행위라 의미 과잉.
2. **PR 외부 사유로 approve 보류** — 코드는 LGTM 인데 main rebase 권장, 인접 회귀 노티, 머지 타이밍 조율처럼 PR 외부 사유로 approve 를 유보하고 싶을 때. `--request-changes` 는 머지 차단이라 의도 과잉.
3. **Stale rebase 회귀 노티** — `references/review-criteria.md` §[stale rebase 회귀 탐지](review-criteria.md#stale-rebase-회귀-탐지) 두 조건을 모두 충족한 경우. CI fail 의 원인이 PR diff 가 아니므로 BLOCKER 강제에서 강등 → 작성자에게 rebase 권장만 남긴다.

### 출력 수단 선택

| 트리거                       | 명령                                             | 이유                                                                                                                                                                                                                                   |
| ---------------------------- | ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 (2차 reviewer 추인)        | `gh pr review <N> --comment --body-file "$BODY"` | Review tab 에 reviewer 정체성이 명시되어, request 이력이 있을 때 "응답함" 상태로 기록된다. `--comment` 는 reviewDecision 에 영향을 주지 않아 prior `APPROVED` 유지. **본 트리거에 한해 §Don'ts 의 `--comment` 금지 규칙이 예외 적용**. |
| 2 (외부 사유로 approve 보류) | `gh pr review <N> --comment --body-file "$BODY"` | 동일. reviewer 가 본 PR 을 검토했다는 사실을 기록하면서 머지 차단은 하지 않는다.                                                                                                                                                       |
| 3 (stale rebase 노티)        | `gh pr comment <N> --body-file "$BODY"`          | 단순 노티 — review submission 의 reviewer 표식이 불필요하다. PR conversation comment 로 충분.                                                                                                                                          |

### Body template

```markdown
<리뷰 의도 1-2줄 — 왜 review submission 대신 comment 인지>

### <한 줄 헤더 — 추인 / 외부 노티 / stale rebase 등 트리거에 맞게>

- <file:path:line 또는 short-sha 근거>로 <전달할 정보>
- <...>

<선택: rebase 권장이면 구체 절차 1-2줄. 2차 reviewer 추인이면 잘 된 점 2-3건 — 6a 와 동일 기준>
```

### Examples

**트리거 1 — 2차 reviewer 추인**

```markdown
이미 @reviewer-A 가 approve 한 PR 이라 추가 approve 는 noise 가 될 것 같아 comment 로 추인만 남깁니다.

### 추인

- `src/lib/auth.ts:42` — refresh 토큰 만료 처리 분기가 명료
- `8a3f2c1` — 에러 처리 경로가 정상/예외 양쪽을 모두 cover

이대로 머지 진행하셔도 좋을 것 같습니다 👍
```

**트리거 2 — PR 외부 사유로 approve 보류 (인접 회귀 노티 + 머지 타이밍 조율)**

```markdown
코드 자체는 LGTM 인데 main 에 직전 머지된 `#<adjacent-PR>` 이 본 PR 이 의존하는 `<file-or-API>` 동작을 바꿨습니다 — 본 PR 머지 전에 한 번 더 점검이 필요해 보여 approve 는 보류합니다. `--request-changes` 까지 갈 사안은 아니라 review submission 대신 comment 로 남깁니다.

### 인접 회귀 노티

- `<file:path:line>` — `#<adjacent-PR>` 이 도입한 `<변경된 동작>` 과 본 PR 의 `<관련 호출/가정>` 이 충돌할 수 있음
- `<short-sha>` (main) 머지 후 본 PR head 가 stale — `git fetch origin main && git rebase origin/main` 후 회귀 케이스 1건 (`<test-name>` 또는 `<수동 확인 절차>`) 만 추가 확인 부탁드립니다

확인 결과가 무해하거나 1줄 수정으로 끝나면 곧바로 approve 진행하겠습니다. 머지 차단 의도는 없습니다.
```

**트리거 3 — Stale rebase 노티**

```markdown
PR 의 diff 자체는 LGTM 인데 `e2e (playwright smoke + a11y)` fail 이 main 의 `<short-sha>` 후속 commit (`#<related-PR>`) 과의 stale-rebase 회귀로 보입니다 — 본 PR diff (`<file-A>`, `<file-B>`) 와 fail 의 대상 경로 (`/login`) 가 겹치지 않습니다.

### 권장 절차

\`\`\`bash
git fetch origin main && git rebase origin/main && git push --force-with-lease
\`\`\`

Rebase 후 e2e 재실행이 green 으로 돌아오면 정상 approve 진행하겠습니다. 머지 차단 의도는 없습니다.
```

### Command

위 표의 명령을 그대로 사용한다. BODY 작성 후:

```bash
gh pr review <N> --repo "$TARGET_REPO" --comment --body-file "$BODY"
# 또는 (트리거 3)
gh pr comment <N> --repo "$TARGET_REPO" --body-file "$BODY"
```

## Second-reviewer prepend (4b/4c)

이미 approve 된 PR 에 2차 reviewer 가 새 finding 으로 4b/4c 리뷰를 제출할 때, 리뷰 본문 첫 줄에 PR 언어에 맞춰 (Language matching 정책 동일) 다음 문구를 prepend 한다:

- 한국어 reference: `이 리뷰는 이미 approve 된 PR 에 추가 finding 을 올리는 2차 리뷰입니다. 직전 reviewer 의 판단을 뒤집을 수 있는 점을 양해 부탁드립니다.`
- English reference: `This is a second-pass review on a PR that already has an approval. Please bear with me — the new findings below may end up overriding the previous reviewer's decision.`

## Language matching

Scan the PR body + most recent 3 human comments. Reply in the dominant language. Korean PR → Korean review. Mixed → match the PR body.

## Don'ts

- **Never** attach `--label`/`--assignee`/`--milestone` to follow-up issues unless verified via `gh label list` / `gh api` that they exist — silent failures or surprise taxonomy damage is worse than terse issues.
- **Never** submit a `--comment` review as a substitute for `--approve` **when you are the primary reviewer and the PR has no prior APPROVE**. "Comment" reviews don't satisfy branch protection and will confuse the author. **예외 — §6d (4d 경로)**: 이미 다른 reviewer 의 `--approve` 가 존재하는 PR 에 2차 reviewer 가 추인하거나, PR 외부 사유 (rebase 권장 · 머지 타이밍 · 인접 회귀 노티) 만 전달하는 경우는 `--comment` 가 정식 출력 수단이다.
- **Never** re-submit a review if one already exists — GitHub dismisses stale ones; check `reviewDecision` first.
