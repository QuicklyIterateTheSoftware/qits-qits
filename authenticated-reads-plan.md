# Authenticated reads via commissioned credentials

Status: PLANNED, opened 2026-08-14; REVISED the same day after the user
corrected the credential model — the first draft distributed one durable
client secret into every pull point, and that is exactly what this platform
must not do. Successor to the unify-ingress campaign, which shipped
method-scoped auth (writes gated, reads anonymous) and left the escape
hatch: `qits.edge.auth.anonymous-read-apps=registry,mirror`.

**Goal: that list becomes empty** — every read through edge authenticates
(docker pulls, `FROM` pulls inside builds, maven/npm resolution, mirror
reads) — **and the credentials doing it are commissioned per dynamic
context, not stored anywhere durable.**

## The credential model (the heart of this plan)

A service that provisions a dynamic context commissions a credential FOR
THAT CONTEXT from qits-idp, and decommissions it when the context ends.
The credential's lifetime IS the context's lifetime — no TTL, no refresh,
no stored secret outliving the thing it authenticates:

| Owner | Context | Commissioned at | Decommissioned at |
|---|---|---|---|
| qits-ci | one build run | run accepted / step launch | run finished — any outcome, boot-sweep-settled included |
| qits-workspaces | one workspace | container ensure | workspace removed / integrated / released / discarded |
| qits-projects | one agent container | container ensure | container removal |
| the operator | one workstation | by hand (a printed one-liner) | by hand, when the machine is retired |

Mechanically a commissioned credential is a **dynamic idp client** (id +
secret row in idp's store): docker's existing Bearer dance through edge's
`/token` works with it unchanged, decommission is deleting the row, and
edge's offline JWT validation stays intact — a deleted client simply can
mint no further tokens.

**The pair is what lives long, tokens stay disposable.** A workspace that
runs for days holds the id+secret, and tokens are re-minted underneath it
transparently (docker per operation, edge's Basic acceptance per request)
— so context lifetime never depends on token lifetime, and no
recommissioning is needed. The token TTL surfaces in exactly two places:
the post-decommission grace (a token minted just before revocation lives
out its clock), and any consumer wired with a bare minted token instead
of the pair. Decision (user, 2026-08-14): **raise idp's token TTL to ~1
hour for now** so the bare-token class is out of scope, and defer
recommissioning/refresh thinking to its own day. Named trade, accepted:
the raise widens the post-decommission grace to that same hour — a
revoked context's last token keeps working until it expires. Revisit the
TTL together with permission scoping.

**Full access now, scoping later.** A commissioned client gets the same
audiences a service client gets today. Per-context permissions (ci may
publish, a refinement container may not) are a declared follow-up on the
same rows — out of scope here, but the commission API should carry an
owner + context-kind + context-id triple from day one so scoping has
something to attach to.

**Static identities stay only where the identity is genuinely static**: the
platform services themselves. The deployer and qits-containers pull as
THEMSELVES (each gets an ordinary service client — the deployer has none
today), not via commissioned contexts: their pulls are steady-state
operation, and a `--with-registry-auth` credential embedded in a swarm
service spec must not be one a finished build already revoked.

**Migration note:** today's shipped static step credential
(`qits.ci.registry-auth.client-id/secret` = the dev-qits-artifacts secret,
added 2026-08-14 for pushes) is an interim exactly of the kind
[[no-speculative-security-schemes]] warns about. This plan RETIRES it: the
commissioned per-run pair replaces it for pushes first, then carries the
read flip.

## What the model does not change (still needed from the first draft)

- **Edge accepts Basic on protected requests** by brokering
  client_credentials to idp with a short positive cache. Maven, npm, git
  and curl cannot do docker's token dance; with this adapter they present
  the commissioned id+secret directly. Broker gets retry patience (the
  idp-redeploy race burned a run on 2026-08-14) and the anonymous-push
  hang fix rides along.
- **BuildKit secret mounts.** The commissioned secret still must enter
  `docker build` without touching a layer:
  `RUN --mount=type=secret,id=qits-maven,env=…` + `<server>` entries in
  `.qits-maven-settings.xml` reading `${env.…}`; recipes pass `--secret`.
  Build args remain forbidden for secrets — the legacy builder records
  them in image history and the images are pullable. So the
  legacy-builder exit is a hard precondition.
- **Committed files stay credential-free.** Per-user host files
  (`~/.docker/config.json`, `~/.m2/settings.xml`, `~/.npmrc`) hold the
  workstation's commissioned pair; never a project `.npmrc` env-expansion
  line (breaks CI when unset).

## Work packages

- **WP0 — verify.** Legacy-builder remnants per repo (build images,
  node-docker-base state); maven answering edge's 401 with Basic; npm
  `_auth` against a path-prefixed registry; `--with-registry-auth`
  beside `--no-resolve-image`; where each owner service already has the
  lifecycle hook pairs (ci run settle paths incl. the boot sweep;
  workspaces resolution verbs; projects container removal).
- **WP-IDP — the commission API.** `POST /idp/clients/dynamic` (returns
  id+secret, records owner/context-kind/context-id) and its DELETE,
  gated by the existing machine-token machinery (a new idp audience for
  callers). List-by-owner for reconciliation. Rows in idp's PG store.
  Also the TTL raise: token lifetime → ~1h (see the credential model),
  as a config knob so it can shrink again later.
- **WP-EDGE — Basic acceptance + broker cache + patience** (see above).
- **WP-BUILDKIT — finish the legacy-builder exit** fleet-wide.
- **WP-CI — commission per run.** Launcher commissions at docker-step
  launch, materializes DOCKER_CONFIG + the maven build secret from the
  commissioned pair, decommissions on every settle path — and a boot/
  periodic reconcile decommissions orphans (list-by-owner vs live runs;
  crashes must not leak clients). Retire the static registry-auth keys
  (code, extras, ComposeTemplate) in the same arc.
- **WP-WS / WP-PROJECTS — lifecycle hooks.** Commission at ensure,
  inject into the container (the daemons' own pulls/pushes), decommission
  on the resolution verbs / removal; reconcile against active rows.
- **WP-SVC — service identities for the pullers.** New idp clients for
  qits-deployments and qits-containers; DOCKER_CONFIG homes on their
  config volumes; deployer adds `--with-registry-auth` and stops
  classifying `pull access denied` as IMAGE_MISSING.
- **WP-BOOTSTRAP.** ComposeTemplate emits the new clients and drops the
  static ci pair; seed phases unaffected (loopback, pre-edge); summary
  prints the operator's commission one-liner; the anonymous-read flip in
  the template lands LAST with the boot-order proof.
- **WP-FLIP — gated like a port drop.** Live: empty the env, redeploy
  edge, prove in order — anonymous pull DENIED, a commissioned build
  (push + in-build maven read), a deploy, a workspace launch + its
  decommission observed in idp, host dev loop with a workstation pair.
  Then a from-zero rebootstrap. Rollback is the flag back to
  `registry,mirror` — one env value.

## What blocks what

    WP0 ─ WP-IDP ─┬─ WP-CI ──────────────┐
                  ├─ WP-WS / WP-PROJECTS ┤
    WP-EDGE ──────┤                      │
    WP-BUILDKIT ──┴─ (secret mounts) ────┤
    WP-SVC ──────────────────────────────┤
    WP-BOOTSTRAP ────────────────────────┤
                                         ▼
                    WP-FLIP (live, gated) ─ rebootstrap proof

Most of it ships inert before the flip (commissioning can replace the
static push credential while reads are still anonymous), so the campaign
lands incrementally through normal releases.

## Risks and accepted costs

- **Leaked clients on crashes** — answered structurally by the per-owner
  reconcile, not by TTLs; idp's list-by-owner makes orphans visible.
- **Decommission lag ≤ token TTL** (~1h after the TTL raise) — a revoked
  context's last token dies on its own clock. Shrink the TTL back when
  refresh/recommissioning gets designed.
- idp joins the read path at broker-cache granularity; patience + cache
  bound the coupling. The break-glass port bypasses edge and stays the
  anonymous recovery.
- The env vhost (browser traffic) remains the qits-idp-plan phase 2/3
  track; per-context permission scoping is the declared follow-up on the
  dynamic-client rows.
