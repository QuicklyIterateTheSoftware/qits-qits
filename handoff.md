# Handoff: 2026-08-01 → next session

Start here. What shipped today, how to verify it landed, and where the work picks up. The map, not
the territory — reasoning lives in the plan docs named inline.

Yesterday's handoff is in git history (`git show 40efd9a:handoff.md`) if you need the release-flow
build-out story; everything it left in flight landed, and today's work sits on top.

## Shipped today, in order (all live on the local platform)

1. **The integrate/release split** (`release-flow-plan.md`, 2026-08-01 addendum) — the parked
   design question from yesterday, answered. `main` is written by **release alone**:
   - `POST /workspaces/api/workspaces/{id}/release` `{summary}` → `{version, commitSha, branch}` —
     branch → `main`, target not a parameter, calver stamp + manifest bump + one two-parent
     `release(<version>): <summary>` commit, pushed with `-o qits.release`.
   - `POST /workspaces/api/workspaces/{id}/integrate` `{summary}` → `{commitSha, branch,
     targetBranch}` — branch → **its parent branch**, a plain `integrate(<source>): <summary>`
     merge. No stamp, no bump, no event, no `version` in the response.
   - Wrong door (integrate whose parent resolves to `main`, or a merge endpoint aimed at `main`) →
     **409 `reason: RELEASE_REQUIRED`**, naming the endpoint that does write it. The whole 409
     reason enum is now declared in the OpenAPI via `api/ApiError`.

   qits-workspaces `3728fcd` (webui gitlink advanced at `27670e6`).
2. **`SoftwareRelease` is live** (`software-release-event-plan.md`, **SHIPPED**) — a release, never
   an integrate, publishes `{projectId, repository, branch, version}` the instant the push is
   accepted, through the qits-eventstream submodule. First observed event on the bus:

       1faa0164-7747-4cf9-9bb5-a996c0db6898  SoftwareRelease  2026-08-01T05:55:29.355478Z
       {"branch":"task/aj-release-proof","projectId":"53c78589-6af3-4221-b3ef-315c867b0863",
        "repository":"qits-stt","version":"2026.801.55529"}

3. **The UI shows one door per workspace** — qits-spa-workspaces `eee3113`: Release when the parent
   is `main`, Integrate otherwise, and a `RELEASE_REQUIRED` 409 surfaces a "Release into main
   instead" affordance.
4. **qits-ci finished-runs** — `GET /ci/api/runs/finished?limit=N` beside `/active`, and the spa-ci
   rail that stacks finished runs above what is in flight. qits-ci `c211a0dc`.
5. **The wiring and the live proof** (this pass) — the qits-workspaces deployment now *declares*
   `QUARKUS_DATASOURCE_EVENTSTREAM_JDBC_URL` and `QITS_EVENTS_URL` (image defaults before, so this
   changed no behaviour, only the record), in `qits-local-up.sh` and in the live `qits-cd-config`
   volume; both proven present on the container the next deploy started. Then the split was proven
   end to end on qits-stt: release `2026.801.55529` / `eed05301` (two parents, three poms bumped,
   ordinary CI run `b3814ea3`, deployment `e8b0ef62` ACTIVE, the event above); integrate onto an
   `epic/aj-proof` parent `05638f5c` with `main` untouched and no second event; integrate on a
   main-parented workspace → 409 `RELEASE_REQUIRED`.

How to verify any of it: `/ci/api/runs?repositoryId=<repo>` for the builds,
`/cd/api/deployments?environmentId=9fc2480c-3ff9-4f24-9bfe-67abe64afb06` for deployments,
`/events/api/events` for the bus, `docker ps` for containers, and each shipped sha vs
`git ls-remote` on both remotes.

## Next feature, planned and ready to implement

**`release-train-hops-plan.md`** (SETTLED, with a 2026-08-01 addendum) — the train's loop closes:
upstream releases → `SoftwareRelease` → the consumer's ci-event pipeline bumps the dependency
(really runs npm; a lockfile's integrity cannot be spliced) and force-pushes
`maintenance/<upstream-repo-id>` → the consumer's ordinary post-receive pipeline runs its tests and,
on green, releases itself → the next `SoftwareRelease`. The new capability the plan needs is
**step-level `branches:` matching** in qits-ci; a step whose filter misses is SKIPPED, and step
order gives release-only-after-green inside one run.

**Workstreams, in order: AD ∥ AE → AF → AG.**

- **AD** — step-level `branches:` in qits-ci.
- **AE** — the branch-keyed endpoint, and the addendum renamed it: **`POST
  /workspaces/api/branches/release`**, not `/branches/integrate`. A maintenance hop merges into
  `main`, so it is a *release*; `/branches/integrate` now means branch → parent branch and would
  409 `RELEASE_REQUIRED`.
- **AF** — the two pipeline files in qits-spa-home; its maintenance step calls `/branches/release`.
  Gates on **AD deployed** (an old qits-ci ignoring the step-level key would release on every push
  — the rollback hazard the plan defuses; the step script also self-asserts its branch).
- **AG** — the live hop.

The canary trigger in qits-spa-workspaces
(`.config/qits/ci-event-upstream-ui-components.yml`) can flip from `BuildSuccessful` to
`SoftwareRelease` now that the payload carries a version — match on `repository`, never on `branch`
(the branch is the source branch, e.g. `maintenance/…`).

## Parked follow-ups (deliberate, not forgotten)

- **index.html immutable-cache bug — USER-IMPACTING**: every SPA serves `index.html` with
  `immutable, max-age=86400`; returning browsers get blank/stale pages after every deploy until a
  hard reload. Fix: document must revalidate, hashed bundles stay immutable; a seven-service
  rollout — queue when CI is quiet.
- Tofu chevrons (`▸▾`) in the explorers on hosts without glyph coverage — CSS triangle would fix.
- `CausationStampingTest` flake in qits-eventstream (~1 in 3: StaleObjectStateException,
  double-delete of an outbox row).
- qits-ci README still promises `jq` in step images; `node-base` has none (plan doc corrected,
  README not — ride the next qits-ci change).
- qits-spa-ci / qits-spa-cd have CI recipes but no repos on the platform git host (their pipelines
  never run; seeding them is a one-liner when wanted). Related: qits-ci's webui gitlink sits at
  `24579ae` while qits-spa-ci's main is `28a4c45` — one commit of lag to ride the next qits-ci push.
- Event-triggered QUEUED rows are discarded (not re-enqueued) at restart — closing it means
  persisting the event payload on the run row.
- DAG cycle detection across trigger files; bus catch-up/replay — both designed-around, both future
  features with their own plans to write.

## Operational truths that bite (full versions in auto-memory + repo AGENTS.md files)

- **Two doors, and they are not interchangeable.** `POST /workspaces/api/workspaces/{id}/release`
  is the only thing that writes `main`; `POST …/{id}/integrate` merges into the branch's *parent*
  and refuses a `main` parent with 409 `RELEASE_REQUIRED`. A direct `git push … main` needs
  `-o qits.token=local-dev` — the token `qits-local-up.sh` configures (`QITS_PUSH_TOKEN`, carried
  into qits-artifacts' run-args). A deployment with no token configured has no escape hatch: unset
  matches nothing and so does empty. Creates are never guarded, so seeding a fresh repo — or
  pushing a task branch — still needs no option.
- `POST /workspaces/api/branches/cleanup` refuses a branch with unmerged commits, by design. A
  proof branch that was integrated into a *parent* rather than released therefore cannot be cleaned
  through the API door; `git push origin :refs/heads/<branch>` still works (non-default refs are not
  the hook's business).
- Replays of `POST /ci/api/events/post-receive` are NOT idempotent; a missing run row while the
  worker is busy means QUEUED, not lost. Loss = FIFO violation with idle worker, or the successor's
  "Marked N left RUNNING" line.
- qits-cd write-wedge: green runs, no deployment row, "database has been closed" in cd logs →
  restart cd container, replay `POST /cd/api/events/build-succeeded`.
- qits-cd caches its run-args config at boot. After editing `application.properties` on the
  `qits-cd-config` volume, **restart the qits-cd container** or the next deploy uses the old values.
- Gateway is :8080; :8081 is qits-artifacts direct. CI filter param is `repositoryId`; cd's is
  `environmentId`.
- Never run qits-local-up.sh casually (recreate branch kills the cd-managed core); never DELETE the
  `qits` project (it deletes the platform's own git origins).
- Superproject: many local commits, **none pushed** (user hasn't asked). Submodule gitlinks lag by
  design; sync is automated.
