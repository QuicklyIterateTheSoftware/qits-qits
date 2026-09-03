# qits-platform-maintenance — dependency inventory and maintenance branches

Decided 2026-08-21. Replaces the "maintenance hook": the 71 per-repository
`.config/qits/ci-event-upstream-*.yml` files that each follow ONE internal
`SoftwareRelease` and force-push ONE `maintenance/<upstream>` branch. Those are
internal-only, one branch per dependency, synchronous, and their force-push is
what breaks the GitHub backup (`handoff.md`, "In flight").

One PLATFORM service owns the **dependency inventory** of every repository in
the catalog, knows the **latest version** of every dependency (internal and
external), groups pending upgrades into **maintenance branches** per
configuration, and asks qits-ci to apply them — on a schedule or on a button.
The service decides *what* changes; a CI step applies them. The orchestrator is
not involved (its law forbids a store and a policy; this is both).

Repos: `components/qits-maintenance/qits-maintenance-platform-service` (Quarkus,
platform tier, segment `/maintenance`) and
`components/qits-maintenance/qits-maintenance-platform-frontend` (Angular 21,
embedded by Quinoa at `service/src/main/webui`) — the deployed application is
`qits-platform-maintenance` whatever the repositories are called. Both modelled
on `qits-platform-orchestrator` / `qits-platform-spa-orchestrator` — same module
split (`maintenance/` domain + `service/`), same clone-alone-builds-green law,
same oidc shape (`qits:admin` people, `qits:system` machines), same
`deployments.yml` stanza (`deployment_target: platform`, `routes: /maintenance`,
`navigation: Maintenance:13`, `resources: postgresql:db` +
`postgresql:eventstream:qits_platform_maintenance_eventstream`,
`health_path: /maintenance/q/health/ready`).

**Platform tier, env-aware.** Repositories and the git host are platform-wide;
CI is per environment. v1 talks to ONE CI (`qits.maintenance.targets.ci-url`,
default `http://qits-ci:8080`, injected as the env's `dev-qits-ci`); every bump
row records the `environment` it ran in so a second environment is a config
entry, not a schema change.

## What it does NOT do (v1)

- No transitive BUMPS. Transitives are READ now — see "The dependency graph" —
  and shown beside the pins; what is still absent is doing anything about one,
  because a manifest holds direct pins and only those have a line to edit.
- No external Docker base tags (`FROM eclipse-temurin:…`): tag ordering across
  vendors is a later decision. `FROM qits/*` IS in scope.
- No `ng update` / tool-driven upgrades; groups carry only `name` + `deps`.
- No workspace creation: pushing the branch is the whole "MR" — and a bump that
  pushed one now asks the workspaces release door for the release itself.
- No polling of the release request. The door answers a `requestId`, this
  service stores it and stops; what became of it comes back as `SCMRelease` on
  the bus, and two mechanisms watching one fact are two ways to disagree.
- No automatic EXTERNAL bumps. `bump.external.auto` exists so the deployment
  surface does not change the day they are implemented, and is read only to WARN
  when somebody sets it.

## Sources of truth

| Fact | Read from | How |
|---|---|---|
| catalog (repo names) | qits-projects `GET /projects/api/repositories` | the name-addressed coordinate every other read uses |
| manifests at `main` | qits-githost `GET /git/<project>/<repo>/tree/<rev>[/<path>]` and `GET …/blob/<rev>/<path>` | resolve the head sha ONCE per scan, read every file at that sha (qits-ci's `HttpGitConfigSource` is the model: FOUND / ABSENT / GONE / UNREACHABLE / INVALID) |
| internal latest | qits-artifacts registry: maven `maven-metadata.xml`, npm packument `dist-tags.latest`, OCI `/v2/<name>/tags/list` | `qits.maintenance.registries.{maven,npm,oci}-url` |
| external latest | qits-platform-mirror: `central` maven-metadata, `npmjs` packument | `qits.maintenance.mirror.{maven,npm}-url` |
| applying a bump | qits-ci `POST /ci/api/events/trigger` | see "The bump pipeline" |
| bump outcome | qits-ci `GET /ci/api/runs/{id}` + githost branch head | polled; NO callback from the step, no new auth |
| an internal release | qits-events `SoftwareRelease` off the durable bus | consumer `maintenance-internal-latest`; moves `mt_latest` FORWARD ONLY |
| a branch's life | qits-events `SCMRelease`, `SCMDeleteBranch`, `SCMPublishCommit` | consumer `maintenance-branch-tracking`; the only writer of `RELEASED`, of a gitlink's latest, and of an `EVENT` rescan |
| what a release CONTAINS | qits-artifacts `GET /artifacts/sboms/{type}/{name}/-/{version}` | one CycloneDX document per released artifact; `qits.maintenance.targets.artifacts-url`, a bare host because that path is qits-artifacts' own API rather than a mount |
| releasing a bump's branch | qits-workspaces `POST /workspaces/api/branches/release` | `qits.maintenance.targets.workspaces-url`; the ask is made BY the bump, see "The release door" |

Internal vs external is a name rule, configured: maven groups
(`eu.wohlben.qits`), npm scopes (`@qits`), image prefixes (`qits/`). A
dependency matching none is external. A **gitlink is INTERNAL by construction**
and not by the rule: a submodule is a repository on this platform's own git host
and nothing else can be one, so there is no key for it and no external half.

## Manifests and parsers

| Manifest | Ecosystem | Pins read | Notes |
|---|---|---|---|
| `pom.xml` (+ reactor modules named in `<modules>`) | maven | `<dependencies>`, `<dependencyManagement>`, `<parent>`; `${prop}` resolved from `<properties>` of the same pom or the root pom | a pin's `location` records WHERE it is set (`property:qits.eventstream.version` or `dependency:g:a`) so the step edits the right line |
| `package.json` + `package-lock.json` | npm | `dependencies`, `devDependencies`; the pinned version is the lock's `packages["node_modules/<name>"].version`, the range is kept as `range` | nested `webui/` package.json (Quinoa SPA gitlink) is NOT scanned — it is its own repository. The gitlink ITSELF is a pin, which is a different fact from what it contains |
| `Dockerfile`, `*.Dockerfile` | docker | every `FROM <image>:<tag>`; v1 keeps only `qits/*` images | `location` = line number |
| `.gitmodules` + the tree's `160000` entries | gitlink | every submodule | `location` = `gitlink:<path>` |

A gitlink's NAME is the url's basename (`qits-artifacts-frontend`), never the
`[submodule "…"]` section — a rename leaves the section behind and the url is
what a clone resolves. Its VERSION is the commit sha off the mode-`160000` tree
entry, because `.gitmodules` names a submodule and never its version; a git host
that does not report that sha yields NO gitlink pin rather than one at a guessed
version. An unparseable `.gitmodules` is NOT `CONFIG_ERROR` — that status is for
this service's own `maintenance.yml`; what parses is used and the rest dropped.

Version ordering: maven `ComparableVersion` semantics, npm semver, OCI tags as
calver/semver; a prerelease/SNAPSHOT latest is offered only when the current pin
is one too. **A gitlink pin has no order at all** — it is a hash — so the only
question asked of it is a DIFFERENCE: is the submodule pinned at the commit the
newest release was cut from. Both shas have to be known or nothing is offered.

## Config in the repository — `.config/qits/maintenance.yml`

```yaml
groups:
  - name: angular                  # branch maintenance/angular
    deps: ["@angular/*", "@qits/angular"]
  - name: quarkus
    deps: ["io.quarkus:*", "io.quarkus.platform:*"]
ignore: [gitlink]                  # maven | npm | docker | gitlink
# what no configured group claimed still splits by KIND:
#   INTERNAL → "dependencies" → maintenance/dependencies
#   EXTERNAL → "external"     → maintenance/external
```

**The default grouping is the pin's KIND, and it is a PAIR.** Absent file = two
groups: `dependencies` claims every `INTERNAL` pin and `external` claims every
`EXTERNAL` one, so the platform's own releases travel on
`maintenance/dependencies` and everybody else's on `maintenance/external`. The
two halves are found by different schedules and reviewed by different eyes; one
branch carrying both made a nightly internal bump wait behind an opinion about a
framework major. `dependencies` keeps its name and its branch — it is now the
internal half of what it used to be all of.

Glob groups are how a repository asks for a FINER grouping than those two
halves. `deps` are globs (`*`, `?`) on the flat dependency name: npm
`@scope/name`, maven `groupId:artifactId`, docker image name. A pin matching two
groups belongs to the FIRST declared, and **the kind pair is appended AFTER
whatever the file declares** — a configured group always claims first, and a file
that declares `dependencies` or `external` itself keeps its own globs under that
name while only the other half is appended. Invalid yml = repository row
`CONFIG_ERROR`, nothing bumped for that repo, the UI shows the message; falling
back to the default grouping would put changes on a branch the author configured
against.

`ignore:` takes a whole ECOSYSTEM off the repository, and it is a different
question from grouping: grouping says which branch a bump rides on, `ignore` says
the pin is not one at all. An ignored ecosystem is not parsed, not stored, not
grouped and never pending — its manifests are not even fetched — and because an
inventory is replaced wholesale, pins an earlier scan stored disappear on the
first scan after the line is committed. **An unknown ecosystem name is
`CONFIG_ERROR`**: a typo quietly dropped would read as a working opt-out while
the ecosystem the author meant to protect went on being bumped nightly.

The case it was built for is **this wrapper**, whose forty-seven submodule
gitlinks are deliberately lagging bank markers rather than version pins (see
"Submodules" in `CLAUDE.md` — every entry carries `ignore = all` for the same
reason). `.config/qits/maintenance.yml` here is that one line, `ignore:
[gitlink]`. Without it this service would read those forty-seven lagging shas as
forty-seven upgrades and open a nightly bump against a doctrine the repository
states in writing.

## Model (PostgreSQL `qits_platform_maintenance`, Flyway)

```
mt_repository        name, last_scan_at, head_sha, status (OK|ABSENT|UNREACHABLE|CONFIG_ERROR), message
mt_pin               repository, manifest_path, ecosystem, name, version, range, kind (INTERNAL|EXTERNAL), location
mt_latest            ecosystem, name, latest, checked_at, source_url, error
                     for a GITLINK: latest = the calver release version, source_url = 'sha:<hex>' of the commit
                     that `refs/tags/<latest>` resolves to. Written only by the bus; no registry answers this row.
mt_group             repository, name, patterns (json), source (CONFIG|DEFAULT), kind (INTERNAL|EXTERNAL|null)
mt_branch            repository, group_name, branch, state (NONE|PUSHED|STALE|RELEASED|FAILED), head_sha, updated_at
mt_bump              id, repository, group_name, branch, environment, trigger (SCHEDULED|MANUAL), ci_event_id, ci_run_id,
                     status (REQUESTED|RUNNING|SUCCEEDED|FAILED|NOTHING_TO_DO), changes (json), started_at, finished_at, message,
                     release_request_id (an id | 'converged' | 'refused' | NULL = still owed)
mt_artifact          id, ecosystem, name, version, repository, occurred_at,
                     sbom_status (PENDING|INGESTED|MISSING|FAILED), sbom_error, ingested_at
mt_artifact_component  id, artifact_id → mt_artifact, bom_ref, purl (verbatim), ecosystem (null = a purl type we do not map),
                     name, version, direct
mt_artifact_edge     id, artifact_id → mt_artifact, parent_component_id (null = the ROOT), child_component_id
```

Landed additions (service, 2026-08-21): `mt_scan` (scan rows behind
`GET /scans/{id}`); `mt_repository.project` + `.main_branch`; `mt_group.ordinal`
(first match wins needs an order); `mt_bump.branch` + `.ci_run_status`,
`ci_run_id` comma-separated (the trigger answers a list; `ciRunIds` rides
beside `ciRunId` on the wire). `mt_latest.latest` is the highest RELEASE, a
prerelease only when the dependency never published a release. A third
`location` form `parent:<g>:<a>`. Reactor walk is transitive (≤128 poms,
never into `src/main/webui`); a pin resolved from a ROOT property is recorded
against the root pom (the file the step edits). A MANUAL scan never
auto-bumps. `bump.enabled=false` answers 409. Poller key
`qits.maintenance.bump.poll-interval` (15s) doubles as restart recovery.

Landed additions (service, 2026-09-01) — override the above where they differ:
`mt_group.kind` (`V2__internal_external_split.sql`, which also rewrites every
DEFAULT row into the pair, so the split is true from the first request after the
deploy rather than after the next scan); `mt_bump.release_request_id`
(`V4__bump_release_request.sql`, with a partial index on the sweep's read and
every historical SUCCEEDED row settled `converged`); the three `mt_artifact*`
tables (`V3__sbom_graph.sql`), whose two foreign keys are the ONLY ones in this
schema — both ends are this context's own. `ScanTrigger` gained `EVENT` with no
migration (the status columns are string columns under no check constraint).
**No scan bumps anything any more**, whoever triggered it: `bump.auto` and that
coupling are gone and the nightly `BumpSchedule` is the only clock.

There is a SECOND database, `qits_platform_maintenance_eventstream`, declared
`postgresql:eventstream:<name>` beside the store: the bus's outbox and the two
consumers' claim ledger and watermarks, qits-eventstream's own Flyway lineage,
never shared with the store above. **The resource name is load-bearing** — the
jar reads `QITS_RESOURCE_EVENTSTREAM_*`, and the triple has no defaults, so a
container started without it dies at Flyway rather than opening a fallback store.

"Pending" is computed, never stored: `mt_pin ⋈ mt_latest` where latest > version,
grouped by `mt_group`. "Who pins X" is a query over `mt_pin`; "who SHIPS a copy
of X" is a query over `mt_artifact_component`, and the two never merge — an SBOM
cannot name a pom property, a pin cannot see a transitive.

## API — `/maintenance/api`, roles `qits:admin` (people) or `qits:system` (machines)

```
GET  /repositories                              → [{name, project, lastScanAt, headSha, status, message, pending,
                                                    groups:[{name, source, kind, branch, state, headSha, pending}]}]
GET  /repositories/{name}                       → the same fields
                                                  + pins:[{manifestPath, ecosystem, name, version, range, kind, latest,
                                                           latestError, pending, group, location, scope: "DIRECT"}]
                                                  + transitives:[{ecosystem, name, version, via, behind}]
GET  /dependencies?name=<glob>[&kind=]          → [{ecosystem, name, latest, checkedAt, error, pins:[{repository, version, manifestPath, pending}]}]
GET  /dependencies/dependents?ecosystem=&name=[&all=true]
                                                → {ecosystem, name, latest, dependents:[{artifactEcosystem, artifactName,
                                                     artifactVersion, repository, embeddedVersion, direct, occurredAt, sbomStatus}]}
GET  /repositories/{name}/dependents            → {repository, artifacts:[{ecosystem, name, dependents:[…as above]}]}
GET  /artifacts                                 → [{ecosystem, name, repository, latest, version, occurredAt, sbomStatus,
                                                    dependentCount, behindCount}]
POST /artifacts/ingest {ecosystem,name,version} → 202 {id}        # the manual backfill; 400 unknown ecosystem
POST /scans  {scope: INTERNAL|EXTERNAL|ALL, repository?}            → 202 {id}        # rescan + refresh latest
GET  /scans/{id}                                → {id, scope, repository, trigger (SCHEDULED|MANUAL|EVENT), status (REQUESTED|RUNNING|SUCCEEDED|FAILED), startedAt, finishedAt, message}
POST /repositories/{name}/groups/{group}/bumps                      → 202 {id}        # "create the branch now"; 409 while one is active for that (repo, group)
GET  /bumps?repository=&limit=20                → [bump]
GET  /bumps/{id}                                → bump
bump = {id, repository, group, branch, environment, trigger, ciEventId, ciRunId, ciRunIds, configPath,
        status, ciRunStatus, changes:[…], startedAt, finishedAt, message}
```
Every error body is `{"message": "…"}`. Wire names are camelCase; `group`, not `groupName`.

- **`kind` on `/dependencies` is INTERNAL or EXTERNAL and nothing else.** REACTOR
  and UNRESOLVED are refused with a 400 rather than answered with an empty list,
  which would read as "there are none of those". The filter is server-side because
  the two halves are two pages — the same split every default group, every branch
  and both scan schedules already make.
- **`/dependencies` and `/dependencies/dependents` are two routes because they
  are two facts**: a pin is a line a bump can edit, a dependent is a component
  inside a published package, transitives included. The default view of
  `dependents` is the NEWEST released version of each dependent; `all=true` is the
  archaeology.
- **`transitives` is what a repository's RELEASES contain that no manifest
  names** — read from the newest INGESTED document of each artifact it publishes,
  with anything that is also a pin removed. `via` is the direct component whose
  subtree pulled it in. **Empty means "we do not know"**, not "there are none".
- **`scope` on a pin is always `DIRECT`, and it is a constant on purpose**: the
  detail now serves two lists whose rows look alike, and a client rendering them
  in one table needs the distinction on the row.

Scan and bump requests are queued on ONE worker thread (the orchestrator's
executor pattern: a sequence, not an interleaving). A scheduled run is the
same code as the button.

Schedules and switches (`qits.maintenance.*`), all defaulted in the domain jar's
`META-INF/microprofile-config.properties` and overridable by environment:

| key | default | what it decides |
|---|---|---|
| `scan.enabled` | `true` | whether the CLOCK may scan |
| `scan.internal.cron` | `0 30 0 * * ?` | the internal scan, 00:30 daily. **It moved off six-hourly when the bus listeners landed** — it is the reconciliation belt behind them, not the mechanism |
| `scan.external.cron` | `0 0 1 * * ?` | the external scan, 01:00 daily — unchanged |
| `sbom.sweep-cron` | `0 5 * * * ?` | re-queue artifact rows still PENDING, hourly. Never retries MISSING or FAILED |
| `time-zone` | `UTC` | the zone every cron is read in |
| `bump.enabled` | `true` | whether a branch may be pushed AT ALL — stops the button as well as the clock; the UI still shows pending |
| `bump.internal.cron` | `0 0 2 * * ?` | the nightly INTERNAL bump, 02:00 — after both scans, so the inventory it reads is today's |
| `bump.internal.auto` | `true` | whether the clock asks for those bumps. **The live deployment holds it false until the pre-split branches are drained** |
| `bump.external.auto` | `false` | **reserved.** External bumps are manual-only; setting it logs a WARN once and does nothing |
| `bump.poll-interval` | `15s` | how often an unfinished bump is looked at; doubles as restart recovery and as the release-door retry tick |
| `targets.workspaces-url` | `http://qits-workspaces:8080` | the release door |
| `targets.artifacts-url` | `http://qits-artifacts:8080` | the SBOM documents — a bare host, no path |

**`bump.auto` is RETIRED and `QITS_MAINTENANCE_BUMP_AUTO` is inert.** Nothing
reads it; MicroProfile does not fail on an environment variable no key claims, so
a live platform still carrying it is misleading rather than broken — remove it
from the deployment's extras at the next edit of that file. A scan is a READ whose
schedule is set by how fast facts go stale; a bump is a WRITE into somebody else's
repository whose schedule is set by when a branch is welcome. Welded together, the
01:00 external scan decided when the internal half got a branch.

Outbound credentials are now SIX named oidc clients — `projects`, `githost`,
`ci`, `artifacts`, `mirror` and `workspaces` — all `client-id=qits-platform-maintenance`,
all shipped `client-enabled=false`, only the audience differing.

## The bump pipeline (qits-ci change)

**Platform-level pipelines.** qits-ci evaluates event triggers from the
repository's own `.config/qits/ci-event-*.yml` today. It gains ONE more source:
`.config/qits/ci-platform-event-*.yml` files read from the repository named by
`qits.ci.platform-pipelines-repository` (default `qits-qits`, the wrapper) at
its `main` head. Such a pipeline is evaluated for every event like a
repository-local one, but the run is recorded against — and cloned from — the
repository the PAYLOAD names (`payload.repository`, which must exist in the
listing; else no run, one WARN). Everything downstream (steps, env, logs,
cancel) is unchanged.

The maintenance service triggers:

```
POST /ci/api/events/trigger
{ "name": "MaintenanceBump",
  "eventId": "<mt_bump.id>",                      # dedupe: a retry records no second run
  "payload": {
    "repository": "qits-ci",
    "group": "dependencies",
    "branch": "maintenance/dependencies",
    "baseRef": "main",
    "changes": [
      {"ecosystem":"maven","manifestPath":"pom.xml","name":"eu.wohlben.qits:qits-eventstream","from":"2026.811.1","to":"2026.821.3","location":"property:qits.eventstream.version"},
      {"ecosystem":"npm","manifestPath":"package.json","name":"@qits/angular","from":"2026.8.1","to":"2026.8.4","location":"dependencies"},
      {"ecosystem":"docker","manifestPath":"Dockerfile","name":"qits/build-images/maven-base","from":"2026.813.1","to":"2026.821.2","location":"line:3"},
      {"ecosystem":"gitlink","manifestPath":"service/src/main/webui","name":"qits-ci-frontend","from":"<the sha the tree holds>","to":"2026.901.140019","location":"gitlink:service/src/main/webui"}
    ]}}
```

The wrapper's `.config/qits/ci-platform-event-maintenance-bump.yml`:
`event: MaintenanceBump`, no `when` (every payload is for us), two steps on
EXISTING images, each a no-op when the payload holds nothing for its
ecosystem:

1. `qits/build-images/maven-base:latest` — maven changes: edit the property or
   the dependency version named by `location` (xml-aware, not blind sed; the
   version is validated against `[0-9A-Za-z._+-]` first, as the hop files do).
2. `qits/build-images/node-base:latest` — npm changes via
   `npm install --package-lock-only --no-audit --no-fund <name>@<to>` with the
   lock-origin rewrite dance from `ci-event-upstream-angular.yml`; docker
   changes by rewriting the `FROM` line; **gitlink changes as an INDEX write** —
   fetch `refs/tags/<to>` from the sibling repository `name` addresses (derived
   from this run's own clone url), peel it to a commit, and
   `git update-index --add --cacheinfo 160000,<sha>,<path>`. There is no file to
   edit: `.gitmodules` names a submodule and never its version. That step is what
   retires the fifteen `ci-event-upstream-frontend.yml` hop files.

Branch policy, **ff-only, never force**: fetch `refs/heads/<branch>`; if it
exists, check it out and commit on top; if absent, start from `baseRef`. Commit
`bump(<group>): <n> dependencies` with one body line per change, author
`qits maintenance <maintenance@qits.local>`. `git push "$QITS_CI_REPOSITORY_URL"
HEAD:refs/heads/<branch>` without `--force`; a non-ff rejection is a FAILED run
and the service marks the branch STALE (someone rewrote it by hand — they own
it now). A branch that was released is deleted by the release door's cleanup
and the next bump starts fresh from main.

The service polls `GET /ci/api/runs/{runId}` (run ids from the trigger
response) until terminal, then reads the branch head from the githost and
writes `mt_branch`/`mt_bump`. No callback, no new token.

### Landed shape (qits-ci `feature/platform-pipelines`, 2026-08-21) — overrides the above where it differs

- Steps share NO working tree: each step clones, fetches the branch, commits its
  own ecosystem and pushes. One bump = up to TWO commits. The service reads the
  branch head; "head did not move after a green run" = NOTHING_TO_DO.
- `location` honoured for maven only; npm edits the section that holds the
  entry, docker anchors on the image name. `from` is never a precondition.
- Step-side validation: `to` ∈ `[0-9A-Za-z._+-]+`, `group` ∈ `[0-9A-Za-z._-]+`,
  plain refs, relative `manifestPath` without `..`. The service validates the same.
- `payload.repository` is the public NAME; qits-ci resolves it against its
  candidate list (projects' catalogue). A 200 with zero `runIds` = no run this
  time → bump FAILED; the next nightly `BumpSchedule` run requests again (no scan
  ever does — see "Who asks for a bump").
- qits-ci config key `qits.ci.platform-pipelines-repository` (default
  `qits-qits`; blank = off). Run rows carry `config_path` =
  `.config/qits/ci-platform-event-maintenance-bump.yml`; a repo with a local
  AND a platform trigger for one event gets two runs.

## Who asks for a bump, and who asks for its release

**Two callers, and no scan is one of them.** The button is
`POST /repositories/{name}/groups/{group}/bumps`, on any group. The clock is
`schedule/BumpSchedule` at 02:00, and it asks for the INTERNAL group
(`dependencies`) of every OK repository with something pending there and no bump
already going — the external half and a repository's own configured groups are
manual-only.

**One nightly bump coalesces every release since the last one.** The changes are
frozen onto the `mt_bump` row at REQUEST time rather than recomputed at dispatch,
so five internal releases between two nights are ONE branch push, one CI build,
one release request and one release — not five of each. That freeze is also what
makes a 503 retry safe: the same payload goes out under the same event id.

### The release door

**A bump that pushed a branch asks for it to be released, itself:**

```
POST {workspaces-url}/workspaces/api/branches/release?projectId=<project>&repositoryName=<repo>
{ "branch": "maintenance/dependencies",
  "summary": "bump(dependencies): 5 dependencies",
  "expectedSha": "<the head this bump observed>" }      → {requestId, state, branch, commitSha, detail}
```

- Only `SUCCEEDED` asks. `NOTHING_TO_DO` pushed nothing; `STALE` is somebody's
  hand-written commit and releasing it on their behalf is the one thing this must
  never do; `FAILED` has nothing to release.
- **Nothing merges at that call.** The door creates a release REQUEST in
  qits-projects which the quality gates settle afterwards, so this service does
  not poll it. That the branch was released comes back as `SCMRelease` on the bus.
- **`expectedSha` pins the ask to what was built**; `projectId` is
  `mt_repository.project` (the door resolves that segment by id first, then by
  slug), so nothing had to be added to the catalog read.
- **`mt_bump.release_request_id` holds the answer and NULL means work is owed**:
  a request id, or the sentinel `converged` (nothing to ask for — already
  integrated, or the branch was released or deleted first), or `refused` (a 400 or
  404 a retry cannot fix). **A door that will not answer NEVER flips the bump's
  status** — the run was green and the branch moved, both facts about this
  service's own work — so a 5xx or a 401/403 leaves the row `SUCCEEDED` with a
  sentence on `message` and the poll sweep asks again. **The retry is bounded by
  the BRANCH, not a counter**: it stops when the request exists, when `SCMRelease`
  makes the branch RELEASED, or when `SCMDeleteBranch` makes it NONE.
- **The ask is CONVERGENT, which is what makes the rollout safe.** Every
  repository still carries `.config/qits/ci-event-maintenance-release.yml`, whose
  step fires on the same push; the door answers the second ask with the request
  the first made. Those triggers come out at the END of the epic and this becomes
  the only caller.
- **The door was WIDENED rather than the client promoted.** `POST /branches/release`
  admits `qits:system` beside `qits:admin` — the pair its execute arm always
  carried — since qits-workspaces `7c0733b`, so this machine's ordinary grant
  opens it and no `qits:admin` lands on a service. Against an older qits-workspaces
  the bearer authenticates and is refused 403, which `ReleaseDoorClient` classifies
  as RETRYABLE on purpose so the ask heals the moment that release deploys.

## The event bus

**This service subscribes and publishes nothing.** Two durable listeners turn
four facts other services know into inventory writes within seconds, where v1
waited up to six hours for a poll. Their `consumerId`s are STORAGE and must never
be changed — a rename mints a new consumer that starts at the head of the log.

| consumer | events | what it does |
|---|---|---|
| `maintenance-internal-latest` | `SoftwareRelease` (qits-ci) | moves `mt_latest` FORWARD ONLY, and writes an `mt_artifact` row PENDING — the SBOM outbox |
| `maintenance-branch-tracking` | `SCMRelease` (qits-workspaces), `SCMDeleteBranch`, `SCMPublishCommit` (qits-githost) | writes a maintenance branch's state; records every release as a GITLINK's latest; re-reads one repository after a push to its main |

- **Forward-only is the difference between an announcement and a poll.** A poll
  asks a registry what the newest version is and the answer replaces what was
  there, downgrades included; an announcement is evidence that THIS version exists
  and never that a higher one does not. `recordLatest` is the poll's writer,
  `recordLatestIfNewer` the bus's.
- **`SCMRelease` is the ONLY source of a gitlink's latest** — there is no registry
  to poll — and it writes two facts: the calver `version` (what the step fetches
  as `refs/tags/<version>`) and the commit that tag resolves to, in `source_url`
  as `sha:<hex>`. Every release is recorded, not only those something pins today.
- **`SCMRelease` is the only thing that can ever write `BranchState.RELEASED`.**
  The door tags, pushes and deletes the source branch; polling would see a branch
  disappear, which is what a person deleting it by hand looks like. The
  `SCMDeleteBranch` that follows writes `NONE` over it, which is correct, and is
  also the only thing that clears a `STALE` row.
- **A push to a repository's main queues a scan of that ONE repository**, through
  the same path `POST /scans {repository}` takes, with `trigger: EVENT`. It NEVER
  bumps, and a burst is debounced against a scan already queued or running.
- **The daily scans are the belt, not the mechanism.** They still cover three
  things no listener can: an event never published or settled as poison, a
  repository added to the catalog (which announces nothing here), and the window
  after a new consumer starts at the head of the log.

## The dependency graph — what a release CONTAINS

**An SBOM says what a released artifact CONTAINS; `mt_pin` says what a bump
EDITS.** They relate by `(ecosystem, name)` and never merge: an SBOM cannot name
a pom property, and a pin cannot see a transitive. So an inventory built from
SBOMs would be unbumpable and one built from manifests cannot answer "who ships a
copy of this". Both are kept and joined at read time.

Ingestion is from qits-artifacts,
`GET /artifacts/sboms/{packageType}/{packageName}/-/{version}` (CycloneDX, one
document per released artifact), and **the `mt_artifact` row is the OUTBOX**: the
listener writes it PENDING and returns, the fetch happens afterwards on the one
worker thread. A listener that fetched inline would hold a durable bus claim open
across another service's HTTP call.

- **A 404 is `MISSING`, it is the ORDINARY answer, and nothing retries it.** The
  route is newer than most of what this platform has released, and a released
  version is immutable, so asking again asks about the same bytes. What supplies
  an answer is the NEXT release; `POST /maintenance/api/artifacts/ingest` is the
  manual backfill and the hourly sweep re-queues PENDING only.
- **`direct` is the ROOT component's own `dependsOn` list and nothing else** —
  that is the whole value of reading the document. A component whose purl names a
  world this service does not inventory (`pkg:golang/…`) is stored with a null
  ecosystem: shown, never matched.
- No `mt_artifact` row is ever a `daemon` or a `gitlink`: nothing in any manifest
  pins them, so the row would join to nothing.

## Rollout (the orchestrator's recipe, twice)

1. Seed both repos, add as submodules here (`--name`, `ignore = all`, `update = merge`).
2. idp client `qits-platform-maintenance` (roles `qits:system`, `qits-platform:system`) in qits-configuration + `.qits-bootstrap.env`; extras block for the peer urls.
3. `PUT /git/<name>` on the githost → seed main → release via the door → wrapper release → projects reconcile → SPA release → bump webui gitlink → service release.
4. qits-ci release with platform pipelines; wrapper gains `ci-platform-event-maintenance-bump.yml`.
5. First scheduled bump green → delete the 71 hop files across the repos (one sweep, one wrapper release).

### The dependency-updates wave (2026-09-01) — what this second half still needs

6. **Two peer releases first, and both are somebody else's deploy.** qits-githost
   carrying `33b0ccf`: `serveTree` answers a tree entry's `sha` and either
   `"mode":"160000"` or `"type":"commit"` — until it is deployed there is NO
   gitlink pin at all, which is deliberate (a made-up version here would be
   compared by the pending rule and then applied into somebody else's repository)
   and the fifteen `ci-event-upstream-frontend.yml` files keep doing the work.
   qits-workspaces carrying `7c0733b`: the widened door — until it is deployed
   every release ask is a 403, retried rather than fatal.
7. **The service deploy carries the second `resources:` line**, which is read at
   the built sha, so that deployment is what creates
   `qits_platform_maintenance_eventstream` and injects `QITS_RESOURCE_EVENTSTREAM_*`.
   Those have no defaults on purpose: a container started without them dies at
   Flyway naming what is missing and the health gate keeps the previous one. Same
   deploy: turn the sixth oidc client on
   (`QUARKUS_OIDC_CLIENT_WORKSPACES_CLIENT_ENABLED`/`_CREDENTIALS_SECRET`/
   `_GRANT_OPTIONS_CLIENT_AUDIENCE=qits-workspaces`, not environment-qualified),
   set `QITS_MAINTENANCE_BUMP_INTERNAL_AUTO=false`, and drop the now-inert
   `QITS_MAINTENANCE_BUMP_AUTO`. Both consumers start at the HEAD of the log, so
   everything published before the deploy is skipped — that is what 00:30 is for.
8. **Wrapper release**: the bump pipeline's gitlink arm, and
   `.config/qits/maintenance.yml` carrying `ignore: [gitlink]` so the wrapper's
   own forty-seven bank markers are never read as forty-seven upgrades.
9. **Confirm the maven `packageName` against ONE live frame**, after the first
   internal release following the deploy. The three spellings the release listener
   assumes come off the `artifacts:` declarations in the platform's own
   `ci-event-release.yml` files; maven is the one carrying a separator, and a
   frame arriving as `qits-eventstream` rather than
   `eu.wohlben.qits:qits-eventstream` would write a row nothing joins to and say
   nothing about it.
10. **Drain the pre-split branches, then flip the nightly on.** Every
    `maintenance/dependencies` branch standing right now carries MIXED commits from
    before `V2__internal_external_split.sql`. Release or delete them, then set
    `QITS_MAINTENANCE_BUMP_INTERNAL_AUTO=true`; the jar defaults it true and only
    the deployment holds it false.
11. **The hop files come out in waves, and the release triggers come out LAST.**
    The 36 remaining `ci-event-upstream-*.yml` go as the inventory takes each one
    over. The 16 `.config/qits/ci-event-maintenance-release.yml` files and the
    inline release blocks are removed only at the END of the epic: until then they
    are the convergent second caller that still releases a bump's branch when the
    door ask has not landed, and the door answers the second ask with the request
    the first made.

## Status

- 2026-08-21 — decided; worktree `feature/maintenance`; three Opus subagents
  building service, SPA and the qits-ci platform pipeline in parallel.
- 2026-08-21 — qits-ci half green on `feature/platform-pipelines` (3 commits,
  verify BUILD SUCCESS); wrapper pipeline file committed (08611b4).
- 2026-08-21 — service green on its local main (11 commits; `clean test` 89/0,
  `clean verify` with the SPA in the webui gitlink PASSED, PackagedSurfaceIT
  9/9). Rollout needs: idp client `qits-platform-maintenance` with
  `qits:system` + claim `project=*`, audiences `<env>-qits-ci`, `qits-projects`,
  `qits-githost`. qits-ci read routes opened to `qits:system` (follow-up on
  `feature/platform-pipelines`) so the client needs NO `qits:admin`.
- 2026-08-21 — SPA green on its local main (82 tests, build, browser-checked
  against ng serve); API section above updated to the shapes it renders.
- 2026-08-22 — LIVE on wohlben.eu. Released through the door: qits-ci
  2026.822.170613 (platform pipelines + qits:system reads; deployed c774890),
  wrapper 2026.822.170641 (catalog + `ci-platform-event-maintenance-bump.yml`),
  SPA 2026.822.171743, service 2026.822.171807 (deployed eafe858, PG db from
  `resources:`), cli-bootstrap 2026.822.172843 (a re-bootstrap ships the
  service: idp client, extras, repos, deploy order after ci/orchestrator). idp
  client `qits-platform-maintenance` live (roles qits:system+qits-platform:system,
  claim project=*), 33 extras entries in qits-configuration + fallback file,
  secret in `.qits-bootstrap.env`. Catalog reconcile adopted both repos (UUID
  rows, GitHub twins green). Door wants `repositoryId=<row uuid>` now (names
  404) — `/root/qits/rel2.sh <repo> <bundle-ref> <branch> "<summary>"` resolves
  it and clones from `/git/qits/<repo>`. First live scan over 49 repos FAILED:
  an unresolved `${project.groupId}` pin reached the maven latest URL and
  killed the scan (row stuck RUNNING) — fix round in flight. Platform-wide
  observation: NO `ci-event-release.yml` run since the rebootstrap (qits-ci
  log: "0 of 7 owed release(s) had an SCMRelease") — version-tag images are
  not being pushed; not a maintenance defect, needs its own look.
- 2026-08-22 — qits-ci 2026.822.173700 (deployed 7de5c09): `when: repository:`
  is aliased to `repositoryName` like `repoId→repoName` (CiEventSelectionEvaluator)
  — release pipelines match `SCMRelease` again platform-wide. Replayed the
  service's SCMRelease via `POST /ci/api/events/trigger` (payload copied from
  `/events/api/events?name=SCMRelease`, whose `payload` is a JSON STRING —
  `fromjson` it): run 1114ee6f SUCCESS, `qits/qits-platform-maintenance:2026.822.171807`
  in the registry. cli-bootstrap has no release pipeline (0 runs, expected).
  Other releases made today before the fix (qits-workspaces 2026.822.164640)
  still lack their version image — replay the same way if wanted.
- 2026-08-22 evening — service 2026.822.175051 (deployed 63858ca): built-ins
  resolved, `kind: UNRESOLVED`/`REACTOR`, own parent dropped, resolver never
  throws, restart recovery. Scan ALL: 49 repos in 9s, 294 pins behind
  (e.g. @angular/core 21→22.1.3 in all 15 SPAs — node-blocks-angular-22, so
  group them in `maintenance.yml` before bumping). **First real bump PROVEN**:
  qits-ci/dependencies → CI run ee853347 SUCCESS, branch
  `maintenance/dependencies` (quinoa 2.9.0, quarkus-bom 3.38.3, lombok
  1.18.46), 4m40s end to end. `bump.auto` is OFF for now (extras
  `QITS_MAINTENANCE_BUMP_AUTO=false` in qits-configuration + live env) — ~45
  bumps at once would saturate the single CI slot; flip it on deliberately.
  Open: SPA shows a SUCCEEDED bump's message in the error tone (cosmetic);
  the 71 hop files stay until the first green scheduled bump.
- 2026-09-01 — the dependency-updates epic's maintenance half, seven commits on
  `dependency-updates-improvements` in `qits-maintenance-platform-service` and two
  in this wrapper. **Nothing below is released yet.** The kind split: the default
  grouping is the pin's KIND, `dependencies` (INTERNAL) beside a new `external`
  (EXTERNAL) on `maintenance/external`, glob groups kept for finer groupings and
  tried first, `GroupDto.kind` on the wire (`V2`). **The bus arrived**: two durable
  consumers, `maintenance-internal-latest` moving `mt_latest` forward only off
  `SoftwareRelease`, `maintenance-branch-tracking` writing `RELEASED`/`NONE` off
  `SCMRelease`/`SCMDeleteBranch` and queueing an `EVENT` rescan off a debounced
  `SCMPublishCommit` on main — so the internal scan cron dropped to `0 30 0` as the
  belt, external unchanged, and there is a second postgres resource. **The SBOM
  graph** (`V3`): `mt_artifact`/`_component`/`_edge`, ingested from qits-artifacts
  `/artifacts/sboms/{type}/{name}/-/{version}` behind a PENDING outbox row, 404 =
  MISSING and terminal, hourly sweep, `POST /artifacts/ingest` the backfill; four
  new read routes and `transitives` on the repository detail. **The bump lifecycle
  moved**: `bump.auto` retired (`QITS_MAINTENANCE_BUMP_AUTO` inert), a nightly
  `BumpSchedule` at `0 0 2` gated by `bump.internal.auto`, and a SUCCEEDED bump
  calls the workspaces release door itself with `expectedSha`
  (`mt_bump.release_request_id`, `V4`). The door was WIDENED rather than the client
  promoted — qits-workspaces `7c0733b` admits `qits:system` beside `qits:admin`, so
  no `qits:admin` grant lands on this machine. **GITLINK is the fourth ecosystem**:
  `.gitmodules` + the tree's `160000` entries become INTERNAL pins, latest comes
  from `SCMRelease` alone (tag resolved to a commit, `sha:<hex>` in `source_url`),
  pending is a DIFFERENCE and never an order, and the wrapper's node step applies it
  with `update-index --cacheinfo`. It needs qits-githost `33b0ccf` to answer a tree
  entry's sha; against an older host no gitlink pin exists at all. And
  `maintenance.yml` gained `ignore:`, whose first user is this wrapper —
  `ignore: [gitlink]`, because the forty-seven gitlinks here are bank markers.
  Still pending rollout: the two peer deploys (githost, workspaces), the service
  deploy carrying the eventstream resource and the sixth oidc client, the wrapper
  release, the maven `packageName` check against one live frame, draining the
  pre-split branches before `BUMP_INTERNAL_AUTO=true`, and the hop-file waves —
  the 16 `ci-event-maintenance-release.yml` and the inline blocks last of all.

**2026-09-03 — the epic closes: the trains are retired and the service runs the line.**
The three-lane manual proof passed end to end (protocol: remove the pipelines first, then the
upstream change, then event pickup, then a manual renovation that merges and releases itself):
npm via a real feature (`@qits/ui-components`' pending-builds bolt) bumped hop-free into the
workspaces SPA; gitlink via the wrapper arm's first live `update-index`, shipping that SPA into
its service; maven via a qits-eventstream release bumped into qits-ci-service. On the strength of
that, EVERY transitional pipeline is gone: all 47 hop files except the three build-time
base-image follows (`FROM ${ARG}` in workspace-editor-oci, workspace-daemon, projects-daemon —
not config pins, no deployable to attach an extras entry to; their designed successor is a
DockerParser that reads a literal `ARG X=image:tag` default as a docker pin, `location:
arg:<name>`), and all 34 release-door triggers (16 event files, 18 inline steps), removed only
after the direct ask was OBSERVED creating requests in production (bacac82a, 2b2c2e96, 772b03d6
— 03:21). The one config pin among the old hops, projects' refinement image, rides
qits-configuration's `PINS` now (the map became one-image→many-applications for it).

Three defects the rollout surfaced and closed, each with its doctrine written where it bit:
the two-datasource claim-transaction wedge (twice — spot-auditing the listener-reachable store
surface failed both times; every `MaintenanceStore` method now owns its transaction, and a test
opens a real claim around `onFrame` to prove the sandwich); the deployed release door ignoring a
method-level `@RolesAllowed` its own tree carried (root cause unfound; the door no longer bets on
the mechanism — the class admits the pair and the person-only doors refuse `qits:system` in their
first line); and the inventory trusting the catalog in one direction only (48 pre-rename ghosts
bumped by the first nightly; a full-catalog scan now marks the dropped ABSENT and clears their
pins, guarded against partial and empty readings).

Nightly bumps are LIVE (`bump.internal.auto=true` in the dev extras since 2026-09-02 evening;
external stays manual). What the platform does now is the plan's first paragraph, verbatim, with
nothing beside it.
