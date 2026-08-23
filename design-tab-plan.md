# Design tab (frozen HTML designs) — shipped 2026-08-23, follow-ups

Status: **LIVE on wohlben.eu** (qits-projects 2026.823.153819 + follow; qits-spa-projects
2026.823.154424 / 2026.823.160313). Browser-proven on the `ui-overhaul` refinement (id 3):
freeze → design → MCP proposal → Keep / Replace / Discard.

## Shape (contracts)

- Rows: `refinement_design` (qits-projects `projects` DB, V5), keyed by the refinement row,
  cascade on discard. `status` ACTIVE | PROPOSED, `based_on_design_id`, `note`,
  `source_route`, `html`, `html_bytes`, `truncated`, `created_by`.
- REST `/projects/api/refinements/{id}/designs` — GET list (no html), POST `{title, html,
  sourceRoute?, truncated}` → 201, GET `/{designId}` (html), PUT `/{designId}` `{title}`,
  POST `/{designId}/resolve` `{mode: REPLACE|KEEP}`, DELETE. 413 over
  `qits.projects.refinement-design-max-bytes` (4 MiB). **No text/html content route** —
  agent-authored HTML is only ever rendered by the SPA in `<iframe sandbox="allow-same-origin"
  srcdoc>` (no scripts).
- SSE topic `designs` on the refinement channel.
- MCP (`repository` server): `list_designs(epicId)`, `get_design(epicId, designId)`,
  `propose_design(epicId, title, html, note, basedOnDesignId?)` → always PROPOSED; no accept
  verb; `propose_design` hidden from read-only runs.
- SPA: `refining/design/*` — `document-freeze.ts` is the THIRD copy of the platform
  style-freeze (qits-integrations-angular `document-freeze.ts`, webui `style-freeze.ts`);
  `freeze.ts` wraps it with `<base href>` and lifts picker marks; Freeze button on the Web view
  toolbar; tab `design` after `sketch`.

## Follow-ups (not started)

- Designs cascade with a refinement discard, like sketches. Promote/export a design to the epic
  if they should outlive it.
- Hoist `document-freeze.ts` into `@qits/ui-components` so three copies become one.
- Agent token cost: a frozen SPA page is ~450 kB of inline-styled HTML. Scoped reads
  (`get_design` by CSS selector) or a list projection without `html` when lists grow.
- HTML editor / diff view between current and proposed; gallery thumbnails; embedding a design
  in the epic markdown.
- The Web view's "Home" link frames `/`, which the edge answers with a JSON blob — the design of
  that page is a `<pre>`; pick a real UI before freezing (web view concern, not design's).
- `claude-verify` — a password-only admin account registered on wohlben.eu for this browser
  check (password `/root/qits/claude-verify.pw`, 0600). Delete the idp user row when not wanted.
