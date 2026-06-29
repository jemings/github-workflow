# github-workflow

A Claude Code **plugin marketplace** for issue-driven GitHub work, backed by a
GitHub Project (v2) board. One plugin (`github-workflow`) bundles four skills, the
shell functions they call, and the policy/setup docs — so anyone can install and
run it independently.

| Skill              | What it does                                                                 |
| ------------------ | --------------------------------------------------------------------------- |
| **github-workflow** | Start/finish issue-based work sessions: pick next issue → dependency gate → worktree-isolated branch → `In progress` → test/commit/push → PR (`Closes #N`) → `In review`. Supports stacked PRs. |
| **gh-pr-reply**    | Fetch a PR's review comments (humans + bots), apply valid fixes, reply to every thread. |
| **gh-pr-approve**  | Review a colleague's PR, then approve or request changes and file follow-up issues. |
| **gh-triage**      | Triage Backlog issues — promote ready ones, enhance with code exploration, split, or ask for clarification. |

The skills share `scripts/github-workflow.sh` (the function SSOT) and a single
GitHub Project board with a six-state `Status` field:

```
Backlog · Ready · In progress · In review · Approved · Done
```

## Prerequisites

- **[GitHub CLI](https://cli.github.com)** authenticated, with the `project`
  scope: `gh auth login` then `gh auth refresh -s project`.
- **`jq`**, **`git`**, **`bash` 4+**.
- An **org-scoped GitHub Project (v2)** with a single-select `Status` field whose
  options are exactly the six above. Create/configure it with
  [`docs/board-setup.md`](plugins/github-workflow/docs/board-setup.md) or the
  helper `scripts/setup-board.sh`.
- Optional: `shellcheck` (push-time lint of any shell scripts), `actionlint`
  (workflow lint).

> **Scope note:** the board functions query `organization(login: …)`, so the
> Project must be **organization-owned**, not user-owned. See [Limitations](#limitations).

## Install

In Claude Code:

```text
/plugin marketplace add jemings/github-workflow
/plugin install github-workflow@github-workflow
```

Then reload plugins (`/reload-plugins`) if prompted. The skills are invoked as
`/github-workflow:github-workflow`, `/github-workflow:gh-pr-reply`,
`/github-workflow:gh-pr-approve`, `/github-workflow:gh-triage` — or auto-trigger
from natural-language requests (see each skill's description).

## Set up the board

Pick one:

**A. Helper script** (creates the Project, writes the per-repo config, and tells
you which `Status` options to set):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-board.sh" --owner <your-org> --title "My Board" --repo /path/to/your-repo
```

**B. Manual** — follow [`docs/board-setup.md`](plugins/github-workflow/docs/board-setup.md).

## Configure

The functions need to know your board. Resolution order (first wins):

1. Environment: `export CLAUDE_PROJECT_OWNER=<org> CLAUDE_PROJECT_NUMBER=<n>`
2. A `.github-workflow.config` file at the **root of the repo you run in** (copy
   [`.github-workflow.config.example`](.github-workflow.config.example) and fill it).

If neither is set, the first board call prints a clear setup message and stops.
Full options (hold labels, local CI hook): [`docs/configuration.md`](plugins/github-workflow/docs/configuration.md).

## Use

Load the functions once per session, then drive the workflow:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/github-workflow.sh"

# main worktree
claude-next-issue                 # pick the next pro-friendly issue
claude-check-deps <N>             # verify "Depends on #N" are closed/merged
claude-enter-issue <N>            # self-assign + create .claude/worktrees/issue-<N> + branch

# in the issue worktree
claude-start-issue <N>            # Status → In progress
# ... do the work ...
claude-close-issue <N> <type> "<description>"   # test → commit → push → PR (Closes #N) → In review

# main worktree, after merge
claude-cleanup-worktree <N>       # remove the worktree
```

Policy details (board transitions, labels, closing keywords, worktree rules) live
in [`docs/github-integration.md`](plugins/github-workflow/docs/github-integration.md).

## Push-time checks

Before creating a PR, `claude-close-issue` runs a **best-effort lint guard**
(`shellcheck` on tracked `*.sh`/`*.bash` if installed; `actionlint` if installed)
and an optional **local CI gate**. Builds/tests are project-specific, so the gate
is pluggable — set `CLAUDE_LOCAL_CI_CMD` or add `.github-workflow/local-ci.sh`.
See [`docs/configuration.md`](plugins/github-workflow/docs/configuration.md).

## Repository layout

```
.claude-plugin/marketplace.json        # marketplace catalog
.github-workflow.config.example        # per-repo board config template
plugins/github-workflow/
├── .claude-plugin/plugin.json
├── skills/
│   ├── github-workflow/SKILL.md
│   ├── gh-pr-reply/   (SKILL.md + references/)
│   ├── gh-pr-approve/ (SKILL.md + references/)
│   └── gh-triage/SKILL.md
├── scripts/
│   ├── github-workflow.sh             # function SSOT
│   ├── test-github-workflow.sh        # pure-helper unit tests
│   ├── shgwt.sh                       # git worktree spawn/teardown helper
│   ├── test-shgwt.sh
│   └── setup-board.sh                 # board bootstrap helper
└── docs/
    ├── github-integration.md          # policy SSOT
    ├── board-setup.md                 # board creation + Status field
    └── configuration.md               # env vars, config file, local CI hook
```

## Develop / test

```bash
cd plugins/github-workflow/scripts
bash test-github-workflow.sh   # pure-helper unit tests (no network)
bash test-shgwt.sh             # worktree helper tests
shellcheck -x -S warning github-workflow.sh shgwt.sh setup-board.sh
```

## Limitations

- **Org-scoped Projects only.** All board queries use `organization(login: …)`;
  user-owned Projects aren't supported yet.
- The board's six `Status` options must match exactly — GitHub's API can't reliably
  edit the built-in `Status` options, so that step is manual (the helper verifies
  and guides you).

## License

[Apache-2.0](LICENSE).
