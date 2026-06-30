# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Kamandar — a personal, single-user GitHub "command center" CLI. One command prints your current GitHub work queue (reviews owed, draft WIP, assigned-not-started issues, stale PRs). Ruby, **stdlib only — no gems, no Gemfile, no bundler**. Requires Ruby 3.2+. Serverless: no server, DB, or OAuth.

## Commands

```sh
ruby test/test_kamandar.rb          # run the full acceptance suite (zero network)
./install.sh                        # symlink CLI to ~/.local/bin/kamandar (run from anywhere)
ruby lib/kamandar.rb --init         # first-run wizard: verify + save token/login to config file
ruby lib/kamandar.rb                # run CLI, terminal output (needs env vars or --init below)
ruby lib/kamandar.rb --serve        # live web app on http://127.0.0.1:4567 (--port N to change)
ruby lib/kamandar.rb --serve --tunnel  # also spawn a Cloudflare Tunnel child (implies --serve)
ruby lib/kamandar.rb --dashboard    # full-screen Matrix TUI (rain splash; r=refresh, q=quit)
ruby lib/kamandar.rb --browser      # render + open static HTML page
ruby lib/kamandar.rb -b --watch 60  # live browser tab, re-fetch every 60s
ruby lib/kamandar.rb --serve --demo # fabricated data (no token) — screenshots/offline trials
ruby lib/kamandar.rb --serve --no-open # serve headless — don't auto-open a browser tab
./service/install-service.sh        # persist --serve as a launchd LaunchAgent (macOS; always-on)
./service/uninstall-service.sh      # stop + remove that LaunchAgent
```

`--serve` can run as an always-on macOS service: `service/install-service.sh` renders `service/com.kamandar.serve.plist` (filling in this machine's repo/ruby/home) into `~/Library/LaunchAgents`, then `bootstrap`s it with `RunAtLoad` + `KeepAlive`. The agent runs `--serve --no-open --tunnel` (headless) with `KAMANDAR_CONFIG` → repo `.env` (git-ignored; holds the token) and `HOME` set so cloudflared finds `~/.cloudflared`. The Ruby server binds `127.0.0.1`; the `cloudflared tunnel run kamandar` child publishes it at the hostname in `~/.cloudflared/config.yml` (`kamandar.byaru.com`), which **must** sit behind Cloudflare Access (it's a live PAT-backed queue). `run_server` traps `SIGTERM` → `Interrupt` so a launchd stop runs the `ensure` and reaps the tunnel child instead of orphaning it; the service scripts also `pkill` a stray `cloudflared tunnel run kamandar` as a backstop. Logs: `~/Library/Logs/kamandar.{out,err}.log`.

Required config to actually run (not needed for tests): `GITHUB_TOKEN` (classic PAT: `repo, read:org, read:project`), `GH_LOGIN`. Optional: `PROJECT_URL` (enables bucket #3), `STALE_DAYS`, `DAY_MODE`, `NOT_STARTED_STATUSES`, `ITERATION_FILTER`, `ITERATION_FIELD`. Supply via shell env **or** a persisted config file (`--init` writes it). See the README config table or the header comment in `lib/kamandar.rb`.

**Config resolution** (`Config.from`): precedence is **CLI flags > real ENV > config file**. The config file is a flat `KEY=VALUE` list (same names as the ENV vars; `#` comments, optional `export ` prefix, quotes stripped — parsed by hand, no dotenv gem). Path: `$KAMANDAR_CONFIG`, else `$XDG_CONFIG_HOME/kamandar/config`, else `~/.config/kamandar/config`. `Config.load_file`/`config_path`/`render_file` are pure + unit-tested; the wizard (`CLI.run_init`) and `0600` write are the only side effects. `--init` verifies the token via `GitHub.viewer_login` (Engine.build_viewer_query) before saving. Tests stay hermetic by pointing `KAMANDAR_CONFIG` at a tempfile. `install.sh` symlinks `lib/kamandar.rb` → `~/.local/bin/kamandar` (symlink, so `git pull` updates in place).

No single-test runner — the suite is a hand-rolled harness (`check`/`ok` helpers), not Minitest/RSpec. Comment out cases or add a guard to isolate one.

## Architecture

Everything lives in one file: `lib/kamandar.rb`. Layers are Ruby modules, ordered **Engine → buckets → Surface**:

- **`Engine`** — pure, side-effect-free: no network, no ENV, no I/O. Time math, GraphQL query *strings*, and all classification. Operates on **raw GraphQL node hashes (string keys)** so the same code classifies fixtures and live data. This is the unit-testable core.
- **buckets** — a plain hash `Engine.classify` returns. **The bucket set depends on scope** (`config[:scope][:mode]`): `project` is board-driven (`classify_project` → `{reviews_owed, wip, assigned_not_started, in_review, in_qa, blocked, stale, forgot_reviewer}`); every other scope is issue+PR driven (`classify_issue` → `{reviews_owed, assigned_todo, assigned_wip, assigned_review, assigned_no_reviewer, stale}`, classified by each assigned issue's linked-PR state via `issue_pr_state`). `Engine.bucket_meta(mode)` returns the ordered metadata for that mode (`BUCKETS_PROJECT` / `BUCKETS_ISSUE`); both surfaces iterate it. `Engine::BUCKETS` aliases the project set.
- **`Surface` / `TerminalSurface` / `DashboardSurface` / `BrowserSurface` / `ServerSurface`** — consume buckets only; never re-query or re-classify. Contract is `render`/`page(buckets, ...) -> String` + `emit`. Adding email/menubar = new surface, **no engine change**. `ServerSurface` reuses `BrowserSurface`'s `css`/`card`/`sections_html` and adds an in-page scope control bar.
- **`GitHub`** — the *only* outbound network layer (`Net::HTTP` → GraphQL). **`Server`** is the *only* inbound one: a minimal stdlib `TCPServer` HTTP/1.1 loop for `--serve`, bound to `127.0.0.1`. Its pure helpers (`parse_request`, `http_response`, `resolve_scope`) are unit-tested; the accept loop lives in `CLI.run_server`. `Config` resolves ENV + CLI flags (flags win). `CLI` is the only place with side effects + ENV.
- **`--tunnel`** (optional): `CLI.start_tunnel`/`stop_tunnel` spawn `cloudflared tunnel run <name>` (default `kamandar`, or `--tunnel <name>`/`$KAMANDAR_TUNNEL`) as a child of `run_server` and TERM+reap it in the `ensure`, so one Ctrl-C stops both. cloudflared is an external binary (not a Ruby dep), dials the unchanged `127.0.0.1` bind, and falls back to local-only with a warning if absent. `--tunnel` implies `--serve`. The public hostname lives in the user's `~/.cloudflared/config.yml`, not in this repo.
- **`Demo`** — pure, deterministic fake-data generator (`Demo.buckets(mode)`): 15–20 rows/bucket shaped exactly like `Engine.classify` output. `--demo` short-circuits `fetch_and_classify` (and skips `validate!`), so any surface renders offline with no token — used for screenshots. `ServerSurface` paginates panels at `PAGE_SIZE` (8) cards/page via a CSS-only pager (`paginated_body` + generated `pager_css`, hidden radio per page; no JS).

The whole file is guarded by `if __FILE__ == $PROGRAM_NAME` at the bottom, so `test/` can `require` it without running or reading ENV.

## Conventions specific to this repo

- **Keep the engine pure.** `today:` and `mode:` are injected as args (never `Time.now` inside Engine) — that's what makes the suite deterministic with a fixed "today" (Monday 2026-06-22). Preserve that when editing classification.
- **Stdlib only.** Do not add gems or a Gemfile. A new dependency breaks the project's core constraint.
- Tests are the **spec of record** (`test/test_kamandar.rb` header says so). Behavior changes should update tests alongside.
- The browser surface renders **one self-contained HTML file** (inline CSS, no CDN/external assets, no `<script src>`, works over `file://`). Tests assert these properties (#13f–h) and that **no token ever reaches the HTML** (#14). Don't introduce external assets or pass secrets into `render`. The same **token-never-in-output** guarantee covers `ServerSurface.page`/`error_page` and the live `--serve` response (tests assert it on all three). The server binds `127.0.0.1` only — never `0.0.0.0`.

## Bucket #7 (stale PRs) — the non-obvious logic

Don't key staleness off `reviewDecision` — it stays `CHANGES_REQUESTED` after the author pushes fixes, dropping the PR you most want flagged. Instead a **timestamp race** decides who holds the ball:

`handoff_at = max(last review-requested, last push, PR created)` vs `reviewer_last_action_at` (latest APPROVED/CHANGES_REQUESTED; plain COMMENTED ignored). Ball is on reviewer when `handoff > action` (or they never acted); stale when that's true, not a draft, and `days_since(handoff) >= STALE_DAYS`. Any push resets the clock by design (see `Engine.handoff_at` to change that).

## Docs

`V2.md` is a design-only roadmap (multi-provider: GitLab/Jira/Linear) — not implemented. `SECURITY.md` covers the token-never-in-HTML guarantee.
