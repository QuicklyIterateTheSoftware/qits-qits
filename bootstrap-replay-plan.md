# Bootstrap replay semantics — plan

Written 2026-08-12, from the user's dictated design narrative plus the session's
measured findings. The first half is normative — the bootstrap as it was
DESIGNED. The second half is the measured current state and the delta. The work
packages close the delta.

## The designed model (normative)

The bootstrap has two phases with two different jobs.

**Phase 1 — the ad-hoc seed.** Build the minimum locally to get the CI/CD loop
going. The libs are built locally into a local Maven repository, only so the
initial service builds can resolve them. Everything builds from `main`, because
the standing expectation is that **main holds only tested versions**. The seed
set is whatever the loop needs and nothing more — events, artifacts, the
mirror, ci, postgres, and their supporting cast. These containers are
scaffolding: ad-hoc identity, ad-hoc builds, meant to be replaced.

**Phase 2 — the platform rebuilds itself.** With the base infrastructure in
place, ALL qits services — the seed set first, then the rest — are built and
deployed **through the regular release flow**. The seed scaffolding is torn
down piece by piece as the cleanly built successors come up.

**The PoC era and its residue.** Originally phase 2 performed REAL releases,
because the platform was a proof of concept and no releases existed yet — the
PoC runs were what created them. That era is over: the flow has run through
many times, and the releases now exist as durable facts (calver tags on the
git host, `SCMRelease` in the event history).

**Therefore the design's end-state:** the bootstrap no longer performs
releases. It **dispatches the events the releases previously dispatched**, so
the platform builds and deploys itself exactly as if it had always been
running. A bootstrap is a RESTORE of the last-released state, expressed in the
platform's own event vocabulary. Pushing the code and the tags is the input;
the platform's own reactions are the mechanism.

## The current state (measured 2026-08-12)

What the implementation does today, verified against the code and a live
green rebootstrap:

1. **The seed set is twelve services**, started by compose: gateway, edge,
   mirror, artifacts, githost, ci, containers, deployments, idp, dns, events,
   oci-postgresql. Libs are seed-published from local checkouts into the
   temporary registry (maven cache volume as the local repository). Matches
   the design.

2. **Lib restore impersonates a release.** The replay pushes the release tag
   (good — the tag is the durable stamp) but the tag does not trigger
   anything: lib recipes declare `event: SCMRelease`, and `SCMPublishTag`
   selects no recipe anywhere ("tag pipelines selectable, none declared yet").
   What actually starts the publish run is the CLI **fabricating a synthetic
   `SCMRelease`** through ci's manual trigger door
   (`PipelinePhases.java:378`). qits-ci then announces `SoftwareRelease` per
   declared artifact — off any green run, regardless of trigger — and the
   release train reacts as it would to a real release: bump runs in every
   consumer, each ending in a release call against qits-workspaces, **which
   does not exist yet** (it is not a seed service; the train deploys it
   minutes later). Every rebootstrap therefore leaves the same FAILED
   maintenance-branch runs behind (measured: 8 SPA repos red after both
   2026-08-12 boots; the bump content is one-time lockfile canonicalization
   drift, but the failure mechanism is structural).

3. **Phase 2 does not replay releases at all.** The boot pushes each repo's
   local `main` (`-o qits.no-ci`) and `environment/dev`; the env-branch push
   fires an ordinary post-receive build of **main's head** with sha identity;
   `BuildSuccessful` drives the deployer. No `SCMRelease`, no release
   identity, no bookkeeping. Consequences, both known:
   - The boot is a direct-main deploy path. It bit on 2026-08-08 (an
     unreleased stack shipped by accident) and was answered with discipline
     ("keep unreleased work on branches") rather than redesign — and the
     discipline is routinely traded away, because shipping local mains via
     boot became the dev loop.
   - Deployed containers carry sha identity even when main equals the
     release (the standing `:$QITS_CI_SHA` vs `:$version` wart).

## The delta, and what closes it

The design says: dispatch what the release dispatched. The release dispatched,
in order: the branch/tag state in SCM, and `SCMRelease`. Everything after —
the publish run, `SoftwareRelease`, the train, the deploy — is the platform's
own reaction and must NOT be replayed by hand.

The one distinction the design needs which the PoC era never drew: a
**restore** re-establishes SCM state (branches, tags) so the platform
re-derives its artifacts; a **release** additionally announces novelty
(`SCMRelease`), which is what wakes the train. A replay has no novelty to
announce. The event vocabulary already carries this distinction — replays
produce only `SCMPublishTag`; only qits-workspaces produces `SCMRelease` — the
implementation just doesn't use it yet.

### WP1 — libs restore off the tag

Every RELEASE_PUBLISHER's release recipe switches `event: SCMRelease` →
`event: SCMPublishTag`. The versionsort tag dedupe in qits-ci already exists
for this adoption (one run per newest tag). The CLI deletes the synthetic
`SCMRelease` fabrication; the replay becomes: push the tag, wait for the
registry to hold the pin. The publish steps are probe-and-skip in the four
package repos, so warm boots no-op there. CORRECTION (found during
implementation): the three image publishers (`oci-workspace`,
`workspace-daemon`, `projects-daemon`) build and push unconditionally — a
warm replay pays the full image build. Not a regression (the fabricated path
rebuilt them too). Follow-up: give them the publish-if-absent probe; the
working idiom is in `daemons/qits-workspace-daemon/.config/qits/
ci-event-upstream-oci-workspace.yml` (origin from `$QITS_MAVEN_REGISTRY_URL`,
ask `/v2/…/manifests/<version>`; `$QITS_REGISTRY` is not reachable from a
step).

### WP2 — `SoftwareRelease` requires a real release

qits-ci announces `SoftwareRelease` only when BOTH hold: a green publish run
for the version exists, AND an `SCMRelease` for that version arrived. Replays
(tag only) publish silently — no announcement, no train, no bump runs, the
red-tile class is structurally gone. Real releases (tag + `SCMRelease`)
announce after green exactly as today, preserving the split's guarantee that
`SoftwareRelease` means "installable now". Design care: the two events race on
a real release; the join must tolerate either arrival order.

### WP3 — phase 2 restores released identity

The deployables come back AS THEIR LAST RELEASE: the boot pushes branches and
tags; the env ref points at the released commit; builds carry release
identity (`:$version`, resolving the standing wart). Under the design's own
invariant — main holds only tested (released) versions — this builds the same
trees as today; what changes is identity and bookkeeping, not bytes or
duration (the sixteen native builds are irreducible on a cold boot; warm
boots already pull instead of rebuilding).

**The fork — DECIDED 2026-08-12: restore is the default, mains are the
opt-in.** The boot restores last-released versions by default; shipping local
mains needs an explicit flag (`--ship-mains`), which is the dev loop's new
spelling. This also resolves the 2026-08-08 hazard at the root: a local main
ahead of the last release no longer deploys by accident, because the deploy
ref stops following it.

Design sketch (the change is ref selection, not new machinery):
- Local mains are still pushed to the githost (`no-ci`, quiet) — the repos
  need their history and the catalog needs the shape. Harmless now: main
  being ahead no longer deploys.
- Deployable tags are pushed too. Safe: deployables' release recipes stay on
  `SCMRelease`, so a deployable's tag push selects no pipeline; and
  qits-projects' backup consumer wants every tag anyway.
- The deploy ref (`environment/<env>`) points at the commit of the NEWEST
  versionsort release tag per deployable — not at main's head. The
  post-receive build and the `BuildSuccessful` → deployer flow are untouched;
  restore semantics enter through where the ref points.
- A deployable with no release tag at all falls back to main's head with a
  printed warning (the honest cold-start answer).
- `--ship-mains` restores today's behavior: deploy ref = main's head.
- The seed phase stays on main, per the design (main holds only tested
  versions; seeds are scaffolding and get replaced either way).

### WP4 — the leftover heal (one-time, independent)

The 8 SPA repos' pushed `maintenance/*` bump branches get released once
through the workspaces endpoint, so their mains absorb the canonical lockfile
and the bump recipes no-op on every future boot. Do this regardless of
WP1-3 — it removes the recurring red tiles today.

## Definition of done

The bootstrap is finished when, in this order:

1. **all libs have been released** — every RELEASE_PUBLISHER's newest tag has
   a green publish run and the registry holds the artifact every consumer
   pins; then
2. **all services have been released** — every deployable runs its
   last-released version as a deployed (`qits-pd-*`) container, every seed is
   replaced, and the edge answers.

That is already the shape of today's green bar (registry probes, 16 healthy
deployables, edge 200) — the redesign changes what "released" means in it
(release identity instead of main-head sha), not the bar itself.

## Non-goals

- Shortening the cold boot. The builds are the clock in both phases and the
  bytes exist nowhere after a data wipe; replay semantics change identity and
  choreography, not wall-clock.
- Replaying `SoftwareRelease` (or any announcement) directly. Announcements
  are reactions; replaying them would announce artifacts the registry may not
  hold. Only SCM facts are replayed.
- Changing the seed phase. It matches the design.
