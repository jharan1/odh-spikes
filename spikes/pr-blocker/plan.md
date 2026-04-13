# PR Blocker / Flaky Test Investigator — Plan

## Background

PRs frequently get held up by failing CI tests where it's not immediately obvious whether the failure is a real regression or a known flaky test. This plan describes two complementary approaches to give developers quick, actionable insight into what's blocking a PR.

Related: Purva may be working on an adjacent (but separate) skill focused on promoting best practices to *avoid* introducing flaky tests. This effort focuses on *identifying* flakiness after the fact.

---

## Shared Foundation: Flaky Test Registry (`docs/flaky-tests.yaml`)

Both approaches below rely on a shared versioned YAML file in the repo that tracks known flaky tests — simple, queryable, and auditable via git history.

### Schema

```yaml
- id: "cypress-timeout-001"
  test: "should open create workbench modal"
  file: "packages/cypress/cypress/tests/mocked/workbenches/workbench.cy.ts"
  area: "workbenches"
  symptoms:
    - "CypressError: Timed out retrying after 10050ms"
    - "cy.click() failed because it requires a DOM element"
  first_seen: "2025-11-03"
  last_seen: "2026-04-10"
  pr_occurrences: ["#4821", "#4897", "#4912"]
  status: "active"  # active | resolved | intermittent
  resolution: "Rerun — passes on retry consistently"
  jira: "RHOAIENG-99999"
  notes: "Race condition in modal animation timing"
```

### Why YAML file vs GitHub Issues

- Queryable locally without API calls — skills can `cat` it instantly
- Versioned with the code — you can see when tests became flaky
- Low ceremony to update — a dev can edit it in a PR
- GitHub Issues are better for discussion; YAML is better for structured lookup

---

## Confidence Model (applies to both approaches)

A key design principle: **symptom patterns are signals, not verdicts.** A timeout or missing DOM element can equally mean a broken component, a slow CI runner, or a racy test. Neither approach should auto-label something as flaky — the developer always makes the final call.

**Tier 1 — Confirmed flaky** (registry match)
- Test name/file matches a registry entry with a history of occurrences across multiple PRs
- High confidence — recommend rerun, cite the history

**Tier 2 — Suspected / investigate** (symptom-only match)
- The error pattern looks like a known flaky symptom, but the specific test is *not* in the registry
- Low confidence — surface it as a possibility, not a conclusion
- Prompt the developer to check: is this failure related to their changes? Has the test passed recently on `main`?

**Tier 3 — Unknown**
- No symptom or registry match — treat as a real failure until proven otherwise

#### Known flaky symptom patterns to detect

- `CypressError: Timed out retrying after 10050ms`
- `cy.click() failed because it requires a DOM element, window or document`
- `cy.intercept()` network timing failures
- Race conditions in async test setup
- `socket hang up` / network connectivity blips in CI

---

## Part 1: Claude Code Skill (terminal-based, on-demand)

A Claude Code skill invoked by a developer in their own terminal. Best suited for deep, interactive investigation when someone is actively debugging a PR.

### Invocation

```
/pr-blocker 4821        # investigate a specific PR
/pr-blocker             # prompts for a PR number
/pr-blocker mark-flaky  # register a confirmed flaky test
/pr-blocker stats       # trend analysis across recent PRs
```

### `/pr-blocker` — Main Investigation Workflow

**Phase 1 — Fetch PR state**
- `gh pr view <number>` — title, author, branch, merge status, review state
- `gh pr checks <number>` — all CI check statuses
- Identify which checks are failing

**Phase 2 — Analyze failures**
- `gh run view <run-id> --log-failed` — fetch logs for each failing check
- Extract test names, error messages, error patterns
- Apply the confidence model (Tier 1 / 2 / 3 classification)

**Phase 3 — Generate report**

Example output:

```
## PR #4821 Blocker Analysis

**Status:** 2 of 3 checks failing | 1 review pending (Joe)

### Failing Tests

| Test | Classification | Confidence | Suggested Action |
|------|---------------|------------|-----------------|
| should open create workbench modal | ✅ Confirmed Flaky | High | Rerun |
| should display error on timeout    | ⚠️ Suspected Flaky | Low  | Investigate first |
| should validate form on submit     | ❓ Unknown         | —    | Treat as real failure |

### Confirmed Flaky
- "should open create workbench modal" is a known flaky test (RHOAIENG-99999)
  - Seen in 3 recent PRs: #4821, #4897, #4912
  - Resolution: Rerun — passes on retry consistently

### Suspected Flaky (verify before acting)
- "should display error on timeout" matches symptom: "Timed out retrying after 10050ms"
  - This error can indicate a flaky test, but may also be a real regression
  - Check: is this failure related to your PR's changes?
  - If you confirm it's flaky, run `/pr-blocker mark-flaky` to track it

### Unknown Failures
- "should validate form on submit" — no pattern matched; investigate as a real failure

### Recommended Actions
1. Rerun failing checks — 1 confirmed flaky test is present
2. Investigate "should display error on timeout" before dismissing as flaky
3. Request review from: [pending reviewer]

### Slack Message (optional)
[Formatted message ready to post to #test-flakiness channel]
```

### `/pr-blocker mark-flaky` — Feedback Loop

After a dev confirms a test was flaky:
1. Prompts: which test? which PR? symptom pattern observed?
2. Updates `docs/flaky-tests.yaml` — adds a new entry or appends a PR occurrence to an existing one
3. Stages the change for the dev to commit and push

Every time someone marks a test as flaky, the next dev benefits from the classification.

### `/pr-blocker stats` — Trend Analysis

Scans recent PRs to surface which tests are causing the most disruption:
1. `gh pr list --limit 30 --json number,headRefName,statusCheckRollup`
2. For each PR with failures, cross-reference against registry and symptom patterns
3. Output frequency by test and area

Example output:

```
## Flaky Test Stats (last 30 PRs)

| Test Area     | Occurrences | Last Seen | Status       |
|---------------|-------------|-----------|--------------|
| workbenches   | 6           | #4912     | active       |
| pipelines     | 3           | #4890     | active       |
| model-serving | 1           | #4854     | intermittent |

Most impacted PRs this week: #4821, #4897, #4912 (all hit workbench timeout)
```

Useful for situations where a broken test is causing mass confusion across many PRs simultaneously — surfacing "this pattern appeared in 6 PRs in the last 2 weeks" is immediately actionable.

---

## Part 2: GitHub PR Comment Trigger via Ambient (WIP)

> **Status: Work in progress** — the integration approach is defined but some Ambient API details need confirming before implementation.

A developer comments `/investigate` on any GitHub PR. A GitHub Actions workflow fires, creates an Ambient agentic session, and posts the investigation results back as a PR comment — no terminal or Claude Code CLI required.

### Why this complements Part 1

| | Claude Code `/pr-blocker` | GitHub `/investigate` comment |
|---|---|---|
| **Who uses it** | Dev in their terminal | Anyone on the PR (including reviewers) |
| **How triggered** | Slash command in Claude Code CLI | Comment on the GitHub PR |
| **Analysis** | Claude reasons interactively | Ambient Claude agent runs autonomously |
| **Good for** | Deep investigation, follow-up questions | Quick triage, team-wide visibility |

### What Ambient Is

[Ambient](https://github.com/ambient-code/platform) is a Kubernetes-native AI automation platform that runs Claude Code CLI in pods as agentic sessions. The session takes a task description and a Claude agent executes it autonomously — fetching data, reasoning, writing output.

This means the `/investigate` path gets the same LLM reasoning quality as the Claude Code skill, rather than being limited to scripted pattern matching. Novel or ambiguous failures that don't match a hardcoded pattern can still be reasoned about intelligently.

### Flow

```
Dev comments /investigate on PR
        ↓
GitHub Actions workflow triggers (on: issue_comment)
        ↓
Workflow gathers PR context (PR number, repo, failing check run IDs)
        ↓
POST /v1/sessions to Ambient with task prompt
        ↓
Ambient spawns a Claude Code CLI pod
        ↓
Claude agent: fetches CI logs via gh CLI, reads flaky-tests.yaml,
              applies confidence model, reasons about failures
        ↓
Workflow polls GET /v1/sessions/:id until complete
        ↓
Workflow posts investigation report as PR comment
```

### GitHub Actions Workflow (sketch)

```yaml
# .github/workflows/pr-investigate.yml
on:
  issue_comment:
    types: [created]

jobs:
  investigate:
    if: |
      github.event.issue.pull_request &&
      contains(github.event.comment.body, '/investigate')
    runs-on: ubuntu-latest
    steps:
      - name: Create Ambient session
        id: session
        run: |
          SESSION=$(curl -s -X POST \
            -H "Authorization: Bearer ${{ secrets.AMBIENT_TOKEN }}" \
            -H "X-Ambient-Project: odh-dashboard" \
            -H "Content-Type: application/json" \
            -d "{\"task\": \"Investigate failing CI checks on PR #${{ github.event.issue.number }} in opendatahub-io/odh-dashboard. Fetch the CI logs for failing checks, cross-reference against docs/flaky-tests.yaml, classify each failure as confirmed flaky / suspected flaky / unknown using the confidence model in the registry, and return a markdown investigation report.\"}" \
            ${{ secrets.AMBIENT_URL }}/v1/sessions)
          echo "session_id=$(echo $SESSION | jq -r '.id')" >> $GITHUB_OUTPUT

      - name: Poll until complete
        run: |
          # Poll GET /v1/sessions/:id until status is complete
          # (polling details TBD pending Ambient response shape confirmation)

      - name: Post results as PR comment
        run: |
          gh pr comment ${{ github.event.issue.number }} --body-file investigation-report.md
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Open Questions (blocking full implementation)

- **Response shape of `GET /v1/sessions/:id`** — how is the session output/result returned? What field contains the agent's output?
- **Passing credentials into the session** — how does the Ambient Claude agent get a `GH_TOKEN` to call `gh` CLI? Is this via env vars in the session payload, or configured at the project level?
- **Ambient instance URL and project name** — what is the org's Ambient instance URL and which project should be used?
- **Session timeout** — what is the maximum session duration, and what happens if CI log fetching is slow?

Recommended next step: speak to whoever owns the Ambient instance in the org to resolve the above before wiring up the GitHub Actions workflow.
