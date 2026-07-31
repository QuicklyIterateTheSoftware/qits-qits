# Handoff: 2026-07-31 → next session

Start here. What shipped today, what is mid-flight RIGHT NOW, how to verify it landed, and where
the work picks up. The map, not the territory — reasoning lives in the plan docs named inline.
**This file is being updated live through the evening of 2026-07-31 as in-flight agents report;
the "In flight" section is the part to re-check first.**

## Shipped today, in order (all live on the local platform unless noted)

1. **qits-events + qits-spa-events** — new Quinoa service at `/events/`, full bring-up
   (docs/project-setup-quinoa-angular.md followed; gateway needed an enum entry — the route table's
   key set is closed, `QitsService.EVENTS`).
2. **The left nav learned its doors** — `@qits/ui-components` 0.0.3 (Events) and, this evening,
   0.0.4 (CD): each a lib release + all-SPA bump train + gitlink advances. Eight apps, eight links.
3. **The event bus** (`eventsourcing-plan.md`) — idempotent `PUT /events/api/events/{id}`,
   `/events/stream` websocket, publisher with outbox + retry, `BuildSuccessful` published on every
   green build and consumed by qits-ci itself. Native-image war stories are in qits-ci's AGENTS.md.
4. **Causation** (`event-causation-plan.md`) — nullable `parentId` stamped by the bus
   (`CausationScope`), in the PUT equality, walkable via `?parentId=`.
5. **CI event triggers** (`ci-event-triggers-plan.md`) — `.config/qits/ci-event-*.yml`, matcher DSL
   (exact/prefix/exists, OR-of-AND-groups), engine on the raw-listener seam, provenance columns +
   dedupe constraint, `QITS_EVENT_*` env into steps. Live canary: qits-spa-workspaces triggers on
   qits-spa-ui-components green builds; the first automatic causation edge is a production row.
6. **The ci + cd explorers** (`ci-cd-explorer-plan.md`) — project-centric trees at `/ci/` and
   `/cd/`, run detail with live tail + cancel, deployment tables with `runId` click-through
   (cd's V2 stores what its intake used to drop). The platform onboarded itself into qits-projects
   (`qits` project; `Repository.id` = git-host dir name is THE join key; legacy mirror dupes
   removed). Both explorers browser-E2E'd: PASS.
7. **ci UX round** — QUEUED runs are real rows (created at accept; re-enqueued across restarts —
   the lossy-intake trap is HALF dead: queued survives cutover, in-flight RUNNING still dies),
   `/ci/api/runs/active` rail, `/ci/api/repositories/summary` badges, projects default-open,
   attribution correct from first render, gzip on (4×).
8. **qits-eventstream extracted** — the bus client left qits-ci: `libs/qits-eventstream`
   (history preserved, renamed eventsourcing→eventstream incl. datasource/env/keys), consumed by
   qits-ci as a submodule at `eventstream/`, deployed on the renamed datasource
   (`QUARKUS_DATASOURCE_EVENTSTREAM_JDBC_URL`). Old `/data/eventsourcing` H2 file orphaned (was
   empty), not deleted.

## In flight at last update (~22:30 local) — VERIFY THESE FIRST NEXT SESSION

Release-flow implementation (`release-flow-plan.md`, settled: calver `YYYY.MMDD.HHMMSS` e.g.
`2026.731.193059`; main protected by `PreReceiveHook`; bypass = `-o qits.release` ff-only +
`-o qits.token=<value>` vs `qits.repositories.git.push-token`, default unset = locked):

- **Agent X — DONE** (~22:32): ProtectedRefHook live at qits-artifacts `b6a0745`, INERT and
  proven so (native IT force-pushes main under shipped defaults and lands; zero hook decisions
  since cutover). Push-options advertised; token semantics as settled (SmallRye reads
  configured-empty as absent — indistinguishable from unset, both match nothing, recorded in
  AGENTS.md). AC's flip is the remaining half.
- **Agent Y — DONE** (~22:40): VersionStamp (UTC pinned, morning case `2026.731.93059` proven) +
  splice bumpers at qits-workspaces `c4bb7cf`, UNPUSHED (Z ships it). Measured find: StAX char
  offsets lie past the first 8KB buffer — pom splicing maps line/column instead. 59 new tests,
  round-trip byte-identity as the load-bearing assertion.
- **Agent Z — RUNNING** (launched ~22:45): integrate flow + endpoint on top of Y, ships Y + Z +
  AA's webui gitlink (f5860ee) as one pipeline run. Carries AA's 409 contract (additive
  reason+conflicts) and X's live facts.
- **Agent AA — DONE** (~22:30): Integrate UI at qits-spa-workspaces `f5860ee`, pushed GitHub +
  mirror (mirror run green). Six outcome surfaces; Z must emit `reason`+`conflicts` on its 409s
  (additive) and 4xx-not-500 for hook refusals — friction notes in AA's report, folded into Z's
  brief. Gitlink advance into qits-workspaces rides Z's ship step.
- **Then queued**: Z (integrate flow + endpoint, after Y) → AB (deployment wiring: token into
  qits-local-up.sh + live cd-config; teach the pushers) → AC (flip protection on, prove
  default-locked live).

How to verify any of it: `/ci/api/runs?repositoryId=<repo>` for the builds,
`/cd/api/deployments?environmentId=9fc2480c-3ff9-4f24-9bfe-67abe64afb06` for deployments,
`docker ps` for containers, and each agent's committed sha vs `git ls-remote` on both remotes.

## Next feature, planned and ready to implement

**`release-train-hops-plan.md`** (being written this evening by a Fable design agent — check it
exists and is marked settled): the train's loop closes. SoftwareRelease event
(`software-release-event-plan.md`, seeded) + event pipelines combine: upstream integrates →
SoftwareRelease → consumer's ci-event pipeline bumps the dep and FORCE-pushes
`maintenance/$artifact` (overwrites, no checks for now) → a NEW capability, **branch filtering on
post-receive pipelines** (today they fire for every branch), binds a test pipeline to
`maintenance/`-pushes → green tests call the integrate action → next SoftwareRelease → next hop.
parentId is knowingly lost across the push boundary (solved differently, later).

**The next session's job, in order:**
1. Verify everything under "In flight" actually landed (agents sometimes die silently after their
   final push — check remotes/pipelines, not just reports).
2. Finish release-flow through AC if any workstream stalled.
3. Implement the SoftwareRelease event (`software-release-event-plan.md`) — small, rides the
   integrate flow's success seam.
4. Implement `release-train-hops-plan.md` (Opus 5 workstreams lettered from AD).

## Parked follow-ups (deliberate, not forgotten)

- **index.html immutable-cache bug — USER-IMPACTING**: every SPA serves `index.html` with
  `immutable, max-age=86400`; returning browsers get blank/stale pages after every deploy until a
  hard reload (measured twice today). Fix: document must revalidate, hashed bundles stay immutable;
  a seven-service rollout — queue when CI is quiet.
- Tofu chevrons (`▸▾`) in the explorers on hosts without glyph coverage — CSS triangle would fix.
- `CausationStampingTest` flake in qits-eventstream (~1 in 3: StaleObjectStateException,
  double-delete of an outbox row).
- qits-ci README still promises `jq` in step images; `node-base` has none (plan doc corrected, README
  not — ride the next qits-ci change).
- qits-spa-ci / qits-spa-cd have CI recipes but no repos on the platform git host (their pipelines
  never run; seeding them is a one-liner when wanted).
- Event-triggered QUEUED rows are discarded (not re-enqueued) at restart — closing it means
  persisting the event payload on the run row.
- DAG cycle detection across trigger files; bus catch-up/replay — both designed-around, both future
  features with their own plans to write.

## Operational truths that bite (full versions in auto-memory + repo AGENTS.md files)

- Replays of `POST /ci/api/events/post-receive` are NOT idempotent; a missing run row while the
  worker is busy means QUEUED, not lost. Loss = FIFO violation with idle worker, or the successor's
  "Marked N left RUNNING" line.
- qits-cd write-wedge: green runs, no deployment row, "database has been closed" in cd logs →
  restart cd container, replay `POST /cd/api/events/build-succeeded`.
- Gateway is :8080; :8081 is qits-artifacts direct. CI filter param is `repositoryId`; cd's is
  `environmentId`.
- Never run qits-local-up.sh casually (recreate branch kills the cd-managed core); never DELETE the
  `qits` project (it deletes the platform's own git origins).
- Superproject: many local commits, **none pushed** (user hasn't asked). Submodule gitlinks lag by
  design; sync is automated.
