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

## Local alignment session path

For local alignment, Firstmate resolves exactly one project and one coherent topic, then runs `bin/fm-alignment-session.sh start` to lease a fresh isolated session.
The session uses the locally configured alignment harness, model, and effort, and is not entered in `data/secondmates.md` as a persistent Secondmate.
The captain may converse directly with that one ephemeral executor for that one topic only.
Firstmate owns routing, archive retention, and cleanup, but must not relay or reconstruct the detailed conversation.
Ordinary implementation crewmates remain non-captain-facing.

The session charter contains the current project knowledge first and a compact deterministic inventory of retained alignment metadata second.
The owner index is repository-bounded and preserves multiple current owners across project scopes.
Declarations remain available unless an explicit contract identity proves incompatible authority over the same scope and contract, in which case the competing declarations are surfaced as conflicts.
It does not load every historical report, and Firstmate does not rank report bodies semantically.
The executor may explicitly retrieve one relevant historical report with `bin/fm-alignment-session.sh retrieve <project> <historical-session-id> --archive-home <parent-home>`.
The session can read the resolved project's repository and documentation, but its charter forbids project edits, commits, pushes, and direct knowledge promotion.

The executor writes the outcome, never a transcript, to `data/<session-id>/report.md`.
A session report must include project identity, alignment identity and topic, the seven existing semantic sections, and a separate `Durable-knowledge candidates` section.
Before completion, it runs `bin/fm-alignment.sh validate-report <report> --complete --session <id> --project <name>` and passes `captain-hold-lifecycle`'s completion gate for every genuine captain-owned decision.
The final open-decision section must explicitly say `None - no material open decisions remain.`.

The executor then uses the existing uncorrelated `complete-direct` pointer for a direct local session, or the existing correlated `fm-secondmate-report.sh --doc` route for a marked request.
The parent runs `bin/fm-alignment-session.sh retain <session-id>` and must durably copy the validated report into its project archive before cleanup.
Launch acknowledgement proves endpoint and instructions delivery only, while executor-authenticated preflight acknowledgement separately establishes semantic readiness.
Retention requires that readiness acknowledgement and the project and archive inventory to match its accepted snapshot.
For a mutable session, the parent uses `bin/fm-alignment-session.sh reconcile <session-id>` to publish a pending refreshed context, then the bound executor acknowledges that snapshot before retention.
A completed immutable outcome cannot be refreshed in place after a later delta; start a revised session and explicitly supersede the earlier report.
A non-empty incomplete abandonment is retained as explicitly abandoned historical evidence and cannot authorize implementation, while an empty scratch session may be closed without an archive.
`inventory` reads archive metadata only, while `retrieve` is the explicit body-read operation.
A successful fresh launch records an observable launch acknowledgement after endpoint and instructions delivery confirmation, but leaves semantic readiness pending until the executor completes and authenticates its current-owner preflight.

A later report may pass `--supersedes <session-id>` to `retain`.
The earlier report remains immutable historical evidence, while any current-knowledge or ADR change is only a candidate until Firstmate routes a normal authorized project task.
Use `bin/fm-alignment-session.sh promote` to compile the accepted outcome into an ordinary ship brief; it never writes project documentation or launches a captain-facing implementation worker.

If the captain owns a remaining choice, use `bin/fm-captain-hold.sh hold` in the home that owns the work, report the keyed decision, and stop the alignment completion path until the captain's actual answer is recorded.
Do not report a complete alignment while a material captain-held decision remains open.

Already-provisioned persistent Secondmates retain the non-default `bin/fm-alignment.sh start` and `complete-direct` compatibility path when the captain explicitly requests direct alignment.
New local alignment intake must use the fresh session path above rather than assuming or provisioning a persistent Secondmate.

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

Do not add a parallel alignment database, state store, or worker kind.
The optional alignment harness/model/effort pin belongs only in local configuration, as the configuration reference documents.
Use the existing brief, parent-owned alignment archive, GitHub handoff issue, backlog, status/document-pointer, and captain-hold primitives.
