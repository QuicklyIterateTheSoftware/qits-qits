# qits-dns — an authoritative DNS server for platform-managed hostnames

Status: **planned, not started.** Written 2026-07-29. The submodule does not exist yet and is
created only after this plan is finalized — §10 carries the recipe but is deliberately not step 1.
Conventions cited as "the qits-ci case" refer to that repo's `CLAUDE.md`; where this document names
a mechanism qits-ci also has (token guard, named datasource, packaged-surface IT), the intent is
*that mechanism, ported*, not a reinvention.

---

## 1. What this is

The platform orchestrates building and deploying applications — including itself — and every
deployed environment needs a resolvable name without a human touching DNS. The scheme:

- `qits.eu` → prod (the qits-gateway; everything else is reached via `/paths` behind it).
- `some-fancy-feature.qits-dev.eu` → the environment for the epic `some-fancy-feature`, a shared
  branch across repositories, built and deployed as its own stack.
- `the-application.some-fancy-feature.qits-dev.eu` → one application inside that environment, when
  an epic's deployment architecture has more than one thing that needs its own hostname.

qits-dns is the module that makes those names resolve. It is an **authoritative-only DNS server**
for zones delegated to it at the registrar (NS records pointed at our IP), serving A/AAAA/CNAME
answers from configuration held in its own database, plus a **record-management HTTP API** for the
other modules to create and delete those entries.

Everything that *calls* the API — CD wiring an epic environment to a hostname, teardown deleting
it, whatever decides what points where — is explicitly **out of scope**. This plan enables the
submodule itself: the wire protocol, the data model, the API, and nothing above it.

## 2. Scope

**In scope**

- Authoritative answers over **UDP and TCP** for any number of zones, each a registered domain of
  at least two labels (`qits-dev.eu` — a zone is `a.b`, never a bare TLD).
- Names at three depths relative to the zone apex, and no deeper: the apex itself, one label
  (`feature.qits-dev.eu`), two labels (`app.feature.qits-dev.eu`).
- Explicit records and **opt-in wildcards** at each depth: `*` (any one label), `*.<label>` (any
  label under a specific sub), `*.*` (any two labels). A wildcard resolves only if its row exists —
  nothing is implied per zone.
- Record types **A, AAAA, CNAME**, plus the synthesized **SOA and NS** a delegated zone cannot
  function without (§3).
- CRUD API for zones and records, guarded by a static machine token (the `qits.ci.token` pattern).

**Out of scope, deliberately**

- The callers (CD, gateway, epic orchestration) and any gateway route to the API.
- Recursion (answers carry RA=0; queries for names outside our zones are REFUSED).
- Zone transfers (AXFR/IXFR → REFUSED), NOTIFY, secondaries, DNSSEC.
- TXT records — noted in §13 as the first likely extension (ACME DNS-01 is how `*.qits-dev.eu`
  eventually gets a wildcard certificate), but the v1 enum is A/AAAA/CNAME.
- Rate limiting / response-rate-limiting. Recorded as a risk (§13), not built in v1.
- Registrar-side setup (NS records, glue) — a deployment fact, documented in the repo README.

## 3. Resolution semantics — the contract

The resolver is a pure function from `(qname, qtype, snapshot)` to a response. Its rules, fixed
here so the implementation and its tests have one source:

**Matching.** Lowercase the qname (DNS is case-insensitive; the response echoes the question's
original spelling — dnsjava does this for free when the response is built from the query). Find the
longest configured zone that is a suffix of the qname. No zone → **REFUSED**. Then match the labels
left of the zone:

| Labels above apex | Tried in order |
|---|---|
| 0 | `@` |
| 1 (`x`) | `x`, then `*` |
| 2 (`y.x`) | `y.x`, then `*.x`, then `*.*` |
| 3+ | no match — **NXDOMAIN** |

First name that has any rows wins; later patterns are not consulted. A wildcard match is
**expanded**: the records in the answer section carry the queried name as their owner, never a
literal `*` — resolvers reject answers whose owner name does not match the question. This deliberately deviates
from RFC 4592's empty-non-terminal corner case: if only `y.x` exists and `*` is configured, a query
for `x` matches `*` here (real DNS would say `x` exists and the wildcard is blocked). Our users
opting into `*` mean "cover every one-label name", and that is what they get.

**One RFC rule we do keep:** if the qname has no rows and matches no wildcard, but *is a prefix of
a name that has rows* (query `x`, only `y.x` exists, no wildcards), the answer is **NODATA**
(NOERROR, empty answer, SOA in authority), not NXDOMAIN — resolvers negative-cache NXDOMAIN for
the whole subtree, which would poison `y.x`.

**Answering, once a name matched:**

- qtype A/AAAA with matching rows → all of them (round-robin by multiple rows is allowed).
- The name has a CNAME → answer the CNAME regardless of qtype (except qtype CNAME, same answer).
  If the target is in one of our zones, chase it **once** and append its A/AAAA rows to the answer
  section — depth is bounded at 2, so one hop is the maximum useful chase. The chase runs this
  same matching table, so a chase target may itself land on a wildcard; a chase that lands on
  another CNAME stops there (one hop means one hop). Out-of-zone target: the
  CNAME alone, the resolver does the rest.
- Name matched but no rows of the asked type (and no CNAME) → NODATA.
- qtype SOA at apex → the synthesized SOA. qtype NS at apex → one NS per name in
  `qits.dns.ns-names`. qtype ANY → REFUSED (the modern stance, RFC 8482 in spirit; keeps the
  amplification surface at zero).
- Every negative answer (NXDOMAIN, NODATA) carries the zone's SOA in the authority section — 
  without it, negative caching breaks and resolvers hammer us.

**Synthesized apex records.** SOA: `mname` = first entry of `qits.dns.ns-names`, `rname` =
`qits.dns.hostmaster`, `serial` = the zone row's serial (bumped on every write in that zone),
refresh/retry/expire constants in code, `minimum` = the default TTL. These exist so delegation
works and are not rows in the DB — the DB holds only what the API creates.

**TTL** defaults to `qits.dns.ttl-seconds` (default 60 — these names change with deployments; low
TTL is the point), overridable per record.

**Validation rules the API enforces** (§6 owns the surface, the rules live here):

- Zone fqdn: lowercase LDH labels, ≥ 2 labels, unique, not a suffix/prefix of an existing zone.
- Record name: exactly one of the six shapes `@ | l | l.l | * | *.l | *.*` (`l` = LDH label).
- A value is an IPv4 literal; AAAA an IPv6 literal; CNAME an absolute hostname (stored without
  trailing dot).
- **No CNAME at `@`** — the apex carries SOA and NS, and DNS forbids CNAME beside anything
  (RFC 1034 §3.6.2). The use case "apex → same CNAME as the wildcards" is served by giving the
  apex A/AAAA rows with the same target IPs; ALIAS-style flattening is future work (§13).
- A name with a CNAME row admits no other rows, and vice versa.
- Multiple A (or AAAA) rows per name are fine; `(zone, name, type, value)` is unique.

## 4. Data model

Own named datasource `dns`, file-based H2 under `~/.qits/data/dns`, own Flyway lineage at
`classpath:db/dns/migration` — the qits-ci arrangement verbatim, and for the same reason: the
module is extraction-shaped from day one. No FK into any other module's tables; there are none to
want.

`V1__init.sql`:

```sql
create table dns_zone (
    id         varchar(255) not null primary key,
    fqdn       varchar(253) not null unique,   -- lowercase, no trailing dot, e.g. 'qits-dev.eu'
    serial     bigint       not null,          -- SOA serial; bumped on every write in the zone
    created_at timestamp(6) with time zone not null,
    updated_at timestamp(6) with time zone not null
);

create table dns_record (
    id         varchar(255) not null primary key,
    zone_id    varchar(255) not null,
    name       varchar(255) not null,          -- '@' | '<l>' | '<l>.<l>' | '*' | '*.<l>' | '*.*'
    type       varchar(8)   not null check (type in ('A', 'AAAA', 'CNAME')),
    value      varchar(253) not null,
    ttl        int,                            -- null -> qits.dns.ttl-seconds
    created_at timestamp(6) with time zone not null,
    updated_at timestamp(6) with time zone not null,
    constraint uq_dns_record unique (zone_id, name, type, value),
    constraint fk_dns_record_zone foreign key (zone_id) references dns_zone
);

create index idx_dns_record_zone_name on dns_record (zone_id, name);
```

The wildcard opt-ins are ordinary rows (`name = '*'` etc.) — "opt in per domain" is the presence
of the row, no flags on the zone.

**The hot path never touches H2.** A `ZoneSnapshot` — an immutable map from zone fqdn to its
records, plus the config-derived SOA/NS material — is built at boot and rebuilt after every
mutating API call, swapped in with one volatile write. A rebuild always re-reads committed DB state (never the
in-flight entities), so concurrent API writes converge on whichever rebuild runs last. The
resolver reads only the snapshot, so the UDP event loop never blocks on a datasource and a query
burst costs zero DB load. At this
data size (hundreds of rows, not millions) rebuilding whole-snapshot-per-write is simpler and
safer than invalidation.

## 5. The wire layer

- **UDP**: a vert.x `DatagramSocket` (Quarkus-managed vert.x instance) bound to
  `qits.dns.host`:`qits.dns.port`. Parse → resolve against the snapshot → encode → send. Malformed
  packets are dropped and counted, never answered (answering FORMERR to garbage is amplification
  surface for free).
- **TCP**: a vert.x `NetServer` on the same port, RFC 1035 two-byte length prefix framing, same
  resolver. Authoritative servers must speak TCP — resolvers retry over it on truncation, and some
  probe it outright.
- **Truncation**: responses that exceed the client's advertised size (EDNS0 OPT payload, else 512)
  are truncated with TC=1; dnsjava's `Message.toWire(maxLength)` implements this. Our answers are
  a handful of records, so TC is rare, but the path must exist and be tested.
- **EDNS0**: echo an OPT record advertising payload size 1232 when the query carried one; the
  effective UDP response budget is min(client's advertised size, 1232). No options, no DNSSEC-OK
  handling (DO bit ignored; we sign nothing).
- **Non-queries**: opcode ≠ QUERY (UPDATE, NOTIFY, …) → NOTIMP; a parseable query with
  QDCOUNT ≠ 1 → FORMERR. Only unparseable bytes get silence.
- Every response sets AA=1 for our zones, RA=0 always.

**Codec: dnsjava** (`org.dnsjava:dnsjava` 3.6.x), used strictly for `Message`/`Name`/`Record`
parse and encode — none of its resolver/lookup machinery, which is where its `ServiceLoader` and
system-configuration reflection live. Rationale over the alternatives:

- *Hand-rolled codec*: the format is small, but this socket parses **hostile input from the open
  internet** — compression-pointer loops, truncated headers, label-length lies. A two-decade-old
  parser beats a fresh one here; this outweighs the repo culture's (correct) suspicion of new
  dependencies.
- *netty-codec-dns*: already Netty-adjacent, but its codecs are channel-pipeline handlers;
  driving them from a vert.x datagram socket means hand-feeding ByteBufs through pipeline
  fixtures — more glue than the dependency saves.

Because `service/` must compile to a native image (§7), **dnsjava-in-native is this plan's named
spike, gated first** (the musl-spike pattern from the ci-daemon plan): a hello-world native build
that parses a query off a real UDP socket and encodes the answer, plus `Message.toWire`
truncation. Expected clean — the classes involved are static-init-friendly — but if it needs
reflection config, that config is part of the change, and if it fails outright, the fallback is a
minimal hand-rolled codec *behind the same internal seam* (`DnsCodec`: bytes → question,
answer → bytes), which is why that seam exists regardless.

**Port and topology**: default `8053` (both protocols). Binding 53 needs privileges; the
deployment maps `53:8053/udp` and `53:8053/tcp` (or grants `NET_BIND_SERVICE`). The public IP the
delegation points at is **the same host the platform (and thus qits-gateway) runs on** — one
machine, port 443 → gateway, port 53 → the qits-dns container. DNS traffic never passes *through*
the gateway: the gateway proxies HTTP, DNS is not HTTP, so qits-dns is a sibling container behind
the same IP, not a gateway feature. Registrar mechanics, in the README: a registrar's NS record
holds a **hostname**, not an IP (e.g. `ns1.qits.eu`), and the IP rides along as a **glue A
record** the registrar asks for whenever the NS name lives inside the zone it serves — that pair
together is "point the domain at our server".

## 6. The management API

JAX-RS in `service/`, under `/dns/api`. Consumers are other modules on the shared network calling
the service directly (`http://qits-dns:8080/dns/api/...`); no gateway route in this plan.

| Verb + path | Meaning |
|---|---|
| `POST /dns/api/zones` | Create a zone `{fqdn}` → 201. Validation per §3. |
| `GET /dns/api/zones` / `GET /dns/api/zones/{id}` | List / read, records embedded on the single read. |
| `DELETE /dns/api/zones/{id}` | Delete zone and its records → 204. |
| `POST /dns/api/zones/{id}/records` | Create `{name, type, value, ttl?}` → 201. 409 on the §3 conflicts (CNAME rules, duplicate). |
| `PUT /dns/api/zones/{id}/records` | **Replace-by-(name, type)**: body `{name, type, values: [...], ttl?}` atomically swaps all rows of that (name, type) → 200. The verb automated deployers actually want — idempotent re-deploys don't dance around 409s. |
| `DELETE /dns/api/records/{id}` | Delete one record → 204. |

Every mutation bumps the zone serial and triggers the snapshot rebuild in the same transaction
boundary (rebuild after commit — a failed write must not publish).

**Auth**: `qits.dns.token`, the qits-ci pattern verbatim — a static token checked by a
`ContainerRequestFilter` on the write verbs, blank ⇒ no-op (dev/test), reads open. When a real
caller exists and wants per-module identity, that is that plan's problem.

## 7. Repo shape

New repository `qits-dns`, submodule at **`services/qits-dns`** — it is a deployable backend
service; the DNS-ness is shape, not role. The qits-ci skeleton, ported:

- Two maven modules, directories **`dns/`** and **`service/`**, artifactIds
  `eu.wohlben.qits:qits-dns-domain` / `qits-dns-service` (namespaced GAV, generic directory names
  — the qits-ci collision rationale applies the moment a workspace container mounts the shared
  m2). Standalone parent pom, versions duplicated on purpose: a clone of this repo alone builds.
- `dns/` — `entity`, `persistence`, `dto`, `mapper`, `control`, `error`, **and the resolver core**
  (`ZoneSnapshot`, the §3 matching, `ResolutionResult`). Framework-free: no JAX-RS, no vert.x, no
  dnsjava — the resolver operates on its own types, so §3 is testable as pure functions.
- `service/` — `api` (routes, token filter, exception mapper) and **`wire`** (the UDP/TCP
  listeners, the `DnsCodec` seam, the dnsjava-backed implementation). Same line that put
  `daemonhost` beside `api` in qits-ci: it needs the runtime stack, the domain module does not.
- **The two rules carry over wholesale**: clone-alone `./mvnw verify` green with no docker and no
  credentials, and `service/` compiles to a GraalVM native image (`.sdkmanrc`, `-Dnative`, the
  fallback-to-container-build log caveat documented). Plain JUnit 5, no Mockito, real sockets in
  tests. Observability follows the siblings (OTLP senders; nothing DNS-specific in v1).
- `README.md` (the boundary: what the wire serves, what the API owns, registrar/deployment notes)
  and `CLAUDE.md` (the two rules, module conventions, the §3 contract pointer).

## 8. Config keys

Shipped from `dns/`'s `META-INF/microprofile-config.properties`, the library-jar-defaults
convention:

```properties
quarkus.datasource.dns.db-kind=h2
quarkus.datasource.dns.jdbc.url=jdbc:h2:file:${user.home}/.qits/data/dns/h2/dns   # no AUTO_SERVER — the qits-ci lesson
quarkus.hibernate-orm.dns.datasource=dns
quarkus.hibernate-orm.dns.packages=eu.wohlben.qits.dns.entity
quarkus.flyway.dns.migrate-at-start=true
quarkus.flyway.dns.locations=classpath:db/dns/migration

qits.dns.host=0.0.0.0
qits.dns.port=8053              # deployment maps 53 -> this; tests override to 0 (ephemeral)
qits.dns.ttl-seconds=60
qits.dns.ns-names=              # comma list of this server's public NS hostnames (ns1.qits.eu,...)
qits.dns.hostmaster=            # SOA rname, as a hostname (hostmaster.qits.eu)
qits.dns.token=                 # blank => write guard is a no-op (dev/test)
```

`ns-names` and `hostmaster` blank by default — this repo cannot know its public names, and a
default it invented would be a lie (the `daemon-version` stance). Blank means SOA/NS synthesis is
disabled and a boot log line says so; the server still answers A/AAAA/CNAME, so dev works
untouched, but a real delegation requires setting both.

## 9. Tests and gates

- **Resolver unit tests** (`dns/`): the whole of §3 as pure-function tests — every row of the
  matching table, the RFC-deviation case, the empty-non-terminal NODATA case, CNAME-chase
  in-zone/out-of-zone, NXDOMAIN at depth 3, REFUSED out-of-zone, serial in the SOA.
- **Wire round-trip tests** (`service/`): server on an ephemeral UDP port, real queries via
  dnsjava's `SimpleResolver` pointed at it — the codec exercised from both sides. TCP framing
  test, one oversized-answer TC + TCP-retry test, one garbage-datagram test (dropped, socket
  stays alive), EDNS echo test.
- **API tests**: CRUD, every §3 validation rejection, PUT-replace atomicity, token guard
  (guarded when set, open when blank), snapshot visibility after write (write a record over HTTP,
  resolve it over UDP in the same test — the whole loop, no docker involved anywhere).
- **`DnsPackagedSurfaceIT`** (the qits-ci precedent, `-Dnative`): boot the binary, Flyway runs,
  one UDP query answered, one API write lands. This is what makes the dnsjava-native spike
  finding *stay* true.

## 10. Submodule add (deferred until the repo has its seed commit)

The `CLAUDE.md` recipe, `--name` included:

    git submodule add --name qits-dns https://github.com/QuicklyIterateTheSoftware/qits-dns services/qits-dns
    git config -f .gitmodules submodule.qits-dns.ignore all
    git config -f .gitmodules submodule.qits-dns.update merge
    git submodule set-branch --branch main services/qits-dns
    git add .gitmodules services/qits-dns && git commit

Confirm with `git ls-tree HEAD services/qits-dns` (a `160000 commit` entry). Remember the remote
must be seeded first — `submodule add` fails on a bare-born branch and leaves a stale
`.git/modules/qits-dns` behind.

## 11. Order

This is the truth about *landing*; §14 is the truth about *working* — which of these steps run as
parallel subagents, and the fences that keep them out of each other's files.

1. **Spike**: dnsjava in a native image (§5). Stop/re-plan the codec choice on failure; nothing
   else is invalidated — the `DnsCodec` seam absorbs the outcome. *Runs in parallel with step 2
   (§14 wave 0).*
2. **Repo scaffold + frozen seams**: poms (both modules, **all dependencies declared upfront**),
   `.sdkmanrc`, `mvnw`, the migration, the entities, and the three internal seams as compiling
   stubs — the `ZoneSnapshot` read surface, `ResolutionResult`, and the `DnsCodec` interface.
   Freezing these here is what makes wave 1's parallelism safe; it is scaffolding, not design —
   §3 already dictates their shapes.
3. **Resolver core** (`dns/`): the §3 matching, snapshot building, the full unit suite.
   **In parallel:** **wire layer** (`service/wire`): UDP + TCP listeners over the codec seam,
   round-trip suite against a scripted fake resolver (§14 wave 1).
4. **API + snapshot rebuild + token guard**, the write-then-resolve loop test, then
   `DnsPackagedSurfaceIT`. One agent, deliberately serial (§14 wave 2).
5. **Docs** (README with registrar/port notes, CLAUDE.md) ride step 4's closing commit; seed
   commit pushed, **submodule commit here** (§10).

## 12. Done when

With a zone `qits-dev.eu` created over the API, records `@ A`, `* CNAME`, `*.* CNAME` and an
explicit `app.feature A` written through it: `dig @host -p 8053 qits-dev.eu A` returns the apex
rows AA-flagged; `dig anything.qits-dev.eu` returns the `*` CNAME with the in-zone chase applied;
`dig x.y.qits-dev.eu` the `*.*` CNAME; `dig app.feature.qits-dev.eu` the explicit A over the
wildcard; `dig other.tld` REFUSED; `dig a.b.c.qits-dev.eu` NXDOMAIN with SOA in authority; the
same answers over TCP; deleting the records over the API changes the answers on the next query
with no restart; `./mvnw verify` green clone-alone with no docker; `-Dnative` produces a binary
that passes `DnsPackagedSurfaceIT`.

## 13. Risks and open questions

- **This is an internet-facing UDP service parsing hostile bytes** — the only qits module exposed
  below HTTP. Mitigations in v1: mature parser, drop-don't-answer on garbage, REFUSED on
  ANY/AXFR/out-of-zone, tiny responses (amplification factor ~1). *Not* in v1: response rate
  limiting. Acceptable while the zones are ours and the deployment sits behind whatever the host
  already has; revisit before pointing anything third-party at it.
- **dnsjava in native image** is assumed, not known — hence spike-first with a named fallback.
- **Apex CNAME is forbidden** and the original sketch wanted "same cname or A record" at the apex.
  The answer is A/AAAA rows at `@`; if callers end up wanting apex-follows-CNAME semantics,
  ALIAS-style flattening (resolve the target server-side at snapshot build) is the extension, and
  it belongs to whichever plan brings those callers.
- **TXT support** rides in cleanly (enum + value validation + no new matching) and will be wanted
  for ACME DNS-01 the day `*.qits-dev.eu` needs a wildcard certificate. Deliberately not in v1;
  the schema's `type` check constraint is the only migration it takes.
- **Serial semantics**: resolvers only see the serial in SOA answers and we have no secondaries,
  so a plain bump-on-write counter suffices; the conventional YYYYMMDDnn encoding buys nothing
  here.
- **Open**: whether epics need names *deeper* than two labels (`x.y.feature.qits-dev.eu`). The
  matching table and the shape grammar are the two places depth lives; extending both is
  mechanical but the stated requirement stops at two, so v1 stops at two.

## 14. Delegation — who can work in parallel, and where the fences are

The ci-daemon plan's delegation section had "one writer per repo per wave" as its natural fence.
This feature is **one repo**, so the fence drops a level: **one writer per maven module per
wave**, and within `service/`, the `wire` and `api` packages are never in flight at once — they
share a pom and an application.properties, and two agents in one module is how a pom gets two
parents. The fences that make the waves below safe:

> **All dependencies are declared by the scaffold, upfront.** Both poms list everything any wave
> needs (quarkus-rest, hibernate/panache, flyway, h2, dnsjava, test deps) before any parallel
> work starts. An agent that discovers it needs a dependency **stops and reports** instead of
> editing a pom it does not own — a pom is the highest-conflict file in a maven repo and exactly
> one wave-0 agent ever writes one.
>
> **The frozen seams have one author.** `ZoneSnapshot`'s read surface, `ResolutionResult`, and
> `DnsCodec` are stubbed by the scaffold and owned by the **resolver agent** from wave 1 on. The
> wire agent codes against them and never edits them; a shape change it needs is a report to the
> resolver agent, whose commit it becomes (the vendored-protocol rule, applied to intra-repo
> seams). Expect one or two of these pings; that channel existing is the point.
>
> **Spikes return findings, not commits.** The dnsjava spike runs in a scratch worktree, never
> the repo's main, and delivers a findings note (build args, any reflection config, the
> toWire-truncation result) that the wire agent applies. Merging spike scratch work is how the
> native config drifts from what was actually proven.
>
> **Each agent owns its own module's test tree**, fixtures included. Shared test helpers are a
> smell here — the resolver suite is pure functions, the wire suite fakes the resolver, the API
> suite arrives when the repo is serial again.

**Wave 0 — two agents, fully parallel, different checkouts:**

- **Spike agent** (scratch worktree): §5's named spike. **Stop/re-plan on failure applies here**
  — this agent failing reopens the codec decision before the wire agent exists; nothing else is
  invalidated.
- **Scaffold agent** (the repo): §11 step 2 exactly — poms, skeletons, migration, entities,
  frozen seams, `./mvnw verify` green on stubs. Small and boring on purpose; everything waits on
  it, so it does nothing that invites review debate.

**Wave 1 — after the scaffold is merged; two agents, disjoint modules:**

- **Resolver agent** (`dns/`, whole module): the §3 contract as pure functions plus the snapshot
  builder and the full §9 resolver suite. Owns the seams from here on.
- **Wire agent** (`service/wire` only): listeners, dnsjava codec behind `DnsCodec`, and the §9
  wire suite driven by a **scripted fake resolver** (canned `ResolutionResult`s — real sockets,
  fake answers), so nothing here blocks on the resolver agent's progress. Applies the spike's
  findings. Touches `service/`'s pom and properties **not at all** — the scaffold already
  declared everything.

**Sync point:** both wave-1 branches merged, `./mvnw verify` green with the resolver suite and
the fake-driven wire suite passing together. Nothing in wave 2 starts before it.

**Wave 2 — one agent, deliberately serial:**

- **Integration agent**: `service/api` (routes, DTOs, token filter, validation calling the
  `dns/` control layer — implemented once there, never duplicated in DTOs), the snapshot rebuild
  wiring, the write-then-resolve loop test, `DnsPackagedSurfaceIT`, and the README/CLAUDE.md.
  This is the wave that touches both modules' wiring and the properties files, which is exactly
  why it is one agent — fanning it out (API to one, packaged IT to another) buys conflicts in
  `application.properties` and the pom in exchange for nothing.

**Reviews ride the boundaries, in parallel with the next wave:** a review agent on the scaffold's
frozen seams while wave 1 starts (the seams are the most expensive thing to get wrong and the
cheapest to review — three small types against §3); a review agent on the resolver's §3
conformance while wave 2 starts (the matching table makes it a checklist); a full review after
wave 2, before the docs flip to done. A review never blocks the wave it reviews, only the next
one.

**The qits-qits side** (submodule commit, §10) is thirty seconds of orchestrator work once the
seed commit is pushed; do not parallelize around it, just do it.
