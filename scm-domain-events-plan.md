# SCM domain events — idea draft

Status: SUPERSEDED 2026-08-10 — the byte-plane split shipped this
(see `byte-plane-split-plan.md`, phase 3). What landed: qits-githost
publishes `SCMPublishCommit` (head metadata + suppressCi),
`SCMPublishTag`, `SCMDeleteBranch`, `SCMDeleteTag` through the
eventstream outbox with causation; qits-ci consumes durably
(`ci-push-runs`, event id = the run's trigger); qits-projects consumes
all four for backup pushes. One idea from this draft is deferred by
design, not dropped: versionsort dedupe of a multi-tag push belongs in a
future tag-triggered CONSUMER (the publisher emits every fact — the
backup listener needs them all), mirroring CI's per-branch supersede.

Original draft below, kept for the record.

Status: rough draft, written before the current refactoring settled.
Do not treat any repo/module names here as verified — refine this prompt
once qits-git is split out and the byte-plane work has landed.

## Basic idea

1. Make qits-events more central to the whole building and releasing
   infrastructure.
2. Remove the old git-event trigger style, replace it with domain events.
3. qits-git (currently being split out of qits-[platform-]artifacts)
   dispatches:
   - `SCMCommitEvent(branchName=…, author=…, and other git metadata)`
   - `SCMTagEvent(tag=…, metadata)`
4. qits-ci listens to those events.
5. Dedupe events received at the same time: if a push brings 5 tags,
   dispatch only the last `SCMTagEvent` (last according to versionsort).

## Scope

- Limited to the new git host and the (I think still happening) local
  clone of the projects that enables git event triggers like
  "commit received".
- Part of the change: switch all commit pipelines to the new domain
  events.
