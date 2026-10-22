# Development flow

This is a live brief for an agent working in this project — read it in a minute,
then work. It is not retired-plan residue: the other files in `docs/` are notes
kept from plans that have been verified and closed, and they say so in their
first paragraph. This one describes how work moves through the platform today,
and it stays current.

## A branch per slug

Work happens on a branch named for the thing you were given: `ticket/<slug>`,
`epic/<slug>` or `task/<slug>`. The same branch name is taken in this wrapper
and in every submodule you touch — one name across the whole stack, as
`README.md` sets out under "How code is iterated" and as `WORKSPACE.md` opens by
restating for this checkout. Commit each change in the
repository it belongs to: a change to a service is a commit in that service's
repository, and the wrapper only ever carries wrapper content.

## A commit is a push

The workspace daemon (`OriginSync` in qits-workspace-daemon) pushes every agent
branch that has commits the git host lacks — the wrapper branch and any branch
made in a submodule — with the agent's own credential, within seconds of the
commit: it polls and is nudged at every harness hook. Nobody runs `git push`.

- A local commit on your ticket, epic or task branch counts as published:
  review the diff before `git commit`, not before a push.
- Fix a mistake with a new commit. Never amend, rebase or reset a commit
  that is already pushed: the daemon never force-pushes, so a rewritten
  branch diverges from origin and quietly stops syncing.
- A push you did not make is the daemon doing its job, not a subagent or
  another actor; `git log origin/<branch>` shows what landed.
- A commit on a detached HEAD is never pushed: each submodule worktree
  starts detached at `origin/main`, so a submodule commit reaches the host
  only once it sits on your branch (`git switch -c <your branch>` first).
  The default branch is never pushed either.

## Name everything by its full id

Whenever you name something the platform tracks, write its full qualified id,
in everything a person or another agent reads: reports, comments, commit
messages, tickets and handoffs.

- A work item is `<project>-<n>`, for example `qits-1178`. Never `1178`, `#1178`
  or "the ticket".
- A release request is `<repository>-rr-<n>`, for example
  `qits-workspaces-service-rr-165`. Never `rr-165`: the number counts per
  repository. `create` prints the qualified id first, and `-o json` carries it
  as `qualifiedId`.
- Anything known only by a uuid gets the full uuid, or the 8-character prefix
  together with what it is and where: "qits-ci run `9677c59a`", not
  `9677c59a`.

An abbreviation that is clear to you is ambiguous to the next reader, who has
no way to tell which repository or project you meant.

## Commit subjects name the work

Every commit subject names the ticket, epic or task it belongs to, by
qualified id: `term(<project>-<n>): message`, for example
`feat(qits-1337): refuse malformed commit subjects`. The term is free (feat,
fix, docs, chore...). The id is the one the dispatch prompt names, and the one
`qits work` shows. qits-githost refuses a push with a malformed subject, but
only on a repository whose default branch carries
`.config/qits/commit-subjects.yml` with `enforce: true`; most repositories do
not yet. Merge commits and pushes by platform automation are exempt: qits:system
service clients (release folds, workspace integrations) and qits:ci-run
(maintenance bumps). When the guard refuses a commit you cannot rewrite,
`git push -o qits.subject-bypass="<why>"` is the break-glass, and every use is
recorded and readable at qits-githost
`GET /githost/api/repositories/{id}/commit-subject-bypasses`. `measureCommitSubjects`,
a repository MCP tool, or `GET /projects/api/repositories/{id}/commit-subjects`
in qits-projects, reports which recent commits on a repository comply.

## A release request per repository, and it is the only way to ship

Nothing reaches the running platform because you pushed it. For each repository
you changed, ask for its branch to be released:
`qits release-request create --project <project> --repository <repository>
--branch <your branch> --summary '<what this release is>'`.
`qits release-request list` shows what is open for a repository, and
`qits release-request join --request <id> --branch <your branch>` adds your
branch to a request that is already open. If a request is open, join it — do not
wait for it to finish and do not open a second one beside it. `WORKSPACE.md`
carries the same door as a plain HTTP call, with the curl body, if you ever need
it without the CLI.

A request's state, verbatim from `qits release-request --help`: PENDING (waiting
for its builds), READY, RELEASED (the tag is cut, waiting on its remaining
gates), FINALIZED (the tag is merged into main, done), REJECTED (a gating build
was red), FAILED (the release itself failed), CONFLICTED (the branches do not
merge), WITHDRAWN, and OBSOLETE (a later request for the repository superseded
this one before it finished).

A REJECTED or CONFLICTED request comes back by itself when one of its source
branches gets a new push. Fix the branch and push; do not open a second request.
When a build was red through the platform's fault rather than the code's — a
flaked container, a registry that was down — retry that run with
`qits ci retry <run id>`, and find the runs with
`qits ci runs --release-request <id>`. `withdraw` is only for a request that
must not ship, because the change is wrong or nobody wants it any more:
WITHDRAWN is final.

## Waiting for a request or a run: declare it and end your turn

A release takes minutes to hours. Do not poll for it, in a loop or by hand, and
do not sit idle at the prompt: an agent that ends its turn with nothing declared
reads as blocked on a person. Declare what you wait on and end your turn:

    qits wait release-request <request id>   # any final state: FINALIZED, REJECTED, FAILED, ...
    qits wait ci-run <run id>
    qits wait work <work id> --status VERIFIED --timeout 2h

The command returns at once. While the wait is open, your work item reads
"waiting on" its label, not blocked. When the request, run or item reaches what
you named, or the timeout passes, the platform gives you a new turn that says
which. Then carry on: a REJECTED request means fix and push, then wait again.
`qits wait list` shows your open waits and `qits wait cancel <id>` ends one.

## Open them early; do not batch

Open each repository's release request as soon as that repository's part is
ready. The platform is resource-restricted, and a request you hold back so it
can go out together with others lengthens every cycle behind it — yours and
everybody else's. Ship the piece that is done.

## The gate

A release request folds `main` with its source branches and builds that fold.
The repository's `.config/qits/release.yml` returns the verdict, and a green
verdict is the whole quality gate: every step of that pipeline gates and no step
may opt out (`README.md`, "Branching model"). There is nothing else to satisfy
and nothing to bypass.

That gate runs the whole suite, so do not run it locally first. Before you push,
run only the tests you know your change affects — the new ones and the existing
classes covering the code you touched — on a best-effort basis, and leave the rest
to the gate. A full local run duplicates work the release request is about to do,
on a platform where that capacity is shared.

For a deployable service the primary gate is a successful deployment. Such a
repository is FINALIZED into `main` only once the deployer reports that version
live; a repository that declares no `.config/qits/deployments.yml` — a library,
an SPA, a docs repo, this wrapper — is finalized at the release itself, because
nothing will ever deploy it (same section). So `main` moves last, and
merged is not released: a branch that merged proves nothing until its version is
live.

## Libraries pull their consumers along

When a library releases, you do not go around updating the things that depend on
it. qits-maintenance notices the new version, commits the bump onto a
`maintenance/*` branch in each consumer, and that branch goes through a release
request like anything else. Forcing this by hand is for work that genuinely
cannot wait. Never move a pin or a submodule gitlink yourself — the bump owns
it, and a hand-written pin is overwritten by the next one.

## Verify each deliverable on the running platform

For every deliverable, check it on the live platform, as far as is sensibly
doable without causing data loss or disturbing somebody else's work. Call the
endpoint, look at the page, read the event, query the logs. A passing test suite
is not the claim being made: the claim is that the behaviour is there in the
environment, and only the environment can answer it.

## Transition when the phase is done

When a phase is finished, transition the ticket or epic with the transition
tool. A transition normally hands you the next phase's instruction in the same
session, so it is not bookkeeping you do afterwards — it is how you are given
your next task. Transition when you are done, and read what comes back.

A phase that does not finish has two other words, and neither of them is a
status you fake. If the phase cannot go on — waiting on somebody, on a
decision, or on a door that is shut — **block it** with `block_entity`, for a
ticket, an epic or a campaign alike, and say what is in the way: the reason is
required, it lands on the thread, and while the flag is set nothing dispatches
an agent onto that phase again. It is temporary and scoped to the phase it
blocks, so the next transition clears it. Moving a status back corrects a
claim that turned out wrong; it is never how a phase reports that it failed.
A verification that finds a defect it can fix is not stuck either: fix it on
the same branch, release it and verify again, with the item left at
VERIFYING. Block only for what you cannot resolve yourself — a decision only
a person can make, a door your credential cannot open, or someone else's
unreleased work. If the work is not stuck but has been decided against,
**drop the ticket**: `DROPPED` is reachable from
every status that is not already closed, and it is what stops abandoned work
from sitting at `REFINED` looking like work that is ready to be picked up. A
dropped ticket reopens to `REPORTED`, because changing your mind about
abandoned work means asking again what it is for.

## The workspace is resolved last

Only once every component you touched has been released, and the ticket or epic
has been transitioned to VERIFIED, do you trigger the release or integration of
the workspace. There is no `qits workspace` verb — `qits --help` lists none —
and for the workspace branch the mechanism is this wrapper repository's own
release request: a release deletes its source branches, and a workspace branch
that is gone is a workspace that is resolved. That is the signal the work is
closed.

This is emphatically **not** the end of the implement phase. A ticket's implement
instruction forbids integrating the workspace, because the verification that
follows runs in this same workspace and needs it alive. For an epic, "integrate
the workspace" means at the end of the whole epic, not at the end of a task
inside it. When in doubt, leave the workspace standing: somebody can always
resolve it later, and nobody can bring it back.
