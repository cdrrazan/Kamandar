#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# test_kamandar.rb — acceptance tests for kamandar.rb (spec of record)
#
# Zero network. Fixed "today" = Monday 2026-06-22. Fabricated PR/item hashes.
# `today:` and `mode:` are injected for determinism.
#
# Run:  ruby test/test_kamandar.rb
# =============================================================================

require_relative "../lib/kamandar"
require "date"
require "time"
require "stringio"

E = Kamandar::Engine
S = Kamandar::Surface
B = Kamandar::BrowserSurface
T = Kamandar::TerminalSurface

TODAY = Time.utc(2026, 6, 22, 12, 0, 0) # Monday

# -- tiny harness -------------------------------------------------------------
$pass = 0
$fail = 0

def check(name, actual, expected)
  if actual == expected
    $pass += 1
    puts "PASS  #{name}"
  else
    $fail += 1
    puts "FAIL  #{name}"
    puts "        expected: #{expected.inspect}"
    puts "        actual:   #{actual.inspect}"
  end
end

def ok(name, cond)
  check(name, !!cond, true)
end

# -- fixture builders ---------------------------------------------------------
def iso(time)
  time.utc.iso8601
end

# Build a PR node hash mirroring the GraphQL shape.
def pr(isDraft: false, created:, last_push: nil, last_request: nil,
       reviews: [], review_requests_total: 0, number: 1, title: "PR",
       url: "https://github.com/o/r/pull/1", repo: "o/r")
  {
    "number" => number, "title" => title, "url" => url, "isDraft" => isDraft,
    "reviewDecision" => nil, "createdAt" => iso(created),
    "repository" => { "nameWithOwner" => repo },
    "reviewRequests" => { "totalCount" => review_requests_total },
    "commits" => { "nodes" => last_push ? [{ "commit" => { "committedDate" => iso(last_push) } }] : [] },
    "timelineItems" => { "nodes" => last_request ? [{ "createdAt" => iso(last_request) }] : [] },
    "latestOpinionatedReviews" => {
      "nodes" => reviews.map { |st, at| { "state" => st, "submittedAt" => iso(at) } }
    }
  }
end

def item(login:, status:, typename: "Issue", number: 1)
  {
    "fieldValues" => {
      "nodes" => [
        { "__typename" => "ProjectV2ItemFieldSingleSelectValue",
          "name" => status, "field" => { "name" => "Status" } }
      ]
    },
    "content" => {
      "__typename" => typename, "number" => number, "title" => "Issue #{number}",
      "url" => "https://github.com/o/r/issues/#{number}", "state" => "OPEN",
      "assignees" => { "nodes" => [{ "login" => login }] },
      "repository" => { "nameWithOwner" => "o/r" }
    }
  }
end

D = ->(y, m, d) { Time.utc(y, m, d, 10, 0, 0) }

STALE = { stale_days: 2, mode: "business", today: TODAY }

# =============================================================================
# #4 staleness (STALE_DAYS=2, business)
# =============================================================================

# 1. requested Wed, never reviewed -> stale
p1 = pr(created: D.(2026, 6, 15), last_request: D.(2026, 6, 17),
        review_requests_total: 1, reviews: [])
ok "#4.1 requested Wed, never reviewed -> stale", E.stale?(p1, **STALE)

# 2. changes requested, no push since -> not stale (ball on author)
p2 = pr(created: D.(2026, 6, 15), last_request: D.(2026, 6, 16),
        reviews: [["CHANGES_REQUESTED", D.(2026, 6, 17)]])
ok "#4.2 changes requested, no push -> not stale", !E.stale?(p2, **STALE)

# 3. changes requested, then a commit pushed after it -> stale
p3 = pr(created: D.(2026, 6, 12), last_request: D.(2026, 6, 15),
        reviews: [["CHANGES_REQUESTED", D.(2026, 6, 16)]],
        last_push: D.(2026, 6, 17))
ok "#4.3 changes requested then pushed -> stale", E.stale?(p3, **STALE)

# 4. approved, last commit before approval -> not stale
p4 = pr(created: D.(2026, 6, 12), last_push: D.(2026, 6, 15),
        reviews: [["APPROVED", D.(2026, 6, 16)]])
ok "#4.4 approved, commit before approval -> not stale", !E.stale?(p4, **STALE)

# 5. approved, then a commit pushed after approval -> stale
p5 = pr(created: D.(2026, 6, 12), reviews: [["APPROVED", D.(2026, 6, 15)]],
        last_push: D.(2026, 6, 17))
ok "#4.5 approved then pushed -> stale", E.stale?(p5, **STALE)

# 6. requested today -> not stale
p6 = pr(created: D.(2026, 6, 18), last_request: D.(2026, 6, 22),
        review_requests_total: 1)
ok "#4.6 requested today -> not stale", !E.stale?(p6, **STALE)

# 7. draft PR -> not stale
p7 = pr(isDraft: true, created: D.(2026, 6, 15), last_request: D.(2026, 6, 16),
        review_requests_total: 1)
ok "#4.7 draft -> not stale", !E.stale?(p7, **STALE)

# 8. no reviewer/request/review -> not stale, forgot_reviewer -> true
p8 = pr(created: D.(2026, 6, 15))
ok "#4.8a no reviewer -> not stale", !E.stale?(p8, **STALE)
ok "#4.8b no reviewer -> forgot_reviewer true", E.forgot_reviewer?(p8)

# =============================================================================
# Time math
# =============================================================================
FRI = D.(2026, 6, 19) # Friday

# 9. days_since(Fri, calendar) on Mon -> 3
check "#9 days_since(Fri, calendar) on Mon == 3",
      E.days_since(FRI, mode: "calendar", today: TODAY), 3

# 10. days_since(Fri, business) on Mon -> 1
check "#10 days_since(Fri, business) on Mon == 1",
      E.days_since(FRI, mode: "business", today: TODAY), 1

# =============================================================================
# #3 project filter
# =============================================================================
items = [
  item(login: "me", status: "Todo", number: 1),
  item(login: "me", status: "In Progress", number: 2),
  item(login: "other", status: "Todo", number: 3),
  item(login: "me", status: "Backlog", number: 4)
]
kept = E.assigned_not_started(items, login: "me",
                                     not_started: ["Todo", "Backlog", "No Status"])
check "#3 project filter keeps mine+Todo and mine+Backlog",
      kept.map { |i| i["content"]["number"] }.sort, [1, 4]

# =============================================================================
# Search query scoping
# =============================================================================
check "owed query is account-wide without org",
      E.reviews_owed_query("me"),
      "is:open is:pr review-requested:me archived:false"
check "owed query scoped to org when given",
      E.reviews_owed_query("me", org: "Recognize"),
      "is:open is:pr review-requested:me org:Recognize archived:false"
check "mine query scoped to org when given",
      E.my_prs_query("me", org: "Recognize"),
      "is:open is:pr author:me org:Recognize archived:false"
check "empty org is treated as no scope",
      E.my_prs_query("me", org: ""),
      "is:open is:pr author:me archived:false"

# =============================================================================
# URL parse
# =============================================================================
check "URL parse orgs/Recognize/projects/10/views/5",
      E.parse_project_url("https://github.com/orgs/Recognize/projects/10/views/5"),
      { org: "Recognize", num: 10 }

# =============================================================================
# Surfaces
# =============================================================================

# 12. Surface dispatch
check "#12a default -> terminal",
      S.resolve_surface(output_env: "terminal", browser_flag: false), :terminal
check "#12b OUTPUT=browser -> browser",
      S.resolve_surface(output_env: "browser", browser_flag: false), :browser
check "#12c --browser overrides OUTPUT=terminal",
      S.resolve_surface(output_env: "terminal", browser_flag: true), :browser

# Build buckets via the real classifier for HTML assertions.
config = {
  login: "me", not_started: ["Todo", "Backlog", "No Status"],
  iteration_filter: "off", iteration_field: "Iteration",
  stale_days: 2, day_mode: "business"
}
buckets = E.classify(
  owed_prs: [pr(number: 101, title: "Review me", url: "https://github.com/o/r/pull/101", created: D.(2026, 6, 18))],
  my_prs: [
    pr(number: 201, title: "Draft work", url: "https://github.com/o/r/pull/201", isDraft: true, created: D.(2026, 6, 18)),
    pr(number: 202, title: "Gone quiet", url: "https://github.com/o/r/pull/202", created: D.(2026, 6, 15), last_request: D.(2026, 6, 17), review_requests_total: 1),
    pr(number: 203, title: "No reviewer", url: "https://github.com/o/r/pull/203", created: D.(2026, 6, 18))
  ],
  project_items: items,
  config: config, today: TODAY
)

html = B.render(buckets, config: config, generated_at: TODAY)

# 13. HTML structure
ok "#13a starts with <!DOCTYPE html>", html.start_with?("<!DOCTYPE html>")
ok "#13b contains item number 101", html.include?("#101")
ok "#13c contains item title 'Gone quiet'", html.include?("Gone quiet")
ok "#13d contains item url 201", html.include?("https://github.com/o/r/pull/201")
ok "#13e contains all bucket headings", Kamandar::Engine::BUCKETS.all? { |_, title, _| html.include?(title) }
ok "#13f no external <link> asset", !html.include?("<link")
ok "#13g no external <script src=> asset", !(html =~ /<script\b[^>]*\bsrc=/)
ok "#13h no http(s) asset in style block",
   !(html[/<style>.*?<\/style>/m].to_s =~ %r{https?://})

# 14. HTML contains no secret
SENTINEL = "ghp_SENTINEL_SECRET_TOKEN_DO_NOT_LEAK"
html_secret = B.render(buckets,
                       config: config.merge(token: SENTINEL),
                       generated_at: TODAY)
ok "#14 rendered HTML contains no token", !html_secret.include?(SENTINEL)

# 15. browser_open_command pure builder
check "#15a darwin -> open",
      S.browser_open_command("darwin21", "file:///t.html"), ["open", "file:///t.html"]
check "#15b linux -> xdg-open",
      S.browser_open_command("linux-gnu", "file:///t.html"), ["xdg-open", "file:///t.html"]
check "#15c windows -> cmd /c start",
      S.browser_open_command("mswin32", "C:\\t.html"), ["cmd", "/c", "start", "", "C:\\t.html"]

# -- bonus: terminal renderer sanity ------------------------------------------
term = T.render(buckets, config: config, generated_at: TODAY)
ok "terminal shows stale handoff suffix",
   term.include?("business days since you handed off")
ok "terminal lists reviews-owed item", term.include?("#101 Review me")

# =============================================================================
# Network errors + spinner (CLI robustness)
# =============================================================================

# 16. GitHub::Error is a clean, catchable failure type.
ok "#16a GitHub::Error < StandardError", Kamandar::GitHub::Error.ancestors.include?(StandardError)
ok "#16b NETWORK_ERRORS covers connect timeout",
   Kamandar::GitHub::NETWORK_ERRORS.include?(Net::OpenTimeout)

# 17. with_spinner: on a non-tty stderr (pipe/cron) it just yields, returns the
#     block value, and writes nothing to stderr — keeping captured output clean.
def without_tty
  old = $stderr
  $stderr = StringIO.new
  [yield, $stderr.string]
ensure
  $stderr = old
end

val, noise = without_tty { Kamandar::CLI.with_spinner("loading") { 7 * 6 } }
check "#17a with_spinner returns block value (non-tty)", val, 42
ok "#17b with_spinner writes nothing on non-tty", noise.empty?

# 18. with_spinner propagates exceptions raised inside the block.
raised = nil
without_tty do
  begin
    Kamandar::CLI.with_spinner("loading") { raise Kamandar::GitHub::Error, "boom" }
  rescue Kamandar::GitHub::Error => e
    raised = e.message
  end
end
check "#18 with_spinner re-raises block error", raised, "boom"

# =============================================================================
puts "=" * 50
puts "#{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
