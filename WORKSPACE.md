# Workspace development flow

This checkout is an aggregate workspace. The wrapper and every checked-out submodule use the same workspace branch. Commit and push changes in the repository where they belong; the workspace credential has normal Git push access so each repository can move independently.

A local commit is not automatically part of the running environment. Changes have to be orchestrated by **releasing** them: a release request folds your branch with `main` (and with every released tag not yet merged back), the quality gate builds that fold, and a green gate turns it into a version **tag**. A service's deployment follows from that release; `main` is merged only once the deployment is live.

Release dependencies before their consumers, then let the affected application or service release carry the new versions into the environment. Keep the wrapper branch as the map of the workspace, but treat each submodule's own release as the unit that promotes code.

## Releasing from inside this container

**Branch → release request.** Never push `main` yourself. Push your branch, then ask **qits-projects** to release it. The door is machine-authenticated and this container carries its own identity — a commissioned idp client in `QITS_COMMISSIONED_CLIENT_ID` / `QITS_COMMISSIONED_CLIENT_SECRET` — so mint a bearer for the service you call. Platform services are dialed as `<tier>-qits-<name>:8080` on the platform network, and a token is cut for exactly one of them (its `audience` is that alias); `QITS_WORKSPACE_DAEMON_AUTH_AUDIENCE` names this tier's workspaces service (for example `dev-qits-workspaces`, so the tier is `dev`).

    token() { curl -fsS -u "$QITS_COMMISSIONED_CLIENT_ID:$QITS_COMMISSIONED_CLIENT_SECRET" -d "grant_type=client_credentials&audience=$1" "$QITS_GIT_AUTH_TOKEN_URL" | jq -r .access_token; }
    PROJECTS=http://<tier>-qits-projects:8080/projects/api

    curl -sS -X POST -H "Authorization: Bearer $(token <tier>-qits-projects)" -H 'Content-Type: application/json' "$PROJECTS/repositories/<repository>/release-requests" -d '{"branch":"<your branch>","summary":"<what this release is>"}'

Nothing has merged when that answers. The request folds `main`, your branch and every released tag still in flight onto its own `release/<id>` branch, the QA pipeline builds that fold, and a green gate releases it: the manifests are stamped, the fold is tagged with the version, and the source branches are deleted. Poll the request (`GET $PROJECTS/repositories/<repository>/release-requests/<id>`) until it reads `RELEASED` — `CONFLICTED` means the fold does not merge and is yours to resolve, `FAILED` and `REJECTED` say why in `detail`. Watch the build behind it: `curl -sS -H "Authorization: Bearer $(token <tier>-qits-ci)" http://<tier>-qits-ci:8080/ci/api/runs/active` (and `/ci/api/runs/finished?limit=10`).

**Trains.** Releasing an SPA or a library deploys nothing by itself: the service that embeds or depends on it follows by event — CI commits a `bump(...)` onto that service's `maintenance/<dependency>` branch and releases it on its own. To ship a service change together with its SPA, release the SPA first and the service once the bump has reached the service's `main`; the service branch then merges cleanly on top of the new pin. Never move a submodule gitlink (`service/src/main/webui`) by hand to follow a release you made — the train owns that pin, and `git add -A` would stage it silently (`.gitmodules` says `ignore = all`); confirm with `git ls-tree HEAD <path>` before committing.

**After a release the source branch is gone in that repository** (the release deletes it). Your local checkout still holds it; `git fetch && git switch main` there before the next change. Note `main` catches up only after the deployment, so a freshly released repository can sit at the tag for a while. The wrapper's branch and this workspace are untouched by a submodule's release.

## Toolchain notes

- Run builds in a login shell (`bash -lc '...'`): `/etc/profile.d/qits-workspace.sh` gives the container uid a passwd entry (embedded-postgres suites need it) and adds `-s /etc/qits/maven-settings.xml` to `MAVEN_ARGS`, which is what lets Maven reach the platform's plain-http repository. `QITS_MAVEN_REPOSITORY_URL` names it; a pom's `registry.dev.localhost` default is dead in here, so pass `-Dqits.maven.repository.url=$QITS_MAVEN_REPOSITORY_URL` where a build asks for it. The local repository is `/caches/m2` (`MAVEN_OPTS`). The same settings file routes **Maven Central** through the platform's pull-through cache whenever `QITS_MAVEN_CENTRAL_URL` is set (it is, by default); unset or empty and Central is dialled directly, which is the only difference.
- `npm` on PATH is a shim that points the `@qits` scope at the platform registry and the rest at the npm mirror. The one thing it cannot fix is a `package-lock.json` whose `resolved` URLs name a developer host (`mirror.dev.localhost:8080`, `localhost:8082`): npm fetches tarballs by that URL and never asks the registry. Do what CI does — swap the origins and keep the paths (the integrity hashes keep it safe), install, then restore the lockfile before committing anything:

      sed -i -E -e 's#("resolved": ")https?://[^/"]+#\1'"${npm_config_registry%%/artifacts/*}"'#' -e 's#("resolved": ")https?://[^/"]+(/artifacts/npm/npm/)#\1'"${QITS_WORKSPACE_NPM_REGISTRY_URL%%/artifacts/*}"'\2#' package-lock.json
      npm ci --no-audit --no-fund
      git checkout -- package-lock.json

  Order matters: the broad mirror swap first, the path-anchored `@qits` correction second. A service's `mvn verify` runs that same install inside `service/src/main/webui` (Quinoa), so install there first and the package step passes.
- qits-projects, CI and every other platform API sit on the platform network at the aliases above; the public edge (`https://...`) wants a browser session, not this container's bearer.
