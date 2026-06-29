# Board Setup

The `github-workflow` skill suite drives one **organization-scoped GitHub Project
(v2)** with a single-select `Status` field. This page gets that board ready.

## Prerequisites

```bash
gh auth login                 # if not already
gh auth refresh -s project    # the board API needs the 'project' scope
gh auth status                # confirm: should list the 'project' scope
```

You also need `jq`. The Project must be owned by an **organization** you can admin
(user-owned Projects aren't supported — see the README's Limitations).

## Option A — helper script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-board.sh" \
  --owner <your-org-login> \
  --title "My Workflow Board" \
  --repo  /path/to/your-repo
```

It will:

1. check `gh`/`jq`/auth/`project` scope,
2. create the Project (or reuse one with `--number <N>`),
3. verify the `Status` field options and tell you which to fix (the next section),
4. write `.github-workflow.config` into `--repo` with the owner/number.

To reuse an existing board instead of creating one:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-board.sh" --owner <org> --number <N> --repo /path/to/your-repo
```

## Option B — manual

```bash
# Create the Project under your org
gh project create --owner <your-org-login> --title "My Workflow Board"
# → note the project number N (also visible at the URL below)
```

Your board lives at `https://github.com/orgs/<org>/projects/<N>`.

## Status field options (required, manual)

GitHub's API cannot reliably edit the built-in `Status` single-select options, so
set them in the UI. Open:

```
https://github.com/orgs/<org>/projects/<N>/settings
```

Edit the **Status** field so its options are **exactly these six, in this order**:

```
Backlog
Ready
In progress
In review
Approved
Done
```

Spelling and casing matter — the functions match option names literally
(`"In progress"`, `"In review"` are lower-case after the first word). Delete any
leftover defaults (`Todo`, etc.).

Verify:

```bash
gh project field-list <N> --owner <org> --format json \
  | jq -r '.fields[] | select(.name=="Status") | .options[].name'
```

## Disable two built-in workflows

At `https://github.com/orgs/<org>/projects/<N>/workflows`, **disable**:

- **Code changes requested** — otherwise CHANGES_REQUESTED drags a PR to
  `In progress`, breaking the "blocked PRs stay In review" rule.
- **Pull request linked to issue** — otherwise moving a PR card drags its linked
  issue card, breaking the Issue/PR independent tracks.

Leave the others enabled (Auto-add, Auto-archive, Auto-close issue, Code review
approved, Item added/closed, Pull request merged). `claude-audit-builtin-workflows`
warns on stderr if either of the two above is still enabled.

## Optional — labels

Labels are optional; every label step silently skips a label that doesn't exist.
If you want the suite's conventions, create them (see
[github-integration.md §Labels](github-integration.md#labels)) — e.g. severity
(`🔥 Critical`, `⚡ High`, `🔼 Medium`), the PR blocker labels (`🚫 Blocked`,
`🔴 CI fail`), the model-tier labels (`pro-friendly`, `max-only`), and your hold
label (default `보류`, configurable via `CLAUDE_BLOCKED_LABELS`).

## Confirm it works

```bash
export CLAUDE_PROJECT_OWNER=<org> CLAUDE_PROJECT_NUMBER=<N>   # or use .github-workflow.config
source "${CLAUDE_PLUGIN_ROOT}/scripts/github-workflow.sh"
claude-board-status            # should print the board grouped by Status
```

If you see `Project 메타데이터 조회 실패 (project_id=null)`, re-check the
`project` scope and the owner/number. If you see `'Status' 필드 ... 없습니다`,
the Status field is missing or renamed. If a transition reports an unknown
`Status 옵션`, the six options above aren't set exactly.
