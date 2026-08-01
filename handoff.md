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

6. **The release train rolls** (`release-train-hops-plan.md`, **SHIPPED AND OBSERVED**) — the loop
   the last five features each built one arc of is closed. Four workstreams:
   - **AD** qits-ci `6922da6` — step-level `branches:` (`exact`/`prefix`, OR'd; absent = every
     branch; `[]` and malformed are `CONFIG_ERROR`; the key is a parse error in a `ci-event-*.yml`).
     An unbound step is one **SKIPPED** row with output `[step not bound to branch <branch>]`, fails
     nothing and blocks nothing. Plus `QITS_WORKSPACES_URL` in every step container.
   - **AE** qits-workspaces `416d814` — `POST /workspaces/api/branches/release?repositoryId=<repo>`
     `{branch, summary}`, the branch-keyed third spelling of the one door. The flow was already
     keyed `(repoId, branch)` inside, so it is a thin resolver and no mechanics were copied.
   - **AF** qits-spa-home `2633238` — the bump pipeline
     (`.config/qits/ci-event-upstream-ui-components.yml`) and the maintenance leg in
     `ci-post-receive.yml`.
   - **AG** — one live hop, end to end, in **67 seconds**:

         release qits-spa-ui-components  2026.801.63140 / dc2047f5
           → SoftwareRelease 064158b0
           → upstream CI publishes @qits/ui-components@2026.801.63140 to the registry
           → bump run 32acd2b9 (EVENT, parentId 064158b0 on its BuildSuccessful 59934bf8)
             force-pushes maintenance/qits-spa-ui-components @ 0fe77803, one bump() commit,
             all 720 lockfile origins localhost:8081
           → maintenance run 8c3081c9: ONE run, TWO steps — tests SUCCESS, release SUCCESS
             "released 2026.801.63247 as 421a70fe… from maintenance/qits-spa-ui-components"
           → qits-spa-home main 421a70fe, two parents, pin ^2026.801.63140
           → SoftwareRelease f81ecac8 — matched by nothing, no run, train stopped
             (?parentId= empty; no run carries it)

     The filter was seen in both directions: the ordinary `main` push that followed (run de530cb7)
     recorded step 1 SKIPPED with the branch note. Causation came out as two chains with the
     force-push as the boundary — designed, not a gap. Probes: a superseded sha force-pushed away
     while QUEUED was **discarded with no row**; re-pushing the already-released bump commit gave
     409 `ALREADY_INTEGRATED` → green step, `main` untouched.

   **The CalVer switchover happened, deliberately** (settled decision 2 of `release-flow-plan.md`):
   `@qits/ui-components` went `0.0.4` → `2026.801.63140` and `dist-tags.latest` moved with it. The
   other seven SPAs still pin `^0.0.4` and so still resolve to `0.0.4` — that is by design until
   their own train files exist.

How to verify any of it: `/ci/api/runs?repositoryId=<repo>` for the builds,
`/cd/api/deployments?environmentId=9fc2480c-3ff9-4f24-9bfe-67abe64afb06` for deployments,
`/events/api/events` for the bus, `docker ps` for containers, and each shipped sha vs
`git ls-remote` on both remotes.

## Next up

No feature is queued. Everything planned has shipped, so the next session picks from the parked
list below. The three items nearest the surface, in order of how ready they are:

- **The other seven SPAs' train files** — now a **mechanical fan-out awaiting the user's go**: copy
  qits-spa-home's two files, change one `exact:` value, and bump the `^0.0.4` pin. Settled decision
  2 of the hops plan held one hop back deliberately; the hop is observed, so the gate is the user's
  say-so, not a plan. Note it fans one ui-components release into seven bump runs, seven maintenance
  pushes and seven releases on one serialized worker.
- **The canary flip in qits-spa-workspaces** — `.config/qits/ci-event-upstream-ui-components.yml`
  still triggers on `BuildSuccessful` from qits-spa-ui-components (it fired once during the live
  hop, run `42b65df3`, harmlessly). Flip it to `SoftwareRelease` now that the payload carries a
  version, and match on `repository`, never on `branch` (the branch is the *source* branch).
- **The `summary` length composition**, reported by AG and not adjusted: the maintenance step reuses
  `git log -1 --format=%s` as the release summary, `/branches/release` caps it at 100, and a release
  subject that quotes a bump subject is 108. Unreachable in the designed flow (the train never
  re-reads its own release subject); it bites a maintenance branch cut from a release commit, as a
  plain 400 with no `reason`. Decide whether the cap moves, the step truncates, or it stays a
  documented edge.

## Parked follow-ups (deliberate, not forgotten)

- **index.html immutable-cache bug — USER-IMPACTING**: every SPA serves `index.html` with
  `immutable, max-age=86400`; returning browsers get blank/stale pages after every deploy until a
  hard reload. Fix: document must revalidate, hashed bundles stay immutable; a seven-service
  rollout — queue when CI is quiet.
- Tofu chevrons (`▸▾`) in the explorers on hosts without glyph coverage — CSS triangle would fix.
- `CausationStampingTest` flake in qits-eventstream (~1 in 3: StaleObjectStateException,
  double-delete of an outbox row). **`OutboxFlowTest` in the same repo flakes too** — AD saw it
  about 1 run in 5; same submodule, likely the same outbox race.
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

- **Three endpoints, two doors, and they are not interchangeable.** Release is the only thing that
  writes `main`, and it has two spellings — `POST /workspaces/api/workspaces/{id}/release` and
  `POST /workspaces/api/branches/release?repositoryId=<repo>` `{branch, summary}` for a branch no
  workspace owns. Both stamp, bump, publish `SoftwareRelease`, resolve any ACTIVE workspace on the
  branch INTEGRATED and **delete the source branch on success**. `POST …/{id}/integrate` is the
  other door: it merges into the branch's *parent* and refuses a `main` parent with 409
  `RELEASE_REQUIRED`. A direct `git push … main` needs
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
  "Marked N left RUNNING" line. **A third cause now, and it is correct behaviour**: a run whose sha
  was force-pushed away is discarded outright — no row, and a `… is no longer reachable … no CI run
  recorded` line in the qits-ci log. Superseded hops clean up after themselves.
- Post-receive steps can carry `branches:` (`exact`/`prefix`, entries OR'd). Absent means every
  branch; an unbound step is a SKIPPED row with output `[step not bound to branch <branch>]` that
  fails nothing and blocks nothing after it. The key is a **parse error** in a `ci-event-*.yml`.
  Every step container also gets `QITS_WORKSPACES_URL` now.
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
