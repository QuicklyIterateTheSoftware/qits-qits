# The workspace overview: what it was for, and what it should be centred on

Status: UX EXPLORATION (2026-08-01) — observed, reframed, NOT settled. No implementation until the
user picks a concept.

The monolith had one screen where a person went to see everything they had going on. It was the
repository detail page, and its main content was a tree of that repository's branches. It worked
well, and almost every good idea in it is worth keeping. But it was *about a repository*, and the
new platform has decided it does not want to be — so the question is not "how do we port the branch
tree", it is "what is the row, if a row is no longer a branch in a repository".

This document does three things. It records the old screen faithfully, because it is the only
existing evidence of what the job actually was. It names, one by one, the assumptions the old screen
made because a repository was in its URL — those are the traps. Then it lays out four genuinely
different things the overview could be centred on instead, with what each buys and what each costs,
and closes with the forks the user has to settle before anyone writes code.

Nothing here is a plan. There are no workstreams and no file paths to edit on purpose.

## 1. What the screen was for

Stripped of its mechanism, the job was: **"what am I in the middle of, and what does it need from me
next?"**

The monolith's own user-flow docs say it in almost those words. `review-changes.md` — the flow that
owns this screen — is titled "see the changes currently in flight in a repository so that I can
decide which to integrate, update, or abandon". `workspace/README.md` is blunter still: the workspace
domain "is about the **change lifecycle**: proposing work, keeping it current with its parent,
reviewing what is in flight, integrating it when complete, and abandoning it when no longer needed."
Not one of those six verbs is about a repository. They are all about a *unit of work*.

Watch what a person actually did on the page, in rough order of frequency:

1. Scanned for the workspace whose coding agent was waiting on them, and clicked into its chat.
2. Read two numbers per row — how far ahead of its parent, how far behind — and decided whether
   something needed catching up or was ready to go in.
3. Opened a count to see the actual commits before committing to a merge.
4. Started a stopped container so they could work in it.
5. Forked a new branch to start something.
6. Integrated or abandoned something that was done.

Now split that by what it needed the repository for. Items 1, 4 and 6 need the repository only to
address the thing — the repository is a lookup key, not information. Items 2, 3 and 5 genuinely are
repository-shaped: ahead/behind is computed inside one git origin, commits belong to one history, and
"branch off" needs a parent ref that exists somewhere.

So the honest split is: **the *questions* the screen answered were about work in flight; the *answers*
happened to be computed per repository.** The old design let the second fact dictate the first, and
put a repository in the URL. That is the whole problem, and it is a smaller problem than it looks —
most of the screen survives being re-scoped. Two things do not, and they are named in section 4.

There is a second, quieter job the page did that is easy to miss: it was the only place where the
*intent* of a piece of work was visible next to its state. A workspace carries a markdown preamble
written at creation ("why this exists and what 'done' means") and a markdown result written when it
ends. That is the thing that makes a row mean something other than a branch name, and it is the
single best idea on the old screen. The overview, ironically, never showed it — you had to open the
workspace or the history page. Any redesign that keeps the preamble buried is repeating a mistake.

## 2. The anatomy and the interactions, as observed

The route was `/repositories/:repoId`. Top to bottom the page was: a header naming the repository; a
sticky agent-activity strip; a sync bar; a submodules section; then the branch forest under a
"Branches" heading. History lived on a separate route.

### The agent-activity strip

One horizontal row of small buttons, one per workspace in this repository that has a live coding-agent
session. Each button is a status dot plus the branch name (falling back to the workspace id), with the
state as its hover title: BUSY renders as a pulsing dot and reads "Cooking…", WAITING is amber and
reads "Waiting on you", IDLE and ENDED are grey. Clicking one opens that workspace's Chat tab
directly — not the workspace, the *chat*.

Two decisions here mattered. **Ordering is newest-activity-first, left to right** — and specifically,
a session that just *stopped* bubbles to the far left, because stopping is its most recent change.
That is the "which conversation is blocked on me" ordering, and it is deliberate. And the strip
**hides itself entirely** when nothing is active, collapsing its own sticky chrome so an idle
repository shows no empty band.

Ordering memory lived on the client, in a root-scoped store that survives page remounts. It is not a
server fact, so it does not survive a reload or follow you to another browser.

The project page mounted *one strip per repository*, stacked, each labelled with its repo name. That
is the monolith admitting the model does not compose: it could not merge activity across repositories
into one ordering, so it drew N rows instead.

### The sync bar

A main-branch selector, the repository's ahead/behind against its git remote as `↑n ↓n` in mono,
and Pull / Sync / Push. The status line has four distinct readings rather than one: "Checking
remote…", "Remote unreachable", "Branch not on remote yet", "Up to date with remote", or the two
counts. Every control locks while any git operation is running — and the lock survives closing the
progress dialog, a page reload, and a second tab, because a discovery query asks the server what is
running.

### The submodules section

Imported submodule edges, each linking to the sibling repository it became; the still-unimported
`.gitmodules` entries; an "Import N submodules" button that imports this level only; and a field to
pre-serve a not-yet-existing submodule's backend. Renders nothing at all for a submodule-free
repository. This is pure repository structure and has no work-in-flight content whatsoever.

### The branch forest — the actual content

**A row is a branch, not a workspace.** That is the foundational choice, and everything follows from
it. Branches with a workspace are richer rows; branches without one are still rows.

**Nesting.** Each branch nests under the branch it forked from. The parent is resolved as: the
workspace's recorded fork point when the branch is workspace-backed, otherwise the repository's
configured main branch. A branch with no resolvable parent, or whose parent is itself, is a root. The
tree renders expanded, always — there is no collapsed default and no persisted expansion state.

**Sibling ordering is alphabetical by branch name.** Not by recency, not by activity, not by state.
This falls out of the backend handing back `git branch --format=%(refname:short)` unsorted-by-anything,
and it was never revisited. It is the weakest part of the screen: the row you need most is wherever
the alphabet put it.

**The connector.** Immediately left of each card, two stacked mono numbers: `-behind` on top,
`+ahead` below, with `+ahead` in bolder weight. The behind number renders only for workspace-backed
branches — a plain branch has no working tree to pull into, so the slot is held invisible rather than
shown as zero, which keeps every row's baseline aligned. The whole element is a button; clicking it
opens a popover.

**The conflict marker.** When a workspace-backed branch is both ahead and behind *and* the backend
says merging its parent in would conflict, the count trigger is replaced by a red alert icon above the
`+ahead` count. It is not a badge — it is the click target, and clicking it opens conflict resolution
rather than the commits popover. Conflict is thus visually *substituted for* the ordinary affordance,
not added beside it.

**The commits popover.** Tabbed: "N behind" and "N forward". Behind is rendered first so it is the
default when it exists. Each tab lists commits — short hash, author, date on one line, subject below,
then every file the commit touched — and each commit links to its detail view in the right branch's
context (the parent's history for incoming commits, this branch's for outgoing). The list scrolls
inside itself. Each tab pins one action at its foot: the Behind tab offers **"Fast-forward to
&lt;parent&gt;"** when the branch has no commits of its own, and **"Merge &lt;parent&gt; in"**
otherwise — the button says what will happen. The Forward tab offers **Integrate**.

The popover is **click-to-open and stays open** until the explicit ×, or another click on the count.
The code says why: closing on mouse-leave was tried and was disruptive. Commits load lazily, only for
the branch whose popover is open.

**The card.** Branch name in medium weight. If workspace-backed, a subline reading
`workspace: <id> · forked from <parent>` followed by up to four badges:

- **Runtime** — the container state, always shown for a workspace: RUNNING, STOPPED, PROVISIONING, or
  FAILED. FAILED is destructive-coloured and carries the provisioning error as its hover title.
- **Clean / Dirty** — the working tree, reported live by the in-container daemon. Only shown when
  reported; unknown means *no badge at all*, never a third label.
- **up since &lt;time&gt;** — when the workspace's daemon registered. Resets on every reconnect, so it
  is "connected since", not "created".
- **daemon &lt;version&gt;** — the daemon build inside the container. Ordinarily neutral; when the
  registry knows a newer build is connected elsewhere it turns destructive with a warning triangle and
  the hover text invites a recreate.

The last two are a deliberately incremental family: the workspace-registry epic's rule is that every
such fact is live-only, known only while the container runs, and renders as *absence* when unknown.

**The actions**, all inline on the card, all always visible, wrapping to a second line when they do
not fit. For a workspace-backed row: View commits; a container control that is one of "Starting…"
(disabled, spinning), "Stop", or "Start"/"Recreate"; "Work on it" (opens the workspace); "Run…"; and
"Configure with Claude". For a plain branch: "Create workspace". Then, on every row, "Branch off
workspace". Then exactly one closing action: "Cleanup" when the backend says the branch is fully
merged and safe, "Abandon" for a workspace, or "Delete" for a plain branch with no children.

Three modifier behaviours are worth recording because they are unusual:

- **Shift turns Start into Delete.** Holding Shift over a stopped or failed workspace swaps the Start
  button for a destructive "Delete", which removes the container but keeps the branch and the
  workspace row. The modifier is tracked from window key events, so it applies before you have
  interacted at all, and it resets on window blur so a missed key-up cannot strand the button in its
  destructive state.
- **Recreate appears only when the daemon is outdated**, and is disabled unless the working tree is
  clean, because recreating destroys the container.
- **Destructive actions are hidden, not disabled, while the tree is dirty.** Abandon and Cleanup
  simply are not rendered when the daemon reports uncommitted changes. Cleanup is deliberately
  no-confirm — the backend re-verifies safety and refuses if anything would be lost.

### The dialogs

Branch off (workspace id, optional branch name, markdown goal). Integrate (target branch selector,
defaulting to the workspace's parent and falling back to main; markdown result; the source branch is
removed from the target list). Abandon (markdown result; the copy states the branch goes but the
record stays). Delete branch. Delete container, gated on **typing the branch name** — the only typed
confirmation on the page, on the only action that destroys uncommitted work without also destroying
the branch. Uncommitted changes, which is a *blocked-merge* dialog that offers "Work on it" rather
than merely refusing. Resolve merge conflict, which lists the conflicting files, then forks a separate
resolution workspace, launches an autonomous agent in it to merge the parent in and fix the
conflicts, and navigates you to that agent's live terminal — leaving your original workspace
untouched. Run…, which lists only *interactive* actions and opens a terminal. And "Starting
workspace" / "Recreating workspace", which stream the segmented provisioning log; closing the dialog
does not stop the work, and reopening replays it.

### What refreshes, and how often

**Nothing polls.** The route is pure push, over one Server-Sent-Events channel per repository. Three
topics matter here:

- `process` — a repository pull/sync/push started or finished; refetches the active-process discovery
  so the sync bar locks and unlocks.
- `git-status` — a container daemon reported its working tree flipped clean↔dirty; refetches the
  workspace list, so the Clean/Dirty badge is live.
- `agent-activity` — a coding agent's rollup state changed; refetches the workspace list, so the
  activity strip re-sorts live.

On every connect *and reconnect*, everything is invalidated once. That is the entire gap-recovery
protocol — there is no replay, no cursor, no sequence number, and the design doc says so explicitly.
A 25-second heartbeat keeps idle connections alive and server-side hints are debounced to roughly one
per second. An idle repository page issues zero requests, which is the point: the predecessor design
polled eight queries at 3–5 second intervals, about ninety requests a minute per open tab.

Separately, **any successful mutation invalidates every cached query whose key contains the repository
id.** This is deliberate and worth stealing: a fast-forward changes ahead/behind on a sibling row, and
refreshing only the caller's slice left the rest of the page lying until a manual reload.

One gap, and it is real: **the branch list is not on the live channel.** The per-branch ahead/behind
and cleanup-eligibility for branches *without* a workspace refresh only on a mutation or on an SSE
reconnect. Workspace-backed rows get refreshed incidentally, because the `git-status` and
`agent-activity` hints happen to refetch the same list — an accident, not a cadence. Nobody appears to
have noticed, which tells you how much of the screen's value was in the workspace rows.

### History, which was not on this screen

A separate route showed every workspace the repository ever had, active and resolved, as a card grid:
workspace id, a status badge (active / integrated / abandoned), "off &lt;parent&gt;", created and
resolved dates. Opening one showed its preamble, its result, its event timeline, and every command
that ran in it. Resolved workspaces keep their row forever; only the branch and the checkout are
deleted. This is the durable-record idea, and the overview linked to it with a single "History"
button.

## 3. Every state the screen had

**Loading.** One combined gate: "Loading branches…" while *either* the branch list or the workspace
list is still pending, because a row cannot be drawn without both. No skeleton rows, no partial tree.

**Error.** One combined message, "Failed to load branches", for either query failing. No retry
affordance.

**Empty repository / no branches.** A proper empty state: "No branches yet — This repository has no
branches to work from." In practice unreachable for a cloned repository; it exists for a
seeded-but-empty origin.

**No workspaces, but branches exist.** Not a distinguished state. The tree renders, every row shows
"Create workspace", and the connector shows ahead counts only. There is no prompt anywhere that
explains what a workspace is or invites you to make your first one.

**Branch with no workspace.** A card with no subline and no badges. Primary action is "Create
workspace", which *adopts the branch in place* rather than forking a new one — one click, no dialog,
the workspace id derived from the branch name (non-alphanumerics to dashes, capped, de-collided by
suffixing `-2`, `-3`), and the parent set to the repository's main branch. Delete is offered only if
the branch has no children. The behind count is suppressed entirely, because there is no working tree
to pull into.

**Workspace with no branch.** Not representable, and not handled. The tree is built by walking
branches; a workspace whose branch has vanished has no node and silently disappears from the
overview. It remains visible only in history. This is a genuine hole, not a decision.

**Conflicts.** The red marker described above, replacing the count affordance. Note that the marker
requires the branch to be both ahead and behind — a workspace that is only behind and would conflict
does not show it.

**Sync in progress.** The sync bar's controls lock and stay locked across dialog close, reload and
second tab. The branch tree does *not* lock: you can branch off, integrate or start a container in the
middle of a repository pull. Whether that is correct was never argued either way.

**Container provisioning.** A disabled, spinning "Starting…" in place of the control, plus a dialog
streaming the segmented provisioning log. The dialog is closeable and the work continues; reopening
replays.

**Container failed.** Destructive runtime badge with the error as hover text; the Start button
relabels itself "Recreate".

**Dirty working tree.** Abandon and Cleanup vanish. Every merge action reroutes to the "Uncommitted
changes" dialog instead of running. Recreate is disabled with an explanatory title. The backend
re-checks all of it, so the UI guard is convenience, not security.

**Unknown clean/dirty.** No badge, and treated everywhere as *not dirty* — destructive actions stay
offered. The registry's stated rule is that null means unknown means render nothing.

**Detached / unresolvable parent.** A branch whose parent does not resolve, is blank, or is itself
becomes a root of the forest with no connector and no counts. It is not marked as anomalous in any
way; it just floats at the top level next to main.

**Daemon outdated.** The version badge turns destructive with a triangle and a "Recreate workspace"
button appears, disabled unless clean.

## 4. The repository-centric assumptions, named one by one

This is the section to argue with. Each item is something the old UX could only do, or only mean,
because exactly one repository was in scope.

**1. The repository is in the route, so no row ever names it.** Every identifier on the page is
relative to a `repoId` in the URL. No row shows a repository, because it did not have to. The moment
the overview spans more than one, every row needs a repository label — and, as of today,
`WorkspaceDto` on the new platform carries **no `repositoryId` field at all**. The very first
consequence of de-repository-ing this screen is a backend change, before any design question.

**2. The row unit is a branch, and branches only exist inside a repository.** `feature/a` is not a
globally meaningful name. Two repositories can both have `main`, `epic/x` and `task/y`; on the live
platform they demonstrably do. A cross-repository list keyed on branch name is ambiguous by
construction.

**3. Parent resolution silently defaults to *the repository's* configured main branch.** Any branch
without a recorded workspace fork point is *asserted* to hang off main. Inside one repository that is
a reasonable lie. Across repositories it is not even wrong — "main" is not one node, it is N nodes
that happen to share a name. Any tree drawn across repositories has N roots, and calling them all
"main" would merge things that have nothing to do with each other.

**4. Ahead/behind is computed inside one git origin, and it is the densest information on the
screen.** Those two numbers are the reason the page works. They compare two refs in one repository.
There is no cross-repository analogue, and no amount of UI can invent one. Whatever the new overview
is, this element either stays repository-scoped-per-row or is replaced by something else that answers
"can this move yet".

**5. Commit identity is repository-scoped.** Every commit link in the popover is
`/repositories/:repoId/branch/:branch/commits/:hash`. A shared commits view across repositories needs
a repository in the link, which means in the data.

**6. Pull / Sync / Push act on the repository, and have no per-row analogue.** The sync bar is page
furniture whose subject is the page's implicit noun. If the page's noun changes, the sync bar has no
home on it — it either moves to a repository page or it becomes a per-row action, which is a different
action with different semantics ("sync the repository this work lives in").

**7. The main-branch selector configures the repository.** Same problem, worse: it is a *settings*
control living on an operational screen, and it only makes sense with one repository in scope.

**8. Submodules are a statement about the repository graph, not about work.** "This repository's
children are these sibling repositories" belongs to a repository page. Nothing on it is in flight.

**9. Integrate's target list is one repository's branch list.** The dialog is a select over
`GET .../branches`. In the new model the target is not chosen at all any more — release always
targets main, integrate always targets the parent — which quietly removes this assumption. Worth
noticing: **the release-flow addendum has already eliminated one repository-centric control**, and
that is the shape of the answer for several others.

**10. Cleanup eligibility is computed per branch against the repository's main branch.** A boolean the
backend hands down per branch, meaningful only in one origin.

**11. The delete-branch guard is a within-repository containment rule** — "refuse if this branch is
the parent of any workspace" — which is exactly the tree the page draws. Outside that tree the rule has
no visible justification.

**12. Agent activity is aggregated per repository, and it does not compose.** The proof is in the
monolith itself: the project page could not merge activity into one ordering, so it stacked one strip
per repository, each with a repo-name prefix. That is the single clearest signal in the codebase that
the repository scope was in the way rather than in the design.

**13. Live-ness is per repository.** One SSE endpoint per repo. Watching five repositories means five
connections — which the monolith worked around by adding a *separate* app-wide channel that
invalidates the whole workspace-list cache prefix. A cross-repository overview needs the app-wide
channel to be the primary one, not the fallback.

**14. History is per repository.** "Everything that ever flowed through" is scoped to one origin, so
there is no way to ask "what did I finish last week" across the platform.

**15. The row's title is not unique outside its repository — and the new service says so out loud.**
The adopt-a-branch flow de-collides derived ids against *that repository's* existing workspaces.
qits-workspaces goes further and makes it a rule: `Workspace.id` (a generated number) is the
identifier, while `workspaceId` — the string every row is titled with, on both the old screen and the
new one — is "a branch-derived **label**, not an identifier: unique only per repository, only among
ACTIVE rows, and reusable once a workspace resolves." A cross-repository list titled by that label
will show duplicate titles by design, and a *historical* list will show the same label meaning two
different pieces of work. Whatever a cross-repository row is titled with, it cannot be that string
alone.

**16. And the trap: work items exist, and were never joined to workspaces.** The monolith has a full
project → epic → feature → task hierarchy with its own pages, and *nothing* connects it to the branch
tree. The task detail page shows a repository link and an "implemented" checkbox; it has no workspace,
no branch, no run. On the new platform the same hole is still open: `TaskDto` carries a `repositoryId`
but no workspace and no branch, and `WorkspaceDto` carries no task reference. **Any concept below
that centres the overview on a work item is not a redesign — it is a new backend relationship that
does not exist yet.** That is the assumption most likely to be missed, because the pages are all
sitting right there and look like they must already be connected.

It is worse than merely absent, and this is the part to read twice: **the platform now has two
different "epic"s that share a word and nothing else.** qits-projects has `EpicDto` → `FeatureDto` →
`TaskDto`, a planning tree. The release flow has `main` → `epic/…` → `task/…`, a branch tree. They use
the same two nouns in the same order and are completely unjoined. A UI that says "epic" without saying
which one will be misread by everybody, including its authors.

**17. The list is ACTIVE-only and unordered, and that is inherited too.** The new
`GET /workspaces/api/workspaces` returns active rows in database order — there is no `ORDER BY` in the
query at all. The old screen at least had a deterministic (alphabetical) order as a side effect of
git. The new one has none. Resolved work is a second, separately-scoped call. Any overview that wants
"oldest in flight first" or "most recently touched first" is asking for a field and an order the API
does not have: **there is no `createdAt` and no `updatedAt` on the live workspace resource** — only
`resolvedAt`, and creation timestamps live on the history resource.

### Three things that are not assumptions but change the ground

- **The service split already happened.** On the new platform, branches, commits, sync, submodules and
  the repository entity live in **qits-projects**; workspaces live in **qits-workspaces**.
  The `qits-repositories` submodule was an empty stub and has been removed. The branch-tree
  data and the workspace data are now two services, joined by a repository id held as a plain string
  with no foreign key and a deliberate rule against ever making it one. Anything that redraws the old
  tree is a cross-service join in the browser.

- **The new list endpoint inherited assumption 1 verbatim.** `GET /workspaces/api/workspaces` takes a
  `repositoryId` query parameter; without one it answers `Repository not found: null`. Since a
  repository must in turn be reached through a project, a cross-repository overview is N+1 calls
  today, and a cross-*project* one is worse. The service is not being lazy about this — its own docs
  state the position as a boundary decision: "a workspace is not a sub-resource of a repository … so
  collections filter by `?repositoryId=` and an item is `{id}` alone." Notably the service *does*
  learn a `projectId` internally (its repository-lookup port returns one, nullable), so exposing it is
  not a modelling problem.

- **Not all work in flight is a workspace, by design.** The release-train plan is explicit that a
  `maintenance/<upstream>` branch — a dependency bump that has been tested and is about to release —
  gets **no workspace row and should not have one**: "a workspace is a container lifecycle, a branch
  *claim* with an ACTIVE-uniqueness constraint, and a resolution state machine — all wrong-shaped for
  a branch a pipeline overwrites at will." That work is real, it is in flight, and it can never appear
  in a list built from the workspace resource. Any overview that promises "everything in flight" is
  promising a second source — the branch listing on qits-projects, or CI runs. Any overview that does
  not promise that should say what it *is* listing, in words, on the page.

## 5. The reframing options

Four concepts. They are not variations on a theme — they disagree about what a row *is*.

Common to all four, and worth stating once rather than four times. A row can no longer be identified
by a branch name or a workspace label alone, so all four need `repositoryId` (and a display name) on
the workspace list resource, plus a list endpoint that is not gated on one repository. All four also
want a creation or last-touched timestamp, which the live workspace resource does not have — without
it there is no honest default order, and "unordered" is what the current API returns. Those are the
shared costs; neither is large, and neither is optional.

### Option A — the release ladder

**A row is a branch, positioned by its level in the release hierarchy.** `main` at the root, `epic/…`
branches beneath it, `task/…` branches beneath those. Structurally this is the old tree — but the
levels are now *named by the release flow* rather than inferred from an arbitrary fork point, and the
new platform's two doors map onto them exactly: a row whose parent is `main` shows **Release**, every
other row shows **Integrate**. The 409 `RELEASE_REQUIRED` becomes structurally impossible to hit,
because the tree tells you which door you are standing in front of.

*What the user scans for:* what is ready to move up a level, and what is blocking the level above it.
Reading down a subtree tells you an epic's story: three tasks, two integrated, one still behind.

*What gets easier:* the doors stop being a per-row guess and become the geometry of the page. "What
can I release today" is a single glance at the second rank. Lineage — which the old tree had by
accident — becomes meaningful information rather than a git artefact.

*What gets harder or is lost:* the ladder is only one tree **per repository**. Cross-repository it is
N forests whose roots all read "main", which is exactly assumption 3. Either the page groups by
repository — reintroducing repository-centricity through the back door, just one level up — or it
draws N roots and accepts that the top rank is noise. Branches with no workspace still collapse onto
main regardless of what they are, so the ladder is only as true as the fork points recorded at
creation. And a tree is a poor scanning structure when what you want is "the three things that need
me": the row you need is wherever the hierarchy put it, which is the old alphabetical-ordering
complaint in a new costume.

*What it demands from the backend:* the branch list (qits-projects) joined to the workspace list
(qits-workspaces) per repository, in the browser, for every repository in scope, plus the repository's
main branch to know which rows are release-door rows — a fact qits-workspaces does not report. Note
the rule is recursive, not three-deep: integrate always targets the parent, so any stacking depth
works, and the ladder is three levels only because `main` has one door and everything else has the
other. Depth beyond two levels exists today only where a workspace recorded a non-main parent at
creation.

### Option B — the work item

**A row is a unit of work — a task, or a feature — and the workspace is an attribute of it.** A row
may have no workspace ("not started"), one, or in principle several. The row's title is the task
title, or the workspace's markdown goal; the branch name is a detail, not the identity.

*What the user scans for:* how the plan is going. What was planned and has not started, what is in
flight, what is done. This is the only option that can answer a question about work that does not
exist yet.

*What gets easier:* it spans repositories naturally, because a task already names its repository — the
grouping is the project and the epic, which are genuinely cross-repository concepts. The preamble
finally has a home: the row's title *is* the intent. And it is the only framing in which "we planned
eleven things and shipped four" is visible anywhere in the product.

*What gets harder or is lost:* everything git demotes to a detail line. Ahead/behind, conflicts,
cleanup eligibility, container state — none of them are the scanline any more, and the screen stops
being able to answer "which of these can move". Worse, work that was not started from a task has no
row. On the live platform today that is **every workspace**, because the link does not exist — the
same orphan problem the CI explorer hit, where a project-centric tree rendered empty while the entire
run history sat in a bucket the UI never drew. An "unattributed" bucket would be the main content on
day one, which is a strong argument that this option is a *later* view, not the first one.

*What it demands from the backend:* the task↔workspace relationship, which does not exist in either
codebase. Someone must decide whether it is one-to-one, whether creating a workspace from a task is
the primary creation path, and what happens to the many workspaces created another way.

### Option C — the attention queue

**A row is a workspace, ordered by who needs you next.** WAITING first, then BUSY, then recently
touched, then everything idle. This is the monolith's sticky activity strip promoted from a
twelve-pixel band to the whole screen.

*What the user scans for:* the conversation that is blocked on them. Nothing else.

*What gets easier:* it takes the single most-used affordance on the old page and makes it the page.
It is naturally cross-repository — the project page's stacked strips were a workaround for exactly
this, and merging them is the fix. It is genuinely live today: `agentActivity` is already on
`WorkspaceDto` and the `agent-activity` SSE topic already fires. And "a session that just stopped
sorts to the front" is a real insight about agent-driven work that no git-shaped view produces.

*What gets harder or is lost:* it cannot answer "what is ready to release", because git state is not
the ordering fact. A workspace with no agent session has no place in the ordering at all — the old
strip simply omitted them, which is fine for a strip and fatal for a page. Ordering lives in a
client-side store today, so it is not stable across reloads or devices unless the backend stamps a
last-activity-changed timestamp. And there is a real risk of a screen that is only ever about the
agent, when a person also does things by hand.

*What it demands from the backend:* a cross-repository workspace list, a server-side
activity-changed-at timestamp, and the app-wide SSE channel promoted to primary.

### Option D — the flat queue, grouped by what it needs

**A row is a workspace. There is no tree.** Rows fall into a small number of buckets named for the
decision they demand, and are ordered by recency inside each bucket:

- **Needs you** — the agent is waiting, or there is a conflict, or a merge is blocked by uncommitted
  changes.
- **Moving** — an agent is busy, a container is provisioning, a build is running.
- **Ready** — clean, ahead of its parent, not behind, last build green. This is the bucket that shows
  Release or Integrate.
- **Parked** — stopped, idle, nothing to decide.

*What the user scans for:* the next thing to touch, in one vertical read, with no expansion and no
navigation.

*What gets easier:* it composes across repositories with no hierarchy to reconcile — a repository is a
label on a row, not a structure. It degrades gracefully when a fact is unknown, which matters because
half the interesting facts (clean, daemon, agent state) are live-only and null whenever a container is
stopped. And it does the arithmetic the old page made you do: the old screen showed four badges and
two numbers and left you to work out that this row was ready and that one was stuck. The buckets *are*
that conclusion.

*What gets harder or is lost:* lineage. You cannot see that three tasks hang off one epic — which the
release flow has just made meaningful, so this option throws away brand-new information. Mitigable by
writing the ladder on the row as breadcrumb text (`task/x → epic/y → main`), which keeps the fact
without the structure, but it is text, not geometry. And the bucket predicates become a design
surface: get "Ready" wrong and the page confidently lies, which is worse than the old page's honest
ambiguity.

There is a second, sharper honesty problem the name invites. A page titled "everything in flight"
that lists workspaces is not telling the truth: a `maintenance/<upstream>` branch is tested,
about-to-release work that deliberately has no workspace row and never will. Either the page draws
from a second source, or it is called something narrower and says so.

*What it demands from the backend:* a cross-repository workspace list with a repository label, plus —
to make "Ready" honest — the last CI result for `(repository, branch)`. That last one is available
today: qits-ci's runs carry `repoId` and `branch`, so the join exists without new modelling. Making
the title honest additionally means the branch listing, from a different service.

### What the new SPA already is, and how each option relates to it

This matters, so it gets its own reading rather than a footnote. `qits-workspaces-frontend` is not a
skeleton — it is a considered, finished, one-repository list, and it is better than the old screen in
several specific ways.

What it does today. Two dropdowns gate everything: pick a project, then pick a repository; both ride
in the URL query string, so the page is bookmarkable and the back button means "the previous
repository". A live lede sentence names the count and teaches the model in passing: "*N* live
workspaces in *repo*. Work off `main` is released into it; anything else is integrated into its
parent branch." Below that, once anything has been merged in the session, a green **"Landed from this
screen"** box holds the version, the source → target and the merge sha — deliberately *above* the
list, because a merged workspace disappears from the list and its sha would otherwise flash and
vanish. Then an unadorned vertical stack of rows: no table, no columns, no headers, no grouping, no
sort control, no filter, no search, no pagination, in whatever order the server returned.

A row: the workspace label as a heading; a grey meta line reading `branch · off <parent> · 3 ahead ·
1 behind` (or `up to date`, or *nothing at all* when the counts are null — the code says why, and it
is the right reason: "a branch reported as 'up to date' because the service could not measure it
would be the list's one outright lie"); a badge strip of only what is actually known — runtime,
`uncommitted changes`, `agent busy/waiting/idle`, `conflicts with parent`; then the preamble as body
text. **The preamble is on the row.** The old screen never managed that.

The badge philosophy is written down and is worth adopting wholesale: badges are "**reported state,
never gates**. A STOPPED workspace integrates exactly as well as a RUNNING one … the runtime badge is
there to explain the row, not to justify a disabled button." Conflicts warn; they do not block.

The right third is the door, and there is **only ever one**: Release when the parent resolves to the
repository's main branch, Integrate otherwise, because offering both "would put a button on every row
that answers 409 every time it is pressed". Pressing expands the row into a small form with a live
preview of the exact commit subject and a character countdown out of 100. The result has **six
distinct outcome surfaces** — landed, merge conflict (with the file list), main-moved ("pressing
again is the whole fix"), already-integrated ("this list is simply out of date"), release-required
(offering "Release into `main` instead", which switches the door and *returns to the form* rather than
firing, so a mis-doored press can never become an unconfirmed release), and refused/no-answer. The
typed summary survives every failure and nothing is ever auto-retried, because a release is not
idempotent.

Loading is per-request shimmer; errors are per-request with their own retry; and there are three
distinct empty states, of which one is load-bearing: "No live workspaces in this repository.
Integrated and abandoned ones are history, and are not listed here."

Three honest gaps. It fetches `runtimeError`, `daemonVersion` and `daemonOutdated` and drops all three
on the floor. Its hand-written agent-activity type is missing the `ENDED` value the backend can send.
And the parent relationship is present in the data and rendered only as the text fragment "off
`epic/foo`" — there is no way to see that three task rows share one epic except by reading their
parent strings.

**So, per option:**

- **A (release ladder)** — *replaces* it. The ladder is a different page shape; the flat stack cannot
  become a tree by addition. The row content and both doors survive intact, but the project/repository
  gate stays and arguably hardens, since a ladder needs a repository to have one root.
- **B (work item)** — *sits beside* it. Different resource, different scope (project rather than
  repository), different primary noun. The workspace list stays exactly where it is as the "by
  repository" view, and the work-item view is a new page that links into it. Neither replaces the
  other, and B cannot be built at all until the task↔workspace link exists.
- **C (attention queue)** — *replaces* the gate, keeps the row. Drop the two dropdowns, keep the row
  and the door verbatim, re-sort. This is the smallest diff of the four and could be built on the
  existing row component more or less as-is — which is also the argument that it is not ambitious
  enough to be the whole answer.
- **D (state buckets)** — *extends* it. Same rows, same doors, same outcome surfaces, same badge
  philosophy. What changes is that the repository gate becomes a *filter* rather than a precondition,
  a repository label joins the meta line, and the flat stack acquires four headed groups. Nothing
  written so far is thrown away; the "Landed from this screen" box and the six outcome surfaces are
  reused unmodified. This is the only option where the existing work is a foundation rather than a
  precedent.

### The recommendation, clearly labelled as an opinion

**My opinion, not a decision: build D, carry A's ladder as text on the row, and treat B as a later
second view that is blocked on a backend relationship nobody has built.**

The reasoning. The user's constraint rules out A as the *overview*, because A cannot be one tree
without a repository at its root — every attempt to make the ladder span repositories reintroduces
repository grouping one level higher, which is the same screen wearing a hat. B is the most valuable
view in the long run and the least buildable now: with no task↔workspace link, its first release would
be a page whose only populated bucket is "unattributed", and that failure mode is already documented
on this platform. C is right about the ordering and wrong about the scope — "who needs me" is a
*bucket* and a *sort*, not a page, and promoting it wholesale loses every workspace without an agent.

D absorbs what is right in the other three. It takes C's ordering insight and makes it the first
bucket. It takes A's new hierarchy information and puts it on the row where it costs nothing. It
leaves B's slot open: when the task link exists, "Needs you / Moving / Ready / Parked" can become a
grouping *choice* alongside "by epic", on the same rows and the same data, with no rewrite.

And it is the only one of the four where the page gets *better* as facts go missing rather than worse,
which matters more than it sounds: a stopped workspace reports no cleanliness, no daemon, no agent
state, and on the old screen simply went blank.

The strongest argument against D — and the user should weigh it — is that bucket predicates are
opinions rendered as fact. "Ready" is a claim. If it is wrong even occasionally, people stop trusting
the page and start opening rows to check, at which point the buckets are worse than a plain list.

## 6. What carries over regardless

Independent of what a row turns out to be, these are the old screen's good ideas and none of them
depend on a repository:

**The workspace as a durable record with a stated intent.** A markdown goal written at creation, a
markdown result written at the end, a timeline in between, and the row survives resolution. This is
what makes a row mean something. The overview should *show* the goal — the old one never did, and it
is the cheapest improvement available.

**Two numbers, not one.** Ahead and behind, read separately, stacked, in mono, occupying almost no
space. Whatever replaces the tree, do not collapse them into a single "status".

**Progressive disclosure to the actual commits, in place.** The count is the summary; clicking it
shows the commits *and the files they touched*, right where the decision is being made. Do not send
people to a separate page to answer "what is actually in this".

**Buttons that say what will happen.** "Fast-forward to main" versus "Merge main in". "Start" versus
"Recreate". The label is computed from state, not from the action's category.

**Blocked actions route somewhere.** The uncommitted-changes dialog does not merely refuse; it offers
"Work on it" and takes you where the problem is fixable.

**Destructive actions hidden rather than disabled when they would lose work**, with a typed
confirmation on the one action that destroys uncommitted changes, and no confirmation at all on the
one the backend can prove is safe. That asymmetry is right.

**Unknown is a third state, rendered as absence.** No badge is better than a grey "unknown" badge, and
unknown must be treated as the safe value everywhere.

**Long work streams into a closeable dialog and is owned by the backend.** Closing does not cancel;
reloading reattaches; a second tab finds it. This should be the pattern for anything slow.

**Pure push, with invalidate-everything on reconnect.** No polling, no replay protocol, no cursors. An
idle overview should cost zero requests.

**Any mutation refreshes everything in scope**, because one merge changes several rows' numbers and a
partially-refreshed list is a lying list.

**A row for the thing that is not a workspace yet**, with one obvious way to make it one. The old
screen's "Create workspace" on a plain branch is a small, generous idea.

**The strip hides itself when empty** rather than rendering an empty band. Every conditional section
on the new page should do the same.

And from the new SPA, which is already better than the old screen on these and should not lose them
in a redesign:

**Badges report, they do not gate.** A stopped workspace integrates exactly as well as a running one.
A badge explains a row; it does not justify a disabled button. The old screen conflated the two in
several places and was worse for it.

**Unmeasured is not "up to date".** When drift cannot be measured the row says nothing rather than
claiming parity. That is the one lie a list of in-flight work must never tell.

**One door per row, never two.** The row computes which operation applies and offers only that one,
so the wrong door is unreachable rather than merely refused. And when the server does refuse with
"you wanted the other door", the affordance switches the door and returns you to the *form* — it does
not fire. A mis-aimed click can never become an unconfirmed release.

**Failure modes are distinct surfaces, not one red box.** Conflict, "the target moved", "already
done", "wrong door" and "no answer" are five different situations a person does five different things
about. Each gets its own heading, its own sentence and its own button. The typed summary survives all
of them, and nothing is auto-retried.

**Results outlive the row that produced them.** A merged workspace vanishes from a list of live work,
so the version and the merge sha are held in a panel above the list rather than on the row. Any
overview whose rows disappear when the work succeeds needs this, or success becomes invisible.

## 7. Questions the user must answer before anyone implements

1. **Is the overview scoped to one project, or to everything?** These are different pages with
   different columns. Cross-project needs a project label per row; cross-repository within one project
   needs a repository label; the current API gives neither. Answer this first — it changes the
   endpoint, not just the layout.

2. **Is a row a workspace, or a branch?** The old screen chose branch, which is why branches with no
   workspace were visible and offered an adopt action. If a row is a workspace, those branches vanish
   from the overview entirely. Which do you want to lose — the noise, or the visibility?

3. **Does the release ladder get drawn as nesting, or written on the row as text?** Nesting is
   strictly more expressive and forces a per-repository tree back onto the page. Text keeps the
   information and gives up the geometry. There is no third answer that is honest.

4. **Do we build the task↔workspace link now?** Without it, Option B cannot exist and the overview can
   never answer a question about planned-but-unstarted work. With it, "create a workspace" becomes a
   flow that starts at a task, which is a change to how work begins, not just how it is displayed.

5. **What is the row's default sort — most recently touched, most blocked, or closest to
   releasable?** Pick one. The other two become filters. Not picking one is how the old screen ended
   up alphabetical.

6. **Is resolved work part of the overview or a separate page?** History was separate in the
   monolith. As a fifth bucket or a filter it becomes answerable across repositories for the first
   time; as a separate page it stays cheap.

7. **Does the overview own repository operations at all?** Pull / Sync / Push, the main-branch
   selector and submodules are repository-shaped and have no per-row meaning. If they move to a
   repository page, this screen becomes purely about work in flight — which I think is the point — but
   somebody has to still be able to reach them.

8. **Is container lifecycle a thing you do from an overview?** Start / Stop / Recreate / Delete
   container were four of the seven buttons on every old row, and they are implementation, not
   intent. Hiding them until you open a workspace would halve the row's visual weight; keeping them
   preserves a workflow that clearly got used.

9. **How honest does "Ready" have to be?** If the overview groups by what a row needs, it is asserting
   things. Does "Ready" require a green build, or only clean-and-ahead? A wrong bucket is worse than
   no bucket.

10. **How live, and over how many channels?** Today live-ness is one SSE connection per repository. A
    cross-repository overview needs one app-wide channel to be the primary path. Is that acceptable,
    or should the overview refresh on a slower, cheaper cadence and leave push to the detail view?

11. **Does the overview list workspaces, or work?** A `maintenance/<upstream>` branch is tested,
    about-to-release work that by design has no workspace row. If the answer is "work", the page needs
    a second data source and a row shape that survives having no container, no agent and no preamble.
    If the answer is "workspaces", the page needs a name and a sentence that admit it.

12. **Which "epic" is on the screen?** The platform has a planning epic (project → epic → feature →
    task, in qits-projects) and a branch epic (`main` → `epic/…` → `task/…`, from the release flow).
    They share two nouns and are entirely unjoined. Either they get joined, or the UI has to name them
    apart before it prints either word — and picking the vocabulary is a decision, not an
    implementation detail.
