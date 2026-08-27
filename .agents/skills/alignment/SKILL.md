---
name: alignment
description: >-
  Agent-only pre-implementation alignment lifecycle for material product, behavioral, contract, data-semantic, and architectural decisions.
  Use before dispatch when a request is not mechanically explicit and unresolved design choices could change the implementation.
metadata:
  internal: true
user-invocable: false
---

# Pre-implementation alignment

Load this skill before dispatch when a request may contain unresolved material product, behavioral, contract, data-semantic, or architectural decisions.
Do not load it as a ceremony for a clear mechanical request whose intended behavior and implementation surface are already explicit.
Alignment is a distinct pre-implementation lifecycle.
It is not a post-implementation review, a replacement for validation, or a new worker kind.

## Intake decision

Classify the request against the decision surface before making an implementation brief.

New ship and scout briefs begin with `Alignment contract: unclassified`.
Firstmate must explicitly classify the request before implementation: use `bypassed` for a mechanical change with an explicit outcome, established behavior, and no material choice left for the implementation worker, or use `required` when a reasonable implementation would have to choose among product behavior, public or internal contract shape, data meaning, architecture, compatibility policy, or another decision that could materially change the outcome.
Examples of bypassed work include a bounded typo correction, a direct version update with a fixed target, or a test-only change whose expected behavior is already specified.
Investigation may proceed while alignment is pending, but implementation must not spawn or be promoted from a scout until the contract is complete.

Do not treat a recommendation, report, issue body, or chat answer as a captain decision merely because it sounds decisive.
A genuine captain-owned choice uses `captain-hold-lifecycle` and records the captain's actual answer through `bin/fm-captain-hold.sh answer` or its channel-neutral intake.

## Reasoning method

The alignment executor should keep the conversation natural rather than forcing a questionnaire.
Start from the desired outcome and make the decision surface visible as it emerges.

Separate each material statement into three kinds:

- Repository or environment fact - something directly observed in source, configuration, documentation, a command, a test, or another inspectable primary source.
- Expert recommendation - an executor's proposed direction with its rationale, alternatives, risks, and uncertainty.
- Captain decision - the policy or product choice the captain actually settled, including an explicit answer to a held decision when one was required.

Investigate discoverable facts directly instead of asking the captain to retrieve information the executor can inspect.
Expose assumptions that affect the outcome, identify meaningful alternatives, and recommend a direction with the trade-offs that make the recommendation useful.
Keep asking or investigating only while an unresolved material choice could change the implementation contract.
Do not turn settled decisions into fresh questions merely to complete a checklist.

## Local Secondmate path

Prefer a suitable strong local Secondmate when its natural-language `scope:` fits the request and its configured model and effort are appropriate for the reasoning class.
Use the existing secondmate routing, harness, model, effort, parent binding, and marked-request machinery.
Do not create one Secondmate per project, add a provider setting, or make an ordinary implementation crewmate captain-facing.

The captain may converse directly with the selected local Secondmate for the focused alignment session.
Firstmate owns routing and lifecycle, but must not relay the detailed captain/executor conversation or reconstruct it from chat history.
A marked request from Firstmate must still use the Secondmate's parent status or document-pointer return channel and preserve its correlation.
For a captain-initiated direct local session, the Secondmate runs `bin/fm-alignment.sh start [<alignment-id>]`, writes the outcome in its own `data/<alignment-id>/report.md`, and runs `bin/fm-alignment.sh complete-direct <alignment-id>` when ready.
That command resolves the seeded local parent, validates the report, and writes an uncorrelated keyed document pointer; it never fabricates a `corr=<id>` token.

The local executor writes the outcome, not a transcript, to its own home at `data/<id>/report.md`.
The completed report must contain exactly these semantic sections, with a meaningful body in each:

```markdown
# Pre-implementation alignment

## Goal
...

## Relevant facts
...

## Settled decisions
...

## Acceptance criteria
...

## Out of scope
...

## Engineering discretion
...

## Remaining open decisions
None - no material open decisions remain.
```

A report may retain open decisions while the conversation is in progress.
Before claiming implementation-ready completion, run `bin/fm-alignment.sh validate-report <report> --complete` and pass `captain-hold-lifecycle`'s completion gate for every genuine captain-owned decision.
The completed report's final section must explicitly state that no material open decisions remain.

When parent-routed alignment reaches implementation-ready completion, notify the parent with the existing correlated report path.
Use `bin/fm-secondmate-report.sh --doc <parent-status-file> done <corr-id> <report-path> ...` or the equivalent parent status contract, and preserve the exact `corr=<id>` token.
For a direct captain-initiated local alignment, `complete-direct` uses the existing parent status/document-pointer stream with a keyed uncorrelated line; the parent consumes the durable report pointer and never needs the Secondmate's chat transcript.

If the captain owns a remaining choice, use `bin/fm-captain-hold.sh hold` in the home that owns the work, report the keyed decision, and stop the alignment completion path until the captain's actual answer is recorded.
Do not report a complete alignment while a material captain-held decision remains open.

## External specialist path

When no suitable local alignment executor exists, use the existing GitHub external-specialist protocol on the coherent source issue.
Do not create a duplicate issue for another discussion round that belongs to the same engineering outcome.
Use the existing `fm-specialist-request:v1` marker and request shape from `.github/firstmate/HANDOFF_PROTOCOL.md`, then match the response with `fm-specialist-response:v1`.
Keep GitHub as the durable shared artifact and keep Firstmate's backlog and holds as the local orchestration authority.

An external response is evidence and a recommendation, not an implicit captain decision.
Reconcile it with repository facts and the original settled decisions.
If it changes a prior decision, require the protocol's explicit `fm-decision-update:v1` history and route any genuine captain choice through `captain-hold-lifecycle`.

External alignment is complete only when the source issue/spec has an explicit current goal, relevant facts, settled decisions, acceptance criteria, out of scope, engineering discretion, and remaining open decisions, with no material open decision remaining.
The implementation brief records the source issue or spec in its `Alignment source:` line and carries the current accepted outcome in its `# Alignment outcome` sections.

## Implementation handoff

After local or external alignment completes, Firstmate turns the durable outcome into the implementation brief without reinterpreting settled decisions.
Copy the current accepted goal, facts, captain decisions, acceptance criteria, scope boundary, and engineering discretion into the brief, and keep any remaining open product/design decisions explicit.
Use `Alignment contract: complete` only after the outcome is copied and `bin/fm-alignment.sh check <brief>` accepts it.

`bin/fm-spawn.sh` and scout promotion enforce the barrier before an endpoint or implementation lifecycle is started.
A `required` contract is a refusal, not a suggestion.
A `bypassed` contract preserves ordinary direct delegation.
A complete contract authorizes implementation only; it does not replace the task's selected delivery path, validation, review, or merge authority.

Settled decisions and acceptance criteria in a complete brief are authoritative for the implementation worker.
If implementation discovers a new material contradiction or decision that the aligned contract does not settle, the worker must stop and escalate it with the existing keyed `needs-decision` and captain-hold lifecycle rather than silently choosing a direction.
A mechanical implementation detail that does not change the aligned outcome remains the worker's engineering discretion.

Do not add a parallel alignment database, provider configuration, state store, or worker kind.
Use the existing brief, Secondmate-local report, GitHub handoff issue, backlog, status/document-pointer, and captain-hold primitives.
