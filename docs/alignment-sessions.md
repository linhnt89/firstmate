# Local alignment sessions

Local alignment is a short, captain-facing conversation scoped to one resolved project and one coherent topic.
Firstmate starts it with `bin/fm-alignment-session.sh start` and leases an isolated home without creating a persistent Secondmate route.
The configured alignment harness, model, and effort are read from the captain-private `config/alignment-harness` file, whose values are never part of the shared protocol.

## Lifecycle

The session receives the AGENTS instruction chain and a compact, deterministic index of current documentation owners first, followed by a compact, deterministic metadata inventory of prior alignments.
The AGENTS chain is bounded by the resolved repository root, and tracked prose paths are resolved relative to that root before being scoped to the project.
`context-owner:` and `owner-pointer:` declarations in the project AGENTS chain, plus optional project-local pointer files, identify explicit owners before fallback document candidates.
Candidates are not treated as authoritative.
Existing authoritative owners and this owner chain take precedence.
Multiple current owners are preserved across their declared project scopes.
Declarations remain available unless an explicit `contract=<id> <path>` identity proves that different files claim incompatible authority over the same scope and contract, in which case all competing declarations are surfaced as conflicts.
No pointer file is required.
The strong executor lazily inspects relevant indexed owners before declaring readiness.
Large required owners remain navigable at their project paths without silent omission or truncation, and audience labels do not determine authority.
The inventory contains no historical report bodies, and Firstmate does not semantically rank them.
The executor may use `bin/fm-alignment-session.sh retrieve <project> <session-id> --archive-home <parent-home>` for one explicitly relevant historical report, using the parent Firstmate home that owns the archive.
When the parent uses a configured alternate data root, the command also passes `--archive-data <parent-data-root>`.
The generic retrieval shape is `bin/fm-alignment-session.sh retrieve <project> <historical-session-id> --archive-home <parent-home> --archive-data <parent-data-root>` after inventory identifies a relevant prior session.
A fresh launch records an observable launch acknowledgement after the worker endpoint and instructions delivery have been confirmed, but semantic readiness remains pending.
After inspecting relevant current owners, the executor authenticates a preflight acknowledgement before it can report substantive readiness or complete the outcome.
If project knowledge or the historical inventory changes while the outcome is still mutable, run `bin/fm-alignment-session.sh reconcile <session-id>` to publish a pending refreshed context, then require the executor's authenticated reconciliation acknowledgement before retention.
A completed immutable outcome cannot be refreshed in place after a later delta; start a revised session and explicitly supersede the earlier report.

The executor writes a validated report rather than a transcript.
The report identifies the project, session, topic, source, and the existing alignment sections, followed by a separate durable-knowledge-candidates section.
A direct local executor returns through the existing uncorrelated `bin/fm-alignment.sh complete-direct` pointer.
A marked external or parent-routed request continues to use the existing correlated GitHub handoff and status protocol.

Firstmate retains a completed report with `bin/fm-alignment-session.sh retain` in `data/alignments/<project-key>/<session-id>/` before `close` removes the ephemeral home.
Archive metadata binds the retained report content digest and the project, session, topic, and archive-key identities before cleanup can proceed.
`inventory` enumerates only retained metadata for one project, so historical artifacts are deterministic and project-associated.
A close without a retained completed report is refused unless Firstmate explicitly closes an abandoned session with `--abandon`.
Abandonment remains safe even when an incomplete session is stale, retaining non-empty incomplete evidence as an explicitly abandoned, discoverable, non-promotable archive before cleanup; a truly empty scratch session may close without an archive.

## Knowledge layers

Historical alignment reports preserve the decisions and rationale discussed at one point in time.
They are evidence for selective retrieval and are not current project truth.

Current project domain knowledge belongs in the project's existing authoritative documentation owner, such as product, architecture, specification, or domain documentation.
It describes current terminology and semantics and excludes session chronology and implementation-only detail.
A context document is created only when no existing owner is suitable, and its filename is project-specific rather than universal.

An ADR or equivalent current decision record is reserved for a consequential, difficult-to-reverse, or non-obvious decision whose rationale should remain discoverable.
A durable-knowledge candidate in a report is only a proposal and is not an ADR or canonical domain knowledge.

Implementation artifacts are ordinary briefs, branches, tests, and project changes produced through the selected delivery path.
Historical reports are immutable evidence, canonical domain knowledge describes current terminology and semantics, ADRs preserve consequential decision rationale, and implementation artifacts are delivered code-work products; none substitutes for another.
`bin/fm-alignment-session.sh promote` compiles the accepted report into an ordinary ship brief without editing project documentation or launching a captain-facing implementation worker.
Knowledge promotion therefore receives normal project review, validation, delivery, and merge authority.

## Supersession

A later retained session may name an earlier session with `--supersedes`.
Before retention, the parent requires the project and archive inventory to match the last executor-acknowledged snapshot.
The earlier report remains unchanged in the archive, while the later report and archive metadata identify the historical relationship.
Updating current project knowledge is a separate authorized project task and never a direct write from the alignment session.

The existing `unclassified -> bypassed | required -> complete` implementation barrier remains authoritative.
An aligned outcome can lead to implementation, a knowledge-only follow-up, both, or neither, and no outcome is inferred from a conversation transcript.
