# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Kamandar — a personal, single-user GitHub "command center" CLI. One command prints your current GitHub work queue (reviews owed, draft WIP, assigned-not-started issues, stale PRs). Ruby, **stdlib only — no gems, no Gemfile, no bundler**. Requires Ruby 3.2+. Serverless: no server, DB, or OAuth.

## Commands

```sh
ruby test/test_kamandar.rb          # run the full acceptance suite (zero network)
ruby lib/kamandar.rb                # run CLI, terminal output (needs env vars below)
ruby lib/kamandar.rb --dashboard    # full-screen Matrix TUI (rain splash; r=refresh, q=quit)
ruby lib/kamandar.rb --browser      # render + open static HTML page
ruby lib/kamandar.rb -b --watch 60  # live browser tab, re-fetch every 60s
```

Required env to actually run (not needed for tests): `GITHUB_TOKEN` (classic PAT: `repo, read:org, read:project`), `GH_LOGIN`. Optional: `PROJECT_URL` (enables bucket #3), `STALE_DAYS`, `DAY_MODE`, `NOT_STARTED_STATUSES`, `ITERATION_FILTER`, `ITERATION_FIELD`. See the README config table or the header comment in `lib/kamandar.rb`.

No single-test runner — the suite is a hand-rolled harness (`check`/`ok` helpers), not Minitest/RSpec. Comment out cases or add a guard to isolate one.

## Architecture

Everything lives in one file: `lib/kamandar.rb`. Layers are Ruby modules, ordered **Engine → buckets → Surface**:

- **`Engine`** — pure, side-effect-free: no network, no ENV, no I/O. Time math, GraphQL query *strings*, and all classification. Operates on **raw GraphQL node hashes (string keys)** so the same code classifies fixtures and live data. This is the unit-testable core.
- **buckets** — a plain hash `Engine.classify` returns. **The bucket set depends on scope** (`config[:scope][:mode]`): `project` is board-driven (`classify_project` → `{reviews_owed, wip, assigned_not_started, in_review, in_qa, blocked, stale, forgot_reviewer}`); every other scope is issue+PR driven (`classify_issue` → `{reviews_owed, assigned_todo, assigned_wip, assigned_review, assigned_no_reviewer, stale}`, classified by each assigned issue's linked-PR state via `issue_pr_state`). `Engine.bucket_meta(mode)` returns the ordered metadata for that mode (`BUCKETS_PROJECT` / `BUCKETS_ISSUE`); both surfaces iterate it. `Engine::BUCKETS` aliases the project set.
- **`Surface` / `TerminalSurface` / `BrowserSurface`** — consume buckets only; never re-query or re-classify. Contract is `render(buckets, ...) -> String` + `emit`. Adding email/menubar = new surface, **no engine change**.
- **`GitHub`** — the *only* network layer (`Net::HTTP` → GraphQL). `Config` resolves ENV + CLI flags (flags win). `CLI` is the only place with side effects + ENV.

The whole file is guarded by `if __FILE__ == $PROGRAM_NAME` at the bottom, so `test/` can `require` it without running or reading ENV.

## Conventions specific to this repo

- **Keep the engine pure.** `today:` and `mode:` are injected as args (never `Time.now` inside Engine) — that's what makes the suite deterministic with a fixed "today" (Monday 2026-06-22). Preserve that when editing classification.
- **Stdlib only.** Do not add gems or a Gemfile. A new dependency breaks the project's core constraint.
- Tests are the **spec of record** (`test/test_kamandar.rb` header says so). Behavior changes should update tests alongside.
- The browser surface renders **one self-contained HTML file** (inline CSS, no CDN/external assets, no `<script src>`, works over `file://`). Tests assert these properties (#13f–h) and that **no token ever reaches the HTML** (#14). Don't introduce external assets or pass secrets into `render`.

## Bucket #7 (stale PRs) — the non-obvious logic

Don't key staleness off `reviewDecision` — it stays `CHANGES_REQUESTED` after the author pushes fixes, dropping the PR you most want flagged. Instead a **timestamp race** decides who holds the ball:

`handoff_at = max(last review-requested, last push, PR created)` vs `reviewer_last_action_at` (latest APPROVED/CHANGES_REQUESTED; plain COMMENTED ignored). Ball is on reviewer when `handoff > action` (or they never acted); stale when that's true, not a draft, and `days_since(handoff) >= STALE_DAYS`. Any push resets the clock by design (see `Engine.handoff_at` to change that).

## Docs

`V2.md` is a design-only roadmap (multi-provider: GitLab/Jira/Linear) — not implemented. `SECURITY.md` covers the token-never-in-HTML guarantee.
