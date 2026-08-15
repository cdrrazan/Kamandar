# Funding Kamandar

Kamandar is free and MIT-licensed, and it stays that way. There is no paid tier,
no hosted plan, no telemetry, and nothing behind a login — it's a single Ruby
file that runs on your machine against your own token.

It's also maintained by one person in Kathmandu, in evenings and weekends. If
the tool earns its place in your morning routine, funding is how you keep that
maintenance going.

---

## Ways to support

### 💛 Free — and genuinely useful

These cost nothing and help more than people expect:

- **Star the repo** — [github.com/cdrrazan/Kamandar](https://github.com/cdrrazan/Kamandar).
  Stars are how anyone else finds it.
- **Open an issue** when something breaks on your board. Real-world Status
  column names, odd project layouts, and unusual scopes are exactly what a
  single-user tool never sees on its own.
- **Send a PR.** Two rules: stdlib only (no gems), and the engine stays pure.
  See [CONTRIBUTING.md](CONTRIBUTING.md).
- **Tell one person** who complains about forgetting reviews.

### ☕ One-off

If it saved you an afternoon of "wait, whose turn is this PR?", a one-time
contribution is welcome. Reach out at
**[irajanbhattarai@gmail.com](mailto:irajanbhattarai@gmail.com)** and I'll point
you at the current option.

### 🔁 Recurring — GitHub Sponsors

Sponsor [**@cdrrazan**](https://github.com/sponsors/cdrrazan) monthly. Recurring
support is what makes it reasonable to treat issues as commitments rather than
favors.

### 🏢 Company or team use

Using Kamandar across a team, or want a feature that fits your workflow
specifically — a provider beyond GitHub, a different bucket, an internal
deployment shape? Email
**[irajanbhattarai@gmail.com](mailto:irajanbhattarai@gmail.com)**. Sponsored
work gets scheduled; it also ships back into the open-source repo.

---

## What funding pays for

Concretely, in rough priority order:

1. **Maintenance** — GitHub's GraphQL schema moves; queries and classification
   have to move with it.
2. **Issue turnaround** — reproducing board setups that don't look like mine.
3. **[V2](V2.md)** — the multi-provider layer (GitLab, Jira, Linear). It's
   designed but not implemented, and it's the single largest chunk of work
   sitting in front of this project.
4. **Surfaces** — the engine → buckets → surface split makes new surfaces cheap;
   each still needs building and testing.

## What it does *not* buy

Being explicit, because it matters for a tool that holds a GitHub token:

- **No paid features.** Everything in the repo is available to everyone, always.
- **No priority on security issues by payment.** Security reports are handled
  first regardless of who sends them — see [SECURITY.md](SECURITY.md).
- **No telemetry, no analytics, no data collection**, sponsored or not. The tool
  talks to GitHub (and, with `--email`, your SMTP server). Nothing else, ever.
- **No influence over the two hard constraints**: stdlib only, and a pure
  engine. Those are the project, not preferences.

---

## Transparency

This is a personal project, not a company or a foundation. There's no budget
document, no fiscal host, and no promise of a support SLA. Funding is a
thank-you that buys maintenance attention — treat it that way, and nobody ends
up disappointed.

---

Thanks for reading this far. Even if you never send a cent, the tool is yours to
keep. 🏹

— Rajan Bhattarai ([@cdrrazan](https://github.com/cdrrazan)) ·
[irajanbhattarai@gmail.com](mailto:irajanbhattarai@gmail.com)
