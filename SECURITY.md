# Security Policy

## Overview

kamandar is a single-user, serverless command-line tool. It holds no
persistent state, runs no server, and exposes no network listener. Its security
surface is small by design, but it does handle a credential (`GITHUB_TOKEN`),
so this document describes how that credential is treated and how to report
issues.

## The token

- **Provide it via environment variable** (`GITHUB_TOKEN`), not on the command
  line — process arguments are visible to other users via `ps`.
- Use a **classic Personal Access Token** scoped to exactly what's needed:
  `repo`, `read:org`, `read:project`. Prefer a fine-grained token where your org
  allows it.
- The token is read once, used only as a `Authorization: Bearer` header on
  HTTPS requests to `https://api.github.com/graphql`, and never written to disk.

### Hard guarantee: secrets never reach the rendered page

The browser surface renders a **static, in-process snapshot**. The page:

- makes **no** GitHub (or any network) calls — it contains only the
  already-fetched display data;
- **never** includes the `GITHUB_TOKEN` or any other secret.

This is enforced by an acceptance test (a sentinel token is passed through and
the rendered HTML is asserted not to contain it). Please keep that test green.

The generated HTML is written to a predictable path
(`<tmpdir>/kamandar.html`) so watch-mode reloads hit the same browser tab.
It contains only the same PR/issue titles and URLs you can already see on
GitHub — no credentials — but be aware it is world-readable depending on your
`tmpdir` permissions. Delete it if you share the machine:

```sh
rm "${TMPDIR:-/tmp}/kamandar.html"
```

## Network

- All GitHub traffic is over HTTPS with TLS verification enabled (Ruby's
  default). Do not disable verification.
- The browser page loads **no external/CDN resources**; it works fully offline.

## Supported versions

This is a personal tool released as-is. Only the latest commit on the default
branch is "supported." Run a current **Ruby 3.2+** for up-to-date TLS and
stdlib fixes.

## Reporting a vulnerability

If you find a security issue:

1. **Do not** open a public issue for anything that could expose user
   credentials or data.
2. Email the maintainer privately at **cdrrazan@gmail.com** with a description,
   reproduction steps, and impact.
3. Please allow a reasonable window to respond before any public disclosure.

When reporting, **never include your `GITHUB_TOKEN` or any other secret** in the
report, logs, or screenshots.

## Hardening tips for users

- Scope the token minimally and rotate it periodically; revoke it immediately
  if leaked (GitHub → Settings → Developer settings → Personal access tokens).
- Run on a machine where your `tmpdir` is not shared, or clean up the generated
  HTML after use.
- Keep your Ruby runtime patched.
