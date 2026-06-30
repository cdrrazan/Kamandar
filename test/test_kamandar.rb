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
MB = Kamandar::MenubarSurface

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

# -- project membership (board item OR closes a board issue) ------------------
# A board holds Issue items and (rarely) PullRequest items. A PR belongs to the
# project if it is a board item, OR it closes an issue that is on the board —
# the usual case, since boards track issues and PRs link via "Closes #N".
def pr_item(url:)
  {
    "fieldValues" => { "nodes" => [] },
    "content" => { "__typename" => "PullRequest", "url" => url,
                   "repository" => { "nameWithOwner" => "o/r" } }
  }
end

# helper: a PR node that closes the given issue url(s)
def pr_closing(number:, url:, closes: [])
  pr(number: number, repo: "o/r", url: url, created: D.(2026, 6, 18))
    .merge("closingIssuesReferences" => { "nodes" => closes.map { |u| { "url" => u } } })
end

ISSUE_URL = "https://github.com/o/r/issues/1"
board_items = [
  item(login: "me", status: "Todo", number: 1),     # Issue item -> issue url derived below
  pr_item(url: "https://github.com/o/r/pull/5")      # a PR carded directly on the board
]
check "project_pr_urls collects PullRequest items",
      E.project_pr_urls(board_items), ["https://github.com/o/r/pull/5"]
check "project_issue_urls collects Issue items",
      E.project_issue_urls(board_items), [ISSUE_URL]

prs_for_filter = [
  pr_closing(number: 5, url: "https://github.com/o/r/pull/5", closes: []),           # board item
  pr_closing(number: 8, url: "https://github.com/o/r/pull/8", closes: [ISSUE_URL]),  # closes board issue
  pr_closing(number: 9, url: "https://github.com/o/r/pull/9", closes: ["https://github.com/o/r/issues/99"]) # other board
]
kept_on_project = E.filter_prs_on_project(
  prs_for_filter,
  pr_urls: E.project_pr_urls(board_items),
  issue_urls: E.project_issue_urls(board_items)
)
check "filter_prs_on_project keeps board items and PRs closing a board issue",
      kept_on_project.map { |p| p["number"] }.sort, [5, 8]

# project scope: a review you owe is shown as the board ISSUE the PR closes
proj_items = [item(login: "me", status: "Ready for Review", number: 50)] # url .../issues/50
cfg_proj = { login: "me", scope: { mode: "project" },
             not_started: [], review_statuses: [], qa_statuses: [], blocked_statuses: [],
             stale_days: 2, day_mode: "business" }
owed_linked = [pr(number: 900, title: "PR for 50", url: "https://github.com/o/r/pull/900", created: D.(2026, 6, 18))
                 .merge("closingIssuesReferences" => { "nodes" => [{ "url" => "https://github.com/o/r/issues/50" }] })]
b_linked = E.classify(owed_prs: owed_linked, my_prs: [], project_items: proj_items,
                      config: cfg_proj, today: TODAY)
check "project reviews-owed resolves to the linked board issue",
      b_linked[:reviews_owed].map { |r| r[:number] }, [50]
check "project reviews-owed points at the issue url",
      b_linked[:reviews_owed].first[:url], "https://github.com/o/r/issues/50"

# a PR that closes no board issue is shown as the PR itself
owed_unlinked = [pr(number: 901, title: "Loose PR", url: "https://github.com/o/r/pull/901", created: D.(2026, 6, 18))]
b_unlinked = E.classify(owed_prs: owed_unlinked, my_prs: [], project_items: proj_items,
                        config: cfg_proj, today: TODAY)
check "project reviews-owed falls back to the PR when no board issue",
      b_unlinked[:reviews_owed].map { |r| r[:number] }, [901]

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

# --demo flag fabricates data and needs no token/login.
check "config --demo flag off by default",
      Kamandar::Config.from(env: {}, argv: [])[:demo], false
check "config --demo flag sets demo",
      Kamandar::Config.from(env: {}, argv: ["--demo"])[:demo], true

# -- config file (KEY=VALUE persistence) --------------------------------------
# Pure parse/serialize + precedence. Uses a temp file so nothing touches the
# real ~/.config and the suite stays hermetic (zero network, zero shared state).
require "tmpdir"
require "fileutils"

CFG_TXT = <<~CFG
  # a comment
  GITHUB_TOKEN=tok_from_file
  GH_LOGIN = filelogin
  export PROJECT_URL="https://github.com/orgs/Acme/projects/4"
  STALE_DAYS=5
  EMPTY=

  bogus line without equals
CFG

Dir.mktmpdir("kamandar-cfg") do |dir|
  path = File.join(dir, "config")
  File.write(path, CFG_TXT)

  parsed = Kamandar::Config.load_file(path)
  check "config file: parses KEY=VALUE",        parsed["GITHUB_TOKEN"], "tok_from_file"
  check "config file: trims whitespace",        parsed["GH_LOGIN"],     "filelogin"
  check "config file: strips quotes + export",  parsed["PROJECT_URL"],  "https://github.com/orgs/Acme/projects/4"
  check "config file: keeps other keys",        parsed["STALE_DAYS"],   "5"
  check "config file: skips blank value",       parsed.key?("EMPTY"),   true
  check "config file: skips non KEY=VALUE",     parsed.key?("bogus line without equals"), false

  # Missing file never raises — just an empty hash.
  check "config file: missing file is empty",   Kamandar::Config.load_file(File.join(dir, "nope")), {}

  # KAMANDAR_CONFIG points Config.from at our temp file.
  cfg_file = Kamandar::Config.from(env: { "KAMANDAR_CONFIG" => path }, argv: [])
  check "config file: feeds token into config", cfg_file[:token],       "tok_from_file"
  check "config file: feeds login into config", cfg_file[:login],       "filelogin"
  check "config file: feeds stale_days",        cfg_file[:stale_days],  5

  # Real ENV (present + non-empty) wins over the file.
  cfg_override = Kamandar::Config.from(
    env: { "KAMANDAR_CONFIG" => path, "GH_LOGIN" => "envlogin" }, argv: []
  )
  check "config file: ENV overrides file",      cfg_override[:login],   "envlogin"
  check "config file: file fills the gaps",     cfg_override[:token],   "tok_from_file"
end

# config_path: KAMANDAR_CONFIG wins, else XDG_CONFIG_HOME/kamandar/config.
check "config_path: honours KAMANDAR_CONFIG",
      Kamandar::Config.config_path("KAMANDAR_CONFIG" => "/tmp/x"), "/tmp/x"
check "config_path: uses XDG_CONFIG_HOME",
      Kamandar::Config.config_path("XDG_CONFIG_HOME" => "/cfg"), "/cfg/kamandar/config"

# render_file: round-trips through load_file, quotes values that need it.
RENDER_OUT = Kamandar::Config.render_file(
  "GITHUB_TOKEN" => "abc", "GH_LOGIN" => "me", "PROJECT_URL" => "", "X" => "a b"
)
check "render_file: drops empty values",  RENDER_OUT.include?("PROJECT_URL"), false
check "render_file: quotes spaced value", RENDER_OUT.include?('X="a b"'),     true
Dir.mktmpdir("kamandar-rt") do |dir|
  p = File.join(dir, "c")
  File.write(p, RENDER_OUT)
  check "render_file: round-trips via load_file",
        Kamandar::Config.load_file(p)["GH_LOGIN"], "me"
end

# --init flag wiring + viewer query string.
check "config --init flag off by default",
      Kamandar::Config.from(env: {}, argv: [])[:init], false
check "config --init flag sets init",
      Kamandar::Config.from(env: {}, argv: ["--init"])[:init], true
check "viewer query asks for login",
      Kamandar::Engine.build_viewer_query.include?("viewer { login }"), true

# --tunnel flag: spawns cloudflared alongside --serve.
check "config --tunnel off by default",
      Kamandar::Config.from(env: {}, argv: [])[:tunnel], false
check "config --tunnel default name",
      Kamandar::Config.from(env: {}, argv: [])[:tunnel_name], "kamandar"
check "config --tunnel sets tunnel",
      Kamandar::Config.from(env: {}, argv: ["--tunnel"])[:tunnel], true
check "config --tunnel NAME sets name",
      Kamandar::Config.from(env: {}, argv: ["--tunnel", "myedge"])[:tunnel_name], "myedge"
check "config --tunnel=NAME sets name",
      Kamandar::Config.from(env: {}, argv: ["--tunnel=foo"])[:tunnel_name], "foo"
check "config --tunnel doesn't swallow next flag",
      Kamandar::Config.from(env: {}, argv: ["--tunnel", "--port", "8080"])[:tunnel_name], "kamandar"
check "config --tunnel port still parses",
      Kamandar::Config.from(env: {}, argv: ["--tunnel", "--port", "8080"])[:port], 8080
check "config KAMANDAR_TUNNEL env sets name",
      Kamandar::Config.from(env: { "KAMANDAR_TUNNEL" => "envedge" }, argv: [])[:tunnel_name], "envedge"
check "config --tunnel flag beats env name",
      Kamandar::Config.from(env: { "KAMANDAR_TUNNEL" => "envedge" }, argv: ["--tunnel=cliedge"])[:tunnel_name], "cliedge"

# --no-open flag: suppresses the browser auto-open (the persistent --serve daemon
# must not spawn a tab on every KeepAlive restart). Off by default.
check "config --no-open off by default",
      Kamandar::Config.from(env: {}, argv: [])[:no_open], false
check "config --no-open sets no_open",
      Kamandar::Config.from(env: {}, argv: ["--serve", "--no-open"])[:no_open], true

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
ok "picker: invalid choice shows a retry message", badchoice_text.include?("type 1, 2, 3, or 4")
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
check "#12d OUTPUT=menubar -> menubar",
      S.resolve_surface(output_env: "menubar", browser_flag: false), :menubar
check "#12e --menubar wins over --browser",
      S.resolve_surface(output_env: "terminal", browser_flag: true, menubar_flag: true), :menubar

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
ok "terminal (plain) has no ANSI escapes", !term.include?("\e[")

# color mode adds ANSI; stripping the escapes still leaves the content
term_color = T.render(buckets, config: config, generated_at: TODAY, color: true)
ok "terminal (color) emits ANSI escapes", term_color.include?("\e[")
stripped = term_color.gsub(/\e\[[0-9;]*m/, "")
ok "terminal color content survives stripping (number+title)", stripped.include?("#101 Review me")
ok "terminal color content survives stripping (repo)", stripped.include?("(o/r)")
ok "terminal color shows a bucket emoji", term_color.include?("\u{1F4E5}")

# matrix theme: green boxed panels
term_matrix = T.render(buckets, config: config, generated_at: TODAY, theme: :matrix)
ok "matrix theme draws box borders", term_matrix.include?("╔") && term_matrix.include?("╚")
ok "matrix theme uses bright green", term_matrix.include?("\e[1;92m")
ok "matrix theme keeps content (after stripping)",
   term_matrix.gsub(/\e\[[0-9;]*m/, "").include?("#101 Review me")
ok "matrix theme upcases bucket titles", term_matrix.include?("REVIEWS YOU OWE")

# -- terminal layout: number alignment + entry spacing ------------------------
# A bucket with mixed-width numbers (#10488 vs #8) must left-pad #number so
# titles start at the same column, and put a blank line between entries.
layout_buckets = { reviews_owed: [
  { number: 10488, title: "Wide one", repo: "o/r", url: "https://x/10488" },
  { number: 8,     title: "Narrow one", repo: "o/r", url: "https://x/8" }
] }
layout_cfg = { login: "me", day_mode: "business", scope: { mode: "global" } }
layout = T.render(layout_buckets, config: layout_cfg, generated_at: TODAY) # plain
ok "aligns #number column (pads #8 to #10488 width)", layout.include?("  #8     Narrow one")
ok "wide number is not padded", layout.include?("  #10488 Wide one")
ok "blank line separates entries", layout.include?("https://x/10488\n\n  #8")
ok "single spacing only — never a double blank line", !layout.include?("\n\n\n")

# -- terminal color: 256-color palette (legible on light + dark) --------------
palette_buckets = { reviews_owed: [{ number: 1, title: "t", repo: "o/r", url: "u" }],
                    stale: [{ number: 2, title: "s", repo: "o/r", url: "u",
                              days: 303, mode: "business" }] }
palette = T.render(palette_buckets, config: layout_cfg, generated_at: TODAY, color: true)
ok "titles use a bold 256-color code (not 16-color bright)", palette.include?("\e[1;38;5;")
ok "blue accent for reviews_owed", palette.include?("\e[1;38;5;33m")
ok "stale suffix uses the amber 256-color (was washed-out yellow 33)",
   palette.include?("\e[38;5;172m")
ok "no legacy 16-color title codes remain", !palette.include?("\e[1;33m") && !palette.include?("\e[1;36m")

# -- bonus: full-screen dashboard (digital rain + panels) ---------------------
DASH = Kamandar::DashboardSurface

# rain_frame: a cols×rows grid that clears+homes, fades green, emits glyphs.
heads = DASH.init_heads(10, 8)
frame = DASH.rain_frame(cols: 10, rows: 8, heads: heads.map { 4 })
ok "rain_frame clears and homes", frame.start_with?("\e[2J\e[H")
ok "rain_frame has rows-1 row separators", frame.scan("\r\n").size == 7
ok "rain_frame paints near-white head", frame.include?("\e[1;97m")
ok "rain_frame fades to dim green trail", frame.include?("\e[2;32m")
ok "rain_frame draws a glyph", DASH::GLYPHS.any? { |g| frame.include?(g) }

# init_heads / step_heads: one head per column, advances and respawns off-screen.
ok "init_heads is one per column", DASH.init_heads(12, 8).size == 12
ok "step_heads advances each head by one", DASH.step_heads([0, 1, 2], 8) == [1, 2, 3]
ok "step_heads respawns a head that fell off", DASH.step_heads([100], 8).first <= 0

# render: header, footer, green panels, windowed to the row budget.
dash = DASH.render(buckets, config: config, generated_at: TODAY, rows: 24, cols: 80)
dash_plain = dash.gsub(/\e\[[0-9;]*m/, "")
ok "dashboard clears and homes", dash.start_with?("\e[2J\e[H")
ok "dashboard shows the brand", dash_plain.include?("KAMANDAR")
ok "dashboard upcases bucket titles", dash_plain.include?("REVIEWS YOU OWE")
ok "dashboard keeps content (after stripping)", dash_plain.include?("#101 Review me")
ok "dashboard draws panel borders", dash.include?("╔") && dash.include?("╚")
ok "dashboard footer offers quit", dash_plain.include?("[q] quit")
ok "dashboard uses bright green", dash.include?("\e[1;92m")
check "dashboard fills exactly rows lines", dash.split("\r\n").size, 24

# -- bonus: menu-bar surface (SwiftBar/xbar plugin) ---------------------------
# Same buckets/config as above (project scope; reviews_owed has #101).
menu = MB.render(buckets, config: config, generated_at: TODAY)
menu_lines = menu.lines.map(&:chomp)
ok "menubar title is the bow + total open",
   menu_lines.first.start_with?("\u{1F3F9} ")
ok "menubar tints the bar when a review is owed",
   menu_lines.first.include?("color=#db6d28")
ok "menubar has the dropdown separator", menu_lines.include?("---")
ok "menubar shows a bucket header with its count",
   menu.include?("Reviews you owe (1)")
ok "menubar links a row to its PR url",
   menu.include?("href=https://github.com/o/r/pull/101")
ok "menubar nests rows as submenu items", menu.include?("--#101 Review me")
ok "menubar offers a refresh action", menu.include?("Refresh | refresh=true")
ok "menubar links to the local web app",
   menu.include?("href=http://127.0.0.1:4567")

# caps rows per bucket and links the overflow to the web app
big = { reviews_owed: Array.new(15) { |i| { number: i, title: "t#{i}", url: "u#{i}", repo: "o/r" } } }
menu_big = MB.render(big, config: { login: "me", scope: { mode: "global" } }, generated_at: TODAY)
ok "menubar caps a bucket at MAX_ROWS rows",
   menu_big.scan(/^--#/).size == Kamandar::MenubarSurface::MAX_ROWS
ok "menubar shows an overflow line", menu_big.include?("…and 3 more")

# pipes in titles can't break the SwiftBar param parser
menu_pipe = MB.render(
  { reviews_owed: [{ number: 9, title: "a | b", url: "u", repo: "o/r" }] },
  config: { login: "me", scope: { mode: "global" } }, generated_at: TODAY
)
ok "menubar neutralizes pipes in titles",
   menu_pipe.include?("a ¦ b") && !menu_pipe.include?("a | b")

# never leaks the token, like every other surface
ok "menubar output contains no token",
   !MB.render(buckets, config: config.merge(token: SENTINEL), generated_at: TODAY).include?(SENTINEL)

# error doc flags the failure and offers a retry
menu_err = MB.error("API rate limited")
ok "menubar error shows the message", menu_err.include?("API rate limited")
ok "menubar error offers retry", menu_err.include?("refresh=true")

# -- bonus: local web app (Server + ServerSurface) ----------------------------
SRV  = Kamandar::Server
SURF = Kamandar::ServerSurface

# parse_request: pulls method, path, and decoded query off the request line.
req = SRV.parse_request("GET /?mode=org&name=Recognize HTTP/1.1\r\nHost: x\r\n\r\n")
check "parse_request method", req[:method], "GET"
check "parse_request path", req[:path], "/"
check "parse_request query mode", req[:query]["mode"], "org"
check "parse_request query name", req[:query]["name"], "Recognize"
ok "parse_request returns nil on garbage", SRV.parse_request("").nil?

# http_response: a well-formed HTTP/1.1 head with an accurate Content-Length.
resp = SRV.http_response(200, "héllo") # multibyte: length must be in BYTES
ok "http_response status line", resp.start_with?("HTTP/1.1 200 OK\r\n")
ok "http_response closes the connection", resp.include?("Connection: close")
ok "http_response Content-Length is byte count",
   resp.include?("Content-Length: #{'héllo'.bytesize}")
check "http_response 404 reason", SRV.http_response(404, "x").lines.first, "HTTP/1.1 404 Not Found\r\n"

# resolve_scope: form query -> Engine scope hash (+ raw inputs for re-render).
glob = SRV.resolve_scope({}, project_org: nil)
check "resolve_scope blank -> global", glob[:scope], { mode: "global" }
org = SRV.resolve_scope({ "mode" => "org", "name" => "Recognize" }, project_org: nil)
check "resolve_scope org:NAME", org[:scope], { mode: "org", org: "Recognize" }
bare = SRV.resolve_scope({ "mode" => "org" }, project_org: "Acme")
check "resolve_scope bare org reuses project_org", bare[:scope], { mode: "org", org: "Acme" }
repo = SRV.resolve_scope({ "mode" => "repo", "name" => "o/r" }, project_org: nil)
check "resolve_scope repo:owner/name", repo[:scope], { mode: "repo", repo: "o/r" }
proj = SRV.resolve_scope({ "mode" => "project", "project_url" => "u", "poll" => "30" }, project_org: nil)
check "resolve_scope project mode", proj[:scope], { mode: "project" }
check "resolve_scope carries project_url", proj[:project_url], "u"
check "resolve_scope carries poll", proj[:poll], 30

# self_link: round-trips the current selection, dropping empties.
check "self_link with no selection -> /", SURF.self_link("global", "", "", 0), "/"
ok "self_link keeps mode + name",
   SURF.self_link("org", "Recognize", "", 0) == "/?mode=org&name=Recognize"

# page: the live page reuses the cards, adds controls, and leaks no token.
SECRET = "ghp_supersecrettoken"
page = SURF.page(buckets, config: config.merge(token: SECRET),
                          generated_at: TODAY, mode: "org", name: "Acme", poll: 60)
ok "server page is HTML", page.start_with?("<!DOCTYPE html>")
ok "server page reuses bucket content", page.include?("#101") && page.include?("Review me")
ok "server page has a scope control", page.include?(%(role="radiogroup")) &&
                                      page.include?(%(<input class="segr" type="radio" name="mode" id="m-org" value="org" checked>))
# scope fields are hidden by default and revealed by CSS :has() per scope.
ok "controls hide scope fields by default", page.include?(".controls .field{display:none}")
ok "controls reveal name for org/repo", page.include?(".controls:has(#m-org:checked) .f-name")
ok "controls reveal project url for project", page.include?(".controls:has(#m-project:checked) .f-proj")
# the toolbar (controls row) lives below the nav, inside the sticky header.
ok "controls live in a toolbar below the nav",
   page.index(%(<nav class="topbar">)) < page.index(%(<div class="toolbar">))
ok "server page has a refresh control", page.include?("↻")
ok "server page reflects poll interval", page.include?(%(http-equiv="refresh" content="60"))
ok "server page loads the Google Sans webfont",
   page.include?("fonts.googleapis.com/css2?family=Google+Sans") &&
   page.include?(%(<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>))
ok "server page applies Google Sans in CSS", page.include?(%(font-family:"Google Sans"))
# sidebar + CSS-only tabs (no JS): a hidden radio per bucket, a sidebar nav,
# and per-index rules that reveal the matching panel.
ok "server page has a sidebar nav", page.include?(%(<aside class="sidebar">)) &&
                                    page.include?(%(<label class="navitem"))
ok "server page builds radio tabs", page.include?(%(<input class="tabr" type="radio" name="kt" id="kt-0" checked>)) &&
                                    page.include?(%(id="kt-1"))
ok "server page panels are id'd", page.include?(%(<main class="panels">)) &&
                                  page.include?(%(id="kp-0"))
ok "server page generates tab rules", page.include?("#kt-0:checked~.panels #kp-0{display:block}")
ok "selected tab fills with the bucket color", page.include?('.navitem[for="kt-0"]{background:var(--c)')
ok "selected tab flips text to white", page.include?('.navitem[for="kt-0"] .navtitle{color:#fff}')
ok "server page stays script-free", !(page =~ /<script/)
# tab_css emits one show + one highlight rule per bucket, scaled to the count.
ok "tab_css scales to bucket count", SURF.tab_css(3).scan("display:block").size == 3

# --- Demo data + pagination -------------------------------------------------
DEMO = Kamandar::Demo
%w[project global].each do |dmode|
  db = DEMO.buckets(dmode)
  keys = E.bucket_meta(dmode).map(&:first)
  ok "demo #{dmode}: covers every bucket", db.keys.sort == keys.sort
  ok "demo #{dmode}: 15..20 rows per bucket", db.values.all? { |r| (15..20).cover?(r.size) }
  ok "demo #{dmode}: rows shaped like real cards",
     db.values.flatten.all? { |r| r[:number] && r[:title] && r[:repo] && r[:url] }
end
ok "demo stale rows carry a waiting badge",
   DEMO.buckets("project")[:stale].all? { |r| r[:days] && r[:mode] }
ok "demo is deterministic", DEMO.buckets("global") == DEMO.buckets("global")
ok "demo URLs point at github.com", DEMO.buckets("project")[:reviews_owed].all? { |r| r[:url].start_with?("https://github.com/") }

# pagination: a >PAGE_SIZE bucket splits into pages with a numbered pager.
demo_page = SURF.page(DEMO.buckets("project"), config: config, generated_at: TODAY, mode: "project")
ok "pagination splits long buckets into pages", demo_page.scan(%(<div class="page">)).size > 8
ok "pagination renders a numbered pager", demo_page.include?(%(<nav class="pager">))
ok "paginated buckets get the .paged class", demo_page =~ /class="bucket[^"]*\bpaged\b/
ok "pager_css shows the chosen page", demo_page.include?("#pg-0-0:checked~.pages>.page:nth-child(1){display:block}")
# a short bucket (<= PAGE_SIZE) gets no pager.
short = SURF.page({ reviews_owed: [{ number: "1", title: "x", repo: "a/b", url: "http://x" }] },
                  config: config, generated_at: TODAY, mode: "global")
ok "short buckets are not paginated", !short.include?(%(<nav class="pager">))
# premium chrome: top nav, sidebar header, and footer.
ok "server page has a top nav", page.include?(%(<nav class="topbar">)) &&
                                page.include?(%(<span class="brandname">Kamandar</span>))
# sidebar splits into two boxes: reviews (others' work) and your own work.
ok "sidebar has an Others' work box", page.include?(%(<span class="side-title">Others&#39; work</span>))
ok "sidebar has a Your work box", page.include?(%(<span class="side-title">Your work</span>))
ok "sidebar uses two carded boxes", page.scan(%(<section class="sidebox">)).size == 2
# sidebar tabs use short labels; the full title stays on the panel + tooltip.
ok "sidebar tab uses a short label", page.include?(%(<span class="navtitle">Reviews</span>))
ok "navitem keeps full title as tooltip", page.include?(%(title="Reviews you owe"))
ok "panel heading keeps full title", page.include?(%(<span class="htitle">Reviews you owe</span>))
# each panel explains what its bucket collects.
ok "panel shows a description", page.include?(%(<p class="desc">)) &&
   page.include?("review was requested from you")
# empty buckets render a centered empty-state card.
ok "empty bucket shows an empty-state card", page.include?(%(<div class="emptybox">)) &&
   page.include?(%(<p class="emptymsg">))
ok "server page has a footer", page.include?(%(<footer class="foot">)) &&
                               page.include?("Kamandar v#{Kamandar::VERSION}")
ok "footer shows the generated time", page.include?("generated ")
# GitHub repo link appears in both the nav and the footer.
ok "page links to the GitHub repo", page.scan(%(href="#{Kamandar::ServerSurface::REPO_URL}")).size >= 2
ok "GitHub link opens in a new tab safely", page.include?(%(class="ghlink" href="#{Kamandar::ServerSurface::REPO_URL}" target="_blank" rel="noopener"))

# error_page: same chrome, no token, still renders a retry link.
errp = SURF.error_page("boom", config: config.merge(token: SECRET))
ok "error_page shows the message", errp.include?("boom")
ok "error_page offers a retry link", errp.include?(%(href="/"))
ok "error_page leaks no token", !errp.include?(SECRET)

# end-to-end: a real socket round-trip through handle_request (stubbed fetch).
require "socket"
module Kamandar::CLI
  def self.fetch_and_classify(_config) # stub: no network in tests
    { reviews_owed: [{ number: 1, title: "Served", repo: "o/r", url: "http://x" }] }
  end
end
srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]
acceptor = Thread.new do
  c = srv.accept
  Kamandar::CLI.handle_request(c, config.merge(scope: { mode: "global" }))
  c.close
end
sock = TCPSocket.new("127.0.0.1", port)
sock.write("GET /?mode=global HTTP/1.1\r\nHost: localhost\r\n\r\n")
served = sock.read
sock.close
acceptor.join
srv.close
ok "live server returns 200", served.start_with?("HTTP/1.1 200 OK")
ok "live server serves the page body", served.include?("Served")
ok "live server response never carries the token", !served.include?(SECRET)

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
