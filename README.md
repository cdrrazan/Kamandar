<div align="center">

# 🏹 Kamandar

### Take aim at your GitHub work queue.

***Kamandar*** (کمان‌دار) is Persian for *archer* — one who draws the bow and
finds the target. A personal, **serverless** GitHub command center: one command
shows what you owe, what you're building, what's assigned, and what's gone
quiet — in your terminal or a self-contained browser page.

<br>

![Ruby](https://img.shields.io/badge/Ruby-3.2%2B-CC342D?logo=ruby&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-stdlib%20only-2ea44f)
![Tests](https://img.shields.io/badge/tests-120%20passing-2ea44f)
![Serverless](https://img.shields.io/badge/serverless-no%20server%20·%20no%20DB%20·%20no%20OAuth-0969da)
![License](https://img.shields.io/badge/license-MIT-blue)
![PRs welcome](https://img.shields.io/badge/PRs-welcome-ff69b4)

</div>

---

```text
Kamandar for @you  —  2026-06-22 09:14  (business days)
========================================================================

📥 Reviews you owe (2)
----------------------
  #482 Tighten retry backoff  (acme/api)
    https://github.com/acme/api/pull/482
  #477 Cache token introspection  (acme/web)
    https://github.com/acme/web/pull/477

🔨 Currently building (WIP) (1)
-------------------------------
  #503 Spike: pluggable providers  (acme/api)
    https://github.com/acme/api/pull/503

⏳ Your PRs gone quiet (1)
--------------------------
  #501 Add billing webhook  (acme/api)  — 3 business days since you handed off
    https://github.com/acme/api/pull/501
```

---

## ✨ What it shows — seven buckets (+ one bonus)

| # | Bucket | What lands here |
|---|--------|-----------------|
| 1 | 📥 **Reviews you owe** | Open PRs where review is requested *from you* |
| 2 | 🔨 **Currently building (WIP)** | Your own open **draft** PRs |
| 3 | 📋 **Assigned, not started** | Projects V2 issues assigned to you whose **Status** is in a configurable "not started" set |
| 4 | 👀 **Submitted for review** | Projects V2 issues assigned to you whose **Status** is in a configurable "in review" set |
| 5 | 🧪 **In QA** | Projects V2 issues assigned to you whose **Status** is in a configurable "QA" set |
| 6 | 🚧 **Blocked** | Projects V2 issues assigned to you whose **Status** is in a configurable "blocked" set (waiting on a requirement or someone's answer) |
| 7 | ⏳ **Your PRs gone quiet** | Your **ready** PRs where the ball is on the reviewer past a threshold |
| ➕ | 🙈 **Ready, no reviewer requested** | *(bonus)* Your ready PRs with nobody asked to review and no reviews yet — silently invisible to everyone |

> **The bucket set depends on [scope](#-scope).** The table above is **project**
> scope, where buckets #3–6 come from your board's **Status** columns. In
> **global / org / repo** scope there is no board, so those four are replaced by
> issue+PR buckets driven by the state of each assigned issue's linked PR:
>
> | Bucket | Lands here |
> |---|---|
> | 📥 Reviews you owe | `review-requested:@me` (same as project) |
> | 📋 Assigned, not started | issue assigned to you with **no linked PR** |
> | 🔨 Assigned, PR in draft | linked PR is a **draft** |
> | 👀 Assigned, PR in review | linked PR is **ready + has a reviewer** |
> | 🙈 Assigned, PR ready (no reviewer) | linked PR is ready but **nobody asked** |
> | ⏳ Your PRs gone quiet | same as project |
>
> Issue→PR links use GitHub's **"Closes #123"** references.

---

## 🚀 Quick start

> Requires **Ruby 3.2+**. No gems — standard library only.

```sh
git clone https://github.com/cdrrazan/Kamandar.git
cd Kamandar

export GITHUB_TOKEN=ghp_xxx          # classic PAT: repo, read:org, read:project
export GH_LOGIN=your-username

ruby lib/kamandar.rb             # terminal output (default)
ruby lib/kamandar.rb --browser   # render + open a static HTML page
ruby lib/kamandar.rb -b --watch 60   # live tab, refreshed every 60s
```

> `PROJECT_URL` is **optional** — the [scope picker](#-scope) asks for the board
> URL when you choose `project`. Set it only if you want bucket #3
> (*Assigned, not started*) populated without picking project scope, or for
> non-interactive runs (cron).

Put it on your `PATH` if you like:

```sh
chmod +x lib/kamandar.rb
ln -s "$PWD/lib/kamandar.rb" ~/.local/bin/kamandar
```

---

## 📂 Project layout

```text
Kamandar/
├── lib/
│   └── kamandar.rb     # engine + both surfaces (single file, stdlib only)
├── test/
│   └── test_kamandar.rb  # acceptance tests — zero network, 120 cases
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
├── V2.md                   # multi-provider roadmap (design only)
└── LICENSE
```

---

## ⚙️ Configuration

> CLI flags take precedence over environment variables.

| Var / flag | Required | Default | Purpose |
|---|:---:|---|---|
| `GITHUB_TOKEN` | ✅ | — | Classic PAT: `repo`, `read:org`, `read:project` |
| `GH_LOGIN` | ✅ | — | Your GitHub username |
| `OUTPUT` / `--browser`, `-b` | | `terminal` | Surface: `terminal` or `browser`. The flag forces browser and overrides `OUTPUT`. |
| `WATCH_SECONDS` / `--watch N` | | `0` (off) | Browser only: re-fetch + rewrite the page every N seconds |
| `PROJECT_URL` | for #3 | — | Board/view URL, e.g. `https://github.com/orgs/Recognize/projects/10/views/5` |
| `SCOPE` / `--scope` | | `global` | Scope for PR buckets (#1, #2, #7, bonus). One of `global`, `org[:NAME]`, `repo:owner/name`, `project`. See [Scope](#-scope). |
| `NOT_STARTED_STATUSES` | | `Todo,Backlog,No Status` | Status names treated as "not started" (case-insensitive) — bucket #3 |
| `REVIEW_STATUSES` | | `In Review,Review,Needs Review` | Status names treated as "in review" (case-insensitive) — bucket #4 |
| `QA_STATUSES` | | `Ready for QA,QA,In QA` | Status names treated as "in QA" (case-insensitive) — bucket #5 |
| `BLOCKED_STATUSES` | | `Blocked,On Hold,Waiting` | Status names treated as "blocked" (case-insensitive) — bucket #6 |
| `ITERATION_FILTER` | | `off` | `current` restricts #3 to the active sprint |
| `ITERATION_FIELD` | | `Iteration` | Board's iteration field name |
| `STALE_DAYS` | | `2` | Threshold (in days) for bucket #7 |
| `DAY_MODE` | | `business` | `business` (skip Sat/Sun) or `calendar` |

Only the **org** and **project number** are parsed from `PROJECT_URL` (via
`/orgs/<org>/projects/<num>`); the saved-view number is ignored — see
[Non-goals](#-non-goals--known-limitations).

> **Finding your board's labels.** The `*_STATUSES` vars (`NOT_STARTED_STATUSES`,
> `REVIEW_STATUSES`, `QA_STATUSES`, `BLOCKED_STATUSES`) must match your board's
> actual **Status** column names — a board's columns *are* its Status options.
> Run `ruby lib/kamandar.rb --statuses` to print every issue assigned to you with
> its exact Status (and the distinct set), then set the vars to suit. It asks for
> the board URL if `PROJECT_URL` isn't set.

---

## 🎯 Scope

By default Kamandar shows your PR buckets **account-wide**. Narrow them with
`SCOPE` (env) or `--scope` (flag; the flag wins):

| `SCOPE` | What PR buckets (#1, #2, #7, bonus) show |
|---|---|
| `global` *(default)* | Every repo your account touches |
| `org` or `org:NAME` | One org. Bare `org` reuses the org from `PROJECT_URL` |
| `repo:owner/name` | A single repo |
| `project` | PRs that **belong to** the `PROJECT_URL` board — a card on it, or one that **closes a board issue** |

```sh
ruby lib/kamandar.rb --scope org:Recognize     # one org
ruby lib/kamandar.rb --scope repo:acme/api     # one repo
SCOPE=project ruby lib/kamandar.rb             # repos on your project board
```

`org`/`repo` filter server-side via a GitHub search qualifier; `project` keeps
only the PRs that **belong to the board** — either carded on it directly, or
(the usual case, since boards track issues) a PR that **closes a board issue**
via `Closes #N`. Because the board tracks issues, a review you owe is shown as
the **board issue** the PR closes (falling back to the PR itself when it closes
no board issue) — so John's review surfaces as his card in "Ready for Review",
not a loose PR. Anything unrecognized (or
`org`/`repo` with no value, or `project` with no `PROJECT_URL`) safely falls
back to `global`. The active scope is shown in the terminal header and the
browser page.

**Interactive picker.** Run plain `ruby lib/kamandar.rb` in a terminal without
`SCOPE`/`--scope` and it asks you to pick a mode by number — you only type the
*name* for `org`/`repo`; you never type the mode itself:

```text
Scope for PR buckets:
  1) global   — account-wide (default)
  2) org      — a single organization
  3) repo     — a single repository
  4) project  — PRs that are items on a GitHub project board
Select 1-4 (Enter = global):
```

Pick `org`/`repo` and it asks for the name; pick `project` and — if no
`PROJECT_URL` is set — it asks for the board URL right there (no need to export
anything first). Press Enter, or give a blank/invalid value, and it defaults to
**global**. The prompt is skipped when a scope is already set, when stdin isn't a
terminal (cron/pipes), or in browser mode — so nothing ever blocks.

---

## 🏗️ Architecture

**Engine → buckets → Surface** — three separable layers. The engine is pure and
side-effect-free; surfaces only consume the buckets hash and never re-query or
re-classify.

```mermaid
flowchart LR
    GH["GitHub GraphQL API"] -->|"1 aliased call + paginated board"| FETCH["Fetch layer"]
    FETCH --> ENGINE["Engine (pure)<br/>time math · classification"]
    ENGINE --> BUCKETS["Buckets<br/>(plain hash)"]
    BUCKETS --> TERM["🖥️ Terminal surface<br/>plain text · cron-friendly"]
    BUCKETS --> BROWSER["🌐 Browser surface<br/>static offline HTML"]
```

- **Engine** — pure functions (GraphQL building, time math, classification),
  unit-testable with zero network.
- **Buckets** — a plain hash the engine returns.
- **Surface** — one tiny contract (`render(buckets, ...) -> String` + an
  `emit`). Two implementations today (terminal, browser); adding email or a
  menubar app later requires **no engine change**.

Everything is guarded by `if __FILE__ == $PROGRAM_NAME` so the test suite can
`require` the file with zero network and no ENV reads.

---

## 🖥️ Surfaces

The same classified buckets feed both surfaces.

### Terminal (default)

Plain text grouped by bucket, no ANSI — safe to pipe to `mail`. Ideal for cron.

### Browser (serverless)

Renders **one self-contained HTML document** (inline CSS, no external/CDN
resources, works offline over `file://`) to a stable path
(`<tmpdir>/kamandar.html`) and opens it in your default browser. Bucket #7
gets a warning accent and a "days since handoff" badge per card. Dark mode via
`prefers-color-scheme`.

- **Watch mode** (`--watch N`): re-fetches, re-classifies, and rewrites the same
  file every N seconds — opening the browser only on the first cycle. The page
  carries `<meta http-equiv="refresh">` so the open tab reloads itself.
  Meta-refresh over `file://` works in current Chrome, Firefox, and Safari.
- 🔒 **Security:** the page is a static in-process snapshot. It makes no GitHub
  calls and **never contains your token or any secret** — see
  [SECURITY.md](SECURITY.md).

---

## ⏳ Bucket #7 — the handoff-vs-reviewer race

Keying off `reviewDecision == REVIEW_REQUIRED` is **wrong**: after a reviewer
requests changes and the author pushes fixes, `reviewDecision` stays
`CHANGES_REQUESTED` until the reviewer re-reviews — so the PR you most want
flagged gets dropped. kamandar uses a **timestamp race** instead.

```mermaid
flowchart TD
    A["handoff = max(last review-requested, last push, PR created)"] --> C{ball on reviewer?}
    B["reviewer action = latest APPROVED / CHANGES_REQUESTED<br/>(plain comments ignored)"] --> C
    C -->|"handoff &gt; action, or never acted"| D{"days since handoff ≥ STALE_DAYS<br/>and not a draft?"}
    C -->|"action newer"| E["not stale (ball on author)"]
    D -->|yes| F["⏳ STALE"]
    D -->|no| G["not stale yet"]
```

| Scenario | Result |
|---|---|
| Fresh, awaiting review | ⏳ stale |
| Changes requested, not yet fixed | ✅ not stale (ball on author) |
| Changes requested, **then pushed** | ⏳ stale |
| Approved, no new commits | ✅ not stale |
| Approved, **then pushed** | ⏳ stale |
| No reviewer at all | 🙈 forgot-reviewer (not stale) |

---

## 📨 Push layer (terminal mode)

No scheduler code lives in the tool. Wire terminal output into your own cron —
e.g. weekday mornings at 8:30, emailed to yourself:

```cron
30 8 * * 1-5  GITHUB_TOKEN=... GH_LOGIN=you PROJECT_URL=... \
              ruby /path/lib/kamandar.rb | mail -s "Kamandar" you@example.com
```

Swap `mail` for `notify-send` (Linux desktop) or `terminal-notifier` (macOS).
Browser mode is for interactive/ambient use (optionally with `--watch`), not cron.

---

## ✅ Tests

Every acceptance scenario is encoded with a fixed "today" (Monday 2026-06-22)
and fabricated fixtures — **zero network**.

```sh
ruby test/test_kamandar.rb
# ...
# 120 passed, 0 failed
```

---

## 🗺️ Roadmap

A **v2** that abstracts the provider layer to support GitLab and other project
managers (Jira, Linear) is sketched in [V2.md](V2.md).

---

## 🚫 Non-goals / known limitations

- The saved **view** filter DSL is **not** replicated; #3 is approximated by
  Status (+ optional iteration). Only org + project number are read from the URL.
- "Commented" reviews are intentionally ignored — a comment doesn't flip the ball.
- Any push (incl. a typo fix or rebase/force-push) resets the #4 clock by design
  ("you resubmitted"). To reset only on an explicit re-request, drop `last_push`
  from `handoff_at` in the engine.
- Browser mode is a **static snapshot** rendered in-process: no client-side
  GitHub calls, no live data except via `--watch` re-runs. The token never
  reaches the page.
- Single user, single token, no multi-tenant concerns.

---

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security policy in [SECURITY.md](SECURITY.md).

## 📄 License

[MIT](LICENSE) © 2026 cdrrazan
