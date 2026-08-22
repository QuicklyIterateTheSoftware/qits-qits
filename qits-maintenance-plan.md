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

Repos: `services/qits-platform-maintenance` (Quarkus, platform tier, segment
`/maintenance`) and `frontends/qits-platform-spa-maintenance` (Angular 21,
embedded by Quinoa at `service/src/main/webui`). Both modelled on
`qits-platform-orchestrator` / `qits-platform-spa-orchestrator` — same module
split (`maintenance/` domain + `service/`), same clone-alone-builds-green law,
same oidc shape (`qits:admin` people, `qits:system` machines), same
`deployments.yml` stanza (`deployment_target: platform`, `routes: /maintenance`,
`navigation: Maintenance:13`, `resources: postgresql:db`,
`health_path: /maintenance/q/health/ready`).

**Platform tier, env-aware.** Repositories and the git host are platform-wide;
CI is per environment. v1 talks to ONE CI (`qits.maintenance.targets.ci-url`,
default `http://qits-ci:8080`, injected as the env's `dev-qits-ci`); every bump
row records the `environment` it ran in so a second environment is a config
entry, not a schema change.

## What it does NOT do (v1)

- No transitive dependencies: manifests hold direct pins and only those move.
- No external Docker base tags (`FROM eclipse-temurin:…`): tag ordering across
  vendors is a later decision. `FROM qits/*` IS in scope.
- No `ng update` / tool-driven upgrades; groups carry only `name` + `deps`.
- No workspace creation: pushing the branch is the whole "MR". The branch is
  released through the workspaces release door like today.
- No bus listener yet: polling only (internal 6h, external daily). The
  `SoftwareRelease` listener that turns an internal release into "pending"
  within seconds is the second release.

## Sources of truth

| Fact | Read from | How |
|---|---|---|
| catalog (repo names) | qits-projects `GET /projects/api/repositories` | the name-addressed coordinate every other read uses |
| manifests at `main` | qits-githost `GET /git/<project>/<repo>/tree/<rev>[/<path>]` and `GET …/blob/<rev>/<path>` | resolve the head sha ONCE per scan, read every file at that sha (qits-ci's `HttpGitConfigSource` is the model: FOUND / ABSENT / GONE / UNREACHABLE / INVALID) |
| internal latest | qits-artifacts registry: maven `maven-metadata.xml`, npm packument `dist-tags.latest`, OCI `/v2/<name>/tags/list` | `qits.maintenance.registries.{maven,npm,oci}-url` |
| external latest | qits-platform-mirror: `central` maven-metadata, `npmjs` packument | `qits.maintenance.mirror.{maven,npm}-url` |
| applying a bump | qits-ci `POST /ci/api/events/trigger` | see "The bump pipeline" |
| bump outcome | qits-ci `GET /ci/api/runs/{id}` + githost branch head | polled; NO callback from the step, no new auth |

Internal vs external is a name rule, configured: maven groups
(`eu.wohlben.qits`), npm scopes (`@qits`), image prefixes (`qits/`). A
dependency matching none is external.

## Manifests and parsers

| Manifest | Ecosystem | Pins read | Notes |
|---|---|---|---|
| `pom.xml` (+ reactor modules named in `<modules>`) | maven | `<dependencies>`, `<dependencyManagement>`, `<parent>`; `${prop}` resolved from `<properties>` of the same pom or the root pom | a pin's `location` records WHERE it is set (`property:qits.eventstream.version` or `dependency:g:a`) so the step edits the right line |
| `package.json` + `package-lock.json` | npm | `dependencies`, `devDependencies`; the pinned version is the lock's `packages["node_modules/<name>"].version`, the range is kept as `range` | nested `webui/` package.json (Quinoa SPA gitlink) is NOT scanned — it is its own repository |
| `Dockerfile`, `*.Dockerfile` | docker | every `FROM <image>:<tag>`; v1 keeps only `qits/*` images | `location` = line number |

Version ordering: maven `ComparableVersion` semantics, npm semver, OCI tags as
calver/semver; a prerelease/SNAPSHOT latest is offered only when the current pin
is one too.

## Config in the repository — `.config/qits/maintenance.yml`

```yaml
groups:
  - name: angular                  # branch maintenance/angular
    deps: ["@angular/*", "@qits/angular"]
  - name: quarkus
    deps: ["io.quarkus:*", "io.quarkus.platform:*"]
# every pin matching no group → group "dependencies" → branch maintenance/dependencies
```

Absent file = one group `dependencies`. `deps` are globs on the dependency
name: npm `@scope/name`, maven `groupId:artifactId`, docker image name. A pin
matching two groups belongs to the FIRST. Invalid yml = scan row `CONFIG_ERROR`,
nothing bumped for that repo, the UI shows the message.

## Model (PostgreSQL `qits_platform_maintenance`, Flyway)

```
mt_repository        name, last_scan_at, head_sha, status (OK|ABSENT|UNREACHABLE|CONFIG_ERROR), message
mt_pin               repository, manifest_path, ecosystem, name, version, range, kind (INTERNAL|EXTERNAL), location
mt_latest            ecosystem, name, latest, checked_at, source_url, error
mt_group             repository, name, patterns (json), source (CONFIG|DEFAULT)
mt_branch            repository, group_name, branch, state (NONE|PUSHED|STALE|RELEASED|FAILED), head_sha, updated_at
mt_bump              id, repository, group_name, branch, environment, trigger (SCHEDULED|MANUAL), ci_event_id, ci_run_id,
                     status (REQUESTED|RUNNING|SUCCEEDED|FAILED|NOTHING_TO_DO), changes (json), started_at, finished_at, message
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

"Pending" is computed, never stored: `mt_pin ⋈ mt_latest` where latest > version,
grouped by `mt_group`. "Who pins X" is a query over `mt_pin`.

## API — `/maintenance/api`, roles `qits:admin` (people) or `qits:system` (machines)

```
GET  /repositories                              → [{name, lastScanAt, status, message, pending, groups:[{name, branch, state, pending}]}]
GET  /repositories/{name}                       → the same fields + pins:[{manifestPath, ecosystem, name, version, range, kind, latest, pending, group, location}]
GET  /dependencies?name=<glob>                  → [{ecosystem, name, latest, pins:[{repository, version, manifestPath, pending}]}]   # "who pins eventstream 2026.8.x"
POST /scans  {scope: INTERNAL|EXTERNAL|ALL, repository?}            → 202 {id}        # rescan + refresh latest
GET  /scans/{id}                                → {id, scope, repository, status (REQUESTED|RUNNING|SUCCEEDED|FAILED), startedAt, finishedAt, message}
POST /repositories/{name}/groups/{group}/bumps                      → 202 {id}        # "create the branch now"; 409 while one is active for that (repo, group)
GET  /bumps?repository=&limit=20                → [bump]
GET  /bumps/{id}                                → bump
bump = {id, repository, group, branch, environment, trigger, ciEventId, ciRunId, status, changes:[…], startedAt, finishedAt, message}
```
Every error body is `{"message": "…"}`. Wire names are camelCase; `group`, not `groupName`.

Scan and bump requests are queued on ONE worker thread (the orchestrator's
executor pattern: a sequence, not an interleaving). A scheduled run is the
same code as the button.

Schedules (`qits.maintenance.*`): `scan.internal.cron` `0 0 */6 * * ?`,
`scan.external.cron` `0 0 1 * * ?`, `time-zone` UTC, `scan.enabled`,
`bump.enabled` (a scan never bumps when false — the UI still shows pending),
`bump.auto` (true: a scan that finds pending changes in a group with no active
bump requests one; false: buttons only). Defaults: enabled, auto.

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
      {"ecosystem":"docker","manifestPath":"Dockerfile","name":"qits/build-images/maven-base","from":"2026.813.1","to":"2026.821.2","location":"line:3"}
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
   changes by rewriting the `FROM` line.

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
  time → bump FAILED, the next scan requests again.
- qits-ci config key `qits.ci.platform-pipelines-repository` (default
  `qits-qits`; blank = off). Run rows carry `config_path` =
  `.config/qits/ci-platform-event-maintenance-bump.yml`; a repo with a local
  AND a platform trigger for one event gets two runs.

## Rollout (the orchestrator's recipe, twice)

1. Seed both repos, add as submodules here (`--name`, `ignore = all`, `update = merge`).
2. idp client `qits-platform-maintenance` (roles `qits:system`, `qits-platform:system`) in qits-configuration + `.qits-bootstrap.env`; extras block for the peer urls.
3. `PUT /git/<name>` on the githost → seed main → release via the door → wrapper release → projects reconcile → SPA release → bump webui gitlink → service release.
4. qits-ci release with platform pipelines; wrapper gains `ci-platform-event-maintenance-bump.yml`.
5. First scheduled bump green → delete the 71 hop files across the repos (one sweep, one wrapper release).

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
