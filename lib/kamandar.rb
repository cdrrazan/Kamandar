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

    # URLs of the PRs that are actually items on the board. This is the precise
    # membership test for project scope — filtering by repo would also catch
    # PRs in the same repo that belong to other boards (e.g. a monorepo).
    def project_pr_urls(items)
      items.filter_map do |it|
        content = it["content"]
        content && content["__typename"] == "PullRequest" ? content["url"] : nil
      end.uniq
    end

    # Keep only PR nodes whose url is one of `urls` (i.e. on the board).
    def filter_prs_by_urls(prs, urls)
      set = urls.compact
      prs.select { |pr| set.include?(pr["url"]) }
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
      mode = config[:day_mode]
      reviews_owed = owed_prs.map { |pr| normalize_pr(pr) }
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

    def render(buckets, config:, generated_at:)
      lines = []
      header = "Kamandar for @#{config[:login]}  —  #{generated_at.strftime('%Y-%m-%d %H:%M')}  (#{config[:day_mode]} days)"
      header += "  [#{Engine.scope_label(config[:scope])}]" if config[:scope]
      lines << header
      lines << ("=" * 72)

      Engine.bucket_meta(Engine.scope_mode(config)).each do |key, title, empty|
        rows = buckets[key] || []
        lines << ""
        lines << "#{title} (#{rows.size})"
        lines << ("-" * title.length)
        if rows.empty?
          lines << "  #{empty}"
          next
        end
        rows.each do |row|
          suffix =
            if key == :stale && row[:days]
              "  — #{row[:days]} #{row[:mode]} days since you handed off"
            else
              ""
            end
          lines << "  ##{row[:number]} #{row[:title]}  (#{row[:repo]})#{suffix}"
          lines << "    #{row[:url]}"
        end
      end
      lines << ""
      lines.join("\n")
    end

    # The terminal surface's emit contract: print to stdout.
    def emit(output)
      $stdout.puts(output)
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

      sections = meta_list.map do |key, title, empty|
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

      if surface == :terminal && !config[:scope_given] && $stdin.tty?
        picked = prompt_scope(config)
        config = config.merge(scope: picked[:scope], project_url: picked[:project_url])
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
        output = TerminalSurface.render(buckets, config: config, generated_at: Time.now)
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
      out.puts "Scope for PR buckets:"
      out.puts "  1) global   — account-wide (default)"
      out.puts "  2) org      — a single organization"
      out.puts "  3) repo     — a single repository"
      out.puts "  4) project  — PRs that are items on a GitHub project board"

      # Re-prompt until a valid choice; blank/Enter (or EOF) means global.
      choice = nil
      loop do
        out.print "Select 1-4 (Enter = global): "
        line = input.gets
        choice = line.nil? ? "" : line.strip
        break if choice.empty? || %w[1 2 3 4].include?(choice)
        out.puts "kamandar: please enter 1, 2, 3, or 4 (or press Enter for global)."
      end

      project_url = config[:project_url]
      scope =
        case choice
        when "2"
          out.print "Org name: "
          name = (input.gets || "").strip
          name.empty? ? { mode: "global" } : { mode: "org", org: name }
        when "3"
          out.print "Repo (owner/name): "
          name = (input.gets || "").strip
          name.empty? ? { mode: "global" } : { mode: "repo", repo: name }
        when "4"
          # Re-prompt on a malformed URL; blank/Enter (or EOF) cancels to global.
          entered = config[:project_url].to_s.strip
          loop do
            if entered.empty?
              out.print "Project URL (e.g. https://github.com/orgs/ORG/projects/N): "
              line = input.gets
              break({ mode: "global" }) if line.nil? # EOF
              entered = line.strip
              break({ mode: "global" }) if entered.empty? # cancel
            end
            if Engine.parse_project_url(entered)
              project_url = entered
              break({ mode: "project" })
            end
            out.puts "kamandar: not a valid org project URL (expected …/orgs/ORG/projects/N). Try again, or press Enter for global."
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
          # Limit PR buckets to the PRs that are items on the board.
          urls = Engine.project_pr_urls(project_items)
          owed = Engine.filter_prs_by_urls(owed, urls)
          mine = Engine.filter_prs_by_urls(mine, urls)
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
