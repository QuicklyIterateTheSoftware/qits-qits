# Releasing from inside a workspace container

How an agent working **inside a workspace container** gets a change from its checkout onto the
running platform, with no help from outside the container. Verified end-to-end on wohlben.eu
(2026-08-20), repeatedly: a qits-workspaces fix released as `2026.820.64615` and
pipeline-deployed; a qits-githost fix authored, tested, pushed and released **from inside an
ad-hoc workspace container** as `2026.820.65553` and pipeline-deployed; a qits-userflows
(library) change released the same way as `2026.820.70117` — merge to `main` only, empty
`promotions`, Maven artifact published by the release pipeline; and, the same afternoon, the
observability explorer's two branches (SPA `2026.820.131011`, then the service `2026.820.131608`
on top of the automatic pin bump) plus three platform fixes, every one of them released **with the
workspace container's own bearer** — the identity every agent in a workspace holds.

The short form of all this is the `WORKSPACE.md` an ad-hoc workspace is born with (the template
lives in qits-workspaces, `WorkspaceService.WORKSPACE_GUIDE`). This file is the long form.

The platform doctrine in one line: **branch → door**. You push a *branch* to the git host and ask
the workspaces service to release it; nothing else ever writes `main` or the deploy branches.

## The container you are standing in

Every workspace container carries the toolchain (JDK 25, maven wrapper support, node/pnpm, git) and
three credentials/knobs that make the flow work:

- **Git**: the credential helper (`/usr/local/bin/qits-git-credential`, wired via
  `/etc/qits-gitconfig`) answers the injected githost authority with a short-lived bearer minted
  from the container's commissioned client. `git fetch`/`git push` against
  `$QITS_WORKSPACE_DAEMON_GIT_BASE_URL` (e.g. `http://githost.dev.internal:8080/git/<repo>`) just
  work.
- **Maven**: `QITS_MAVEN_REPOSITORY_URL` names the platform's Maven repository
  (in-network: `http://dev-qits-artifacts:8080/artifacts/maven/maven`). The login-shell profile
  (`/etc/profile.d/qits-workspace.sh`) adds `-s /etc/qits/maven-settings.xml` to `MAVEN_ARGS`,
  which is what defeats Maven's plain-HTTP blocker. **Run builds through `bash -lc`** (the daemon
  does this for every command it starts) so the profile applies.
- **Platform APIs — your own identity**: the container carries a commissioned idp client
  (`QITS_COMMISSIONED_CLIENT_ID` / `QITS_COMMISSIONED_CLIENT_SECRET`, the token endpoint in
  `QITS_GIT_AUTH_TOKEN_URL`). A token is cut for **one** service — the `audience` is that service's
  alias on the platform network (`dev-qits-workspaces`, `dev-qits-ci`, …; the tier prefix is the one
  `QITS_WORKSPACE_DAEMON_AUTH_AUDIENCE` carries). Mint per call:

  ```sh
  token() { curl -fsS -u "$QITS_COMMISSIONED_CLIENT_ID:$QITS_COMMISSIONED_CLIENT_SECRET" \
              -d "grant_type=client_credentials&audience=$1" "$QITS_GIT_AUTH_TOKEN_URL" | jq -r .access_token; }
  curl -H "Authorization: Bearer $(token dev-qits-workspaces)" http://dev-qits-workspaces:8080/workspaces/api/…
  ```

  Workspace images from `qits/workspace-base` 2026.820.131511 on ship this as `qits-token <audience>`.
  The token's `groups` claim carries the roles the door checks (`qits:system`, `qits-platform:system`,
  `qits:admin` — the idp issues a commissioned client its owner's roles, and since 2026-08-20 the
  workspaces client carries `qits:admin` like the ci client). **The public edge is not a door for
  this bearer** — `https://wohlben.eu/...` wants a browser session; talk to the services by their
  in-network aliases.

## Step by step

Work in the submodule the change belongs to. In an **ad-hoc (aggregate) workspace** every
registered submodule is already checked out on the workspace branch, so you edit, commit and push
on that branch directly. In an older or single-repo workspace, first get the submodule onto a real
branch:

```sh
cd /workspace/services/<repo>
git fetch origin                      # see wrinkles below if this 404s
git switch -c my-fix origin/main      # or: git switch <workspace-branch>
```

1. **Change + test.** Build with the wrapper through a login shell so the Maven settings apply:

   ```sh
   bash -lc './mvnw -B -pl domain -am test -Dqits.maven.repository.url=$QITS_MAVEN_REPOSITORY_URL'
   ```

2. **Commit and push the branch** (never `main`, never `environment/*`):

   ```sh
   git push -u origin my-fix
   ```

   The push alone triggers a POST_RECEIVE CI run for the branch — a free pre-release validation of
   the very commit you are about to release. Watch it:

   ```sh
   curl -s -H "Authorization: Bearer $(token dev-qits-ci)" http://dev-qits-ci:8080/ci/api/runs/active
   ```

   (Or push with `-o qits.no-ci` when the release's own build is validation enough — the door
   builds `main` and the deploy branch regardless — and keep the single CI slot free.)

3. **Release through the door.** The branch needs no workspace row of its own:

   ```sh
   curl -s -X POST -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $(token dev-qits-workspaces)" \
        -d '{"branch":"my-fix","summary":"What this release is"}' \
        'http://dev-qits-workspaces:8080/workspaces/api/branches/release?repositoryId=<repo>'
   ```

   The answer carries the minted CalVer version, the merge commit sha, and `promotions`:

   ```json
   {"version":"2026.820.64615","commitSha":"fdeb676…","branch":"my-fix",
    "promotions":[{"branch":"environment/dev","error":null}]}
   ```

   (A workspace's own branch has a sibling door: `POST /workspaces/api/workspaces/<id>/release`.
   Same flow, keyed by workspace id instead of branch name.)

4. **What the door did** — one commit `release(<version>): <summary>` merged into `main`, tagged,
   pushed, and then:
   - **Service / application** (repo declares deploy branches in `.config/qits/deployments.yml`):
     the same commit is fast-forwarded to each deploy branch (`environment/dev` for dev-tier
     services, `platform/main` for platform services). *That* push is what deploys: its
     POST_RECEIVE CI run builds the image and pushes it under the commit sha; a green run announces
     BuildSuccessful and qits-deployments cuts the running container over to the new sha. A second
     run (SCMRelease-triggered, `ci-event-release.yml`) additionally publishes the image under the
     CalVer tag.
   - **Library** (no deployments.yml → no deploy branches): `promotions` comes back **empty** — the
     release is the merge into `main` plus the pipeline that publishes the Maven artifact under the
     released version. Nothing deploys; consumers pick the version up via their upstream bump
     trains (or a hand pin bump).

5. **Verify.** CI: `GET http://dev-qits-ci:8080/ci/api/runs/finished?limit=10` — look for your
   commit sha on the deploy branch with `"status":"SUCCESS"`. Deployment: the running service
   container's image tag becomes your merge commit sha (visible on the deployments UI, or to an
   operator via `docker ps`). Release order matters: release **dependencies before consumers**
   (libs first, then the services that pin them).

## Wrinkles an agent will hit (all real, all observed)

- **Submodule remotes carry a `.git` suffix the githost refuses** (404 "repository not found" on
  `git fetch`). The wrapper's `.gitmodules` says `../<name>.git`, so every submodule origin ends in
  `.git`, but the githost's id-addressed route only accepted the bare name. Fixed in qits-githost
  (`.git` is stripped as an alias); on an older githost the workaround is
  `git remote set-url origin ${QITS_WORKSPACE_DAEMON_GIT_BASE_URL}/<repo>`.
- **Detached HEAD in submodules.** A non-aggregate workspace checks submodules out at the recorded
  gitlink, detached and possibly weeks old. Always `git fetch` + `git switch` onto a real branch
  before working.
- **Maven "Blocked mirror … http://0.0.0.0/"** means the profile did not apply: you are not in a
  login shell. Prefix builds with `bash -lc`, or pass
  `-s /etc/qits/maven-settings.xml` (or the repo's own `.qits-maven-settings.xml`) plus
  `-Dqits.maven.repository.url=$QITS_MAVEN_REPOSITORY_URL` by hand.
- **`initdb: could not look up effective user ID`** in embedded-postgres test suites means the
  container's uid has no passwd entry — also a login-shell fix (the profile appends one). Old
  containers (pre-profile image) lack both fixes; recreate the container
  (`POST /workspaces/api/workspaces/<id>/recreate-container`) to get the current image.
- **`registry.dev.localhost:8080` (the pom default) is dead in-container.** It resolves but
  refuses connections on qits-net. Always supply
  `-Dqits.maven.repository.url=$QITS_MAVEN_REPOSITORY_URL`.
- **A release that answers 200 with empty `promotions`** on a repo you expected to deploy means the
  repo declares no deploy branches — check its `.config/qits/deployments.yml` is present on the
  released commit.
- **No `mvnw` in the repo.** The container image ships no system Maven; a repo without a wrapper
  (qits-userflows today) builds via a sibling's wrapper:
  `/workspace/services/qits-workspaces/mvnw -f pom.xml test …`.
- **`npm ci` in an SPA dies with 401/404 on tarballs.** The lockfile pins full `resolved` URLs
  minted on the deployment host (`mirror.dev.localhost:8080`, …), and npm fetches tarballs by that
  URL, never via the configured registry (`npm` itself is a shim that already carries the `@qits`
  scope — that is not the problem). Images from `qits/workspace-base` 2026.820.131511 on ship
  `qits-npm-ci`, which swaps the origins for the install and restores the lockfile byte for byte.
  On an older image do by hand what it and CI do — swap the origins, keep the paths (integrity
  hashes make it safe), and restore the lockfile before committing:

  ```sh
  sed -i -E \
    -e 's#("resolved": ")https?://[^/"]+#\1'"${npm_config_registry%%/artifacts/*}"'#' \
    -e 's#("resolved": ")https?://[^/"]+(/artifacts/npm/npm/)#\1'"${QITS_WORKSPACE_NPM_REGISTRY_URL%%/artifacts/*}"'\2#' \
    package-lock.json
  npm ci --no-audit --no-fund
  git checkout -- package-lock.json
  ```

  (Order matters: broad proxy swap first, the path-anchored @qits correction second. SPA unit
  tests then run on jsdom — `npm run test` — no browser needed.) A service's `mvn verify` runs the
  same install inside `service/src/main/webui` through Quinoa, so install there first and the
  package step passes; `mvn test` alone never needed it.
- **The release door answers 403 to the container's bearer** (401 without one, 404 on a route that
  exists — so the token authenticates and is refused). That was every workspace on wohlben.eu until
  2026-08-20: the idp issues a commissioned client its *owner's* roles, the workspaces client had
  `qits:system` only, and the door is `@RolesAllowed("qits:admin")`. Fixed by config — the
  qits-configuration entry `env.QITS_IDP_CLIENT_DEV_QITS_WORKSPACES_ROLES` for application
  `qits-platform-idp` now ends in `,qits:admin` and the idp was redeployed (`POST
  /platform-deployments/api/events/build-succeeded` re-posting its own sha re-reads the extras) —
  and in the bootstrap default (qits-cli-bootstrap `2026.820.131511`, `ComposeTemplate`). A platform
  booted from an older bootstrap needs that one entry and one idp redeploy; the acceptance test is a
  `200` from the door for a bearer minted from the container's pair.
- **A pin train ships an SPA; your service release rides on top of it.** Releasing an SPA or a lib
  deploys nothing (`promotions: []`); the consuming service's `ci-event-upstream-*.yml` commits a
  `bump(...)` onto `maintenance/<dependency>`, whose post-receive run releases it with the run's own
  commissioned bearer (it carries `qits:admin`; measured working 2026-08-20, runs `c7a36b5a` and
  `81e079a8`). Release the SPA, wait for the bump to reach the service's `main` (minutes), then
  release the service branch — it merges on top of the new pin. Never move the gitlink by hand.
- **Ad-hoc creation 409 "Branch already exists in <repo>"**: a leftover branch from an earlier
  tree (the guard reports one repo at a time). If `POST /workspaces/api/branches/cleanup` refuses
  (it will, for unmerged commits), inspect the branch (`git log main..<branch>`) and, when it holds
  nothing worth keeping, delete the ref: `git push origin --delete <branch>` — workspace branches
  are unprotected.
- **Branch creation used to queue a CI build in every registered repo** (~45 POST_RECEIVE runs of
  content identical to main per ad-hoc tree). Fixed in qits-workspaces `2026.820.73213`: every
  branch-*creation* push carries `-o qits.no-ci`, so a create at an existing tip builds nothing —
  the first commit you push onto the branch triggers the branch's first build. If you ever see a
  quiet-branch storm on an older platform, the policy is to cancel the runs
  (`POST /ci/api/runs/{id}/cancel` with a reason).
- **The release deletes its source branch**, so a branch build still *queued* at release time dies
  with `CLONE_FAILED: Remote branch … not found` — a spurious red run, not your change failing.
  Either let the branch build finish before releasing, or cancel it first.
- **After a submodule's release the workspace branch is gone in that submodule.** The local
  checkout keeps a now-orphaned branch; `git fetch && git switch main` (or push a fresh branch) for
  the next change. The wrapper's workspace row and branch are untouched by submodule releases.
- **Discarding a dirty workspace**: the plain discard is refused by the clean-tree guard; the UI
  then offers a confirmation whose accept re-sends `POST …/discard?ignore-changes=true` (since
  workspaces `2026.820.90633` / spa `.90640`). The override is URL-only by design — never put it on
  a first request.
- **Discarding an aggregate workspace leaves the submodule branches behind** (only the wrapper's
  branch is deleted — open gap). Sweep them like the stale-branch case above: for each registered
  repo, delete the branch iff `git log main..<branch>` is empty.

## Ad-hoc (aggregate) workspaces

The `/workspaces/` overview and each project page offer the ad-hoc creator: one branch name
(default `adhoc-changes`), taken in the wrapper **and every registered submodule**, with
`WORKSPACE.md` published on the wrapper's copy. The container then checks everything out on that
branch, so cross-repo work commits and pushes per submodule, on one shared branch name, and each
submodule releases through its own door when ready.

Fixed 2026-08-20: creation failed platform-wide ("Not currently on any branch. nothing to commit")
once a previously released `WORKSPACE.md` had reached the wrapper's `main` — the guide write was
not idempotent (qits-workspaces `2026.820.64615`).
