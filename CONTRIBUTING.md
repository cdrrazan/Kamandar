# Contributing to kamandar

Thanks for your interest! This is a small, deliberately minimal personal tool.
Contributions that keep it small, dependency-free, and well-tested are very
welcome.

## Ground rules

These constraints are the whole point of the project — please preserve them:

- **Stdlib only.** No gems, no `Gemfile`, no `bundler`. Only `net/http`,
  `json`, `date`, `time`, `tmpdir`, `rbconfig`, and friends.
- **Serverless.** No web server, no OAuth flow, no database. The browser
  surface is a static `file://` page rendered in-process.
- **Ruby 3.2+.**
- **No secrets on the page.** The rendered HTML must never contain the token or
  any secret. (Enforced by an acceptance test — keep it green.)
- **Keep the layering.** Engine → buckets → Surface:
  - The **Engine** is pure and side-effect-free (no network, no ENV, no I/O).
    All new classification/time/query-building logic goes here and must be
    unit-testable with zero network.
  - **Surfaces** only consume the buckets hash; they never re-query or
    re-classify.

## Development setup

```sh
git clone https://github.com/cdrrazan/releaser.git
cd releaser
ruby -c lib/kamandar.rb   # syntax check
ruby test/test_kamandar.rb       # run the acceptance tests
```

### Layout

```text
lib/kamandar.rb     # engine + both surfaces (single file)
test/test_kamandar.rb      # acceptance tests (zero network)
```

No build step. No install step.

## Tests

`test_kamandar.rb` is the spec of record. It uses a fixed "today"
(Monday 2026-06-22) and fabricated PR/item hashes, with `today:` and `mode:`
injected for determinism — so it runs offline with no token.

- Every change to engine behavior **must** come with a test.
- Run `ruby test/test_kamandar.rb` before opening a PR; it must print `0 failed`.
- Prefer adding a focused fixture + `check`/`ok` assertion over reworking
  existing cases.

## Making changes

1. Develop on a feature branch.
2. Match the surrounding style: `# frozen_string_literal: true`, two-space
   indentation, `module_function` for stateless modules, descriptive method
   names ending in `?` for predicates.
3. Keep the in-file README block (the header of `kamandar.rb`) in sync with
   any config/flag/behavior changes, and update `README.md` to match.
4. Run the tests.

## Commit messages

- Write clear, imperative-mood subject lines ("Add iteration filter", not
  "added").
- Explain the *why* in the body when the change isn't obvious.

## Pull requests

- Describe what changed and why, and note any new config or flags.
- Confirm `ruby test/test_kamandar.rb` passes.
- Keep PRs focused — one logical change per PR.

## Reporting bugs

Open an issue with:

- What you ran (command + relevant non-secret config).
- What you expected vs. what happened.
- Ruby version (`ruby -v`).

**Never paste your `GITHUB_TOKEN` or any other secret** into an issue, PR, or
log. See [SECURITY.md](SECURITY.md).
