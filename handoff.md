# Handoff

Updated 2026-08-06. Everything shipped-and-verified has been removed; history is in git
(this file's own log included). What remains is open, pending, or standing.

## Awaiting user verdicts

1. **WO-b judgment call**: the merge panel left the workspaces overview (merging lives
   on the detail route). Keep it that way, or bring a merge entry point back.

Resolved 2026-08-06: the **git-storage flip executed** — the live git host runs
`qits.repositories.git.storage=dfs` since this day (user's go). All 41 repositories
imported and three-check-verified; every path proven live: protection + both bypasses,
post-receive → CI, repository create/import over HTTP, history reads, the full release
train (SCMRelease → event run → SoftwareRelease), workspace container provisioning, a
service deploy, and qits-artifacts redeploying itself from its own DFS store. Full
record at the top of git-host-storage-unification-plan.md. Rollback stays a config
flip: the file bares sit untouched on `qits-repositories`.

Resolved 2026-08-06: the explorer copy (old item 1) shipped — lede approved as-is, the
count punctuated, excluded rows say "not collected" (qits-spa-artifacts `85ea629`,
live via the qits-artifacts webui bump `a72cfd7`, verified in the browser). Note the
shape of that release: a green qits-spa-* run ships nothing by itself — the SPA goes
live only when qits-artifacts bumps its `service/src/main/webui` submodule and
redeploys, queue empty first (self-hosting landmine).

## Open work, not user-gated

- **First real GC sweep**: currently a proven no-op (2-day-old platform, everything
  inside the windows). When the store ages past P30D, run the README's first-sweep
  choreography (review the per-repo or global dry-run → H2 backup + blob listing →
  sweep → verify store-summary balance, cd restart pulls, evicted proxy package
  re-caches). Nothing sweeps without the review.
- **SHUTDOWN COMPACT** maintenance restart: the only way packument CLOB space comes
  back after proxy evictions; documented in qits-artifacts README, never run by code.
- **ci-screenshots / ci-videos GC**: excluded by configuration today; the user wants an
  own-like "$last versions" strategy for them eventually (out of scope for now).
- **Log-streaming leftovers**: none since 2026-08-05 — qits-events gained its OpenAPI
  export test (every repo has one now). Standing note: qits-artifacts publishes
  `paths: {}` (raw-route service — fine, known).

## Longer-term backlog (from settled plans)

- **Workspace views**: the pre-PoC overview tree shipped; the real model is
  project → epic → workspace views (user's mental model, recorded 2026-08-04) — future
  design work.
- **qits-idp**: machine auth is live platform-wide; the user-auth track of
  qits-idp-plan.md (gateway pointing at idp for humans) remains.
- **Workspace-launched dev services telemetry (LD-b): NOT PLANNED** (user decision
  2026-08-05). Console capture is the answer for both daemons; qits-observability's
  README "missing sender" note is a description, not a TODO.
- **Durable log retention (LG): SETTLED** (user decision 2026-08-05). qits adds no
  external component that cannot be embedded into the Quarkus app — no third-party log
  backend, no sidecar collector. The bounded live window stands; if it ever proves
  insufficient, the only path is a qits-owned persistent store inside
  qits-observability.
- **Git pack GC** (old BD): separate, DFS-gated, untouched by the GC reshape.

## Standing facts and landmines (not in memory files)

- **Release a self-hosting repo only after its epic build drained the queue** — a
  release run's npm install can race the redeploy of the service building it.
- Security model: publish surfaces are tokenless on qits-net by decision; qits-idp
  gates them together when its user track lands. `DaemonOpenPublishTest` and siblings
  pin this — re-gating one surface alone fails the build.
- idp token endpoint is not reachable via gateway; call it on `qits-net`. Machine auth
  is ON live (`QITS_AUTH_MACHINE_REQUIRED=true`); only the `qits-artifacts` idp client
  carries `project=*` (see memory: machine-token-minting).
- Git storage: the live git host runs **dfs** since 2026-08-06 — packs and refs are
  blobs in qits-artifacts' own store. The env lives in cd run-args (backup:
  `application.properties.bak-prefdfs` on qits-cd-config). The file bares on
  `qits-repositories` are the rollback — config flip + redeploy — and are never
  deleted. **Never run `DfsGarbageCollector`**: in a store without deletes it doubles
  the footprint (plan §1.7; posture ⚖2(b) — no git GC, in writing). The git CLI cannot
  open a DFS repo — every operation is the wire protocol; receive-pack is the sole
  writer of everything. `DfsBlockCache` rides its 32 MiB default, which today's whole
  git host fits inside. A fresh `qits-local-up.sh` platform still boots `file` — the
  bootstrap was deliberately not touched (both backends ship, ⚖4).
- musl builder supply-chain flag stands: `FROM localhost:8081/...` + toolchain fetched
  from `more.musl.cc` per build.
- qits-ci: a record targeted by a MapStruct mapper needs `clean` after changing (stale
  generated impl → `NoSuchMethodError`); same family as stale `target/` after source
  deletions.
- GC operational shape: per-repository plan/sweep are subresources under
  `/artifacts/api/gc/repositories/`; pins are fetched per run from qits-cd
  `/cd/api/pins` and qits-ci `/ci/api/daemon`, any failure aborts the whole run; blob
  bytes lag identity deletion by up to two runs (row-less + 7-day grace); Σ(per-repo
  reclaim) ≤ global by design.
- Log export: all eleven services (idp included) carry the explicit
  `quarkus.otel.logs.*` block + an `OtelLogConfigTest` drift guard; the behavioral
  proof lives once, in qits-events (`OtelLogBridgeTest`/`PackagedLogBridgeIT`).
  Resource identity (`service.version` = deploy sha) is injected by qits-cd at
  `docker run`; a service shows it after its first post-2026-08-05 deploy.

## Preserve

- Root untracked user files: `daemon-artifact-identity-plan.md`,
  `workspace-overview-ux.md`.
- `services/qits-workspaces/.claude/` is user-owned and untracked.
- Do not reintroduce EventStream as a CI/Workspaces submodule or reactor module.
- QuarkusTest on this host: pass `-Dquarkus.http.test-port=0` (8081 is the npm
  registry).
- Moving the daemon pin stays a human act: edit cd run-args volume + compose, restart
  qits-cd, then redeploy qits-ci — in that order (qits-cd caches run-args at boot).
