# gh:pr-approve — Help

## Arguments

| #   | Name                               | Default                                 | Description                    |
| --- | ---------------------------------- | --------------------------------------- | ------------------------------ |
| 1   | PR number, or `-h`/`--help`/`help` | required unless current branch has a PR | Target PR, e.g. `99`           |
| 2   | remote name                        | `origin`                                | Git remote for the target repo |

## Usage

- `/gh-pr-approve 99` — review PR #99 on `origin`
- `/gh-pr-approve 99 upstream` — PR #99 on `upstream`'s repo
- `/gh-pr-approve` — review the PR open on the current branch
- `/gh-pr-approve -h` / `--help` / `help` — print this help

## What the skill does

1. Pre-flight gate — checks PR state, draft, author, merge conflicts, required CI.
   Stops early on any blocker (won't approve your own PR, can't approve a draft, etc.).
2. Fetches diff, commits, and all three comment endpoints (inline / issue / review).
3. Reviews against `references/review-criteria.md` — correctness, conventions, security,
   performance, tests. If you previously reviewed this PR, enters re-review mode and
   verifies every prior concern was addressed.
4. Classifies findings as BLOCKER, FOLLOW-UP, or PRAISE.
5. Submits the review:
   - 0 BLOCKER, 0 FOLLOW-UP → **Approve with LGTM 👍** + specific compliments.
   - 0 BLOCKER, ≥1 FOLLOW-UP → files each follow-up as a GitHub issue, posts one PR
     comment linking them, then approves. Keeps the AI-driven issue workflow intact.
   - ≥1 BLOCKER → **Request changes** with per-blocker `file:line` + "왜 BLOCKER 인가"
     한 줄 이유. FOLLOW-UP 이 함께 있으면 같은 리뷰 본문의 _Suggestions (non-blocking)_
     섹션에 합산하고, 별도 이슈는 만들지 않는다 — 작성자가 한 번에 검토 가능. Blockers
     stay on the PR so the author's next push triggers natural re-review. 재리뷰에서
     BLOCKER 가 0 이 된 시점에 남아 있는 FOLLOW-UP 을 이슈로 만든 뒤 approve 한다.
   - **Comment-only (4d)** — 이미 다른 reviewer 가 approve 한 PR 에 2차 reviewer 가
     추인하거나, stale-rebase 회귀 노티, PR 외부 사유로 approve 를 보류하는 경우.
     review submission 없이 PR comment 만 남긴다.
6. Re-fetches `reviewDecision` + `mergeStateStatus` and reports a compact summary
   (plus diagnosis if merge is still blocked for reasons outside your review).

## What the skill won't do

- Approve your own PR.
- Approve without reading the diff.
- Merge the PR (author decides).
- Create follow-up issues for trivia that don't justify a tracked item.
- Attach labels/milestones to follow-up issues unless the label already exists in the repo.
