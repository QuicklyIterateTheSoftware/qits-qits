# qits-qits

QuicklyIterateTheSoftware (qits) is a self-hosting PaaS. It deploys
applications across environments and automates routine updates.

The platform is built around agentic code editing. It follows Spec Driven
Design with one twist: the code is the spec. The platform only works when
the code is written like one.

Using this approach will most likely not work with brownfield projects.

Set `QITS_DOMAIN` at bootstrap to serve a real domain: qits-platform-dns
becomes its authoritative nameserver and the edge gets HTTPS with a Let's
Encrypt certificate slot. See the qits-bootstrap-cli README for the knobs
and the issuance step.

## Credentials on a development host

Every request through the edge — maven, npm, docker, git, plain curl —
authenticates, reads included. Your personal credential is a client the
idp commissions for this machine: run the one-liner the bootstrap report
prints (a `POST /idp/api/clients` from a container on qits-net,
authorized by the `dev-qits-artifacts` client whose secret is in
`.qits-bootstrap.env`). The answer's `clientId` and `secret` are the
pair; keep them in `~/.qits-workstation-client` and
`~/.qits-workstation-secret`.

The pair is wired in three places, and all three must carry the same
one: `~/.npmrc` with a per-registry `_auth` line (base64 of
`client:secret`) for each of the two npm vhosts, `~/.m2/settings.xml`
with a `<server>` entry whose id matches the `qits-maven-host` mirror,
and `docker login` against the registry and mirror vhosts. Project
`.npmrc` files and poms only pick addresses; the answer to their 401s
always comes from these host-level files.

The rows do not survive a re-bootstrap. When every registry suddenly
answers 401, nothing is broken: commission a fresh client and rewrite
the three consumers. Hand the credential back when the machine is
retired: `DELETE /idp/api/clients/<clientId>`.

## Branching model

There are no deploy branches. A release is a **release request** on
qits-projects, and a version — not a branch — is what deploys. The
`environment/*` and `platform/*` branch archetypes were retired on
2026-09-04 along with per-push CI.

You push a working branch and ask qits-projects to release it. It folds
`main`, that branch and any released tags still in flight onto a backing
branch `release/<id>`, and re-folds whenever one of those moves. The
repository's `.config/qits/ci-event-release-request.yml` builds that fold
and returns a verdict; **a green gating verdict is the whole quality gate,
and there are no exceptions**. Over a green one the platform stamps the
calendar version, bumps the manifests, tags, and publishes an SCMRelease
event. `.config/qits/ci-event-release.yml` then builds the image at
`qits/<app>:<version>` and announces SoftwareRelease, which is what
qits-deployments deploys.

`main` is the final destination of the code, and it moves **last**. A
repository that declares a `.config/qits/deployments.yml` is finalized
into `main` only once the deployer reports that version live; a
repository that declares none — a library, an SPA, a docs repo — is
finalized at the release itself, because nothing will ever deploy it. A
push to `main` builds and deploys nothing.

`maintenance/*` branches are opened automatically. qits-maintenance keeps
an inventory of every pin in every repository — maven properties and
dependencies, npm entries, Dockerfile image ARGs, and this repository's
submodule gitlinks — and when a newer version appears it emits a
MaintenanceBump. One platform pipeline applies it: this wrapper's
`.config/qits/ci-platform-event-maintenance-bump.yml`, which qits-ci runs
against whichever repository the payload names. It edits the manifest,
commits a `bump(...)`, and pushes `maintenance/<upstream>`; the service
then opens a release request for that branch, so a bump ships through the
same gate as anything else. There are no per-dependent bump pipelines and
no `ci-event-upstream-*.yml` files any more.

## How code is iterated

Everything starts with a feature idea. The idea is fleshed out into an
epic. Once the epic is refined, the whole stack branches to
`epic/<epic-slug>` — all submodule repositories included. Everything
done for the epic lives under the `epic/*` prefix.

That branch is the basis for the coding harness's workspace. The
workspace can open sub-branches like `epic/<epic-slug>/<task-slug>`
when it needs to, but that is an edge case.

When the changes are ready for a first deployment, each repository's part
of them is released — a release request per repository, gated, versioned
and deployed as above. There is no environment branch to merge into. The
rest of the loop is planned but not implemented yet:

- The epic is notified of the result of each release.
- On success, the epic is available for the next environment.
- On failure, the ball goes back to the coordinating workspace to
  resolve the error.

