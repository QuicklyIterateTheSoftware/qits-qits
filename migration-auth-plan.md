# Authentication: terminate at the gateway

Status: **landed** (Parts 1–4). Written and implemented 2026-07-27.
Settles [`migration-plan.md`](migration-plan.md) §4 (`auth/*`, unassigned) and §9 item 4, and
supersedes the `qits-gateway` epic's Part 4 wording on auth variants.

**The decision in one line:** `qits-gateway` performs authentication for every human request,
injects the resulting identity as request headers, and every other component consumes that header
instead of authenticating anything.

This is the third of the migration documents. [`migration-plan.md`](migration-plan.md) maps
**files**, [`migration-api-map.md`](migration-api-map.md) maps **entrypoints**, and this one maps
**who decides whether a request is allowed**.

---

## 1. Why this exists

`auth/` is the last unassigned block in the split: **33 tracked files** with no target, parked in
`migration-manifests/unassigned.txt`. The reason they were parked is worth restating, because it is
what this plan deletes rather than solves.

The monolith picks an auth scheme at **build time** — `-Dqits.variant={local,forwardauth,oidc}`
swaps a module onto the classpath, and `service` fails augmentation if no variant is present. That
mechanism does not survive a per-service split: seven services would each need the variant matrix,
each need the swap wired into its own build, and each be independently mis-buildable.

`libs/qits-auth` was the obvious answer and is the wrong one — it makes seven copies of the problem
share a jar without making the problem smaller.

Terminating at the gateway makes the variant question **single-instance**. One component chooses a
scheme; the rest have no scheme to choose.

> §4 of `migration-plan.md` said 34 files. The tracked count is **33**; corrected when this landed.

## 2. The model

```
   browser ─────▶ qits-gateway ──────────────▶ qits-projects   ─┐
                  · authenticates              qits-workspaces  │  no auth mechanism
                  · authorizes (role)          qits-artifacts   ├─ identity from header only
                  · strips X-Qits-*            qits-observability│  anonymous ⇒ no name, not "deny"
                  · injects X-Qits-User        qits-ci, qits-stt┘
                                    ▲
   workspace container ─────────────┘  (bypasses the gateway on qits-net — §7)
```

Three roles, and nothing holds two of them:

| Component | Authenticates | Authorizes | Materializes identity |
|---|---|---|---|
| `qits-gateway` | **yes** — the only place a login happens | **yes** — `qits.auth.required-role` | emits the header |
| every `services/*` | no | no | **yes** — header ⇒ `SecurityIdentity` |
| `qits-workspace-daemon` | its own bearer token (§7) | no | no — it has no user concept |
| workspace containers | n/a — they are callers, not callees | n/a | n/a |

The services keep **`SecurityIdentity` as the API** they read. What changes is only what produces
it: today the monolith's variant mechanism, after this a 115-line header reader. Every consumer
(`EpicsPrincipal`, any future one) is unchanged.

## 3. What is actually true today

Load-bearing, because two of these make the migration cheaper than it looks:

1. **No extracted service carries any auth at all.** `QitsAuthPolicy`, `PublicPaths` and every
   variant module exist only in `../qits`. Nothing has to be removed from a service — only added.
2. **`qits-projects` reads an identity that can never be non-anonymous.** It declares
   `quarkus-security` and injects `SecurityIdentity` into four epics controllers, but ships no
   authentication mechanism, so `EpicsPrincipal.changedBy()` returns `null` on every call. The
   `changed_by` audit column has been silently unwritten since extraction. **This plan fixes an
   existing bug rather than risking a new one.**
3. **The gateway authenticated nothing**, by documented intent — its README's "Security posture"
   said so, and `WorkspaceApi`'s javadoc *cited that sentence* as the reason the daemon token
   exists. Both went stale together, and both were updated (§9). The daemon token stays: its
   attackers are peer workspaces already inside `qits-net`, which never traverse the front door.
4. **Static tokens are unrelated to any of this.** `qits.ci.token`, `qits.artifacts.token` and the
   daemon's `api-token` guard specific machine-to-machine paths, not user sessions. They survive
   untouched.
5. **Four of six services are not reachable through their own segment** (see the ⚠ section of
   `migration-api-map.md`). Edge auth over a route that carries no traffic proves nothing — see §8
   Part 0.

## 4. The header contract

### 4.1 The invariant

> **Any header a service trusts must be unconditionally stripped from every inbound request.**

Get this wrong once and the whole design is an open door: `curl -H 'X-Qits-User: admin'` against the
public port would be a complete bypass, forwarded verbatim by a gateway that has no reason to
suspect it.

`EdgeHeaders` already strips an **enumerated** list (`Remote-User`, `Remote-Groups`,
`X-Auth-Request-*`, …). Enumeration is the wrong shape here, because the failure mode is *adding a
trusted header and forgetting to extend the list* — a silent, additive mistake with no test that
naturally catches it.

**Use a reserved prefix instead.** Every gateway-asserted header is `X-Qits-*`, and the strip rule
is `startsWith("X-Qits-")`. It is then structurally impossible to introduce a trusted header that is
not stripped: the same prefix does both jobs. The existing enumerated `Remote-*` / `X-Auth-Request-*`
list stays as-is for compatibility with a deployment that still fronts the gateway.

### 4.2 The headers

| Header | Value | Consumed by |
|---|---|---|
| `X-Qits-User` | the principal name (`preferred_username` today) | `SecurityIdentity.getPrincipal().getName()` |
| `X-Qits-User-Id` | stable subject id | an identity attribute; nothing reads it yet |

**The principal stays the *name*, not the id.** `EpicsPrincipal` writes it into `changed_by`, and
the monolith's rows already hold usernames. Making the id the principal would leave that column
holding two incompatible kinds of value with nothing to tell them apart.

`X-Qits-User-Id` is emitted from the start even though nothing reads it — adding a header later
means re-testing the strip rule; carrying it now costs nothing.

### 4.3 Roles stay at the gateway

`qits.auth.required-role` is the only authorization the system has, and it is a single global check.
The gateway performs it; **no groups header is emitted.** That is one fewer trusted header, and it
keeps "terminate entirely" literally true.

If a service ever needs a per-resource role decision, that is a new design (scoped tokens — see the
`qits-tokens` feature idea), not an extension of this one.

## 5. Build targets, not configuration

The unauthenticated build must remain reachable for testing and must remain **impossible to switch
on by accident**.

- **`local` is a `qits-gateway` build target**, selected the way the monolith does it — a build
  property, never a runtime config key, so no env var and no properties file can turn a production
  gateway open. The monolith's own `auth/local` config file carries the warning verbatim: *"only
  `-Dqits.variant=local` produces an open build."*
- **Services have no variant at all.** They always trust the header and never authenticate. A
  service alone is, by construction, unauthenticated — its safety is the gateway's and the network's
  property, never its own.
- That is a real improvement on today: **one** build target to get wrong instead of a per-service
  matrix of seven.
- A `local` gateway synthesizes a fixed identity and emits the same `X-Qits-*` headers, so the
  downstream path is byte-identical in every target. Test and production differ in one component.

## 6. Disposition of the 33 `auth/` files

As landed — 9 to the gateway, 3 duplicated per service, 21 monolith-only. The manifests carry the
same split (`gateway.txt`, `duplicated.txt`, `monolith-only.txt`), and `assign.py` classifies it so
a regeneration reproduces it.

| Monolith file | Goes to | Note |
|---|---|---|
| `auth/oidc` — `NonNavigationRequestChecker`, its config | **`qits-gateway`** | the login itself; the config folded into `application.properties` |
| `auth/core` — `QitsAuthPolicy`, `PublicPaths` (+ `PublicPathsTest`) | **`qits-gateway`** | the global gate and the token-free allowlist; the policy dropped its root-path stripping, which is inert at a front door |
| `auth/core` — `AuthController` (`/api/auth/me`) | **`qits-gateway`** | as a raw Vert.x route, not JAX-RS — the gateway has no REST layer |
| `auth/local` — both mechanism classes, its config | **`qits-gateway`** | becomes the `local` build target of §5 |
| `auth/forwardauth` — 2 classes + config | **every `services/*`** | ~115 lines; header name is config, and the roles half is dropped on arrival (§4.3) |
| every `pom.xml`, the `package-info`, every variant suite (21) | **monolith-only** | they exist to serve `-Dqits.variant`, the mechanism this deletes rather than moves |

`auth/forwardauth`'s `%dev` / `%test` `dev-user` fallback is what keeps every service's suite
runnable with no auth setup — the property that makes this cheap. It is `LaunchMode`-guarded, so a
`NORMAL` build ignores it even if the env leaks in.

The two classes went into **each service's own package** (`eu.wohlben.qits.<root>.security`) rather
than the monolith's shared one: six copies of a single package would become a split package the
moment something puts two services on one classpath.

**Duplicate `forwardauth` per service; do not create `libs/qits-auth`.** 115 lines across six repos
is cheaper than a shared jar in a build model where every repo must build from a clone of itself
alone. Revisit under `migration-plan.md` §9 item 5 (`libs/qits-commons`) if a second thing ever
wants to travel with it.

## 7. What does not change

Named explicitly, because "auth moves to the edge" reads like it subsumes these and it does not:

- **`PublicPaths` moves, it does not disappear.** Container callers (`/git`, `/api/otel`, `/mcp`,
  `/api/workspace-daemon`, `/api/ci/events`, `/api/capture`) hold no user token by construction.
  Wherever the gateway sits in their path it must not demand an identity.
- **The daemon's bearer token stays.** It is *peer* authentication on a shared network whose peers
  are other workspaces running untrusted code — not user auth. Deleting it makes every workspace's
  working tree readable by every other workspace's agent. See `WorkspaceApi`'s security javadoc.
- **`SameOriginUpgradeCheck` stays.** It is CSWSH protection, not authentication. Cookie-based edge
  sessions are precisely the case it defends: a cross-origin page can open a `ws://` carrying the
  user's cookie. It must live at the gateway or in the services — it may not be swept up as "auth".
- **The static tokens stay** — `qits.ci.token`, `qits.artifacts.token` (§3 item 4).

## 8. Staging

### Part 0 — Prerequisites (not this plan's work, but gating)

Neither is auth work; both make auth work meaningful. **Both are still open** — Parts 1–3 landed
without them, which is why the seam is tested on each side and unproven in the middle.

- **Segment/path mismatch** — four of six services cannot be reached through their own segment.
  Until that is decided (services adopt the prefix / gateway rewrites / enum changes), edge auth
  gates an empty pipe. `migration-api-map.md`, ⚠ section. It also leaves `PublicPaths` correct only
  for the monolith-relative paths the `/` catch-all carries: when a service starts serving
  `/observability/otel/v1/…` rather than `/api/otel/v1/…`, that list has to grow the
  segment-prefixed form with it. Flagged in its javadoc rather than guessed at.
- **No service is a deployable** — and this is broader than written. It is not only
  `qits-workspaces`: every `service/` module in all six repos is a library JAR
  (`quarkus-maven-plugin` only in `pluginManagement`, no `src/main/resources/application.properties`
  anywhere). `@QuarkusTest` boots each module, so Part 2 is genuinely tested — but no service can be
  *started*, so Part 3's stated "done when" (an authenticated request writing `changed_by` through
  the gateway into `qits-projects`) **cannot be demonstrated by any amount of auth work**. Whatever
  packages each service as a process is where that proof belongs. `migration-plan.md` §9 item 7 has
  been corrected to say all six.

### Part 1 — The header contract *(gateway; no behavior change)* ✅

Prefix-based stripping in `EdgeHeaders` + `GatewayConfig`, before anything asserts a header. Lands
first and alone, so the strip rule is proven while nothing yet depends on it.

- `X-Qits-*` dropped from every inbound request, unconditionally, ahead of the existing enumerated list.
- `RouteTableTest`-style unit coverage on the prefix predicate; `GatewayRoutingTest` asserts a
  client-supplied `X-Qits-User` never reaches the stub upstream.
- README "Security posture" gains the reserved-prefix rule.

**Done when** an inbound `X-Qits-User` provably cannot reach an upstream. **Done** — and the
test was checked against a deliberately disabled strip, so it is known to detect the bypass
rather than merely to pass.

### Part 2 — Identity consumption *(services; no behavior change)* ✅

Add `auth/forwardauth` to each service, pointed at `X-Qits-User`. Nothing emits the header yet, so
every service still sees anonymous — identical to today's behavior (§3 item 2).

- Per service: `quarkus-security` (only `qits-projects` has it), the two `forwardauth` classes, the
  variant config with `%dev`/`%test` `dev-user`.
- `qits-projects` gets the regression test that has been missing: a request with the header writes
  `changed_by`; one without writes null.

**Done when** each service resolves a principal from the header in its own suite. **Done**, all
six. Two departures from the text above, both deliberate:

- The classes live in each service's **own** package (`eu.wohlben.qits.<root>.security`), not
  the monolith's shared one. Six copies of one package would become a split package the moment
  a packaging module puts two services on a classpath, which every repo's conventions forbid.
- `ForwardAuthIdentityProvider`'s **roles are dropped**, not merely unwired. §4.3 emits no
  groups header and no service makes a role decision, so a roles field here would be a security
  control that decides nothing. Each copy's javadoc says so, to stop the next reader restoring
  it for symmetry with the monolith.

`qits-projects`' regression is `EpicsAuditIdentityTest`, and it deliberately does **not** use
`@TestSecurity` — that annotation bypasses the mechanism entirely and is precisely what hid the
unwritten `changed_by` for the whole period this repo shipped no mechanism at all.

### Part 3 — Edge authentication *(gateway; the behavior change)* ✅

The login moves in. This is the only part users notice.

- `auth/oidc` + `auth/core`'s policy into the gateway; `/api/auth/me` as a raw route.
- The gateway asserts `X-Qits-User` / `X-Qits-User-Id` after authenticating.
- `qits.auth.required-role` enforced at the gateway.
- The `local` build target (§5).

**Done when** an unauthenticated request to the public port is challenged, and an authenticated
one writes the right `changed_by` through the gateway into `qits-projects`.

**Half done, and the half that is missing is not auth work.** Challenged: yes — 302 into the
login for a navigation, 499 for a background transport, 403 for an authenticated caller without
`qits.auth.required-role`, and an authenticated request arrives at the stub upstream carrying
`X-Qits-User`, with a simultaneously-spoofed header provably losing to it. The `changed_by`
half **cannot be demonstrated at all** until some service is a runnable process (Part 0). Every
piece is tested on both sides of the seam; the seam itself is not.

Two things the packaged artifact taught that reasoning had not:

- A `local` build whose OIDC extension was merely bean-conditioned **refuses to start**, because
  quarkus-oidc treats a missing `auth-server-url` as fatal rather than as "not needed". The
  variant profile disables the extension; the test profile does the same, or it would exercise a
  target that does not ship.
- §5's claim that no runtime config can open a production gateway is now **verified rather than
  argued**: an `oauth` artifact run with `QITS_AUTH_VARIANT=local` in its environment still
  reports `oauth`, still has nobody logged in, and still challenges.

### Part 4 — Decommission ✅

- `auth/*` is out of `unassigned.txt`, split 9 / 3 / 21 across `gateway.txt`, `duplicated.txt` and
  `monolith-only.txt`. `assign.py` classifies them so a regeneration produces the same answer;
  926/926 still classified, nothing unclassified.
- `gateway.txt` has no `.paths` file on purpose: the nine files were **adapted**, not replayed
  (`AuthController` → a raw route, `QitsAuthPolicy` minus its root-path stripping, two config files
  folded into `application.properties`). A `filter-repo` list would have promised a history replay
  that did not happen.
- The stale statements in §9 are updated.
- The monolith keeps its copies — `migration-plan.md` §1's invariant is unchanged.

## 9. Documents this made wrong

Each was load-bearing somewhere, and each was updated in the change that invalidated it.

| Document | Said | Now says | |
|---|---|---|---|
| `qits-gateway/README.md` "Security posture" | "No authentication of its own, yet" | it is the only thing that authenticates; gained an **Authentication** section and the measured native-image cost | ✅ |
| `qits-gateway/AGENTS.md` | strip list is for a *fronted* qits' forwardauth | the reserved prefix protects the gateway's *own* assertions; strip-then-inject order is named as load-bearing | ✅ |
| `WorkspaceApi.java` javadoc (l. 93–95) | cites the gateway authenticating nothing as why the daemon token exists | the token's justification is the **network** — its attackers are peer workspaces already inside `qits-net` and never traverse the front door | ✅ |
| `migration-plan.md` §4, §9 items 4 and 7 | auth unassigned, decide later; only `qits-workspaces` undeployable | decided here; item 7 corrected to all six services | ✅ |
| `EdgeHeaders` javadoc | honours a fronted qits' contract | asserts its own identity, strips by prefix first | ✅ |
| `migration-manifests/README.md` + `assign.py` | `unassigned.txt` covers auth | `gateway.txt` exists; auth is classified | ✅ |
| `qits-gateway` epic Part 4 | `forwardauth` "degrades to a compatibility mode" | `forwardauth` is the **only** internal contract; `oidc` is what moved | ⬜ epic lives in `../qits`, not updated here |

## 10. Deferred, with the cost named

- **`qits-net` is treated as trusted.** Every service sits unpublished on `qits-net` — and so does
  every workspace container, running coding agents over untrusted checkouts with unrestricted
  outbound network. `curl http://qits-projects:8080/api/…` from inside a workspace bypasses the
  gateway entirely. **Accepted for the POC**, to be addressed by a later feature (network split, or
  a service-to-service credential).
  *Consequence to hold onto:* the gateway is a perimeter against the internet, not a boundary on
  `qits-net`. Nothing in this plan should be described as if it were.
  *Corollary:* "temporarily trusted" means **do not add** isolation, not **remove** it. Nothing in
  §7 gets deleted under this assumption.
- **The control socket is unauthenticated and impersonable.**
  `/api/workspace-daemon/{workspaceId}` is token-free in `PublicPaths` and identifies its caller by
  a *path parameter*. Anyone on `qits-net` can claim to be any workspace's daemon. Edge auth neither
  touches nor fixes this; it is its own item.
- **WebSocket session lifetime.** The gate fires at upgrade only, so a socket open for hours
  outlives token expiry. True today, true after — no regression, but not a thing the edge fixes.
- **Workspace terminals are blocked on gateway Part 2.** The daemon's HTTP API and its two
  websockets have no gateway route and no injected token, so they do not bind at all
  (`migration-plan.md` §9 item 16). When addressability lands the shape is two hops with two
  credentials: browser → gateway (user auth) → gateway holds the per-workspace daemon token →
  daemon.

## 11. Open questions

1. ~~**Does `quarkus-oidc` fit the gateway's native-image budget?**~~ **Measured, and yes.** Container
   build, same machine: 50,146,360 B before → 56,286,264 B for `-Dqits.variant=oauth` (+6.1 MB,
   +12.2%); native generation 26.6 s → 27.6 s. The `local` target is 52,317,240 B — it switches the
   extension off but cannot drop the jar, which is the price of a single-module build. Judged
   acceptable for deleting the auth question from six other repositories. The escape hatch is
   recorded in the README and works unchanged: front the gateway with a forward-auth proxy and have
   it translate `Remote-User` into `X-Qits-User`.
2. ~~**Where does `SameOriginUpgradeCheck` live?**~~ **Already answered by the extraction** — it is
   in the services, and was before this plan was written: `qits-workspaces`' `DaemonControlSocket`
   and `ServiceProxyRoute`, and `qits-projects`' `RemoteLoginTerminalSocket`. Nothing to move. It is
   CSWSH protection, not authentication, and §7 stands: it must not be swept up as "auth".
3. **Session storage — still open.** `quarkus.oidc.application-type=hybrid` puts an encrypted
   `q_session` cookie on the browser, so a single gateway is stateless and needs nothing. Two
   gateway replicas need a shared `quarkus.oidc.token-state-manager.encryption-secret` at minimum.
   Nothing forces the issue yet; settle it before anyone scales the front door.
4. ~~**`/api/config.json` has two owners.**~~ **It has one.** It is `qits-observability`'s
   `telemetry/api/ConfigResource` — the telemetry/capture relay that `@qits/angular` fetches
   base-relative pre-bootstrap (`init-qits-integration.ts:70`). It carries no identity claim and has
   nothing to do with `/api/auth/me`; `PublicPaths`' "SPA identity relay" wording was describing this
   same endpoint. No conflict, and none blocking the move.

### Opened by the implementation

5. **`PublicPaths` is correct only for monolith-relative paths.** It matches what the `/` catch-all
   carries. The moment a service serves one of these under its own segment, the segment-prefixed
   form has to be added or a token-free caller starts being challenged. Tied to Part 0's
   segment/path mismatch; flagged in the class javadoc rather than guessed at.
6. **The gateway's suite proves the challenge, not the login.** It runs with no docker and no
   network against a static, never-contacted provider, asserting that the gateway challenges (302),
   refuses background transports differently (499), and where it points. Completing a code flow is
   quarkus-oidc's own test surface. If that ever needs proving here it wants an integration test,
   not a change to the unit suite.

## 12. Recorded in each service's AGENTS.md ✅

All six carry this, because it is the assumption a future change would silently break:

> Authentication happens at `qits-gateway`. This service resolves a principal from a trusted header
> and authenticates nothing. **`identity.isAnonymous()` is not a security state** — it means "no
> name for the audit row". A check of the form `if (identity.isAnonymous()) deny` would look like a
> security control and be worth nothing, because reaching this service at all already implies you
> are inside the trusted network.

Each also names the class that reads the header and states that roles are deliberately not resolved,
since "the monolith's version had roles" is the most likely reason someone would add them back.
