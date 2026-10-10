# Pre-run gates: dependency bumps become an automation, and QA waits for the pre-run

USER DECISION 2026-10-09: the release lifecycle is

    pre-run gates → build (Test) → quality gates → publish → deploy → deployment gates → finalized

> "The whole point is to reduce the number of builds. BEFORE it runs the regular tests, do the
> pre-run: verify whether a version bump needs to happen, or the entity diagram needs updating; if
> so, push to their branches; THEN start the build."

Builds on epic qits-978 (VERIFIED, not edited). qits-978 scoped out two things, and this plan
brings both in:

- (a) deferring QA until the automations are fresh;
- (b) group bumps (`maintenance/<group>`).

Ticket: qits-1133.

## What runs today (measured on main, 2026-10-09)

- **Every fold does two things at once.** `ReleaseRequests.remerge` calls `announce(folded)`
  (`ReleaseRequestChanged`, which qits-ci turns into the QA run) and then
  `refreshAutomations`. The automations gate is checked after the CI gate. An automation commit
  re-folds the request and `cancel()` stops the QA run. So a fold that needs an automation commit
  costs a partial QA run.
- **Dependency bumps are a second, separate train.** `SoftwareReleaseListener` and
  `ScmEventListener.onGitlinkReleased` move `mt_latest`. `BumpDispatcher.tick` finds owed
  repositories (pins on **main** ⋈ `mt_latest`), dispatches `maintenance-bump.yml`, which writes
  `maintenance/<group>` (`dependencies` = internal, `external` = third party). A green bump asks
  qits-projects for a release (`ReleaseRequestClient.requestRelease`, priority `LOWEST`). That
  converges onto the repository's one open request. Each push to the group branch re-folds the
  request and restarts QA. The train on 2026-10-09 shows the cost: qits-projects-service carried
  six `bump(dependencies): 5 dependencies` commits in one request.
- **The automation engine** (`AutomationService`) settles each kind per fold: applicability,
  carry-over, plan, row. It never lists NOT_APPLICABLE kinds. Rows are `mt_bump` with
  `mode = AUTOMATION`. At most one run per (request, kind), at most 2 runs estate-wide
  (`MAX_RUNNING`). Automation runs are not cancelled.
- **No repository uses `groups:`** in `.config/qits/maintenance.yml`. Only the wrapper has the file,
  with `ignore: [gitlink]`.

## Decisions

### D1. Two stages inside the pre-run: SOURCE kinds, then DERIVED kinds

qits-978's carry-over rests on "no automation's output is another automation's input". A
dependency bump breaks that: a new `@qits/ui-components` changes the screenshots, and a new
Hibernate can change what the entity diagram generator reads. So kinds get a stage:

| stage | kinds | what it writes | rule |
|---|---|---|---|
| `SOURCE` | `estate-pins`, `dependency-bump` | inputs of the build | always planned (cheap, no carry-over needed); a plan with nothing to change is FRESH with no run |
| `DERIVED` | `screenshot-baselines`, `entity-diagram` | outputs generated from the sources | planned only when every SOURCE kind is FRESH at this fold; until then answered `WAITING` ("waits for Dependency bump"), not stored |

- New interface member `Stage stage()` on `ReleaseRequestAutomation`, default `DERIVED`.
- **Carry-over for a DERIVED kind** counts only DERIVED kinds' paths as automation output. A
  SOURCE kind's commit (a pom, a lockfile) always re-runs the DERIVED kinds.
- **Optional `inputPaths()`** (default: everything). A DERIVED kind is also carried when no
  changed path matches its inputs. `entity-diagram` declares `**/*.java`, `**/*.kt`, `**/pom.xml`.
  This is the main cost guard: a fold that changes no Java and no pom costs no diagram run, and so
  no added wait before QA.
- **Runtime disjointness check.** Per subject, the committable paths of the kinds that apply must
  not overlap. An overlap is UNKNOWN with the sentence naming both kinds (the registry test can only
  check static paths).
- `WAITING` and `NOT_APPLICABLE` become answered states. The trigger and the read list **every**
  registered kind; NOT_APPLICABLE carries its reason. The projects side of NOT_APPLICABLE is already
  written (uncommitted in `/tmp/rr-projects-train-na`); maintenance has to start sending it.

### D2. `dependency-bump` is a SOURCE kind

| | |
|---|---|
| kind / label | `dependency-bump` / "Dependency bump" |
| applies when | `ManifestScanner.pinsAt(project, name, foldSha)` finds at least one actionable pin (maven, npm, docker, gitlink), after the fold's own `maintenance.yml` `ignore:`. A repository with none: NOT_APPLICABLE "no manifest the scan knows". An unreadable fold: UNKNOWN. |
| plan | pins **at the fold** ⋈ `mt_latest`, through `PendingChanges.newerVersion` (same prerelease and order rules). Nothing newer: FRESH, no run. Else RUN with the change list in `extras.changes`. Cached per fold sha (one `pinsAt` per fold). |
| which pins | see Q1. Default proposal: a request with a person's branch gets INTERNAL pins only; a request with no source besides main and `maintenance/automations/**` (one maintenance opened) gets INTERNAL and EXTERNAL. Derived from `subject.sourceBranches()`, no flag. |
| pipeline | `ReleaseRequestAutomation` (the shared core), kind file `automations/dependency-bump.yml` on `node-base`. Its script is the apply part of the one-step `maintenance-bump.yml` on qits-ci `one-commit-bumps` (maven by awk, npm install, docker re-tag, gitlink update-index). |
| target | `OWN_BRANCH` → `maintenance/automations/dependency-bump/<rr>`, cut from the fold, ONE commit per run, plain push (the fold contains the previous head, so the push is a fast-forward). |
| commit | `bump(<item or dependencies>): <n> dependencies`, one body line per change. The core gains one hook: a kind script may write the message to `$QITS_AUTOMATION_COMMIT_MESSAGE`; the postlude uses it if present. |
| committable paths | per subject: every manifest path `pinsAt` read, plus `package-lock.json` beside each `package.json`, plus gitlink paths. Payload `commitPaths`: only the changed manifests and their lockfiles. |
| join priority | `LOWEST` on the source row it adds. |

**Who owns gitlinks.** `estate-pins` owns every gitlink of a repository it applies to (archetype
`PROJECT`, the wrapper). `dependency-bump` owns gitlinks everywhere else (the `src/main/webui` SPA
gitlinks in services). Enforced twice: `dependency-bump` drops GITLINK pins when the archetype is
`PROJECT`, and the runtime disjointness check (D1) catches any overlap. The wrapper's
`ignore: [gitlink]` stays as the first line of defence.

**Escape for a breaking upstream.** A person adds `hold: [<dependency name>]` to
`.config/qits/maintenance.yml` on their branch; the plan reads it at the fold and leaves that pin
alone. They revert the bump commit in the same push. (`ignore:` stays for whole ecosystems.)

### D3. QA waits for the pre-run (qits-projects)

- **One announce per fold, after the ask.** `remerge` calls `refreshAutomations` **before**
  `announce`. `ReleaseRequestChanged` gains `preRun: PENDING | DONE`. DONE when the ledger is FRESH
  for this sha (no kind applies, all carried, all plans FRESH) or a waiver exists; else PENDING.
  Absent field = DONE, so an older producer means what it means today.
- **qits-ci starts no QA run for `preRun: PENDING`.** The filter sits in `CiEventTriggerService`
  before trigger matching, so composed archetypes and any hand-written
  `ci-event-release-request.yml` both obey it. The UI keeps refreshing on the event.
- **The second announce.** When the ledger turns FRESH for the current `mergedSha` (trigger answer,
  30 s sweep read, or a waiver), projects publishes `ReleaseRequestChanged` again with
  `preRun: DONE`. A new durable column `release_request.qa_announced_sha` makes this exactly once
  per sha, also across restarts (the ledger is in memory).
- **Gate order.** `AUTOMATIONS` moves before `CI`. While it holds, the request says "Pre-run
  running: Dependency bump running, Screenshot baselines waiting" and the CI gate says "waiting
  for the pre-run" instead of "waiting for the build".
- **Sweep.** The 30 s sweep re-POSTs on UNKNOWN, absence, **and WAITING** (a SOURCE kind ended
  NOTHING_TO_DO without a commit, so no re-fold will come; the re-POST settles the DERIVED kinds
  on the same fold).
- **A failed automation holds** (as qits-978): no QA, "Pre-run failed: <kind> (run …); push,
  re-run or waive". A waiver for the fold counts as pre-run done and announces DONE.
- **A source moves during the pre-run.** Re-fold → new sha → pre-run again on the new fold.
  Unchanged kinds carry as today. No QA run exists, so nothing to cancel. Running automation runs
  finish and are recorded against their own fold (qits-978 behaviour); waiting rows of the old fold
  become SUPERSEDED.
- **A source moves during QA.** Re-fold → `cancel()` the QA run (as today) → pre-run on the new
  fold → QA again when it is done.
- The qits-978 guard "a red verdict on a fold whose automations still move holds" stays during the
  rollout (an old-style QA run can still land) and is removed afterwards (piece PR-3).

### D4. Upstream publication

One hook in qits-maintenance, "latest moved for dependency X", called from
`SoftwareReleaseListener` (maven, npm, docker), `ScmEventListener.onGitlinkReleased` (gitlink) and
the daily registry scan (external). Debounced 2 minutes per repository (one release emits several
`SoftwareRelease` frames). For each repository that pins X:

- **Open request, not READY** → re-plan `dependency-bump` on the request's current fold
  (`ReleaseRequestClient.state` gives `mergedSha` and branches). FRESH → nothing. RUN → a row with
  trigger `UPSTREAM`; its commit joins and re-folds the request; that cancels a running QA (user
  wants that), and the pre-run runs again.
- **Starvation guard.** After 3 upstream re-plans of one request that each restarted QA without a
  QA verdict in between, further upstream changes wait for the next request (the owed sweep below).
- **Open request, READY** (gates passed, waiting for approval or the release) → leave it. It ships
  as approved; the owed sweep opens the next request after it releases.
- **No open request** → the owed sweep opens one.

**The owed sweep** is `BumpDispatcher` reshaped. It keeps its gates (qits-ci free slots, `BumpOrder`
bottom of the chain first, quiet hours, the debt-armed window). What it does with a ready candidate
changes: instead of dispatching a group bump, it asks for a **main-only** release request
(`branch: main`, `priority: LOWEST`). The first fold runs the pre-run, which writes the bump. If
that `dependency-bump` answers FRESH and the request still has no source besides main (an unmerged
tag already carried the bump), maintenance withdraws the request it opened. A candidate is held
while its own request is open, as today's hold does for group rows.

### D5. Retire `maintenance/<group>`

- Groups go: `GroupConfig` keeps `ignore:` and gains `hold:`; `groups:` is refused with a sentence
  (nobody uses it). The `dependencies`/`external` split survives only as the Q1 rule.
- **Cutover migration** (maintenance release with the switch flipped):
  1. group dispatch stops (no new `maintenance/<group>` pushes);
  2. an open request that has a `maintenance/<group>` source releases as it is; its pre-run sees the
     pins already bumped (FRESH) or newer ones (writes them on its own branch). The release deletes
     the group branch, as today;
  3. a `maintenance/<group>` branch on no open request (withdrawn, stalled, rejected) is listed by a
     one-off sweep, its `mt_branch` row closed, and the branch deleted. The repository is then owed
     again and the owed sweep opens a request;
  4. `mt_bump` GROUP rows stay readable as history (`BumpMode.GROUP` stays as a word).
- Retired after the cutover: `POST /repositories/{name}/groups/{group}/bumps`, `/bumps/window`
  (GET/POST/DELETE), `BumpSchedule`, the group arm of `maintenance-bump.yml` (the estate-pins
  TARGETED arm stays) and of `RunGitRefs`, the qits-githost allowance for `maintenance/<group>`
  pushes (qits-955), and the maintenance frontend's bump window page.

### D6. Wire and UI

- **qits-maintenance answer** (`ReleaseRequestAutomationsDto`): every registered kind, with
  `stage` and states `FRESH | REQUESTED | RUNNING | COMMITTED | FAILED | UNKNOWN | SUPERSEDED |
  WAITING | NOT_APPLICABLE`.
- **qits-projects `ReleaseRequestDto`** gains `preRun: {state, foldSha, detail}`:
  - `PENDING`: folded, not asked yet, or the answer is UNKNOWN;
  - `RUNNING`: some kind REQUESTED, RUNNING, COMMITTED or WAITING;
  - `FAILED`: some kind FAILED (a hold);
  - `PASSED`: every applicable kind FRESH (no kind applying included);
  - `WAIVED`: a person waived this fold.
  The QA phase reads `WAITING_FOR_PRE_RUN` (no run) while `preRun` is not PASSED or WAIVED.
- **Landing app.** P1 "Pre-run" = the merge plus every kind; the cog counts merge + applicable
  kinds (`2/3 · 1 skipped`), NOT_APPLICABLE listed with the reason, WAITING drawn as pending with
  "waits for …". P1 and P2 are no longer "side by side": P2 Test shows "waiting for pre-run" until
  `preRun` passes. Today's note "The automations run alongside the test run" goes.
- **CLI.** No command changes. `qits maintenance automations` prints the new states as they come.

## Release order

1. **qits-ci** (additive): `preRun` filter (CI-1), `dependency-bump` kind file and the
   commit-message hook (CI-2). Nothing sends `preRun` yet, so nothing changes.
2. **qits-maintenance R1**: stages, WAITING, NOT_APPLICABLE listing, `inputPaths`, runtime
   disjointness (MT-1); `dependency-bump` kind behind `qits.maintenance.automations.dependency-bump.enabled=false`
   (MT-2); upstream hook and owed sweep behind the same switch (MT-3, MT-4). Group bumps still run.
   With the switch off, the only visible change is NOT_APPLICABLE and WAITING in the answer.
3. **qits-projects** (needs 1 live, or every fold builds QA twice): land the train
   (`external/fold-rebuild` with its qits-githost half, `external/release-gate-classes`,
   `external/rr-phase-race`, the NOT_APPLICABLE work), then pre-run deferral (PR-2). Joined with the
   landing app (LA-1) through the SPA gitlink bump.
4. **qits-maintenance R2 cutover** (MT-5): switch on, group dispatch off, legacy branch sweep.
   Watch one live request per case (below) before step 5.
5. **Retirement** (MT-6, CI-3, GH-1): group code, doors and pipeline arm.

Backward compatibility:

- an old qits-ci with a new projects would build every PENDING announce, so qits-ci goes first;
- an old projects with a new qits-ci sends no field and builds as today;
- the projects on main reads a state word it does not know as UNKNOWN, which holds the request
  (`AutomationRefresh`, `default -> unknown`). So **R1 sends WAITING and NOT_APPLICABLE only when
  the trigger body carries `"accepts": ["WAITING","NOT_APPLICABLE"]`**, which PR-2 adds.

## What to drop from the unreleased branches

| branch | keep / drop |
|---|---|
| qits-maintenance `external/one-commit-bumps` | drop. It rebuilds `maintenance/<group>`, which D5 retires. |
| qits-ci `one-commit-bumps` / `external/one-commit-bumps` | drop the group rebuild (force-with-lease, exit 42, STALE). Keep its one-step apply script as the source of the `dependency-bump` kind file (CI-2). See Q3. |
| qits-projects + qits-githost `external/fold-rebuild` | keep; land first. Carry-over reads changed paths between two folds, which a rebuilt fold still answers. |
| qits-projects `external/rr-projects-train` (gate classes, `qualityGates[]`, phase race, NOT_APPLICABLE) | keep; it is the base of PR-2. |
| `publish-if-changed-plan.md` | keep, independent. It cuts the number of upstream publications, so the number of upstream re-plans (D4). |

## Risks

- **A slow automation now delays every QA.** Mitigations: SOURCE kinds cost no run unless
  something changes; `entity-diagram` carries over folds with no Java or pom change; screenshot
  baselines apply only to qits-landing-app. Measure the pre-run time per repository after the
  cutover.
- **Cap.** `MAX_RUNNING = 2` now sits in front of every QA. Replace it with qits-ci's free slots
  (the read `BumpDispatcher` already makes), floor 1, ceiling half the slots.
- **Stale automation runs are not cancelled.** A person pushing three times keeps up to two slots
  busy with runs for dead folds. Follow-up: let qits-maintenance (`qits:system`) cancel its own
  automation runs in qits-ci.
- **qits-maintenance down = no QA anywhere** (before: QA ran, release held). The waiver is the
  escape, as in qits-978.
- **A breaking upstream blocks a person's request.** Q1 keeps external upgrades out of it; `hold:`
  (D2) is the escape for internal ones.
- **Screenshot baselines do not need a build first.** The kind runs `npm ci` and
  `test:browser` itself, and the entity diagram compiles itself; both duplicate part of the QA
  build. Accepted.
- **Main-only requests.** Verify that maintenance's credential may withdraw the request it opened.

## Implementation pieces (agent-sized)

| id | repo | piece |
|---|---|---|
| CI-1 | qits-ci-service | `ReleaseRequestChanged.preRun = PENDING` starts no run (platform-level, before trigger matching); contract test; absent = today |
| CI-2 | qits-ci-service | `automations/dependency-bump.yml` (apply script from `one-commit-bumps`); composer hook `$QITS_AUTOMATION_COMMIT_MESSAGE`; packaged-pipeline tests |
| CI-3 | qits-ci-service | (after cutover) remove the group arm of `maintenance-bump.yml` and of `RunGitRefs` |
| MT-1 | qits-maintenance-service | `Stage`, `WAITING`, `NOT_APPLICABLE` listed with reason (only when the trigger says it `accepts` them), `inputPaths()` carry rule, `entity-diagram` inputs, runtime disjointness check, cap from qits-ci free slots |
| MT-2 | qits-maintenance-service | `DependencyBumpAutomation` (applicability, plan at the fold, Q1 rule, gitlink ownership, `hold:`), behind the switch |
| MT-3 | qits-maintenance-service | "latest moved" hook from the three sources, debounce, re-plan of an open non-READY request (trigger `UPSTREAM`), starvation guard |
| MT-4 | qits-maintenance-service | owed sweep: `BumpDispatcher` opens main-only `LOWEST` requests instead of group bumps; withdraws its own empty request |
| MT-5 | qits-maintenance-service | cutover: switch on, group dispatch off, legacy `maintenance/<group>` sweep |
| MT-6 | qits-maintenance-service + qits-maintenance-frontend | retire groups, group doors, window, `BumpSchedule`, `mt_branch` writes, the window page |
| PR-1 | qits-projects-service (+ qits-githost-service) | land `fold-rebuild`, `release-gate-classes`, `rr-phase-race`, the NOT_APPLICABLE work |
| PR-2 | qits-projects-service | refresh before announce; `preRun` on the event; `qa_announced_sha` (new Flyway version); second announce on FRESH or waiver; WAITING re-POST; `AUTOMATIONS` before `CI`; `preRun` on the DTO; sends `accepts` |
| PR-3 | qits-projects-service | (after cutover) remove the "red verdict holds while automations move" arm |
| LA-1 | qits-landing-app | P1 pre-run then P2; cog counts merge + kinds; WAITING and "waiting for pre-run" |
| GH-1 | qits-githost-service | (after cutover) drop the `maintenance/<group>` push allowance |

## Done when (live)

- A qits-landing-app push: the request shows "Pre-run running", no QA run exists until the
  screenshot baselines are FRESH; then exactly one QA run for that fold.
- A library release (for example `@qits/ui-components`) with no open request on a consumer: one
  main-only `LOWEST` request opens, its pre-run commits one `bump(dependencies)` commit on
  `maintenance/automations/dependency-bump/<rr>`, then one QA run. No `maintenance/<group>` branch.
- The same release while a consumer's request runs QA: QA is cancelled, the bump joins, one new QA
  run on the new fold.
- A qits-landing-app fold with a dependency bump: screenshot baselines wait (WAITING), then run once
  on the fold that carries the bump.
- A service fold that changes no Java and no pom: the entity diagram is carried, no run.
- A request of a repository with no manifest lists `dependency-bump` NOT_APPLICABLE with its reason;
  the cog says `1/1 · 3 skipped`.

## Open questions for the user

- **Q1.** Does the pre-run put EXTERNAL (third-party) upgrades into a request a person opened? The
  proposal: internal only; external only in requests maintenance opens itself. "All upgrades in
  every request" is the alternative, and it risks a person's work failing QA on a framework major.
- **Q2.** Confirm the limits on "a version bump cancels QA": READY requests are left alone, and
  after 3 upstream restarts without a QA verdict, further upgrades wait for the next request.
- **Q3.** Ship qits-ci `one-commit-bumps` as a stopgap until the cutover (it stops the stacked
  `bump(dependencies)` commits now), or drop it? Proposal: drop, unless the cutover is more than a
  week away.
