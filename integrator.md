# Integrator handoff — CI plane recovery and the unreleased work behind it

> **Superseded as a recipe; kept as the record of that week.** The release-flow
> cutover of 2026-09-04 retired the qits-workspaces release door this document
> releases through (`POST /workspaces/api/branches/release`), the `environment/*`
> deploy branches it promotes onto, and per-push CI. The commands in §4 and the
> traps in §5 describe the world as it was on 2026-08-21 and will not work now;
> releasing is a release request on qits-projects — see `WORKSPACE.md`. The
> reasoning, the ordering argument and the diagnoses are why this file stays.

Written 2026-08-21. Everything below is pushed and unreleased. **Nothing here can be built or
released until step 0 is done, and step 0 needs a shell on the docker host** — it cannot be done
from inside a workspace container, which has no docker.

Read the release order in §4 before releasing anything. Two of the steps are order-dependent in a
way that breaks every build on the platform if inverted, and one of those is not recoverable by CI.

## 0. What has NOT been verified — read this before trusting anything below

**None of this work has been through CI.** CI has been down for the entire period it was written
(§1), so every "green" in this document is a **local suite on a workspace container** and nothing
else. Specifically:

- `qits-ci-daemon` 37 tests, `qits-ci` 227 tests, `qits-platform-edge` full `verify` — all local
  `./mvnw`, none of them a CI run, none of them a packaged artifact, and none of them an integration
  test against real containers. The daemon's `extended` ITs (`CiDaemonGateIT`,
  `CiDaemonHandshakeIT`) need docker, a step image and a built daemon binary; **they have not been
  run**, and they are the only place the bash→sh change is exercised against a real container.
- **The `docker:28-dind` claim is from image metadata, not from running it.** `git` and `wget`
  present, `bash`/`curl`/`jq` absent was read out of the image config's build history through the
  mirror. It has never been used as a step image. If the first qits-oci release fails, check that
  first: run `docker run --rm docker:28-dind sh -c 'git --version; wget --version; command -v bash'`
  on the host.

**Whether the edge's `2026.820.161525` is actually running is unknown.** It is released, tagged and
on `environment/dev` at `5d1fd20`, but the deploy build failed and I could not distinguish a running
old edge from a new one — the edge's own generated routes say `no-store` either way, and
`/q/health` reports no version. Establish it before deciding step 4 is needed: fetch any SPA document
through the edge and read `Cache-Control` on the **document** response. `no-cache` means the fix is
live; `public, immutable, max-age=86400` means it is not.

Two more things are inference rather than observation, and are marked as such where they appear: the
`QITS_OBSERVABILITY_URL` diagnosis (§6) and the claim that the daemon pin will flip on release (§4).

---

## 1. How the platform got here

Three separate faults stacked up, and they were diagnosed in the wrong order. The short version:

1. **The disk filled** (150G, 0 bytes free). Symptoms were misleading — CI runs failing with
   `QuarkusTransactionException: RollbackException: ARJUNA016053: Could not commit transaction`
   (postgres unable to write), runs recorded `FAILED` with **no steps at all**, `git fetch` dying
   with `unable to create temporary file`, intermittent `Could not resolve host: dev-qits-ci`.
   Resolved by the operator; ~39G free as of writing. Watch `df -h /`.

2. **A `docker system prune` reclaiming that disk deleted the five `qits/build-images/*` step
   images**, which every recipe on the platform names *unqualified* (`image:
   qits/build-images/ci-base:latest`). Docker resolves a bare name against Docker Hub, so those
   references only ever worked because the bootstrap had left copies in the host's local store.
   Every build in every repository now fails at step launch with:

       orchestrator refused: refused 409 IMAGE_MISSING: Unable to find image
       'qits/build-images/ci-base:latest' locally
       docker: Error response from daemon: pull access denied for qits/build-images/ci-base

   **CI is therefore completely down, platform-wide.** The pipeline that publishes those images ran
   on one of them, so nothing could rebuild them.

3. **The registry is empty too.** The images were not merely missing locally — all five hold zero
   tags in qits-platform-artifacts, so a pull cannot recover them either:

       $ curl -sS http://dev-qits-artifacts:8080/v2/qits/build-images/ci-base/tags/list
       {"name":"qits/build-images/ci-base","tags":[]}

   Same for `maven-base`, `userflows-base`, `node-base`, `node-docker-base`. (`_catalog` answers 404;
   it is not exposed. Query per-repository.) qits-ci's `CLAUDE.md` records this happening before —
   *"A salvage re-seeded the artifacts store without them and nothing went red"* — so treat the
   registry as capable of losing content silently.

The only durable copy of those images is the Dockerfiles in `images/qits-oci`.

### What the fixes below actually change

| fault | fix | repo |
|---|---|---|
| bare image names are unpullable | resolve them against the platform registry | `qits-ci` |
| qits-oci could only be built by an image it publishes | build it on upstream `docker:28-dind` | `qits-oci` |
| `docker:28-dind` was refused for having no bash | require *a* shell, not bash | `qits-ci-daemon` |
| SPA `index.html` served immutable for 24h | port the retired gateway's rewrite to the edge | `qits-platform-edge` |

---

## 2. Step 0 — unblock CI (do this first, on the docker host)

```sh
cd images/qits-oci
for i in ci-base maven-base userflows-base node-base node-docker-base; do
  docker build -t "qits/build-images/$i:latest" -f "$i/Dockerfile" .
done
```

Build context is the repository root with the Dockerfile named per-image — that is the invocation the
bootstrap's own `DockerBuildTest` pins. `ci-base` is `FROM docker:cli` plus four apk packages, so it
is quick.

**Before doing anything else, check whether the prune also took volumes.** If it was
`docker system prune -a --volumes`, the bootstrap-made set also includes the
`qits-platform-deployments-config` volume — *"the git host's push token among them"* — and the seed
postgres holding the `qits_deployments` role and database (see `local-platform.md`). Those are not
rebuildable with `docker build`; they need a bootstrap rerun. If only images were pruned, the loop
above is sufficient.

**Verify:** push any branch and watch a run reach a step rather than `IMAGE_MISSING`.

---

## 3. The unreleased work

All branches are pushed. Unless noted, the branch is `remote/observability-improvements`.

### 3.1 `daemons/qits-ci-daemon` — `0d74624` "Require a shell, not bash, in a step image"

The step image contract was `git` + `bash` + a downloader, all probed with `--version` before the
clone. Requiring **bash specifically** refused an entire class of image for no capability:
`docker:28-dind` carries docker, git and wget but no bash, and it is the only upstream image that can
build qits-oci's five step images.

Now: `git` and a downloader are required; `bash` is *preferred*. It is still probed at the same
moment (before the clone, so a broken image is reported as a broken image rather than as a failed
step), and an image that has it runs the script under it **exactly as before** — which is what keeps
every existing pipeline's bashisms safe. An image without bash runs the script under `sh`.

- `Workspace.probeTooling()` decides once and stores the shell; `StepProcess` is told rather than
  probing again.
- 37 tests green locally (`./mvnw -pl ci-daemon -am test`), including three new `Workspace` cases and
  a real `sh` execution through `StepProcess`.
- **No protocol change** — `CiDaemonProtocol.CAPABILITY_VERSION` is untouched, so the vendored copy
  in `services/qits-ci/ci-daemon-protocol/` does **not** need re-vendoring. Confirm with
  `diff -r daemons/qits-ci-daemon/ci-daemon-protocol/src services/qits-ci/ci-daemon-protocol/src`
  (must be silent).

### 3.2 `images/qits-oci` — `744eb1d`, `dc91abc`

- `dc91abc` switches **both** pipelines (`ci-event-release.yml`, `ci-post-receive.yml`) from
  `qits/build-images/ci-base:latest` to upstream **`docker:28-dind`**, pulled through the platform's
  OCI mirror. This is what removes the circularity: nothing this repository publishes is needed to
  publish it.
- `744eb1d` adds `ci-post-receive.yml`, which **publishes nothing**. These images are consumed under
  `latest`, so a branch build writing that tag would make an unreviewed Dockerfile the thing the whole
  platform builds on. It exists to prove a Dockerfile still builds on the push that changed it.
- READMEs updated; the bootstrap section is now titled *"No bootstrap"*.

`docker:28-dind` was verified through the mirror rather than assumed — DOCKER_VERSION 28.5.2,
maintained, with `git` and `wget` present in its build history and no `bash`, no `curl`, no `jq`.
The release script already parses the version with `sed` rather than `jq`, deliberately, so it is
POSIX and needs neither.

### 3.3 `services/qits-ci` — `4e402d0` "Resolve an unqualified platform step image against the registry"

New `CiStepImage` prefixes the platform registry onto a step image that names no registry **and**
whose first path segment is the platform's own image repository (`qits`). So
`qits/build-images/ci-base:latest` becomes
`qits-platform-artifacts:8080/qits/build-images/ci-base:latest`, and a pruned host re-pulls instead
of needing a rebuild.

Deliberately narrow: a reference that already names a registry is a decision the recipe made and is
untouched; a single-segment official image like `docker:cli` is untouched; another namespace is
untouched. The resolved reference is **recorded as well as started**, so a failed launch names what
it could not pull.

- Done centrally rather than in ~20 recipes, so recipes keep naming no deployment fact — the property
  the publish scripts already preserve by composing `$QITS_REGISTRY`.
- **Kill switch: `qits.ci.resolve-platform-step-images`, shipped `true`.** Setting it `false` falls
  back to the local store exactly as before, with no rebuild and no redeploy. This exists because the
  blast radius is every build in every repository and the failure is not recoverable by CI.
- 227 tests green (`./mvnw -pl ci -am test`).

### 3.4 `services/qits-platform-edge` — released, **not deployed**

`2026.820.161525` / `5d1fd20` is already merged, tagged, and promoted onto `environment/dev`
(the release door returned `"error": null`). **But the `environment/dev` post-receive build failed**
on the full disk and has not re-run, so the code is banked and not running.

There is also a follow-up branch **`remote/edge-cache-doc`** (`57fd15d`, README documentation of the
new interceptor), pushed, whose CI run failed on `IMAGE_MISSING`. Releasing it is the cleanest way to
put a fresh commit on `environment/dev` and trigger the deploy that ships the cache fix.

What the fix does: `EdgeCacheControl`, a response-direction `ProxyInterceptor` on both proxy sites in
`EdgeRouter`, rewriting the Quarkus static default `public, immutable, max-age=86400` to `no-cache`
for any path whose filename is **not** content-hashed — above all each SPA's `index.html`, the
mutable pointer naming the hashed bundles. Only that exact default is rewritten; an upstream's own
`no-store` is not overruled. This was `qits-gateway`'s job and was not carried across when the
gateway was retired in favour of the edge.

### 3.5 wrapper `qits-qits` — `318b6a3`, `1091c90`

`local-platform.md` only: moves the five step images out of the "bootstrap-made" set into
"built and published, like anything else", with the 2026-08-20 incident as the reason.

---

## 4. Release order — this matters

Releases go through the door, never by pushing `main` or `environment/*`:

```sh
token() { curl -fsS -u "$QITS_COMMISSIONED_CLIENT_ID:$QITS_COMMISSIONED_CLIENT_SECRET" \
  -d "grant_type=client_credentials&audience=$1" "$QITS_GIT_AUTH_TOKEN_URL" | jq -r .access_token; }
WS=http://$QITS_WORKSPACE_DAEMON_AUTH_AUDIENCE:8080/workspaces/api

curl -sS -X POST -H "Authorization: Bearer $(token $QITS_WORKSPACE_DAEMON_AUTH_AUDIENCE)" \
  -H 'Content-Type: application/json' \
  "$WS/branches/release?repositoryId=<repo>" \
  -d '{"branch":"<branch>","summary":"<what this release is>"}'
```

The answer is `{"version","commitSha","branch","promotions"}`. `promotions` is **empty for a library
or an SPA** and that is correct. **After a release the source branch is deleted in that repository** —
`git fetch && git switch main` locally before the next change there.

### The order

| # | repo | branch | why here |
|---|---|---|---|
| 0 | — | — | rebuild the five images on the host (§2). Nothing runs before this. |
| 1 | `qits-ci-daemon` | `remote/observability-improvements` | must ship **before** qits-oci, see below |
| 2 | `qits-oci` | `remote/observability-improvements` | republishes the five images to the empty registry |
| 3 | `qits-ci` | `remote/observability-improvements` | **must be after 2**, see below |
| 4 | `qits-platform-edge` | `remote/edge-cache-doc` | triggers the deploy of the already-released cache fix — **check first whether it is already deployed** (§0), in which case skip |
| 5 | wrapper `qits-qits` | `remote/observability-improvements` | docs; no deploy, any time |

**Why 1 before 2.** qits-oci's pipelines now declare `docker:28-dind`, which has no bash. Until the
new daemon is what step containers run, that image is refused `InitFailed{TOOLING_MISSING}` and the
qits-oci release fails. Releasing the daemon first is not a preference.

> **Verify the daemon actually reached CI before doing step 2.** Right now the pin is
> *configured*, not adopted:
>
>     $ curl -H "Authorization: Bearer $(token dev-qits-ci)" http://dev-qits-ci:8080/ci/api/daemon
>     {"daemonName":"qits-ci-daemon","daemonVersion":"d835f92…","previousDaemonVersion":"","source":"configured"}
>
> `source: "configured"` means `$QITS_CI_DAEMON_BINARY_URL` is pinned by deployment config rather
> than adopted from a `SoftwareRelease`. qits-ci has a `DaemonReleaseListener` (`ci-daemon-adopt`)
> that adopts the daemon's own releases — check whether `daemonVersion` changes and `source` flips
> after step 1. **If it does not, the deployment config is pinning an old binary and must be updated,
> or step 2 will fail on the bash probe against a daemon that still requires bash.** This is the
> single most likely place this plan stalls.

**Why 3 after 2.** The registry currently holds **zero tags** for all five images. If qits-ci's
resolver deploys first, every step image resolves to a registry path with nothing behind it, and
every build in every repository breaks — including the one that would fix it. Step 2 is what puts
the tags there. If this is inverted by accident, set `qits.ci.resolve-platform-step-images=false` on
the qits-ci deployment to fall back to the local store; that is one variable and needs no rebuild.

### Watching a release land

```sh
# the branch build, then the release, then the environment build that deploys
curl -sS -H "Authorization: Bearer $(token dev-qits-ci)" \
  "http://dev-qits-ci:8080/ci/api/runs/active" | jq -r '.runs[]? | "\(.repoId) \(.branch) \(.commitSha[0:7])"'
curl -sS -H "Authorization: Bearer $(token dev-qits-ci)" \
  "http://dev-qits-ci:8080/ci/api/runs/finished?limit=20" \
  | jq -r '.runs[] | "\(.finishedAt[11:19]) \(.repoId)\t\(.branch)\t\(.status)"'

# a failed run's actual output (there is no /logs endpoint; steps carry it)
curl -sS -H "Authorization: Bearer $(token dev-qits-ci)" \
  "http://dev-qits-ci:8080/ci/api/runs/<runId>" | jq -r '.steps[]? | "\(.status) \(.output)"'
```

A run recorded `FAILED` with `steps: null` and no `cancellationReason` did not execute a step at all
— that is an infrastructure fault (disk, orchestrator, missing image), not a pipeline verdict.

### Verifying the outcomes

```sh
# 2 — the registry stops being empty
for i in ci-base maven-base userflows-base node-base node-docker-base; do
  curl -sS "http://dev-qits-artifacts:8080/v2/qits/build-images/$i/tags/list"; echo
done
# expect a CalVer and "latest" in each

# 4 — the edge stops serving SPA documents as immutable.
# This is ALSO the check for whether step 4 was needed at all (§0): run it BEFORE releasing.
# A browser session is required — these paths are gated, and this container's bearer is refused —
# so read it from DevTools -> Network -> the document request, or with a session cookie:
#   document (e.g. https://<host>/observability/)  -> must be: cache-control: no-cache
#   hashed bundle (main-<HASH>.js)                 -> must stay: public, immutable, max-age=86400
# If the document already says no-cache, 5d1fd20 deployed on its own and step 4 is unnecessary.
```

---

## 5. Traps

- **Never push `main` or `environment/*`.** Releases go through the door. A branch push builds; the
  door merges, tags and promotes.
- **`POST /ci/api/events/post-receive` no longer exists.** Push intake is event-driven
  (`SCMPublishCommit` off the bus), so a failed `environment/*` build **cannot be re-triggered
  without a new commit on that branch**. That is why step 4 releases a documentation branch rather
  than re-running anything.
- **`git add -A` in the wrapper stages moved gitlinks silently** — `.gitmodules` says `ignore = all`.
  Commit explicit paths, and confirm a gitlink with `git ls-tree HEAD <path>`.
- **Never move a submodule gitlink by hand to follow a release you made.** The release train owns
  that pin.
- **Building inside a workspace container**: `HOME` is unwritable, so `./mvnw` needs
  `export HOME=/tmp/mvnhome`; run in a login shell (`bash -lc`) so `MAVEN_ARGS` picks up
  `/etc/qits/maven-settings.xml`. npm lockfiles name unreachable hosts — see `WORKSPACE.md` for the
  `sed` rewrite, and restore the lockfile before committing.
- **Watch the disk.** `df -h /`. This whole incident started there, and a native/container build
  chews through it.
- **Do not `docker rmi` in a pipeline.** Both qits-oci pipelines carry a comment explaining the
  2026-08-11 race it caused; leave it.

---

## 6. Open, not addressed

- **`qits.observability.url` defaults to the unprefixed `qits-observability`** in every service
  (artifacts, ci, deployments, containers, events, githost, observability, edge). That host does not
  resolve on the platform network; `dev-qits-observability` does. `cli/qits-cli-bootstrap/README.md`
  records this as one of three hand-recoveries from the 2026-08-08 re-plane —
  *"nothing spelled `QITS_OBSERVABILITY_URL`, so every exporter dialled a name the rename had
  killed"* — fixed in the CLI but never proven against a live bootstrap. **Unresolved question:**
  whether the fix belongs in deployment config (deployments should inject the variable) or in the
  properties files (the shipped default should become tier-aware). Decide that before touching eight
  repositories. Symptom if it is real: telemetry sources appear in the observability UI with **zero
  spans**, so trace screens draw *"No spans have arrived from …"*.
- **A synthetic probe trace** was injected into the observability buffer as
  `_service/qits-workspace-probe` (trace `08999f137968b719094e2d38de505509`) to prove the trace UI
  end to end. It is an in-memory ring buffer, so it evicts on its own and dies on restart — nothing
  to clean up, but ignore it when reading real data.
- **The original observability complaint was not a bug.** The trace/span drill-down works; the
  screens live in the sidebar sub-menu and appear only **after a source is selected**. That is a
  discoverability problem worth fixing (show the five screens disabled, or name them in the
  placeholder) but no code is broken.

---

## 7. If you only read one thing

Do §2, then release in the §4 order, checking the daemon pin between steps 1 and 2 and never
inverting 2 and 3. Everything else is context.
