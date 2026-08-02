# qits-idp phase 1 — cross-workstream contract

Pinned interface for the phase 1 workstreams (see qits-idp-plan.md). If your
implementation must diverge, update this file in the same commit and say why.

## Repo and module layout

- Submodule: path `services/qits-idp`, name `qits-idp`,
  url `https://github.com/QuicklyIterateTheSoftware/qits-idp.git` (seeded, main
  at 4e422f8). Add per the CLAUDE.md ritual: `--name`, `ignore=all`,
  `update=merge`, branch `main`.
- Maven: groupId `eu.wohlben.qits`. Service mirrors the qits-cd layout
  (parent + domain module `idp` + `service` module). Named H2 datasource
  `idp`, Flyway at `classpath:db/idp/migration`.
- Shared lib: `eu.wohlben.qits:qits-auth-core`, a module inside
  `integrations/qits-integrations-quarkus`. Services consume it the same way
  qits-ci consumes `libs/qits-eventstream` (nested submodule + reactor
  module). The lib's README documents the exact adoption steps.

## Endpoints (paths served under /idp)

- `GET /idp/.well-known/openid-configuration` — discovery document.
- `GET /idp/jwks` — public signing keys.
- `POST /idp/token` — `application/x-www-form-urlencoded`,
  `grant_type=client_credentials`. Client auth: `client_secret_basic` or
  `client_secret_post`. Optional `audience` param; must be within the
  client's allowed audiences (default: all of them).
- Phase 2 (schema may anticipate, endpoint not built yet):
  `POST/DELETE /idp/api/clients`.

## Tokens

- RS256, `kid` header, key generated on first start and persisted in H2 —
  validation must survive an idp restart.
- `iss` = configured issuer (`qits.idp.issuer`; local default
  `http://qits-idp:8080/idp`). `sub` = client_id. `aud` = target service
  id(s). `exp` default 300 s (configurable).
- Structured claims only when granted to the client: `project`, `workspace`,
  `branch`. No scope strings.
- **The wildcard.** A claim value of `*` (`QitsClaims.ANY`) satisfies any
  required value for that claim. Token-side only — a service asking about the
  literal target `*` gets plain equality, so no caller can widen its own check.
  Per-claim, not per-token: `project=*` says nothing about `workspace`. An
  absent claim is a mismatch, never a wildcard.
- Client ids for static clients = service names: `qits-ci`, `qits-cd`,
  `qits-artifacts`, `qits-workspaces`, `qits-gateway`. Secrets, allowed
  audiences, and claim grants come from idp config (env-overridable).

## Consumers

- Validate with `quarkus-oidc` (bearer-only) against the issuer + JWKS;
  keep the existing forward-auth mechanism for user traffic beside it.
- Obtain tokens with `quarkus-oidc-client`.
- Claim names and enforcement helpers come from `qits-auth-core` — do not
  hand-roll claim checks in services.
- Rollout gate: machine-token enforcement must be config-gated with one
  uniform key (owned by qits-auth-core) so a service can deploy before the
  idp exists. Gate off = endpoint behaves as today (network trust), never a
  half-enforced state.
- **The OIDC tenant follows that gate**, in all three services:

      quarkus.oidc.tenant-enabled=${qits.auth.machine.required:false}

  Gate off, there is no tenant — nothing fetches a JWKS, nothing waits on a
  host named qits-idp, and a clone-alone `./mvnw verify` needs no issuer. There
  is no third state: validation and enforcement are one switch. A gate-on test
  therefore also enables the tenant, so it must either reach a real issuer or
  set `quarkus.oidc.public-key` with `auth-server-url` cleared and
  `token.issuer` stated (qits-cd's and qits-artifacts' profiles do the latter).
- **Outbound is two more switches, independent of the gate**:
  `quarkus.oidc-client.client-enabled` (shipped `false`) and that client's
  secret, always set together — a client enabled without a secret refuses to
  boot. Independent on purpose: either end of a hop can turn on first, so a
  deployment can have senders sending before receivers demand. Enabling only
  the receiver's gate is the silent failure — fire-and-forget POSTs answer 401
  and no side logs a reason.

## Phase 1 behavior changes per service

- qits-ci: writes under `/ci/api/events/*` require bearer `aud=qits-ci`
  whose `project` claim matches the event's **repoId**; `X-CI-Token`
  (CiTokenFilter) is removed. Outbound build-succeeded notify to qits-cd
  sends a bearer (`aud=qits-cd`) via oidc-client.

  The claim is named `project` but matched against a repository id, because
  qits-ci has no project concept by design — no entity, no lookup, no
  qits-projects client — and the repoId is the finest thing it can honestly
  assert. The full argument is in `CiEventController`'s javadoc. Consequence
  for grants: qits-artifacts holds `project=*` (it hosts every repository),
  and a narrower-than-`*` grant must spell **repository ids**, not project
  names.
- qits-cd: `/cd/api/events/build-succeeded` requires bearer `aud=qits-cd`.
- qits-artifacts: JAX-RS admin writes (repositories, store, gc,
  mirror-upstreams) require bearer `aud=qits-artifacts`; `X-Artifacts-Token`
  (ArtifactsTokenFilter) is removed. `/artifacts/git/*` and `/v2/*` are
  unchanged in phase 1.

## Phase 2 seams

Known and deliberately left alone in phase 1.

- **Mechanism ordering under `%dev`/`%test`.** qits-auth-core ships
  `qits.auth.forward.dev-user=dev` for both profiles, and
  `ForwardAuthMechanism` answers every request without an `X-Qits-User` header
  with that synthetic identity — before bearer auth is asked. So under those
  profiles a machine token is never looked at, and every gate-on test blanks
  `qits.auth.forward.dev-user` to exercise one. Production is unaffected: no
  dev user, forward auth abstains, the bearer is judged. The fix belongs in the
  lib — order the mechanisms, or make forward auth abstain when an
  `Authorization: Bearer` header is present. Until it lands, every new gate-on
  test carries the blanking override.

## Working rules for all workstreams

- Work in the worktree `/home/wohlben/code/qits-qits-idp` (superproject
  branch `qits-idp`; submodules are on their own `main`).
- Commit on each submodule's `main`. Push only `qits-idp`; do NOT push
  qits-ci, qits-cd, qits-artifacts, or qits-integrations-quarkus — deploy
  order matters and the push is coordinated later.
- **Push order, when that coordination happens:**
  `integrations/qits-integrations-quarkus` **first**. The three services carry
  it as a nested gitlink at `81ed0cf`, and every one of those gitlinks dangles
  — a fresh clone cannot `submodule update --init` — until that commit is on
  its remote. Then the services, in any order.
- Tests must pass via `./mvnw verify -Dquarkus.http.test-port=0` (port 8081
  is taken on this host).
- Plain Language in comments and commit messages; match surrounding code
  style.
