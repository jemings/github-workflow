# Review Criteria — for gh:pr-approve skill

## Three comment endpoints (fetch all)

Bot tools and humans scatter feedback across three APIs. Missing one means missing comments.

```bash
# Inline code review comments (line-anchored)
gh api "repos/<owner>/<repo>/pulls/<N>/comments" --paginate

# Top-level issue-style comments on the PR conversation
gh api "repos/<owner>/<repo>/issues/<N>/comments" --paginate

# Review summaries (bots often put content here)
gh api "repos/<owner>/<repo>/pulls/<N>/reviews" --paginate
```

For threading / dedup details see the sibling skill
`gh-pr-reply/references/comment-fetching.md` if installed.

## Review checklist

Work through each dimension; skip categories that don't apply to the diff.

1. **Correctness** — does the code do what the PR title/body says? Spot-check each changed hunk against the claim. For scripts, trace the happy path + one failure path.
2. **Conventions** — naming, file location, import order, error-handling idioms match the surrounding code. Check for any `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, or `.editorconfig` in the repo root or changed directories and apply those rules.
3. **Project Policy** — load the repo-root `CLAUDE.md`/`AGENTS.md`/`DEVELOPMENT.md` and every `.claude/**/*.md` it links from a "참조 문서" / "References" table (e.g. `.claude/workflow.md`, `.claude/github-integration.md`, `.claude/implementation.md`, `.claude/session-rules.md`). In each, scan for rules tagged with **필수 / 고정 / 금지 / 반드시 / required / must / do not / never** and compare them against the diff. A diff that violates, contradicts, or silently omits such a rule is a **설계 원칙 위반** — map it to the BLOCKER criterion below, not to a stylistic FOLLOW-UP. Repos without such root docs or referenced policy docs skip this dimension.

   **Merge strategy compatibility (BLOCKER)** — read `CLAUDE.md`/`AGENTS.md`/`DEVELOPMENT.md` "PR 머지 전략" 절 to determine the project default. Apply:
   - Default is `--rebase` (e.g. `gh pr merge <N> --rebase --auto`) **and** `rebaseable == false` → **BLOCKER**: head branch contains a merge commit; rebase merge is impossible. The author must rebase the branch onto the target without merge commits.
   - Default is `--squash` and head branch history contains multiple unrelated logical changes with no squash intent declared → **FOLLOW-UP** (or **BLOCKER** per team agreement; note in the review body).
   - Default is `--merge` → no additional gate on `rebaseable`.

4. **Security** — input validation, shell-injection (`set -euo pipefail`, quoted expansions), hardcoded secrets, unsafe `eval`, missing authn/z checks, over-broad `sudo` usage, signed-by on apt keys, etc.
5. **Performance** — obvious N+1 patterns, unnecessary I/O inside hot loops, missing caching on expensive calls. Don't over-engineer — flag only concrete wins.
6. **Tests** — are the new paths covered? If the PR touches logic (function·class·API handler·script branch), absence of unit tests for that logic is **반드시 BLOCKER** — see [명확한 오류 유형](#명확한-오류-유형--발견-시-반드시-blocker) below; FOLLOW-UP 강등 불가. Exceptions (no test required): docs-only changes (`docs/**`, `*.md`), config files (`*.json` / `*.yaml` / `*.toml`), shell-bootstrap-only changes.
7. **Docs / comments** — public API changes without doc updates, lies in comments, stale references.
8. **Backward compatibility** — breaking API/CLI/config changes flagged in the PR body? Migration path documented?

## Re-review verification (when prior comments by ME exist)

Re-review mode is the dominant case for this skill. The contract is:
**every prior concern must be accounted for**.

1. Pull the list of prior comments/reviews by `ME` from the three endpoints.
2. For each concern, locate one of:
   - A commit in the PR that resolves it (link the short SHA in the review body).
   - A follow-up issue the author opened with a back-link to the PR.
   - A reply from the author explaining why it was declined (judge: is the reasoning acceptable?).
3. Any concern with none of the above → escalate to **BLOCKER** (unresolved prior review comment).

Do not silently let a prior concern drop. That erodes trust in the review process.

## BLOCKER vs FOLLOW-UP — where to draw the line

The single decision rule is **"is there an error in this PR?"** — not "would I prefer it differently?".

### FOLLOW-UP의 전제 조건

FOLLOW-UP은 **PR에 오류가 없는 상태에서** 더 나은 구현 방향·개선 제안·의견을 트래킹하기 위한 분류다. 오류가 있는 PR에서는 FOLLOW-UP을 사용할 수 없다.

| 구분          | 판단 기준                                            | 처리                                                                                                    |
| ------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **BLOCKER**   | 오류가 있음 — 지금 머지하면 무언가 깨지거나 퇴보한다 | `--request-changes`                                                                                     |
| **FOLLOW-UP** | 오류는 없음 — 더 좋은 방법이 있을 뿐이다             | BLOCKER=0이면 이슈 생성 후 `--approve`. BLOCKER≥1이면 같은 리뷰 본문에 Suggestions로 합산 (이슈 생성 X) |
| **PRAISE**    | 칭찬할 만한 구체적 포인트                            | `--approve` 본문에 포함                                                                                 |

### "오류가 있으면 BLOCKER — FOLLOW-UP으로 강등 불가"

이 규칙은 별도 항목으로 분리되어 있으며 협상 대상이 아니다. 명백한 오류를 "나중에 고쳐도 되겠지" 판단으로 FOLLOW-UP으로 강등하면 작성자는 머지 후에도 오류를 인지하지 못하고, 이슈 백로그에는 같은 PR에 대한 중복 이슈가 재생성된다.

### 명확한 오류 유형 — 발견 시 반드시 BLOCKER

아래 유형 중 **하나라도** 해당하면 **반드시 BLOCKER로 분류**한다. FOLLOW-UP으로 강등 불가.

- **로직 버그** — 코드가 PR 제목/설명과 다르게 동작하거나, 분기 조건이 반전되어 있거나, 명세된 결과를 산출하지 못함
- **보안 취약점** — 인젝션(shell·SQL·command), 노출된 시크릿, 인증/인가 누락, 미검증 입력값을 권한 경계 너머로 전달
- **실패하는 CI 체크** — `gh pr checks`에서 required check 가 FAILURE/CANCELLED 상태. **예외: stale rebase 회귀** — 아래 두 조건을 모두 충족하면 BLOCKER 가 아니라 [**4d 경로** (`SKILL.md` §Step 4 — comment-only notice)](#stale-rebase-회귀-탐지)로 라우팅한다 (작성자에게 rebase 권장만 남기고 머지 차단은 보류).
  1. `git fetch <remote> <baseRefName>` 후 `git merge-base --is-ancestor "<remote>/<baseRefName>" "<PR head SHA>"` 가 비-0 반환 — 즉 PR head 가 base 의 최신 commit 을 ancestor 로 포함하지 않음 (`<remote>` 는 SKILL.md Step 1 arg #2, default `origin`)
  2. fail 한 CI check 가 손대는 파일/경로가 `gh pr diff <N> --name-only` 결과와 겹치지 않음 — 즉 회귀 원인이 PR 자체의 diff 가 아님
- **미해결 선행 리뷰 코멘트** (re-review 모드) — 직전 리뷰의 concern 이 후속 commit·이슈·납득 가능한 거절 사유 중 어느 것으로도 처리되지 않음
- **로직 변경 시 unit test 누락** — PR 이 함수·클래스·API 핸들러·스크립트 분기 등 로직 경로를 생성하거나 수정했으나 해당 로직을 검증하는 unit test 가 없거나 추가되지 않은 경우. 예외: 순수 문서(`docs/**`, `*.md`), 설정 파일(`*.json` / `*.yaml` / `*.toml`), shell bootstrap 스크립트 단독 변경. 신규 로직의 테스트 누락은 "테스트 누락 회귀"가 아니므로 별도 항목으로 명시 — 회귀 케이스와 동일하게 FOLLOW-UP 강등 불가
- **공식 approve 불가 사례** — repo 가 `.claude/github-integration.md` 등에서 선언한 차단 사유 (보안·데이터 손실·명백한 로직 버그·테스트 누락 회귀·설계 원칙 위반). "Project Policy" 체크리스트에서 발견한 위반은 정의상 "설계 원칙 위반"이므로 여기에 포함

### 통상 분류 절차

위 강제 목록에 해당하지 않는 finding 은 다음 질문으로 분류한다 — _"If the author merged this PR right now, would something break or regress?"_

- **Yes** → BLOCKER. 강제 목록 누락 케이스(예: API break without migration, 명세된 invariant 깨뜨리는 변경)
- **No, but the team would want it tracked** → FOLLOW-UP. 예시: 더 나은 리팩터, 트리거되지 않는 경로의 테스트 커버리지 갭, doc 문구 개선, 미래 edge case 용 TODO, 주변 코드와의 사소한 idiom 불일치
- **No and too small to track** → PRAISE 또는 무시. 사소한 의견을 이슈로 만들지 말 것 — 노이즈가 쌓이면 팀이 이슈를 무시하기 시작한다

When in doubt between FOLLOW-UP and ignore: file it if you can state, in one sentence, the concrete harm of leaving it. Otherwise drop it.

## Praise is part of the review

Approvals without specifics ("LGTM!") teach authors nothing. Every approval body should include ≥1 compliment anchored to a file:line or commit SHA. Examples:

- `set -euo pipefail` + `pipefail`-aware piping in `scripts/install.sh:2`
- `BASH_SOURCE` anchoring for idempotent lock files at `b665789`
- Table in `setup.md` making the lock-file convention discoverable

Generic praise ("great job!", "looks good!") is worse than none — it signals a skimmed review.

## Doc PRs with a different audience

`docs/**` (human-facing) and `.claude/**` (AI-facing) often coexist and can drift. When a `docs/**` change describes a workflow that contradicts or omits a rule declared in `.claude/**`:

- Honor the document's **declared audience** first (check the README or front-matter — e.g. "이 가이드는 외부 컨트리뷰터 대상").
- **Audience = project contributor / maintainer** → the doc is expected to mirror internal rules. Missing a 필수 step (e.g. `git fetch origin main && git rebase origin/main` from `.claude/implementation.md` "PR 생성 전 선행 조건") is a **BLOCKER**.
- **Audience = external / non-expert** → pedagogical simplification is allowed, but a simplification that _induces a policy violation_ (e.g. fully omitting a 필수 step rather than explaining it) is still a BLOCKER. Cosmetic re-ordering or terminology changes that don't change behavior are FOLLOW-UP at most.
- **Audience unclear** → do not guess. Submit a `--comment` review asking the author to declare the target audience, then re-evaluate after they reply. Do not approve in this state.

## Stale rebase 회귀 탐지

CI fail 의 원인이 PR 의 diff 가 아니라 main 의 후속 commit 과의 stale-rebase 인 경우, 작성자에게 BLOCKER 책임을 전가하지 않는다. 절차는 [명확한 오류 유형 — 실패하는 CI 체크](#명확한-오류-유형--발견-시-반드시-blocker)의 예외 두 조건을 그대로 따른다. 두 조건이 모두 충족되면:

- 분류는 **BLOCKER 아님 · FOLLOW-UP 아님 · 정보성 노티**. SKILL.md §Step 4 의 **4d 경로** (`approval-templates.md` §6d) 로 처리한다 — `gh pr comment` 또는 `gh pr review --comment` 로 rebase 권장만 남기고 review submission (approve / request-changes) 는 생략.
- 한 조건이라도 미충족이면 (PR head 가 최신이거나 fail 이 PR diff 와 직접 관련) 기존 BLOCKER 강제를 유지한다.

### 조건 2 ("path 겹치지 않음") 검증 휴리스틱

조건 2 는 비교 단위가 모호하면 false-negative (실제로는 PR diff 가 원인인데 stale 로 강등) 또는 false-positive (디렉토리 기준으로 보면 겹친다고 잘못 판단해 BLOCKER 유지) 가 발생한다. **파일 단위**로 비교한다 — 디렉토리 단위 비교는 인접 파일이 같은 디렉토리에 있다는 이유만으로 강등을 막아 reviewer 가 매번 수동 추론해야 한다.

1. fail 한 job 의 출력에서 stack 의 파일 경로를 추출 + 정규화:

   ```bash
   gh run view --job <fail-job-id> --log-failed \
     | grep -oE '[^[:space:]]+\.(ts|tsx|js|jsx|py|go|sh|md)(:[0-9]+)?' \
     | sed -E 's/^[^A-Za-z0-9_./-]+//; s|^\./||; s/:[0-9]+$//' \
     | sort -u
   ```

   파일 확장자는 repo 의 실제 언어 셋에 맞춰 조정한다. `sed` 단계가 (a) 선행 punctuation (`[`, `(`, `<` 등 stack trace 장식), (b) `./` 접두사, (c) 라인 번호를 제거해 PR diff 출력과 같은 repo-relative 경로 형식으로 맞춘다.

2. PR diff 의 파일 목록을 가져와 비교 (`gh pr diff` 는 `--name-only` 미지원이라 `gh pr view --json files` 사용):

   ```bash
   gh pr view <N> --json files --jq '.files[].path' | sort -u
   ```

3. 두 집합이 **완전히 disjoint (교집합 ∅)** 이면 조건 충족 → 4d 경로. 한 파일이라도 겹치면 stale 로 강등하지 않고 BLOCKER 유지. `comm -12 <(...1번...) <(...2번...)` 가 비어 있는지로 확인할 수 있다.

job → 검사 path 의 정적 매핑 표를 두는 대안 (예: `e2e (playwright smoke)` → `frontend/e2e/**`) 은 reviewer 의 매 PR 추론 부담을 줄이지만, job 추가/변경 시 매핑 갱신 부담이 생긴다. 본 휴리스틱은 매핑 없이도 동작하므로 기본 절차로 채택한다.

GitHub branch protection 을 사용하지 않는 환경에서는 "required check" 의 정의 자체가 advisory 다. 그래도 `_명백히 PR diff 가 원인인_` CI fail 은 여전히 BLOCKER — 위 강등은 _stale rebase_ 케이스에만 적용한다. CI 실패 차원의 정의·가시화 채널(`🚫 Blocked` · `🔴 CI fail` 라벨 등)은 이 스킬 묶음의 정책 문서 `${CLAUDE_PLUGIN_ROOT}/docs/github-integration.md` 를 따른다 (라벨 미설정 repo 는 silent skip).

## Self-review guard

Before submitting: if the PR author's login equals `ME`, stop. GitHub itself will reject the approval, but the skill should fail fast with a clear message rather than let `gh pr review` error out.
