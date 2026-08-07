# qits-idp implementation plan

Self-built identity provider. No Keycloak — an external user store would force
linked realms or duplicate accounts once we use the users for anything.

## Settled decisions

- **Name and path:** `services/qits-idp`, served under `/idp`.
- **Order:** SYSTEM (machine) auth first, USER auth second. Nothing is in prod,
  so there is no migration concern.
- **User auth is unchanged in shape.** The gateway keeps terminating sessions
  (`quarkus-oidc` hybrid) and forwarding `X-Qits-User` / `X-Qits-User-Id`;
  services keep trusting those headers. qits-idp becomes the auth server the
  gateway points at. JWTs are machine identity only.
- **Agents are dynamic clients.** ci-daemon and workspace-daemon get real OIDC
  clients registered at the idp by their spawning service. This replaces
  qits-ci's in-memory per-launch secret (`CiDaemonRegistry`) — that scheme
  couples agents to the service process and a qits-ci restart invalidates
  running daemons, which was never desired. It goes away in phase 2.
- **Claims over scopes:** `aud` = target service, plus structured claims
  (`project`, `workspace`, `branch`). Enforcement lives in the resource
  services, helped by a shared lib.
- **Bootstrap:** a hardcoded single-use invite token (`qitsqits`) seeds the
  first (admin) user. Invite tokens are consumed on use, so a static default
  is safe enough for now.
- **Persistence:** H2-file datasource `idp`, Flyway — the existing pattern.
  Centralizing persistence is a separate pre-prod effort, not this plan.
- **Shared code** goes into `libs/qits-integrations-quarkus`
  (currently an empty stub).

## Phase 1 — issuer core, service-to-service auth

1. **New submodule** `services/qits-idp` (seed remote, `--name`, `ignore=all`,
   `update=merge`, per CLAUDE.md). Quarkus service, H2 + Flyway.
2. **Issuer core:**
   - Signing keypair generated on first start, stored in H2 so validation
     survives restarts. Tokens carry a `kid` from day one so rotation is
     possible later without a flag day.
   - JWKS endpoint, OIDC discovery document, token endpoint supporting
     `client_credentials` (built on `smallrye-jwt-build`).
3. **Static clients** for the long-lived services (qits-ci, qits-cd,
   qits-artifacts, qits-workspaces, ...), seeded from config. Each carries its
   granting authority for phase 2 (see below).
4. **Shared auth module** in `qits-integrations-quarkus`:
   - Move the `ForwardAuthMechanism` / `ForwardAuthIdentityProvider` pair that
     is currently copy-pasted into all 8 services.
   - Claim-name constants and enforcement helpers ("token `project` claim must
     match this path param").
   - Config presets for bearer validation against qits-idp (issuer, JWKS URL,
     audience).
5. **Services validate:** add `quarkus-oidc` bearer auth beside forward-auth.
   Replace the static schemes:
   - `X-CI-Token` on `/ci/api/events/*` → bearer with matching `project` claim.
   - `X-Artifacts-Token` on artifacts admin writes → bearer.
   - The unauthenticated qits-ci → qits-cd `build-succeeded` call → bearer
     (`aud=qits-cd`), obtained via `quarkus-oidc-client` in qits-ci.
6. **qits-local-up.sh** gains the qits-idp container. Services get its internal
   URL for JWKS/token fetches — they reach the idp directly on qits-net, not
   through the gateway.

## Phase 2 — dynamic clients for agents

7. **Registration API** on the idp, callable only with a service bearer token:
   - `POST /idp/api/clients` with the claims the new client's tokens will
     carry, an `aud` list, and a lease TTL. Returns `client_id` + secret.
   - `DELETE /idp/api/clients/{id}` deregisters. Expired leases are GC'd, so
     orphaned agents lose access without cleanup code on the registrar side.
   - **Granting authority:** a registrar may only mint clients within its own
     scope template — qits-ci grants `{project: *}`, qits-workspaces grants
     `{workspace: *, branch: *}`. The template sits on the registrar's static
     client record; the idp rejects anything outside it.
8. **qits-ci:** on step launch, register a client scoped to the run's project;
   inject `client_id`/secret as env (replacing `QITS_CI_DAEMON_SECRET`);
   deregister on teardown. The daemon fetches its own tokens via
   `client_credentials` and presents a bearer on the control-socket handshake.
   Remove `CiDaemonRegistry` secret minting — a qits-ci restart no longer
   kills running daemons.
9. **qits-workspaces:** same for workspace-daemon. Retires the shared
   `QITS_WORKSPACE_DAEMON_API_TOKEN` and the credential-free dial-home socket
   (the workspace id in the path stops being the credential). The daemon's
   token is scoped `{workspace, branch}`.
10. **qits-artifacts:** `ProtectedRefHook` accepts a branch-scoped bearer
    (via the existing `git push -o qits.token=` channel) instead of the static
    push-token, enforcing "workspace-agent pushes only to its own branch".

## Phase 3 — users

11. **Schema:** users, invite tokens (single-use, creator, expiry). Initial
    invite token seeded from config (default `qitsqits`); the first
    registration through it creates the admin.
12. **Registration:** page + API at `/idp/register`, consumes an invite token.
13. **Login:** authorization-code + PKCE, login page, idp session cookie,
    refresh, logout, userinfo.
14. **Gateway cutover:** point `QUARKUS_OIDC_AUTH_SERVER_URL` (+ client id and
    secret) at qits-idp; add the idp's browser-facing paths to `PublicPaths`.
    Issuer topology: the issuer string is the public URL; the gateway's
    backchannel calls and the services' JWKS fetches go direct on qits-net
    with the issuer configured explicitly.
15. **Invite generation:** authenticated users create invite tokens through
    the idp (surface in a frontend later; API first).
16. **local-up:** optionally switch the gateway build from the `local` variant
    to `oauth` against the local idp once the flow is stable.

## Cross-cutting

- **Token lifetimes:** short for agents (minutes); `quarkus-oidc-client`
  handles caching and refresh. Allow modest clock skew in validation.
- **Availability:** services cache JWKS and issued tokens, so an idp restart
  only pauses new-token issuance, never validation. Keys persist in H2.
- **Audit:** log client registration/deregistration, token issuance failures,
  and invite consumption.
- **Enforcement stays server-side:** the idp states identity and claims;
  each resource service decides what a claim permits, using the shared lib's
  helpers.
