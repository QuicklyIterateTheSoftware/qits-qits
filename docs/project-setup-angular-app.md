# Standing up an `-app`

An `-app` is a standalone Angular SSR application: it serves itself from a node process, ships one
container image, and is deployed and addressed in its own right. It is the third thing an Angular
repository can be here, and the role is defined by what it publishes — a `jslib` publishes a package
on the `@qits` scope, a `frontend` publishes a bundle a service carries at `src/main/webui`, an
`app` publishes an image the platform deploys.

This is the steps, written after the first one — `qits-landing-app`, built 2026-09-22 — from what
that application actually took. It is deliberately not a second
[`project-setup-quinoa-angular.md`](project-setup-quinoa-angular.md): that file is 458 lines because
it is the reference for a configuration bought with bugs. This one is a list of steps, and the
reference material lives where it belongs — in `.config/qits/release-archetypes/app.yml`'s header,
and in `qits-landing-app`'s own README and file comments.

## 1. Create the repository, with one command

    qits repositories --project <project> create <name>-app --component <component>

That single call is the whole of it: it mints the bare on the git host from the repository template,
derives the GitHub backup twin, writes the qits-projects row, **and commits this wrapper's
`.gitmodules` entry and gitlink**. Nobody runs `git submodule add` — the "Adding a submodule"
section of `AGENTS.md` is the manual path, and this door is not it.

Measured for the first app, the door answered `archetype APP`, `component qits-landing`, wrapper
entry `components/qits-landing/qits-landing-app`.

**The name is the one thing to get right before typing it.** The archetype is derived from the
name's role suffix — `RepositoryArchetype.fromRepositoryName`, the only derivation of kind there is
— at mint, and never re-derived afterwards. A name with no role suffix stores a null archetype that
nothing in the service will correct later.

## 2. Pre-create the forge twin

If backups should land from the very first push, create the GitHub repository before you push. Its
address is this wrapper's own forge url folded with `../<name>.git`, the same relative resolution
`.gitmodules` uses — which is why one `.gitmodules` resolves the siblings on GitHub and on the
platform git host alike.

## 3. `ng new`, with SSR on

Measured: Angular CLI 22 declares `node: ^22.22.3 || ^24.15.0 || >=26.0.0`, and the workstation's
node 22.23.2 satisfies it, so **22.1.8 was used**. The "not Angular 22" constraint in
`project-setup-quinoa-angular.md` does **not** apply to an `-app`: it exists because Quinoa shells
out to the *host's* node during `mvn package`, and an `-app` has no Quinoa and no host node — it
builds inside its own image, on `node:24-alpine`.

Three traps come with the Angular 22 SSR scaffold, and every `-app` will hit all three.

**`security.allowedHosts` ships as `[]`, and that 400s every request.** Angular 22 validates `Host`
and `X-Forwarded-Host` against `projects.*.architect.build.options.security.allowedHosts`; the empty
list refuses everything, measured on a fresh build against `curl http://127.0.0.1:8080/`. Set
`["*"]`. That is the honest value rather than a shortcut: the edge is the trust boundary — nothing
reaches the container except through it — and the set of vhosts an `-app` legitimately answers on is
unbounded by design (its own vhost per tier, plus its path prefix on *every* other vhost the edge
serves).

**The scaffold's `{ path: '**', redirectTo: '' }` sends your published prefix somewhere else.** It
answers `/<prefix>` with a 302 to `/` — and `/<prefix>` is reached from foreign vhosts, where `/` is
somebody else's application. Measured: the browser is sent from the landing page to qits-ci's SPA.
Render the component instead (`{ path: '**', component: <Page> }`), which leaves the URL alone and
makes the app indifferent to whether the edge forwards the prefix or strips it.

**The SSR server defaults to port 4000.** `DeploymentSpecParser.DEFAULT_UPSTREAM_PORT` is 8080.
Either make `src/server.ts` listen on 8080 and state `ENV PORT=8080` in the Dockerfile, or declare
`upstream_port:` in `deployments.yml` — and whichever you pick, make the files agree.

## 4. Write the two `.config/qits` files

**`.config/qits/release.yml`** — the release cycle. It is `archetype: app` plus exactly one docker
artifact:

    archetype: app
    artifacts:
      - { type: docker, name: qits/<application> }

`artifacts:` must be in the repository's own file: qits-projects reads it out of the repository at
the tag, so an archetype default would be invisible to it. **Exactly one** — the recipe's release
step extracts the coordinate with a `sed -n` over one-line flow mappings and fails the release on
any other count, with the reason printed.

The Dockerfile does the `npm ci` and the `npm run build` **itself**; the recipe's `release:` step
runs `buildctl` and nothing else. That is the `app` archetype's one deliberate divergence from
`java-service`, and the reason is that the image a person builds on a workstation and the image CI
builds are then produced by the same instructions. The consequence is that the builder has none of
the step container's environment, so the @qits registry **origins** reach it as build args and the
**credential** reaches it as a buildkit secret (`--secret id=qits-npm-token`, mounted as a file at
`/run/secrets/qits-npm-token`) — never as a build arg, which is written into the image history of a
pullable image. `.config/qits/release-archetypes/app.yml`'s header is the contract; read it before
writing the first Dockerfile rather than re-deriving it here.

**`.config/qits/deployments.yml`** — how qits-platform-deployments deploys the image, read at the
released tag. Carrying the file at all is what makes the release the front half: the deployer opens
a Deployment Request and `main` is finalized only once the deployment succeeds.

- **`application:`** — state it. It defaults to the **repository** name, so an omitted line puts the
  `-app` role suffix into the swarm service, the wire alias (`dev-qits-landing-app`), the derived
  `host` label, the image path, the provisioned database name and the `QITS_APPLICATION` the
  container boots with. Six places, and changing the value later is a decommission plus a new
  application rather than a rename. `qits-landing-app` deploys as `qits-landing`.
- **`host:`** — also defaults off the repository name, same hazard. It is the DNS label:
  `<host>.<env>.<domain>`.
- **`routes:`** — at least one, or `DeploymentSpecParser` refuses the `host:`. Use the application's
  own segment (`/landing`, as qits-ci takes `/ci`). Never `/`: it is syntactically legal, is
  path-routed on every vhost, and would claim every path of every application on the platform.
- **`health_path:`**, not `health_cmd:`. A node server answers a path; `health_cmd:` exists for a
  deployable with no HTTP surface at all. The derived default is a Quarkus shape
  (`/<prefix>/q/health/ready`) that nothing here serves, so taking it fails every deployment as
  unhealthy after the container came up perfectly well. Put the path under the published prefix so
  it is answerable from outside the container too.
- **The image owes that path a `curl`.** The gate is `curl -fsS
  http://localhost:<port><health_path> || exit 1`, run *inside* the container, and `node:*-alpine`
  ships busybox `wget` and no `curl` — so the runtime stage needs `RUN apk add --no-cache curl`
  before it drops to the non-root user. Omit it and you get the same failure this bullet warns about
  from the other end, wearing a disguise: the container boots, logs that it is listening, and is then
  killed with `exit (137): dockerexec: unhealthy container` and rolled back. It reads as an
  application fault and is not one — the probe is exiting 127. Every sibling on the estate is
  `ubi-minimal` and gets `curl` from the base, which is why this had never been written down before
  `qits-landing` hit it.
- **`deployment_target: environment`** — one instance per tier, with the tier in the wire alias.
- **`upstream_port:`** only if the server is not on 8080.

## 5. The first `release.yml` cannot ride its own first release

This is the single hardest thing the first application hit, and it is not a property of `-app`
repositories — it is a property of *new* repositories.

qits-ci composes the publish run from the repository's **`main` head**:
`CiEventTriggerService.evaluateRepo` reads the release slots at the head the trigger listing
resolved for `main` (`TRIGGER_BRANCH = "main"`). The release request's publish gate reads the
**tag**: `releasePhaseAt`, which qits-projects' `ReleaseFinalization` asks at `refs/tags/<version>`.

So the first release whose *tag* declares a `release:` slot stamps a publish gate that no run will
ever answer — because at the moment the trigger fired, `main` had no slot to compose from. The
request sits RELEASED for good and `main` never moves.

The way through is **one direct commit of `.config/qits/release.yml` onto `main`**, through the
githost commit primitive `POST /githost/api/repositories/{repoId}/commits`. That door needs
`qits:system` and therefore a person: an agent credential is refused both it (403, measured) and a
push to `main` (`refs/heads/main is outside the push scope`, measured). This is the shape the estate
already uses — `qits-coding-agents` carries `release.yml` as the **second commit on its `main`**,
pushed directly, before any release.

**So an agent standing up an `-app` lands everything except `.config/qits/release.yml` in the first
release, and hands that one file to a person.** After that commit, an ordinary release request
publishes the image and deploys it.

## 6. Release it, and look at it

Open the release request the ordinary way (`docs/development-flow.md`), let the publish slot push
the image and the deployer roll it out, then open `<component>.<env>.<domain>` in a browser. A
passing pipeline is not the claim; the claim is that the page renders where it is addressed, and
only the environment answers that.
