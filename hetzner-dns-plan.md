# Hetzner DNS provider plan

> **Status 2026-08-15: deferred.** qits-platform-dns was removed from the
> platform instead: the submodule left the wrapper, the bootstrap no longer
> seeds or deploys it, and the two callers now carry NOTE comments marking
> the hook (qits-projects' `ProjectDomainRegistrar` port, the bootstrap's
> former dnsZone phase). DNS records are configured by hand at the external
> provider. This plan is the design to revive if the platform ever manages
> DNS again — the spi/hetzner module split and the Cloud-API notes below
> still hold.

Replace qits-platform-dns's self-hosted DNS serving with pushes to the
Hetzner DNS API. The service keeps its Postgres record store and its
`/dns/api` REST surface. It stops answering DNS queries itself: the wire
listener goes away, ports 5353/8053 disappear, and Hetzner's nameservers
serve the zone.

## Decisions

- **Target the Hetzner Cloud API** (`https://api.hetzner.cloud/v1`), not the
  legacy `dns.hetzner.com/api/v1`. The legacy API and console shut down in
  May 2026 — it no longer exists. The new API is rrset-based:
  - `GET/POST /v1/zones`, `GET /v1/zones/{id}`
  - `GET/POST /v1/zones/{zone_id}/rrsets`
  - `DELETE /v1/zones/{zone_id}/rrsets/{name}/{type}`
  - Auth header: `Authorization: Bearer <token>` (a Hetzner Cloud project
    token; old DNS tokens do not carry over).
  - An rrset is `(name, type) -> {ttl, [values]}` and carries `labels`.
    Verify the exact zone-create body and update semantics against
    docs.hetzner.cloud during implementation; as of early 2026 there is no
    partial rrset update — replace via POST, or delete + create.
- **Two new maven modules** in qits-platform-dns: `spi` (interfaces) and
  `hetzner` (the one implementation). "SPI" (service provider interface) is
  the term for this, not "ABI". Reactor order: `spi`, `dns`, `hetzner`,
  `service`.
- **The sync unit is the rrset**, not the single record. Local desired
  state is `dns_record` rows grouped by `(zone, name, type)`; that maps 1:1
  onto Hetzner rrsets and onto the existing `PUT …/records` replace-set
  semantics.
- **Ownership rule:** the sync only ever creates, replaces, or deletes
  rrsets it is tracking in its own table, and stamps them with the label
  `managed-by=qits`. It never touches NS, SOA, or any rrset it has no
  tracking row for. Hand-managed records in the same zone (MX etc.) are
  safe by construction.
- **Blank token = provider sync off** with one boot log line — house style,
  same as `qits.dns.ns-names` today.

## Module layout

    spi/       qits-dns-spi       plain jar, framework-free interfaces + records
    dns/       qits-dns-domain    existing; gains sync state + sweeper; depends on spi
    hetzner/   qits-dns-hetzner   Quarkus REST client impl of the spi
    service/   qits-dns-service   deployable; wires dns + hetzner, loses the wire package

SPI shape (framework-free, exceptions carry a `retryable` flag):

    public interface DnsProviderClient {
        ProviderZone ensureZone(String fqdn);                    // find-or-create
        List<Rrset> listManagedRrsets(String providerZoneId);    // qits-labeled only
        void putRrset(String providerZoneId, Rrset desired);     // create or replace
        void deleteRrset(String providerZoneId, String name, String type);
    }
    record Rrset(String name, String type, Integer ttl, List<String> values) {}
    record ProviderZone(String id, String fqdn, List<String> nameservers) {}

`hetzner` implements it with a MicroProfile REST client
(`@RegisterRestClient(configKey = "hetzner-dns")`, the IdpClients pattern from
qits-workspaces). Config:

    qits.dns.hetzner.token        env QITS_DNS_HETZNER_TOKEN, blank = off
    quarkus.rest-client.hetzner-dns.url = https://api.hetzner.cloud/v1

Back off and retry on 429/5xx; treat 4xx as non-retryable.

## Sync state and sweeper (dns module)

New migration `V2__provider_sync.sql`:

    dns_provider_zone   zone_id PK/FK, provider_zone_id, status, attempts,
                        next_attempt_at, last_error, updated_at
    dns_provider_rrset  (zone_id, name, type) PK, applied_hash, status,
                        attempts, next_attempt_at, last_error, updated_at

Rows in `dns_provider_rrset` mean "this rrset exists (or is pending) at the
provider because of us". A local delete keeps the row as a tombstone until
the provider delete succeeds, then removes it — no separate tombstone table.

Flow:

1. Every write endpoint (the five spots that call `snapshots.rebuild()`
   today) upserts the affected rrset row as `PENDING` in the same
   transaction, then nudges the sweeper.
2. Sweeper: `@Scheduled` (new `quarkus-scheduler` dep,
   `ConcurrentExecution.SKIP`) plus a boot pass. Per due row: ensure zone,
   then diff desired (grouped `dns_record` rows, hashed) against
   `applied_hash` → `putRrset` / `deleteRrset`. Success stamps `APPLIED` +
   hash; failure stamps `FAILED`, bumps `attempts`, sets `next_attempt_at`
   with the eventstream `RetrySchedule`-style exponential backoff capped at
   5 min.
3. CommissionReconciler rules apply: a failed provider read deletes
   nothing; a failed local read deletes nothing.
4. DbRetry caveat: provider HTTP calls never run inside a
   `DbRetry.inNewTx` body. Claim work in one tx, call Hetzner, record the
   outcome in a second tx.

Surface the state: add a `sync` field (`status`, `lastError`) to
`RecordDto`/`ZoneDetailDto`, and return the zone's Hetzner nameservers in
`ZoneDetailDto` so the delegation target is visible from the API.

## Removals (service + dns modules)

- `wire/` package entirely: `DnsWireServer`, `DnsCodec`, `DnsjavaCodec`,
  `DecodedQuery`, `DnsFormatException`.
- `DnsResolver` / `DnsResolverImpl`, `ZoneSnapshotBuilder`,
  `ZoneSnapshotHolder` — nothing consumes snapshots once the listener is
  gone; the write-side hook becomes the PENDING upsert.
- dnsjava dependency, its native-image args (`application.properties` L69,
  L80), and `quarkus-vertx` if nothing else needs it.
- Config keys `qits.dns.host`, `qits.dns.port`, `qits.dns.ns-names`,
  `qits.dns.hostmaster` (SOA/NS are Hetzner's job now).
- Dockerfile `EXPOSE 8053/udp 8053/tcp`.

Keep: zone/record tables and services, `/dns/api` controllers,
`DnsTokenFilter`, health, OTel.

## Deployment and bootstrap (qits-cli-bootstrap)

- `ComposeTemplate`: drop the dns `ports:` block (5353→8053 udp/tcp,
  `mode: host`); pass through `QITS_DNS_HETZNER_TOKEN`.
- `DomainTokens`: drop `QITS_DNS_NS_NAMES` / `QITS_DNS_HOSTMASTER`.
- `SeedPhases.dnsZone`: keep `@` and `*` A records; drop `ns1` (was glue
  for self-hosting) and `*.*` (real DNS wildcards already cover multiple
  labels; `*.*` is not a standard wildcard).
- `.env.example`: replace `#QITS_DNS_PORT=53` with
  `#QITS_DNS_HETZNER_TOKEN=`.
- `services/qits-platform-dns/.config/qits/deployments.yml`: no ports, so
  `update_order: stop-first` can go.

## Tests

- dns module: sweeper tests against a fake in-memory `DnsProviderClient`
  (the FakeDeploymentDriver pattern) — pending→applied, tombstone delete,
  backoff on retryable failure, untracked rrsets untouched.
- hetzner module: WireMock test of the REST client (auth header, rrset
  bodies, 429 handling).
- Existing arch-rules and Zonky-postgres harness stay; `./mvnw verify`
  needs `-Dquarkus.http.test-port=0` on this host.

## Ship order

1. Release qits-platform-dns (spi + hetzner + sync + wire removal) through
   the workspaces release endpoint.
2. Release qits-cli-bootstrap (compose template, tokens, seed changes).
3. Host ops on wohlben.eu: create a Hetzner Cloud project + API token, set
   `QITS_DNS_HETZNER_TOKEN` in `/root/qits/.env`, remove `QITS_DNS_PORT`;
   remove the live service's published 5353 ports (swarm publish-rm needs
   the full spec).
4. At the registrar: point the domain's NS at the nameservers Hetzner
   assigns the zone (read them from `GET /dns/api/zones/{id}` once synced).
5. Verify: seed a record via `/dns/api`, watch it turn `APPLIED`, resolve
   it against Hetzner's NS, confirm hand-made records untouched.

## Follow-ups (out of scope)

- TXT record type (enum + check-constraint migration) → DNS-01 → wildcard
  Let's Encrypt cert on the edge. Hetzner delegation is what unblocks
  moving off ACME staging.
- A second provider module beside `hetzner` if ever needed; the spi exists
  for that.
