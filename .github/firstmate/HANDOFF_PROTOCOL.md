# Firstmate ↔ GitHub ↔ External Specialist Handoff Protocol

Protocol version: **v1**

This document defines the shared durable handoff format between:

- a local Firstmate system;
- GitHub issues and pull requests;
- an external interactive specialist such as ChatGPT Web;
- the captain / human operator.

The protocol is intentionally model-agnostic. Concrete models and providers
belong in local dispatch configuration, not in this file.

---

## 1. Core model

Use each system for a different purpose:

| Artifact / system | Authority |
| --- | --- |
| GitHub issue | Shared problem statement, requirements, settled decisions, discussion history |
| Firstmate backlog | Local orchestration, dispatch, worker state, holds, sequencing |
| Pull request | Concrete implementation, validation evidence, code review |
| External specialist | Advisory reasoning, investigation, architecture, or external implementation |
| Captain | Final policy / product judgment where human input is required |

Do **not** mirror the complete Firstmate execution state into GitHub labels or
comments. GitHub is the shared engineering boundary; Firstmate remains the
local orchestration authority.

---

## 2. Repository files

The protocol expects these files:

```text
.github/
├── ISSUE_TEMPLATE/
│   └── fm-handoff.md
├── pull_request_template.md
└── firstmate/
    └── HANDOFF_PROTOCOL.md
```

Recommended GitHub labels:

- `fm-handoff` — issue is intended for Firstmate intake.
- `fm-external-review` — external specialist input or review is requested.

Keep labels minimal. Do not create GitHub labels that duplicate every
Firstmate backlog state.

---

## 3. Chat / discussion → Firstmate

When an idea, bug, feature, or design starts in an external chat:

1. Discuss freely until the goal and known constraints are reasonably clear.
2. Ask the external specialist to read this protocol and
   `.github/ISSUE_TEMPLATE/fm-handoff.md`.
3. Create one GitHub issue using the handoff template.
4. Preserve settled decisions and acceptance criteria.
5. Preserve unresolved questions explicitly; do not disguise them as settled
   conclusions.
6. Hand the issue URL or `owner/repo#number` to Firstmate.
7. Firstmate creates or links a local backlog item and performs normal intake.

Suggested external-chat instruction:

> Create a Firstmate handoff issue for what we have discussed. Read
> `.github/firstmate/HANDOFF_PROTOCOL.md` and
> `.github/ISSUE_TEMPLATE/fm-handoff.md` first. Preserve settled decisions,
> acceptance criteria, constraints, evidence, and unresolved questions.
> Do not invent implementation constraints that we did not actually decide.

Suggested Firstmate instruction:

> Take over `owner/repo#123` and follow the repository handoff protocol.

### One issue may span many discussion rounds

Prefer one long-lived issue for one coherent feature / bug / engineering
outcome, even when Firstmate and the external specialist exchange multiple
rounds of questions and answers.

Create a new issue when the new work becomes independently deliverable,
independently prioritizable, or no longer shares the same acceptance criteria.

---

## 4. Durable markers

Structured comments use HTML markers so they remain unobtrusive in GitHub while
being easy to identify later.

### Specialist request

```html
<!-- fm-specialist-request:v1 id=sr-001 -->
```

### Specialist response

```html
<!-- fm-specialist-response:v1 for=sr-001 -->
```

### Decision update

```html
<!-- fm-decision-update:v1 id=du-001 -->
```

### PR external review request

```html
<!-- fm-review-request:v1 id=rr-001 -->
```

### PR external review response

```html
<!-- fm-review-response:v1 for=rr-001 -->
```

IDs are local to the issue or PR.

Use monotonically increasing identifiers:

- `sr-001`, `sr-002`, ...
- `du-001`, `du-002`, ...
- `rr-001`, `rr-002`, ...

Do not reuse an ID.

---

## 5. Firstmate → external specialist: Issue request

When Firstmate encounters uncertainty that warrants outside reasoning, prefer
a structured comment on the existing source issue rather than creating a
duplicate issue.

Use:

```markdown
<!-- fm-specialist-request:v1 id=sr-001 -->

## External specialist request

### Decision / question needed

State one precise question or tightly related set of questions.

### Why this requires escalation

Explain what uncertainty, risk, contradiction, or architectural issue prevents
normal progress.

### Current evidence

- `path/to/file` / symbol — observed fact
- command / test — observed result
- log / benchmark — observed result
- related issue / PR — relevant context

### Current hypotheses

1. Hypothesis ...
2. Hypothesis ...

These are hypotheses, not established facts.

### Constraints

- Constraint ...
- Constraint ...

### Requested output

Provide:

1. recommended conclusion;
2. supporting reasoning and evidence;
3. alternatives considered;
4. risks and remaining unknowns;
5. what remains engineering discretion after the recommendation;
6. any required change to acceptance criteria, constraints, or implementation direction.

Do not implement code unless explicitly requested.
```

While waiting, the local Firstmate task should be placed on an external hold
using the local backlog mechanism. The exact command is an implementation
detail of the Firstmate installation.

Suggested external-chat instruction:

> Handle the latest external specialist request on `owner/repo#123`.
> Read the repository and issue as needed, follow
> `.github/firstmate/HANDOFF_PROTOCOL.md`, and post your response back to the
> same issue.

---

## 6. External specialist → Firstmate: Issue response

Respond to a specific request ID:

```markdown
<!-- fm-specialist-response:v1 for=sr-001 -->

## External specialist response

### Conclusion

State the recommendation clearly.

### Evidence and reasoning

Explain the evidence and reasoning necessary for Firstmate or a worker to
evaluate the conclusion.

### Recommended direction

Describe the recommended implementation or investigation direction without
over-specifying unrelated details.

### Engineering discretion

State which implementation choices remain deliberately open after the
recommendation, and which choices must stay fixed.

### Alternatives considered

- Alternative:
  - Why it was rejected or deprioritized:

### Risks and remaining uncertainty

List remaining uncertainty explicitly.

Write `None` if none is known.

### Acceptance-criteria / constraint changes

Write `None` if the original issue remains valid.

If changes are required, state them explicitly. A settled prior decision should
not be considered superseded until a `fm-decision-update:v1` comment records
that change.
```

A specialist response is evidence, not automatic authority. Firstmate or the
task owner should reconcile it with repository evidence, tests, requirements,
and delivery constraints before acting on it.

## Pre-implementation alignment

When unresolved product, behavioral, contract, data-semantic, or architectural decisions block implementation, use the same source issue and `fm-specialist-request:v1` / `fm-specialist-response:v1` markers for the alignment round.
Do not create a competing alignment marker or duplicate issue.
The aligned outcome must make the goal, relevant facts, settled decisions, acceptance criteria, out of scope, engineering discretion, and remaining open decisions explicit before Firstmate copies it into an implementation brief.
A specialist recommendation remains advisory until Firstmate reconciles it with repository evidence and records any genuine captain decision through the existing local captain-hold lifecycle.

Suggested Firstmate instruction after the response exists:

> The external specialist response on `owner/repo#123` is ready. Reconcile it
> with the repository evidence and continue according to the handoff protocol.

---

## 7. Decision updates and supersession

Do not silently rewrite history when later work changes an earlier settled
decision.

When a decision changes, add:

```markdown
<!-- fm-decision-update:v1 id=du-001 -->

## Decision update

### Supersedes

Identify the earlier decision, comment, or section being superseded.

### New decision

State the new decision.

### Reason

Explain why the earlier decision is no longer appropriate.

### Consequences

- Acceptance criteria affected:
- Constraints affected:
- Existing implementation affected:
- Follow-up work required:
```

Rules:

- Later prose does not implicitly override earlier settled decisions.
- A decision is superseded only when the change is explicit.
- If useful, the issue body may later be edited to summarize the current state,
  but the decision-update comment remains the durable history.
- Never remove material historical context merely to make the issue look clean.

---

## 8. Implementation and PR handoff

Once code exists, use the pull request as the implementation and code-review
artifact.

The source issue remains authoritative for:

- goal;
- context;
- settled decisions;
- acceptance criteria;
- constraints;
- discussion history.

The PR should contain:

- source issue;
- implemented scope;
- important implementation choices;
- deviations;
- validation evidence;
- unresolved limitations;
- implementation origin;
- review focus.

One source issue may produce multiple PRs when the work has distinct
implementation slices.

Example:

```text
Issue #123 — synchronization architecture
├── PR #140 — server protocol
├── PR #147 — desktop client
└── PR #153 — mobile client
```

Do not duplicate the complete issue discussion into every PR.

---

## 9. External implementation

An external specialist may create code or a PR when explicitly requested.

Requirements:

1. Prefer a dedicated branch.
2. Prefer a draft PR until the local workflow has validated it.
3. Do not treat external code as a completed Firstmate worker result.
4. Do not merge solely because the external specialist says the change is
   complete.
5. Run the project’s normal local validation / delivery path.
6. Record important deviations or changed decisions on the source issue.

Suggested external-chat instruction:

> Implement the agreed change from `owner/repo#123` on a separate branch and
> open a draft PR. Follow `.github/pull_request_template.md` and
> `.github/firstmate/HANDOFF_PROTOCOL.md`. Do not merge it.

Suggested Firstmate instruction:

> Take over PR `owner/repo#140` as incoming external implementation. Validate
> it against its source issue and complete the normal delivery path.

---

## 10. External PR review

When an external specialist should review a PR, add a structured review request
comment on the PR.

```markdown
<!-- fm-review-request:v1 id=rr-001 -->

## External review request

### Source requirements

- Issue: #123

### Review focus

- Area / risk 1
- Area / risk 2

### Evidence already available

- tests:
- CI:
- benchmark:
- migration validation:

### Requested output

Identify:

1. blocking correctness issues;
2. violations of source requirements or settled decisions;
3. high-risk design issues;
4. missing validation;
5. non-blocking improvements, clearly separated from blockers.
```

The external specialist responds on the PR:

```markdown
<!-- fm-review-response:v1 for=rr-001 -->

## External review response

### Blocking findings

- None

### Requirement / design findings

- None

### Missing validation

- None

### Non-blocking improvements

- None

### Overall assessment

Summarize the review without treating passing CI as proof of architectural
correctness.
```

Suggested external-chat instruction:

> Review PR `owner/repo#140` against its source issue. Follow the latest
> `fm-review-request:v1` comment and the repository handoff protocol. Post the
> structured review response to the PR.

Suggested Firstmate instruction:

> Process the latest external review response on `owner/repo#140`, reconcile
> findings with the source issue and local evidence, and continue the normal
> delivery path.

---

## 11. Ownership and waiting states

At any moment, distinguish between:

- **Firstmate-owned work** — local orchestration should proceed.
- **External-specialist-owned next action** — local task should wait on an
  external hold.
- **Captain-owned next action** — local task should wait on a captain hold.
- **PR review / CI-owned next action** — use the normal project delivery
  mechanism.

Do not pretend an external specialist is a Firstmate-supervised worker.
Firstmate cannot assume it can inspect the specialist's live context, restart
it, message it mid-run, or determine completion from process state.

GitHub is the durable synchronization boundary.

---

## 12. Evidence rules

All participants should prefer evidence-bearing handoffs.

Good evidence:

- repository path and symbol;
- exact command;
- test name and exit status;
- observed error;
- stack trace;
- benchmark;
- version number;
- URL / specification;
- commit / issue / PR reference.

Weak evidence:

- "the code probably does...";
- "the worker said it is fixed";
- "tests seem fine";
- unsupported architectural conclusions.

Weaker or cheaper agents may gather evidence, but consequential conclusions
remain the responsibility of an appropriately capable task owner.

---

## 13. Security and privacy

Never put secrets, credentials, private keys, access tokens, sensitive customer
data, or other material unsuitable for the repository into issues, PRs, or
handoff comments.

Before asking an external specialist to inspect a repository or issue, follow
the repository/project's data-handling policy.

A GitHub handoff makes information durable and potentially visible to everyone
with access to that repository. Treat the handoff as part of the repository's
normal security boundary.

---

## 14. Minimal day-to-day workflow

### Start in external chat

1. Discuss the bug / feature / design.
2. Ask Chat to create a Firstmate handoff issue.
3. Tell Firstmate: `Take over owner/repo#123`.

### Firstmate needs stronger external reasoning

1. Firstmate adds `fm-specialist-request:v1 id=sr-NNN`.
2. Firstmate waits on an external hold.
3. Tell Chat: `Handle the latest specialist request on owner/repo#123`.
4. Chat posts `fm-specialist-response:v1 for=sr-NNN`.
5. Tell Firstmate: `The specialist response is ready; continue`.

### Implementation exists

1. Worker opens PR linked to the source issue.
2. PR follows `.github/pull_request_template.md`.
3. Firstmate runs normal validation / delivery.

### External review is useful

1. Add `fm-review-request:v1 id=rr-NNN` on the PR.
2. Tell Chat to review the PR.
3. Chat posts `fm-review-response:v1 for=rr-NNN`.
4. Firstmate processes findings and continues.

---

## 15. Protocol evolution

This is protocol **v1**.

When changing marker syntax or semantics:

- create a new protocol version;
- do not reinterpret old comments under new semantics;
- keep old markers readable;
- prefer backwards-compatible additions when possible.

Concrete model names, providers, quotas, and effort mappings should **not** be
added to this protocol. Those belong in the local Firstmate dispatch
configuration and can change independently.
