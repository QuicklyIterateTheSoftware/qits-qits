# Epic refining workspace

A REFINING epic gets a third action, **Refine**, which starts a real
qits-workspaces workspace on the project wrapper repository, branch
`refining/<epic-slug>` (new convention), and opens a refining page that
mirrors today's Workspace Detail UI. First draft: copy the detail UI from
qits-spa-workspaces into qits-spa-projects — per-SPA duplication is the
sanctioned pattern there (terminal stack was already copied once).

## Decisions

1. **No backend change.** `POST /workspaces/api/workspaces` already does the
   whole job: with `adoptExisting=false` it CREATES the branch by pushing
   through the git host (`WorkspaceService.createBranchOnHost`), from
   `parent` (blank = the repo's main branch). The browser is the integrator —
   same-origin through the gateway, exactly like STT (`/stt/api`) today.
   This keeps the service arrow one-way (workspaces → projects only).
2. **Branch rule composed client-side**, like `epic/<slug>` and friends:
   `refiningBranch(epicSlug) = refining/<epicSlug>` in `epics-model.ts`.
   `refining/` is a fresh top-level prefix — no path conflict with
   `epic/`, `feature/`, `task/`.
3. **The workspace is looked up, never stored**: the refining workspace of an
   epic IS the active workspace on `refining/<epicSlug>` in the wrapper repo
   (`GET /workspaces/api/workspaces?repositoryId=<wrapper>` + branch match).
   No new column, no drift.
4. **Route**: `:projectId/epics/:epicSlug/refining` in qits-spa-projects,
   tab selection via `?tab=` (never a path segment — the workspaces rationale
   holds here too).
5. **Mirror scope**: today's Workspace Detail has NO sketch canvas (removed
   deliberately; screenshot paste + prompt attachments replaced it). "Same
   usages" therefore = tabs, chat + prompt + STT, agent terminal, files,
   services/web-view/actions, status strip. Copy, then let use decide trims.

## Flow

Refine click (on a REFINING draft card, button ordered before
Start implementation | Abandon):

1. Resolve the wrapper repository id (the repositories listing already marks
   the wrapper; fallback: by-name `<slug>-<slug>`).
2. `GET /workspaces/api/workspaces?repositoryId=` — active workspace with
   `branch === refining/<epicSlug>` → navigate to the refining page.
3. Else `POST /workspaces/api/workspaces` `{repositoryId, id:
   "refining-<epicSlug>", parent: "", branch: "refining/<epicSlug>",
   preamble: <rendered epic outline as markdown>, adoptExisting: false}`.
   On 409 "Branch already exists" retry with `adoptExisting: true`; on 409
   "Branch already has an active workspace" re-list and navigate.
4. Navigate. The refining page re-resolves the same way (idempotent; shows a
   create offer if the workspace is missing, e.g. after a discard).

The preamble carries the epic's title, description and current
feature/task outline — the workspace's stated goal.

## Phases (all in frontends/qits-spa-projects, commits on main)

- **A — plumbing + entry + shell**: copied API layer (workspaces-api,
  workspace-events, workspace-daemon-api transport, dtos), the Refine action
  + create/adopt flow, the route, the refining page shell + tabs host +
  status strip (merge panel deferred to C) + starting panel; placeholders
  for the not-yet-copied tabs. Dev proxy entries `/workspaces/api`,
  `/workspaces/container`, `/stt/api` (ws: true where needed).
- **B — interactive tabs**: agents/terminal (agent-session, agents-panel,
  embedded-session, session-tree, plugins-section + their APIs), chat
  (chat-socket/model/conversation/chat-panel), prompt panel + STT
  (speech-api, speech-runtime, recorder, level-meter) + prompt draft +
  attachments.
- **C — remaining tabs**: files (panel, tree, viewer, navigation, filters),
  web-view + element-picker + services, actions/bootstrap, merge panel.
- **Verify**: ng test + lint each phase; then browser e2e via ng serve +
  proxy against the live gateway — refine a real epic, watch
  `refining/<slug>` appear on the wrapper, drive terminal/chat/STT.

## Known seams / risks

- The workspace-daemon provisioner's handling of the wrapper's 34 submodules
  is unproven (the projects-daemon proved ITS clone path, not this one).
  The e2e will show it; not a UI concern.
- qits-spa-projects is Angular 21 (node ceiling) — source SPA is 21.2,
  compatible.
- `epic-draft-card.ts` states "nothing has a branch — the scope is not
  frozen"; that comment needs updating once refining branches exist.
