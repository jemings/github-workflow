# Configuration

All configuration is via environment variables or a per-repo
`.github-workflow.config` file (sourced as bash by `scripts/github-workflow.sh`).
Already-exported environment variables always win over the file.

## Board (required)

| Variable                | Meaning                                                      |
| ----------------------- | ----------------------------------------------------------- |
| `CLAUDE_PROJECT_OWNER`  | Organization login that owns the Project.                   |
| `CLAUDE_PROJECT_NUMBER` | Project number (`…/projects/<N>`).                          |

Resolution order, on `source`:

1. `CLAUDE_PROJECT_OWNER` / `CLAUDE_PROJECT_NUMBER` already in the environment.
2. Otherwise, a config file is sourced if present:
   `$CLAUDE_GW_CONFIG`, else `${CLAUDE_PROJECT_DIR:-$PWD}/.github-workflow.config`.
3. Otherwise they stay empty — the first board call prints a setup message and
   returns non-zero (sourcing itself never fails).

`.github-workflow.config` example (see [`.github-workflow.config.example`](../.github-workflow.config.example)):

```bash
CLAUDE_PROJECT_OWNER="your-org-login"
CLAUDE_PROJECT_NUMBER=1
```

`CLAUDE_GW_CONFIG` lets you point at a config file outside the repo root:

```bash
export CLAUDE_GW_CONFIG="$HOME/.config/github-workflow/config"
```

## Hold labels (optional)

| Variable                 | Default     | Meaning                                                       |
| ------------------------ | ----------- | ------------------------------------------------------------ |
| `CLAUDE_BLOCKED_LABELS`  | `("보류")`  | Bash array of label names that make `claude-enter-issue` refuse an issue. |

Set it (e.g. in the config file, which is bash) to use English or multiple labels:

```bash
CLAUDE_BLOCKED_LABELS=("on-hold" "blocked")
```

See [github-integration.md §Hold label](github-integration.md#hold-label-claude_blocked_labels-default-보류).

## Local CI hook (optional)

Before pushing a PR, `claude-close-issue` runs a local CI gate. Builds and tests
are project-specific, so the actual command is **pluggable**. Resolution order:

1. `CLAUDE_LOCAL_CI_CMD` — a command string evaluated with `bash -c`.
2. `<repo>/.github-workflow/local-ci.sh` — run with `bash` if it exists (no execute
   bit needed).
3. Neither → the gate is skipped (informational notice; remote CI is relied on).

A non-zero exit from the hook **fails the gate** and blocks the push.

The hook receives (all exported):

| Variable          | Meaning                                                                |
| ----------------- | --------------------------------------------------------------------- |
| `GW_CI_BASE_REF`  | Base ref being compared against (default `main`).                     |
| `GW_CI_CHANGED`   | Newline-separated changed files (`origin/base..HEAD` + staged + unstaged). |
| `GW_CI_WITH_UI`   | `1` if called with `--with-ui`/`--with-visual`, else `0`.             |

### Examples

Simple command:

```bash
export CLAUDE_LOCAL_CI_CMD="npm run lint && npm test"
```

Path-filtered script (`.github-workflow/local-ci.sh`, committed to your repo):

```bash
#!/usr/bin/env bash
set -euo pipefail
changed="$GW_CI_CHANGED"

if grep -qE '^frontend/' <<<"$changed"; then
  ( cd frontend && npm run typecheck && npm test )
fi
if grep -qE '^backend/' <<<"$changed"; then
  ( cd backend && pytest )
fi
if grep -qE '\.(md|json|ya?ml)$' <<<"$changed"; then
  npx prettier --check '**/*.{md,json,yml,yaml}'
fi
```

## Push-time lint guard (automatic)

Independent of the local CI hook, `claude-close-issue` runs a best-effort lint
guard before pushing:

- If the repo tracks any `*.sh`/`*.bash` files and `shellcheck` is installed →
  `shellcheck -x -S warning` on them (a violation fails the push). If `shellcheck`
  isn't installed, it warns and skips (no longer fail-closed).
- If `actionlint` is installed → run it (a violation fails the push).

To enforce stricter project-wide linting, do it in your local CI hook instead.
