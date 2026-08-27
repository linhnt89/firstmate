# Local alignment sessions

Local alignment is a short, captain-facing conversation scoped to one resolved project and one coherent topic.
Firstmate starts it with `bin/fm-alignment-session.sh start` and leases an isolated home without creating a persistent Secondmate route.
The configured alignment harness, model, and effort are read from the captain-private `config/alignment-harness` file, whose values are never part of the shared protocol.

## Lifecycle

The session receives the current project knowledge first and a compact, deterministic metadata inventory of prior alignments second.
The inventory contains no historical report bodies, and Firstmate does not semantically rank them.
The executor may use `bin/fm-alignment-session.sh retrieve <project> <session-id>` for one explicitly relevant historical report.

The executor writes a validated report rather than a transcript.
The report identifies the project, session, topic, source, and the existing alignment sections, followed by a separate durable-knowledge-candidates section.
A direct local executor returns through the existing uncorrelated `bin/fm-alignment.sh complete-direct` pointer.
A marked external or parent-routed request continues to use the existing correlated GitHub handoff and status protocol.

Firstmate retains a completed report with `bin/fm-alignment-session.sh retain` in `data/alignments/<project>/<session>/` before `close` removes the ephemeral home.
`inventory` enumerates only retained metadata for one project, so historical artifacts are deterministic and project-associated.
A close without a retained completed report is refused unless Firstmate explicitly closes an abandoned session with `--abandon`.

## Knowledge layers

Historical alignment reports preserve the decisions and rationale discussed at one point in time.
They are evidence for selective retrieval and are not current project truth.

Current project domain knowledge belongs in the project's existing authoritative documentation owner, such as product, architecture, specification, or domain documentation.
It describes current terminology and semantics and excludes session chronology and implementation-only detail.
A context document is created only when no existing owner is suitable, and its filename is project-specific rather than universal.

An ADR or equivalent current decision record is reserved for a consequential, difficult-to-reverse, or non-obvious decision whose rationale should remain discoverable.
A durable-knowledge candidate in a report is only a proposal and is not an ADR or canonical domain knowledge.

Implementation artifacts are ordinary briefs, branches, tests, and project changes produced through the selected delivery path.
`bin/fm-alignment-session.sh promote` compiles the accepted report into an ordinary ship brief without editing project documentation or launching a captain-facing implementation worker.
Knowledge promotion therefore receives normal project review, validation, delivery, and merge authority.

## Supersession

A later retained session may name an earlier session with `--supersedes`.
The earlier report remains unchanged in the archive, while the later report and archive metadata identify the historical relationship.
Updating current project knowledge is a separate authorized project task and never a direct write from the alignment session.

The existing `unclassified -> bypassed | required -> complete` implementation barrier remains authoritative.
An aligned outcome can lead to implementation, a knowledge-only follow-up, both, or neither, and no outcome is inferred from a conversation transcript.
