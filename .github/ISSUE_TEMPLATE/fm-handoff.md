---
name: Firstmate handoff
about: Implementation-ready handoff for the local Firstmate system
title: "[FM] "
labels:
  - fm-handoff
---

<!-- fm-handoff:v1 -->

# Firstmate handoff

## Goal

Describe the outcome that should exist when this work is complete.

Keep this outcome-focused. Do not prescribe implementation details unless they
have already been deliberately decided.

## Context

Explain why this work is needed.

Include the user-visible problem, technical motivation, or background necessary
for someone who did not participate in the original discussion.

## Decisions already made

List only decisions that should constrain implementation.

- Decision:
  - Rationale:
  - Consequences:

If no implementation-constraining decisions have been made, write:

`None — implementation approach remains open.`

## Acceptance criteria

- [ ] Observable criterion 1
- [ ] Observable criterion 2
- [ ] Required tests or validation, if already known
- [ ] Compatibility / migration requirement, if applicable

Acceptance criteria should describe what must be true, not how the worker must
implement it.

## Constraints

List requirements that must be preserved, for example:

- backwards compatibility
- public API compatibility
- performance limits
- security or privacy requirements
- supported environments
- dependencies that must or must not be introduced
- explicitly out-of-scope work

Write `None` if there are no special constraints.

## Evidence and relevant code

Provide concrete evidence from the discussion or repository when available.

Examples:

- `path/to/file.ext` — why it is relevant
- `SymbolName` — observed behavior
- failing command or test
- log excerpt or error message
- related issue / PR
- documentation or specification
- benchmark or reproduction steps

Prefer primary evidence over conclusions.

## Open questions

List questions that are genuinely unresolved and could materially change what
should be built.

Write:

`None — ready for implementation intake.`

if no further design or investigation is required before Firstmate can choose
an implementation path.

## Out of scope

List work explicitly excluded from this handoff.

Write `None` if not applicable.

## Handoff

**State:** Ready for Firstmate intake.

Firstmate should preserve the goal, settled decisions, constraints, acceptance
criteria, and explicitly stated scope from this issue.

Firstmate should independently choose task decomposition, worker capability,
model/effort, implementation details, and delivery sequencing unless this issue
explicitly constrains them.

If unresolved requirements, architecture, root cause, or task boundaries could
materially change what should be built, Firstmate should investigate or request
specialist input before committing to implementation.

See `.github/firstmate/HANDOFF_PROTOCOL.md` for the shared handoff protocol.
