<!-- fm-pr-handoff:v1 -->

# Implementation handoff

## Source

Primary issue / handoff:

- Closes #
<!-- Replace with "Relates to #" when the PR should not close the source issue. -->

Other related issues / PRs:

- None

## Intended outcome

Briefly restate the part of the source issue this PR implements.

Do not copy the complete design history from the issue. The source issue remains
the durable record for requirements, decisions, and discussion.

## Implementation

Summarize the important implementation choices.

- Change:
  - Why:
- Change:
  - Why:

## Deviations from the source issue

Describe any intentional deviation from the source issue, its acceptance
criteria, constraints, or settled decisions.

Write:

`None.`

if there are no deviations.

If a deviation changes an earlier settled decision, record a corresponding
decision update on the source issue according to
`.github/firstmate/HANDOFF_PROTOCOL.md`.

## Validation

Check only what was actually run or verified.

- [ ] Relevant automated tests
- [ ] Build / compilation
- [ ] Type checking
- [ ] Lint / static analysis
- [ ] Manual verification
- [ ] Migration / rollback validation, if applicable
- [ ] Benchmark / performance validation, if applicable

Commands and results:

```text
# command
# result / exit status
```

Important evidence or artifacts:

- None

## Known limitations and unresolved questions

Write:

`None.`

if there are no known limitations or unresolved questions.

Otherwise list them explicitly and state whether they block merge.

## Implementation origin

Select the closest match:

- [ ] Firstmate-supervised worker
- [ ] ChatGPT Web / external specialist implementation
- [ ] Human implementation
- [ ] Other external implementation

If implementation originated outside the local Firstmate workflow, this PR is
incoming implementation only. It is not considered complete merely because the
code was committed or a PR was opened. The local delivery path must still
perform the required validation and review.

## Review focus

List areas where reviewers should spend disproportionate attention.

- None

For an external specialist review, follow the PR review request/response
conventions in `.github/firstmate/HANDOFF_PROTOCOL.md`.
