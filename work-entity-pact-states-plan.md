# Work-entity pact states (qits-projects-service → its consumers)

Epic: qits-112. Status: plan.

The unified SPA (`qits-landing-app`) will show work: counts on the project card first, then lists
and detail pages for epics, tickets, features, tasks and campaigns. Every answer it relies on must
come from a qits-projects golden master, and every call it makes must be in its pact. This plan
fixes the provider states and the recorded operations up front, so each new screen adds a row
here instead of inventing a state.

## Rules

- **One state per situation a consumer meets**, named by the situation, not by the test
  ("a project with refined work", never "work test 1").
- **Each state seeds its own project** with fresh ids and returns its params (`projectId`,
  `entityId`, …). No state relies on another state or on an empty database.
- **Combinations are named states.** States do not compose (see the thread on 2026-10-02): "an
  epic with features and tasks" is one state, not "an epic" + "with features".
- **A state is recorded for every operation a consumer calls in it**, with the query it calls
  with (`status=REFINED`), so the consumer mocks with exactly that answer.
- **Only what a pact names is binding.** A state may hold more than one consumer reads.
- **Every recorded operation needs an `operationId`** in `docs/openapi.yml`. The entity endpoints
  have none today; add them as part of the first slice (`listProjectEntities`, `getEntity`,
  `listEntityComments`, `listProjectEpics`, `listProjectTickets`, `listProjectCampaigns`).

## Lifecycle facts the states must cover

- Archetypes: EPIC, TICKET, FEATURE, TASK, CAMPAIGN.
- Epic and ticket status: REPORTED → REFINED → IMPLEMENTED → VERIFIED → DONE, or DROPPED.
- Features and tasks have no status, only an `implemented` instant.
- Entities can be blocked, can depend on others, carry comments, and nest (epic → feature →
  task). A campaign orders several developments.

## State catalogue

| # | State | Seeds | Operations recorded | First consumer use |
|---|---|---|---|---|
| 1 | a project with refined work | 3 REFINED (2 tickets, 1 epic), 1 REPORTED, 1 DONE | `listProjectEntities?status=REFINED` | card "Work" tile (in progress) |
| 2 | a project with no work | a project, no entities | `listProjectEntities`, `…?status=REFINED` | card "Work" = 0 |
| 3 | a project with work in every status | one epic and one ticket per status, incl. DROPPED | `listProjectEntities` (no filter), `listProjectEpics`, `listProjectTickets` | status columns / filters |
| 4 | an epic with features and tasks | 1 epic → 2 features (one implemented) → 3 tasks (one implemented) | `getEntity` (epic, with children), `listProjectEntities?parent=` | epic detail page |
| 5 | a ticket with comments | 1 ticket, 3 comments by 2 authors | `getEntity`, `listEntityComments` | ticket detail page |
| 6 | a blocked ticket with a dependency | ticket A blocked, depends on ticket B | `getEntity` | blocked marker |
| 7 | a campaign with ordered developments | 1 campaign ordering 3 epics, one done | `listProjectCampaigns`, `getEntity` (campaign) | campaign view |
| 8 | no entity with the given id | nothing | `getEntity` (404) | not-found page |
| 9 | a project with pending release requests | PENDING (CI not answered), READY (CI passed), REJECTED (CI failed), CONFLICTED, RELEASED, and one FINALIZED | `listProjectReleaseRequests` | top-bar release menu (recorded) |
| 10 | a project with no release requests | a project with one repository, no requests | `listProjectReleaseRequests` | release menu, empty (recorded) |

Rows 1, 2 and 8 come first (the card needs them); rows 9 and 10 serve the release menu. Release
requests are written straight to the table with fixed times, and their CI answers as ledger
verdicts at the folded sha; the states delete the rows again after each use, because open requests
are swept by every later test. The others are recorded when the screen that
calls them is built, in the same change as that screen's pact interaction, so no golden master
exists that nobody consumes.

## Order of a slice

1. qits-projects-service: the state, its golden masters, `operationId`s; release. The golden
   masters publish as `@qits/projects-golden-masters` (and the jar).
2. `@qits/angular/testing`: only if the slice needs something new (for example query parameters
   in a recorded request).
3. qits-landing-app: pin the golden masters exactly, the store with `consume(...)`, the
   `.pact.spec.ts` interaction with its UI trigger slug, plain and screenshot specs from the same
   golden masters; release. qits-projects verifies the new pact when qits-maintenance bumps it.

## Open questions

- Should "Work" stay a count of REFINED entities, or become per-archetype (epics vs tickets)?
  The mapping lives in one place in the landing store, so either is a small change.
- Do features and tasks count as "work" on the card, or only epics and tickets?
