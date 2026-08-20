# Workspace development flow

This checkout is an aggregate workspace. The wrapper and every checked-out submodule use the same workspace branch. Commit and push changes in the repository where they belong; the workspace credential has normal Git push access so each repository can move independently.

A local commit is not automatically part of the running environment. Changes have to be orchestrated by **releasing** them: shared libraries and SPAs are released into `main` only, while applications and services are released into `main` and promoted onto the environment branch that runs them (for example `environment/dev`) — the green build of that branch is what deploys.

Release dependencies before their consumers, then let the affected application or service release carry the new versions into the environment. Keep the wrapper branch as the map of the workspace, but treat each submodule's own release as the unit that promotes code.

## Releasing from inside this container

**Branch → door.** Never push `main` or `environment/*` yourself. Push your branch (every push already builds it in CI), and when the build is green ask qits-workspaces to release the branch. The door is machine-authenticated and this container carries its own identity — a commissioned idp client in `QITS_COMMISSIONED_CLIENT_ID` / `QITS_COMMISSIONED_CLIENT_SECRET` — so mint a bearer for the service you call. Platform services are dialed as `<tier>-qits-<name>:8080` on the platform network, and a token is cut for exactly one of them (its `audience` is that alias); `QITS_WORKSPACE_DAEMON_AUTH_AUDIENCE` names this tier's workspaces service (for example `dev-qits-workspaces`, so the tier is `dev`).

    token() { curl -fsS -u "$QITS_COMMISSIONED_CLIENT_ID:$QITS_COMMISSIONED_CLIENT_SECRET" -d "grant_type=client_credentials&audience=$1" "$QITS_GIT_AUTH_TOKEN_URL" | jq -r .access_token; }
    WS=http://$QITS_WORKSPACE_DAEMON_AUTH_AUDIENCE:8080/workspaces/api

    curl -sS -X POST -H "Authorization: Bearer $(token $QITS_WORKSPACE_DAEMON_AUTH_AUDIENCE)" -H 'Content-Type: application/json' "$WS/branches/release?repositoryId=<repository>" -d '{"branch":"<your branch>","summary":"<what this release is>"}'

The answer is `{"version","commitSha","branch","promotions"}`: one commit `release(<version>): <summary>` merged into `main`, tagged and announced. `promotions` lists the deploy branches the commit was pushed onto — **empty for a library or an SPA** (they have no `.config/qits/deployments.yml`, so nothing deploys and that is correct), and for a service each entry carries an `error` when that promotion failed. A `409` with reason `ALREADY_INTEGRATED` means the branch was already released. Watch the build that ships it: `curl -sS -H "Authorization: Bearer $(token <tier>-qits-ci)" http://<tier>-qits-ci:8080/ci/api/runs/active` (and `/ci/api/runs/finished?limit=10`) — the deploy is the green run of the environment branch at your merge commit.

**Trains.** Releasing an SPA or a library deploys nothing by itself: the service that embeds or depends on it follows by event — CI commits a `bump(...)` onto that service's `maintenance/<dependency>` branch and releases it on its own. To ship a service change together with its SPA, release the SPA first and the service once the bump has reached the service's `main`; the service branch then merges cleanly on top of the new pin. Never move a submodule gitlink (`service/src/main/webui`) by hand to follow a release you made — the train owns that pin, and `git add -A` would stage it silently (`.gitmodules` says `ignore = all`); confirm with `git ls-tree HEAD <path>` before committing.

**After a release the source branch is gone in that repository** (the door deletes it). Your local checkout still holds it; `git fetch && git switch main` there before the next change. The wrapper's branch and this workspace are untouched by a submodule's release.

## Toolchain notes

- Run builds in a login shell (`bash -lc '...'`): `/etc/profile.d/qits-workspace.sh` gives the container uid a passwd entry (embedded-postgres suites need it) and adds `-s /etc/qits/maven-settings.xml` to `MAVEN_ARGS`, which is what lets Maven reach the platform's plain-http repository. `QITS_MAVEN_REPOSITORY_URL` names it; a pom's `registry.dev.localhost` default is dead in here, so pass `-Dqits.maven.repository.url=$QITS_MAVEN_REPOSITORY_URL` where a build asks for it. The local repository is `/caches/m2` (`MAVEN_OPTS`).
- `npm` on PATH is a shim that points the `@qits` scope at the platform registry and the rest at the npm mirror. The one thing it cannot fix is a `package-lock.json` whose `resolved` URLs name a developer host (`mirror.dev.localhost:8080`, `localhost:8082`): npm fetches tarballs by that URL and never asks the registry. Do what CI does — swap the origins and keep the paths (the integrity hashes keep it safe), install, then restore the lockfile before committing anything:

      sed -i -E -e 's#("resolved": ")https?://[^/"]+#\1'"${npm_config_registry%%/artifacts/*}"'#' -e 's#("resolved": ")https?://[^/"]+(/artifacts/npm/npm/)#\1'"${QITS_WORKSPACE_NPM_REGISTRY_URL%%/artifacts/*}"'\2#' package-lock.json
      npm ci --no-audit --no-fund
      git checkout -- package-lock.json

  Order matters: the broad mirror swap first, the path-anchored `@qits` correction second. A service's `mvn verify` runs that same install inside `service/src/main/webui` (Quinoa), so install there first and the package step passes.
- The release door, CI and every other platform API sit on the platform network at the aliases above; the public edge (`https://...`) wants a browser session, not this container's bearer.
