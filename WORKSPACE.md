# Workspace development flow

This checkout is an aggregate workspace. The wrapper and every checked-out submodule use the same workspace branch. Commit and push changes in the repository where they belong; the workspace credential has normal Git push access so each repository can move independently.

A local commit is not automatically part of the running environment, and **a push builds nothing** — per-push CI was retired on 2026-09-04. Changes reach the platform by being **released**, and a release starts as a release REQUEST in qits-projects. Shared libraries, SPAs and docs repositories are released into `main` and deploy nothing; applications and services are released, deployed by qits-deployments at the version coordinate, and only then finalized into `main`.

Release dependencies before their consumers, then let the affected application or service release carry the new versions into the environment. Keep the wrapper branch as the map of the workspace, but treat each submodule's own release as the unit that promotes code.

## Releasing from inside this container

**Branch → release request.** Never push `main` yourself, and there is no `environment/*` branch to push any more. Push your branch, then ask qits-projects to open a release request naming it. The route is machine-authenticated and this container carries its own identity — a commissioned idp client in `QITS_COMMISSIONED_CLIENT_ID` / `QITS_COMMISSIONED_CLIENT_SECRET` — so mint a bearer for the service you call. Platform services are dialed as `<tier>-qits-<name>:8080` on the platform network, and a token is cut for exactly one of them (its `audience` is that alias); `QITS_WORKSPACE_DAEMON_AUTH_AUDIENCE` names this tier's workspaces service (for example `dev-qits-workspaces`, so the tier is `dev`) and the release ask goes to `<tier>-qits-projects`.

    token() { curl -fsS -u "$QITS_COMMISSIONED_CLIENT_ID:$QITS_COMMISSIONED_CLIENT_SECRET" -d "grant_type=client_credentials&audience=$1" "$QITS_GIT_AUTH_TOKEN_URL" | jq -r .access_token; }
    PJ=http://dev-qits-projects:8080/projects/api
    PTOK=$(token dev-qits-projects)

    # the repository is addressed by its CATALOG ID, not its name
    curl -sS -H "Authorization: Bearer $PTOK" "$PJ/projects/$QITS_WORKSPACE_DAEMON_PROJECT_ID/repositories" | jq -r '.entries[].repository | "\(.name) \(.id)"'

    curl -sS -X POST -H "Authorization: Bearer $PTOK" -H 'Content-Type: application/json' \
      "$PJ/repositories/<repoId>/release-requests" \
      -d '{"branch":"<your branch>","summary":"<what this release is>"}'

The answer is `{"request": {id, state, backingBranch, mergedSha, …}}`. **Nothing merges and nothing is released at that call.** qits-projects folds `main`, your branch and any released tags still in flight onto a backing branch `release/<id>`, and re-folds it whenever any of those sources moves — so a commit you push afterwards is gated rather than smuggled in, which is why the ask carries no expected sha.

**The QA gate is a green verdict on the fold, and there are no exceptions.** `.config/qits/ci-event-release-request.yml` is the pipeline that produces it — the build, the tests and the userflows that used to run per push, now run once against the thing being released. Over a green verdict, Auto Release stamps the CalVer, bumps the manifests, tags, and publishes `SCMRelease`; `.config/qits/ci-event-release.yml` then builds `qits/<app>:<version>` and announces `SoftwareRelease`; qits-deployments opens a Deployment Request and deploys that version coordinate.

Poll the request with `GET $PJ/repositories/<repoId>/release-requests` until it is terminal. `PENDING` is waiting on the gate — the QA pipeline and one runner mean the queue drains slowly. `CONFLICTED` means the fold would not apply: merge `origin/main` into your branch, resolve, push, and the request re-arms itself. `REJECTED` means the gate went red — read the run in qits-ci, fix it, push. `RELEASED` carries the `version`.

**`main` moves last, and only for what deployed.** A repository that declares a `.config/qits/deployments.yml` is finalized into `main` when qits-deployments reports the version live — that ordering is the whole point of the flow. A repository that declares none (a library, an SPA, a docs repo) is finalized at the release itself, because nothing will ever deploy it.

**Trains.** Releasing an SPA or a library deploys nothing by itself: the service that embeds or depends on it follows by event — qits-maintenance commits a `bump(...)` onto that service's `maintenance/<dependency>` branch and opens a release request for it on its own. To ship a service change together with its SPA, release the SPA first and the service once the bump has reached the service's `main`; the service branch then folds cleanly on top of the new pin. Never move a submodule gitlink (`service/src/main/webui`) by hand to follow a release you made — the train owns that pin, and `git add -A` would stage it silently (`.gitmodules` says `ignore = all`); confirm with `git ls-tree HEAD <path>` before committing.

Your source branch is folded, not consumed: fetch and rebase onto `main` once the release has finalized before starting the next change in that repository. The wrapper's branch and this workspace are untouched by a submodule's release.

## Toolchain notes

- Run builds in a login shell (`bash -lc '...'`): `/etc/profile.d/qits-workspace.sh` gives the container uid a passwd entry (embedded-postgres suites need it) and adds `-s /etc/qits/maven-settings.xml` to `MAVEN_ARGS`, which is what lets Maven reach the platform's plain-http repository. `QITS_MAVEN_REPOSITORY_URL` names it; a pom's `registry.dev.localhost` default is dead in here, so pass `-Dqits.maven.repository.url=$QITS_MAVEN_REPOSITORY_URL` where a build asks for it. The local repository is `/caches/m2` (`MAVEN_OPTS`).
- `npm` on PATH is a shim that points the `@qits` scope at the platform registry and the rest at the npm mirror. The one thing it cannot fix is a `package-lock.json` whose `resolved` URLs name a developer host (`mirror.dev.localhost:8080`, `localhost:8082`): npm fetches tarballs by that URL and never asks the registry. Do what CI does — swap the origins and keep the paths (the integrity hashes keep it safe), install, then restore the lockfile before committing anything:

      sed -i -E -e 's#("resolved": ")https?://[^/"]+#\1'"${npm_config_registry%%/artifacts/*}"'#' -e 's#("resolved": ")https?://[^/"]+(/artifacts/npm/npm/)#\1'"${QITS_WORKSPACE_NPM_REGISTRY_URL%%/artifacts/*}"'\2#' package-lock.json
      npm ci --no-audit --no-fund
      git checkout -- package-lock.json

  Order matters: the broad mirror swap first, the path-anchored `@qits` correction second. A service's `mvn verify` runs that same install inside `service/src/main/webui` (Quinoa), so install there first and the package step passes.
- qits-projects, CI and every other platform API sit on the platform network at the aliases above; the public edge (`https://...`) wants a browser session, not this container's bearer.
