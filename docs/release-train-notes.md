# The release train: design history rescued from the retired hops plan

Shipped and observed 2026-07-31/08-01; the plan was verified fully implemented and retired
2026-08-01. The shipped shape is documented in qits-ci-service's README (branches: filters, skip
semantics, loop footguns) and qits-workspaces-service's AGENTS.md (/branches/release). The
bump/maintenance conventions lived in qits-spa-home's README, which went with that repository when
it was archived. This is the record of the road not taken.

## Why branch filtering is a STEP key, not a pipeline key

The first draft scoped whole pipelines: a top-level `branches:` key plus a `ci-post-receive-*.yml`
file family so one repo could carry a test pipeline and a maintenance pipeline side by side. The
user's counter-proposal — the matcher moves onto the step — replaced it, and won on evidence:

- Sequencing came free: "integrate only after green tests" is exactly what step order inside one
  run already means; the family needed two runs per maintenance push with no way to couple their
  verdicts short of a run-dependency feature.
- The draft's dilemma dissolved: pipeline-level scoping forced choosing between a redundant full
  test run per maintenance push OR scoping the default file to `main` and losing feature-branch
  CI. Step-level pays neither.
- The engine barely changed: no file-family discovery, no run-level accept/discard changes. A
  filtered STEP is recorded (SKIPPED with a note), which is more honest than a run-level discard.

Pipeline-level filtering was deliberately NOT kept as a dormant second mechanism: one filtering
concept, at the step. A future need that `exact`+`prefix` cannot spell reopens the vocabulary in
a plan, not in the parser.
