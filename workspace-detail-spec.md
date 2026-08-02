# The workspace detail view: a clean-room specification

Status: CLEAN-ROOM SPEC (2026-08-01) — behaviour observed in the monolith, written for
reimplementation without access to it.

This document describes one screen: the page you land on when you open a single workspace. It is
written so the screen can be rebuilt from this prose alone. Nothing here names a file, a class, or
a CSS rule from the original. Where the original made a decision that matters — an ordering rule,
a polling interval, an empty state, a reconnect strategy — the decision is recorded together with
the reason it exists, because the reason is what makes it reproducible.

Scope is the detail view only. The workspace list, the branch tree, projects, repositories-as-a-page,
and CI/CD are out of scope and owned elsewhere. Section 7 is opinionated about what should *not*
come across.

## 1. The pitch

A workspace is one unit of work: a branch, a container, and everything that has happened inside
it. The detail view is the room you sit in while that work happens. You open it to drive a coding
agent — compose a prompt, watch the agent think, read what it changed, run the app it just built,
look at the logs when it breaks — without leaving the page or losing your place. Every other
screen in the product tells you *about* workspaces; this one is where you *do* the work.

The job, in the user's words: "I've asked an agent to change something here. Show me what it is
doing, let me see the result, and let me tell it the next thing."

## 2. What exists today, measured (the anatomy)

### The route and the shell

The screen is addressed by a repository and a workspace. It carries an optional trailing URL
segment naming the active tab, so every tab is a shareable link. It also reads two query
parameters that deep-link into the file browser (a path, and an optional line range).

Three URL facts are load-bearing:

- **Changing tabs must not remount the page.** Tab changes only rewrite the trailing segment. If
  a tab change tore the page down, the chat socket would drop, the framed app would reload, and
  every scroll position would reset. The original achieves this with a single route definition
  covering the tab segment; whatever the mechanism, the requirement is that a tab switch is not a
  navigation the page notices.
- **Changing to a *different workspace* must remount.** The page reads its identity once. If the
  same page instance were reused across workspaces, it would keep showing the old one's data.
- **A bare URL with no tab segment is deliberate**, not a bug. It means "no tab pinned", and the
  tab row picks its own default (the first tab in the user's saved order). The page must not
  helpfully write a slug into a bare URL — that would break the "share a link to the workspace,
  not to a tab" case. An *unknown* slug, by contrast, is normalised away back to the bare URL.

The shell around the content is a standard page frame with three states: a pending line while the
workspace loads, an error line if it fails, and otherwise a header plus the content.

The header is minimal, and this is a finding rather than a design: it shows the **workspace
identifier** as the title, and underneath it the **branch name**, plus "forked from {parent}" when
a parent exists. That is all. No status, no container state, no daemon version, no ahead/behind,
no clean/dirty. See section 7 — this is the single biggest thing I would change.

### The activity bar (sticky, above the tabs)

A single horizontal row of buttons, one per workspace **in this repository** that currently has a
live coding-agent session. It sticks to the top of the content as you scroll, and it spans the
full content width. When no workspace in the repository has agent activity, the row collapses to
nothing — not an empty strip, actually nothing.

Each button shows a coloured dot, the workspace's branch name (falling back to the workspace id),
and a hidden-but-announced state label. The four states and their treatment:

| State | Label | Dot |
|---|---|---|
| Busy | "Cooking…" | accent, pulsing |
| Waiting | "Waiting on you" | amber |
| Idle | "Idle" | muted |
| Ended | "Ended" | dimmer muted |

**Ordering is the whole point of this bar**, and it is the subtlest decision on the page. Buttons
are sorted by *when that workspace's activity last changed*, most recent first — not by name, not
by state. A session that has just stopped bubbles to the far left, because stopping is its most
recent change. That is exactly the workspace that needs your next prompt. Ties break by
identifier so the order is stable.

Two consequences the implementer must reproduce:

- The "last changed" timestamps are **client-side memory**, not a server field. The client watches
  the workspace list and records the moment each workspace's activity value changed. This memory
  must live *above* the page, at application scope, so it survives navigating from one workspace to
  another. If it were page-scoped, the bar would re-shuffle to an arbitrary order every time you
  clicked one of its own buttons.
- A button **persists while its session is stopped or waiting**, and drops off only when activity
  clears entirely (ended and reaped, or the container stopped). The bar is a "who needs me"
  queue, not a liveness indicator.

Clicking a button opens that workspace's **Chat tab** directly.

The same bar is reused on the repository and project screens (with an optional prefix naming the
repository, since several stack there). On the detail view it also highlights the currently open
workspace. That reuse is worth preserving: it is the product's one cross-workspace "what needs me"
affordance.

### The tab row

Everything else on the page is one tab row. This was a deliberate consolidation: an earlier design
had a tab group *plus* an always-visible panel *plus* a header button opening a dialog *plus* a
floating button opening another dialog — four idioms. They were collapsed into one. Rebuild the
consolidated version; do not reintroduce dialogs for these surfaces.

Properties of the tab row itself:

- **Hidden tabs stay mounted.** This is not an optimisation, it is the contract the rest of the
  page is built on. The chat's websocket, the framed app's iframe, the file browser's open file,
  the half-finished sketch, and every scroll position survive tab switches because the panels are
  merely hidden, never destroyed. Several features (deep-linking into the file browser from
  another tab, for one) only work because of it.
- **Tabs are drag-reorderable, and the order persists per browser.** Stored locally, not on the
  server: tab order is per-device ergonomics, deliberately unlike the prompt draft (section 4),
  which is work product and lives on the server. A stored order that does not mention a tab (a tab
  added since) must degrade gracefully by appending, not by breaking.
- **Reordering moves only the tab buttons, never the panels.** Moving a panel in the document
  would reload its iframe and reset its scroll — the very thing keep-mounted exists to prevent.
- **Tab labels can carry a status dot** with a tooltip. Three tones: accent ("something wants your
  attention"), success ("something is running, healthily"), warning ("something failed or is
  restarting"). The dots are how the consolidation stayed honest: when the always-visible services
  panel became a tab, its at-a-glance status had to move somewhere, and it moved onto the label.
- **A tab can pin itself to the front**, ahead of the saved order. Exactly one tab uses this: the
  transient process tab below.

The tabs, in their default order:

1. **Starting** — transient, present only while a technical process runs. Pinned first, auto-selected.
2. **Chat** — the agent conversation. Primary.
3. **Files** — the workspace's working tree. Primary.
4. **Sketch** — a drawing canvas that attaches to the prompt. Secondary/experimental.
5. **Services** — the workspace's long-running processes, plus their event feed. Primary.
6. **Bootstrap** — the repository's declared setup chain and its last run. Secondary.
7. **Actions** — runnable actions plus this workspace's run history. Primary.
8. **Web view** — the running app, framed, with an element picker. Primary.
9. **Telemetry** — traces, logs, metrics from the workspace. Secondary.
10. **Agents** — the embedded agent terminal, activity, session history, plugins. Primary.

"Primary" here means: essential to the pitch, rebuild it. "Secondary" means: real and working, but
the screen still does its job without it. Section 7 sorts these into build order.

Only the Starting tab has no URL slug — it is deliberately unpinned from the URL, because it
unmounts when the process ends and a stale link to it would land nowhere.

### Tab 1 — Starting (the transient technical-process tab)

While a long technical operation runs against the workspace — a container start is the canonical
case — a tab appears at the front of the row and is selected automatically. It renders the
operation's live log as a **stack of named segments**, each an expander with a status badge
(running / ok / failed).

Behaviour that matters:

- The currently-running segment auto-expands; a settled segment collapses to its status line. A
  manual toggle by the user overrides that default for that segment, permanently.
- The expanded log body auto-scrolls to its newest line while streaming.
- On the terminal frame the stream closes, the final state freezes, and the host is told so it can
  refresh everything the operation just changed.
- The tab then **lingers for about five seconds** before unmounting, so you can read the final
  state instead of watching it vanish. This linger is a real decision: without it, a fast container
  start flashes a tab you never get to read.
- A failed segment may carry a **failure classification** and a target it applies to (for example
  "this remote needs authentication", naming which repository). The host is expected to offer the
  matching remedy. Treat these as an idempotent set — a reconnect replays them.

The same view is reused in the workspace list's "starting" dialog. Worth keeping as a shared piece.

### Tab 2 — Chat

The agent conversation, rendered in place. Two modes:

- **No session running** → the prompt composition panel (described under "the prompt panel" below).
- **A session running** → the live conversation, with a Terminate button in the tab's own header
  strip.

A session started anywhere — here, from the list, from the commands screen — is picked up here.
Launching from the composition panel swaps the panel for the conversation in place, without
navigating.

The header strip carries a permanent one-line reassurance: *"Switching tabs keeps the agent
running; come back to pick up the conversation."* Small, but it is the sentence that makes the
keep-mounted contract legible to the user. Keep it.

The conversation renders a stream of typed items: user turns, assistant text, thinking blocks,
tool calls, tool results (truncated at a few thousand characters), and system notices. Successful
completions are *not* rendered — they are redundant with the assistant's own text — but failures
are, as an error-styled system line. Sub-agent side-chains are folded into collapsible groups
anchored immediately after the tool call that spawned them; a side-chain whose anchor is missing
appends at the end.

The user's own turn is **rendered from the server's echo, not optimistically**. This is
deliberate: it guarantees that the live view and a later replay of the same conversation show the
same thing in the same order. Do not add an optimistic local bubble.

Below the message list sit rows of **picked context**: elements picked from the web view, and code
references picked in the Files tab. Each is a button that inserts that item into the message draft
(an element as a fenced block, a reference as its `path:start-end` label). Attached images appear
as thumbnail rows with a Remove control.

Pasting an image into the message box attaches it to the workspace's prompt draft instead of
pasting text, and the outgoing message gets a short appended nudge telling the agent to re-fetch
its attachments. (A text-only chat turn cannot carry an image; the attachment rows are the
delivery path.) A paste with no image falls through to a normal text paste.

### Tab 3 — Files

The largest surface on the page, and the one most worth getting right. It is a two-pane browser:
a resizable tree on the left, a read-only viewer on the right.

**The tree** is built from the workspace's tracked and new files, read from the working tree — so
uncommitted agent edits are visible. Build output and VCS internals stay out.

Five behaviours compose here, and they interact:

1. **Lazy directories.** Directories that would be large or are ignored are not listed eagerly.
   They appear as collapsed folders with their immediate-child count appended to the label
   (`node_modules (312)`), dimmed. Expanding one fetches that single level, cached per directory
   so re-expanding is instant. Content only ever enters the tree through such a directory, which
   makes "at or under a lazy directory" an exact test for "this is ignored" — no ignore-file
   parsing needed for the dimming.
2. **Path compaction.** Single-child directory chains collapse into one breadcrumb row
   (`src / main / java`). The ancestor prefix renders dimmed and slightly smaller so the final
   segment stands out. Lazy directories are compaction boundaries and never fold into a chain.
   When a filter change later splits a chain, the newly separate ancestors must already be
   expanded — the user was "inside" the chain, so re-opening there is right.
3. **A fuzzy name filter** at the top of the tree, matching on the filename. It also accepts glob
   forms (`*.ts`).
4. **An advanced filter dialog** holding an ordered rule list, evaluated top-to-bottom with
   **last match wins**, exactly like a `.gitignore`. Each rule has a match kind (exact / fuzzy /
   includes), a query, and a mode (show / hide). Rules can be reordered, disabled, and removed.
   The dialog shows a live preview of the resulting visible paths, truncated at 500 with a count.
5. **Dynamic filters** — generated rule sets, layered under the manual rules. Two kinds:
   *ignore-lists* (pick a `.gitignore`/`.dockerignore` basename; its rules are read from every
   such file in the tree, applied with locality scoping, shallow-to-deep) and *frameworks* (pick
   a detected project; its rule is a whitelist over an explicit server-resolved membership set).
   Each is expandable to show its generated rules read-only.

Rule precedence is fixed and matters: framework restrictions first (they set a default-hidden
stance), then ignore-list rules, then manual rules — so a manual "show" rule can always resurrect
a file something else hid.

**A framework quick-access footer** sits under the tree: one toggle per detected framework kind,
labelled by its short name. Toggling one narrows the tree to that framework's files; several
compose as a union. Toggling one **on** expands the tree to a framework-sensible depth (a Java
root to its source directory, an Angular root to its source directory) — but a name search or a
manual rule expands the tree *fully*, because that is a search and deep matches must be visible,
while a framework toggle is *browsing* and expanding everything would be jarring. That distinction
is a real decision; reproduce it.

When a filter is active and some lazy directories have not been opened, a footer line says so:
"N collapsed directories not searched — open to include." Without it, "no match" silently lies.

**The viewer** is read-only, syntax-highlighted, with line numbers, reading from the working tree.
Binary or oversized files are flagged rather than rendered. Some file types have a *rendered* view
(markdown and the like) with a source/rendered toggle; the rendered view is the default when one
matches, and the choice is remembered per renderer for the session. A relative link inside a
rendered view resolves to a repository path and opens it — silently doing nothing for a dead link.

**Test/code tabs.** When the opened file has detected counterparts, a small tab strip appears above
the viewer: a "Code" tab for the source plus one tab per linked test, labelled by the test's
basename minus its extension, with the full path as tooltip. Opening any member shows the identical
strip — the group is normalised through the owning source. Tests reachable this way are **hidden
from the tree** to avoid redundancy, except while name-searching, so a test can always still be
found by name.

**Line picking.** A "Pick lines" toggle arms selection mode. While armed, selecting a line range in
the viewer collects it as a **code reference**: a removable `path:start-end` chip above the viewer,
a persistent highlight painted into the viewer, a row on the Chat tab, and an entry in the prompt
draft. An excerpt of the selected lines is captured at pick time for preview. Pick mode is sticky
across picks (unlike the web view's one-shot pick) and disarms when you switch files.

**Two entry points from elsewhere**, both of which the browser must expose:

- *Open at an exact line range* — used by a service event's "open in source" and by a chat
  reference row. The path is exact; anchor it, paint the highlight, scroll to it. Note this must
  work for files that are **not in the tree** at all (a log file is usually ignored) — the content
  read is not restricted to tracked files.
- *Open the closest match to a possibly-stale path* — used by picked-element attributions, which
  can outlive renames. Seed the name filter with the path exactly as if the user had typed it
  (narrowing and expanding the tree, so the user sees *why* it is narrowed), then select the
  closest match among the filtered paths. No plausible match means the seeded filter stays and
  nothing is selected.

### Tab 4 — Sketch

A drawing canvas: pen/eraser, three colours, three stroke widths, undo, clear. A fixed logical
canvas of roughly 1024×640, scaled to fit. "Attach to prompt" exports the drawing and adds it to
the workspace's prompt draft as an image attachment, on exactly the same path a pasted screenshot
takes.

Two details that are bugs if missed: the canvas is **white-backfilled** and the export composites
onto white, because the eraser punches transparent holes that would otherwise reach the agent as
black rectangles. And undo history is capped (about 30 snapshots) by evicting the *oldest stroke*,
never the blank baseline — undo must always be able to reach a clean canvas.

The canvas survives tab switches (keep-mounted) but **does not survive a reload**. The original's
own plan says the canvas autosave belongs to the prompt-draft work and had not landed. Treat
"sketch survives reload" as unimplemented, not as a requirement you have missed.

### Tab 5 — Services

Two stacked sections.

**The services panel** lists every service declared in the repository's committed configuration —
running or not, because the convention is that everything is visible and rules do the narrowing.
Each row shows name, description, a status chip with a restart count, health-check results when
present, a Logs link into the run's audit log, and a Start or Stop button. A live service also
offers an interactive terminal attach.

Statuses are: starting, ready, restarting, crashed, stopped. Health is reported by the in-container
daemon and reads "unknown" until it does. (An earlier "degraded" status and per-line log observers
existed and were **deliberately removed** — see section 7.)

The tab label's dot aggregates: warning if anything is restarting, success if anything is starting
or ready, otherwise no dot.

**The events feed** below it shows the workspace's recent service events from a durable store,
newest first, one page of 20 — which is exactly the feed's window. Each row is a severity dot, a
time, the service name, a source chip, and a one-line summary; expanding shows the captured log
excerpt, or says none was captured. Two "open in source" affordances:

- An event anchored in a command's output links to that command's log at the anchored sequence range.
- An event anchored in a **tailed file** offers a button that switches the page to the Files tab and
  anchors that file at the event's line range. This cross-tab jump is one of the nicest things on
  the page and only works because hidden tabs stay mounted.

### Tab 6 — Bootstrap

The setup chain declared in the repository's committed configuration, in file order, numbered.
Each step shows name, description, and its last run *in this workspace*: an outcome chip, a
timestamp, a non-zero exit code when there is one, and a Logs link. A step that never ran says
"never ran". Each step has a Run button; the section header has "Run all".

While the chain is running, the header shows "Chain running…" and every Run button is disabled.
The tab label's dot is accent while the chain runs, warning when the last run of any step failed.

### Tab 7 — Actions

Two stacked sections.

**The action list** is the union of two origins: globally defined code actions, and actions declared
in the workspace's own committed configuration (read in-container). Each row shows name,
description, an origin badge (`code` / `config`), an `interactive` badge where applicable, and a
Run button.

The two origins run differently, and the difference is visible:

- **Code actions** launch through the regular command pipeline: they get a history row and can be
  re-attached. An interactive one navigates away to its terminal page; a non-interactive one
  surfaces in the run history below.
- **Config actions** run fire-and-await through the in-container daemon and show their captured
  exit code, stdout and stderr **inline**, expanded under the row, with a Hide control. They get no
  history row. Interactive config actions are listed but not runnable, and their disabled Run button
  explains why on hover.

**The run history** below lists this workspace's commands: name (or a kind label), launch time, exit
code when known, a kind badge for anything that is not a plain terminal run (chat session, service),
and a status badge. A running row offers Open and Terminate; a finished row offers an inline
expandable log.

The tab label's dot is accent when a **terminal** command is running in this workspace that is not
agent-driven — chats, services and agent runs each have their own tab's dot. The history list still
shows everything. That split is deliberate: each dot points at its owner tab.

### Tab 8 — Web view

Frames the running application through a same-origin proxy path, so the framed app and the host
page share an origin. Without a live web-viewable service it renders an empty state ("No
web-viewable service is running — start one from the Services tab") rather than a dead frame.

The iframe mounts on the tab's **first activation** and then stays mounted. Without that gate the
framed app would load eagerly on every page load even if you never open the tab. This
latch-on-first-selection pattern appears twice on the page (here and on Agents) and is worth
naming as a rule: *expensive panels initialise on first selection, then persist.*

The toolbar carries:

- A **service selector** when more than one service is web-viewable, otherwise just the name.
- A **URL bar toggle** (a globe). Opening it swaps the rest of the toolbar for an input seeded with
  the frame's *current* app-side path — read from the framed window's live location, so it tracks
  in-app navigation, not just the initial source. It offers reset-to-opened-value and a navigate
  action, validates the path, and closing discards edits without applying. Navigation is an in-frame
  location change, so the picker re-attaches through the normal load hook.
- A **pick-element toggle**. While armed, clicking an element in the framed app captures it into the
  prompt context. A plain pick is **one-shot** — it captures and disarms, so the framed app is
  usable again immediately. Shift-click (or a touch long-press) keeps picking for multi-select.
  Picking an already-picked element unpicks it.
- A count of picked items and a Clear control.

A pick captures the element's tag, a CSS selector, a text preview, and the URL. Two enrichments:
the **app-side route** (the proxy prefix stripped off, so the agent sees the route the app was on,
not the internal proxy path), and **component attribution** — the picked element is walked up to
its owning component, yielding a class name, a selector, its source files, and the ancestor chain.
The attribution map is fetched once per pick-mode activation; picks made before it resolves simply
carry no attribution. Already-picked elements keep a visible mark in the frame, kept in sync with
the store in both directions.

The picker cannot work on a foreign-origin page; when that happens the toolbar says so plainly
("picker unavailable on external pages") rather than failing silently.

### Tab 9 — Telemetry

Three sub-tabs over the workspace's in-memory telemetry buffer. Ephemeral by design — this is a
live window, not a store.

- **Traces**: a recent-errors feed at the top, then every buffered span behind a Recent / Slowest
  lens, then (when a trace is selected) that trace's flat span list with its logs. A span row shows
  time, kind, name, an ERROR marker, and duration. Selecting any row selects its trace.
- **Logs**: a tail, filterable by the exporting service. The filter options are derived from the
  services actually present in the current tail.
- **Metrics**: the latest point of every series.

One notable default: the browser's own page-load instrumentation spans are **hidden by default**,
behind a reveal toggle that counts them ("Show 42 page-load spans"). Opening the web view floods
the buffer with one span per subresource, which drowns everything worth seeing. When *only*
page-load spans exist, the empty state says so and points at the toggle rather than claiming
nothing was captured.

Sub-tabs stay mounted when hidden, same as the outer row.

### Tab 10 — Agents

Four stacked sections.

**The embedded session** is an interactive agent terminal living directly in the tab. Nothing
launches on page load — a session is expensive to materialise — so the tab latches on first
selection and then resolves, in this exact order:

1. A running interactive agent run for this workspace → **attach** to it, wherever it was started.
2. A running chat for this workspace → **defer**. Render "This workspace's conversation is live in
   the Chat tab" with a jump link. Do not launch: a concurrent resume of the same session is the
   exact collision session-pinning exists to prevent.
3. No session history at all → **launch fresh**.
4. History exists but nothing is running → **idle on an explicit choice.** Offer "Start new
   session", an agent-harness picker, and a pointer to the session list below.

Step 4 is the one that looks wrong and is right. Resuming is **never automatic**. The recorded last
session can be gone from the agent's own state (a re-materialised container, pruned volume state),
and auto-resuming a vanished id exits instantly with "no conversation found" — in a loop the user
never asked for. The original hit this and wrote it down. Do not optimise it away.

A **finished** run does not auto-relaunch either (a crashing agent would loop). The ended state
offers Resume, New session, and a link to the imported transcript. On Resume the harness picker is
shown but **disabled** — a resumed session keeps its original harness; only a fresh launch may pick.

One special case: when the agent is not signed in, the launch returns a sign-in terminal instead of
an agent session (recognisable because it has no session lineage). It is a terminal like any other,
so it renders in place; when it exits, resolution re-runs *and replays the launch the sign-in
interrupted*, so completing the login continues what you actually asked for.

**The activity section** shows the workspace's live agent state as a badge — "Cooking…" / "Waiting
on you" / "Idle" / "Ended", or "No active agent" — reported by the in-container daemon hearing the
agent's lifecycle hooks. It also carries an instance-wide checkbox toggling whether those hooks are
injected at all, with an inline save error.

**The session history** is a tree. One node per session, resumes collapsing onto the session they
continued, newest roots first. Forks nest under their origin with a stable per-lineage accent colour
so sibling branches are tellable apart. Sub-agent side-chains nest one level deeper, greyed. Each
row shows a date and a message count; the currently-live session's row is highlighted.

Each row offers **Resume** — but only while nothing owns the workspace's conversation. When a run or
chat is live the Resume buttons disappear, for the same collision reason as above. Resuming makes
the embedded terminal above attach to it.

**The plugins section** lists a curated set of language-server plugins for the coding agent, each
with an install status chip and an Install button when available. The store is global to the shared
agent home, so an install here turns the plugin green in every workspace — the copy says so.
Plugins matching the workspace's detected frameworks float to the top with a "Recommended" badge,
without hiding the rest. A failed install says what to check ("the agent must be signed in and its
container running").

The tab label's dot is accent when the agent is actively busy, success when an interactive agent is
running but idle or waiting, otherwise absent. That is an upgrade of an earlier binary
running/not-running dot into a real busy signal, and it is worth having.

### The prompt panel (inside Chat, when nothing is running)

Composition has four inputs that all feed one draft:

1. **Speech.** A Record button captures audio and transcribes it server-side, appending each
   utterance to a transcript textarea as you pause. A live input-level meter is shown while
   recording — if it stays flat while you speak, no audio is reaching the page, which is the single
   most useful diagnostic here. Uploads are serialised so the text stays in order.
2. **Refinement.** "Refine into prompt" sends the transcript to a small model that rewrites it into
   a coherent agent prompt. "Use transcript as-is" skips that step. Either promotes text into the
   editable prompt box.
3. **Picked context.** Picked elements (each showing its tag, attributed component, pick-time route,
   and source files as links that deep-link into the Files tab), code references (each with its
   excerpt preview and a deep link back to the file at those lines), and images (thumbnails). All
   removable.
4. **Typed text**, in a prompt textarea. Pasting an image here attaches it rather than pasting text.

Two launch buttons: launch as a **chat** (renders in place on this tab) or launch as a **terminal
session** (the full agent TUI).

The launch path has one rule that must not be lost: **the draft is flushed to the server
synchronously before launching, and a failed flush aborts the launch** with a visible error. The
agent fetches the composed prompt back from the server rather than receiving it inline, so a
just-typed edit still inside the autosave debounce would otherwise race the launch and the agent
would read stale or absent instructions. Failing loudly beats launching with the wrong prompt.

A restored draft announces itself: a dashed one-line hint above the panel — "Restored draft from
2h ago" — with a Discard action. It disappears on first edit. Cheap insurance against week-old
context silently riding into a launch.

## 3. Every interaction

This section is the checklist. For each control: what it does, its in-flight feedback, and its
failure mode.

**Global to the page**

| Control | Does | In flight | On failure |
|---|---|---|---|
| Tab click | Selects tab; pushes the slug into the URL | — | — |
| Tab drag | Reorders the row; persists locally | Drag preview | Silent |
| Activity-bar button | Opens that workspace's Chat tab | — | — |
| Back button | Walks back through tabs (they are pushes, not replaces) | — | — |

**Chat**

| Control | Does | In flight | On failure |
|---|---|---|---|
| Send | Sends the turn over the socket | Thinking indicator until the turn ends | Message queues; socket reconnects and flushes |
| Terminate | Ends the running session | Button spinner | Stays; list refetches |
| Insert picked item | Appends its formatted text to the draft | — | — |
| Paste image | Attaches to the draft; nudges the agent | — | Inline "may exceed the size limit" |

**Files**

| Control | Does | In flight | On failure |
|---|---|---|---|
| Tree node (file) | Opens it in the viewer | "Loading {path}…" | "Failed to load {path}" |
| Tree node (folder) | Toggles it, without stealing the selection highlight | Lazy dirs show "Loading…" | Silent |
| Name filter | Narrows and fully expands the tree | — | — |
| Filter dialog rules | Recompute the visible set live, with a preview | — | — |
| Framework toggle | Restricts to that framework; expands to a sensible depth | — | — |
| Pick lines | Arms sticky selection mode | Button reads "Picking — select line ranges" | — |
| Reference chip ✕ | Removes the reference and its highlight | — | — |
| Source/rendered toggle | Switches view mode; remembered per renderer | — | — |

**Services / Bootstrap / Actions**

| Control | Does | In flight | On failure |
|---|---|---|---|
| Start / Stop service | Starts or stops it | Button spinner | Refetches regardless (settled, not success) |
| Service logs link | Navigates to the run's audit log | — | — |
| Run all (bootstrap) | Runs the chain | Button spinner; all Run buttons disabled | Refetches regardless |
| Run step | Runs one step | Spinner **on that row only** | Refetches regardless |
| Run action (code) | Launches through the command pipeline | Spinner on that row | Mutation error surfaces |
| Run action (config) | Runs fire-and-await | Spinner on that row | Result panel expands showing the error message |
| Terminate command | Terminates it | Spinner on that row | List refetches |
| Log toggle | Expands one command's log inline | — | — |

**Web view / Agents**

| Control | Does | In flight | On failure |
|---|---|---|---|
| Pick element | Captures it; disarms (shift keeps picking) | Toggle reads "Picking — click an element" | "picker unavailable on external pages" |
| URL bar apply | Navigates the frame | — | Invalid path disables apply and shows the error |
| Start new session | Fresh launch | "Starting agent session…" | "Failed to launch" + Retry |
| Resume (ended state) | Resumes the last session | Same | Same |
| Resume (a tree row) | Resumes that session | Buttons hidden while anything runs | "Failed to resume the session." |
| Install plugin | Installs on the shared home | Spinner on that row | "Install failed. The agent must be signed in and its container running." |
| Terminate | Ends the run | Button spinner | List refetches |

**Optimistic updates.** The page is deliberately conservative. There are exactly two:

1. **Image attach/remove** patches the local image list immediately, then reconciles against a
   refetch. Attach adds the row only after the server confirms an id; remove drops it locally first
   and reconciles in a `finally`, so a failed delete is corrected by the refetch rather than lost.
2. **The prompt draft** is local-first by construction: you type, the UI is already updated, and a
   debounced save follows. A failed save leaves the draft marked dirty so the next edit retries.

Everything else — service start/stop, action runs, launches, terminates, plugin installs — waits
for the server and then refetches. Two supporting rules make that feel fast rather than sluggish:
mutations invalidate on **settled**, not on success (so a failed start still refreshes the truth),
and per-row spinners are keyed to the row actually being acted on, never to "some mutation is
pending" — otherwise one Run click spins every row.

**Launch bridging.** Both the Chat tab and the embedded agent session keep a local "I just launched
this id" value that bridges the gap between the launch returning and the command registry reporting
the new run. The bridge stops the moment the registry knows the command and reports it as not
running. Without it the panel blinks back to its empty state for a beat after every launch.

## 4. Live data and its lifecycle

This is the part most likely to be under-specified, so it is spelled out completely.

### The core decision: hint-and-refetch, not push-the-data

The page holds **one** server-sent-event channel for the workspace. It carries **payload-free topic
names** — nothing but a string per frame. Each topic maps to one or more cache invalidations, and
the data itself keeps flowing over the ordinary REST endpoints.

This replaced eight independent polls. The consequences are the reason to copy it:

- An idle workspace produces **zero** traffic. Polling has a floor; this does not.
- A dropped or missed hint **self-heals** — the next hint or the next reconnect re-fetches.
- No payload means no versioning, no partial-update merge logic, and no risk of the pushed shape
  drifting from the fetched shape.
- Nothing on the page polls. That is a rule, not a tendency: every query on this screen is
  fetch-on-signal.

### The topics

| Topic | Fired when | Refreshes |
|---|---|---|
| `services` | A service's status flips (start, ready, exit, crash, restart) | The services list |
| `service-events` | A service event row is persisted | The events feed |
| `telemetry` | Telemetry buffers got new data (highest churn) | All four telemetry views |
| `commands` | A command's lifecycle changed (started, exited, terminated) | The command list **and** the session tree |
| `bootstrap` | The chain started/ended, or a step's outcome was recorded | The bootstrap surface |
| `files` | The working tree changed on disk | The file tree, the detection, and any open file's content |
| `agent-activity` | The agent's rollup flipped (busy/idle/waiting/none) | The workspace list (feeds the activity bar and the Agents dot) |
| `process` | A technical process started or completed | The active-process lookup |
| `prompt-draft` | The draft text was saved or deleted (usually on another device) | The draft |
| `prompt-attachments` | An image attachment row was added or removed | The attachment list |
| `ping` | Every ~25s | Nothing — heartbeat, ignored |

Three modelling decisions inside that table:

- **The session tree rides the `commands` topic** rather than having its own. Transcript imports
  happen on command exit, which already fires `commands`. Fewer topics, same freshness.
- **Prompt text and prompt attachments are separate topics** on purpose. Text autosave is
  high-churn; image payloads are large. Sharing a topic would re-download every image on every
  keystroke's debounced save.
- **The `files` topic refreshes three things together** — tree, framework detection, and open file
  content — because they must agree. See "generation tokens" below.

### Debounce, heartbeat, and overflow

- Hints are debounced server-side per (workspace, topic), **leading-edge plus trailing**: the first
  hint in a quiet window emits immediately, so a service flip feels instant; further hints in the
  window coalesce into at most one trailing emit. A continuous burst converges to roughly one emit
  per second per topic — quieter than the poll it replaced, rather than chattier.
- A **~25 second heartbeat** frame keeps idle connections alive through intermediate proxies. The
  client ignores unknown topics, so the heartbeat needs no special handling.
- Server-side overflow is **dropped**, not buffered. Hints are recoverable by definition.

### Reconnect and replay

The reconnect story is deliberately trivial, and this is the single most copyable decision on the
page:

> **On every connect and every reconnect, invalidate everything once.**

There is no replay protocol, no `Last-Event-ID`, no resume token, no snapshot-then-delta. The
browser's own event-source reconnect handles the retry; the client's open handler closes whatever
gap the disconnected window left by re-fetching all topics. It costs one burst of requests on
reconnect and buys the removal of an entire class of correctness bugs.

**What the user sees during a disconnect: nothing.** There is no banner, no greyed-out state, no
"reconnecting…" indicator. The data simply stops updating and then catches up. This is a genuine
gap rather than a design choice — see section 8.

### The other three transports

The hint channel is not the only live thing on the page. Three others behave differently and each
needs its own reconnect treatment.

**1. The technical-process stream** (Starting tab) is a *payload-bearing* stream, separate from the
hint channel. The hint channel only says "a process started"; the log itself rides its own stream.
On reconnect it **resets local state and rebuilds from the server's replay** — again no diffing
protocol. On the terminal frame the client closes the source itself. If the stream closes for good
*without* a terminal frame (the process expired server-side), the view says so explicitly: "The log
stream ended before the process finished (it may have expired)." That distinct state matters —
otherwise an expired process looks identical to one still running.

**2. The chat socket** replays the whole conversation on attach, so re-attaching costs nothing and
shows the same thing as the live stream. It auto-reconnects on close after a short fixed delay
(~1.5s). Messages sent while the socket is down are **queued and flushed on open**, and a send while
closed also triggers an immediate reconnect attempt.

**3. The terminal socket** (embedded agent session, service terminals) is the most carefully tuned
piece on the page, and its rules were each learned from a real failure:

- Opening the socket **re-attaches and replays scrollback**; closing it only detaches. The process
  keeps running server-side.
- A **clean server close** (code 1000) is final — the command is gone, or the server detached
  deliberately. Print `[disconnected]` and stop.
- **Everything else reconnects**, with exponential backoff capped at 4s, five attempts. Each attempt
  resets the terminal and lets the replay repaint it. This covers two distinct real causes: the
  server closes every authenticated socket when the access token expires, and the re-handshake
  carries the session cookie so **reconnecting is the token renewal**; and ordinary network blips
  and machine sleep.
- A **spent retry budget is not the end.** It re-arms when the tab becomes visible or the browser
  comes back online. A laptop sleep outlives an 8-second backoff window, and "I'm back" is an event,
  not something to poll for.
- The terminal is keyed by command id, so a relaunch (a new id) recreates it rather than reusing a
  socket bound to a dead process.

### Fetched once, not streamed

Some things deliberately do not participate in the live channel:

- **The component attribution map** for the web view picker is fetched once per pick-mode
  activation. A map that misses a just-created component simply skips attribution until next time —
  which is fine, and much cheaper than keeping it fresh.
- **The available agent harnesses** and the activity-tracking setting are fetched once.
- **The action list** refreshes only on ordinary mutation invalidations. Definitions change rarely,
  and never from this screen.
- **The plugin registry** is a static client-side list joined with fetched install status.

### Generation tokens: the anti-flicker rule

The file tree and the framework detection are two independent fetches over the same working tree,
and the `files` topic refreshes both. If they land at different times the user briefly sees a
skewed combination — a tree from before an agent's edit with detection from after, or vice versa.

The fix, and it is worth copying verbatim in spirit: **both responses carry the same structural
generation token**, and detection is applied only while its token matches the tree currently
rendered. On a mismatch the *last consistent* detection is held rather than blanked, and the next
tick resolves it. The tokens agree on first load, so there is no initial flash.

Any pair of independently-fetched views over the same mutable tree needs this. Without it the page
flickers in a way that is very hard to diagnose after the fact.

### Shared cache entries

Several panels read the same data. The original leans hard on this: the page, the activity bar, the
agent-activity badge and the Agents dot all read one workspace-list entry; the page, the Chat tab,
the Actions history, the session tree and the embedded session all read one command-list entry; the
services panel, the tab-label dot and the web view all read one services entry; the file browser and
the plugin recommender share one detection entry.

The rule the original states repeatedly: **identical key *and* identical result shape**, or they
silently stop sharing. Whatever the new stack, keep the discipline — it is what makes ten panels on
one screen affordable.

## 5. Every state

An implementer cannot guess these. Each is listed with what the screen actually looks like.

### Page level

| State | What the screen shows |
|---|---|
| Loading | "Loading workspace…" — nothing else, no skeleton |
| Load failed | "Failed to load workspace" — no retry affordance |
| Workspace not in the list | The page renders normally, title = the identifier, **no branch subtitle**. There is no 404 state. This is a gap, not a design |
| Loaded | Header, activity bar, tab row |

### Per-panel states

Every panel follows the same three-line pattern, in muted then destructive styling: a pending
line ("Loading services…", "Loading files…", "Loading sessions…"), an error line ("Failed to load
services", "Failed to load run history"), and an empty state. The empty states are all written as
*instructions*, never as bare "no data" — copy that habit:

| Panel | Empty state copy |
|---|---|
| Files tree | "No files match." |
| Files viewer | "Select a file to view its contents." |
| Services | "No services declared in this repository's qits config (…)." |
| Service events | "No service events yet — start a service and its status changes and detected errors land here." |
| Bootstrap | "No bootstrap steps declared in this repository's qits config (…)." |
| Actions | "No actions configured — define global ones under Action Configurations or declare them in the repository's qits config (…)." |
| Run history | "Nothing has run in this workspace yet — hit Run on an action above." |
| Sessions | "No agent sessions yet — the first session starts when the tab resolves." |
| Web view | "No web-viewable service is running — start one from the Services tab." |
| Traces | "No spans captured yet — interact with the app to generate traces." |
| Traces (only page-load) | "Only page-load spans captured — reveal them above." |
| Activity bar | The host collapses entirely — no empty strip |

### Lifecycle and infrastructure states

This is where the current screen is weakest, and the reimplementation should do better.

| Condition | What the detail view does today |
|---|---|
| **Container stopped** | Nothing explicit. The header says nothing. Panels that need the container fail with their own generic error lines. The user's only clue is a wall of "Failed to load …" |
| **Container provisioning** | Only visible via the transient Starting tab, if a process is running. No header state |
| **Container failed** | Not surfaced on this screen at all. The runtime error message exists in the data and is shown only in the workspace list |
| **Daemon disconnected** | Not surfaced. Known bug: agent activity goes *stale* rather than clearing, because the disconnect evicts the cached state without firing a hint. The bar and the Agents dot keep showing "Cooking…" until something else invalidates |
| **Daemon outdated** | Not surfaced. The list view shows a warning badge and offers a recreate; the detail view shows nothing |
| **Working copy dirty/clean** | Not surfaced on this screen |
| **Ahead/behind parent** | Not surfaced on this screen |
| **Agent busy** | Surfaced well: the Agents tab dot, the activity badge, and the activity-bar dot |
| **Workspace resolved (integrated/abandoned)** | **Not handled.** The detail view has no notion of a resolved workspace. Resolved workspaces are read on a separate history screen. Opening the detail view for one is undefined behaviour |
| **Permission denied** | No distinct treatment anywhere. It renders as a generic load error |
| **Service wedged (alive but not serving)** | Reads as "ready". Health checks inform the chip but do not drive recovery. A known, documented architectural gap |

Sections 7 and 8 return to these.

## 6. The data contract the UX implies

Capabilities, not payload shapes. Each line is "this region needs to know X".

**Header** — the workspace identifier; the branch name; the parent branch name (optional). *Should
also need, but does not currently read:* container runtime state and its error text; working-copy
clean/dirty; ahead/behind counts; daemon connected-since, version, and whether it is outdated;
resolution status and result.

**Activity bar** — for every workspace in the repository: an identifier, a branch name, and a
current agent-activity state (busy / waiting / idle / ended / none). Nothing else. The ordering
timestamps are client-derived.

**Chat** — whether a chat session is running for this workspace and its identifier; a bidirectional
message stream that replays on attach; the ability to terminate by identifier. Plus everything under
"prompt draft" below.

**Files** — a listing of the working tree's tracked and new files; per-directory lazy listings with
an immediate-child count; the content of any path in the workspace (including untracked and ignored
paths, for log anchoring) with a binary flag; a structural generation token shared by the listing and
the detection. Framework detection needs: per detected project a framework identifier, a root path, a
human label, and its resolved member paths; plus a source→test link graph.

**Sketch** — nothing from the server except the attachment write path.

**Services** — per service: an identifier, name, description, status, restart count, health-check
results, an optional proxy path, an optional web-view entry path, and the identifier of the run
whose logs to show. Plus start and stop by service identifier. Service events need: timestamp,
service name, severity, a summary, an optional log excerpt, and an anchor (either a command
identifier with a sequence range, or a file path with a line range).

**Bootstrap** — the declared chain in file order (identifier, name, description); per step the last
run in this workspace (outcome, timestamp, exit code, log reference); whether the chain is running.
Plus run-chain and run-step.

**Actions** — per action: identifier, name, description, origin (code or config), whether it is
interactive, whether it is runnable. Plus launch-through-pipeline and run-inline (which must return
exit code, stdout, stderr). Run history needs: per command an identifier, a display name, a kind, a
launch time, a status, an exit code, and whether it has agent-session lineage.

**Web view** — a same-origin proxy path per live web-viewable service, plus its entry path. A
component attribution map (selector → class name, selector, source files, ancestor chain).

**Telemetry** — buffered spans (trace id, span id, name, kind, start, duration, status), grouped
recent errors, one trace's spans and logs, log records with an exporting-service name, and latest
metric points.

**Agents** — running interactive agent runs and running chats for this workspace, each with session
lineage; a session tree (session id, first-recorded time, message count, fork origin, children,
sub-agents with type/description/timestamp/count, newest command id); the available agent harnesses
and the instance default; launch with an optional resume-session id, a mode, a harness, and a
deliver-prompt flag; the workspace's current agent activity state; an instance-wide
activity-tracking setting; plugin install status on the shared agent home, plus install.

**Prompt draft** — per workspace: an opaque composition blob (client-owned schema: prompt text,
picked snippets, code references, attachment ids), a server-readable serialized prompt, a version
counter, the version last delivered to a run, and a last-updated timestamp. Read, upsert, delete.
Separately, attachment rows: identifier, mime type, label, source (sketch or paste), and bytes; list,
create, delete. The server must be able to serve the serialized prompt and the attachments to the
agent on demand.

**Technical processes** — the currently-running process identifier for this workspace, and a
payload-bearing stream of segment-open / line / segment-settled / done frames, each with a sequence
number, and settled frames optionally carrying a failure classification and a target.

**The live channel** — one subscription per workspace, emitting the topic names in section 4.

## 7. What NOT to rebuild

The brief asked for opinions. Here they are, with the evidence.

**Do not rebuild the speech capture.** Record → transcribe → refine-with-a-small-model is the
oldest thing on this page — it is literally the route's origin, and the whole screen grew around
it. Its own epic still calls the page it lives on "the legacy work-in-progress page, unlinked, kept
for prototyping". It carries a server-side speech runtime, a WAV recorder, an audio-level meter,
and a second model call, and everything it produces is *text in a textarea*. Ship the textarea.
Add speech later if anyone asks, as an input method rather than a flow.

**Do not rebuild the Sketch tab.** A drawing canvas is a charming idea, and the implementation is
careful (the white-backfill and undo-baseline details above are real bugs it fixed). But it does not
survive a reload, its persistence was deferred to work that had not landed, and the same delivery
path is already covered by pasting a screenshot — which is what people actually do. Keep **image
attachment by paste**; drop the canvas. If it comes back, it belongs behind the prompt panel, not as
a top-level tab.

**Do not rebuild the Bootstrap tab as a tab.** It is a repository-level declaration whose only
per-workspace content is "when did each step last run here". That is three lines of status, not a
tenth of the tab row. Fold it into Actions as a section, or into a workspace status area. The
evidence that it is over-promoted: it is the only tab whose *entire* content is disabled while its
one action runs.

**Do not rebuild the removed telemetry machinery.** Per-line log observers, pattern/severity-based
error detection, file log sources, and a `DEGRADED` service status all existed and were
**deliberately deleted**, because they were anchored to a host-side log-follower that the
in-container daemon architecture bypasses. Rather than re-home them, they were dropped. Do not
resurrect them by reading old screenshots. A service reports starting / ready / restarting /
crashed / stopped, plus health checks.

**Do not rebuild host-side service supervision.** The host's supervisor — launcher, liveness poll,
restart policy with backoff, straggler reaper, boot re-adoption, scheduler, and health probing —
was collapsed to a pure projection of what the in-container daemon reports. The reason is worth
knowing: double supervision meant a socket blip could put host and daemon into a port fight. The
host issues manual start/stop and projects events. Keep it that way.

**Reconsider the Telemetry tab's placement.** It is real and it works, but it is three sub-tabs of
an ephemeral in-memory buffer, and its most-used feature is a toggle that hides the noise it
generates. It is secondary. Build it after the primaries, and consider whether "recent errors" alone
— surfaced next to the services it came from — covers 90% of the value.

**Do rebuild, and improve: the header.** The detail view currently shows a workspace's name and
branch and nothing else, while the *list* view shows runtime status, runtime error, daemon
connected-since, daemon version, an outdated-daemon warning with a recreate action, clean/dirty, and
ahead/behind. The detail view is the page that *is* the workspace, and it is the one place you
cannot see its state. The screen silently assumes you arrived from the list and remember. Give the
detail view a proper status strip: runtime state, daemon health, clean/dirty, ahead/behind,
resolution status.

**Do rebuild, and improve: the lifecycle verbs.** Discard, integrate, merge, release, and the
container controls (start, stop, recreate) exist **only** on the list view. From inside a workspace
you cannot finish it. Whatever the list keeps, the detail view should at minimum offer stop/start,
recreate, and integrate/discard — the actions that end the work you are looking at.

**Keep, unreservedly:** the one-hint-channel-plus-refetch design; the invalidate-everything-on-
reconnect rule; keep-mounted hidden tabs; the activity bar's recency ordering; the
never-auto-resume rule; the flush-draft-before-launch rule; the generation-token consistency gate;
the cross-tab "open in source" jump; the empty states written as instructions.

## 8. Open questions for the user

1. **Does the detail view get the lifecycle verbs?** Discard, integrate, merge, and container
   start/stop/recreate live only on the list today. Moving or duplicating them changes what the two
   screens are for.
2. **What should a resolved workspace's detail view look like?** Today it is undefined — resolved
   work is read on a separate history screen. Is the detail view read-only for a resolved workspace,
   or does it not open at all?
3. **Should the page show a disconnect indicator?** Today a dropped live channel is invisible; data
   just stops updating. A quiet "reconnecting" marker is cheap. Is silence deliberate?
4. **How many tabs is too many?** Ten (plus one transient) is a lot for a row that also scrolls
   horizontally. Are Bootstrap and Telemetry worth their slots, or should the row be six?
5. **Is the web view's element picker in scope for the first cut?** It is the most distinctive thing
   on the screen and also the most expensive — a proxy, a same-origin frame, a DOM picker, and a
   component attribution map.
6. **Should tab order still persist per browser?** It is a nice touch that adds a stored-order
   migration concern every time a tab is added or renamed.
7. **Is speech genuinely dead, or paused?** Section 7 recommends dropping it. Confirm before the
   server-side speech runtime is designed out.

## 9. The gap list

Measured against `services/qits-workspaces` (its generated `docs/openapi.yml` plus the routes that
document deliberately omits) and `frontends/qits-spa-workspaces`. All REST paths below are prefixed
`/workspaces/api`.

### The finding that shapes the whole list

The new service has **15 documented operations**. None of them serves a file, a command, a terminal,
an agent, or a service. That looks like a catastrophic gap and mostly is not — because **the
capabilities exist inside the workspace-daemon and are reachable through an undocumented byte proxy**
at `/workspaces/container/{id}/*`. Behind that proxy the daemon serves file listing, file content,
framework detection, the component map, command launch and logs and terminate, agent launch, agent
session lists, agent plugins, prompt refinement, service start/stop, the bootstrap chain, and two
websockets (interactive terminal, agent chat).

So the honest framing is three tiers, not two:

1. **Documented host API** — typed, in the OpenAPI document, safe to generate a client from.
2. **Undocumented daemon API behind the proxy** — the capability is live and the route is stable,
   but there is *no* OpenAPI, *no* typed client, and no contract test on the client side. The proxy
   rewrites no path and injects the bearer. It deliberately does not gate on control-socket liveness,
   so file browsing and terminals survive a reconnect blip.
3. **Genuinely absent** — no endpoint and, in some cases, no domain code either.

Tier 2 is where most of the detail view lives. The backend work it implies is not "build these
features" but "**decide how the SPA is allowed to talk to the daemon**". That decision is the
single largest open item in this document, and it is architectural rather than incremental. Note
also the recorded security hole: the daemon control socket is token-free and names its caller by
path parameter, so anything on the internal network can claim to be any workspace's daemon.

Also note two hard constraints from the service's own rules: `WorkspaceServiceController` and
`WorkspaceBootstrapController` were **deleted on purpose**, with the instruction "do not add host
routes back". Any plan that re-adds host-side service or bootstrap endpoints is fighting a settled
decision, and should route through the daemon instead.

### Region by region

**Header / workspace identity** — *mostly provided.*
`GET /workspaces?repositoryId=` returns a `WorkspaceDto` carrying every field the improved header in
section 7 wants: `workspaceId`, `branch`, `parent`, `ahead`, `behind`, `conflictsWithParent`,
`status`, `runtimeStatus`, `runtimeError`, `clean`, `agentActivity`, `preamble`, `result`,
`resolvedAt`, `daemonConnectedAt`, `daemonVersion`, `daemonBuildTime`, `daemonOutdated`. The new DTO
is *richer* than what the old detail view rendered — the data was always there and the old screen
simply ignored it.

Two shape differences to plan for:

- **There is no `GET /workspaces/{id}`.** A detail screen must list-and-filter by repository. That
  is what the old screen did too (it shared one list cache entry across every panel), so it is
  survivable — but it means a detail view cannot be opened without knowing the repository, and a
  resolved workspace never appears in that list at all.
- **Identity is now a generated `Long` `id`**, and `workspaceId` is a branch-derived *label* that is
  unique only among active workspaces in one repository and is reusable after resolution. Every new
  route keys on `id`. URLs, deep links, and the activity bar must key on `id`, not the label.

*Missing:* nothing for the header itself.

**Activity bar** — *provided.*
Needs a workspace list per repository with `agentActivity`, plus the `agent-activity` SSE topic. Both
exist. The global channel `GET /events` carries `agent-activity` for the cross-repository case.
Ordering timestamps are client-derived, so nothing is needed server-side.
*Note:* the SPA's hand-written DTO declares only `IDLE | BUSY | WAITING` — **`ENDED` is missing
client-side** while the API does emit it. Fix that before building the bar, or the "Ended" state
renders as nothing.

**The live channel** — *fully provided, and it is the same design.*
`GET /workspaces/{id}/events` emits payload-free lowercase topic names with the identical vocabulary:
`services`, `service-events`, `telemetry`, `commands`, `bootstrap`, `files`, `git-status`,
`agent-activity`, `process`, `prompt-draft`, `prompt-attachments`, plus `ping`. Debounce is
leading-edge-plus-trailing at 1000 ms; heartbeat is 25 s; overflow is dropped; there is explicitly
no replay protocol and no `Last-Event-ID`. The invalidate-everything-on-reconnect rule transfers
verbatim.

The irony worth stating plainly: **five of those topics currently fire against nothing readable.**
`services`, `bootstrap`, `commands`, `prompt-draft` and `prompt-attachments` all have hint plumbing
and no host reader. The channel is ahead of the API.

One implementation gotcha recorded in the service's own rules: an SSE method returning a stream runs
on the IO thread, so any database lookup inside one must be marked blocking or it answers 500.

**Technical process / Starting tab** — *fully provided.*
`GET /workspaces/{id}/active-process` gives the discovery lookup; `GET /technical-processes/{id}/events`
gives the payload-bearing stream. The frame shape matches what section 2 describes exactly: `segment`,
`kind` (`segment-open` / `line` / `segment-settled` / `done` / `ping`), `seq`, `line`, `status`
(`ok` / `failed`), `hint`, `hintTarget`. The one documented hint value is `remote-auth`, whose
`hintTarget` is the repository to sign into — and for a submodule child that is *not* the root
repository, so the UI must act on the target it is given.

Two behaviours differ slightly and simplify the client:

- **Every reconnect replays all buffered segments and lines with fresh ordinals**, then streams live.
  Rebuilding from scratch on reconnect is not just acceptable, it is the intended contract.
- **An unknown or evicted id answers 404**, which the browser treats as fatal rather than retrying.
  That maps cleanly onto the "stream ended before the process finished" state.

`ensure-container` and `recreate-container` both return a process id, so the Starting tab has two
natural triggers.

**Container lifecycle** — *provided, and better than the old detail view.*
`ensure-container`, `stop-container`, `delete-container`, `recreate-container` all exist. Section 7
recommends surfacing these on the detail view; the API is ready.
One rule to honour in the UI: **`recreate-container` refuses with 400 unless the working tree is
provably clean** — and "unknown" (no live daemon) counts as not-clean. So a recreate button must be
disabled, with an explanation, whenever `clean` is not exactly `true`. This matters because recreate
is the remedy for `daemonOutdated`, and an outdated daemon may well be a disconnected one.

**Lifecycle verbs** — *provided.*
`discard` (with an optional markdown result), `merge` (arbitrary target, answers with conflicts
rather than throwing), `integrate` (onto the parent, requires a summary of at most 100 characters),
`release` (the one door into the default branch). Errors are structured: an `ApiError` with a
`reason` enum (`CONFLICT`, `MERGE_CONFLICT`, `NOT_FAST_FORWARD`, `ALREADY_INTEGRATED`,
`PUSH_REJECTED`, `RELEASE_REQUIRED`) and a `conflicts` path list on the two conflict reasons. A 409
with `RELEASE_REQUIRED` means "you asked to merge into the default branch; use release". The UI
should route that automatically rather than showing a raw error.

*Missing:* `fast-forward` and `update-from-parent` are **not** host routes — they live on the daemon
(`POST /fast-forward`, `POST /update-from-parent`), and were deliberately removed from the host.
There is also no conflict-listing or resolve-conflict flow.

**Files tab** — *tier 2, via the daemon.*
`GET /files`, `GET /files/content`, `GET /detection` and `GET /component-map` all exist on the
daemon and are reachable through the container proxy. That covers the tree, lazy directory levels,
file content with a binary flag, framework detection with membership sets and the source→test link
graph, and the web view's component attribution.
*What needs verifying rather than building:* whether the daemon's `/files` response carries the
**generation token** the anti-flicker rule in section 4 depends on, and whether `/files/content` will
read paths outside the tracked set (the log-anchoring case).
*Missing at the host:* no typed client, no OpenAPI, no contract test. Also no changed-files list, no
per-file status, and no diff of any kind — the entire diff surface is the raw `output` string and
`conflicts` path array that a merge returns. A "review the change" affordance would be new work.

**Chat and the agent session** — *tier 2, via the daemon.*
`POST /agents` (launch), `GET /agents/available`, `GET /agent-sessions`, `GET`/`POST /agent-plugins`,
`POST /agent-plugins/{id}/install`, plus the two websockets `WS /terminal/commands/{id}` and
`WS /chat/commands/{id}`. That is the entire Agents tab and the entire Chat tab, minus the prompt
draft.
*Verify:* whether the launch accepts a resume-session id, a launch mode, a harness selection and a
deliver-prompt flag — the four parameters the resolution order in section 2 depends on. Whether
`agent-sessions` returns the nested tree (forks, sub-agents) or a flat list. Whether the chat socket
replays on attach, which the whole "switch tabs freely" contract rests on.
*Missing:* the instance-wide agent-activity-tracking setting has no home in this service.

**The prompt draft** — *domain code exists, no controller. This is the clearest backend gap.*
`WorkspacePromptDraftService`, `WorkspacePromptDraftDto`, a `WorkspacePromptDraft` entity and the
`workspace_prompt_draft` table all exist. So do the attachment equivalents, including a
`workspace_prompt_attachment` table and a 64 MB body limit configured specifically for the uploads.
The SSE topics `prompt-draft` and `prompt-attachments` already fire. **Only the REST controllers are
missing.**

Needed: read, upsert and delete for the draft (an opaque composition blob plus a server-readable
serialized prompt, a version counter, a last-delivered version, and a timestamp); list, create and
delete for attachment rows. Plus — and this is the part that is easy to forget — **the agent must be
able to fetch the serialized prompt and the attachments back**, because the launch path delivers by
fetch, not by push. Without that, the flush-before-launch rule in section 3 has nothing to flush to.

This is small, well-specified work with the schema already in place. It should be first.

**Services tab** — *split.*
The events feed is **provided**: `GET /service-events` with paging (default 50, max 500), and filters
for repository, severity, since, source and workspace label. The DTO carries everything section 6
asks for, including the command-or-file anchor fields, so both "open in source" affordances work.
The services *panel* is tier 2: `GET /services`, `POST /services/{name}/start`,
`POST /services/{name}/signal` on the daemon. The host controller was deleted on purpose.
*Note:* `ServiceEventKind` currently has exactly one value, `STATUS_CHANGED` — consistent with the
removal of log observers described in section 7. Do not build UI expecting more kinds.

**Bootstrap tab** — *tier 2, with an orphaned host table.*
`GET /bootstrap-commands`, `POST /bootstrap-commands/run` and `POST /bootstrap-commands/{name}/run`
exist on the daemon. The host has a `workspace_bootstrap_run` table and a `BootstrapRunService` that,
in the service's own words, "now has no reader". Given section 7 recommends demoting Bootstrap from
a tab to a section, the cheapest path is to read it from the daemon and leave the host table alone.

**Actions tab** — *tier 2, partially.*
`GET /commands/actions` (the action list), `GET`/`POST /commands`, `GET /commands/{id}`,
`GET /commands/{id}/log`, `POST /commands/{id}/terminate` all exist on the daemon. That is the whole
tab.
*Missing at the host:* there is no live command list. `WorkspaceCommandHistory` is an optional port
and commands are readable host-side **only** through `history/{id}`, for a workspace that has already
been resolved. So the run history of a *live* workspace must come from the daemon — which means it
disappears when the container is stopped. That is a real behavioural difference from the old screen
and worth an explicit decision.

**Web view** — *tier 1 route, tier 2 data.*
The reverse proxy exists: `/workspaces/service/{id}/{serviceId}/*`, baked into the public base the
container is told about. The component map comes from the daemon. What is missing is the *list* of
web-viewable services with their proxy paths and entry paths — `ServiceInstanceDto` and `WebViewDto`
exist in the domain but no controller exposes them, so this rides on whatever answer the Services
question gets.

**Telemetry tab** — *absent from this service by design.*
`telemetry` is an SSE topic here, but there is no telemetry read endpoint: the hint points at
qits-observability. Rebuilding the Telemetry tab means a cross-service read, exactly as the CI/CD
explorer plan describes for browser-side cross-service calls behind the gateway session. Since
section 7 rates Telemetry secondary, this is a good candidate to defer.

**Sketch and speech** — *absent, and section 7 recommends not building either.*
No image-attachment endpoint beyond the prompt-attachment work above; no speech transcription
anywhere in the service; the daemon does offer `POST /prompt-refinements`, so the *refine* half of
the old flow survives even though the *record* half does not. That is a neat outcome: keep
refinement as a button on a textarea, drop the microphone.

**Resolved workspaces** — *provided, on a separate surface.*
`GET /history`, `GET /history/{id}` (with events and commands), and `PATCH /history/{id}` to amend
the narrative. This is where open question 2 lands: resolved workspaces are simply not in the active
list, so the detail view cannot currently open one at all.

### The front end's own gap

The SPA is a list view and nothing else. It has two routes, one real screen, and calls **3 of the 15
documented endpoints** (`workspaces`, `release`, `integrate`). It consumes **no SSE at all**, has no
detail route, and no container lifecycle controls.

`@qits/ui-components` at 0.0.4 exports **four components**: a button, a badge, a card, and the main
layout. For this screen that means the following do not exist and must be built: **tabs** (the
organising principle of the entire page), a **tree**, a **split/resizable pane**, a **code viewer
with line numbers, highlighting and range selection**, a **terminal**, a **dialog** (for the filter
rules), **form controls** of any kind (input, select, textarea, checkbox), a **spinner**, a
**tooltip**, and an **icon set**. `Async`, `Empty` and `Loadable` are duplicated per SPA on purpose
and should be reused that way rather than promoted.

The tab component alone is a meaningful piece of work, because the requirements in section 2 are not
the usual ones: hidden panels must stay mounted, reordering must move only the buttons, labels carry
status dots, and one tab pins itself to the front.

### Headline: how much backend work is implied

Less than the endpoint count suggests, and the shape is unusual.

- **Genuinely new backend work is small and well-defined**: the prompt-draft and prompt-attachment
  controllers over schema that already exists, plus a way for the agent to fetch them back. That is
  the only "build a feature" item on the list.
- **The large item is architectural, not incremental**: deciding how the browser reaches the
  workspace-daemon. Roughly forty capabilities — every file, every command, every terminal, the
  entire agent surface, services, bootstrap — sit behind an undocumented, untyped byte proxy today.
  The options are to publish a contract for the proxied daemon API, to re-front the needed slices as
  host routes (which collides with a settled "do not add host routes back" decision for services and
  bootstrap), or to let the SPA call the proxy directly with a hand-written client. That choice
  determines the shape of the whole implementation and should be made before any tab is built.
- **Smaller, definite gaps**: no single-workspace read; no branch listing; no changed-files or diff
  surface; no live command list host-side; no agent-activity-tracking setting; telemetry lives in
  another service; the SPA's activity enum is missing `ENDED`.
- **The live-data layer needs nothing.** Both hint channels and the process stream already exist with
  the same semantics, the same debounce, the same heartbeat, and the same deliberate absence of a
  replay protocol. Five topics currently fire against readers that do not exist yet — which is a
  gap that closes itself as the readers land.

The realistic sequencing: settle the daemon-access question, build the tab shell and the prompt-draft
controllers in parallel, then Chat and Files, then Agents, then Services and Actions, and treat
Telemetry, Bootstrap-as-a-tab, and Sketch as explicitly deferred.
