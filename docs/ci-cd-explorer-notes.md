# CI/CD explorers: what survives the retired plan

The explorers shipped 2026-07-31; the plan was verified 2026-08-01 (fully implemented except one
item below) and retired. Contracts live in the repos' code, AGENTS.md and docs/openapi.yml.

## The one unimplemented commitment

- **Live-output auto-scroll** on `/ci/runs/<id>`: the pane was to follow output unless the user
  scrolled up. Never built (zero scroll handling in qits-ci-frontend). Ride the next qits-ci-frontend
  change; do not spend a qits-ci redeploy on it alone.

## Named fast-follows (parked deliberately, recorded nowhere else)

- **Output offsets or a conditional GET on the run read** — the answer to poll cost. Measured
  2026-08-01: a real run's poll payload is 4.5–40 KB, far under the feared 320 KiB, so this is
  theoretical until runs grow.
- **Cursor paging (`before=<createdAt>`)** on the hot lists. `?offset=` was rejected because an
  offset over a head-growing list re-shows rows under concurrent insert.
- **ci: a `?triggerEventId=` query filter** on the runs list (the field exists; the filter does not).
- **cd: `?repoId=` filter, deployment-by-id, and application routes outside the environment
  nesting** — all rendered around at no cost.
- **Exposing the alias table's registered name on `RepositoryDto`** — would remove the SPA's
  url-basename label hack.

## Operational rationale worth keeping

- **Why `Repository.id` is a directory name, not a UUID**: `CiRun.repoId` is the git host's
  `/data/repositories/<name>` directory name; making `Repository.id` equal it (SelfSeedService +
  adoptExistingOrigin enforce this for platform repos) is THE join between projects, ci and cd.
  A UUID id would have needed a mapping table on every read path.
- **There is no project→environment edge.** Environments are deliberate tiers owned by qits-cd
  (`dev` on branch `environment/dev`), created over its REST API. The old convention
  `CdEnvironment.name === Project.slug` is gone with qits-projects' `CdEnvironmentNotifier`;
  never present the two as related, by FK or by name.

## Known cosmetic deviations (accepted)

- `/ci/api/nope` and `/cd/api/nope` 404 with Vert.x's stock `text/html` error page; the ITs
  assert "404 and not the client", which is the correct claim.
- `**/.quinoa` is missing from qits-cd's `.dockerignore`.
- qits-workspaces-frontend's nav-link count assertion is relaxed (`> 0`) where the other seven pin 8.
- All SPAs pin `@qits/ui-components@^0.0.4` while the lib is on calver — the caret will never
  cross; the release-train fan-out is what unfreezes it.
