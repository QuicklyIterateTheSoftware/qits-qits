# Workspace development flow

This checkout is an aggregate workspace. The wrapper and every checked-out submodule use the same workspace branch. Commit and push changes in the repository where they belong; the workspace credential has normal Git push access so each repository can move independently.

A local commit is not automatically part of the running environment. Changes have to be orchestrated by **releasing** them: a release request folds your branch with `main` (and with every released tag not yet merged back), the quality gate builds that fold, and a green gate turns it into a version **tag**. A service's deployment follows from that release; `main` is merged only once the deployment is live.

Release dependencies before their consumers, then let the affected application or service release carry the new versions into the environment. Keep the wrapper branch as the map of the workspace, but treat each submodule's own release as the unit that promotes code.

## Releasing from inside this container

**Branch → release request.** Never push `main` yourself. Push your branch, then ask **qits-projects** to release it. Use `qits` first (next section): `qits release-request create --project <project> --repository <repository> --branch <your branch> --summary '<what this release is>'` is the door with the credential handled for you. The fallback is a hand-written `curl` against the service's public name, `https://<app>.qits.$QITS_DOMAIN/…`, with the bearer `qits-token qits-platform` prints — it works from the platform network and from a runner node alike, because the public names answer from both:

    PROJECTS=https://projects.qits.$QITS_DOMAIN/projects/api

    curl -sS -X POST -H "Authorization: Bearer $(qits-token qits-platform)" -H 'Content-Type: application/json' "$PROJECTS/repositories/<repository>/release-requests" -d '{"branch":"<your branch>","summary":"<what this release is>"}'

Nothing has merged when that answers. The request folds `main`, your branch and every released tag still in flight onto its own `release/<id>` branch, the QA pipeline builds that fold, and a green gate releases it: the manifests are stamped, the fold is tagged with the version, and the source branches are deleted. Poll the request (`GET $PROJECTS/repositories/<repository>/release-requests/<id>`) until it reads `RELEASED` — `CONFLICTED` means the fold does not merge and is yours to resolve, `FAILED` and `REJECTED` say why in `detail`. Watch the build behind it: `curl -sS -H "Authorization: Bearer $(qits-token qits-platform)" https://ci.qits.$QITS_DOMAIN/ci/api/runs/active` (and `/ci/api/runs/finished?limit=10`).

**Trains.** Releasing an SPA or a library deploys nothing by itself: the service that embeds or depends on it follows by event — CI commits a `bump(...)` onto that service's `maintenance/<dependency>` branch and releases it on its own. To ship a service change together with its SPA, release the SPA first and the service once the bump has reached the service's `main`; the service branch then merges cleanly on top of the new pin. Never move a submodule gitlink (`service/src/main/webui`) by hand to follow a release you made — the train owns that pin, and `git add -A` would stage it silently (`.gitmodules` says `ignore = all`); confirm with `git ls-tree HEAD <path>` before committing.

**After a release the source branch is gone in that repository** (the release deletes it). Your local checkout still holds it; `git fetch && git switch main` there before the next change. Note `main` catches up only after the deployment, so a freshly released repository can sit at the tag for a while. The wrapper's branch and this workspace are untouched by a submodule's release.

## The qits CLI

`qits` is on PATH and already signed in by this container's credential, so there is no `qits login` to run in here. That credential is one of two: `QITS_TOKEN` on a runner-placed workspace — one opaque token, used as it is — or the commissioned pair `QITS_COMMISSIONED_CLIENT_ID` / `QITS_COMMISSIONED_CLIENT_SECRET`, from which a bearer is minted once per process and kept in memory, never written to disk. It finds each service by itself, so none of the addressing above has to be composed by hand.

    qits work list --project qits
    qits ci runs --project qits --repository <repository> --limit 3
    qits release-request --project qits --repository <repository> list

`qits events` and `qits observe` are the other two an agent reaches for; `qits --help` lists everything, and `qits help skill` prints the whole surface as a SKILL.md. The credential is `qits:agent`: reads answer, and an operator write comes back `403 - this credential is qits:agent, which reads but does not write`. That is the credential doing its job, not a misconfiguration — a write that matters goes through the release request above, or through a person.

The two shell helpers keep their jobs and carry whichever credential this container holds: `qits-git-credential` is git's credential helper, and `qits-token qits-platform` prints the bearer for a hand-written `curl`.

## Toolchain notes

- Run builds in a login shell (`bash -lc '...'`): `/etc/profile.d/qits-workspace.sh` gives the container uid a passwd entry (embedded-postgres suites need it) and adds `-s /etc/qits/maven-settings.xml` to `MAVEN_ARGS`. The local repository is `/caches/m2` (`MAVEN_OPTS`).
- Package registries are derived from `QITS_DOMAIN` and nothing else: the platform's own packages (the `@qits` npm scope, the hosted Maven repository) at `https://registry.qits.<domain>`, npmjs and Maven Central through the caches at `https://mirror.qits.<domain>`. The `npm` shim on PATH and the Maven settings file authenticate both with this container's credential, so no `.npmrc` token and no `-D` repository override is needed — plain `npm ci` / `npm install` and `mvn` just work. A lockfile committed from here only ever names those public https hosts; never rewrite its `resolved` URLs. A service's `mvn verify` runs the same install inside `service/src/main/webui` (Quinoa).
- qits-projects, CI and every other platform API answer at their public names, `https://<app>.qits.<domain>`: the public edge accepts this container's bearer on every service vhost, so the same `curl` works wherever this container runs.
