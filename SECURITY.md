# Security Policy

## Overview

kamandar is a single-user command-line tool. It holds no persistent state and
needs no backend. Its only network listener is **opt-in** (`--serve`), and it
binds **`127.0.0.1` only** — never a public interface. Its security surface is
small by design, but it does handle a credential (`GITHUB_TOKEN`), so this
document describes how that credential is treated and how to report issues.

## The token

- **Provide it via environment variable** (`GITHUB_TOKEN`), not on the command
  line — process arguments are visible to other users via `ps`.
- Use a **classic Personal Access Token** scoped to exactly what's needed:
  `repo`, `read:org`, `read:project`. Prefer a fine-grained token where your org
  allows it.
- The token is read once, used only as a `Authorization: Bearer` header on
  HTTPS requests to `https://api.github.com/graphql`, and never written to disk.

### Hard guarantee: secrets never reach the rendered page

Every surface is handed only **already-fetched display data** — PR/issue titles
and URLs — never the token. This holds for the static browser page
(`BrowserSurface`) and for the live web app (`ServerSurface.page` /
`error_page`, served by `--serve`): the rendered output

- contains only display data — no `GITHUB_TOKEN` or any other secret;
- (browser file) makes **no** further network calls; (server) re-fetches
  server-side only, so the token stays in the process and never in a response.

This is enforced by acceptance tests — a sentinel token is passed through and
the rendered HTML, the server page, and a real `--serve` HTTP response are each
asserted not to contain it. Please keep those tests green.

### The `--serve` web app

`--serve` starts a minimal stdlib `TCPServer` HTTP/1.1 listener for a single
user on your own machine:

- it binds **`127.0.0.1`** only, so it is not reachable from the network;
- it serves over plain HTTP (localhost only — no TLS needed for loopback);
- responses set `Cache-Control: no-store` and carry no credentials.

Anyone with access to your loopback interface (i.e. a local account on your
machine) can read the served page while the server runs. Stop it (`Ctrl-C`)
when you're done, and don't port-forward or proxy it to a public address.

### `KAMANDAR_HOST` — the one way to leave loopback

`KAMANDAR_HOST` overrides the bind address, and the shipped `Dockerfile` sets it
to `0.0.0.0` so a reverse proxy can reach the server inside a container. Treat
that as an explicit opt-out of the loopback guarantee:

- **The app has no authentication of its own.** Whatever sits in front of it
  (Cloudflare Access, an authenticating reverse proxy, a private network) is the
  only thing standing between your GitHub queue and whoever finds the address.
- In Docker, publish the port to loopback (`-p 127.0.0.1:4567:4567`) or to a
  private interface — never to a public one without auth in front.
- Outside a container there is essentially no good reason to set it. If you want
  remote access, use a Cloudflare Tunnel with Access instead: the bind stays
  `127.0.0.1` and `cloudflared` dials outbound.

The token itself never leaves the process regardless of the bind — but the
**data** on the page (private repo names, PR and issue titles) is sensitive.

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
2. Email the maintainer privately at **irajanbhattarai@gmail.com** with a description,
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
