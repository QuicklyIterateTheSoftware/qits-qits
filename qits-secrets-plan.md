# qits-secrets — feature outline

> **Scope decision 2026-08-17:** this lands as one entry class inside
> **qits-configuration**, a per-env service owning versioned named values that
> services are told at runtime (the deployer-extras replacement). Plain
> entries are durable and readable at every deploy; secret entries keep the
> broker semantics below unchanged (in-memory only, approval-gated, one-shot
> redemption). Consumption contract: the deployer resolves per deploy or
> subscribes to change events — never a boot-time snapshot.

## Purpose

`qits-secrets` is an operator-unsealed, approval-gated secret broker. It reduces the platform's
reliance on Docker Swarm secrets by allowing authenticated workloads to request values from
Bitwarden at runtime.

It is not itself a durable secret store. Secret values and the Bitwarden access credential remain
in memory only and are never written to the database, configuration, logs, events, traces, or audit
records.

## Core model

`qits-secrets` stores:

- the Bitwarden access credential in memory only; it is write-only, can be overwritten, and is lost
  whenever `qits-secrets` restarts;
- Bitwarden secret identifiers and display metadata, but not secret values;
- persisted access rules;
- persisted request state and audit events, without secret values; and
- retrieved secret values only for the brief period needed to deliver them once.

A consuming process must necessarily possess a plaintext secret while using it. “Cannot be read
back” therefore means that qits provides no retrieval or debugging endpoint for an already-delivered
value, never persists or logs it, and releases it only to the authorized process.

## Request flow

```text
Workload -> IDP client-credentials token -> qits-secrets
                                         |
                              matching automatic rule?
                              +-- yes -> approve
                              +-- no  -> pending operator approval
                                         |
                                  operator approves
                                         |
                              fetch value from Bitwarden
                                         |
                              workload redeems value once
```

1. A workload submits `POST /secret-requests` using its IDP machine identity.
2. The response is `202 Accepted` with a request ID and a request-scoped capability.
3. The workload follows the request status through an SSE stream with heartbeats and reconnection.
4. A matching rule approves the request automatically, or an operator approves it in the UI.
5. Approval changes the request state to `approved`; no secret travels through SSE.
6. The workload calls a separate, one-use redemption endpoint.
7. `qits-secrets` fetches the value from Bitwarden and returns it once.
8. The approval expires after redemption or after a short, configurable TTL.

SSE carries status changes only. Separating status observation from redemption avoids keeping a
secret-bearing response open for minutes or hours and avoids replaying a value during SSE
reconnection.

## Delivery phases

### 1. Secret browser and operator unsealing

- Add an operator-authenticated frontend.
- Accept the Bitwarden credential through a write-only input.
- Keep the credential in memory only and discard it on restart.
- Show an explicit locked or unlocked state.
- Allow the credential to be overwritten without exposing the old value.
- Browse Bitwarden projects, secret identifiers, and display metadata.
- Keep revealing values out of the ordinary browser flow. If direct reveal is ever added, require a
  separate explicit operator action and leave it disabled by default.
- Ensure credentials and values never enter URLs, browser persistence, logs, metrics, traces, audit
  records, or error messages.

### 2. IDP client catalogue

- Add an IDP extension or protected API that lists machine clients and their display metadata.
- Use this catalogue to build rules and show understandable requester names in the UI.
- Authenticate requests by validating their signed access tokens.
- Take the authoritative requester identity from the token's `client_id` or `azp` claim, never from
  a name supplied in the request body.
- Use immutable client IDs in rules; names are display-only and may change.
- Disable or invalidate rules whose IDP client has been deleted or disabled.

The IDP catalogue improves management and presentation. It is not the source of request
authenticity; the signed token is.

### 3. Access rules

A rule can contain:

- requesting client ID;
- Bitwarden secret ID;
- environment or project scope;
- automatic or manual approval mode;
- approval and redemption TTLs;
- one-shot or renewable behavior; and
- optional workload or service constraints.

The default is deny or manual approval. Automatic release requires an explicit rule. Rules use
immutable client and secret IDs internally, with names retained only for display.

### 4. Secret request UI

- Show pending, approved, denied, expired, redeemed, and cancelled requests.
- Show requester identity, requested secret metadata, environment, reason, and first-seen time.
- Provide `approve once`, `deny`, and `approve and create rule` actions.
- Record the approving or denying operator in the audit trail.
- Do not display secret values in request lists or request details.
- Avoid bulk approval in the first version.
- Coalesce equivalent outstanding requests so a failing workload cannot flood the operator queue.

### 5. Workload integration

Provide a small shared client library that:

- authenticates with the workload's existing IDP machine identity;
- submits secret requests;
- follows status using SSE heartbeats and reconnection;
- redeems an approved secret once;
- holds the result only in process memory;
- clears references during shutdown where practical;
- reports locked, pending, denied, and expired states clearly; and
- does not blindly retry redemption after an ambiguous network failure.

## Request lifecycle

Suggested states:

```text
pending -> approved -> redeemed
   |          |
   |          +-> expired
   +-> denied
   +-> cancelled
   +-> expired
```

Request metadata may survive a `qits-secrets` restart, but approval does not imply that a value has
been fetched or stored. Approvals made before the broker becomes locked should expire or require
reconfirmation after it is unsealed again.

## Restart semantics

When `qits-secrets` restarts:

- it starts locked;
- the Bitwarden credential is absent;
- an operator must enter the credential again; and
- outstanding requests remain visible but cannot be completed until unsealed and reassessed.

When a workload restarts:

- it requests its required secrets again;
- matching automatic rules may approve them; and
- requests without automatic rules return to the manual approval queue.

This intentionally trades unattended recovery of the secret broker for an explicit human unseal.

## Security boundaries

- Require TLS for every secret-bearing request.
- Use IDP client credentials to identify workloads.
- Protect the frontend with operator authentication and a dedicated authorization role.
- Bind request capabilities and redemption to the authenticated requesting client.
- Make redemption capabilities short-lived and single-use.
- Prevent workload clients from creating or modifying access rules.
- Never place secret values in persistence, events, SSE messages, exceptions, tracing, metrics, or
  access logs.
- Audit requests and decisions using identifiers and metadata only.
- Apply rate limits and duplicate-request coalescing.
- Keep the Bitwarden credential inaccessible to browser code after submission.
- Define behavior for token expiry, client disablement, rule changes, approval races, and ambiguous
  redemption failures before enabling automatic release.

## Bootstrap boundary

This feature reduces Swarm-secret usage but cannot initially eliminate bootstrap secrets entirely.
`qits-secrets` needs enough identity and TLS configuration to authenticate with the IDP and safely
serve requests before it can broker anything else.

The first version can retain a minimal Swarm-managed root set for that bootstrap identity. A later
design may replace it with workload identity or a platform-local key hierarchy.

## First usable release

The first usable release should include only:

1. manual operator unsealing;
2. the Bitwarden metadata browser;
3. authenticated IDP client identity;
4. manual request approval;
5. one-use redemption; and
6. a metadata-only audit trail.

Automatic rules come afterward. This lets the complete authentication, approval, redemption, and
audit boundary be exercised manually before unattended secret release is introduced.

## Open design questions

- Which Bitwarden product and credential type will be targeted first?
- Should pending requests survive restarts, and which pre-restart decisions remain valid?
- What are the default approval and redemption TTLs?
- How should a workload recover when redemption succeeds server-side but its connection fails before
  it receives the response?
- Is secret version selection explicit, pinned by a rule, or always the provider's latest value?
- Which secret metadata is safe to expose to operators and requesting clients?
- How are environment and project scopes derived and cryptographically bound to workload identity?
- What is the smallest unavoidable bootstrap-secret set for `qits-secrets` itself?
