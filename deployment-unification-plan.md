# Deployment unification plan — DRAFT

Implements the target model of `deployment-model-draft.md`. End state: a full
clean cold bootstrap brings up the platform in the target shape, with ONE env
named **prod** (no second env in the MVP).

Status: plan approved in its decisions (user, 2026-08-08); phase content is
still a draft.

## Decisions (user-approved 2026-08-08)

- **D1 — `platform/main` is retired.** Platform services are prod applications,
  so they deploy from `environment/prod` like every other prod application.
  One ref scheme: `main` (trunk, builds only) + `environment/<env>` (deploy).
  "Platform" reduces to: a `qits-platform-<x>` repo name, deployed only in
  prod, joins every env's networks.
- **D2 — the edge is a new repo `services/qits-platform-edge`**, wire name =
  repo name. Created on GitHub 2026-08-08
  (`QuicklyIterateTheSoftware/qits-platform-edge`), verified: has `main`
  with an initial commit, so `git submodule add` works directly.
- **D3 — repo naming: platform services' repos are `qits-platform-<x>`; env
  services' repos are plain `qits-<x>`.** GitHub renames DONE (user,
  2026-08-08) and VERIFIED over ls-remote: qits-platform-deployments →
  qits-deployments, qits-platform-spa-deployments → qits-spa-deployments,
  qits-artifacts → qits-platform-artifacts, qits-idp → qits-platform-idp,
  qits-dns → qits-platform-dns, qits-spa-artifacts →
  qits-platform-spa-artifacts. qits-platform-docs and qits-platform-spa-docs
  already carried the right names. Wire names follow: platform services are
  dialed by repo name (singletons, no instance prefix); env services as
  `<env>-<repo>`. Remaining on this side: rename the wrapper submodules
  locally (entry name, url, path — per the CLAUDE.md submodule procedure) in
  phase 4; the bootstrap then seeds the platform under the new names.
  GitHub redirects keep old-name remotes working meanwhile. Leftover seen on
  GitHub: `platform/main` branches still exist on qits-platform-artifacts,
  qits-platform-idp and qits-deployments — delete them in phase 3 (D1).
- **D4 — no swarm in this plan.** The deployer keeps its `docker run` +
  cutover machinery; only names and topology change. Swarm is a separate
  later reshape (the daemon is already a swarm manager; nothing here blocks
  it).
- **D5 — the GC ships UNCHANGED in the MVP.** Today's single pin-source pair,
  only the injected URLs change (`prod-qits-deployments` + `prod-qits-ci`).
  The multi-deployments reshape is deferred — with a HARD GATE: it must land
  BEFORE a second env is ever created. Until it lands, another env's pins
  would be invisible to the sweep and its deployed images deletable
  (over-deletion, accepted as impossible while prod is the only env).

## Target shape (MVP)

12 containers, all deployed by prod's deployer from `environment/prod`:

    qits-platform-edge            host :8080; routes by host name; env list = [prod]
    qits-platform-idp             the one issuer
    qits-platform-artifacts       the one store; git host also on host :8081
    qits-platform-docs            the reader over the one docs store
    prod-qits-gateway             path routing, auth, headers (no host port)
    prod-qits-deployments         deploys everything above and below
    prod-qits-ci                  all builds
    prod-qits-observability       the sink (platform services export here too)
    prod-qits-workspaces          release endpoint
    prod-qits-events              the bus
    prod-qits-projects            inventory, wrapper, backups
    prod-qits-stt

Out of MVP: qits-dns deployment (classified `qits-platform-dns`, the fifth
platform service — one zone authority, host :53; `*.localhost` needs no DNS
locally), second env, swarm, epic envs.

Token model: client ids `prod-qits-<app>` / `qits-platform-<app>`; audiences
the same names. Fresh bootstrap mints everything — no credential migration.

Naming: qualified names everywhere on the wire. Every peer URL and expected
audience arrives as deployer-injected config; images stay env-agnostic.

## Phases

Each phase ends green (`verify` + boot) and releasable on its own. Order
matters: config plumbing first, the edge before the gateway loses its port,
refs last before the bootstrap rework.

### Phase 1 — config plumbing (no behavior change)

1. **Audit every repo for hardcoded peer names.** The invariant says peer
   URLs and audiences are injected config; verify it per service. Anything
   hardcoded (`qits-artifacts:8080` in a default, an `aud` literal) becomes
   config with today's value as default. Grep targets: `qits-` host names in
   application.properties and code, `aud`/audience literals, oidc client ids.
2. **Deployer: container names and aliases from one scheme** —
   `<env>-qits-<app>` for env applications, `qits-platform-<app>` for
   applications flagged platform. The flag lives on the application row
   (reuse the existing plane concept; its meaning narrows to "platform-
   prefixed, prod-deployed, joins all env networks"). Aliases are what
   everything dials, so this lands together with 4.
3. **Deployer: injected run-args/config templates use the qualified names.**
   One rollover per service picks the new alias up; order services so
   callers re-read after their dependency moved (or accept one restart
   round — MVP is not zero-downtime).

### Phase 2 — the edge

5. **New repo `services/qits-platform-edge`** (Quarkus, native, same repo shape as the
   others). Behavior: read `$env` from the Host header, forward the whole
   request to `http://<env>-qits-gateway:8080`; unknown host/apex → the
   default env (`prod`). Env list + default from config. No auth, no header
   stripping, no path knowledge — that stays the env gateway's job. It must
   pass Host/X-Forwarded-* through untouched.
6. **qits-gateway sheds the host port.** The edge takes `-p 8080:8080`; the
   gateway becomes a plain env service reached only by the edge and its env.
   The gateway keeps auth, `X-Qits-*` stripping, path routing, and
   `/main-navigation` exactly as is.
7. Wire seam checks: SPA absolute URLs, websockets (projects sign-in
   terminal, workspaces), SSE (events stream) must survive the extra hop.
   Verify each through the edge in a browser before calling this phase done.

### Phase 3 — refs and release flow

8. **Retire `platform/main` (A1).** Deploy refs are `environment/<env>`
   only. qits-workspaces' release flow reads each repo's deploy refs from
   its `.config/qits/deployments.yml` instead of assuming branch names —
   this closes the standing stale-plane bug family — and pushes non-deploy
   refs quietly (`-o qits.no-ci`), closing the CI-hot multi-build bug.
9. **qits-ci / deployer: ref → deployment mapping** comes from the same
   spec: `environment/prod` deploys; `main` builds only. Delete the
   `platform/main` special case everywhere it is spelled
   (`PLATFORM_BRANCH`, pipeline configs, docs), and delete the leftover
   `platform/main` branches on GitHub (qits-platform-artifacts,
   qits-platform-idp, qits-deployments) and on the platform git host.

### Phase 4 — renames (A3)

10. Apply the D3 renames locally (GitHub is already done): six wrapper
    submodules move — qits-deployments, qits-spa-deployments,
    qits-platform-artifacts, qits-platform-idp, qits-platform-dns,
    qits-platform-spa-artifacts — entry name, url, AND directory path each
    (per the CLAUDE.md submodule procedure). Then, inside the repos that
    reference them: Angular project key + `quinoa.build-dir` + Dockerfile
    path (move together — known landmine), CI event triggers, idp
    client/audience spellings, `PlatformModel.repoPath`, gateway route
    segments if any change. The platform-side state (git-host repos, CI repo
    ids, application rows, image repos) is NOT migrated — the clean
    bootstrap recreates it under the new names. Until then GitHub redirects
    keep old-name remotes working, and the live platform keeps running under
    the old names.

### Phase 5 — bootstrap CLI rework

11. **Default env is `prod`** (`QITS_ENV_NAME`, default `prod`; no second
    env created).
12. `PlatformModel`: platform set = `{edge, idp, artifacts, docs}`; everything
    else is an env application of the default env. Deploy ref =
    `environment/<env>` for all. Container/alias naming per the scheme.
13. Seed generation: compose aliases, run-args templates, and the config
    volume use qualified names; the edge is a seed service (it binds the
    only port — nothing is reachable before it); artifacts keeps :8081.
14. **Idp seeding: qualified client ids and audiences**
    (`prod-qits-ci`, `aud=qits-platform-artifacts`, …). `IDP_AUDIENCES`
    restated in full. Machine-token minting recipes in docs/memory update
    with the new client names.
15. GC config keeps today's shape (D5) — only the injected URLs change to
    `prod-qits-deployments` / `prod-qits-ci`.

### Phase 6 — the clean bootstrap (the gate)

16. Preconditions: all repos released through the release flow; GitHub
    backups current (they are automatic); `.qits-bootstrap.env` secrets
    saved; optional tarball of anything sentimental — run/deployment/event
    history WILL reset, as in previous resets.
17. `unwrap --with-volumes`, then cold `bootstrap`. Expect the usual truth:
    the first cold run finds real bugs; each is a fix in the phase that
    owns it, then re-run.
18. **Verification checklist**: 12 containers healthy under the new names;
    every route 200 THROUGH THE EDGE; browser pass over every SPA
    (websocket terminal + SSE included); one full release train end to end
    (SCMRelease → SoftwareRelease → follow-bump); GC dry-run reports the
    prod pin source pair; `docker network inspect` shows platform services
    on prod's networks only (no other envs exist yet); handoff + memory
    files updated (several memories go stale: platform-plane conversion,
    release-flow branch assumptions, machine-token client names).

### Phase 7 — deferred, with design notes (NOT in MVP)

- **GC multi-deployments awareness (D5) — HARD GATE before env #2.** Pin
  sources become a configured list of `(deployments-url, ci-url)` pairs;
  keep = union across all pairs; fail-closed across every source. Creating
  a second env before this lands means that env's pins are invisible and
  its deployed images deletable.
- Second env (dev): creation choreography (idp client grants, stack,
  networks for the platform services, GC pin-list entry, DNS).
  Blocked on the GC gate above.
- Multi-env lifecycle wiring: post-receive fan-out per ref → that env's ci;
  who owns `main` builds; per-env projects/workspaces against the one git
  host.
- Swarm substrate (A4).
- qits-platform-dns deployment (host :53), host-name routing on real domains.

## Risks worth naming

- The edge is new code in front of everything; phase 2's browser pass is the
  gate, not unit tests.
- Phase 1.4's alias flip is a coordinated restart round — do it in a quiet
  moment, deployer last (it reads run-args at ITS boot).
- Renames (phase 4) have bitten before (webui gitlink drag-back, path
  triplets). The clean bootstrap absorbs the platform-side state, which is
  most of the historical pain.
- The release flow changes (phase 3) and the bootstrap (phase 5) both touch
  the self-hosting knot: release each through the OLD working flow before
  it is replaced, queue drained, one at a time.
