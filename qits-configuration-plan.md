# qits-configuration — deployment configuration as platform state

Decided 2026-08-17. Kills the failure class that burned 2026-08-16 on wohlben.eu:
deployment env config is a hand-edited properties file on a volume, snapshotted
at deployer boot and silently re-stamped on every deploy — file edits are inert
without a deployer force-reload, and live `service update --env-add` fixes are
reverted by the next deploy.

`qits-secrets-plan.md` folds in here: secrets become one entry CLASS of this
service (broker semantics unchanged — in-memory credential, approval-gated,
one-shot redemption). Plain entries are durable, versioned, readable at every
deploy.

## The trust-domain argument (read before objecting)

qits-deployments' standing doctrine: "Deployment config is the trust domain
that already holds the docker socket, and it is the only source. Nothing
arriving over HTTP contributes here." That doctrine guards against the OPEN
intake API contributing env to a `docker run`. qits-configuration changes the
source, not the guard: the deployer PULLS from an authenticated service with
its own machine identity; nothing pushes config into a deployment. The
consequence is that qits-configuration becomes credential-bearing
infrastructure — treat its database and its write surface with the
sensitivity of the `qits-deployments-config` volume. Writes are qits:admin
(forward-auth) or machine-gated; there is no anonymous surface.

## Work packages

### WP0 — deployer reads the file per deployment (ships alone, first)

qits-deployments. `ServiceExtras.of(Config, app)` reads the BOOT config; the
config-volume `application.properties` enters it once, through Quarkus'
config-dir source (workdir `/work`). Fix: a per-deployment snapshot — a fresh
read of that same file layered over the boot config, taken once per argv
build so "every reading agrees" still holds within one deployment. A present
but unreadable file REFUSES the deployment (never a silent fall-back to boot
values). File absent (clone-alone suite, dev) → boot config alone, today's
behaviour byte for byte. This kills the snapshot class with no new component
and no trust-domain change: edit file → next deploy carries it. Call sites:
`SwarmDeploymentDriver` 1019 (apply argv) and 1148 (update argv).

Status: IMPLEMENTED (see status log below).

### WP1 — the service

New repo `services/qits-configuration`, package `eu.wohlben.qits.configuration`,
REST path `/configuration/api`, PostgreSQL (`resources: postgresql:db`),
native-image gate, no SPA in v1, no eventstream in v1 (change events are a
later phase; the deployer pulls per deploy, so nothing depends on push).

Model:
- `configuration_entry` — current value per (application, key). `key` is the
  extras grammar after the application segment (`env.<VAR>`, `mounts[i]`,
  `publishes[i]`, `groups[i]`, `aliases[i]`) — the deployer's `ServiceExtras`
  stays the single parser; this service stores, versions and serves, it does
  not re-model docker.
- `configuration_revision` — append-only history: (application, key, value,
  deleted flag, revision seq, updatedBy, updatedAt). Current state is
  reproducible from the log; entry rows are the read-optimised head.
- `class` column on entry: `plain` now; `secret` later (qits-secrets fold-in).

API (machine-gated writes; reads for the deployer's identity; qits:admin
forward-auth accepted throughout):
- `GET  /configuration/api/applications` — apps with entry counts
- `GET  /configuration/api/applications/{app}/resolved` — flat
  `qits.platform.deployments.extras.<app>.*`-shaped properties map + the head
  revision seq (the deployer records what it deployed with)
- `GET/PUT/DELETE /configuration/api/applications/{app}/entries/{key}`
- `GET  /configuration/api/applications/{app}/history`
- `POST /configuration/api/import` — bulk import of the extras properties
  format; idempotent (identical values write no revision). Bootstrap seeding
  and the one-time migration from the volume file both use it.

### WP2 — deployer pulls from the service

qits-deployments. `qits.platform.deployments.extras-url` (optional, unset
shipped). Unset → WP0 file behaviour. Set → the service is AUTHORITATIVE: a
resolved read per deployment (bounded timeout + patience), and an unreachable
service REFUSES the deployment loudly — never a silent fall-back to the stale
file, which would resurrect the snapshot class with extra steps. The deployment
row's detail records the config revision it deployed with.

### WP3 — bootstrap and adoption

cli-bootstrap: seed qits-configuration as a core service (after postgres,
before the deployer flip); import the rendered extras through
`/configuration/api/import` instead of only writing the file; set
`QITS_PLATFORM_DEPLOYMENTS_EXTRAS_URL` on the deployer as a late phase (cold
boot still deploys from the file until the service is up). PlatformModel repo
list + seed compose + idp client. Wrapper: submodule at
`services/qits-configuration`, catalog adoption via wrapper push to the
platform githost.

### WP-UI — the SPA (user go 2026-08-17; twin repo exists)

`qits-spa-configuration` (GitHub twin created by the user), the
qits-platform-spa-idp scaffold pattern: Angular 21, baseHref
`/configuration/`, `@qits/ui-components`, QitsMainLayout. Pages:
applications list → entries (edit + delete) → history. Calls relative
`/configuration/api` (edge session forward-auth). Quinoa wiring in
qits-configuration per the idp precedent (webui submodule, quinoa 2.8.2,
relative ignored-path-prefixes, prebuilt-bundle Dockerfile, node-docker-base
CI recipe, SPA probes in the packaged IT). `routes: /configuration` +
`navigation:` join deployments.yml. Wrapper gains
`frontends/qits-spa-configuration`.

### WP-DEMOTE — the file becomes bootstrap-only (user go 2026-08-17)

Two defects drive it: deletions resurface (file layered under the service
re-serves deleted keys), and hand env-adds outlive their welcome.
- qits-deployments: with `extras-url` SET the file contributes NOTHING —
  the served map is the sole extras source (authoritative means sole).
  And the update argv learns removals: env vars stamped on the service's
  current spec that the new extras no longer state are `--env-rm`'d
  (never the deployer's own identity/OTel set — that family stays).
- cli-bootstrap: the deployer's OWN `qits.platform.deployments.*` keys
  move from file lines to seed-stack env (the dotted-only rule guards the
  extras family alone). The file shrinks to the extras that cold boot
  needs before the flip; post-flip it is unread. The volume itself stays
  (DOCKER_CONFIG config.json lives there).
- Rollback story post-demotion: unset `extras-url` returns to the file,
  which may be stale — re-render/export before relying on it.

### Later (explicitly out of v1)
- Secret entries (qits-secrets broker fold-in; see that plan's flows).
- Change events / deployer subscription.
- Export endpoint (store → properties file) for the rollback story.
- Other consumers (qits-ci step env, workspace knobs) reading entries.

## Status log
- 2026-08-17: plan written; WP0 dispatched; WP1 scaffold dispatched.
- WP0 DONE — qits-deployments 56eb588 (ExtrasSnapshot, per-argv file read,
  unreadable file refuses). Rode along: e367035 made the suite green again
  (stale machine-guard contract; roles ride the idp `groups` claim; doctrine
  table updated in that repo's AGENTS.md).
- WP1 DONE — services/qits-configuration on its own main (5 commits, no
  remote): two modules mirroring qits-events, PG via QITS_RESOURCE_DB_*,
  V1 entry+revision schema, the API as specified (all routes
  `@RolesAllowed({qits:admin, qits:system})`, machine gate present but no
  route is machine-ONLY — deployer pull and operator edit share both
  surfaces), 41 JVM tests + 6 packaged ITs green, native gate green.
  Left out per plan: secret class (column exists), events, SPA, release
  recipe (needs the githost repo to exist first).
- GitHub twin created by the user; service history rebased onto its seed
  commit and pushed; wrapper tracks the submodule (a14a833).
- WP2 DONE — qits-deployments cdff321 (DeploymentExtrasSource seam, served
  map above the file, refuse-on-unreachable, gated `configuration`
  oidc-client, 374 tests green, independently verified).
- WP3 DONE — cli-bootstrap b353de4 (deploy-configuration → import → flip
  phases 57-59, idp DEPLOYMENTS_ROLES line, RECEIVE_ONLY_APPS audience,
  flip values read from the rendered extras; 413 tests green). Cold boot is
  72 phases now. Note: deploy-configuration warns until a release tag
  exists (falls back to main's head).
- **LIVE ON WOHLBEN.EU 2026-08-17**: the whole train executed by hand on the
  running platform, mirroring WP3's phases — catalog adopted via wrapper
  push, dev-qits-configuration pipeline-built and deployed (DB provisioned
  through `resources:`), 189 extras entries imported, idp audience+roles
  seeded for dev-qits-deployments (file+store+live), deployer running
  WP0+WP2 and FLIPPED (`extras-url` set, oidc client on). PROOFS:
  (WP0) a file-only edit reached a replayed deploy with zero deployer
  reloads; (flip) an API-only entry (`env.QITS_CONFIG_PROOF` on qits-docs,
  never in the file) landed on the redeployed service — deployer log
  `answered 3 extras properties … at config-revision=195` — then was
  deleted and the clean state redeployed. Rollback if ever needed: env-rm
  `QITS_PLATFORM_DEPLOYMENTS_EXTRAS_URL` (file stays current — every store
  write so far is mirrored there).
- WP-DEMOTE DONE AND LIVE (2026-08-17 evening): qits-deployments db0acda
  (extras-url set → file not consulted; updates env-rm what the source no
  longer states, three protected families) + cli-bootstrap 7fd6db5 (file
  is extras-only; git-host-url moved to env in both spellings) — both
  suites green (379 / 415), independently verified. Live rollout followed
  demotion-rollout.md: the pre-flight audit found NINE unrecorded live env
  keys (projects OIDC gate, edge ACME set, idp edge-roles) — preserved in
  store+file; the workspaces image override was left to die (code default
  identical, train owns the pin). Proofs: docs redeploy removed NOTHING;
  workspaces redeploy removed EXACTLY QITS_WORKSPACE_IMAGE; daemon
  reconnected. The live file now carries zero non-extras config lines.
- Open tail: release qits-configuration + qits-deployments + cli-bootstrap
  through the release door (main-deploys carry stale version identity);
  secrets class + change events per "Later"; WP-UI in flight.
- DEFECT FOUND AT THE PROOF (pre-existing, now visible): a service UPDATE
  only `--env-add`s, so an entry DELETED from the extras never leaves a
  live service until `service rm` + redeploy (measured: revision 196
  served 2 properties, the deploy succeeded, the stale env stayed; removed
  by hand env-rm). Fix in qits-deployments: the update argv should env-rm
  keys the predecessor deployment stamped that the source no longer
  states.
