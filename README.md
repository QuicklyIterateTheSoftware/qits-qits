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
authenticates, reads included. Workstation setup — signing in, git, and
the npm and Maven registries — is in `qits help guide --for
workstation`. Run it on a fresh machine before anything else.

Docker has no `qits` login yet. `docker login` against the registry and
mirror vhosts takes a client the idp commissions for this machine: the
bootstrap report prints the one-liner (a `POST /idp/api/clients`), and
the answer's `clientId` and `secret` are the pair. It does not survive a
re-bootstrap; hand it back with `DELETE /idp/api/clients/<clientId>`.

## Addressing

There is one address model: every platform service is
`https://<label>.qits.<QITS_DOMAIN>`, reached through the edge (epic
qits-428). The label is the service's `host:` in its
`.config/qits/deployments.yml`, else its application name without `qits-`
(`registry` is qits-artifacts, `mcp` the MCP service). The platform project
`qits` has no environment label, so `QITS_ENVIRONMENT` never enters an
address. Services call each other the same way browsers, runners, CI steps
and agents do, with their own `qits:system` bearer from
`quarkus.oidc-client.qits`. Defaults are expressions over `QITS_DOMAIN`, never
configuration entries, and a service without `QITS_DOMAIN` refuses to start.
A call to the process's own host goes to `http://localhost:8080`.

Four exceptions, and nothing else names an internal alias:

- **E1, the edge itself.** It dials upstreams by the `upstreamHost` in its
  projection, and dials qits-idp (`QITS_EDGE_IDP_DIAL_URL`), qits-events (its
  catch-up), qits-observability (its own telemetry) and its Postgres on
  `qits-net`. It cannot dial itself, so it serves the platform labels
  (`idp`, `registry`, `mirror`, `githost`) before its catch-up ends.
- **E2, the edge's own image and the cold boot.** qits-edge deploys
  start-first, so the old edge serves the pull of the new image. Before the
  edge is ready, qits-bootstrap-cli makes its API calls on internal aliases,
  and switches each label to its edge host once `edge-ready` has proved it.
  Its image pushes never use a machine name: they wait until
  `registry.qits.<domain>` serves a real certificate (`registry-ready`) and
  push there. The edge answers a machine name such as
  `registry.dev.localhost` with a 404.
- **E3, the deployer's break-glass.** In qits-deployments only, a peer call
  that still fails after qits-http-core's 30 s switchover retry gets one more
  try on `http://<env>-qits-<app>:8080`, logged as `edge unavailable; using
  internal address for <app>`.
- **E4, databases.** Postgres stays on `qits-net` (`QITS_RESOURCE_*_URL`
  JDBC).

Telemetry goes through the edge too: services export with
`qits-telemetry-core`, whose OTLP exporters carry the `qits` bearer, and the
edge records no span for the ingest path. Services stay attached to
`qits-net`, because the edge and Postgres reach them there; only the
addressing changed. Measured results are on epic qits-428's thread.

## Branching model

There are no deploy branches. A release is a **release request** on
qits-projects, and a version — not a branch — is what deploys. The
`environment/*` and `platform/*` branch archetypes were retired on
2026-09-04 along with per-push CI.

You push a working branch and ask qits-projects to release it. It folds
`main`, that branch and any released tags still in flight onto a backing
branch `release/<id>`, and re-folds whenever one of those moves. The
repository's `.config/qits/release.yml` builds that fold and returns a
verdict; **a green verdict is the whole quality gate, and there are no
exceptions** — every step of that pipeline gates, and no step may opt
out. Over a green one the platform stamps the calendar version, bumps
the manifests, tags, and publishes an SCMRelease event. The same
document's release phase then builds the image at
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
MaintenanceBump. One platform pipeline applies it: qits-ci's packaged
`.config/qits/platform-pipelines/maintenance-bump.yml` (in qits-ci-service),
which qits-ci runs against whichever repository the payload names. It edits the manifest,
commits a `bump(...)`, and pushes `maintenance/<upstream>`; the service
then opens a release request for that branch, so a bump ships through the
same gate as anything else. There are no per-dependent bump pipelines and
no `ci-event-upstream-*.yml` files any more.

## How code is iterated

Everything starts with a feature idea. The idea is fleshed out into an
epic. Once the epic is refined, the whole stack branches to
`epic/<qualified id>` (for example `epic/qits-765`) — all submodule
repositories included. Everything done for the epic lives under the
`epic/*` prefix.

That branch is the basis for the coding harness's workspace. The
workspace can open sub-branches like `<epic branch>-<name>` (for
example `epic/qits-765-pacts`) when it needs to, but that is an edge
case.

When the changes are ready for a first deployment, each repository's part
of them is released — a release request per repository, gated, versioned
and deployed as above. There is no environment branch to merge into. The
rest of the loop is planned but not implemented yet:

- The epic is notified of the result of each release.
- On success, the epic is available for the next environment.
- On failure, the ball goes back to the coordinating workspace to
  resolve the error.

