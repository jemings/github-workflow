---
name: gh-pr-reply
license: Apache-2.0
description: >-
  Fetch code review comments on a GitHub PR, apply valid fixes, and reply to
  each (accepted, or declined with reasoning). Use when the user runs
  /gh:pr-reply, /gh-pr-reply, or asks "PR 리뷰 코멘트 확인하고 수정", "리뷰 답변
  달아", "PR 123 코멘트 처리해". Defaults to the current branch's PR; accepts an
  explicit PR number. Handles bot comments (gemini, sourcery, copilot) too.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# gh:pr-reply — Address PR Review Comments

## Role

Process every code-review comment on a PR: judge validity, fix valid ones,
reply to each with the outcome. The **politeness rule** — every thread (human
or bot) gets an explicit response. Silent fixes are unacceptable; silent
declines worse.

## Step 1: Resolve Target PR

1. **Explicit argument** — `/gh:pr-reply 123` → PR #123.
2. **Current branch** — `gh pr view --json number,url,headRefName,baseRefName`;
   no PR for the branch → stop and tell the user.

Never guess or pick "the latest PR in the repo". Capture `owner/repo` via
`gh repo view --json nameWithOwner`.

## Step 2: Fetch All Review Comments

Read `references/comment-fetching.md` — the three API endpoints, field
extraction, dedup rule. Fetch all three; drop already-replied threads.

## Step 3: Evaluate Each Comment

**First (optional)**, if your project defines an out-of-scope platform filter,
run it — `references/out-of-scope-platforms.md`. The reference ships **disabled
by default** with iOS/Safari/WebKit as a worked example; enable and customize it
only if your project genuinely has unsupported platforms. When enabled and a
comment's _primary motivation_ matches an out-of-scope platform: classify
**DECLINE**, apply no patch, reply with the platform's canonical template
**verbatim**, and log the trigger line in the reference's format. Bypass only on
an explicit per-session user override (see the reference). If no filter is
configured, skip straight to normal classification.

Comments go through normal classification:

- **ACCEPT** — reviewer is correct; change the code.
- **ACCEPT-PARTIAL** — valid concern, but a different fix is better; note the
  deviation in the reply.
- **DECLINE** — reviewer is wrong, misreads the context, or would regress
  something; explain why.
- **QUESTION** — reviewer wants clarification, not a change; answer it.

Bot comments (gemini-code-assist, sourcery-ai, copilot) follow the same rules,
out-of-scope filter included when configured.

## Step 4: Apply Fixes (ACCEPT / ACCEPT-PARTIAL only)

- Minimal, scoped fixes — no drive-by refactors.
- Group into logical commits: one per theme, not one per comment, unless asked.
- Reference the PR in the message, e.g.
  `fix(review): address X as suggested in PR #123 review`.
- Never `--amend` or `--no-verify`.

## Step 5: Reply to Every Comment

**Non-negotiable: every comment from Step 2 gets a reply — declined and bot
comments included.** `references/reply-templates.md` has the POST shapes (inline
thread vs top-level) and the four body templates (Accepted / Accepted-with-modification
/ Declined / Question); reply in the reviewer's language.

## Step 6: Push & Clear `🚫 Blocked`

- **Push** any fix commits: `git push` (never force-push unless the user asked);
  report new commit SHAs with the reply summary.
- **Clear the label** when ≥1 ACCEPT / ACCEPT-PARTIAL was applied **and** commits
  were actually pushed: `gh pr edit <N> --remove-label "🚫 Blocked"`. The board
  card stays **In review**, ready for re-review.
  - Skip silently if the label isn't attached, or if
    `gh label list --search "🚫 Blocked"` is empty (label not set up in this repo).
  - All comments DECLINE/QUESTION (nothing pushed) → leave the label; the blocker
    stands until the reviewer relents or a fix lands in a later turn.
    `gh-pr-approve` re-attaches it if a fresh blocker emerges on re-review.

## Step 7: Report

Print a scannable table:

```
PR #123 review comments processed: 5 total
  Accepted: 3 (commits abc1234, def5678)
  Declined: 1
  Declined (out-of-scope: iOS): 0
  Answered: 1
  -> All comments replied to.
```

Include the `Declined (out-of-scope: <platform>)` row whenever the filter ran
(even at 0) so the user sees the policy was applied. List any "already replied"
skips at the bottom.

## Constraints

- **Never skip a reply** — even a one-line "Declined: out of scope"; bots included.
- Never close or resolve threads programmatically — leave that to the user.
- Never fix files outside the PR's diff without flagging it to the user first —
  that's scope creep.
- Never force-push or `--amend`. A fix needing history rewrite → stop and ask.
- Never bypass the out-of-scope filter without an explicit session override, and
  never paraphrase the canonical decline template — keep it verbatim from
  `references/out-of-scope-platforms.md` so future audits can grep for it.
