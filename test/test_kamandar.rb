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

# in_review: issues assigned to me whose Status is in the review set
review_items = [
  item(login: "me", status: "In Review", number: 10),
  item(login: "me", status: "In Progress", number: 11),
  item(login: "other", status: "In Review", number: 12),
  item(login: "me", status: "needs review", number: 13) # case-insensitive
]
in_rev = E.assigned_in_review(review_items, login: "me",
                                            review_statuses: ["In Review", "Needs Review"])
check "in_review keeps mine + review status (case-insensitive)",
      in_rev.map { |i| i["content"]["number"] }.sort, [10, 13]

# in_qa: issues assigned to me whose Status is in the QA set
qa_items = [
  item(login: "me", status: "Ready for QA", number: 20),
  item(login: "me", status: "In Review", number: 21),
  item(login: "other", status: "Ready for QA", number: 22)
]
in_qa = E.assigned_in_qa(qa_items, login: "me", qa_statuses: ["Ready for QA", "QA"])
check "in_qa keeps mine + QA status",
      in_qa.map { |i| i["content"]["number"] }.sort, [20]

# blocked: issues assigned to me whose Status is in the blocked set
blocked_items = [
  item(login: "me", status: "Blocked", number: 30),
  item(login: "me", status: "On Hold", number: 31),
  item(login: "me", status: "In Progress", number: 32)
]
blocked = E.assigned_blocked(blocked_items, login: "me",
                                            blocked_statuses: ["Blocked", "On Hold"])
check "blocked keeps mine + blocked status",
      blocked.map { |i| i["content"]["number"] }.sort, [30, 31]

# --statuses diagnostic: every issue assigned to me, with its raw Status
breakdown = E.assigned_status_breakdown(review_items, login: "me")
check "status breakdown lists only my issues",
      breakdown.map { |r| r[:number] }.sort, [10, 11, 13]
check "status breakdown carries the raw Status label",
      breakdown.find { |r| r[:number] == 10 }[:status], "In Review"

# =============================================================================
# Search query scoping
# =============================================================================
check "owed query is account-wide without qualifier",
      E.reviews_owed_query("me"),
      "is:open is:pr review-requested:me archived:false"
check "owed query takes an org qualifier",
      E.reviews_owed_query("me", qualifier: "org:Recognize"),
      "is:open is:pr review-requested:me org:Recognize archived:false"
check "mine query takes a repo qualifier",
      E.my_prs_query("me", qualifier: "repo:o/r"),
      "is:open is:pr author:me repo:o/r archived:false"
check "empty qualifier is no scope",
      E.my_prs_query("me", qualifier: ""),
      "is:open is:pr author:me archived:false"

# -- scope resolution (4 modes) -----------------------------------------------
check "scope: blank -> global",      E.parse_scope(""),        { mode: "global" }
check "scope: 'global' -> global",   E.parse_scope("global"),  { mode: "global" }
check "scope: 'org:Foo' -> org",     E.parse_scope("org:Foo"), { mode: "org", org: "Foo" }
check "scope: bare 'org' uses project_org",
      E.parse_scope("org", project_org: "Recognize"), { mode: "org", org: "Recognize" }
check "scope: bare 'org' with no project_org -> global",
      E.parse_scope("org"), { mode: "global" }
check "scope: 'repo:o/r' -> repo",   E.parse_scope("repo:o/r"), { mode: "repo", repo: "o/r" }
check "scope: 'project' -> project", E.parse_scope("project"),  { mode: "project" }
check "scope: unknown -> global",    E.parse_scope("bananas"),  { mode: "global" }

check "qualifier for org",  E.search_qualifier({ mode: "org", org: "Foo" }),  "org:Foo"
check "qualifier for repo", E.search_qualifier({ mode: "repo", repo: "o/r" }), "repo:o/r"
check "qualifier for global is empty",  E.search_qualifier({ mode: "global" }),  ""
check "qualifier for project is empty (post-filtered)",
      E.search_qualifier({ mode: "project" }), ""

check "scope_label project", E.scope_label({ mode: "project" }), "project"
check "scope_label repo",    E.scope_label({ mode: "repo", repo: "o/r" }), "repo:o/r"

# -- project board membership (PR items, by url) ------------------------------
# A board can hold Issue items and PullRequest items; project scope filters PR
# buckets to the PullRequest items only, matched by url (not by repo — a
# monorepo would leak PRs from other boards).
def pr_item(url:)
  {
    "fieldValues" => { "nodes" => [] },
    "content" => { "__typename" => "PullRequest", "url" => url,
                   "repository" => { "nameWithOwner" => "o/r" } }
  }
end

board_items = [
  item(login: "me", status: "Todo", number: 1),                 # Issue item, ignored
  pr_item(url: "https://github.com/o/r/pull/5"),                 # PR on the board
  pr_item(url: "https://github.com/o/r/pull/9")                  # PR on the board
]
check "project_pr_urls collects only PullRequest items",
      E.project_pr_urls(board_items),
      ["https://github.com/o/r/pull/5", "https://github.com/o/r/pull/9"]

prs_for_filter = [
  pr(number: 5, repo: "o/r", url: "https://github.com/o/r/pull/5", created: D.(2026, 6, 18)),
  pr(number: 7, repo: "o/r", url: "https://github.com/o/r/pull/7", created: D.(2026, 6, 18))
]
check "filter_prs_by_urls keeps only PRs on the board",
      E.filter_prs_by_urls(prs_for_filter, E.project_pr_urls(board_items)).map { |p| p["number"] },
      [5]

# -- Config wires scope from env + --scope flag -------------------------------
cfg_default = Kamandar::Config.from(env: {}, argv: [])
check "config default scope is global", cfg_default[:scope], { mode: "global" }

cfg_env_repo = Kamandar::Config.from(env: { "SCOPE" => "repo:o/r" }, argv: [])
check "config reads SCOPE env", cfg_env_repo[:scope], { mode: "repo", repo: "o/r" }

cfg_org_from_url = Kamandar::Config.from(
  env: { "SCOPE" => "org", "PROJECT_URL" => "https://github.com/orgs/Recognize/projects/10/views/5" },
  argv: []
)
check "config 'org' scope derives org from PROJECT_URL",
      cfg_org_from_url[:scope], { mode: "org", org: "Recognize" }

cfg_flag = Kamandar::Config.from(env: { "SCOPE" => "global" }, argv: ["--scope", "project"])
check "config --scope flag overrides SCOPE env",
      cfg_flag[:scope], { mode: "project" }

# scope_given drives whether the interactive picker runs.
check "scope_given false when neither env nor flag set",
      Kamandar::Config.from(env: {}, argv: [])[:scope_given], false
check "scope_given true when SCOPE env set",
      Kamandar::Config.from(env: { "SCOPE" => "org:Foo" }, argv: [])[:scope_given], true
check "scope_given true when --scope flag set",
      Kamandar::Config.from(env: {}, argv: ["--scope", "global"])[:scope_given], true

# -- interactive scope picker -------------------------------------------------
# Feeds canned stdin; captures the prompt on a StringIO so nothing hits stderr.
# Returns [{scope:, project_url:}, prompt_text].
def pick(keystrokes, project_url: nil)
  out = StringIO.new
  res = Kamandar::CLI.prompt_scope({ project_url: project_url },
                                   input: StringIO.new(keystrokes), out: out)
  [res, out.string]
end

check "picker: Enter -> global",        pick("\n").first[:scope],            { mode: "global" }
check "picker: '1' -> global",          pick("1\n").first[:scope],           { mode: "global" }
check "picker: '2' + name -> org",      pick("2\nRecognize\n").first[:scope], { mode: "org", org: "Recognize" }
check "picker: '2' + blank -> global",  pick("2\n\n").first[:scope],         { mode: "global" }
check "picker: '3' + owner/name -> repo", pick("3\nacme/api\n").first[:scope], { mode: "repo", repo: "acme/api" }

# valid_repo? guards the "owner/name" shape
ok "valid_repo? accepts owner/name",  E.valid_repo?("Recognize/recognize")
ok "valid_repo? rejects bare name",   !E.valid_repo?("recognize")
ok "valid_repo? rejects trailing slash", !E.valid_repo?("acme/")
ok "valid_repo? rejects spaces",      !E.valid_repo?("acme / api")

# '3' re-prompts on a bare name (no slash), then accepts owner/name
res_repo, repo_text = pick("3\nrecognize\nRecognize/recognize\n")
check "picker: '3' bare name then owner/name -> repo",
      res_repo[:scope], { mode: "repo", repo: "Recognize/recognize" }
ok "picker: '3' shows a retry message on bad repo", repo_text.include?("owner/name")
check "picker: '3' bad repo then blank -> global", pick("3\nrecognize\n\n").first[:scope], { mode: "global" }
check "picker: '4' with PROJECT_URL set -> project",
      pick("4\n", project_url: "https://github.com/orgs/Recognize/projects/10").first[:scope], { mode: "project" }

# '4' with no PROJECT_URL prompts for one; a valid URL is captured + used.
res_url, _ = pick("4\nhttps://github.com/orgs/Recognize/projects/10\n")
check "picker: '4' asks for URL -> project", res_url[:scope], { mode: "project" }
check "picker: '4' captures entered URL",
      res_url[:project_url], "https://github.com/orgs/Recognize/projects/10"

check "picker: '4' blank URL -> global",   pick("4\n\n").first[:scope],       { mode: "global" }

# '4' re-prompts on a malformed URL, then accepts a valid one
res_retry, retry_text = pick("4\nnope\nhttps://github.com/orgs/Recognize/projects/10\n")
check "picker: '4' bad URL then valid -> project", res_retry[:scope], { mode: "project" }
check "picker: '4' captures the retried URL",
      res_retry[:project_url], "https://github.com/orgs/Recognize/projects/10"
ok "picker: '4' shows a retry message on bad URL", retry_text.include?("Try again")

check "picker: '4' bad URL then blank -> global", pick("4\nnope\n\n").first[:scope], { mode: "global" }
check "picker: '4' bad URL then EOF -> global",   pick("4\nnope\n").first[:scope],  { mode: "global" }
# invalid choice re-prompts until a valid one (or blank) is entered
res_badchoice, badchoice_text = pick("google.com\n2\nRecognize\n")
check "picker: invalid choice then '2' -> org", res_badchoice[:scope], { mode: "org", org: "Recognize" }
ok "picker: invalid choice shows a retry message", badchoice_text.include?("please enter 1")
check "picker: invalid choice then blank -> global", pick("google.com\n\n").first[:scope], { mode: "global" }
check "picker: invalid choice then EOF -> global",   pick("google.com\n").first[:scope],   { mode: "global" }

_, prompt_text = pick("1\n")
ok "picker prompt lists all four modes",
   %w[global org repo project].all? { |m| prompt_text.include?(m) }

# -- empty-result hint --------------------------------------------------------
def warn_text(scope, buckets)
  out = StringIO.new
  Kamandar::CLI.warn_if_empty({ scope: scope }, buckets, out: out)
  out.string
end

ok "warn_if_empty: org + all empty -> hint",
   warn_text({ mode: "org", org: "Recognize" }, { reviews_owed: [], stale: [] })
     .include?("double-check the name")
ok "warn_if_empty: repo + all empty -> hint",
   !warn_text({ mode: "repo", repo: "o/r" }, { reviews_owed: [] }).empty?
ok "warn_if_empty: org but a bucket has rows -> no hint",
   warn_text({ mode: "org", org: "Recognize" }, { reviews_owed: [{ number: 1 }], stale: [] }).empty?
ok "warn_if_empty: global + all empty -> no hint (name not the cause)",
   warn_text({ mode: "global" }, { reviews_owed: [], stale: [] }).empty?

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
# project scope -> board-driven buckets are exercised.
config = {
  login: "me", scope: { mode: "project" },
  not_started: ["Todo", "Backlog", "No Status"],
  review_statuses: [], qa_statuses: [], blocked_statuses: [],
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
# Issue+PR scope (global/org/repo): assigned issues classified by linked PR
# =============================================================================
def linked_pr(draft: false, reviewer: false)
  {
    "isDraft" => draft,
    "reviewRequests" => { "totalCount" => reviewer ? 1 : 0 },
    "timelineItems" => { "nodes" => [] },
    "latestOpinionatedReviews" => { "nodes" => [] }
  }
end

def issue_node(number:, title: "Issue", repo: "o/r", linked: [])
  {
    "number" => number, "title" => title,
    "url" => "https://github.com/o/r/issues/#{number}",
    "repository" => { "nameWithOwner" => repo },
    "closedByPullRequestsReferences" => { "nodes" => linked }
  }
end

check "issue_pr_state: no PR -> not_started",
      E.issue_pr_state(issue_node(number: 1)), :not_started
check "issue_pr_state: draft PR -> draft",
      E.issue_pr_state(issue_node(number: 2, linked: [linked_pr(draft: true)])), :draft
check "issue_pr_state: ready + reviewer -> in_review",
      E.issue_pr_state(issue_node(number: 3, linked: [linked_pr(reviewer: true)])), :in_review
check "issue_pr_state: ready, no reviewer -> no_reviewer",
      E.issue_pr_state(issue_node(number: 4, linked: [linked_pr(reviewer: false)])), :no_reviewer

check "bucket_meta(project) is the board set",
      E.bucket_meta("project"), Kamandar::Engine::BUCKETS_PROJECT
check "bucket_meta(global) is the issue set",
      E.bucket_meta("global"), Kamandar::Engine::BUCKETS_ISSUE

issue_config = { login: "me", scope: { mode: "global" },
                 stale_days: 2, day_mode: "business" }
issue_buckets = E.classify(
  owed_prs: [pr(number: 101, title: "Review me", url: "https://github.com/o/r/pull/101", created: D.(2026, 6, 18))],
  my_prs: [pr(number: 202, title: "Gone quiet", url: "https://github.com/o/r/pull/202", created: D.(2026, 6, 15), last_request: D.(2026, 6, 17), review_requests_total: 1)],
  assigned_issues: [
    issue_node(number: 1, linked: []),
    issue_node(number: 2, linked: [linked_pr(draft: true)]),
    issue_node(number: 3, linked: [linked_pr(reviewer: true)]),
    issue_node(number: 4, linked: [linked_pr(reviewer: false)])
  ],
  config: issue_config, today: TODAY
)
check "issue mode: not started bucket",  issue_buckets[:assigned_todo].map { |r| r[:number] }, [1]
check "issue mode: PR draft bucket",      issue_buckets[:assigned_wip].map { |r| r[:number] }, [2]
check "issue mode: in review bucket",     issue_buckets[:assigned_review].map { |r| r[:number] }, [3]
check "issue mode: no reviewer bucket",   issue_buckets[:assigned_no_reviewer].map { |r| r[:number] }, [4]
check "issue mode: reviews owed kept",    issue_buckets[:reviews_owed].map { |r| r[:number] }, [101]
check "issue mode: gone quiet kept",      issue_buckets[:stale].map { |r| r[:number] }, [202]
ok "issue mode: no board-only keys",      !issue_buckets.key?(:in_qa) && !issue_buckets.key?(:blocked)

# issue-mode HTML renders the issue bucket set, not the board set
issue_html = B.render(issue_buckets, config: issue_config, generated_at: TODAY)
ok "issue HTML shows issue bucket heading", issue_html.include?("Assigned, PR in review")
ok "issue HTML omits board-only heading", !issue_html.include?("In QA")

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

# 18b. with_retries: succeeds after transient failures, no sleeping in tests.
calls = 0
res = Kamandar::GitHub.with_retries(max: 2, backoff: 0) do
  calls += 1
  raise SocketError, "blip" if calls < 3
  "ok"
end
check "#18b1 with_retries returns after recovering", res, "ok"
check "#18b2 with_retries used all attempts", calls, 3

# 18c. with_retries re-raises once attempts are exhausted.
tries = 0
exhausted = begin
  Kamandar::GitHub.with_retries(max: 1, backoff: 0) do
    tries += 1
    raise SocketError, "down"
  end
rescue SocketError => e
  e.message
end
check "#18c1 with_retries re-raises after exhaustion", exhausted, "down"
check "#18c2 with_retries attempted max+1 times", tries, 2

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
