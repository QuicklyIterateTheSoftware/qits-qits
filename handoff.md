# Handoff: 2026-07-30 → next session

Purpose: start tomorrow's session from this file. It says what happened today, what was still in
flight at handoff, how to verify it all landed, and where tomorrow's work — fleshing out the
frontends — picks up. Deeper reasoning lives in the repo docs named per section; this file is the
map, not the territory.

## What happened today, in order

1. **qits-artifacts grew an npm registry** — a hosted repo (`npm`, publishes at
   `/artifacts/npm/npm/`) and a pull-through cache of npmjs (`npmjs`, at `/artifacts/npm/npmjs/`),
   same protocol-type pattern as the OCI registry, tokenless on qits-net like everything else.
   Design + status: `npm-registry-plan.md` (root). Wire details: qits-artifacts README/AGENTS.
2. **Both Angular libraries publish from their own pipelines**: `@qits/angular@0.0.1`
   (qits-integrations-angular, reshaped to publish its ng-packagr dist; git-install contraptions
   removed) and `@qits/ui-components@0.0.1` (qits-spa-ui-components, scaffolded from empty).
   Publish-if-absent: bumping `projects/<lib>/package.json`'s version IS the release.
3. **qits-spa-home was scaffolded** (Angular 21, consumes both packages via the registry), went
   through three serving shapes in one day — nginx image (rejected: foreign to the stack) →
   standalone Quarkus+Quinoa (superseded) → **final: the gateway serves it**. qits-gateway carries
   qits-spa-home as a git submodule at `src/main/webui`; Quinoa packages it; the landing page is
   the gateway's `/`. It also migrated pnpm → npm mid-day (your call: npm/node from the container).
4. **Every backend with a UI got the same Quinoa treatment** (user-driven, parallel to the above):
   ci, artifacts, projects, workspaces, observability each carry a public `qits-spa-*` submodule
   at `service/src/main/webui`, per `docs/project-setup-quinoa-angular.md`. All were pushed to the
   platform today; all but workspaces verified serving (see §2).
5. **Bare segments redirect**: `/ci` → `/ci/` etc. via an exact-path-guarded `WebUiRedirect` route
   in all five UI services (Quinoa only matches `/<seg>/*`). The exact-path guard matters — v1
   looped, because Vert.x path routes are trailing-slash tolerant.
6. **Every pipeline now fails closed** (`set -eu`): a workspaces run had reported SUCCESS with no
   image pushed (build failed, `docker rmi || true` ate the exit code), and cd deployed
   `IMAGE_MISSING` off the lie.
7. **Everything is synced to GitHub** (all submodules + home repo), all six `qits-spa-*` repos are
   public (qits-spa-workspaces was private until late today), and **no repo carries an `insteadOf`
   line anymore** — the workarounds for private/unsynced repos were removed once obsolete.

The full e2e was proven mid-day: green pipeline publishes → registry serves → spa-home installs
through the proxy (cold 10.6s / warm 1.7s for 568 tarballs) → gateway image packages the bundle →
cd deploys → front door serves. What was NOT yet verified at handoff is the tail of the day's
queue — hence §1 and §2 tomorrow.

## State at handoff (~20:30 UTC)

| service | deployed | notes |
|---|---|---|
| qits-gateway | `3ed7e4c` | landing SPA at `/`; run for `64d72fb` (cleanup) **still queued** |
| qits-ci | `eab7df5` | `/ci/` live; run for `728c8ac` (set -eu) **still queued** |
| qits-artifacts | `763a8d5` | `/artifacts/` + npm registry live |
| qits-projects | `1998c9f` | `/projects/` live |
| qits-observability | `e881968` | `/observability/` live |
| qits-workspaces | **old bootstrap image** | **UI never deployed successfully today**; run in flight at handoff, and new pushes were landing — trust live tips, not this table |
| qits-cd / qits-stt | `826e6f2` / `7e1f55e` | set -eu landed; stt has no frontend |

## 1. First: did every push get a run, and did every run deploy?

The post-receive notifier is fire-and-forget, and today proved the gap is real: **four pushes lost
their events** by landing during a qits-ci or qits-artifacts cutover — git host ahead of CI, no
run, no error anywhere. So verify tips against runs, not memory:

    for r in qits-gateway qits-ci qits-artifacts qits-projects qits-observability \
             qits-workspaces qits-cd qits-stt; do
      tip=$(git ls-remote "http://localhost:8080/artifacts/git/$r" main | cut -c1-7)
      last=$(curl -s "localhost:8080/ci/api/runs?repositoryId=$r" \
             | python3 -c "import json,sys; r=json.load(sys.stdin)['runs'][0]; print(r['commitSha'][:7], r['status'])")
      echo "$r: tip=$tip run=$last"
    done

Every line must show tip == run sha and `SUCCESS`. Fixes:

- **Run missing** (tip ahead): replay the lost event, no noise commit needed:

      curl -X POST -H 'Content-Type: application/json' \
        -d '{"repoId":"<repo>","branch":"main","oldSha":"<full last-run sha>","newSha":"<full tip>"}' \
        localhost:8080/ci/api/events/post-receive

- **Run FAILED**: `curl -s localhost:8080/ci/api/runs/<id>` carries per-step output. Seconds-long
  with `steps: null` = orphaned by qits-ci's own cutover; replay it too.
- **Run green but old container serving**: check cd —
  `curl -s 'localhost:8080/cd/api/deployments?environmentId=<id>' | jq` (env id from
  `/cd/api/environments`). `IMAGE_MISSING` should now be impossible (set -eu), so investigate any.

## 2. Then: the sweep

    docker ps --format '{{.Image}}\t{{.Status}}' | grep 'qits/' | sort

    for seg in ci artifacts projects workspaces observability; do
      bare=$(curl -s -o /dev/null -w '%{http_code}' localhost:8080/$seg)
      final=$(curl -sL -o /dev/null -w '%{http_code}' localhost:8080/$seg)
      title=$(curl -s localhost:8080/$seg/ | grep -o '<title>[^<]*</title>')
      echo "/$seg: $bare -> $final $title"
    done
    curl -s localhost:8080/ | grep -o '<title>[^<]*</title>'

    curl -s -o /dev/null -w 'npm proxy: %{http_code}\n' localhost:8080/artifacts/npm/npmjs/left-pad
    curl -s -o /dev/null -w 'oci root:  %{http_code}\n' localhost:8081/v2/
    curl -s -o /dev/null -w 'git:       %{http_code}\n' 'localhost:8080/artifacts/git/qits-ci/info/refs?service=git-upload-pack'
    curl -s -o /dev/null -w 'ci api:    %{http_code}\n' 'localhost:8080/ci/api/runs?repositoryId=qits-ci'

Expected: every segment `301 -> 200`, titles `qits` / `QitsSpaCi` / `QitsSpaArtifacts` /
`QitsSpaProjects` / `QitsSpaWorkspaces` / `QitsSpaObservability`; machine paths non-HTML 200s.
**qits-workspaces is the one to watch** — it never deployed today (first the green-lying
IMAGE_MISSING run, then the then-private spa repo failing the anonymous submodule clone).

## 3. Sharp edges met today (fixed, but they shape tomorrow's loop)

- **Quinoa MOVES the webui `dist/`** into `target/quinoa` during any `mvnw package`/`verify` — an
  image build right after finds no bundle. Rebuild the webui immediately before `docker build`.
- **A docker-build RUN step reaches the internet but never the platform registry** — anything
  needing `@qits/*` installs in the CI step container; images only package prebuilt output. The
  gateway's Dockerfile documents the whole story (Quinoa's install/build nulled with `--version`).
- **npm lockfiles pin resolved URLs** (`localhost:8081`); CI host-swaps to `qits-artifacts:8080`
  before `npm ci` (identical paths on both addresses; npm's `--replace-registry-host` mangles
  path-mounted registries). Regenerate lockfiles on the host, against `localhost:8081`.
- **Vert.x path routes match the trailing-slash form too** — any new bare-segment route needs the
  exact-path guard `WebUiRedirect` carries, or it loops ahead of Quinoa.
- **`mvn verify` needs a free test port while the platform holds 8081**: `-Dquarkus.http.test-port=0`.
- **Cutovers can orphan queued runs and drop push events** (§1 catches, replay fixes). A real fix
  is unclaimed: notifier retry, or an intake catch-up comparing git tips to last runs at startup.

## 4. Tomorrow: the frontend iteration loop

Per-service UI change: push the `qits-spa-*` repo (its own CI keeps it green) → bump the gitlink
in the owning service repo:

    git -C service/src/main/webui fetch origin && git -C service/src/main/webui merge --ff-only origin/main
    git add service/src/main/webui && git commit && git push http://localhost:8080/artifacts/git/<repo> main

→ the service's pipeline rebuilds its image with the new bundle, cd swaps it in (gateway/artifacts
swaps blink the front door for a few seconds). For the landing page the "owning service repo" is
**qits-gateway** (`src/main/webui` = qits-spa-home). Note the gateway pinned spa-home at `73b4e50`
at handoff while spa-home's `main` had already moved (quinoa-unify merge) — bumping that gitlink
is likely tomorrow's first real change.

Also loose, non-blocking: home-repo gitlinks lag several submodules (advance with explicit
`git add <path>` only — `ignore = all` hides staged gitlinks from status/diff); `@qits` library
releases are version bumps in `projects/<lib>/package.json`; GitHub and the platform git host are
both canonical — push every change to BOTH, always.
