# User authentication: register, login, and edge-terminated sessions

The platform gets real users. An operator registers the first account with a
one-time token minted at bootstrap, logs in with a passkey (WebAuthn) or an
optional password, and from then on **every request that is not `/idp/login`,
`/idp/register` or their machinery is refused at the edge unless it carries a
valid credential**. The edge turns a valid browser session into the
`X-Qits-User` / `X-Qits-User-Id` headers the services already trust.

Status 2026-08-14: PLANNED. Nothing below is implemented.

## What already exists, and what this plan moves

Measured against the code, not assumed (explorations 2026-08-14):

- **The identity-header contract is live.** The gateway strips inbound
  `X-Qits-*` by prefix and injects `X-Qits-User` (username) and
  `X-Qits-User-Id` (subject) from its own session
  (`qits-gateway/.../security/`, `EdgeHeaders.java`). Five services carry a
  `ForwardAuthMechanism` that reads them (events, observability, projects,
  stt, workspaces; artifacts and deployments reference the key in config).
  Nothing about the downstream half changes.
- **The gateway's session is quarkus-oidc `hybrid`** (`q_session` cookie,
  code flow) pointed at an auth server that was never deployed; the dev
  pipelines therefore build the `local` NO-AUTH variant
  (`--build-arg QITS_VARIANT=local`), which authenticates every request as
  user `local`. This is the machinery this plan retires.
- **The edge gates machine credentials only.** App vhosts (registry, mirror,
  githost) demand Bearer/Basic; the environment vhost — all browser traffic —
  is deliberately open (`qits.edge.auth.enforce-on-environments=false`).
  `EdgeHeaders` there injects nothing and strips nothing beyond
  `X-Forwarded-*` set-if-absent.
- **idp already stores credentials hashed with a scheme prefix**
  (`ClientSecret`, `sha-256:`) and already has the commission API guarded by
  the caller's own Basic pair. The store is PostgreSQL, migrations V1/V2.
- **`qits-idp-plan.md` phase 3 is superseded by this document.** That sketch
  kept session termination in the gateway (authorization-code + PKCE). The
  edge is the single ingress now and terminates machine auth already; user
  sessions terminate there too, and the first-party UI needs no OAuth dance
  against its own idp. Remove `qits-idp-plan.md` when this plan lands
  (phases 1 and 2 are delivered; the removal commit carries the verdict).

## Settled decisions

- **The user row is minimal**: `id` (uuid), `username` (unique). No email, no
  display name, no roles. The first user is "the admin" only in the sense
  that there is exactly one user; an authorization model is a later plan.
- **Passwordless by default.** Registration runs the WebAuthn ceremony
  (`quarkus-security-webauthn`, in the 3.34.6 BOM, webauthn4j-based) so a
  Bitwarden-style authenticator can hold the key. A user may additionally set
  a password — the fallback for automated tests and for the one browsing
  route without a secure context (see the warts). The only password rule is
  non-empty — no length or complexity limits, deliberately.
- **Users are per-deployment.** Accounts are never shared or migrated across
  deployments; a re-bootstrap or a domain move starts from the register
  token again. This is what makes the passkey's rp-id binding a non-issue.
- **Passwords hash with bcrypt**, stored `bcrypt:`-prefixed beside the
  existing `sha-256:` scheme. The SHA-256 argument ("guessing a generated
  256-bit secret is hopeless either way") does not cover a human-chosen
  password, and the `ClientSecret` prefix exists exactly so a second scheme
  can land beside the first.
- **Sessions are idp rows, cookies are opaque.** The `qits-session` cookie
  carries a random 256-bit value; idp stores its SHA-256 fingerprint. The
  edge introspects at idp and caches — the same shape as its Basic-credential
  cache, and the DB stays the single truth, so logout and revocation are row
  updates, not cryptography. (The alternative — a JWT cookie the edge
  verifies offline against the JWKS it already holds — costs revocation and
  wins only idp-outage tolerance, which the cache grace below buys back.)
- **The register token is a row, minted through an API, printed by the
  bootstrap.** One-time use. Static clients may mint; dynamic clients may
  not (the commissioning rule, reused). No log-line token: idp logs ship to
  qits-observability, and a credential must not ride the log plane.
- **The anonymous carve-out at the edge is `/idp/*` wholesale.** The login
  and register pages need their SPA assets, the OIDC protocol endpoints
  authenticate their own callers, and `/idp/api/*` guards itself (Basic
  today, session tomorrow). One prefix, no asset-path list to drift.
- **Machine credentials keep working everywhere.** A Bearer or Basic that
  passes today's `EdgeAuth` passes on the environment vhost too — CI dialing
  through the gateway, git pushes, curl with the workstation pair. The
  session cookie is a third acceptable credential, not a replacement.

## The flows

**Register** (`/idp/register`): the page asks for the register token and a
username. Passkey path: fetch creation options
(`POST /idp/api/auth/register-options` with token + username — the token is
checked before any ceremony state is created), run
`navigator.credentials.create`, post the attestation
(`POST /idp/api/auth/register`). idp verifies token-unused + attestation,
then in one transaction: create user, store credential, consume the token,
create a session. Response sets the cookie; the page moves on. Password
path: the same register call accepts `password` instead of an attestation
(token still required). Setting the *other* factor later happens
session-authenticated (`POST /idp/api/auth/password`,
`.../register-options` + `.../register` without a token when a session is
present — which is also how a second authenticator is added).

**Login** (`/idp/login`): username first. Passkey: fetch assertion options
(`POST /idp/api/auth/login-options`), run `navigator.credentials.get`, post
the assertion (`POST /idp/api/auth/login`). Password: one
`POST /idp/api/auth/login` with `{username, password}`. Success creates a
session row and sets the cookie; the page honors a `redirect` query param
(same-origin paths only). Failures are uniform 401s — no
username-exists oracle beyond what WebAuthn options inherently leak.

**Logout**: `POST /idp/api/auth/logout` revokes the row and clears the
cookie. The edge cache TTL bounds how long a revoked session lingers.

**A gated request** (edge, environment vhost, feature flag on):

1. Strip every inbound `X-Qits-*` header. Always, before anything else —
   nothing a client sends under that prefix may survive the hop.
2. A Bearer/Basic machine credential → today's `EdgeAuth` path, proxied
   (no identity headers; machine identity stays in the token).
3. A `qits-session` cookie → introspect (cached by fingerprint), inject
   `X-Qits-User` + `X-Qits-User-Id`, proxy.
4. Path starts with `/idp/` → proxy anonymously (headers already stripped).
5. Otherwise: a navigation (`Sec-Fetch-Mode: navigate`, or GET accepting
   `text/html`) → 302 to `/idp/login?redirect=<path>`; anything else → 401.

**Cookie attributes**: `qits-session`, HttpOnly, `Path=/`, `SameSite=Lax`,
`Secure` when the request (or `X-Forwarded-Proto`) says https, host-only —
no `Domain`. Browser surfaces live on one host; the vhosts are machine
planes with their own credentials. Absolute TTL `PT12H`
(`qits.idp.session-ttl`); sliding renewal is an open question, not a
blocker. CSRF posture: `SameSite=Lax` keeps the cookie off cross-site
POSTs, and the state-changing idp endpoints take JSON bodies, which a
cross-site form cannot send.

## Schema (idp `V3__users.sql`)

    idp_user            id uuid pk, username varchar unique not null,
                        password_hash varchar null ("bcrypt:..."),
                        created_at
    idp_register_token  id uuid pk, token_hash varchar unique not null
                        ("sha-256:..."), minted_by varchar not null (client id),
                        created_at, consumed_at null, created_user_id null
    idp_webauthn_credential
                        credential_id varchar pk (base64url),
                        user_id fk not null, public_key + counter + the
                        fields quarkus-security-webauthn's
                        WebAuthnCredentialRecord needs, created_at
    idp_session         id uuid pk, token_hash varchar unique not null,
                        user_id fk not null, created_at, expires_at not null,
                        revoked_at null

All four are `CausedRow`/`@Uncaused` per the arch rules, like V1/V2's tables.
Exact WebAuthn columns are fixed by the extension's record type — read the
extension source at implementation time, do not improvise them.

## New idp surface

| Route | Guard | Purpose |
|---|---|---|
| `POST /idp/api/auth/register-options` | register token (or session) | WebAuthn creation options |
| `POST /idp/api/auth/register` | register token (or session) | attestation or password → user + session |
| `POST /idp/api/auth/login-options` | anonymous | WebAuthn assertion options |
| `POST /idp/api/auth/login` | anonymous | assertion or password → session |
| `POST /idp/api/auth/logout` | session | revoke + clear |
| `POST /idp/api/auth/password` | session | set/replace the password |
| `POST /idp/api/sessions/introspect` | Basic, static client | `{userId, username, expiresAt}` or 404-shaped refusal |
| `POST /idp/api/register-tokens` | Basic, static client | mint; refused for dynamic clients |

`/api/auth` and `/api/sessions` sit under the existing `/api` prefix, so the
Quinoa ignore list does not change. The built-in extension endpoints
(`/q/webauthn/*`) stay disabled; idp calls `WebAuthnSecurity`
programmatically and issues its own session — the extension's own login
cookie never appears.

WebAuthn config: `quarkus.webauthn.relying-party.id` and `.origins` come
from env (`QITS_IDP_WEBAUTHN_RP_ID`, `..._ORIGINS`); the dev default is
`localhost` / `http://localhost:8080`.

## Edge mechanics (new, beside `EdgeAuth`)

New config group `qits.edge.sessions.*`: `enabled` (default **false** — the
rollout flag), `cookie-name` (`qits-session`), `login-path` (`/idp/login`),
`anonymous-prefixes` (`/idp/`), `cache-ttl-ms`, `cache-size`,
`stale-grace-ms`. Introspection dials idp with the edge's own static client
(`{env}-qits-edge`, new) using the existing bounded-dial shape
(`idpCallTimeoutMs` / retry window / connection-classed retries —
`IdpGrants` is the model). The cache is `EdgeAuth`'s bounded access-ordered
LRU keyed by cookie fingerprint, value `(userId, username, expiresAtMillis)`;
refusals are not cached; within `stale-grace-ms` a cached entry outlives an
unreachable idp (the token-broker-dies-during-idp-redeploy lesson — a
browser session must not 401 because idp is mid-cutover).

The strip-then-inject lives in `EdgeHeaders` for both the ordinary and the
WebSocket-upgrade path (the upgrade path bypasses the interceptor chain —
the gateway's `applyToUpgrade` is the precedent). Stripping happens whenever
`sessions.enabled`, injection only on a validated session.

## Work packages

Every WP lands dark behind the flag; suites green before anything flips.

- **WP-IDP** (`services/qits-platform-idp`): V3 migration, entities +
  repositories, `quarkus-security-webauthn` + `quarkus-elytron-security-common`
  (BcryptUtil), the eight routes, register-token mint rule (static clients
  only), session TTL config. Tests: `@QuarkusTest` flows with
  `quarkus-test-security-webauthn`'s ceremony emulation, packaged-IT
  additions (register → login → introspect round trip — the JCA/reflection
  class of native loss, same reasoning as the existing IT).
- **WP-SPA** (`frontends/qits-platform-spa-idp`): the register and login
  pages become real — token input, username, `navigator.credentials`
  ceremony (small hand-rolled base64url util, no new dependency), password
  fallback UI, redirect handling, and a visible notice when
  `window.isSecureContext` is false (see the wart below).
- **WP-EDGE** (`services/qits-platform-edge`): the session gate, cache,
  redirect/401 shaping, `X-Qits-*` hygiene, `{env}-qits-edge` credential
  config. Tests extend `StubGateways` with an introspection stub and follow
  the existing `EdgeRoutingTest` patterns (cache-hit counters, idp-down
  holds, header-spoof refusal).
- **WP-GATEWAY** (`services/qits-gateway`): a third build variant `edge`
  beside `oauth`/`local` (enforcer regex updated): trust the *inbound*
  `X-Qits-User(-Id)` as the identity source — record `AssertedIdentity` from
  the headers, keep the strip-then-reinject exactly where it is, keep
  `AuthMeRoute` answering from the same source so spa-home's header still
  works, and permit-all in `QitsAuthPolicy` (the edge already refused
  anonymous traffic). The oauth variant and its quarkus-oidc block retire in
  a follow-up once `edge` is proven — not in this wave.
- **WP-BOOT** (`cli/qits-cli-bootstrap`): seed the `{env}-qits-edge` client
  secret (the existing `IDP_SECRET_*` pattern), mint one register token via
  the API after idp is healthy and print it in the closing report beside the
  workstation one-liner, pass the webauthn RP env to idp, and carry the flip
  values (`qits.edge.sessions.enabled`, gateway variant) pinned OFF/`local`
  until the proof.

## Rollout order, and why it is an order

1. Release WP-IDP + WP-SPA. Prove register and login against the live dev
   platform with the flag off: mint a token by hand, register, log in, see
   the cookie, introspect with the edge client pair by hand.
2. Release WP-EDGE + WP-BOOT, flip `qits.edge.sessions.enabled` on dev.
   The gateway still runs `local`, so browsing works the moment a session
   exists; anonymous browsing now 302s to `/idp/login`. Prove: gated 302,
   login round trip, machine credentials still pass, git/docker/npm flows
   unaffected (they ride app vhosts or carry Bearer/Basic).
3. Flip the dev pipelines' gateway build to `QITS_VARIANT=edge` and release.
   Downstream services now see real usernames in `X-Qits-User`. Prove: a
   projects/workspaces write audits the logged-in username, a spoofed
   `X-Qits-User` from the outside is stripped, `/api/auth/me` answers the
   session's user.

Order matters both ways: flipping the gateway to `edge` before the edge
injects headers would turn every request anonymous and 401 the platform;
flipping the edge first is safe because `local` ignores the new headers.

## Warts and constraints, named now

- **WebAuthn needs a secure context, and localhost IS one.** `localhost`,
  `*.localhost`, and loopback addresses count as secure contexts over plain
  http, so passkeys work on `http://localhost:8080` with no TLS. The one
  route without a secure context is a raw IP — `http://<wsl-ip>:8080`,
  today's Windows-browser path to this platform — where
  `navigator.credentials` does not exist and only the password fallback
  logs in. The SPA says this on the page (`window.isSecureContext`)
  instead of letting the ceremony fail cryptically. TLS via `QITS_DOMAIN`,
  or Windows reaching localhost again, dissolves it.
- **The RP id pins the host, which costs nothing here.** A passkey
  registered under rp id `localhost` does not assert under a real domain —
  but users are per-deployment by decision, so a domain move re-registers
  from the register token anyway.
- **qits-net remains the trusted plane.** A process on qits-net can dial a
  service directly and write `X-Qits-User` itself; the header is trustworthy
  only because the network is. That is today's stance for every service
  credential and does not get worse here; per-hop verification is the same
  future work it always was.
- **Session revocation lags by the edge cache TTL** (seconds, configurable).
  Stated so nobody files it as a bug.
- **The dev deployment keeps one intentional bypass**: the deployer's health
  gate and service-to-service dials run on qits-net and never cross the
  edge, so nothing about deploys or internal calls changes.

## Open questions (not blockers)

- Sliding session renewal vs. the fixed `PT12H`; "remember me".
- Roles / authorization: `qits.auth.required-role` exists at the gateway but
  the user row carries no roles — a later plan, together with per-context
  permission scoping on dynamic clients.
- Invite tokens for user #2 (the same table minted by a session-authenticated
  user — API exists in shape, UX undecided) and an account page (list/remove
  authenticators, sessions).
- Session-authenticated admin reads for the SPA's clients/users pages (the
  clients listing is owner-Basic today; the users page lands with WP-IDP's
  store but its listing API is deliberately not in this plan).
- OIDC authorization-code flow for third-party apps — nothing first-party
  needs it; the issuer core is ready if it ever comes.
