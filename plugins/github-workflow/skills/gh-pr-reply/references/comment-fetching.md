# Comment Fetching — for gh:pr-reply skill

PRs expose review feedback through three distinct API endpoints — all must be
queried. Missing any one of them means missing comments (bots especially tend
to scatter content across these endpoints).

## The three endpoints

```bash
# Inline code review comments (line-anchored)
gh api "repos/<owner>/<repo>/pulls/<N>/comments" --paginate

# Top-level issue-style comments on the PR conversation
gh api "repos/<owner>/<repo>/issues/<N>/comments" --paginate

# Review summaries (bots often put content here)
gh api "repos/<owner>/<repo>/pulls/<N>/reviews" --paginate
```

## Fields to extract per comment

- `id` — comment identifier (needed for replying)
- `user.login` — author (including bots: gemini-code-assist, sourcery-ai, copilot)
- `path` — file the comment is anchored to (inline comments only)
- `line` — line number in the file (inline comments only)
- `body` — comment text
- `in_reply_to_id` — parent comment id, for threading
- `html_url` — link back to the comment on GitHub

## Deduplication rule

Skip a thread only if the **latest** comment in the thread is authored by
the current user or by Claude. This allows the skill to respond when a
reviewer leaves a follow-up comment after a previous Claude reply.

Algorithm:

1. Build threads by chaining `in_reply_to_id` from each comment back to its
   root (comments with `in_reply_to_id == null`).
2. For each thread, sort descendants by `created_at`.
3. Look at the last (most recent) comment. If its `user.login` is the
   current user or Claude, skip the thread. Otherwise process it.

Exception: if the user explicitly asks to re-process, ignore this filter and
reply to everything fresh.

## Review summaries

`/pulls/<N>/reviews` entries have no line anchor and no `replies` sub-resource.
Handle each review summary as follows:

- **Actionable content** (reviewer wrote a critical concern in the summary
  body itself, not just linking to inline comments): post a new top-level
  issue comment that blockquotes the review summary and addresses it, using
  the top-level reply shape from `reply-templates.md`.
- **Meta content** (summary just recaps the inline comments, or is a service
  notice like "your repo doesn't have access to X"): no reply needed; note
  it in the Step 7 report as "skipped (meta summary)".

Judgment: if deleting the summary would lose information not already
captured in an inline comment, it is actionable.
