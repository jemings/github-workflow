# Out-of-Scope Platform Filter — for the gh-pr-reply skill

**Status: OPTIONAL, disabled by default.** This file is a template. If your
project supports every platform a reviewer might raise, leave it disabled —
`gh-pr-reply` skips this step and goes straight to normal classification.

Enable it only when your project genuinely has **unsupported platforms** and you
want review suggestions targeting them auto-declined with a consistent,
greppable response. The iOS / Safari / WebKit section below is a **worked
example** (e.g. an internal-only web app that never ships to iOS) — replace or
delete it to match your project.

## How it works (when enabled)

This filter runs at Step 3 of the skill, **before** classifying a comment as
ACCEPT / ACCEPT-PARTIAL / DECLINE / QUESTION. If a comment matches an
out-of-scope platform's trigger as its **primary motivation**, classify it as
DECLINE, do not apply the patch, and reply with the platform's canonical
template (below). Log one line to the user noting which platform/keyword
triggered the filter (requirement: debuggability).

To enable: tell the skill (or note in your project's CLAUDE.md) that this filter
is active, and keep the platform sections below current.

## Example platform — iOS / Safari / WebKit (web app, iOS out of scope)

**Trigger keywords** (case-insensitive, **match as whole words** on comment
body OR suggested diff content — use word-boundary matching to avoid false
positives on substrings like `studios`/`audios`/`radios` containing `ios`,
or `safarisearch`/etc.):

- `iOS`, `iPad`, `iPhone` (whole-word only — `iOS` must not match `studios`)
- `Safari`, `WebKit` (whole-word only)
- `-webkit-` vendor prefix — **only** when it appears alone or as the
  dominant prefix in the suggestion **and** is not one of the
  Chromium-supported `-webkit-` properties that are required in
  Chromium-based browsers too. Exempt (treat as normal Accept/Decline):
  `-webkit-line-clamp`, `-webkit-box-orient`, `-webkit-box`, `-webkit-scrollbar`,
  `-webkit-overflow-scrolling`, `-webkit-tap-highlight-color`,
  `-webkit-text-size-adjust`, `-webkit-appearance` and any other
  `-webkit-` property widely supported on Chromium per MDN. Also exempt:
  any suggestion that pairs `-webkit-` with `-moz-` / `-ms-` as a normal
  cross-browser compatibility set.
- `apple-touch-icon`, `apple-mobile-web-app-*` meta tags
- `viewport-fit=cover` and other iOS notch / safe-area workarounds
- iOS Safari quirks (e.g. `100vh` viewport bug workaround)

**Primary-motivation rule**: the filter fires only when an iOS/Safari concern
is the comment's main reason for existing. If the comment is fundamentally
about something else (e.g. accessibility, a real bug on a supported browser)
and merely mentions Safari in passing, run normal classification.

**Decline reply template** (keep verbatim for consistency — customize the text
to your project, then never paraphrase it):

```
Declined — iOS / Safari is out of scope for this project's supported platforms, so iOS/Safari compatibility suggestions are not applicable here. Thanks for the review.
```

Use this template verbatim once you've set it; do not paraphrase per-comment.
The reviewer-language override (Step 5 / `reply-templates.md`) does **not** apply
here — the canonical text is fixed so future audits can grep for it.

## Override path

The user may explicitly opt in for a single session with phrases like:

- "이번엔 수용", "iOS 제안 반영해줘", "이번 PR 은 iOS 도 반영"
- "accept the iOS suggestion", "apply the Safari fix anyway"

Only an **explicit one-line user instruction in the current session** counts
as override. Ambiguous phrasing → keep the Declined default. The override is
session-scoped (not persisted) and applies only to the current `/gh-pr-reply`
run.

## Logging line (Step 3)

When the filter fires on a comment, print one line to stdout for the user:

```
[out-of-scope] comment #<id> declined — platform=<name>, matched keyword=<keyword>
```

This appears in the skill's running log so the user can verify the filter
worked as intended.

## Adding another platform

Append a new section with the same shape: trigger keywords, primary-motivation
rule, verbatim decline template, override phrasing. Keep the structure uniform
so the classifier logic in Step 3 stays a single pass over platforms.
