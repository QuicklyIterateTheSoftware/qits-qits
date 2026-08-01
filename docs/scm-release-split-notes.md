# The SCM-release split: what survives the retired plan

Shipped and observed 2026-08-01; the plan was verified fully implemented (every id reproduced
live) and retired the same day. Contracts live in the repos: qits-workspaces (SCMRelease,
ReleaseIntegrator, gitmirror), qits-ci (artifacts: declarations, SoftwareRelease), qits-artifacts
(the latest guard, the tag-push tests). These arguments and the measured chain had no other home.

## The measured chain (compressed; verified twice, at ship and at retirement)

npm: release `2026.801.85149`/`21655ba4` on qits-spa-ui-components → annotated tag `69f6181f` →
`SCMRelease c5edabb5` → release run `9e62191e` publishes the real version, `latest` moves forward
→ `SoftwareRelease 0bdbe98d {npm, "@qits/ui-components"}` (parent `c5edabb5`) → spa-home bump run
`5d42b91f` → maintenance run `e55d9131` → spa-home release `2026.801.85249` → `SCMRelease
8e1520bf` with NO children (no release pipeline — the designed stop).
docker: qits-stt `2026.801.85448`/`ccd55834` → tag `7ec49abb` → `SCMRelease 7bb9fc99` → release
run `df62403a` → manifest `qits/qits-stt:2026.801.85448` HEAD 200 → `SoftwareRelease f99998d3
{docker, "qits/qits-stt"}`. Causation is a fork: one SCMRelease → BuildSuccessful + one
SoftwareRelease per artifact, same instant (N+1 siblings).

## Arguments recorded only here

1. **Why tag pushes are not a CI trigger (the ⚖1 pricing, not just the decline).** Relaxing the
   git host's `refs/heads/*` filter and changing the intake wire format move together — the wire
   `{repoId, branch, oldSha, newSha}` has no ref field, and the naive filter removal turns
   `"refs/tags/v1".substring(11)` into `"1"`. Two services' wire change, to buy a duplicate CI
   run per release. The event path costs nothing; a step fetches the tag itself.
2. **The outbox drains renamed events under the OLD name.** Outbox rows persist the event name as
   a String, so a row enqueued before a class rename replays with the pre-rename name after
   cutover. This is why any event rename's rollout must drain/verify-empty the outboxes before
   deploying the renamed publisher (executed as rollout step 2; the reason lives here).
3. **Peel annotated tags at the git-host boundary if tags ever drive anything.** An annotated
   ref resolves to a TAG object; storing that sha where a commit id is expected
   (`CiRun.commitSha` → `BuildSuccessful` → `ImageRefs`) surfaces as IMAGE_MISSING far from the
   cause, because the pipeline tagged the image with the peeled commit sha.
4. **Deterministic event ids must also derive `occurredAt`.** qits-events' idempotency comparison
   includes `parentId` (and occurredAt), so a replayed PUT with a derived id but a fresh
   timestamp is a 400, not a no-op.

Two connective facts: the artifact DECLARATION (vs step emission) exists because the daemon
return channel is only StepChunk/StepFinished with a 64 KiB rolling output tail and a
stdout-sentinel is forbidden by design; and the N+1 fork shape above is the one-sentence summary
of machinery spread across three files.
