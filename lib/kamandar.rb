#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# kamandar.rb — a personal GitHub command center (CLI)
# =============================================================================
#
# Kamandar (Persian for "archer") prints one developer's current GitHub work
# queue in a single command.
# Personal tool, single user, GitHub-only, serverless. Stdlib only.
#
# -----------------------------------------------------------------------------
# WHAT IT SHOWS — the bucket set depends on scope.
# -----------------------------------------------------------------------------
# PROJECT scope (board-driven) — seven buckets (+ one bonus):
#   1. Reviews you owe        — open PRs where review is requested *from you*.
#   2. Currently building     — your own open *draft* PRs (WIP).
#   3. Assigned, not started  — Projects V2 issues assigned to you whose Status
#                               is in a configurable "not started" set.
#   4. Submitted for review   — Projects V2 issues assigned to you whose Status
#                               is in a configurable "in review" set.
#   5. In QA                  — Projects V2 issues assigned to you whose Status
#                               is in a configurable "QA" set.
#   6. Blocked                — Projects V2 issues assigned to you whose Status
#                               is in a configurable "blocked" set (waiting on a
#                               requirement confirmation or someone's answer).
#   7. Your PRs gone quiet    — your *ready* (non-draft) PRs where the ball is
#                               on the reviewer and the wait exceeds a threshold.
#   +  Ready, no reviewer     — your non-draft PRs with nobody asked to review
#      requested (bonus)         and no reviews yet (invisible to everyone).
#
# GLOBAL / ORG / REPO scope (no board) — six buckets driven by each assigned
# issue's linked PR ("Closes #N"):
#   1. Reviews you owe        — same as above.
#   2. Assigned, not started  — issue assigned to you with no linked PR.
#   3. Assigned, PR in draft  — linked PR is a draft (WIP).
#   4. Assigned, PR in review — linked PR is ready and has a reviewer.
#   5. Assigned, no reviewer  — linked PR is ready but nobody is asked to review.
#   6. Your PRs gone quiet    — same as above.
#
# Architecture: Engine -> buckets -> Surface, in three separable layers.
#   * Engine   : pure, side-effect-free functions (GraphQL building, time math,
#                classification). Unit-testable with zero network.
#   * Buckets  : a plain hash the engine returns.
#   * Surface  : consumes buckets and emits output. Two implementations behind
#                one tiny contract (`render(buckets, ...) -> String` + `emit`).
#
# -----------------------------------------------------------------------------
# SETUP
# -----------------------------------------------------------------------------
#   1. Create a classic Personal Access Token with scopes: repo, read:org,
#      read:project.
#   2. Provide the two required values, easiest first:
#        ruby lib/kamandar.rb --init      # wizard: verify + save to a config file
#      or export them in your shell:
#        export GITHUB_TOKEN=ghp_xxx
#        export GH_LOGIN=your-username
#      or write ~/.config/kamandar/config (flat KEY=VALUE; $KAMANDAR_CONFIG
#      overrides the path). Precedence: CLI flags > env > config file.
#      (PROJECT_URL is optional — the scope picker asks for it when you choose
#       project scope; set it only to wire bucket #3 non-interactively.)
#      Tip: `./install.sh` symlinks the CLI to ~/.local/bin/kamandar.
#   3. Run:
#        ruby lib/kamandar.rb              # terminal output (default)
#        ruby lib/kamandar.rb --serve      # live web app at http://127.0.0.1:4567
#        ruby lib/kamandar.rb --serve --tunnel  # + a Cloudflare Tunnel child
#        ruby lib/kamandar.rb --dashboard  # full-screen Matrix TUI (rain splash)
#        ruby lib/kamandar.rb --browser    # render + open a static HTML page
#        ruby lib/kamandar.rb -b --watch 60  # live tab, refreshed every 60s
#        ruby lib/kamandar.rb --email      # send the daily-summary email now
#        ruby lib/kamandar.rb --email --demo  # print the digest (no SMTP send)
#        ruby lib/kamandar.rb --statuses   # list a board's Status labels (to
#                                          # configure NOT_STARTED/REVIEW_STATUSES)
#        ruby lib/kamandar.rb --init       # first-run wizard: save token + login
#
# -----------------------------------------------------------------------------
# CONFIGURATION (CLI flags take precedence over env vars)
# -----------------------------------------------------------------------------
#   GITHUB_TOKEN          (required)  classic PAT: repo, read:org, read:project
#   GH_LOGIN              (required)  your GitHub username
#   OUTPUT / --browser,-b (terminal) surface: terminal | browser; flag forces
#                                     browser and overrides OUTPUT
#   WATCH_SECONDS / --watch N  (0)    browser only: re-fetch + rewrite every N s
#   PROJECT_URL           (for #3)    board/view URL; org + project number read
#   SCOPE / --scope       (global)    PR-bucket scope, one of:
#                                       global            account-wide (default)
#                                       org[:NAME]        one org; bare `org`
#                                                         reuses PROJECT_URL's org
#                                       repo:owner/name   one repo
#                                       project           PRs that are items on
#                                                         the PROJECT_URL board
#                                     If unset and run in an interactive terminal,
#                                     you're prompted to pick a mode (Enter =
#                                     global). Skipped for pipes/cron/browser.
#   NOT_STARTED_STATUSES  (Todo,Backlog,No Status,Ready)  case-insensitive set
#   REVIEW_STATUSES       (In Review,Review,Needs Review)  statuses for bucket #4
#   QA_STATUSES           (Ready for QA,QA,In QA)  statuses for bucket #5
#   BLOCKED_STATUSES      (Blocked,On Hold,Waiting)  statuses for bucket #6
#   ITERATION_FILTER      (off)       `current` restricts #3 to the active sprint
#   ITERATION_FIELD       (Iteration) board's iteration field name
#   STALE_DAYS            (2)         threshold for bucket #7. --init prompts for
#                                     it; --serve has a live "Stale after Nd"
#                                     field (?stale=N override, no persist)
#   SMTP_HOST/PORT/USER/PASS (—/587)  --email daily summary: SMTP submission.
#   SMTP_TLS              (true)       STARTTLS on the submission connection
#   MAIL_FROM / MAIL_TO   (=SMTP_USER) sender + recipient of the digest email
#   IGNORE_OLDER_THAN     (0=off)     hide any issue/PR untouched for more than
#     / --ignore-older-than N         N calendar days (declutter cold work; all
#                                     buckets, every surface). 0/unset = show all
#   DAY_MODE              (business)  business (skip Sat/Sun) | calendar
#   THEME / --theme       (—)         `matrix` = green boxed TUI (terminal/TTY
#                                     only; pipes stay plain)
#
# -----------------------------------------------------------------------------
# PUSH LAYER — built-in daily email, or bring-your-own cron.
# -----------------------------------------------------------------------------
# `--email` fetches the queue, builds a plain-text digest (MailSurface), and
# sends it over SMTP (Mailer) — set SMTP_HOST/USER/PASS + MAIL_TO first (--init
# prompts for them). `service/install-digest.sh [HH:MM]` schedules it via a
# launchd agent (default 22:00). Or wire the terminal output into your own
# cron, piping to a notifier. Examples (crontab, 8:30am Mon-Fri):
#
#   30 8 * * 1-5  GITHUB_TOKEN=... GH_LOGIN=you PROJECT_URL=... \
#                 ruby /path/lib/kamandar.rb | mail -s "Kamandar" you@example.com
#
#   # or, on a Linux desktop:
#   30 8 * * 1-5  ... ruby /path/lib/kamandar.rb | head -c 4000 | \
#                 xargs -0 notify-send "Kamandar"
#
#   # or, on macOS:
#   30 8 * * 1-5  ... ruby /path/lib/kamandar.rb | \
#                 terminal-notifier -title "Kamandar"
#
# Terminal output is plain text (no ANSI), safe to pipe to `mail`. Browser mode
# is for interactive/ambient use (optionally with --watch), not cron.
#
# -----------------------------------------------------------------------------
# NON-GOALS / KNOWN LIMITATIONS
# -----------------------------------------------------------------------------
#   * The saved *view* filter DSL is NOT replicated; #3 is approximated by
#     Status (+ optional iteration). Only org + project number are read from
#     PROJECT_URL; the view number is ignored.
#   * "Commented" reviews are intentionally ignored — a comment doesn't flip
#     the ball back to the reviewer.
#   * Any push (incl. a typo fix or rebase/force-push) resets the #4 clock by
#     design ("you resubmitted"). To instead reset only on an explicit
#     re-request, drop `last_push` from `handoff_at` (see Engine.handoff_at).
#   * Browser mode is a STATIC snapshot rendered in-process: no client-side
#     GitHub calls, no live data except via --watch re-runs. The token never
#     reaches the page.
#   * Single user, single token, no multi-tenant concerns.
#
# Browser/watch note: meta-refresh over file:// is supported in current Chrome,
# Firefox, and Safari, so the open tab reloads itself from the same file://
# path in watch mode.
# =============================================================================

require "net/http"
require "openssl"
require "json"
require "date"
require "time"
require "tmpdir"
require "rbconfig"
require "io/console" # default gem (ships with Ruby): winsize + getch for the TUI
require "socket" # stdlib: TCPServer for the local web UI (--serve)
require "cgi"    # stdlib: query-string parsing + HTML escaping for the server
require "net/smtp" # stdlib: SMTP delivery for the --email daily summary

module Kamandar
  VERSION = "1.0.0"
  GRAPHQL_ENDPOINT = "https://api.github.com/graphql"
  HTML_PATH = File.join(Dir.tmpdir, "kamandar.html")

  # ---------------------------------------------------------------------------
  # Engine — pure, side-effect-free. No network, no ENV, no I/O.
  # ---------------------------------------------------------------------------
  module Engine
    module_function

    # -- time helpers ---------------------------------------------------------

    # Parse an ISO8601 timestamp string into a Time (UTC). Passes Time/nil
    # through unchanged.
    def parse_time(value)
      return nil if value.nil?
      return value if value.is_a?(Time)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      Time.parse(value.to_s)
    end

    # Coerce a Time/Date/String into a Date (UTC for Times) for day counting.
    def to_date(value)
      case value
      when Date then value
      when Time then value.utc.to_date
      else Date.parse(value.to_s)
      end
    end

    # Whole days between `time` and `today`, floored at 0.
    #   calendar : every calendar day, weekends included.
    #   business : count of Mon-Fri dates in [from_date, today). A Friday
    #              handoff is "1 business day" the following Monday.
    def days_since(time, mode:, today:)
      from = to_date(time)
      now  = to_date(today)
      case mode.to_s
      when "calendar"
        [(now - from).to_i, 0].max
      else # "business"
        return 0 if now <= from
        count = 0
        d = from
        while d < now
          count += 1 if (1..5).cover?(d.wday) # Mon=1 .. Fri=5
          d += 1
        end
        count
      end
    end

    # -- bucket #7: the handoff-vs-reviewer race ------------------------------
    # Operates on raw GraphQL PR node hashes (string keys) so the same code
    # classifies fixtures and live data.

    # Latest REVIEW_REQUESTED_EVENT time, or nil.
    def last_review_requested_at(pr)
      nodes = pr.dig("timelineItems", "nodes") || []
      times = nodes.map { |n| parse_time(n["createdAt"]) }.compact
      times.max
    end

    # Time of the last commit on the PR, or nil.
    def last_push_at(pr)
      nodes = pr.dig("commits", "nodes") || []
      times = nodes.map { |n| parse_time(n.dig("commit", "committedDate")) }.compact
      times.max
    end

    # The last moment YOU put the ball in the reviewer's court.
    # To reset only on explicit re-request, drop last_push_at below.
    def handoff_at(pr)
      candidates = [
        last_review_requested_at(pr),
        last_push_at(pr),
        parse_time(pr["createdAt"])
      ].compact
      candidates.max
    end

    # The reviewer's last *decisive* action. Plain COMMENTED reviews do not
    # count (latestOpinionatedReviews already excludes them; we filter again
    # defensively).
    def reviewer_last_action_at(pr)
      nodes = pr.dig("latestOpinionatedReviews", "nodes") || []
      times = nodes
              .reject { |n| n["state"].to_s.upcase == "COMMENTED" }
              .map { |n| parse_time(n["submittedAt"]) }
              .compact
      times.max
    end

    def has_reviewer?(pr)
      (pr.dig("reviewRequests", "totalCount").to_i > 0) ||
        !last_review_requested_at(pr).nil? ||
        !reviewer_last_action_at(pr).nil?
    end

    # Ball is on the reviewer when your handoff is newer than their last
    # decisive action, or they never acted.
    def ball_on_reviewer?(pr)
      return false unless has_reviewer?(pr)
      action = reviewer_last_action_at(pr)
      action.nil? || handoff_at(pr) > action
    end

    def stale?(pr, stale_days:, mode:, today:)
      return false if pr["isDraft"]
      return false unless ball_on_reviewer?(pr)
      days_since(handoff_at(pr), mode: mode, today: today) >= stale_days
    end

    def forgot_reviewer?(pr)
      !pr["isDraft"] && !has_reviewer?(pr)
    end

    # -- bucket #3: Projects V2 Status ----------------------------------------

    # Flatten an item's single-select field values into {field_name => value}.
    def single_select_fields(item)
      nodes = item.dig("fieldValues", "nodes") || []
      out = {}
      nodes.each do |n|
        next unless n["__typename"] == "ProjectV2ItemFieldSingleSelectValue"
        fname = n.dig("field", "name")
        out[fname] = n["name"] if fname
      end
      out
    end

    # The item's iteration value node for the named field, or nil.
    def iteration_value(item, iteration_field)
      nodes = item.dig("fieldValues", "nodes") || []
      nodes.find do |n|
        n["__typename"] == "ProjectV2ItemFieldIterationValue" &&
          n.dig("field", "name") == iteration_field
      end
    end

    # Keep items that are Issues assigned to `login` whose Status is in `statuses`
    # (case-insensitive, trimmed). When iteration filtering is on and an
    # iteration field exists, also require the active iteration.
    def assigned_with_status(items, login:, statuses:,
                             iteration_filter: "off",
                             iteration_field: "Iteration",
                             iterations: nil, today: nil)
      wanted = statuses.map { |s| s.to_s.strip.downcase }
      active = nil
      filtering = iteration_filter.to_s == "current" && iterations && !iterations.empty?
      active = active_iteration(iterations, today: today) if filtering

      items.select do |item|
        content = item["content"]
        next false unless content && content["__typename"] == "Issue"

        assignees = (content.dig("assignees", "nodes") || []).map { |a| a["login"] }
        next false unless assignees.include?(login)

        status = single_select_fields(item)["Status"]
        next false unless status && wanted.include?(status.strip.downcase)

        if filtering
          # No iteration field on the board -> active is nil -> no-op (keep).
          next true if active.nil?
          iv = iteration_value(item, iteration_field)
          next false unless iv
          next false unless iv["startDate"].to_s == active["startDate"].to_s
        end

        true
      end
    end

    # Issues assigned to you whose Status is in the "not started" set.
    def assigned_not_started(items, login:, not_started:, **opts)
      assigned_with_status(items, login: login, statuses: not_started, **opts)
    end

    # Issues assigned to you whose Status is in the "in review" set — issues you
    # submitted for review on the board.
    def assigned_in_review(items, login:, review_statuses:, **opts)
      assigned_with_status(items, login: login, statuses: review_statuses, **opts)
    end

    # Issues assigned to you whose Status is in the "in QA" set.
    def assigned_in_qa(items, login:, qa_statuses:, **opts)
      assigned_with_status(items, login: login, statuses: qa_statuses, **opts)
    end

    # Issues assigned to you whose Status is in the "blocked" set — waiting on a
    # requirement confirmation or an answer from someone else.
    def assigned_blocked(items, login:, blocked_statuses:, **opts)
      assigned_with_status(items, login: login, statuses: blocked_statuses, **opts)
    end

    # Diagnostic: every board issue assigned to `login`, with its raw Status.
    # Used by `--statuses` to reveal the exact labels a board uses so the
    # NOT_STARTED_STATUSES / REVIEW_STATUSES sets can be configured to match.
    def assigned_status_breakdown(items, login:)
      items.filter_map do |item|
        content = item["content"]
        next unless content && content["__typename"] == "Issue"

        assignees = (content.dig("assignees", "nodes") || []).map { |a| a["login"] }
        next unless assignees.include?(login)

        { number: content["number"], title: content["title"],
          status: single_select_fields(item)["Status"] }
      end
    end

    # -- current-sprint filter (§6) -------------------------------------------

    # The iteration whose [startDate, startDate + duration) range contains
    # today, or nil.
    def active_iteration(iterations, today:)
      return nil if iterations.nil? || iterations.empty?
      td = to_date(today)
      iterations.find do |it|
        sd = to_date(it["startDate"])
        ed = sd + it["duration"].to_i # exclusive end
        td >= sd && td < ed
      end
    end

    # -- URL parsing ----------------------------------------------------------

    # Parse org + project number from a board/view URL. Returns
    # {org:, num:} or nil. The view number is ignored by design.
    def parse_project_url(url)
      return nil if url.nil? || url.to_s.empty?
      m = url.to_s.match(%r{/orgs/([^/]+)/projects/(\d+)})
      return nil unless m
      { org: m[1], num: m[2].to_i }
    end

    # -- scope ----------------------------------------------------------------

    # Resolve a raw SCOPE value into {mode:, org:/repo:}. Forms:
    #   "" / "global"      -> account-wide (default)
    #   "org" / "org:NAME" -> single org; bare "org" reuses project_org
    #   "repo:owner/name"  -> single repo
    #   "project"          -> repos present on the PROJECT_URL board
    # Anything unrecognized, or org/repo without a usable value, falls back to
    # global so the tool always runs.
    # True when `s` looks like "owner/name" (no spaces, exactly one slash with
    # non-empty sides).
    def valid_repo?(s)
      !!(s.to_s.strip =~ %r{\A[^/[:space:]]+/[^/[:space:]]+\z})
    end

    def parse_scope(raw, project_org: nil)
      key, _, val = raw.to_s.strip.partition(":")
      val = val.strip
      case key.downcase
      when "", "global"
        { mode: "global" }
      when "org"
        org = val.empty? ? project_org.to_s : val
        org.empty? ? { mode: "global" } : { mode: "org", org: org }
      when "repo"
        val.empty? ? { mode: "global" } : { mode: "repo", repo: val }
      when "project"
        { mode: "project" }
      else
        { mode: "global" }
      end
    end

    # The GitHub search fragment for a scope. org/repo filter at query time;
    # global and project add nothing (project is filtered after the board is
    # fetched, since its repos aren't known up front).
    def search_qualifier(scope)
      case scope[:mode]
      when "org"  then "org:#{scope[:org]}"
      when "repo" then "repo:#{scope[:repo]}"
      else ""
      end
    end

    # Short human label for surface headers.
    def scope_label(scope)
      case scope[:mode]
      when "org"     then "org:#{scope[:org]}"
      when "repo"    then "repo:#{scope[:repo]}"
      when "project" then "project"
      else "global"
      end
    end

    # URLs of the PRs that are themselves items on the board.
    def project_pr_urls(items)
      board_urls(items, "PullRequest")
    end

    # URLs of the Issues that are items on the board.
    def project_issue_urls(items)
      board_urls(items, "Issue")
    end

    def board_urls(items, typename)
      items.filter_map do |it|
        content = it["content"]
        content && content["__typename"] == typename ? content["url"] : nil
      end.uniq
    end

    # A PR belongs to a project if it is itself a board item OR it closes an
    # issue that is on the board ("Closes #N"). Boards usually track issues and
    # the PR is linked rather than carded, so the closing-issue link is what
    # keeps reviews-owed/gone-quiet from coming up empty under project scope.
    def pr_on_project?(pr, pr_urls:, issue_urls:)
      return true if pr_urls.include?(pr["url"])
      closing = (pr.dig("closingIssuesReferences", "nodes") || []).map { |n| n["url"] }
      closing.any? { |u| issue_urls.include?(u) }
    end

    # Keep only PR nodes that belong to the project (board item or linked issue).
    def filter_prs_on_project(prs, pr_urls:, issue_urls:)
      prs.select { |pr| pr_on_project?(pr, pr_urls: pr_urls, issue_urls: issue_urls) }
    end

    # -- search strings -------------------------------------------------------

    # `qualifier` is a GitHub search fragment ("org:Foo", "repo:owner/name", or
    # "" for none) appended so PR buckets match the chosen scope rather than the
    # whole account.
    def reviews_owed_query(login, qualifier: "")
      scoped("is:open is:pr review-requested:#{login}", qualifier)
    end

    def my_prs_query(login, qualifier: "")
      scoped("is:open is:pr author:#{login}", qualifier)
    end

    # Open issues assigned to you (non-project scopes classify these by the
    # state of their linked PR).
    def assigned_issues_query(login, qualifier: "")
      scoped("is:open is:issue assignee:#{login}", qualifier)
    end

    def scoped(base, qualifier)
      base = "#{base} #{qualifier}".strip if qualifier && !qualifier.to_s.empty?
      "#{base} archived:false"
    end

    # -- GraphQL builders -----------------------------------------------------

    # The shared PR field selection used by both aliased searches.
    PR_FIELDS = <<~GQL
      number
      title
      url
      isDraft
      reviewDecision
      createdAt
      updatedAt
      repository { nameWithOwner }
      reviewRequests(first: 1) { totalCount }
      commits(last: 1) { nodes { commit { committedDate } } }
      timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 1) {
        nodes { ... on ReviewRequestedEvent { createdAt } }
      }
      latestOpinionatedReviews(first: 10) { nodes { state submittedAt } }
      closingIssuesReferences(first: 5) { nodes { url } }
    GQL

    # One GraphQL document running BOTH PR searches via aliases.
    # Tiny identity query — used by `--init` to verify a token works and learn
    # which account it authenticates as.
    def build_viewer_query
      "query { viewer { login } }"
    end

    def build_pr_query
      <<~GQL
        query($owed: String!, $mine: String!) {
          owed: search(query: $owed, type: ISSUE, first: 50) {
            nodes { ... on PullRequest { #{PR_FIELDS} } }
          }
          mine: search(query: $mine, type: ISSUE, first: 50) {
            nodes { ... on PullRequest { #{PR_FIELDS} } }
          }
        }
      GQL
    end

    # Fields for the PR(s) linked to an assigned issue via "Closes #N" — enough
    # to reuse has_reviewer? for the in-review vs no-reviewer split.
    LINKED_PR_FIELDS = <<~GQL
      isDraft
      reviewRequests(first: 1) { totalCount }
      timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 1) {
        nodes { ... on ReviewRequestedEvent { createdAt } }
      }
      latestOpinionatedReviews(first: 10) { nodes { state submittedAt } }
    GQL

    # Open issues assigned to you, each with the open PRs that would close it.
    def build_assigned_issues_query
      <<~GQL
        query($q: String!) {
          assigned: search(query: $q, type: ISSUE, first: 50) {
            nodes {
              ... on Issue {
                number
                title
                url
                updatedAt
                repository { nameWithOwner }
                closedByPullRequestsReferences(first: 5, includeClosedPrs: false) {
                  nodes { #{LINKED_PR_FIELDS} }
                }
              }
            }
          }
        }
      GQL
    end

    # Paginated board query (100 items/page). Also pulls the iteration field
    # configuration for §6.
    def build_board_query
      <<~GQL
        query($org: String!, $num: Int!, $cursor: String) {
          organization(login: $org) {
            projectV2(number: $num) {
              fields(first: 50) {
                nodes {
                  ... on ProjectV2IterationField {
                    name
                    configuration {
                      iterations { title startDate duration }
                      completedIterations { title startDate duration }
                    }
                  }
                }
              }
              items(first: 100, after: $cursor) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  fieldValues(first: 20) {
                    nodes {
                      __typename
                      ... on ProjectV2ItemFieldSingleSelectValue {
                        name
                        field { ... on ProjectV2SingleSelectField { name } }
                      }
                      ... on ProjectV2ItemFieldIterationValue {
                        title
                        startDate
                        duration
                        field { ... on ProjectV2IterationField { name } }
                      }
                    }
                  }
                  content {
                    __typename
                    ... on Issue {
                      number
                      title
                      url
                      state
                      updatedAt
                      assignees(first: 10) { nodes { login } }
                      repository { nameWithOwner }
                    }
                    ... on PullRequest {
                      number
                      url
                      updatedAt
                      repository { nameWithOwner }
                    }
                  }
                }
              }
            }
          }
        }
      GQL
    end

    # -- normalization & classification --------------------------------------

    def normalize_pr(pr, extra = {})
      {
        number: pr["number"],
        title: pr["title"],
        url: pr["url"],
        repo: pr.dig("repository", "nameWithOwner"),
        updated_at: pr["updatedAt"]
      }.merge(extra)
    end

    def normalize_item(item)
      content = item["content"]
      {
        number: content["number"],
        title: content["title"],
        url: content["url"],
        repo: content.dig("repository", "nameWithOwner"),
        updated_at: content["updatedAt"]
      }
    end

    def normalize_issue(issue)
      {
        number: issue["number"],
        title: issue["title"],
        url: issue["url"],
        repo: issue.dig("repository", "nameWithOwner"),
        updated_at: issue["updatedAt"]
      }
    end

    # The open PRs that would close this issue ("Closes #N" references).
    def linked_prs(issue)
      issue.dig("closedByPullRequestsReferences", "nodes") || []
    end

    # Map of board issue url => normalized issue row, for resolving a PR back to
    # the issue card it tracks.
    def board_issue_index(items)
      index = {}
      items.each do |it|
        content = it["content"]
        next unless content && content["__typename"] == "Issue" && content["url"]
        index[content["url"]] = normalize_item(it)
      end
      index
    end

    # The board issue a PR closes (first match in `issue_index`), or nil.
    def linked_board_issue(pr, issue_index)
      closing = (pr.dig("closingIssuesReferences", "nodes") || []).map { |n| n["url"] }
      url = closing.find { |u| issue_index.key?(u) }
      url && issue_index[url]
    end

    # Classify an assigned issue by the state of its linked PR(s):
    #   :not_started — no open linked PR
    #   :draft       — every linked PR is a draft (work in progress)
    #   :in_review   — a ready (non-draft) linked PR has a reviewer
    #   :no_reviewer — a ready linked PR exists but nobody is asked to review
    def issue_pr_state(issue)
      prs = linked_prs(issue)
      return :not_started if prs.empty?
      ready = prs.reject { |pr| pr["isDraft"] }
      return :draft if ready.empty?
      ready.any? { |pr| has_reviewer?(pr) } ? :in_review : :no_reviewer
    end

    # Turn raw fetched data into the buckets hash. Pure: takes already-fetched
    # node arrays plus config, returns the classified hash that both surfaces
    # consume. The bucket set depends on scope: project scope is board-driven,
    # every other scope is issue+PR driven. Surfaces never re-query or re-classify.
    #
    # config keys: :scope, :login, :not_started, :review_statuses, :qa_statuses,
    #              :blocked_statuses, :stale_days, :ignore_older_than, :day_mode,
    #              :iteration_filter, :iteration_field
    def classify(owed_prs:, my_prs:, project_items: [], assigned_issues: [],
                 iterations: nil, config:, today:)
      buckets =
        if scope_mode(config) == "project"
          classify_project(owed_prs: owed_prs, my_prs: my_prs,
                           project_items: project_items, iterations: iterations,
                           config: config, today: today)
        else
          classify_issue(owed_prs: owed_prs, my_prs: my_prs,
                         assigned_issues: assigned_issues, config: config, today: today)
        end
      apply_recency_filter(buckets, config: config, today: today)
    end

    # Drop rows whose last activity (updatedAt) is older than
    # config[:ignore_older_than] calendar days — a queue declutter for work
    # that's gone cold. Unset / 0 disables it, so the default is show-everything.
    # Calendar days (not DAY_MODE) — "older than 90 days" reads literally.
    # Rows without an updated_at (e.g. --demo fabricated data) are always kept.
    def apply_recency_filter(buckets, config:, today:)
      days = config[:ignore_older_than].to_i
      return buckets unless days.positive?

      buckets.transform_values do |rows|
        rows.reject do |row|
          t = parse_time(row[:updated_at])
          t && days_since(t, mode: "calendar", today: today) > days
        end
      end
    end

    def scope_mode(config)
      (config[:scope] && config[:scope][:mode]) || "global"
    end

    # Board-driven buckets (project scope).
    def classify_project(owed_prs:, my_prs:, project_items:, iterations:, config:, today:)
      # The board tracks issues, so a review you owe is shown as the board issue
      # the PR closes; if a PR closes no board issue, the PR itself is shown.
      issue_index = board_issue_index(project_items)
      reviews_owed = owed_prs
                     .map { |pr| linked_board_issue(pr, issue_index) || normalize_pr(pr) }
                     .uniq { |row| row[:url] }

      wip = my_prs.select { |pr| pr["isDraft"] }.map { |pr| normalize_pr(pr) }
      stale = stale_rows(my_prs, config: config, today: today)
      forgot = my_prs.select { |pr| forgot_reviewer?(pr) }.map { |pr| normalize_pr(pr) }

      board_opts = {
        login: config[:login],
        iteration_filter: config[:iteration_filter],
        iteration_field: config[:iteration_field],
        iterations: iterations,
        today: today
      }
      board = lambda do |statuses|
        assigned_with_status(project_items, statuses: statuses, **board_opts)
          .map { |item| normalize_item(item) }
      end

      {
        reviews_owed: reviews_owed,
        wip: wip,
        assigned_not_started: board.call(config[:not_started] || []),
        in_review: board.call(config[:review_statuses] || []),
        in_qa: board.call(config[:qa_statuses] || []),
        blocked: board.call(config[:blocked_statuses] || []),
        stale: stale,
        forgot_reviewer: forgot
      }
    end

    # Issue+PR-driven buckets (global/org/repo scope).
    def classify_issue(owed_prs:, my_prs:, assigned_issues:, config:, today:)
      reviews_owed = owed_prs.map { |pr| normalize_pr(pr) }
      stale = stale_rows(my_prs, config: config, today: today)

      grouped = Hash.new { |h, k| h[k] = [] }
      assigned_issues.each { |iss| grouped[issue_pr_state(iss)] << normalize_issue(iss) }

      {
        reviews_owed: reviews_owed,
        assigned_todo: grouped[:not_started],
        assigned_wip: grouped[:draft],
        assigned_review: grouped[:in_review],
        assigned_no_reviewer: grouped[:no_reviewer],
        stale: stale
      }
    end

    # Shared "PRs gone quiet" rows (used by both modes).
    def stale_rows(my_prs, config:, today:)
      mode = config[:day_mode]
      stale_days = config[:stale_days]
      my_prs.select { |pr| stale?(pr, stale_days: stale_days, mode: mode, today: today) }
            .map do |pr|
        normalize_pr(pr,
                     days: days_since(handoff_at(pr), mode: mode, today: today),
                     mode: mode)
      end
    end

    # Ordered bucket metadata per scope mode. Surfaces iterate whichever set the
    # active scope selects (key, title, empty-message).
    BUCKETS_PROJECT = [
      [:reviews_owed,         "Reviews you owe",            "Nothing waiting on your review. \u{1F389}"],
      [:wip,                  "Currently building (WIP)",   "No drafts in flight."],
      [:assigned_not_started, "Assigned, not started",      "Nothing assigned and waiting to start."],
      [:in_review,            "Submitted for review",       "No issues waiting on review."],
      [:in_qa,                "In QA",                      "Nothing in QA."],
      [:blocked,              "Blocked",                    "Nothing blocked. \u{1F44D}"],
      [:stale,                "Your PRs gone quiet",        "No PRs have gone quiet."],
      [:forgot_reviewer,      "Ready, no reviewer requested", "Every ready PR has a reviewer."]
    ].freeze

    BUCKETS_ISSUE = [
      [:reviews_owed,         "Reviews you owe",                  "Nothing waiting on your review. \u{1F389}"],
      [:assigned_todo,        "Assigned, not started",            "Nothing assigned and waiting to start."],
      [:assigned_wip,         "Assigned, PR in draft",            "No assigned work in progress."],
      [:assigned_review,      "Assigned, PR in review",           "No assigned PRs in review."],
      [:assigned_no_reviewer, "Assigned, PR ready (no reviewer)", "Every ready PR has a reviewer."],
      [:stale,                "Your PRs gone quiet",              "No PRs have gone quiet."]
    ].freeze

    # Default kept as the project set for any back-compat reference.
    BUCKETS = BUCKETS_PROJECT

    def bucket_meta(mode)
      mode.to_s == "project" ? BUCKETS_PROJECT : BUCKETS_ISSUE
    end
  end

  # ---------------------------------------------------------------------------
  # Demo — fabricated buckets for screenshots and offline trials (`--demo`).
  # Pure and deterministic: no network, no ENV, no randomness — so a `--demo`
  # render is byte-stable and needs no token. Produces 15–20 plausible rows per
  # bucket, shaped exactly like `Engine.classify` output so every surface and
  # the pagination logic exercise the same code paths as live data.
  # ---------------------------------------------------------------------------
  module Demo
    module_function

    REPOS = %w[
      acme/api acme/web acme/mobile acme/billing acme/search
      acme/infra acme/auth acme/docs core/platform core/design
    ].freeze

    TITLES = [
      "Fix flaky checkout spec", "Add rate limiting to the public API",
      "Refactor the session store", "Bump Rails to 8.1",
      "Cache the dashboard query", "Handle webhook retries idempotently",
      "Migrate uploads to S3", "Tidy up the onboarding flow",
      "Add dark mode to settings", "Backfill missing slugs",
      "Guard against nil reviewer", "Paginate the activity feed",
      "Speed up the search index", "Drop the legacy columns",
      "Wire up feature flags", "Improve the empty states",
      "Extract the billing service", "Add OpenTelemetry traces",
      "Fix N+1 on the project board", "Harden the CSV importer"
    ].freeze

    # Buckets keyed off bucket_meta for the given scope mode. Counts land in
    # 15..20 and vary per bucket, but deterministically (index-derived).
    def buckets(mode)
      Engine.bucket_meta(mode).each_with_index.to_h do |(key, _t, _e), ki|
        count = 15 + (ki * 2) % 6 # 15..19, stable per position
        [key, (1..count).map { |j| row(key, ki, j) }]
      end
    end

    # Buckets where the linked work is an issue rather than a PR (for URLs).
    ISSUE_KEYS = %i[assigned_not_started assigned_todo in_qa blocked].freeze

    def row(key, ki, j)
      number = (ki + 1) * 100 + j
      repo   = REPOS[(ki + j) % REPOS.size]
      title  = TITLES[(ki * 7 + j) % TITLES.size]
      kind   = ISSUE_KEYS.include?(key) ? "issues" : "pull"
      base   = { number: number.to_s, title: title, repo: repo,
                 url: "https://github.com/#{repo}/#{kind}/#{number}" }
      key == :stale ? base.merge(days: 3 + (j % 12), mode: "calendar") : base
    end
  end

  # ---------------------------------------------------------------------------
  # Surface — dispatch + shared helpers
  # ---------------------------------------------------------------------------
  module Surface
    module_function

    # Resolve the surface preference. --browser/-b (browser_flag:true) wins;
    # otherwise OUTPUT env decides; default terminal.
    def resolve_surface(output_env:, browser_flag:, menubar_flag: false)
      return :menubar if menubar_flag
      return :browser if browser_flag

      case output_env.to_s.strip.downcase
      when "browser" then :browser
      when "menubar" then :menubar
      else :terminal
      end
    end

    # Pure builder for the OS "open this file" command. Not executed here so it
    # can be unit-tested. For Windows pass the plain path; otherwise a file://
    # URL.
    def browser_open_command(host_os, file_url)
      case host_os
      when /mswin|mingw|cygwin|windows/i
        ["cmd", "/c", "start", "", file_url]
      when /darwin|mac/i
        ["open", file_url]
      else
        ["xdg-open", file_url]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Terminal surface — plain text, pipe-friendly (no ANSI).
  # ---------------------------------------------------------------------------
  module TerminalSurface
    module_function

    # Per-bucket emoji + ANSI foreground color (used only in color mode).
    ICON = {
      reviews_owed: "\u{1F4E5}", wip: "\u{1F528}", assigned_not_started: "\u{1F4CB}",
      in_review: "\u{1F440}", in_qa: "\u{1F9EA}", blocked: "\u{1F6A7}",
      stale: "\u{23F3}", forgot_reviewer: "\u{1F648}",
      assigned_todo: "\u{1F4CB}", assigned_wip: "\u{1F528}",
      assigned_review: "\u{1F440}", assigned_no_reviewer: "\u{1F648}"
    }.freeze
    # 256-color, mid-tone palette. Chosen for legibility on BOTH light and dark
    # terminals: the old 16-color bright codes (esp. 33 yellow / 36 cyan) and
    # bold's bright variant washed out on light backgrounds. Bold (1;) here only
    # sets weight — with 38;5;N the color stays put, so titles stay readable.
    AMBER = "38;5;172" # warm orange that survives a white background (was 33)
    COLOR = {
      reviews_owed: "38;5;33",  wip: "38;5;99", assigned_not_started: "38;5;34",
      in_review: "38;5;37",     in_qa: "38;5;31", blocked: "38;5;160",
      stale: AMBER,             forgot_reviewer: AMBER,
      assigned_todo: "38;5;34", assigned_wip: "38;5;99",
      assigned_review: "38;5;37", assigned_no_reviewer: AMBER
    }.freeze

    # Render the report. `color: true` adds ANSI escapes + emoji; `false`
    # produces the exact plain text (pipe/cron/mail safe). `theme: :matrix`
    # draws green-on-black boxed panels (TTY only). Plain output is the spec the
    # tests assert, so keep the no-color branch byte-for-byte stable.
    def render(buckets, config:, generated_at:, color: false, theme: :default)
      return matrix_render(buckets, config: config, generated_at: generated_at) if theme == :matrix

      paint = lambda do |codes, str|
        color && codes ? "\e[#{codes}m#{str}\e[0m" : str
      end

      lines = []
      meta = "@#{config[:login]}  —  #{generated_at.strftime('%Y-%m-%d %H:%M')}  (#{config[:day_mode]} days)"
      meta += "  [#{Engine.scope_label(config[:scope])}]" if config[:scope]
      if color
        lines << "#{paint.call('1', "\u{1F3F9} Kamandar")}  #{paint.call('2', meta)}"
        lines << paint.call("2", "═" * 72)
      else
        lines << "Kamandar for #{meta}"
        lines << ("=" * 72)
      end

      Engine.bucket_meta(Engine.scope_mode(config)).each do |key, title, empty|
        rows = buckets[key] || []
        lines << ""
        if color
          col = COLOR[key] || "37"
          lines << "#{ICON[key] || '•'}  #{paint.call("1;#{col}", title)}  #{paint.call(col, "(#{rows.size})")}"
          lines << paint.call("2", "─" * (title.length + 4))
        else
          lines << "#{title} (#{rows.size})"
          lines << ("-" * title.length)
        end

        if rows.empty?
          lines << "  #{paint.call('2;3', empty)}"
          next
        end

        # Left-pad the #number token to the widest in this bucket so every title
        # starts at the same column (#8 lines up under #10488).
        numw = rows.map { |r| "##{r[:number]}".length }.max
        rows.each_with_index do |row, idx|
          suffix =
            if key == :stale && row[:days]
              "  — #{row[:days]} #{row[:mode]} days since you handed off"
            else
              ""
            end
          num = paint.call("2", "##{row[:number]}".ljust(numw))
          repo = paint.call("2", "(#{row[:repo]})")
          suf = suffix.empty? ? "" : paint.call(AMBER, suffix)
          lines << "  #{num} #{row[:title]}  #{repo}#{suf}"
          lines << "    #{paint.call('2;4', row[:url])}"
          lines << "" unless idx == rows.size - 1 # breathing room between entries
        end
      end
      lines << ""
      lines.join("\n")
    end

    # The terminal surface's emit contract: print to stdout.
    def emit(output)
      $stdout.puts(output)
    end

    # -- Matrix theme ---------------------------------------------------------

    MATRIX_W = 72 # inner content width of every panel

    # Truncate (char-count) to width, adding an ellipsis when clipped.
    def mtrunc(str, width)
      s = str.to_s
      s.length <= width ? s : "#{s[0, width - 1]}…"
    end

    # Truncate then right-pad with spaces to exactly `width` chars.
    def mpad(str, width)
      t = mtrunc(str, width)
      t + (" " * (width - t.length))
    end

    # Green-on-black boxed dashboard. All ANSI + box-drawing, no gems. Three
    # green shades: bright (borders/labels), green (content), dim (urls/empty).
    def matrix_render(buckets, config:, generated_at:)
      w  = MATRIX_W
      br = ->(s) { "\e[1;92m#{s}\e[0m" } # bright green
      gr = ->(s) { "\e[32m#{s}\e[0m" }   # green
      dm = ->(s) { "\e[2;32m#{s}\e[0m" } # dim green
      framed = ->(body, fn) { br.call("║ ") + fn.call(mpad(body, w)) + br.call(" ║") }

      meta = "@#{config[:login]}  #{generated_at.strftime('%Y-%m-%d %H:%M')}  (#{config[:day_mode]} days)"
      meta += "  [#{Engine.scope_label(config[:scope])}]" if config[:scope]

      lines = []
      lines << br.call("╔" + ("═" * (w + 2)) + "╗")
      lines << framed.call("KAMANDAR  //  #{meta}", gr)
      lines << br.call("╚" + ("═" * (w + 2)) + "╝")

      Engine.bucket_meta(Engine.scope_mode(config)).each do |key, title, empty|
        rows = buckets[key] || []
        left  = "╔═ #{title.upcase} "
        right = " #{rows.size} ═╗"
        fill  = [(w + 4) - left.length - right.length, 0].max

        lines << ""
        lines << br.call(left + ("═" * fill) + right)
        if rows.empty?
          lines << framed.call(empty, dm)
        else
          rows.each do |row|
            tag = (key == :stale && row[:days]) ? "  · #{row[:days]}#{row[:mode] == 'business' ? 'bd' : 'd'}" : ""
            lines << framed.call("##{row[:number]} #{row[:title]}  (#{row[:repo]})#{tag}", gr)
            lines << framed.call("  #{row[:url]}", dm)
          end
        end
        lines << br.call("╚" + ("═" * (w + 2)) + "╝")
      end
      lines << ""
      lines.join("\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Dashboard surface — full-screen Matrix TUI (alt-screen) + digital rain.
  # Pure ANSI, stdlib only. The pure frame builders are unit-tested; the screen
  # takeover + key loop live in CLI.run_dashboard.
  # ---------------------------------------------------------------------------
  module DashboardSurface
    module_function

    ENTER_ALT = "\e[?1049h\e[?25l" # alt buffer + hide cursor
    LEAVE_ALT = "\e[?25h\e[?1049l" # show cursor + leave alt buffer
    CLEAR_HOME = "\e[2J\e[H"

    # Falling-rain glyphs: digits + halfwidth katakana (the iconic look).
    GLYPHS = ((0x30..0x39).to_a + (0xFF66..0xFF9D).to_a).map { |cp| [cp].pack("U") }.freeze

    # One digital-rain frame for a cols×rows grid given per-column head rows.
    # Head is near-white, the next cell bright green, the trail fades to dim.
    def rain_frame(cols:, rows:, heads:)
      grid = Array.new(rows) { Array.new(cols, " ") }
      heads.each_with_index do |head, col|
        (0..7).each do |t|
          r = head - t
          next if r.negative? || r >= rows
          style = if t.zero? then "1;97"
                  elsif t <= 1 then "1;92"
                  elsif t <= 3 then "32"
                  else "2;32"
                  end
          grid[r][col] = "\e[#{style}m#{GLYPHS.sample}\e[0m"
        end
      end
      CLEAR_HOME + grid.map(&:join).join("\r\n")
    end

    # Advance the rain one step; columns that fall off the bottom respawn above.
    def step_heads(heads, rows)
      heads.map { |h| h > rows + 8 ? -rand(0..rows) : h + 1 }
    end

    # Seed one rain head per column at a random row above the top, so the
    # streams start staggered rather than all falling from row 0 together.
    def init_heads(cols, rows)
      Array.new(cols) { -rand(0...[rows, 1].max) }
    end

    # The static dashboard frame: green panels windowed to fit, header + footer.
    def render(buckets, config:, generated_at:, rows:, cols:)
      w  = [cols - 4, 8].max
      br = ->(s) { "\e[1;92m#{s}\e[0m" }
      gr = ->(s) { "\e[32m#{s}\e[0m" }
      dm = ->(s) { "\e[2;32m#{s}\e[0m" }
      fr = ->(body, fn) { br.call("║ ") + fn.call(TerminalSurface.mpad(body, w)) + br.call(" ║") }

      body = []
      Engine.bucket_meta(Engine.scope_mode(config)).each do |key, title, empty|
        data  = buckets[key] || []
        left  = "╔═ #{title.upcase} "
        right = " #{data.size} ═╗"
        fill  = [(w + 4) - left.length - right.length, 0].max
        body << br.call(left + ("═" * fill) + right)
        if data.empty?
          body << fr.call(empty, dm)
        else
          data.each do |r|
            tag = (key == :stale && r[:days]) ? "  · #{r[:days]}d" : ""
            body << fr.call("##{r[:number]} #{r[:title]}  (#{r[:repo]})#{tag}", gr)
          end
        end
        body << br.call("╚" + ("═" * (w + 2)) + "╝")
      end

      meta = "@#{config[:login]}  #{generated_at.strftime('%H:%M:%S')}  (#{config[:day_mode]})"
      meta += "  [#{Engine.scope_label(config[:scope])}]" if config[:scope]
      header = br.call("▓▒░ KAMANDAR ░▒▓  ") + gr.call(TerminalSurface.mpad(meta, [cols - 19, 0].max))
      footer = br.call(TerminalSurface.mpad(" [r] refresh    [q] quit", cols))

      inner = [rows - 2, 1].max
      view  = body.first(inner)
      view += Array.new(inner - view.size, "") if view.size < inner
      CLEAR_HOME + ([header] + view + [footer]).join("\r\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Browser surface — one self-contained, offline-capable HTML file.
  # ---------------------------------------------------------------------------
  module BrowserSurface
    module_function

    # The Kamandar mark: a small transparent PNG (downscaled from assets/logo.png
    # via `magick assets/logo.png -fuzz 12% -transparent white -trim -resize x44`)
    # inlined as a data URI. Keeps every surface self-contained — no external
    # asset, works offline over file://, carries no secret.
    LOGO_DATA_URI = "data:image/png;base64,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".freeze

    # Per-bucket icon + accent color, keyed by bucket key. `var(--warn)` lets the
    # stale bucket track the warning color across light/dark themes.
    BUCKET_META = {
      reviews_owed:         { icon: "\u{1F4E5}", color: "#0969da" }, # 📥
      wip:                  { icon: "\u{1F528}", color: "#8250df" }, # 🔨
      assigned_not_started: { icon: "\u{1F4CB}", color: "#1a7f37" }, # 📋
      in_review:            { icon: "\u{1F440}", color: "#6e40c9" }, # 👀
      in_qa:                { icon: "\u{1F9EA}", color: "#0a7ea4" }, # 🧪
      blocked:              { icon: "\u{1F6A7}", color: "#cf222e" }, # 🚧
      stale:                { icon: "\u{23F3}",  color: "var(--warn)" }, # ⏳
      forgot_reviewer:      { icon: "\u{1F648}", color: "#9a6700" }, # 🙈
      # issue+PR scope buckets
      assigned_todo:        { icon: "\u{1F4CB}", color: "#1a7f37" }, # 📋
      assigned_wip:         { icon: "\u{1F528}", color: "#8250df" }, # 🔨
      assigned_review:      { icon: "\u{1F440}", color: "#6e40c9" }, # 👀
      assigned_no_reviewer: { icon: "\u{1F648}", color: "#9a6700" }  # 🙈
    }.freeze

    def escape(text)
      text.to_s
          .gsub("&", "&amp;")
          .gsub("<", "&lt;")
          .gsub(">", "&gt;")
          .gsub('"', "&quot;")
          .gsub("'", "&#39;")
    end

    # Render a single self-contained HTML document. SECURITY: receives only
    # already-fetched display data — never a token or any secret. Inline CSS,
    # no external/CDN assets, no JS, works offline over file://.
    def render(buckets, config:, generated_at:, watch_seconds: 0)
      refresh =
        if watch_seconds.to_i > 0
          %(<meta http-equiv="refresh" content="#{watch_seconds.to_i}">)
        else
          ""
        end

      meta_list = Engine.bucket_meta(Engine.scope_mode(config))
      total = meta_list.sum { |key, _, _| (buckets[key] || []).size }
      sections = sections_html(buckets, meta_list)

      chips = [
        %(<span class="chip total">#{total} open</span>),
        %(<span class="chip">@#{escape(config[:login])}</span>),
        %(<span class="chip">#{escape(generated_at.strftime('%Y-%m-%d %H:%M'))}</span>),
        %(<span class="chip">#{escape(config[:day_mode])} days</span>),
        (config[:scope] ? %(<span class="chip">#{escape(Engine.scope_label(config[:scope]))}</span>) : nil),
        (watch_seconds.to_i > 0 ? %(<span class="chip live">live #{watch_seconds.to_i}s</span>) : nil)
      ].compact.join("\n      ")

      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        #{refresh}
        <title>Kamandar — @#{escape(config[:login])}</title>
        <style>#{css}</style>
        </head>
        <body>
        <header>
          <div class="wrap">
            <h1><img class="bow" src="#{BrowserSurface::LOGO_DATA_URI}" alt=""> Kamandar</h1>
            <div class="meta">
              #{chips}
            </div>
          </div>
        </header>
        <main>
        #{sections}
        </main>
        </body>
        </html>
      HTML
    end

    # Build the <section> blocks for each bucket. Shared by the static page
    # (render) and the live server page (ServerSurface). Display data only.
    def sections_html(buckets, meta_list)
      meta_list.map do |key, title, empty|
        rows = buckets[key] || []
        meta = BUCKET_META[key] || { icon: "•", color: "var(--accent)" }
        classes = +"bucket"
        classes << " warn" if key == :stale
        classes << " is-empty" if rows.empty?
        body =
          if rows.empty?
            %(<p class="empty">#{escape(empty)}</p>)
          else
            rows.map { |row| card(row, key) }.join("\n")
          end
        <<~SECTION
          <section class="#{classes}" style="--c:#{meta[:color]}">
            <h2><span class="icon">#{meta[:icon]}</span> <span class="htitle">#{escape(title)}</span> <span class="count">#{rows.size}</span></h2>
            #{body}
          </section>
        SECTION
      end.join("\n")
    end

    def card(row, key)
      badge =
        if key == :stale && row[:days]
          %(<span class="badge">#{row[:days]} #{escape(row[:mode])} days waiting</span>)
        else
          ""
        end
      <<~CARD
        <a class="card" href="#{escape(row[:url])}" target="_blank" rel="noopener" title="#{escape(row[:title])}">
          <span class="num">##{escape(row[:number])}</span>
          <span class="title">#{escape(row[:title])}</span>
          <span class="spacer"></span>
          <span class="repo">#{escape(row[:repo])}</span>
          #{badge}
        </a>
      CARD
    end

    def css
      <<~CSS
        :root{--bg:#f6f8fa;--fg:#1f2328;--muted:#656d76;--card:#fff;--border:#d0d7de;--accent:#0969da;--warn:#bc4c00;--warnbg:#fff8f0;--shadow:0 1px 2px rgba(0,0,0,.06),0 1px 6px rgba(0,0,0,.04)}
        @media (prefers-color-scheme: dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#8b949e;--card:#161b22;--border:#30363d;--accent:#58a6ff;--warn:#db6d28;--warnbg:#1f1206;--shadow:0 1px 2px rgba(0,0,0,.4),0 1px 8px rgba(0,0,0,.3)}}
        *{box-sizing:border-box}
        body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;background:var(--bg);color:var(--fg);line-height:1.45;-webkit-font-smoothing:antialiased}
        header{position:sticky;top:0;z-index:5;background:var(--bg);border-bottom:1px solid var(--border)}
        .wrap{max-width:880px;margin:0 auto;padding:18px 16px 14px}
        h1{margin:0;font-size:1.5rem;display:flex;align-items:center;gap:9px;letter-spacing:-.01em}
        .bow{height:1.6rem;width:auto;vertical-align:-.35rem}
        .meta{margin:11px 0 0;display:flex;flex-wrap:wrap;gap:6px}
        .chip{background:var(--card);border:1px solid var(--border);color:var(--muted);border-radius:999px;font-size:.78rem;padding:3px 10px;font-weight:500;white-space:nowrap}
        .chip.total{border-color:var(--accent);color:var(--accent);font-weight:700}
        .chip.live{border-color:var(--warn);color:var(--warn);font-weight:600}
        main{max-width:880px;margin:0 auto;padding:20px 16px 56px}
        .bucket{margin:22px 0}
        .bucket.is-empty{opacity:.55}
        h2{font-size:1.05rem;margin:0 0 10px;display:flex;align-items:center;gap:9px;border-bottom:1px solid var(--border);padding-bottom:8px}
        .icon{font-size:1.05rem;line-height:1;filter:saturate(1.1)}
        .htitle{font-weight:700}
        .count{margin-left:1px;background:var(--c);color:#fff;border-radius:999px;font-size:.74rem;line-height:1.5;padding:0 9px;font-weight:700;min-width:22px;text-align:center}
        .is-empty .count{background:var(--border);color:var(--muted)}
        .empty{color:var(--muted);font-style:italic;margin:6px 2px}
        .card{display:flex;align-items:center;gap:12px;text-decoration:none;color:inherit;background:var(--card);border:1px solid var(--border);border-left:3px solid var(--c);border-radius:10px;padding:13px 15px;margin:9px 0;box-shadow:var(--shadow);transition:transform .08s ease,border-color .08s ease,box-shadow .08s ease}
        .card:hover{transform:translateY(-1px);border-color:var(--c);box-shadow:0 2px 4px rgba(0,0,0,.08),0 4px 14px rgba(0,0,0,.06)}
        .spacer{flex:1 1 auto}
        .num{color:var(--muted);font:600 .85rem/1 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-variant-numeric:tabular-nums;flex:none}
        .title{font-weight:600;flex:0 1 auto;min-width:0}
        .repo{color:var(--muted);font-size:.78rem;background:var(--bg);border:1px solid var(--border);border-radius:6px;padding:2px 8px;white-space:nowrap;flex:none}
        .badge{background:var(--warn);color:#fff;border-radius:6px;font-size:.72rem;padding:3px 9px;white-space:nowrap;font-weight:600;flex:none}
        .bucket.warn .card{background:var(--warnbg)}
        @media (max-width:560px){.card{flex-wrap:wrap;gap:8px}.spacer{display:none}.repo{order:3}}
      CSS
    end

    # Write the HTML to a stable temp path (so watch-mode reload hits the same
    # tab). Returns the path.
    def write(html, path = HTML_PATH)
      File.write(path, html)
      path
    end

    # The browser surface's emit contract: write the file and (optionally) open
    # it. Returns the file path.
    def emit(html, path: HTML_PATH, open: true, host_os: RbConfig::CONFIG["host_os"])
      write(html, path)
      open_in_browser(path, host_os: host_os) if open
      path
    end

    def open_in_browser(path, host_os: RbConfig::CONFIG["host_os"])
      # Windows uses the plain path; POSIX uses a file:// URL.
      arg = host_os =~ /mswin|mingw|cygwin|windows/i ? path : "file://#{path}"
      cmd = Surface.browser_open_command(host_os, arg)
      system(*cmd)
    rescue StandardError => e
      $stderr.puts "kamandar: could not open browser (#{e.message}); page at #{path}"
    end
  end

  # ---------------------------------------------------------------------------
  # ServerSurface — the live local web app (served by Server over TCP).
  # Reuses BrowserSurface's CSS and cards, and adds a control bar so you can
  # switch scope and refresh in-page. SECURITY: like BrowserSurface, it is
  # handed only display data — never a token. Same no-secret guarantee.
  # ---------------------------------------------------------------------------
  module ServerSurface
    module_function

    SCOPE_MODES = %w[global org repo project].freeze

    # Project home — linked from the footer.
    REPO_URL = "https://github.com/cdrrazan/Kamandar"

    # Short sidebar tab labels. The panel headings keep the full descriptive
    # title (and it's the navitem's hover tooltip); the narrow sidebar shows
    # these so nothing truncates. Falls back to the full title if unmapped.
    SHORT_LABELS = {
      reviews_owed: "Reviews", wip: "Building", assigned_not_started: "Not started",
      in_review: "In review", in_qa: "In QA", blocked: "Blocked",
      stale: "Gone quiet", forgot_reviewer: "No reviewer",
      assigned_todo: "Not started", assigned_wip: "PR in draft",
      assigned_review: "PR in review", assigned_no_reviewer: "PR, no reviewer"
    }.freeze

    # One-line explanation of what each bucket collects, shown under the panel
    # heading. Keyed by bucket key across both scope modes.
    DESCRIPTIONS = {
      reviews_owed: "Open PRs where a review was requested from you — your turn to review.",
      wip: "Your own draft PRs still in progress.",
      assigned_not_started: "Issues assigned to you whose status hasn't moved off the backlog.",
      in_review: "Your issues submitted and waiting on review.",
      in_qa: "Your work that's currently in QA.",
      blocked: "Your work that's flagged as blocked.",
      stale: "Your ready (non-draft) PRs where the ball is in the reviewer's court and it's gone quiet.",
      forgot_reviewer: "Your ready PRs that don't have a reviewer requested yet.",
      assigned_todo: "Issues assigned to you with no linked PR yet — not started.",
      assigned_wip: "Assigned issues whose linked PR is still a draft.",
      assigned_review: "Assigned issues whose PR is ready and has a reviewer.",
      assigned_no_reviewer: "Assigned issues whose ready PR has no reviewer requested."
    }.freeze

    # Instrument Sans (UI) + JetBrains Mono (numbers/paths) webfonts. Served
    # pages have network access (live localhost), so a CDN link is fine here —
    # unlike BrowserSurface, which must stay self-contained for offline file://
    # use. Falls back to the system stack in extra_css if the fonts don't load.
    FONT_LINKS = <<~HTML.chomp
      <link rel="icon" type="image/x-icon" href="/favicon.ico">
      <link rel="preconnect" href="https://fonts.googleapis.com">
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
      <link href="https://fonts.googleapis.com/css2?family=Instrument+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
    HTML

    # The full live page: header chips + a control bar + the bucket sections.
    # `scope`/`name`/`project_url`/`poll` reflect the current request so the
    # form re-renders with the user's selection.
    def page(buckets, config:, generated_at:, mode: "global", name: "",
             project_url: "", poll: 0, stale: nil)
      esc         = BrowserSurface.method(:escape)
      meta_list   = Engine.bucket_meta(Engine.scope_mode(config))
      total       = meta_list.sum { |key, _, _| (buckets[key] || []).size }
      scope_label = config[:scope] ? Engine.scope_label(config[:scope]) : "global"
      login       = config[:login].to_s
      now         = generated_at

      refresh = poll.to_i > 0 ? %(<meta http-equiv="refresh" content="#{poll.to_i}">) : ""

      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        #{refresh}
        <title>Kamandar — @#{esc.call(login)}</title>
        #{FONT_LINKS}
        <style>#{extra_css}</style>
        </head>
        <body>
        #{header_html(config, generated_at: now, mode: mode, name: name, project_url: project_url, poll: poll, total: total, stale: stale)}
        <div class="shell">
          #{left_rail(buckets, meta_list, scope_label: scope_label, repos: distinct_repos(buckets))}
          <main class="main">
            #{kpi_row(buckets, meta_list, now: now, scope_label: scope_label)}
            #{sections_html(buckets, meta_list, now: now)}
          </main>
          #{right_rail(buckets, meta_list, now: now)}
        </div>
        #{footer_html(now)}
        </body>
        </html>
      HTML
    end

    # ---- header ------------------------------------------------------------
    # Sticky glass bar: brand + live/synced badge + user, over a tools row with
    # the scope fields, the scope segmented control, Apply/Refresh, and clock.
    # The whole thing is one GET <form class="controls"> so CSS :has() can
    # reveal only the fields a scope needs — no JavaScript.
    def header_html(config, generated_at:, mode:, name:, project_url:, poll:, total:, stale: nil)
      esc   = BrowserSurface.method(:escape)
      login = config[:login].to_s
      day   = config[:day_mode].to_s
      local = generated_at.getlocal # show wall-clock local time, not UTC
      live  = poll.to_i > 0 ? "Live · every #{poll.to_i}s" : "Synced #{local.strftime('%-I:%M %p')}"
      segments = SCOPE_MODES.map do |m|
        ck = m == mode ? " checked" : ""
        %(<input class="segr" type="radio" name="mode" id="m-#{m}" value="#{m}"#{ck}>) +
          %(<label class="seglabel" for="m-#{m}">#{m.capitalize}</label>)
      end.join
      <<~HEAD
        <header class="topbar">
          <form class="controls" method="get" action="/">
            <div class="bar bar-main">
              <a class="brand" href="/"><span class="logo">#{MenubarSurface::GLYPH}</span><span class="bname">Kamandar</span><span class="vpill">v#{VERSION}</span></a>
              <span class="grow"></span>
              <span class="livebadge"><span class="livedot"></span>#{esc.call(live)}</span>
              <span class="userbox"><span class="ulogin">@#{esc.call(login)}</span><span class="uava">#{esc.call(monogram(login))}</span></span>
            </div>
            <div class="bar bar-tools">
              <span class="seg" role="radiogroup" aria-label="Scope">#{segments}</span>
              <input class="field f-name" type="text" name="name" value="#{esc.call(name)}" placeholder="org or owner/name">
              <input class="field f-proj" type="text" name="project_url" value="#{esc.call(project_url)}" placeholder="project board URL">
              <label class="field f-poll pollbox" title="Auto-refresh interval — 0 turns it off">
                <span class="pollicon">↻</span><span class="polltext">Auto-refresh</span>
                <input type="number" name="poll" value="#{poll.to_i}" min="0" step="5" aria-label="Auto-refresh seconds"><span class="pollunit">s</span>
              </label>
              <label class="field f-stale pollbox" title="Days a PR can sit quiet before it counts as stale">
                <span class="pollicon">⏳</span><span class="polltext">Stale after</span>
                <input type="number" name="stale" value="#{config[:stale_days].to_i}" min="1" step="1" aria-label="Stale threshold in days"><span class="pollunit">d</span>
              </label>
              <button class="btn-apply" type="submit">Apply</button>
              <a class="btn-refresh" href="#{esc.call(self_link(mode, name, project_url, poll, stale))}" title="Refresh now">↻ Refresh</a>
              <span class="grow"></span>
              <span class="daymeta">#{esc.call(local.strftime('%H:%M:%S'))} · #{esc.call(day)} days</span>
              <span class="totalmeta">#{total} open</span>
            </div>
          </form>
        </header>
      HEAD
    end

    # ---- left rail ---------------------------------------------------------
    # Two carded groups of lanes: "Others' work" (reviews you owe) and "Your
    # work" (everything assigned to you). Each lane anchor-links to its section
    # in the main column — pure HTML, no JS.
    def left_rail(buckets, meta_list, scope_label:, repos:)
      esc = BrowserSurface.method(:escape)
      lane = lambda do |key, title|
        n    = (buckets[key] || []).size
        meta = BrowserSurface::BUCKET_META[key] || { color: "#8b9099" }
        %(<a class="lane#{n.zero? ? ' empty' : ''}" href="#sec-#{key}" style="--c:#{meta[:color]}">) +
          %(<span class="ldot"></span><span class="lname">#{esc.call(SHORT_LABELS[key] || title)}</span>) +
          %(<span class="lcount">#{n}</span></a>)
      end
      review, mine = meta_list.partition { |k, _t, _e| REVIEW_KEYS.include?(k) }
      review_open  = review.sum { |k, _, _| (buckets[k] || []).size }
      mine_open    = mine.sum { |k, _, _| (buckets[k] || []).size }
      <<~ASIDE
        <aside class="rail rail-left">
          <div class="card">
            <div class="card-head"><span class="eyebrow">Others' work</span><span class="openpill#{review_open.zero? ? ' z' : ''}">#{review_open} open</span></div>
            <div class="lane-list">#{review.map { |k, t, _| lane.call(k, t) }.join}</div>
          </div>
          <div class="card">
            <div class="card-head"><span class="eyebrow">Your work</span><span class="openpill#{mine_open.zero? ? ' z' : ''}">#{mine_open} open</span></div>
            <div class="lane-list">#{mine.map { |k, t, _| lane.call(k, t) }.join}</div>
            <div class="card-foot"><span class="mono">scope: #{esc.call(scope_label)}</span><span class="mono">#{repos} repo#{repos == 1 ? '' : 's'}</span></div>
          </div>
        </aside>
      ASIDE
    end

    # ---- KPI row -----------------------------------------------------------
    # Four stat cards, every number computed from the real buckets — no
    # fabricated CI/throughput/velocity metrics the engine can't produce.
    def kpi_row(buckets, meta_list, now:, scope_label:)
      esc      = BrowserSurface.method(:escape)
      keys     = meta_list.map(&:first)
      total    = keys.sum { |k| (buckets[k] || []).size }
      awaiting = (buckets[:reviews_owed] || []).size
      yours    = total - awaiting
      quiet_rows = buckets[:stale] || []
      repos    = distinct_repos(buckets)

      oldest_owed = (buckets[:reviews_owed] || []).map { |r| Engine.parse_time(r[:updated_at]) }.compact.min
      owed_sub    = oldest_owed ? "oldest updated #{rel_short(oldest_owed, now)} ago" : "all caught up"
      max_days    = quiet_rows.map { |r| r[:days].to_i }.max
      quiet_sub   = quiet_rows.empty? ? "nothing gone quiet" : "oldest #{max_days} #{quiet_rows.first[:mode] || 'business'} days"

      owed_color  = (BrowserSurface::BUCKET_META[:reviews_owed] || {})[:color] || "#0969da"
      quiet_color = (BrowserSurface::BUCKET_META[:stale] || {})[:color] || "#bc4c00"
      cards = [
        ["Awaiting your review", awaiting, owed_sub, owed_color],
        ["Your open work",       yours,    "across #{repos} repo#{repos == 1 ? '' : 's'}", "#8250df"],
        ["Gone quiet",           quiet_rows.size, quiet_sub, quiet_color],
        ["In queue",             total,    "scope: #{esc.call(scope_label)}", "#0969da"]
      ]
      body = cards.map do |label, value, sub, color|
        %(<div class="kpi" style="--c:#{color}"><span class="kpi-l">#{esc.call(label)}</span>) +
          %(<span class="kpi-v">#{value}</span><span class="kpi-s">#{sub}</span></div>)
      end.join
      %(<div class="kpis">#{body}</div>)
    end

    # ---- main sections -----------------------------------------------------
    # A tab strip over one section per bucket. Only "Reviews you owe" shows by
    # default; the tabs are anchor links (`#sec-key`) so :target CSS reveals the
    # clicked section and hides the rest — same mechanism the rail links use, no
    # JavaScript. Every section stays in the DOM (and anchored) for those links.
    def sections_html(buckets, meta_list, now:)
      esc  = BrowserSurface.method(:escape)
      tabs = meta_list.map do |key, title, _empty|
        n = (buckets[key] || []).size
        %(<a class="mtab mt-#{key}" href="#sec-#{key}">) +
          %(<span class="mt-nm">#{esc.call(SHORT_LABELS[key] || title)}</span>) +
          %(<span class="mt-n#{n.zero? ? ' z' : ''}">#{n}</span></a>)
      end.join
      nav = %(<nav class="mtabs" role="tablist" aria-label="Buckets">#{tabs}</nav>)

      secs = meta_list.map do |key, title, empty|
        rows = buckets[key] || []
        meta = BrowserSurface::BUCKET_META[key] || { icon: "•", color: "#8b9099" }
        desc = DESCRIPTIONS[key]
        head = %(<div class="sec-head"><span class="sec-ic">#{meta[:icon]}</span>) +
               %(<h2 class="sec-title">#{esc.call(title)}</h2>) +
               %(<span class="sec-count#{rows.empty? ? ' z' : ''}">#{rows.size}</span>) +
               (desc ? %(<p class="sec-desc">#{esc.call(desc)}</p>) : "") + "</div>"
        body =
          if rows.empty?
            %(<div class="emptybox"><span class="emptyicon">#{meta[:icon]}</span><p class="emptymsg">#{esc.call(empty)}</p></div>)
          else
            rows.map { |r| queue_row(r, key, now) }.join
          end
        %(<section class="sec#{key == :stale ? ' warn' : ''}" id="sec-#{key}" style="--c:#{meta[:color]}">) +
          head + %(<div class="rows">#{body}</div></section>)
      end.join("\n")
      nav + secs
    end

    # A single queue row — real fields only.
    def queue_row(row, key, now)
      esc     = BrowserSurface.method(:escape)
      updated = rel_short(row[:updated_at], now)
      sub = []
      sub << %(<span class="m-updated">updated #{esc.call(updated)} ago</span>) if updated
      if key == :stale && row[:days]
        d = row[:days].to_i
        sub << %(<span class="waitchip">quiet #{d} #{esc.call(row[:mode].to_s)} day#{d == 1 ? '' : 's'}</span>)
      end
      %(<a class="qrow" href="#{esc.call(row[:url])}" target="_blank" rel="noopener">) +
        %(<span class="q-rail"></span><span class="q-body">) +
        %(<span class="q-meta"><span class="q-repo">#{esc.call(row[:repo])}</span><span class="q-sep">/</span><span class="q-num">##{esc.call(row[:number])}</span></span>) +
        %(<span class="q-title">#{esc.call(row[:title])}</span>) +
        %(<span class="q-sub">#{sub.join}</span></span>) +
        %(<span class="q-open">Open ↗</span></a>)
    end

    # ---- right rail --------------------------------------------------------
    # Queue-at-a-glance mini bars, an "oldest waiting" list, and a focus card —
    # all derived from the same buckets (no invented activity feed or history).
    def right_rail(buckets, meta_list, now:)
      esc  = BrowserSurface.method(:escape)
      maxn = meta_list.map { |k, _, _| (buckets[k] || []).size }.max.to_i
      maxn = 1 if maxn.zero?
      bars = meta_list.map do |key, title, _e|
        n     = (buckets[key] || []).size
        meta  = BrowserSurface::BUCKET_META[key] || { color: "#8b9099" }
        w     = (n.to_f / maxn * 100).round
        %(<a class="glance" href="#sec-#{key}" style="--c:#{meta[:color]}">) +
          %(<span class="g-name">#{esc.call(SHORT_LABELS[key] || title)}</span>) +
          %(<span class="g-track"><span class="g-fill" style="width:#{w}%"></span></span>) +
          %(<span class="g-n">#{n}</span></a>)
      end.join

      mine_keys = meta_list.map(&:first).reject { |k| REVIEW_KEYS.include?(k) }
      pool = mine_keys.flat_map { |k| buckets[k] || [] }
                      .map { |r| [Engine.parse_time(r[:updated_at]), r] }
                      .reject { |t, _| t.nil? }
                      .sort_by { |t, _| t }
                      .first(5)
      oldest_card =
        if pool.empty?
          ""
        else
          items = pool.map do |t, r|
            %(<a class="ow" href="#{esc.call(r[:url])}" target="_blank" rel="noopener">) +
              %(<span class="ow-title">#{esc.call(r[:title])}</span>) +
              %(<span class="ow-age mono">#{esc.call(rel_short(t, now))} ago</span></a>)
          end.join
          %(<div class="card"><div class="card-title">Oldest waiting</div><div class="ow-list">#{items}</div></div>)
        end

      awaiting = (buckets[:reviews_owed] || []).size
      first    = (buckets[:reviews_owed] || []).first
      focus =
        if awaiting.positive? && first
          %(<div class="card focus"><div class="f-title">Focus block</div>) +
            %(<p class="f-body">You owe #{awaiting} review#{awaiting == 1 ? '' : 's'}. Clear the queue while it's fresh — start with the oldest.</p>) +
            %(<a class="f-btn" href="#{esc.call(first[:url])}" target="_blank" rel="noopener">Start reviewing →</a></div>)
        else
          %(<div class="card focus clear"><div class="f-title">Inbox zero</div>) +
            %(<p class="f-body">No reviews waiting on you. Nice.</p></div>)
        end

      <<~ASIDE
        <aside class="rail rail-right">
          <div class="card"><div class="card-title">Queue at a glance</div><div class="glance-list">#{bars}</div></div>
          #{oldest_card}
          #{focus}
        </aside>
      ASIDE
    end

    # ---- footer ------------------------------------------------------------
    def footer_html(now)
      esc = BrowserSurface.method(:escape)
      <<~FOOT
        <footer class="foot">
          <div class="foot-in">
            <span class="f-brand">Kamandar v#{VERSION}</span>
            <span class="f-sep">·</span><span>personal GitHub command center</span>
            <span class="f-sep">·</span><span class="mono">127.0.0.1 · stdlib-only Ruby</span>
            <span class="grow"></span>
            <a class="f-gh" href="#{REPO_URL}" target="_blank" rel="noopener">GitHub</a>
            <span class="f-sep">·</span><span class="mono">generated #{esc.call(now.getlocal.strftime('%H:%M:%S'))}</span>
          </div>
        </footer>
      FOOT
    end

    # Two-letter monogram for the header avatar, from the login.
    def monogram(login)
      s = login.to_s.gsub(/[^A-Za-z0-9]/, "")
      return "?" if s.empty?
      (s.length >= 2 ? s[0, 2] : s[0, 1]).upcase
    end

    # Distinct repos across every row — a real "N repos in queue" figure.
    def distinct_repos(buckets)
      buckets.values.flatten.map { |r| r[:repo] }.compact.uniq.size
    end

    # Compact relative age ("41m" / "3h" / "2d") from an ISO timestamp or Time
    # to `now`. Returns nil when the input is missing/unparseable (e.g. --demo
    # rows without updatedAt), so the caller just omits that meta.
    def rel_short(iso, now)
      t = iso.is_a?(Time) ? iso : Engine.parse_time(iso)
      return nil unless t
      secs = (now - t).to_i
      return "now" if secs < 60
      return "#{secs / 60}m" if secs < 3600
      return "#{secs / 3600}h" if secs < 86_400
      "#{secs / 86_400}d"
    rescue ArgumentError, TypeError
      nil
    end

    # Buckets that represent *other people's* work (review requested from you),
    # as opposed to your own assigned issues/PRs. Drives the left-rail split.
    REVIEW_KEYS = %i[reviews_owed].freeze

    # A tiny error page reusing the same chrome — shown when a fetch fails so the
    # server keeps running instead of dropping the connection.
    def error_page(message, config:)
      esc = BrowserSurface.method(:escape)
      <<~HTML
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Kamandar — error</title>#{FONT_LINKS}<style>#{extra_css}</style></head>
        <body>
        <header class="topbar"><div class="bar bar-main"><a class="brand" href="/"><span class="logo">#{MenubarSurface::GLYPH}</span><span class="bname">Kamandar</span></a></div></header>
        <div class="shell shell-error">
          <section class="sec warn" style="--c:#cf222e">
            <div class="sec-head"><span class="sec-ic">\u{26A0}\u{FE0F}</span><h2 class="sec-title">Couldn't load your queue</h2></div>
            <div class="rows"><div class="emptybox"><p class="emptymsg">#{esc.call(message)}</p><p class="emptymsg"><a href="/">Try again</a></p></div></div>
          </section>
        </div>
        </body></html>
      HTML
    end

    # GET link back to self with the current selection preserved.
    def self_link(mode, name, project_url, poll, stale = nil)
      m = mode.to_s == "global" ? "" : mode.to_s # global is the default; omit it
      q = { "mode" => m, "name" => name, "project_url" => project_url,
            "poll" => poll.to_i, "stale" => stale.to_i }
      pairs = q.reject { |_, v| v.to_s.empty? || v == 0 }
               .map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }
      pairs.empty? ? "/" : "/?#{pairs.join('&')}"
    end

    # The full self-contained design system for the live web app — ported from
    # the Kamandar Claude Design mockup (Instrument Sans + JetBrains Mono, oklch
    # palette, 3-column grid). Theme-aware via prefers-color-scheme. No external
    # assets beyond the webfont links; every panel is fed by real bucket data.
    def extra_css
      # Active-tab highlight, generated per bucket: a tab lights up when its
      # section is the :target (and reviews_owed lights up when nothing is).
      keys       = BrowserSurface::BUCKET_META.keys
      tab_active = (keys.map { |k| ".main:has(#sec-#{k}:target) .mt-#{k}" } +
                    [".main:not(:has(.sec:target)) .mt-reviews_owed"]).join(",")
      <<~CSS
        :root{
          --bg:#f4f5f7;--surface:#fff;--ink:#14161a;--ink2:#2b3038;--muted:#6b7280;--muted2:#8b9099;
          --line:#e6e8ec;--line2:#f0f1f4;
          --accent:oklch(0.53 0.17 262);--accent-d:oklch(0.47 0.17 262);--accent2:oklch(0.5 0.19 285);
          --accent-bg:oklch(0.97 0.02 262);--accent-bd:oklch(0.9 0.05 262);
          --good:oklch(0.62 0.15 150);--good-bg:oklch(0.96 0.03 150);--good-bd:oklch(0.9 0.06 150);
          --warn:oklch(0.58 0.16 45);--warn-bg:oklch(0.96 0.04 50);--warn-bd:oklch(0.9 0.06 50);
          --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
        }
        @media (prefers-color-scheme:dark){:root{
          --bg:#0e1116;--surface:#161b22;--ink:#e6edf3;--ink2:#c9d1d9;--muted:#8b949e;--muted2:#6e7681;
          --line:#232a33;--line2:#1b212a;
          --accent:oklch(0.72 0.14 262);--accent-d:oklch(0.66 0.15 262);--accent2:oklch(0.68 0.16 288);
          --accent-bg:color-mix(in srgb,var(--accent) 16%,transparent);--accent-bd:color-mix(in srgb,var(--accent) 40%,transparent);
        }}
        *{box-sizing:border-box}
        html,body{margin:0;padding:0}
        body{font-family:"Instrument Sans","Helvetica Neue",Helvetica,-apple-system,BlinkMacSystemFont,Arial,sans-serif;-webkit-font-smoothing:antialiased;color:var(--ink);background:linear-gradient(180deg,var(--bg),color-mix(in srgb,var(--bg) 88%,#000 4%));min-height:100vh;padding-bottom:52px}
        a{color:var(--accent);text-decoration:none}
        a:hover{color:var(--accent-d)}
        .mono{font-family:var(--mono)}
        .grow{flex:1 1 auto}
        ::selection{background:color-mix(in srgb,var(--accent) 26%,transparent)}

        /* ---------- header ---------- */
        .topbar{position:sticky;top:0;z-index:20;background:color-mix(in srgb,var(--surface) 86%,transparent);backdrop-filter:saturate(1.4) blur(14px);-webkit-backdrop-filter:saturate(1.4) blur(14px);border-bottom:1px solid var(--line)}
        .controls{max-width:1440px;margin:0 auto;padding:0 28px}
        .bar{display:flex;align-items:center;gap:14px}
        .bar-main{height:60px}
        .bar-tools{flex-wrap:wrap;gap:8px;padding:10px 0 12px;border-top:1px solid var(--line2)}
        .brand{display:flex;align-items:center;gap:10px;color:var(--ink)}
        .brand:hover{color:var(--ink)}
        .logo{width:26px;height:26px;display:flex;align-items:center;justify-content:center;font-size:19px;line-height:1}
        .bname{font-size:16px;font-weight:600;letter-spacing:-.02em}
        .vpill{font-family:var(--mono);font-size:10px;color:var(--muted2);border:1px solid var(--line);border-radius:5px;padding:2px 5px}
        .seg{display:inline-flex;align-items:center;gap:2px;background:var(--line2);border:1px solid var(--line);border-radius:9px;padding:3px}
        .segr{position:absolute;width:1px;height:1px;opacity:0;pointer-events:none}
        .seglabel{cursor:pointer;font-size:13px;font-weight:500;color:var(--muted);padding:5px 13px;border-radius:6px;transition:background .12s,color .12s}
        .seglabel:hover{color:var(--ink);background:color-mix(in srgb,var(--line) 70%,transparent)}
        .segr:checked+.seglabel{background:var(--surface);color:var(--ink);box-shadow:0 1px 2px rgba(16,24,40,.1)}
        .segr:focus-visible+.seglabel{outline:2px solid var(--accent);outline-offset:2px}
        .livebadge{display:inline-flex;align-items:center;gap:7px;height:30px;padding:0 11px;border-radius:8px;background:var(--good-bg);border:1px solid var(--good-bd);font-size:12px;font-weight:600;color:oklch(0.44 0.11 150);white-space:nowrap}
        .livedot{width:6px;height:6px;border-radius:50%;background:var(--good);animation:km-pulse 2.4s ease-in-out infinite}
        @keyframes km-pulse{0%,100%{opacity:1}50%{opacity:.35}}
        .userbox{display:inline-flex;align-items:center;gap:8px;height:30px;padding:0 4px 0 10px;border-radius:8px;border:1px solid var(--line);background:var(--surface)}
        .ulogin{font-family:var(--mono);font-size:12px;color:var(--ink2)}
        .uava{width:22px;height:22px;border-radius:6px;background:linear-gradient(135deg,#2b3038,#4b5058);color:#fff;font-size:10px;font-weight:600;display:flex;align-items:center;justify-content:center}
        /* tools row */
        .field{min-width:170px;font:inherit;font-size:13px;height:30px;padding:0 11px;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--ink)}
        .field:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 18%,transparent)}
        .controls .field{display:none}
        .controls:has(#m-org:checked) .f-name,
        .controls:has(#m-repo:checked) .f-name,
        .controls:has(#m-project:checked) .f-proj,
        .controls:has(.segr:checked:not(#m-global)) .f-poll{display:inline-flex}
        .controls .f-stale{display:inline-flex} /* stale applies to every scope */
        .pollbox{align-items:center;gap:7px;min-width:0;padding:0 7px 0 11px;cursor:text}
        .pollbox:focus-within{border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 16%,transparent)}
        .pollicon{color:var(--accent);font-size:14px;line-height:1}
        .polltext{font-size:12px;font-weight:600;color:var(--muted)}
        .pollbox input{width:46px;height:22px;text-align:center;font-family:var(--mono);font-size:12px;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--ink);min-width:0;padding:0}
        .pollbox input:focus{outline:none;border-color:var(--accent)}
        .pollunit{font-size:12px;color:var(--muted2)}
        .btn-apply{border:none;background:var(--accent);color:#fff;font:600 12px "Instrument Sans",sans-serif;height:30px;padding:0 15px;border-radius:8px;cursor:pointer;box-shadow:0 1px 2px rgba(16,24,40,.14);transition:background .12s}
        .btn-apply:hover{background:var(--accent-d)}
        .btn-refresh{display:inline-flex;align-items:center;gap:5px;border:1px solid var(--line);background:var(--surface);color:var(--ink2);font:500 12px "Instrument Sans",sans-serif;height:30px;padding:0 12px;border-radius:8px;transition:background .12s}
        .btn-refresh:hover{background:var(--line2);color:var(--ink)}
        .daymeta{font-family:var(--mono);font-size:11px;color:var(--muted2)}
        .totalmeta{font-size:11px;font-weight:600;color:var(--accent);background:var(--accent-bg);border:1px solid var(--accent-bd);border-radius:20px;padding:2px 9px}

        /* ---------- layout ---------- */
        .shell{max-width:1440px;margin:0 auto;padding:22px 28px 48px;display:grid;grid-template-columns:248px minmax(0,1fr) 300px;gap:20px;align-items:start}
        .rail{display:flex;flex-direction:column;gap:14px;position:sticky;top:112px}
        .main{display:flex;flex-direction:column;gap:18px;min-width:0}

        /* ---------- cards / rails ---------- */
        .card{background:var(--surface);border:1px solid var(--line);border-radius:14px;box-shadow:0 1px 2px rgba(16,24,40,.04)}
        .card-head{display:flex;align-items:center;justify-content:space-between;padding:13px 14px 11px}
        .eyebrow{font-size:10.5px;font-weight:700;letter-spacing:.09em;color:var(--muted2);text-transform:uppercase}
        .openpill{font-size:11px;font-weight:600;color:var(--accent);background:var(--accent-bg);border:1px solid var(--accent-bd);border-radius:20px;padding:1px 8px}
        .openpill.z{color:var(--muted2);background:var(--line2);border-color:var(--line)}
        .card-title{font-size:13.5px;font-weight:600;letter-spacing:-.01em;padding:15px 15px 12px}
        .lane-list{display:flex;flex-direction:column;padding:0 8px 10px}
        .lane{display:flex;align-items:center;gap:10px;padding:9px 10px;border-radius:9px;color:var(--ink2);transition:background .12s}
        .lane:hover{background:var(--line2);color:var(--ink2)}
        .ldot{width:6px;height:6px;border-radius:50%;background:var(--c);flex:none}
        .lane.empty .ldot{background:#c8ccd2}
        .lname{font-size:13.5px;font-weight:500;flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .lcount{font-size:11px;font-weight:700;color:#fff;background:var(--c);border-radius:20px;padding:1px 8px;min-width:20px;text-align:center}
        .lane.empty .lcount{color:var(--muted2);background:var(--line2);font-weight:600}
        .card-foot{border-top:1px solid var(--line2);padding:10px 14px;display:flex;align-items:center;justify-content:space-between}

        /* ---------- KPI row ---------- */
        .kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
        .kpi{background:var(--surface);border:1px solid var(--line);border-top:2px solid var(--c);border-radius:13px;padding:13px 14px;box-shadow:0 1px 2px rgba(16,24,40,.04);display:flex;flex-direction:column;gap:6px}
        .kpi-l{font-size:11px;font-weight:600;letter-spacing:.04em;color:var(--muted2);text-transform:uppercase}
        .kpi-v{font-size:26px;font-weight:600;letter-spacing:-.03em;color:var(--ink);font-family:var(--mono);line-height:1}
        .kpi-s{font-size:11.5px;color:var(--muted2)}

        /* ---------- main tabs ---------- */
        .mtabs{display:flex;flex-wrap:wrap;gap:6px;padding:5px;background:var(--surface);border:1px solid var(--line);border-radius:12px;box-shadow:0 1px 2px rgba(16,24,40,.04)}
        .mtab{display:inline-flex;align-items:center;gap:7px;padding:7px 12px;border-radius:8px;color:var(--muted);font-size:13px;font-weight:500;transition:background .12s,color .12s}
        .mtab:hover{background:var(--line2);color:var(--ink)}
        .mt-nm{letter-spacing:-.01em}
        .mt-n{font-family:var(--mono);font-size:11px;font-weight:700;color:var(--muted2);background:var(--line2);border-radius:20px;padding:1px 7px;min-width:20px;text-align:center}
        .mt-n.z{opacity:.7}
        #{tab_active}{background:var(--accent-bg);color:var(--accent)}
        #{keys.map { |k| ".main:has(#sec-#{k}:target) .mt-#{k} .mt-n" }.join(",")},
        .main:not(:has(.sec:target)) .mt-reviews_owed .mt-n{background:var(--accent);color:#fff;opacity:1}

        /* ---------- sections ---------- */
        /* Only the targeted section shows; reviews_owed is the default tab. */
        .sec{display:none}
        .main:not(:has(.sec:target)) #sec-reviews_owed{display:block}
        .sec:target{display:block}
        .sec{background:var(--surface);border:1px solid var(--line);border-radius:16px;box-shadow:0 1px 3px rgba(16,24,40,.05);overflow:hidden;scroll-margin-top:118px}
        .sec-head{padding:16px 18px 14px;border-bottom:1px solid var(--line2);display:flex;align-items:center;gap:10px;flex-wrap:wrap}
        .sec-ic{width:30px;height:30px;display:inline-flex;align-items:center;justify-content:center;background:color-mix(in srgb,var(--c) 15%,transparent);border-radius:9px;font-size:15px}
        .sec-title{margin:0;font-size:16px;font-weight:600;letter-spacing:-.02em}
        .sec-count{font-size:11px;font-weight:700;color:#fff;background:var(--c);border-radius:20px;padding:2px 8px;min-width:22px;text-align:center}
        .sec-count.z{color:var(--muted2);background:var(--line2)}
        .sec-desc{flex-basis:100%;margin:2px 0 0;font-size:13px;color:var(--muted)}
        .rows{display:flex;flex-direction:column}
        .qrow{position:relative;display:flex;align-items:center;gap:14px;padding:13px 18px 13px 24px;border-bottom:1px solid var(--line2);color:inherit;transition:background .12s}
        .qrow:last-child{border-bottom:none}
        .qrow:hover{background:color-mix(in srgb,var(--c) 5%,var(--surface));color:inherit}
        .q-rail{position:absolute;left:0;top:10px;bottom:10px;width:3px;border-radius:0 3px 3px 0;background:var(--c)}
        .q-body{display:flex;flex-direction:column;gap:5px;min-width:0;flex:1}
        .q-meta{display:flex;align-items:center;gap:8px;font-family:var(--mono);font-size:11.5px}
        .q-repo{color:var(--muted2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:280px}
        .q-sep{color:#d2d6dc}
        .q-num{font-weight:600;color:var(--accent)}
        .q-title{font-size:14.5px;font-weight:600;letter-spacing:-.01em;color:var(--ink);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .qrow:hover .q-title{color:var(--accent)}
        .q-sub{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
        .m-updated{font-size:12px;color:var(--muted2)}
        .waitchip{font-size:11px;font-weight:600;color:oklch(0.46 0.14 45);background:var(--warn-bg);border:1px solid var(--warn-bd);border-radius:20px;padding:1px 8px}
        .q-open{flex:none;font-size:12px;font-weight:600;color:var(--muted2);border:1px solid var(--line);border-radius:8px;padding:6px 11px;transition:color .12s,border-color .12s,background .12s}
        .qrow:hover .q-open{color:var(--accent);border-color:var(--accent-bd);background:var(--accent-bg)}

        /* ---------- right rail widgets ---------- */
        .glance-list{display:flex;flex-direction:column;gap:9px;padding:0 15px 15px}
        .glance{display:flex;align-items:center;gap:10px;color:inherit}
        .glance:hover{color:inherit}
        .g-name{font-size:12px;color:var(--ink2);width:98px;flex:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .glance:hover .g-name{color:var(--accent)}
        .g-track{flex:1;height:6px;border-radius:3px;background:var(--line2);overflow:hidden}
        .g-fill{display:block;height:100%;border-radius:3px;background:var(--c);min-width:2px}
        .g-n{font-family:var(--mono);font-size:11.5px;font-weight:600;color:var(--muted);width:22px;text-align:right;flex:none}
        .ow-list{display:flex;flex-direction:column;padding:0 15px 12px}
        .ow{display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid var(--line2);color:inherit}
        .ow:last-child{border-bottom:none}
        .ow:hover{color:inherit}
        .ow-title{font-size:12.5px;color:var(--ink2);flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .ow:hover .ow-title{color:var(--accent)}
        .ow-age{flex:none;color:var(--muted2);font-size:11px}
        .focus{background:linear-gradient(150deg,#1d2026,#2b3038);border:none;padding:15px;color:#fff;box-shadow:0 4px 14px rgba(16,24,40,.16)}
        .focus.clear{background:linear-gradient(150deg,oklch(0.48 0.12 162),oklch(0.42 0.11 178))}
        .f-title{font-size:13px;font-weight:600;margin-bottom:6px}
        .f-body{margin:0 0 12px;font-size:12.5px;line-height:1.45;color:rgba(255,255,255,.66)}
        .f-btn{display:block;text-align:center;width:100%;background:#fff;color:#14161a;font:600 12.5px "Instrument Sans",sans-serif;height:32px;line-height:32px;border-radius:8px}
        .f-btn:hover{background:#e8eaee;color:#14161a}

        /* ---------- empty state ---------- */
        .emptybox{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;padding:44px 24px;text-align:center}
        .emptyicon{font-size:2.4rem;line-height:1;opacity:.85}
        .emptymsg{margin:0;color:var(--muted);font-size:14px;font-weight:500}

        /* ---------- footer (pinned to the viewport bottom) ---------- */
        .foot{position:fixed;left:0;right:0;bottom:0;z-index:20;border-top:1px solid var(--line);background:color-mix(in srgb,var(--surface) 92%,transparent);backdrop-filter:saturate(1.4) blur(14px);-webkit-backdrop-filter:saturate(1.4) blur(14px)}
        .foot-in{max-width:1440px;margin:0 auto;padding:12px 28px;display:flex;align-items:center;gap:12px;flex-wrap:wrap;font-size:12px;color:var(--muted2)}
        .f-brand{font-weight:600;color:var(--ink2)}
        .f-sep{color:#d2d6dc}
        .f-gh{font-weight:500}
        .shell-error{min-height:46vh}

        /* ---------- responsive ---------- */
        @media (max-width:1180px){
          .shell{grid-template-columns:220px minmax(0,1fr)}
          .rail-right{display:none}
          .kpis{grid-template-columns:repeat(2,1fr)}
        }
        @media (max-width:860px){
          .controls,.shell,.foot-in{padding-left:16px;padding-right:16px}
          .shell{grid-template-columns:1fr;padding-top:16px}
          .rail{position:static}
          .rail-left{order:2}
          .bar-main{flex-wrap:wrap;height:auto;padding:12px 0}
          .kpis{grid-template-columns:repeat(2,1fr)}
          .q-open{display:none}
        }
        @media (max-width:520px){.kpis{grid-template-columns:1fr}}
      CSS
    end
  end

  # ---------------------------------------------------------------------------
  # Menu-bar surface — emits a SwiftBar/xbar plugin document on stdout. Those
  # apps run an executable on an interval and render its stdout in the macOS
  # menu bar: the first line is the bar title, `---` opens the dropdown, a `--`
  # prefix nests a submenu item, and ` | href=… color=…` set per-line params.
  # Pure: consumes buckets only (no network, no engine change) — exactly the
  # "add a menubar = new surface" the architecture was built for. The token is
  # never referenced here, so it can never reach the output.
  # ---------------------------------------------------------------------------
  module MenubarSurface
    module_function

    GLYPH     = "\u{1F3F9}".freeze # 🏹 — matches the app brand
    ATTENTION = "#db6d28".freeze   # warn orange: bar tint when something needs you
    MAX_TITLE = 52                 # truncate long PR/issue titles so the menu stays tidy
    MAX_ROWS  = 12                 # cap rows per bucket; overflow links to the web app

    # SwiftBar/xbar read ` | ` as the start of params and newlines as item
    # breaks — neutralize both in any text we interpolate into a line.
    def clean(text)
      text.to_s.tr("|", "¦").gsub(/\s+/, " ").strip
    end

    def truncate(text, max = MAX_TITLE)
      t = clean(text)
      t.length > max ? "#{t[0, max - 1]}…" : t
    end

    # Build the plugin document. `generated_at` is injected (surface stays pure,
    # no Time.now here); `port` deep-links the dropdown to the live web app.
    def render(buckets, config:, generated_at:, port: Server::DEFAULT_PORT)
      mode  = (config[:scope] && config[:scope][:mode]) || :global
      metas = Engine.bucket_meta(mode)
      total = buckets.values.sum { |rows| rows.size }
      attn  = (buckets.fetch(:reviews_owed, []).size +
               buckets.fetch(:stale, []).size).positive?

      lines = []
      title = total.zero? ? GLYPH.dup : "#{GLYPH} #{total}"
      lines << (attn ? "#{title} | color=#{ATTENTION}" : title)
      lines << "---"

      login = config[:login].to_s
      head  = login.empty? ? "Kamandar" : "Kamandar — @#{clean(login)}"
      prof  = login.empty? ? "https://github.com" : "https://github.com/#{clean(login)}"
      lines << "#{head} | href=#{prof}"
      lines << "Updated #{generated_at.strftime('%-I:%M %p')} | color=gray size=12"

      metas.each do |key, title_text, _empty|
        rows  = buckets.fetch(key, [])
        meta  = BrowserSurface::BUCKET_META[key] || { icon: "•", color: "#8b949e" }
        color = meta[:color].start_with?("#") ? meta[:color] : ATTENTION
        header = "#{meta[:icon]} #{clean(title_text)} (#{rows.size})"
        lines << "---"
        lines << (rows.empty? ? "#{header} | color=gray" : "#{header} | color=#{color}")
        rows.first(MAX_ROWS).each do |row|
          repo = row[:repo] ? "  (#{clean(row[:repo])})" : ""
          lines << "--##{row[:number]} #{truncate(row[:title])}#{repo} | href=#{row[:url]} color=#{color}"
        end
        if rows.size > MAX_ROWS
          lines << "--…and #{rows.size - MAX_ROWS} more | href=http://#{Server::HOST}:#{port} color=gray"
        end
      end

      lines << "---"
      lines << "Open the web app | href=http://#{Server::HOST}:#{port}"
      lines << "Refresh | refresh=true"
      lines.join("\n") + "\n"
    end

    # Minimal plugin shown when the fetch fails, so the bar flags the problem
    # (red glyph) instead of silently keeping a stale count.
    def error(message)
      ["#{GLYPH} ⚠\u{FE0F} | color=#cf222e", "---",
       "Couldn't load your queue", "--#{clean(message)}", "---",
       "Retry | refresh=true"].join("\n") + "\n"
    end

    def emit(output, io: $stdout)
      io.puts output
    end
  end

  # ---------------------------------------------------------------------------
  # MailSurface — a plain-text daily digest of the queue plus RFC-822 framing.
  # Pure like every other surface: consumes buckets only, never touches the
  # network or the token. The SMTP send lives in Mailer; this just builds the
  # subject, the body, and the assembled message. (`--email`.)
  # ---------------------------------------------------------------------------
  module MailSurface
    module_function

    MAX_ROWS = 15 # cap rows per bucket so a huge queue still makes a readable email

    # One-line subject, ASCII-only (no RFC-2047 encoding needed): total open plus
    # the two counts that actually demand action — reviews owed and stale PRs.
    def subject(buckets, config)
      total = buckets.values.sum { |rows| rows.size }
      owed  = buckets.fetch(:reviews_owed, []).size
      stale = buckets.fetch(:stale, []).size
      bits  = ["#{total} open"]
      bits << "#{owed} to review" if owed.positive?
      bits << "#{stale} stale"    if stale.positive?
      "Kamandar daily: #{bits.join(', ')}"
    end

    # Plain-text digest. `generated_at` is injected (surface stays pure). Sections
    # follow bucket_meta order; empty buckets collapse into one trailing line.
    def text_body(buckets, config, generated_at:)
      mode  = (config[:scope] && config[:scope][:mode]) || :global
      metas = Engine.bucket_meta(mode)
      login = config[:login].to_s
      total = metas.sum { |key, _t, _e| buckets.fetch(key, []).size }
      local = generated_at.getlocal # local wall-clock, not UTC (matches the web UI)

      out = []
      out << "Kamandar — daily summary#{login.empty? ? '' : " for @#{login}"}"
      out << "#{local.strftime('%a %b %-d, %Y · %-I:%M %p')} · " \
             "#{Engine.scope_label(config[:scope])} · #{total} open"
      out << ""

      empty = []
      metas.each do |key, title, _e|
        rows  = buckets.fetch(key, [])
        label = ServerSurface::SHORT_LABELS[key] || title
        if rows.empty?
          empty << label
          next
        end
        out << "#{label.upcase} (#{rows.size})"
        rows.first(MAX_ROWS).each do |row|
          repo = row[:repo] ? " (#{row[:repo]})" : ""
          tail = row[:days] ? "  — quiet #{row[:days]}d" : ""
          out << "  ##{row[:number]}  #{row[:title]}#{repo}#{tail}"
          out << "     #{row[:url]}"
        end
        out << "  …and #{rows.size - MAX_ROWS} more" if rows.size > MAX_ROWS
        out << ""
      end

      out << "All clear: #{empty.join(', ')}" unless empty.empty?
      out << ""
      out << "— Kamandar v#{VERSION}"
      out.join("\n") + "\n"
    end

    # A complete RFC-822 message (headers + CRLF body) ready for Net::SMTP.
    # `Date:` comes from generated_at so the whole thing stays deterministic.
    def message(buckets, config, generated_at:, from:, to:)
      body = text_body(buckets, config, generated_at: generated_at)
      [
        "From: #{from}",
        "To: #{to}",
        "Subject: #{subject(buckets, config)}",
        "Date: #{generated_at.rfc2822}",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8",
        "Content-Transfer-Encoding: 8bit",
        "", ""
      ].join("\r\n") + body.gsub(/\r?\n/, "\r\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Mailer — the only outbound SMTP layer (Net::SMTP). Sends a prebuilt message;
  # knows nothing about buckets. STARTTLS on by default (submission port 587).
  # ---------------------------------------------------------------------------
  module Mailer
    class Error < StandardError; end

    # Failures we translate into a clean one-line Error instead of a stack trace.
    SEND_ERRORS = [
      Net::SMTPError, Net::OpenTimeout, Net::ReadTimeout, SocketError,
      OpenSSL::SSL::SSLError, SystemCallError
    ].freeze

    module_function

    # Deliver a raw RFC-822 message via SMTP. `mail` is config[:mail]. Plain auth
    # only when a user is set. Raises Mailer::Error on any connection/SMTP failure.
    def deliver(message, mail)
      raise Error, "SMTP host not configured (set SMTP_HOST)" if mail[:host].to_s.empty?

      smtp = Net::SMTP.new(mail[:host], mail[:port])
      smtp.enable_starttls_auto if mail[:tls]
      authtype = mail[:user].to_s.empty? ? nil : :plain
      smtp.start("localhost", mail[:user], mail[:pass], authtype) do |s|
        s.send_message(message, mail[:from], mail[:to])
      end
    rescue *SEND_ERRORS => e
      raise Error, "SMTP delivery failed (#{e.class}: #{e.message})"
    end
  end

  # ---------------------------------------------------------------------------
  # Server — a minimal stdlib HTTP/1.1 server (TCPServer) for the live web UI.
  # Single-user, localhost-only. Pure helpers (request parsing, response
  # framing, scope resolution) are unit-tested; the accept loop lives in CLI.
  # ---------------------------------------------------------------------------
  module Server
    module_function

    HOST = "127.0.0.1" # localhost only — never expose the queue on the network
    DEFAULT_PORT = 4567

    STATUS_TEXT = {
      200 => "OK", 204 => "No Content", 404 => "Not Found",
      500 => "Internal Server Error"
    }.freeze

    # Parse a raw HTTP request (we only need the request line). Returns
    # { method:, path:, query: {String=>String} } or nil if unparseable.
    def parse_request(raw)
      line = raw.to_s.lines.first.to_s.strip
      method, target, = line.split(" ", 3)
      return nil if method.nil? || target.nil?

      path, qs = target.split("?", 2)
      query = qs ? CGI.parse(qs).transform_values(&:first) : {}
      { method: method, path: path, query: query }
    end

    # Frame a full HTTP/1.1 response. Connection: close keeps the loop simple.
    def http_response(status, body, type: "text/html; charset=utf-8")
      bytes = body.to_s.b
      reason = STATUS_TEXT[status] || "OK"
      [
        "HTTP/1.1 #{status} #{reason}",
        "Content-Type: #{type}",
        "Content-Length: #{bytes.bytesize}",
        "Cache-Control: no-store",
        "Connection: close",
        "", ""
      ].join("\r\n").b + bytes
    end

    # Turn the form query into a scope hash (via the pure Engine parser) plus the
    # raw inputs the page needs to re-render the form. project_org seeds bare
    # `org` from PROJECT_URL, matching the CLI picker.
    def resolve_scope(query, project_org:)
      mode = query["mode"].to_s.strip
      mode = "global" if mode.empty?
      name = query["name"].to_s.strip
      raw =
        case mode
        when "org"  then name.empty? ? "org" : "org:#{name}"
        when "repo" then "repo:#{name}"
        when "project" then "project"
        else "global"
        end
      scope = Engine.parse_scope(raw, project_org: project_org)
      st    = query["stale"].to_s.strip
      { scope: scope, mode: mode, name: name,
        project_url: query["project_url"].to_s.strip,
        poll: query["poll"].to_i,
        stale: st.empty? ? nil : st.to_i } # nil = fall back to configured STALE_DAYS
    end
  end

  # ---------------------------------------------------------------------------
  # GitHub — the only network layer.
  # ---------------------------------------------------------------------------
  module GitHub
    # Raised for any GitHub-side failure (network, HTTP, GraphQL). CLI catches
    # this and prints a clean one-line message instead of a raw stack trace.
    class Error < StandardError; end

    OPEN_TIMEOUT = 8  # seconds to establish the TCP/TLS connection
    READ_TIMEOUT = 20 # seconds to wait for the response
    MAX_RETRIES  = 2  # extra attempts after the first, on transient blips
    RETRY_BACKOFF = 1.0 # base seconds; waits backoff*1, backoff*2, ...

    # Connection-level failures we want to surface as a friendly Error rather
    # than a raw stack trace. Also the set we retry on — a flapping route often
    # recovers within seconds.
    NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError,
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH
    ].freeze

    module_function

    # Run `block`, retrying up to `max` times on a transient network error with
    # linear backoff. Re-raises the last error once attempts are exhausted.
    # `backoff: 0` disables sleeping (used by tests).
    def with_retries(max: MAX_RETRIES, backoff: RETRY_BACKOFF)
      attempt = 0
      begin
        yield
      rescue *NETWORK_ERRORS
        attempt += 1
        raise if attempt > max
        sleep(backoff * attempt) if backoff.positive?
        retry
      end
    end

    def graphql(query, variables, token)
      with_retries { request_graphql(query, variables, token) }
    rescue *NETWORK_ERRORS => e
      raise Error, "could not reach GitHub (#{e.class}: #{e.message}) after #{MAX_RETRIES + 1} attempts. Check your connection and try again."
    end

    # One GraphQL round-trip. Raises raw NETWORK_ERRORS (so with_retries can act)
    # and a GitHub::Error for GraphQL/HTTP-level failures (not retried).
    def request_graphql(query, variables, token)
      uri = URI(GRAPHQL_ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{token}"
      req["Content-Type"] = "application/json"
      req["User-Agent"] = "kamandar/#{VERSION}"
      req.body = JSON.generate(query: query, variables: variables)

      res = http.request(req)
      body = JSON.parse(res.body)
      if body["errors"] && !body["errors"].empty?
        raise Error, "GraphQL error: #{body['errors'].map { |e| e['message'] }.join('; ')}"
      end
      unless res.is_a?(Net::HTTPSuccess)
        raise Error, "HTTP #{res.code}: #{res.body}"
      end
      body["data"]
    end

    # Verify a token and return the authenticated login (nil if absent).
    def viewer_login(token)
      data = graphql(Engine.build_viewer_query, {}, token)
      data.dig("viewer", "login")
    end

    # Run both PR searches in one call. Returns [owed_nodes, mine_nodes].
    # `qualifier` (optional) scopes both searches (e.g. "org:Foo", "repo:o/r").
    def fetch_prs(login, token, qualifier: "")
      data = graphql(
        Engine.build_pr_query,
        { "owed" => Engine.reviews_owed_query(login, qualifier: qualifier),
          "mine" => Engine.my_prs_query(login, qualifier: qualifier) },
        token
      )
      owed = (data.dig("owed", "nodes") || []).reject(&:empty?)
      mine = (data.dig("mine", "nodes") || []).reject(&:empty?)
      [owed, mine]
    end

    # Open issues assigned to you (with their linked PRs), optionally scoped.
    def fetch_assigned_issues(login, token, qualifier: "")
      data = graphql(
        Engine.build_assigned_issues_query,
        { "q" => Engine.assigned_issues_query(login, qualifier: qualifier) },
        token
      )
      (data.dig("assigned", "nodes") || []).reject(&:empty?)
    end

    # Paginated board fetch. Returns [items, iterations_config].
    def fetch_board(org, num, token, iteration_field: "Iteration")
      items = []
      iterations = nil
      cursor = nil
      loop do
        data = graphql(
          Engine.build_board_query,
          { "org" => org, "num" => num, "cursor" => cursor },
          token
        )
        project = data.dig("organization", "projectV2")
        return [[], nil] if project.nil?

        if iterations.nil?
          field = (project.dig("fields", "nodes") || []).find do |f|
            f && f["name"] == iteration_field && f["configuration"]
          end
          if field
            cfg = field["configuration"]
            iterations = (cfg["iterations"] || []) + (cfg["completedIterations"] || [])
          end
        end

        page = project["items"]
        items.concat(page["nodes"] || [])
        info = page["pageInfo"] || {}
        break unless info["hasNextPage"]
        cursor = info["endCursor"]
      end
      [items, iterations]
    end
  end

  # ---------------------------------------------------------------------------
  # Config — resolve env + CLI flags (flags take precedence).
  # ---------------------------------------------------------------------------
  module Config
    module_function

    def from(env:, argv:)
      flags = parse_flags(argv)
      env = with_config_file(env) # config file is the base layer; real ENV wins over it

      not_started = (env["NOT_STARTED_STATUSES"] || "Todo,Backlog,No Status,Ready")
                    .split(",").map(&:strip).reject(&:empty?)

      review_statuses = (env["REVIEW_STATUSES"] || "In Review,Review,Needs Review")
                        .split(",").map(&:strip).reject(&:empty?)

      qa_statuses = (env["QA_STATUSES"] || "Ready for QA,QA,In QA")
                    .split(",").map(&:strip).reject(&:empty?)

      blocked_statuses = (env["BLOCKED_STATUSES"] || "Blocked,On Hold,Waiting")
                         .split(",").map(&:strip).reject(&:empty?)

      project_url = env["PROJECT_URL"]
      project_org = (Engine.parse_project_url(project_url) || {})[:org]
      scope_raw = flags[:scope] || env["SCOPE"] || "global"
      scope_given = !!(flags[:scope] || (env["SCOPE"] && !env["SCOPE"].strip.empty?))

      {
        token: env["GITHUB_TOKEN"],
        login: env["GH_LOGIN"],
        project_url: project_url,
        scope: Engine.parse_scope(scope_raw, project_org: project_org),
        scope_given: scope_given,
        not_started: not_started,
        review_statuses: review_statuses,
        qa_statuses: qa_statuses,
        blocked_statuses: blocked_statuses,
        iteration_filter: (env["ITERATION_FILTER"] || "off"),
        iteration_field: (env["ITERATION_FIELD"] || "Iteration"),
        stale_days: (env["STALE_DAYS"] || "2").to_i,
        ignore_older_than: (flags[:ignore_older_than] || env["IGNORE_OLDER_THAN"] || "0").to_i,
        day_mode: (env["DAY_MODE"] || "business"),
        output_env: (env["OUTPUT"] || "terminal"),
        browser_flag: flags[:browser],
        theme: (flags[:theme] || env["THEME"] || "").to_s.strip.downcase,
        dashboard: flags[:dashboard] || false,
        serve: flags[:serve] || false,
        no_open: flags[:no_open] || false,
        menubar: flags[:menubar] || false,
        demo: flags[:demo] || false,
        email: flags[:email] || false,
        mail: {
          host: env["SMTP_HOST"],
          port: (env["SMTP_PORT"] || "587").to_i,
          user: env["SMTP_USER"],
          pass: env["SMTP_PASS"],
          # STARTTLS on unless explicitly disabled (common falsey spellings).
          tls: !%w[0 false no off].include?((env["SMTP_TLS"] || "true").strip.downcase),
          from: (env["MAIL_FROM"] || env["SMTP_USER"]),
          to: (env["MAIL_TO"] || env["SMTP_USER"])
        },
        tunnel: flags[:tunnel] || false,
        tunnel_name: flags[:tunnel_name] || env["KAMANDAR_TUNNEL"] || "kamandar",
        port: flags[:port] || (env["PORT"] || Server::DEFAULT_PORT).to_i,
        project_org: project_org,
        list_statuses: flags[:statuses] || false,
        init: flags[:init] || false,
        config_path: config_path(env),
        watch_seconds: flags.key?(:watch) ? flags[:watch] : (env["WATCH_SECONDS"] || "0").to_i
      }
    end

    # ---- config file (KEY=VALUE) -------------------------------------------
    # Lets the user persist GITHUB_TOKEN/GH_LOGIN/etc once instead of exporting
    # them every shell. Precedence: CLI flags > real ENV > config file. The file
    # is a flat KEY=VALUE list (same names as the ENV vars), parsed by hand —
    # stdlib only, no dotenv gem.

    # Where the config file lives. KAMANDAR_CONFIG overrides everything (handy
    # for tests + alternate profiles); otherwise XDG_CONFIG_HOME, then ~/.config.
    def config_path(env)
      explicit = env["KAMANDAR_CONFIG"]
      return explicit if explicit && !explicit.empty?

      base = env["XDG_CONFIG_HOME"]
      base = File.join(Dir.home, ".config") if base.nil? || base.empty?
      File.join(base, "kamandar", "config")
    end

    # Merge the on-disk config under the live ENV (ENV present & non-empty wins).
    # Returns a plain Hash so downstream `env["KEY"]` lookups behave the same.
    def with_config_file(env)
      path = config_path(env)
      return env unless path && File.file?(path)

      present = {}
      env.each { |k, v| present[k] = v unless v.nil? || v.to_s.empty? }
      load_file(path).merge(present)
    end

    # Parse a KEY=VALUE file: blank lines and `#` comments skipped, surrounding
    # quotes stripped, `export ` prefix tolerated. Never raises on a bad file.
    def load_file(path)
      out = {}
      File.foreach(path) do |raw|
        line = raw.strip
        next if line.empty? || line.start_with?("#")

        line = line.sub(/\Aexport\s+/, "")
        key, sep, val = line.partition("=")
        next if sep.empty?

        key = key.strip
        next if key.empty?

        val = val.strip
        if val.length >= 2 &&
           ((val.start_with?('"') && val.end_with?('"')) ||
            (val.start_with?("'") && val.end_with?("'")))
          val = val[1..-2]
        end
        out[key] = val
      end
      out
    rescue SystemCallError
      {}
    end

    # Serialize a {KEY => value} hash back to KEY=VALUE lines (values quoted when
    # they contain spaces or `#`). Pure — the CLI wizard does the actual write.
    def render_file(values)
      values.reject { |_k, v| v.nil? || v.to_s.empty? }.map do |k, v|
        v = v.to_s
        v = %("#{v}") if v =~ /[\s#"']/
        "#{k}=#{v}"
      end.join("\n") + "\n"
    end

    def parse_flags(argv)
      flags = {}
      i = 0
      while i < argv.length
        case argv[i]
        when "--browser", "-b"
          flags[:browser] = true
        when "--watch"
          flags[:watch] = argv[i + 1].to_i
          i += 1
        when /\A--watch=(\d+)\z/
          flags[:watch] = Regexp.last_match(1).to_i
        when "--scope"
          flags[:scope] = argv[i + 1]
          i += 1
        when /\A--scope=(.+)\z/m
          flags[:scope] = Regexp.last_match(1)
        when "--ignore-older-than"
          flags[:ignore_older_than] = argv[i + 1].to_i
          i += 1
        when /\A--ignore-older-than=(\d+)\z/
          flags[:ignore_older_than] = Regexp.last_match(1).to_i
        when "--statuses"
          flags[:statuses] = true
        when "--init"
          flags[:init] = true
        when "--dashboard"
          flags[:dashboard] = true
        when "--serve"
          flags[:serve] = true
        when "--no-open"
          flags[:no_open] = true
        when "--menubar"
          flags[:menubar] = true
        when "--email"
          flags[:email] = true
        when "--demo"
          flags[:demo] = true
        when "--tunnel"
          flags[:tunnel] = true
          nxt = argv[i + 1]
          if nxt && !nxt.start_with?("-")
            flags[:tunnel_name] = nxt
            i += 1
          end
        when /\A--tunnel=(.+)\z/
          flags[:tunnel] = true
          flags[:tunnel_name] = Regexp.last_match(1)
        when "--port"
          flags[:port] = argv[i + 1].to_i
          i += 1
        when /\A--port=(\d+)\z/
          flags[:port] = Regexp.last_match(1).to_i
        when "--theme"
          flags[:theme] = argv[i + 1]
          i += 1
        when /\A--theme=(.+)\z/
          flags[:theme] = Regexp.last_match(1)
        end
        i += 1
      end
      flags
    end
  end

  # ---------------------------------------------------------------------------
  # CLI — wires it all together (the only place with side effects + ENV).
  # ---------------------------------------------------------------------------
  module CLI
    module_function

    SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    # Static assets shipped alongside the code (sibling of lib/). `__dir__` is
    # symlink-resolved, so this still points at the repo even when the CLI is run
    # through the ~/.local/bin/kamandar symlink that install.sh creates.
    ASSET_DIR = File.expand_path("../assets", __dir__)
    FAVICON_PATH = File.join(ASSET_DIR, "favicon.ico")

    def run(env: ENV, argv: ARGV)
      config = Config.from(env: env, argv: argv)
      return run_init(config) if config[:init] # first-run setup; no token needed yet

      validate!(config)

      surface = Surface.resolve_surface(
        output_env: config[:output_env],
        browser_flag: config[:browser_flag],
        menubar_flag: config[:menubar]
      )

      # Terminal + interactive + no scope given: let the user pick one (and a
      # project URL if they choose project and none is set). Browser, cron, and
      # pipes are skipped so nothing ever blocks on stdin.
      return print_statuses(config) if config[:list_statuses]

      # Daily summary email: one fetch, build the digest, send via SMTP, exit.
      # Runs headless (launchd at 22:00) — no stdin picker, no browser.
      return run_email(config) if config[:email]

      # The live web UI picks its own scope in-page, so skip the stdin picker.
      # --tunnel implies --serve (there must be a local server to expose).
      return run_server(config, open: !config[:no_open]) if config[:serve] || config[:tunnel]

      # Menu-bar plugin: one fetch, emit the SwiftBar/xbar document, exit. No
      # stdin picker (it runs headless under SwiftBar); a fetch error becomes an
      # error plugin so the bar flags it instead of going blank.
      if surface == :menubar
        begin
          buckets = fetch_and_classify(config)
          output  = MenubarSurface.render(buckets, config: config,
                                                   generated_at: Time.now, port: config[:port])
        rescue GitHub::Error => e
          output = MenubarSurface.error(e.message)
        end
        return MenubarSurface.emit(output)
      end

      if surface == :terminal && !config[:scope_given] && $stdin.tty?
        picked = prompt_scope(config)
        config = config.merge(scope: picked[:scope], project_url: picked[:project_url])
      end

      if config[:dashboard] && $stdout.tty? && $stdin.tty?
        return run_dashboard(config)
      elsif config[:dashboard]
        $stderr.puts "kamandar: --dashboard needs an interactive terminal; showing plain output."
      end

      if surface == :browser && config[:watch_seconds].to_i > 0
        run_watch(config)
      elsif surface == :browser
        buckets = with_spinner("Fetching your GitHub queue…") { fetch_and_classify(config) }
        html = BrowserSurface.render(buckets, config: config,
                                              generated_at: Time.now,
                                              watch_seconds: 0)
        path = BrowserSurface.emit(html)
        $stderr.puts "kamandar: wrote #{path}"
        warn_no_project(config)
        warn_if_empty(config, buckets)
      else
        buckets = with_spinner("Fetching your GitHub queue…") { fetch_and_classify(config) }
        theme = (config[:theme] == "matrix" && $stdout.tty?) ? :matrix : :default
        output = TerminalSurface.render(buckets, config: config, generated_at: Time.now,
                                                 color: $stdout.tty?, theme: theme)
        TerminalSurface.emit(output)
        warn_no_project(config)
        warn_if_empty(config, buckets)
      end
    rescue GitHub::Error => e
      $stderr.puts "kamandar: #{e.message}"
      exit 1
    end

    # Fetch the queue, build the plain-text digest, and email it. With --demo
    # (no SMTP creds) it prints the message to stdout as a preview instead of
    # sending. A GitHub::Error bubbles to run's rescue; SMTP errors are handled
    # here. Exits non-zero on misconfiguration so cron/launchd surfaces it.
    def run_email(config)
      mail    = config[:mail]
      buckets = with_spinner("Building your daily summary…") { fetch_and_classify(config) }
      msg     = MailSurface.message(buckets, config, generated_at: Time.now,
                                                     from: mail[:from], to: mail[:to])

      if config[:demo]
        puts msg # preview: no SMTP round-trip, no creds required
        return
      end

      if mail[:host].to_s.empty? || mail[:to].to_s.empty?
        $stderr.puts "kamandar: --email needs SMTP_HOST and a recipient " \
                     "(MAIL_TO, or SMTP_USER as the default). See the README."
        exit 1
      end

      Mailer.deliver(msg, mail)
      $stderr.puts "kamandar: daily summary sent to #{mail[:to]}."
    rescue Mailer::Error => e
      $stderr.puts "kamandar: #{e.message}"
      exit 1
    end

    def run_watch(config)
      first = true
      loop do
        begin
          buckets = fetch_and_classify(config)
          html = BrowserSurface.render(buckets, config: config,
                                                generated_at: Time.now,
                                                watch_seconds: config[:watch_seconds])
          path = BrowserSurface.emit(html, open: first)
          $stderr.puts "kamandar: refreshed #{path} (#{Time.now.strftime('%H:%M:%S')})"
          first = false
        rescue GitHub::Error => e
          # A transient blip shouldn't kill a long-running watch; retry next tick.
          $stderr.puts "kamandar: #{e.message} — retrying in #{config[:watch_seconds]}s"
        end
        sleep config[:watch_seconds]
      end
    rescue Interrupt
      $stderr.puts "\nkamandar: watch stopped."
    end

    # Full-screen Matrix TUI: a digital-rain splash, then the dashboard with a
    # key loop (r = refresh, q/Ctrl-C = quit). Always restores the screen.
    def run_dashboard(config, out: $stdout, input: $stdin)
      out.print DashboardSurface::ENTER_ALT
      rows, cols = terminal_size(out)

      rain_splash(out, rows: rows, cols: cols)

      buckets = fetch_and_classify(config)
      loop do
        rows, cols = terminal_size(out)
        out.print DashboardSurface.render(buckets, config: config,
                                                   generated_at: Time.now,
                                                   rows: rows, cols: cols)
        out.flush
        key = read_key(input)
        break if key.nil? || %w[q Q].include?(key) || key == "" # q / Ctrl-C
        buckets = fetch_and_classify(config) if %w[r R].include?(key)
      end
    rescue GitHub::Error => e
      out.print DashboardSurface::LEAVE_ALT
      $stderr.puts "kamandar: #{e.message}"
      exit 1
    ensure
      out.print DashboardSurface::LEAVE_ALT
    end

    # Current terminal size, clamped to a usable minimum; falls back to a sane
    # 24x80 if the stream has no winsize (e.g. not a real TTY).
    def terminal_size(out)
      r, c = out.winsize
      [[r, 6].max, [c, 24].max]
    rescue StandardError
      [24, 80]
    end

    # Read a single keypress (raw, unbuffered); nil on EOF or a non-TTY stream,
    # which the dashboard loop treats as "quit".
    def read_key(input)
      input.getch
    rescue StandardError
      nil
    end

    # Play the digital-rain intro: a fixed number of frames, advancing the heads
    # one row per frame. Kept separate from run_dashboard so the loop reads clean.
    def rain_splash(out, rows:, cols:, frames: 22, delay: 0.05)
      heads = DashboardSurface.init_heads(cols, rows)
      frames.times do
        out.print DashboardSurface.rain_frame(cols: cols, rows: rows, heads: heads)
        out.flush
        sleep delay
        heads = DashboardSurface.step_heads(heads, rows)
      end
    end

    # Live web UI: a localhost-only HTTP server that re-fetches per request and
    # serves the colorful page with in-page scope controls. One request at a
    # time (single-user); a fetch failure renders an error page, not a crash.
    # SECURITY: binds 127.0.0.1 by default, and the token never reaches any
    # response. KAMANDAR_HOST=0.0.0.0 opts into binding all interfaces — only
    # for running behind a trusted reverse proxy (e.g. in a container); never
    # expose the queue directly on an untrusted network.
    def run_server(config, host: (ENV["KAMANDAR_HOST"] || Server::HOST), open: true)
      tunnel_pid = nil
      # launchd stops the service with SIGTERM; Ruby's default TERM exits without
      # running `ensure`, which would orphan the cloudflared child. Route TERM
      # through the same Interrupt path as Ctrl-C so stop_tunnel always reaps it.
      trap("TERM") { raise Interrupt }
      port   = config[:port].to_i
      port   = Server::DEFAULT_PORT if port <= 0
      server = TCPServer.new(host, port) # binds 127.0.0.1 — raises EADDRINUSE before any tunnel starts
      url    = "http://#{host}:#{port}"
      tunnel_pid = start_tunnel(config, port: port)
      $stderr.puts "kamandar: serving your queue at #{url}  (Ctrl-C to stop)"
      open_url(url) if open

      loop do
        client = server.accept
        begin
          handle_request(client, config)
        rescue StandardError => e
          $stderr.puts "kamandar: request error (#{e.class}: #{e.message})"
        ensure
          client.close
        end
      end
    rescue Errno::EADDRINUSE
      $stderr.puts "kamandar: port #{config[:port]} is already in use — try --port N."
      exit 1
    rescue Interrupt
      $stderr.puts "\nkamandar: server stopped."
    ensure
      stop_tunnel(tunnel_pid)
      server&.close
    end

    # Optionally bring the Cloudflare Tunnel up as a child process, so a single
    # `kamandar --serve --tunnel` both serves locally and exposes the public
    # hostname. cloudflared is an external binary the user installs (no Ruby
    # dependency); the server still binds 127.0.0.1 and cloudflared dials it.
    # Returns the child pid, or nil when disabled / cloudflared isn't installed.
    def start_tunnel(config, port:, out: $stderr)
      return nil unless config[:tunnel]

      name = config[:tunnel_name]
      unless tunnel_available?
        out.puts "kamandar: --tunnel needs `cloudflared` on your PATH — serving locally only."
        return nil
      end

      out.puts "kamandar: starting Cloudflare Tunnel '#{name}' → 127.0.0.1:#{port}…"
      pid = Process.spawn("cloudflared", "tunnel", "run", name)
      out.puts "kamandar: tunnel '#{name}' up (pid #{pid}); public hostname is the one in your cloudflared config."
      pid
    rescue StandardError => e
      out.puts "kamandar: couldn't start tunnel (#{e.message}) — serving locally only."
      nil
    end

    def tunnel_available?
      system("command -v cloudflared > /dev/null 2>&1")
    end

    # TERM the tunnel child and reap it so Ctrl-C tears down both halves cleanly.
    def stop_tunnel(pid, out: $stderr)
      return unless pid

      out.puts "kamandar: stopping tunnel (pid #{pid})…"
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      # already exited — nothing to reap
    end

    # Open a full URL (http) in the default browser — unlike BrowserSurface's
    # opener, which assumes a local file path.
    def open_url(url, host_os: RbConfig::CONFIG["host_os"])
      system(*Surface.browser_open_command(host_os, url))
    rescue StandardError => e
      $stderr.puts "kamandar: open #{url} manually (#{e.message})"
    end

    # Read one request off the socket, route it, and write the response.
    def handle_request(client, config)
      raw = read_http_request(client)
      req = Server.parse_request(raw)
      return client.write(Server.http_response(400, "bad request")) if req.nil?

      if req[:method] != "GET"
        return client.write(Server.http_response(404, "not found"))
      end

      case req[:path]
      when "/favicon.ico"
        client.write(serve_favicon)
      when "/"
        client.write(serve_queue(req[:query], config))
      else
        client.write(Server.http_response(404, "not found"))
      end
    end

    # Build the queue page for a request: resolve scope from the query, fetch,
    # classify, render. On a GitHub error, serve the error page (still HTTP 200
    # chrome) so the long-running server survives a transient blip.
    def serve_queue(query, config)
      sel = Server.resolve_scope(query, project_org: config[:project_org])
      live = config.merge(scope: sel[:scope],
                          project_url: sel[:project_url].empty? ? config[:project_url] : sel[:project_url])
      live[:stale_days] = sel[:stale] if sel[:stale] && sel[:stale] > 0 # per-request override
      buckets = fetch_and_classify(live)
      html = ServerSurface.page(buckets, config: live, generated_at: Time.now,
                                         mode: sel[:mode], name: sel[:name],
                                         project_url: sel[:project_url], poll: sel[:poll],
                                         stale: sel[:stale])
      Server.http_response(200, html)
    rescue GitHub::Error => e
      Server.http_response(200, ServerSurface.error_page(e.message, config: config))
    end

    # Serve the browser-tab favicon from assets/. SECURITY: a static image only —
    # no token, no user data ever touches this path. Falls back to 204 if the
    # file is missing so a stripped checkout still serves pages.
    def serve_favicon
      bytes = File.binread(FAVICON_PATH)
      Server.http_response(200, bytes, type: "image/x-icon")
    rescue SystemCallError
      Server.http_response(204, "")
    end

    # Read the request head (up to the blank line). We don't consume a body —
    # the UI only issues GETs — so headers are enough to route on.
    def read_http_request(client)
      buf = +""
      while (line = client.gets)
        buf << line
        break if line == "\r\n" || line == "\n" || buf.bytesize > 16_384
      end
      buf
    end

    # Diagnostic for --statuses: fetch the board and print each issue assigned
    # to you with its exact Status, plus the distinct set, so NOT_STARTED_STATUSES
    # / REVIEW_STATUSES can be configured to match the board's real labels.
    def print_statuses(config, input: $stdin, out: $stderr)
      url = config[:project_url].to_s
      if Engine.parse_project_url(url).nil? && input.tty?
        out.print "Project URL (e.g. https://github.com/orgs/ORG/projects/N): "
        url = (input.gets || "").strip
      end
      parsed = Engine.parse_project_url(url)
      unless parsed
        out.puts "kamandar: --statuses needs a valid org project URL."
        return
      end

      items, = with_spinner("Reading the board…") do
        GitHub.fetch_board(parsed[:org], parsed[:num], config[:token],
                           iteration_field: config[:iteration_field])
      end
      rows = Engine.assigned_status_breakdown(items, login: config[:login])

      if rows.empty?
        $stdout.puts "No issues on this board are assigned to @#{config[:login]}."
        return
      end

      $stdout.puts "Board issues assigned to @#{config[:login]} (status in brackets):"
      rows.sort_by { |r| r[:status].to_s }.each do |r|
        $stdout.puts "  [#{r[:status] || 'no status'}] ##{r[:number]} #{r[:title]}"
      end
      distinct = rows.map { |r| r[:status] }.compact.uniq.sort
      $stdout.puts ""
      $stdout.puts "Distinct statuses: #{distinct.join(', ')}"
      $stdout.puts "Set NOT_STARTED_STATUSES / REVIEW_STATUSES to the labels you want."
    rescue GitHub::Error => e
      $stderr.puts "kamandar: #{e.message}"
      exit 1
    end

    # Interactive scope picker. The user SELECTS a mode by number (they never
    # type the mode itself) and only enters a name for org/repo, or a board URL
    # for project. Prompts go to stderr so a piped report on stdout stays clean.
    # Anything blank/invalid resolves to global. Returns
    # { scope:, project_url: } — project_url may be the value the user just
    # entered (for project scope) or the one already in config.
    def prompt_scope(config, input: $stdin, out: $stderr)
      tty   = out.respond_to?(:tty?) && out.tty?
      paint = ->(c, s) { tty ? "\e[#{c}m#{s}\e[0m" : s }
      title = ->(s) { paint.call("1", s) }            # bold
      key   = ->(s) { paint.call("1;38;5;33", s) }    # bold blue digit
      dim   = ->(s) { paint.call("2", s) }            # hints / examples

      out.puts
      out.puts "#{title.call("\u{1F3F9} Kamandar")} — which GitHub work should I show?"
      out.puts dim.call("Pick how wide to look. Press Enter to keep the default.")
      out.puts
      # Each row: digit · mode (padded) · what it covers · example/hint.
      out.puts "  #{key.call('1')}  #{'global'.ljust(9)}Every repo your account touches      #{dim.call('· default')}"
      out.puts "  #{key.call('2')}  #{'org'.ljust(9)}A single organization                #{dim.call('· e.g. Recognize')}"
      out.puts "  #{key.call('3')}  #{'repo'.ljust(9)}A single repository                  #{dim.call('· e.g. acme/api')}"
      out.puts "  #{key.call('4')}  #{'project'.ljust(9)}A GitHub project board               #{dim.call('· paste its URL')}"
      out.puts

      # Re-prompt until a valid choice; blank/Enter (or EOF) means global.
      choice = nil
      loop do
        out.print "#{title.call('Choose 1–4')} #{dim.call('(Enter = global)')}: "
        line = input.gets
        choice = line.nil? ? "" : line.strip
        break if choice.empty? || %w[1 2 3 4].include?(choice)
        out.puts dim.call("Please type 1, 2, 3, or 4 — or press Enter for global.")
      end

      project_url = config[:project_url]
      scope =
        case choice
        when "2"
          out.print "#{title.call('Organization')} #{dim.call('(e.g. Recognize)')}: "
          name = (input.gets || "").strip
          name.empty? ? { mode: "global" } : { mode: "org", org: name }
        when "3"
          # Re-prompt until "owner/name"; blank/Enter (or EOF) cancels to global.
          loop do
            out.print "#{title.call('Repository')} #{dim.call('(owner/name, e.g. acme/api)')}: "
            line = input.gets
            break({ mode: "global" }) if line.nil? # EOF
            name = line.strip
            break({ mode: "global" }) if name.empty? # cancel
            break({ mode: "repo", repo: name }) if Engine.valid_repo?(name)
            out.puts dim.call("That isn't owner/name (e.g. acme/api). Try again, or press Enter for global.")
          end
        when "4"
          # Re-prompt on a malformed URL; blank/Enter (or EOF) cancels to global.
          entered = config[:project_url].to_s.strip
          loop do
            if entered.empty?
              out.print "#{title.call('Project board URL')} #{dim.call('(github.com/orgs/ORG/projects/N)')}: "
              line = input.gets
              break({ mode: "global" }) if line.nil? # EOF
              entered = line.strip
              break({ mode: "global" }) if entered.empty? # cancel
            end
            if Engine.parse_project_url(entered)
              project_url = entered
              break({ mode: "project" })
            end
            out.puts dim.call("That isn't a project board URL (expected …/orgs/ORG/projects/N). Try again, or press Enter for global.")
            entered = "" # force a re-prompt
          end
        else
          { mode: "global" }
        end

      { scope: scope, project_url: project_url }
    end

    # Run `block` while animating a spinner on stderr. Only animates on an
    # interactive terminal — when stderr is piped/redirected (cron, `| mail`)
    # it just yields, keeping captured output clean. The spinner never touches
    # stdout, so the rendered report stays pipe-safe. Exceptions raised inside
    # the block propagate after the line is cleared.
    def with_spinner(label)
      return yield unless $stderr.tty?

      result = nil
      error = nil
      worker = Thread.new do
        result = yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        error = e
      end

      i = 0
      while worker.alive?
        $stderr.print "\r#{SPINNER_FRAMES[i % SPINNER_FRAMES.length]} #{label}"
        $stderr.flush
        sleep 0.08
        i += 1
      end
      worker.join
      $stderr.print "\r\e[2K" # clear the spinner line
      $stderr.flush

      raise error if error
      result
    end

    # Fetch everything, then classify once. The bucket set depends on scope:
    # project is board-driven, every other scope is issue+PR driven.
    def fetch_and_classify(config)
      # --demo skips the network entirely and serves fabricated buckets.
      return Demo.buckets(Engine.scope_mode(config)) if config[:demo]

      scope = config[:scope] || { mode: "global" }
      qualifier = Engine.search_qualifier(scope)

      # owed (reviews you owe) and mine (gone quiet) are needed in both modes.
      owed, mine = GitHub.fetch_prs(config[:login], config[:token], qualifier: qualifier)

      if scope[:mode] == "project"
        parsed = config[:project_url] ? Engine.parse_project_url(config[:project_url]) : nil
        project_items = []
        iterations = nil
        if parsed
          project_items, iterations = GitHub.fetch_board(
            parsed[:org], parsed[:num], config[:token],
            iteration_field: config[:iteration_field]
          )
          # Limit PR buckets to PRs that belong to this project — board items or
          # PRs that close a board issue ("Closes #N").
          pr_urls = Engine.project_pr_urls(project_items)
          issue_urls = Engine.project_issue_urls(project_items)
          owed = Engine.filter_prs_on_project(owed, pr_urls: pr_urls, issue_urls: issue_urls)
          mine = Engine.filter_prs_on_project(mine, pr_urls: pr_urls, issue_urls: issue_urls)
        else
          $stderr.puts "kamandar: SCOPE=project needs PROJECT_URL — board buckets will be empty."
        end

        Engine.classify(owed_prs: owed, my_prs: mine, project_items: project_items,
                        iterations: iterations, config: config, today: Time.now)
      else
        assigned = GitHub.fetch_assigned_issues(config[:login], config[:token], qualifier: qualifier)
        Engine.classify(owed_prs: owed, my_prs: mine, assigned_issues: assigned,
                        config: config, today: Time.now)
      end
    end

    def validate!(config)
      return if config[:demo] # demo mode fabricates data; no token/login needed

      missing = []
      missing << "GITHUB_TOKEN" unless config[:token] && !config[:token].empty?
      missing << "GH_LOGIN" unless config[:login] && !config[:login].empty?
      return if missing.empty?
      $stderr.puts "kamandar: missing required configuration: #{missing.join(', ')}"
      $stderr.puts "Run `kamandar --init` to set them up once, or export them in your shell."
      exit 1
    end

    # First-run wizard: prompt for token + login (+ optional project URL), verify
    # the token against GitHub, then write a 0600 config file so the user never
    # has to export env vars again. Token is read with no echo via io/console.
    def run_init(config, input: $stdin, out: $stdout)
      require "io/console"
      path = config[:config_path]
      out.puts "Kamandar setup — writing #{path}"
      out.puts "Leave a field blank to keep what's already set.\n\n"

      token = prompt_secret(out, input, "GitHub token (classic PAT: repo, read:org, read:project): ")
      token = config[:token] if token.empty?
      login = prompt_line(out, input, "GitHub login (your username)", config[:login])
      project = prompt_line(out, input, "Project URL (optional, enables board buckets)", config[:project_url])
      stale = prompt_line(out, input, "Stale threshold — days quiet before a PR is flagged", config[:stale_days].to_s)

      # Optional daily-summary email. Blank SMTP host skips it entirely.
      m = config[:mail] || {}
      out.puts "\nDaily summary email (optional — leave SMTP host blank to skip):"
      smtp_host = prompt_line(out, input, "  SMTP host (e.g. smtp.gmail.com)", m[:host])
      smtp_port = smtp_user = smtp_pass = mail_to = nil
      unless smtp_host.to_s.empty?
        smtp_port = prompt_line(out, input, "  SMTP port", (m[:port] || 587).to_s)
        smtp_user = prompt_line(out, input, "  SMTP username", m[:user])
        smtp_pass = prompt_secret(out, input, "  SMTP password (blank keeps current): ")
        smtp_pass = m[:pass].to_s if smtp_pass.empty?
        mail_to   = prompt_line(out, input, "  Send the summary to", m[:to] || smtp_user)
      end

      if token.nil? || token.empty? || login.nil? || login.empty?
        out.puts "\nkamandar: token and login are both required — nothing written."
        return
      end

      verify_token(token, login, out)

      values = { "GITHUB_TOKEN" => token, "GH_LOGIN" => login, "PROJECT_URL" => project,
                 "STALE_DAYS" => stale }
      unless smtp_host.to_s.empty?
        values.merge!("SMTP_HOST" => smtp_host, "SMTP_PORT" => smtp_port,
                      "SMTP_USER" => smtp_user, "SMTP_PASS" => smtp_pass,
                      "MAIL_TO" => (mail_to.to_s.empty? ? smtp_user : mail_to))
      end
      write_config_file(path, Config.render_file(values))
      out.puts "\nSaved. Run `kamandar` from anywhere now."
      out.puts "Tip: `kamandar --email` sends the summary now; see service/ to schedule 10 PM." unless smtp_host.to_s.empty?
    rescue Interrupt
      out.puts "\nkamandar: setup cancelled."
    end

    def prompt_secret(out, input, label)
      out.print label
      out.flush
      # No-echo only makes sense on a real terminal; on a pipe `noecho` raises
      # ENOTTY, so fall back to a plain read there (tests, scripted setup).
      value = if input.respond_to?(:noecho) && input.respond_to?(:tty?) && input.tty?
                input.noecho(&:gets)
              else
                input.gets
              end
      out.puts # newline the suppressed Enter swallowed
      value.to_s.strip
    end

    def prompt_line(out, input, label, current)
      suffix = current && !current.empty? ? " [#{current}]" : ""
      out.print "#{label}#{suffix}: "
      out.flush
      value = input.gets.to_s.strip
      value.empty? ? current.to_s : value
    end

    # One viewer query to confirm the token works and matches the login. A bad
    # token shouldn't abort the wizard — warn, let the user save anyway.
    def verify_token(token, login, out)
      actual = GitHub.viewer_login(token)
      if actual.nil?
        out.puts "kamandar: couldn't verify token (will save anyway)."
      elsif actual.casecmp?(login)
        out.puts "kamandar: token OK — authenticated as #{actual}."
      else
        out.puts "kamandar: token authenticates as #{actual}, not #{login} (saving as entered)."
      end
    rescue GitHub::Error => e
      out.puts "kamandar: token check failed: #{e.message} (will save anyway)."
    end

    def write_config_file(path, contents)
      require "fileutils"
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      File.chmod(0o600, path) # contains a token — keep it owner-only
    end

    def warn_no_project(config)
      return unless Engine.scope_mode(config) == "project"
      return if config[:project_url] && !config[:project_url].empty?
      $stderr.puts "kamandar: PROJECT_URL unset — board buckets will be empty."
    end

    # When a name-based scope (org/repo) returns nothing at all, the name is the
    # likely culprit — surface that instead of leaving the user guessing.
    def warn_if_empty(config, buckets, out: $stderr)
      return unless %w[org repo project].include?(Engine.scope_mode(config))
      return unless buckets.values.all? { |rows| (rows || []).empty? }
      out.puts "kamandar: everything is empty for #{Engine.scope_label(config[:scope])} — " \
               "double-check the name is spelled correctly and your token can access it."
    end
  end
end

# Guard: tests can `require` this file without running or reading ENV.
if __FILE__ == $PROGRAM_NAME
  Kamandar::CLI.run
end
