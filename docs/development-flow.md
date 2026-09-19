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
