# GitHub Integration — Policy SSOT

This is the single source of truth for the **policy** behind the `github-workflow`
skill suite: board-state transitions, label semantics, worktree isolation, session
preemption, and closing-keyword rules. Function implementations live in
[`../scripts/github-workflow.sh`](../scripts/github-workflow.sh).

It assumes one **org-scoped GitHub Project (v2)** with a single-select `Status`
field. Configure the board with [board-setup.md](board-setup.md) and point the
skill at it via `CLAUDE_PROJECT_OWNER` / `CLAUDE_PROJECT_NUMBER`
(see [configuration.md](configuration.md)).

## Board model

`Status` field options (single-select, in order):

```
Backlog · Ready · In progress · In review · Approved · Done
```

**Issue and PR are independent tracks.** `In review` / `Approved` are PR-card
only; issues go `In progress` → `Done` directly.

| Transition          | From                     | To            | Trigger                                                       | Target |
| ------------------- | ------------------------ | ------------- | ------------------------------------------------------------ | ------ |
| Issue created       | —                        | `Backlog`     | `claude-create-issue` (or built-in "Item added to project")  | Issue  |
| Promote to Ready    | `Backlog`                | `Ready`       | `claude-create-issue` / `claude-register-related-issue`, or `claude-set-issue-status <N> "Ready"` | Issue |
| Session start       | `Backlog` / `Ready`      | `In progress` | `claude-start-issue`                                          | Issue  |
| PR created          | —                        | `In review`   | `claude-close-issue` → `claude-set-pr-status`                | PR     |
| PR approved         | `In review`              | `Approved`    | built-in "Code review approved" workflow                     | PR     |
| PR merged — issue   | `In progress`            | `Done`        | `Closes`/`Fixes #N` closing keyword                          | Issue  |
| PR merged — PR      | `Approved` / `In review` | `Done`        | built-in "Pull request merged" workflow                      | PR     |

**Principles:**

- State transitions are always performed by a script function or a built-in
  Project workflow. If you create a PR by hand, run
  `claude-set-pr-status <pr-number> "In review"` to align the board.
- If a card isn't on the Project yet, the transition functions add it first,
  then set the status (idempotent).
- The Project API needs the `project` scope on your `gh` token
  (`gh auth refresh -s project`).
- **`Approved` has a single meaning:** `claude-set-pr-status <pr> "Approved"`
  refuses unless `gh pr view <pr> --json reviewDecision` is `APPROVED`
  (fail-closed).

### Built-in Project workflows

GitHub Projects ship built-in automation. Two of them **must be disabled**
because they fight the Issue/PR independent-track model — `claude-audit-builtin-workflows`
prints a stderr warning if it detects them enabled:

| Built-in workflow            | Policy            | Why                                                                                       |
| ---------------------------- | ----------------- | ---------------------------------------------------------------------------------------- |
| Auto-add to project          | keep              | idempotent                                                                                |
| Auto-add sub-issues          | keep              | convenience                                                                               |
| Auto-archive items           | keep              | archive Done cards after N days (keeps the board's indexed item count under limits)       |
| Auto-close issue             | keep              | closes the issue when Status → Done                                                       |
| Item added to project        | keep              | new items default to `Backlog`                                                            |
| Item closed                  | keep              | issue → `Done` after a closing keyword fires                                              |
| Code review approved         | keep              | APPROVED review → PR Status `Approved` (matches the single-meaning rule above)            |
| Pull request merged          | keep              | merged PR → `Done`                                                                        |
| **Code changes requested**   | **disable**       | moves a PR to `In progress` on CHANGES_REQUESTED — violates "keep blocked PRs In review"  |
| **Pull request linked to issue** | **disable**   | moving a PR card drags its linked issue card → breaks the Issue/PR independent tracks     |

Disable them at `https://github.com/orgs/<owner>/projects/<number>/workflows`.

## Issue creation

Every new issue that needs milestone application + Ready promotion + checklist
registration is created through one of two entry points — never `gh issue create`
directly (the wrappers do the post-creation board handling):

| Entry point                               | When                                          | Behavior                                                       |
| ----------------------------------------- | --------------------------------------------- | ------------------------------------------------------------- |
| `claude-register-related-issue "<title>"` | a related issue discovered mid-session        | Backlog dedup check + `Related: #N` body + milestone/Ready/checklist |
| `claude-create-issue [gh opts…]`          | every other context                           | no dedup; milestone/Ready/checklist only                      |

**Body should include:** a clear title, Acceptance Criteria, and the affected
files/modules. Express dependencies with `Depends on #<N>`.

### Backlog dedup (mandatory)

Before creating an issue, search existing `Backlog`/`Ready` OPEN issues once
with `claude-find-similar-issues`:

- no match → create.
- strong match (score ≥ 2) → add context as a comment to the existing issue.
- weak match (score 1) → ask the user once; if creating, link `Related: #N`.
- search failure → proceed, but append _"backlog dedup failed — manual check
  recommended"_ to the body.

### References in issue bodies

Point at code with **section heading + permalink**, not bare line numbers:

| | Bad | Good |
| --- | --- | --- |
| Form | `path/to/file:1-56` | `path/to/file §Section` + permalink |
| Permalink | — | `https://github.com/<owner>/<repo>/blob/<SHA>/<path>#Lx-Ly` |

SHA = the HEAD at issue-creation time (`git rev-parse HEAD`).

## Sessions

**Isolation principle:** each issue is worked in a dedicated git worktree under
`.claude/worktrees/issue-<N>/`.

```bash
# --- in the main worktree ---
gh pr list --search "review-requested:@me" --state open    # review-first
claude-next-issue [pro|max]                                # pick next issue
claude-check-deps <issue-number>                           # verify dependencies
claude-enter-issue <issue-number>                          # self-assign + worktree + branch
claude-enter-issue <issue-number> <parent-pr-or-branch>    # stacked child (optional)

# --- session enters the worktree (EnterWorktree, or: cd .claude/worktrees/issue-<N>) ---
claude-start-issue <issue-number>                          # context + Status "In progress"
```

### Session preemption

- Current branch is `main` (no `issue-` prefix) → `claude-enter-issue` creates a
  worktree and moves the session there.
- Current branch is `issue-<N>-<slug>` → already bound to issue #N. Under the
  **one-session-one-issue** rule, no further issue lookup/assignment happens.

### Worktree isolation rules

| Function                  | Allowed location        |
| ------------------------- | ----------------------- |
| `claude-next-issue`       | main worktree           |
| `claude-check-deps`       | anywhere (read-only)    |
| `claude-enter-issue`      | **main branch only**    |
| `claude-start-issue`      | **issue worktree only** |
| `claude-close-issue`      | issue worktree          |
| `claude-cleanup-worktree` | **main branch only**    |
| `claude-adopt-worktree`   | **main worktree only**  |

### Review-first policy

Before starting issue work, handle any review-requested PRs first (use the
`gh-pr-approve` skill). Don't approve over: security holes, data-loss risk,
clear logic bugs, missing-test regressions, or project-policy violations.

## Closing keywords

```bash
# --- in the issue worktree ---
source "${CLAUDE_PLUGIN_ROOT}/scripts/github-workflow.sh"
claude-close-issue <issue-number> <type> "<description>"   # test → commit → push → PR "In review"
claude-wait-bot-review <pr-number>                         # wait for bot review, then gh-pr-reply

# --- back in the main worktree, after merge ---
claude-cleanup-worktree <issue-number|pr-number>          # remove the worktree
```

- Use `Closes #N` (default) or `Fixes #N` (bug fix). Do **not** use `Resolves #N`.
- **Never `Refs #N`** in a PR meant to close an issue — it doesn't populate
  `closingIssuesReferences`, so issue auto-close + board Done + PR↔Issue linking
  all silently fail. (`claude-ref-issue` uses `Refs #N` deliberately, to attach a
  PR to an issue *without* closing it.)
- If the issue can't be closed yet, split the remaining work into a new issue and
  close the original with `Closes #N`.

## Labels

Labels are **optional** — every label-applying step silently skips when the label
doesn't exist in the repo (`gh label list` is empty for it). Define the labels you
want and the skill will use them. The conventions below are what the suite
understands.

### Severity (priority, at most one per card)

| Label       | Meaning                                  |
| ----------- | ---------------------------------------- |
| 🔥 Critical | respond immediately                      |
| ⚡ High     | next milestone, high priority            |
| 🔼 Medium   | normal priority                          |

Ordinary issues get **no** severity label (= "normal"). Custom `type:*` labels for
your own domain (at most one per card) work the same way.

**Severity propagation to PRs:** `claude-apply-pr-labels <base> <pr#>` copies the
closing issue's severity onto the PR at creation time (highest one only if a PR
closes several issues; none if the issue has none). `gh-pr` / `claude-close-issue`
/ `claude-ref-issue` call it after creating a PR.

### `🚫 Blocked` (PR blocked, distinct from `🔴 CI fail`)

| Reason                                            | Cleared when                       |
| ------------------------------------------------- | ---------------------------------- |
| dependency open — a `Depends on #N` issue/PR open | the dependency is CLOSED/MERGED    |
| review blocker — a blocking change request        | addressed and re-approved          |

When CHANGES_REQUESTED or an unmet dependency blocks a PR, attach `🚫 Blocked`
and **keep** the board Status at `In review` (the `In progress` column is for
issue cards). CI failures are a separate, orthogonal `🔴 CI fail` dimension.
`gh-pr-approve` attaches `🚫 Blocked`; `gh-pr-reply` removes it once a fix lands.
(These can be driven by your own GitHub Actions on `pull_request_review` /
`workflow_run` triggers — optional; nothing in the skill requires them.)

### Hold label (`CLAUDE_BLOCKED_LABELS`, default `보류`)

An issue carrying a hold label is **refused** by `claude-enter-issue` before any
worktree spawn / self-assign / model call — so a deliberately-deferred issue never
burns tokens. Configure the label name(s) via `CLAUDE_BLOCKED_LABELS` (a bash
array; default `("보류")`).

**Hold vs `🚫 Blocked`:** `🚫 Blocked` is an *external* block (CI/review/dependency)
that clears automatically; a hold is a *deliberate* deferral that clears only by
removing the label. They can coexist.

**Guard behavior:** no worktree, no branch, no self-assign, zero tokens — just a
stderr message + `return 1`. Checked once at entry; a label added mid-session does
not abort the running session.

**Release procedure:**

1. Re-read the issue and confirm the hold reason is resolved.
2. `claude-unhold-issue <N>` removes the label (REST DELETE per label name —
   idempotent; 404 treated as success).
3. `claude-enter-issue <N>` again.

There is **no escape hatch** env var — removing the label is the procedure that
records the reason was resolved.

## Issue size (optional model-tier labels)

`claude-next-issue` defaults to showing issues labeled `pro-friendly`. Use
`claude-next-issue max` (or `gh issue list`) to see everything.

| Label          | Meaning                                  |
| -------------- | ---------------------------------------- |
| `pro-friendly` | completable in a single session          |
| `max-only`     | large refactor / multi-file change       |

## Command summary

Full reference: [`../scripts/github-workflow.sh`](../scripts/github-workflow.sh).

```text
source "${CLAUDE_PLUGIN_ROOT}/scripts/github-workflow.sh"

# --- main worktree ---
claude-next-issue [pro|max]                 → pick next issue
claude-check-deps <issue-number>            → verify dependencies
claude-enter-issue <issue-number>           → self-assign + worktree + branch
claude-cleanup-worktree <issue|pr-number>   → remove worktree after merge

# --- issue worktree ---
claude-start-issue <issue-number>           → context + Status "In progress"
claude-close-issue <issue-number> <type> "<description>"  → test → commit → PR + "In review"
claude-register-related-issue "<title>" [keyword…]        → milestone-aware related issue
```
