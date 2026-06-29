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
#   2. Export the two required values:
#        export GITHUB_TOKEN=ghp_xxx
#        export GH_LOGIN=your-username
#      (PROJECT_URL is optional — the scope picker asks for it when you choose
#       project scope; set it only to wire bucket #3 non-interactively.)
#   3. Run:
#        ruby lib/kamandar.rb              # terminal output (default)
#        ruby lib/kamandar.rb --serve      # live web app at http://127.0.0.1:4567
#        ruby lib/kamandar.rb --dashboard  # full-screen Matrix TUI (rain splash)
#        ruby lib/kamandar.rb --browser    # render + open a static HTML page
#        ruby lib/kamandar.rb -b --watch 60  # live tab, refreshed every 60s
#        ruby lib/kamandar.rb --statuses   # list a board's Status labels (to
#                                          # configure NOT_STARTED/REVIEW_STATUSES)
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
#   NOT_STARTED_STATUSES  (Todo,Backlog,No Status)  case-insensitive status set
#   REVIEW_STATUSES       (In Review,Review,Needs Review)  statuses for bucket #4
#   QA_STATUSES           (Ready for QA,QA,In QA)  statuses for bucket #5
#   BLOCKED_STATUSES      (Blocked,On Hold,Waiting)  statuses for bucket #6
#   ITERATION_FILTER      (off)       `current` restricts #3 to the active sprint
#   ITERATION_FIELD       (Iteration) board's iteration field name
#   STALE_DAYS            (2)         threshold for bucket #7
#   DAY_MODE              (business)  business (skip Sat/Sun) | calendar
#   THEME / --theme       (—)         `matrix` = green boxed TUI (terminal/TTY
#                                     only; pipes stay plain)
#
# -----------------------------------------------------------------------------
# PUSH LAYER (terminal mode) — no scheduler code lives in this tool.
# -----------------------------------------------------------------------------
# Wire it into your own weekday-morning cron, piping terminal output to a
# notifier. Examples (crontab, 8:30am Mon-Fri):
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
                      assignees(first: 10) { nodes { login } }
                      repository { nameWithOwner }
                    }
                    ... on PullRequest {
                      number
                      url
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
        repo: pr.dig("repository", "nameWithOwner")
      }.merge(extra)
    end

    def normalize_item(item)
      content = item["content"]
      {
        number: content["number"],
        title: content["title"],
        url: content["url"],
        repo: content.dig("repository", "nameWithOwner")
      }
    end

    def normalize_issue(issue)
      {
        number: issue["number"],
        title: issue["title"],
        url: issue["url"],
        repo: issue.dig("repository", "nameWithOwner")
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
    #              :blocked_statuses, :stale_days, :day_mode, :iteration_filter,
    #              :iteration_field
    def classify(owed_prs:, my_prs:, project_items: [], assigned_issues: [],
                 iterations: nil, config:, today:)
      if scope_mode(config) == "project"
        classify_project(owed_prs: owed_prs, my_prs: my_prs,
                         project_items: project_items, iterations: iterations,
                         config: config, today: today)
      else
        classify_issue(owed_prs: owed_prs, my_prs: my_prs,
                       assigned_issues: assigned_issues, config: config, today: today)
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
  # Surface — dispatch + shared helpers
  # ---------------------------------------------------------------------------
  module Surface
    module_function

    # Resolve the surface preference. --browser/-b (browser_flag:true) wins;
    # otherwise OUTPUT env decides; default terminal.
    def resolve_surface(output_env:, browser_flag:)
      return :browser if browser_flag
      output_env.to_s.strip.downcase == "browser" ? :browser : :terminal
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
            <h1><span class="bow">\u{1F3F9}</span> Kamandar</h1>
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
        .bow{font-size:1.35rem}
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

    # Project home — linked from the nav and footer.
    REPO_URL = "https://github.com/cdrrazan/Kamandar"

    # Inline GitHub mark (no external asset; inherits currentColor).
    GH_ICON = %(<svg class="ghmark" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>)

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

    # Google Sans webfont. Served pages have network access (live localhost),
    # so a CDN link is fine here — unlike BrowserSurface, which must stay
    # self-contained for offline file:// use. Falls back to the system stack
    # in BrowserSurface.css if the font fails to load.
    FONT_LINKS = <<~HTML.chomp
      <link rel="preconnect" href="https://fonts.googleapis.com">
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
      <link href="https://fonts.googleapis.com/css2?family=Google+Sans:ital,opsz,wght@0,17..18,400..700;1,17..18,400..700&display=swap" rel="stylesheet">
    HTML

    # The full live page: header chips + a control bar + the bucket sections.
    # `scope`/`name`/`project_url`/`poll` reflect the current request so the
    # form re-renders with the user's selection.
    def page(buckets, config:, generated_at:, mode: "global", name: "",
             project_url: "", poll: 0)
      esc = BrowserSurface.method(:escape)
      meta_list = Engine.bucket_meta(Engine.scope_mode(config))
      total = meta_list.sum { |key, _, _| (buckets[key] || []).size }
      scope_label = config[:scope] ? Engine.scope_label(config[:scope]) : "global"
      app = tabbed_html(buckets, meta_list, total: total, scope_label: scope_label)
      tab_rules = tab_css(meta_list.size)

      refresh = poll.to_i > 0 ? %(<meta http-equiv="refresh" content="#{poll.to_i}">) : ""

      # Scope picker as a radio segmented control (not a <select>) so CSS :has()
      # can reveal only the fields a scope needs — no JavaScript. The server
      # keeps the chosen scope checked across reloads.
      segments = SCOPE_MODES.map do |m|
        ck = m == mode ? " checked" : ""
        %(<input class="segr" type="radio" name="mode" id="m-#{m}" value="#{m}"#{ck}>) +
          %(<label class="seglabel" for="m-#{m}">#{m}</label>)
      end.join

      chips = [
        %(<span class="chip total">#{total} open</span>),
        %(<span class="chip">@#{esc.call(config[:login])}</span>),
        %(<span class="chip">#{esc.call(generated_at.strftime('%H:%M:%S'))}</span>),
        %(<span class="chip">#{esc.call(config[:day_mode])} days</span>),
        (poll.to_i > 0 ? %(<span class="chip live">live #{poll.to_i}s</span>) : nil)
      ].compact.join("\n      ")

      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        #{refresh}
        <title>Kamandar — @#{esc.call(config[:login])}</title>
        #{FONT_LINKS}
        <style>#{BrowserSurface.css}#{extra_css}#{tab_rules}</style>
        </head>
        <body>
        <header class="appbar">
          <nav class="topbar">
            <div class="nav-wrap">
              <a class="brand" href="/"><span class="bow">\u{1F3F9}</span> <span class="brandname">Kamandar</span></a>
              <div class="meta">
                #{chips}
              </div>
              <a class="ghlink" href="#{REPO_URL}" target="_blank" rel="noopener" title="Kamandar on GitHub">#{GH_ICON}</a>
            </div>
          </nav>
          <div class="toolbar">
            <form class="controls" method="get" action="/">
              <span class="seg" role="radiogroup" aria-label="Scope">#{segments}</span>
              <input class="field f-name" type="text" name="name" value="#{esc.call(name)}" placeholder="org or owner/name">
              <input class="field f-proj" type="text" name="project_url" value="#{esc.call(project_url)}" placeholder="project board URL">
              <label class="field f-poll pollbox" title="Auto-refresh interval — 0 turns it off">
                <span class="pollicon">↻</span>
                <span class="polltext">Auto-refresh</span>
                <input type="number" name="poll" value="#{poll.to_i}" min="0" step="5" aria-label="Auto-refresh seconds">
                <span class="pollunit">s</span>
              </label>
              <button type="submit">Apply</button>
              <a class="refresh" href="#{esc.call(self_link(mode, name, project_url, poll))}" title="Refresh now">↻</a>
            </form>
          </div>
        </header>
        #{app}
        <footer class="foot">
          <div class="foot-wrap">
            <span class="fbrand"><span class="bow">\u{1F3F9}</span> Kamandar v#{VERSION}</span>
            <span class="dot">·</span>
            <span>personal GitHub command center</span>
            <span class="dot">·</span>
            <span>127.0.0.1 · stdlib-only Ruby</span>
            <span class="grow"></span>
            <a class="ghlink" href="#{REPO_URL}" target="_blank" rel="noopener">#{GH_ICON}<span>GitHub</span></a>
            <span class="dot">·</span>
            <span>generated #{esc.call(generated_at.strftime('%H:%M:%S'))}</span>
          </div>
        </footer>
        </body>
        </html>
      HTML
    end

    # Build the sidebar + tabbed panels. Pure CSS tabs: one hidden radio per
    # bucket drives which panel shows (`tab_css` generates the per-index rules),
    # so it works with no JavaScript. The first bucket is selected by default.
    def tabbed_html(buckets, meta_list, total: 0, scope_label: "global")
      esc = BrowserSurface.method(:escape)
      radios = []
      items = [] # one {key, size, nav} per bucket, in board order
      panels = []
      meta_list.each_with_index do |(key, title, empty), i|
        rows = buckets[key] || []
        meta = BrowserSurface::BUCKET_META[key] || { icon: "•", color: "var(--accent)" }
        checked = i.zero? ? " checked" : ""
        radios << %(<input class="tabr" type="radio" name="kt" id="kt-#{i}"#{checked}>)
        cls = rows.empty? ? "count z" : "count"
        short = SHORT_LABELS[key] || title
        nav = %(<label class="navitem" for="kt-#{i}" style="--c:#{meta[:color]}" title="#{esc.call(title)}">) +
              %(<span class="icon">#{meta[:icon]}</span>) +
              %(<span class="navtitle">#{esc.call(short)}</span>) +
              %(<span class="#{cls}">#{rows.size}</span></label>)
        items << { key: key, size: rows.size, nav: nav }
        body =
          if rows.empty?
            %(<p class="empty">#{esc.call(empty)}</p>)
          else
            rows.map { |row| BrowserSurface.card(row, key) }.join("\n")
          end
        classes = +"bucket"
        classes << " warn" if key == :stale
        classes << " is-empty" if rows.empty?
        panels << <<~SECTION.chomp
          <section class="#{classes}" id="kp-#{i}" style="--c:#{meta[:color]}">
            <h2><span class="icon">#{meta[:icon]}</span> <span class="htitle">#{esc.call(title)}</span> <span class="count">#{rows.size}</span></h2>
            #{body}
          </section>
        SECTION
      end

      # Two boxes: reviews you owe on *other people's* work, and *your own*
      # assigned issues/PRs. REVIEW_KEYS lists the "others' work" buckets.
      reviews, mine = items.partition { |it| REVIEW_KEYS.include?(it[:key]) }
      boxes = [
        sidebox("Others' work", reviews),
        sidebox("Your work", mine, foot: scope_label)
      ].join("\n")

      <<~APP
        <div class="app">
        #{radios.join("\n")}
        <aside class="sidebar">#{boxes}</aside>
        <main class="panels">#{panels.join("\n")}</main>
        </div>
      APP
    end

    # Buckets that represent *other people's* work (review requested from you),
    # as opposed to your own assigned issues/PRs. Drives the sidebar split.
    REVIEW_KEYS = %i[reviews_owed].freeze

    # One carded sidebar group: a header (title + open count) and its tabs.
    # Skipped entirely if the group has no buckets in the current scope.
    def sidebox(title, items, foot: nil)
      return "" if items.empty?

      esc = BrowserSurface.method(:escape)
      open = items.sum { |it| it[:size] }
      cls = open.zero? ? "chip total z" : "chip total"
      footer = foot ? %(<div class="side-foot">#{esc.call(foot)}</div>) : ""
      <<~BOX.chomp
        <section class="sidebox">
          <div class="side-head">
            <span class="side-title">#{esc.call(title)}</span>
            <span class="#{cls}">#{open} open</span>
          </div>
          <nav>#{items.map { |it| it[:nav] }.join("\n")}</nav>
          #{footer}
        </section>
      BOX
    end

    # Per-index tab rules. CSS can't loop, and the bucket count varies by scope
    # (project = 8, issue = 6), so the show-panel / highlight-tab pairs are
    # generated to match the current bucket count.
    def tab_css(count)
      (0...count).map do |i|
        on = %(#kt-#{i}:checked~.sidebar .navitem[for="kt-#{i}"])
        %(#kt-#{i}:checked~.panels #kp-#{i}{display:block}) +
          # selected tab: fill with the bucket color, flip text/badge to white
          %(#{on}{background:var(--c);border-color:var(--c);box-shadow:var(--shadow)}) +
          %(#{on} .navtitle{color:#fff}) +
          %(#{on} .count{background:rgba(255,255,255,.26);color:#fff;border:1px solid rgba(255,255,255,.85)})
      end.join("\n")
    end

    # A tiny error page reusing the same chrome — shown when a fetch fails so the
    # server keeps running instead of dropping the connection.
    def error_page(message, config:)
      esc = BrowserSurface.method(:escape)
      <<~HTML
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Kamandar — error</title>#{FONT_LINKS}<style>#{BrowserSurface.css}#{extra_css}</style></head>
        <body><header><div class="wrap">
          <h1><span class="bow">\u{1F3F9}</span> Kamandar</h1>
        </div></header>
        <main><section class="bucket warn" style="--c:var(--warn)">
          <h2><span class="icon">\u{26A0}\u{FE0F}</span> <span class="htitle">Couldn't load your queue</span></h2>
          <p class="empty">#{esc.call(message)}</p>
          <p class="empty"><a href="/">Try again</a></p>
        </section></main></body></html>
      HTML
    end

    # GET link back to self with the current selection preserved.
    def self_link(mode, name, project_url, poll)
      m = mode.to_s == "global" ? "" : mode.to_s # global is the default; omit it
      q = { "mode" => m, "name" => name, "project_url" => project_url,
            "poll" => poll.to_i }
      pairs = q.reject { |_, v| v.to_s.empty? || v == 0 }
               .map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }
      pairs.empty? ? "/" : "/?#{pairs.join('&')}"
    end

    # The premium chrome layered on top of BrowserSurface.css: a sticky glass
    # top nav, the sidebar + tabbed panels, and a footer. Theme variables are
    # inherited from BrowserSurface.css so it tracks light/dark automatically.
    def extra_css
      <<~CSS
        body{font-family:"Google Sans",-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;display:flex;flex-direction:column;min-height:100vh;background:radial-gradient(1100px 380px at 50% -160px,color-mix(in srgb,var(--accent) 12%,transparent),transparent),var(--bg);background-attachment:fixed}
        /* sticky app header — frosted glass; nav row + toolbar row */
        .appbar{position:sticky;top:0;z-index:10;background:color-mix(in srgb,var(--bg) 80%,transparent);backdrop-filter:saturate(1.5) blur(12px);-webkit-backdrop-filter:saturate(1.5) blur(12px);border-bottom:1px solid var(--border)}
        .nav-wrap{max-width:70%;margin:0 auto;padding:12px 16px;display:flex;flex-wrap:wrap;align-items:center;gap:10px 14px}
        .brand{display:flex;align-items:center;gap:8px;text-decoration:none;font-weight:800;font-size:1.18rem;letter-spacing:-.01em;color:var(--fg)}
        .brand .bow{font-size:1.2rem}
        .brandname{background:linear-gradient(90deg,var(--accent),#8250df);-webkit-background-clip:text;background-clip:text;color:transparent}
        .topbar .meta{margin:0 0 0 auto}
        /* toolbar row (below the nav) */
        .toolbar{border-top:1px solid var(--border)}
        .controls{max-width:70%;margin:0 auto;padding:10px 16px;display:flex;flex-wrap:wrap;gap:8px;align-items:center}
        .controls input,.controls button{font:inherit;font-size:.82rem;background:var(--card);color:var(--fg);border:1px solid var(--border);border-radius:8px;padding:6px 10px}
        .controls .field{min-width:160px}
        .controls .pollbox{min-width:0;display:inline-flex;align-items:center;gap:7px;padding:4px 6px 4px 11px;cursor:text;transition:border-color .1s ease}
        .controls .pollbox:focus-within{border-color:var(--accent)}
        .controls .pollbox .pollicon{font-size:.92rem;line-height:1;color:var(--accent)}
        .controls .pollbox .polltext{font-size:.78rem;font-weight:600;color:var(--muted)}
        .controls .pollbox input{font-variant-numeric:tabular-nums;font-weight:600;color:var(--fg);background:var(--bg);border:1px solid var(--border);border-radius:6px;padding:3px 4px;width:48px;text-align:center;min-width:0}
        .controls .pollbox input:focus{outline:none;border-color:var(--accent)}
        .controls .pollbox .pollunit{font-size:.78rem;color:var(--muted);padding-right:3px}
        .controls button{cursor:pointer;font-weight:600;border-color:var(--accent);color:var(--accent);transition:background .1s ease,color .1s ease}
        .controls button:hover{background:var(--accent);color:#fff}
        .controls .refresh{text-decoration:none;font-size:1.1rem;line-height:1;color:var(--muted);border:1px solid var(--border);border-radius:8px;padding:5px 10px}
        .controls .refresh:hover{color:var(--accent);border-color:var(--accent)}
        /* segmented scope control (radios styled as a pill group) */
        .seg{display:inline-flex;background:var(--card);border:1px solid var(--border);border-radius:9px;padding:2px;gap:2px}
        .segr{position:absolute;width:1px;height:1px;opacity:0;pointer-events:none}
        .seglabel{cursor:pointer;font-size:.82rem;font-weight:600;color:var(--muted);padding:5px 11px;border-radius:7px;text-transform:capitalize}
        .seglabel:hover{color:var(--fg)}
        .segr:checked+.seglabel{background:var(--accent);color:#fff}
        /* reveal only the fields the chosen scope needs — pure CSS, no JS */
        .controls .field{display:none}
        .controls:has(#m-org:checked) .f-name,
        .controls:has(#m-repo:checked) .f-name,
        .controls:has(#m-project:checked) .f-proj,
        .controls:has(.segr:checked:not(#m-global)) .f-poll{display:inline-block}
        .ghlink{display:inline-flex;align-items:center;gap:6px;color:var(--muted);text-decoration:none;border:1px solid var(--border);border-radius:8px;padding:6px 9px;transition:color .1s ease,border-color .1s ease}
        .ghlink:hover{color:var(--fg);border-color:var(--accent)}
        .ghmark{display:block}
        /* layout: sidebar + main content */
        .app{flex:1 0 auto;display:flex;gap:24px;width:100%;max-width:70%;margin:0 auto;padding:24px 16px 48px;align-items:flex-start}
        .tabr{position:absolute;width:1px;height:1px;opacity:0;pointer-events:none}
        .sidebar{position:sticky;top:120px;flex:none;width:248px;display:flex;flex-direction:column;gap:14px}
        .sidebox{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:12px;box-shadow:var(--shadow)}
        .side-head{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:2px 4px 11px;border-bottom:1px solid var(--border)}
        .side-title{font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:.09em;color:var(--muted)}
        .chip.total.z{border-color:var(--border);color:var(--muted)}
        .sidebar nav{display:flex;flex-direction:column;gap:3px;margin-top:8px}
        .navitem{display:flex;align-items:center;gap:9px;padding:9px 11px;border:1px solid transparent;border-radius:10px;cursor:pointer;color:var(--fg)}
        .navitem:hover{background:var(--bg)}
        .navtitle{flex:1 1 auto;min-width:0;font-weight:600;font-size:.9rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .navitem .count.z{background:var(--border);color:var(--muted)}
        .side-foot{margin-top:11px;padding:9px 4px 2px;border-top:1px solid var(--border);font-size:.74rem;color:var(--muted);text-align:center}
        .panels{flex:1 1 auto;min-width:0;margin:0;padding:0;max-width:none}
        .panels .bucket{display:none;margin:0}
        .navitem:focus-within{outline:2px solid var(--accent);outline-offset:2px}
        /* footer */
        .foot{flex-shrink:0;border-top:1px solid var(--border);background:var(--card)}
        .foot-wrap{max-width:70%;margin:0 auto;padding:18px 16px 28px;display:flex;flex-wrap:wrap;align-items:center;gap:6px 12px;color:var(--muted);font-size:.78rem}
        .foot .fbrand{display:flex;align-items:center;gap:6px;font-weight:700;color:var(--fg)}
        .foot .dot{opacity:.45}
        .foot .grow{flex:1 1 auto}
        .foot .ghlink{border:none;padding:0;font-weight:600}
        @media (max-width:720px){
          .app{flex-direction:column;gap:14px}
          .sidebar{position:static;width:auto}
          .sidebar nav{flex-direction:row;flex-wrap:wrap}
          .navitem{flex:0 0 auto}
          .navtitle{display:none}
          .side-head,.side-foot{display:none}
          .topbar .controls{margin:0;width:100%}
        }
      CSS
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
      { scope: scope, mode: mode, name: name,
        project_url: query["project_url"].to_s.strip,
        poll: query["poll"].to_i }
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

      not_started = (env["NOT_STARTED_STATUSES"] || "Todo,Backlog,No Status")
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
        day_mode: (env["DAY_MODE"] || "business"),
        output_env: (env["OUTPUT"] || "terminal"),
        browser_flag: flags[:browser],
        theme: (flags[:theme] || env["THEME"] || "").to_s.strip.downcase,
        dashboard: flags[:dashboard] || false,
        serve: flags[:serve] || false,
        port: flags[:port] || (env["PORT"] || Server::DEFAULT_PORT).to_i,
        project_org: project_org,
        list_statuses: flags[:statuses] || false,
        watch_seconds: flags.key?(:watch) ? flags[:watch] : (env["WATCH_SECONDS"] || "0").to_i
      }
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
        when "--statuses"
          flags[:statuses] = true
        when "--dashboard"
          flags[:dashboard] = true
        when "--serve"
          flags[:serve] = true
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

    def run(env: ENV, argv: ARGV)
      config = Config.from(env: env, argv: argv)
      validate!(config)

      surface = Surface.resolve_surface(
        output_env: config[:output_env],
        browser_flag: config[:browser_flag]
      )

      # Terminal + interactive + no scope given: let the user pick one (and a
      # project URL if they choose project and none is set). Browser, cron, and
      # pipes are skipped so nothing ever blocks on stdin.
      return print_statuses(config) if config[:list_statuses]

      # The live web UI picks its own scope in-page, so skip the stdin picker.
      return run_server(config) if config[:serve]

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
    # SECURITY: binds 127.0.0.1 only, and the token never reaches any response.
    def run_server(config, host: Server::HOST, open: true)
      port   = config[:port].to_i
      port   = Server::DEFAULT_PORT if port <= 0
      server = TCPServer.new(host, port)
      url    = "http://#{host}:#{port}"
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
      server&.close
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
        client.write(Server.http_response(204, ""))
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
      buckets = fetch_and_classify(live)
      html = ServerSurface.page(buckets, config: live, generated_at: Time.now,
                                         mode: sel[:mode], name: sel[:name],
                                         project_url: sel[:project_url], poll: sel[:poll])
      Server.http_response(200, html)
    rescue GitHub::Error => e
      Server.http_response(200, ServerSurface.error_page(e.message, config: config))
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
      missing = []
      missing << "GITHUB_TOKEN" unless config[:token] && !config[:token].empty?
      missing << "GH_LOGIN" unless config[:login] && !config[:login].empty?
      return if missing.empty?
      $stderr.puts "kamandar: missing required configuration: #{missing.join(', ')}"
      $stderr.puts "See the header of this file for setup instructions."
      exit 1
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
