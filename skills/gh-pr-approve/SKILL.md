---
name: gh-pr-approve
license: Apache-2.0
description: >-
  Review a GitHub PR a colleague requested you review, then approve it or
  request changes and file follow-up issues. Use when the user runs
  /gh-pr-approve, /gh:pr-approve, or asks "PR 리뷰하고 승인해", "approve PR 99",
  "#99 리뷰 승인", "동료 PR 검토 후 approve", "re-review requested". Accepts
  `-h`/`--help`/`help` to print usage.
allowed-tools: Bash, Read, Grep, Glob
---

# gh:pr-approve — Review → Approve or File Follow-up Issues

## Help

If arg #1 is `-h`, `--help`, or `help`, read `references/help.md` and
output its content verbatim, then stop. No API calls.

## Step 1: Resolve + Pre-flight Gate (parallel)

Resolve context, then fetch pre-flight signals in parallel before
reading the diff:

- `TARGET_REPO` from `git remote get-url <remote>` (arg #2, default
  `origin`). Missing remote → list `git remote -v` and stop.
- PR number: explicit arg #1 → `gh pr view --json number` on current
  branch → stop and ask.
- `ME=$(gh api user -q .login)` for self-review / re-review checks.
- PR JSON: `number,title,author,state,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefName,headRefOid,baseRefName,files` (`headRefOid` 는 §[stale rebase 회귀 탐지](references/review-criteria.md#stale-rebase-회귀-탐지) 의 `<PR head SHA>` 인자에 직접 사용)
- `REBASEABLE=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER" --jq .rebaseable)` —
  `rebaseable` 은 REST 전용 (`gh pr view --json rebaseable` 은 GraphQL 에
  필드가 없어 `Unknown JSON field` 실패).
- Prior reviews/comments on this PR by `ME`
- `gh pr checks <N> --repo $TARGET_REPO`
- **Merge strategy**: 명시적 `--merge-strategy=<rebase|squash|merge>` arg
  (remote 뒤 positional) → 없으면 repo-root
  `CLAUDE.md`/`AGENTS.md`/`DEVELOPMENT.md` "PR 머지 전략" 절에서 추출 →
  그것도 없으면 `--rebase` (project default).

**Stop conditions** (explain, don't approve): `state != OPEN` ·
`isDraft == true` · `author.login == ME` · any required check failing.

**CI failure exception** — failing required check 가 `references/review-criteria.md` §[stale rebase 회귀 탐지](references/review-criteria.md#stale-rebase-회귀-탐지) 두 조건을 모두 충족하면 stop 하지 않는다 — Step 3 에서 정보성 노티로 마킹하고 Step 4 **4d** 경로로 라우팅.

Warn (but do not stop) on `mergeable: CONFLICTING` or `rebaseable: false` —
prepend a visible warning block to the review body and include it in the
Step 5 report.

If prior `ME` comments/reviews exist → **re-review mode**: primary goal
is verifying each prior concern was addressed by a subsequent commit.

**Second-reviewer mode** — `reviewDecision == APPROVED` (다른 reviewer 가 이미 approve) 인데 `ME` 의 prior review/comment 가 없으면 2차 reviewer 모드:

- 추가할 finding (BLOCKER 또는 FOLLOW-UP) 있음 → 정상 분류 진행. 결과가 **4b**/**4c** 면 리뷰 본문 첫 줄에 2차 리뷰 prepend 를 PR 언어에 맞춰 추가 — 문구는 `references/approval-templates.md` §Second-reviewer prepend.
- finding 없는 코드 LGTM 추인 → **4d** 경로 (review submission 생략, comment-only). 추가 `--approve` 는 reviewDecision 을 바꾸지 못해 noise.

## Step 2: Fetch Review Material + Review

In parallel: `gh pr diff <N>`, `gh pr view <N> --json commits`, and the
three comment endpoints in `references/review-criteria.md`. Also read
repo-root `CLAUDE.md`/`AGENTS.md`/`DEVELOPMENT.md` if present plus every
`.claude/**/*.md` linked from their "참조 문서" / "References" table —
the source of truth for the **Project Policy** checklist dimension.
Apply the review-criteria checklist — correctness, conventions, project
policy, security, performance, tests. In re-review mode, map each prior
concern to the commit that resolved it (or flag "unresolved").

## Step 3: Classify Findings

Each concern is exactly one of **BLOCKER** (must fix before merge),
**FOLLOW-UP** (valid but non-blocking), or **PRAISE** (collect ≥1 for
approvals, anchored to a concrete diff location). See
`references/review-criteria.md` for the BLOCKER / FOLLOW-UP line and
the **명확한 오류 유형 — 발견 시 반드시 BLOCKER** 강제 목록 (로직 버그,
보안 취약점, 실패하는 CI 체크, 미해결 선행 리뷰 코멘트, 공식 approve 불가 사례).

**BLOCKER 분류 근거 명시 강제** — 각 BLOCKER 마다 "왜 BLOCKER 인가?"
한 줄 이유(예: "분기 조건 반전으로 PR 제목과 반대 동작", "미검증 입력값을
shell 에 직접 전달", "required CI failing: lint")를 리뷰 본문에 포함한다.
이유 없는 BLOCKER 는 오분류 — 제출 금지, FOLLOW-UP/PRAISE 로 재분류.

Path selection:

- 0 BLOCKER, 0 FOLLOW-UP → **4a** clean LGTM
- 0 BLOCKER, ≥1 FOLLOW-UP → **4b** approve with follow-up issues
- ≥1 BLOCKER → **4c** request changes (FOLLOW-UP 은 같은 본문에 합산)
- **4d** comment-only (Step 1 second-reviewer mode · stale rebase 노티 · PR 외부 사유로 approve 보류) — review submission 자체를 생략. 트리거·출력 수단은 `approval-templates.md` §6d 참조

## Step 4: Submit Review

Command shapes + body templates in `references/approval-templates.md`.
Match the language dominant in the PR (Korean PR → Korean review).

- **4a** `gh pr review --approve` with 👍 + 2–4 specific compliments.
- **4b** (BLOCKER=0, FOLLOW-UP≥1) 먼저 **묶음 가치**를 판단해 통합 1 이슈
  (`### Item N` 나열) 또는 FOLLOW-UP 별 분리 N 이슈로 생성하고, PR 코멘트로
  모든 이슈 링크를 모은 뒤 `gh pr review --approve` 로 마무리한다.
  묶음 판단 기준·본문 템플릿은 `references/approval-templates.md` §6b.
- **4c** (BLOCKER≥1) `gh pr review --request-changes` — 본문에
  `## 🚫 Blockers` (file:line + 왜 BLOCKER 인가 + 최소 수정안) 와
  `## 💡 Suggestions (non-blocking)` (FOLLOW-UP 합산) 를 함께 작성한다
  (템플릿 §6c).
  - **FOLLOW-UP 이슈를 생성하지 않는다** — 작성자가 BLOCKER 수정과 제안을
    한 번에 검토하도록 소통을 집중시키고 백로그 노이즈를 막는다. 재리뷰에서
    BLOCKER=0 이 되면 남은 FOLLOW-UP 을 **4b** 절차(§6b)로 이슈화 후 approve.
  - BLOCKER 는 이슈로 만들지 않는다 — PR 에 남아 있어야 작성자의 다음 push 가
    자연스러운 re-review 를 트리거한다.
  - `gh pr edit <N> --add-label "🚫 Blocked"` 로 차단 상태를 보드 카드에
    노출 (`gh label list --search "🚫 Blocked"` 가 비어 있으면 silent skip;
    작성자는 fix push 후 `gh-pr-reply` 로 떼낸다).
- **4d** (comment-only) review submission 을 생략하고 PR conversation/review
  timeline 에 comment 만 남긴다 (PR description 수정 아님). 2차 reviewer
  추인·PR 외부 사유 보류는
  `gh pr review <N> --repo "$TARGET_REPO" --comment --body-file "$BODY"`
  (reviewer 표식 + prior `APPROVED` 보존), stale rebase 노티는
  `gh pr comment <N> --repo "$TARGET_REPO" --body-file "$BODY"`.
  트리거별 근거·템플릿·`--comment`
  금지 규칙 예외는 §6d. boards/Status 전환·`🚫 Blocked` 라벨 부착 없음.

## Step 5: Verify and Report

Re-fetch `reviewDecision` + `mergeStateStatus`. If still BLOCKED despite
an approval, diagnose (another reviewer CHANGES_REQUESTED, required
check pending, branch out of date, reviewer lacks write access) and
include that in the report.

Print:

```
PR #<N>: <APPROVED|CHANGES_REQUESTED>
  Blockers:   <n>
  Follow-ups: <n>  → issues: #A, #B   (bundled: 1 issue covering N items, or N separate issues)
  Merge:      <CLEAN|BLOCKED — <reason>>
  <PR URL>
```

## Constraints

- Never approve without reading the diff, nor approve your own PR.
- Compliments must reference concrete diff locations — no generic praise.
- Never fabricate follow-ups to look thorough. Each issue must represent
  a real concern you can defend.
- Never merge the PR — the author decides when to merge.
- No labels/milestones on follow-up issues unless `gh label list` confirms the label exists.
