# The main environment — plan

Written 2026-07-30. The next link in the chain: a **project** gets its standing deployment target
the moment it exists. Every project creation produces a `main` environment in qits-cd and
registers the project's domain in qits-dns — including the self-seeded `qits` project, whose seed
is implemented and reconciles on every packaged boot (`SelfSeedService`), so it takes the same
path rather than a special one.

Epic environments (branch-per-epic, the dns plan's `<epic>.qits-dev.eu` scheme) are a LATER leg;
nothing here precludes them and nothing here implements them.

## 1. The model

**One new fact on the project, temporary by declaration.** `Project` gains an embedded DNS record
config — `{domain, type, value}` — modelled as a JPA `@Embeddable` (`ProjectDnsRecord`: `domain`
an fqdn, `type` one of `A`/`AAAA`/`CNAME`, `value` the address or CNAME target). This is exactly
the payload later handed to qits-dns, stored 1:1 and nothing more. It is explicitly a placeholder:
when a dedicated service owns domain configuration, the embeddable and its columns go, and this
section of the plan is the record of that intent. (A CNAME needs a target to be a record at all,
so `value` is required for every type — the elided value in the sketch `{domain, type: cname}` is
read as "the caller supplies the target", not as a defaultable field.)

**Required at the API, nullable in the schema.** `POST /projects/api/projects` gains a required
`dns` object (`@NotNull @Valid`, fqdn/type/value validated). The columns themselves are nullable:
rows created before this change exist, and the self-seed may run without dns configuration (§3) —
a project without a stored record simply registers no domain. `ProjectDto` carries the config
back out; `docs/openapi.yml` is regenerated (the diff is the review — this is a breaking API
change and the document is where a client learns it).

**Two hooks on project creation**, both the house port pattern (interface in `domain/…/control`,
injected `Instance<T>`, sole implementation in `service/`, absent = supported configuration), both
fired after the creating transaction commits, both fire-and-forget with failures logged rather
than thrown — a project must never fail to exist because a sibling service was down:

1. **The main environment**: `POST {qits.cd.url}/cd/api/environments` with
   `{name: <project-slug>, branch: "main", applications: []}`. The environment name is the
   project's slug (already the dns-label charset cd validates); the branch is the convention this
   environment exists for; the applications list starts empty — qits-cd accepts that today, and
   which repositories become deployable applications is a later decision (cd has no
   add-application endpoint yet; that gap is named in §5, not papered over here). A 409 from cd
   (environment already exists — the seed reconciling on a later boot) is the idempotent no-op,
   logged at debug.
2. **The domain registration**: resolve the zone by suffix — `GET {qits.dns.url}/dns/api/zones`,
   pick the zone whose fqdn equals the domain or is its longest `.`-boundary suffix — then
   `PUT /dns/api/zones/{zoneId}/records` with `{name, type, values: [value]}` (the record name is
   the domain minus the zone apex, `@` when they are equal), `X-DNS-Token` from `qits.dns.token`
   when set. `PUT` replace-by-`(name,type)` is the verb the dns plan built for exactly this
   caller: re-registering is a 200, not a 409 dance. **No zone matches ⇒ warn and stop** — a zone
   is a registrar-level fact (NS delegation, glue) that this hook must not invent.

Config keys, receiver-named, shipped as defaults in qits-projects: `qits.cd.url=http://qits-cd:8080`
and `qits.dns.url=http://qits-dns:8080` (scheme+host+port, NO path — the paths are the receivers'
own and live in the notifier code), plus `qits.dns.token` (blank ⇒ no header, matching the dns
guard's open mode). HttpClient as an instance field of the `@ApplicationScoped` bean — the
native-image constraint every notifier in the platform documents.

## 2. Where the hooks hang

`ProjectService.create(...)` gains the dns parameter (nullable — the service is also the seed's
entry) and fires both ports after its commit, so every creation path — the REST controller, the
self-seed, any future caller — produces the environment and the registration without knowing
either exists. The controller enforces the API-level requiredness before the service is reached.

## 3. The self-seeded project

`SelfSeedService.ensureProject()` already reaches `ProjectService.create`, so the `qits` project
gets its `main` environment for free on the next reconcile of a fresh deployment — and on an
ALREADY-seeded deployment the reconcile finds the project by name and creates nothing, so the
environment hook does not fire for it. That asymmetry is accepted for now (a one-line curl closes
it on an existing deployment) rather than taught to the reconcile, which would mean making the
hooks themselves reconciliation-aware — more machinery than the temporary model deserves.

The seed's dns config is optional: `qits.startup-seed.dns-domain`, `qits.startup-seed.dns-type`,
`qits.startup-seed.dns-value` — all three set ⇒ the seeded project stores and registers them;
absent (the shipped default) ⇒ the project is created without a domain, exactly what the nullable
columns exist for. A deployment that owns `qits.eu` sets three env vars and the seed does the
rest.

## 4. Changes, by repo

Everything lands in **qits-projects**:

1. `domain/`: `ProjectDnsRecord` embeddable + enum, `@Embedded` on `Project`, Flyway migration
   (nullable columns) in the `projects` lineage, validation (`DnsNames`-grade fqdn check, value
   required, type enum), `ProjectService.create` signature + post-commit hook calls, the two port
   interfaces in `control/`.
2. `service/`: the two notifier implementations (fire-and-forget, instance-field HttpClient,
   receiver-named config), `CreateProjectRequest` + `ProjectDto`/mapper updates, seed config keys
   read in `SelfSeedService`, `docs/openapi.yml` regenerated.
3. Tests: creation without `dns` is a 400 and with a hostile domain is a 400; the embeddable
   round-trips through the API; both hooks fire on creation with the right payloads (recording
   fakes for the ports); the dns notifier's wire shape (zone suffix resolution, `@` vs label,
   token header, silence on no matching zone) against a local HttpServer — the
   `CdBuildNotifierTest` pattern; the seed passes dns through when configured and skips it clean
   when not; existing creation tests updated for the required parameter.

**qits-cd**: nothing. **qits-dns**: nothing — the API is already exactly the one called.

## 5. Out of scope, deliberately

- **Populating the main environment's applications** — cd can only take applications at
  environment creation; a project's repositories arrive later. Syncing repositories into the
  environment (and the add/remove-application surface cd needs first) is its own leg.
- **Zone creation** — registrar-level, stays manual per the dns plan.
- **The dedicated domain-config service** — this embeddable is its placeholder and is deleted
  when it arrives; nothing else may grow a dependency on these columns.
- **Epic environments** — the branch-per-epic flow, slug on Epic, participating-repo derivation:
  the next leg, not this one.
- **Automatic drift healing** — the hooks are fire-and-forget, and unlike an event stream a
  creation has no next event to carry a missed registration forward. The remedy, for now, is a
  MANUAL step (added after the first cut): `POST /projects/api/projects/{id}/reconcile` re-asserts
  the stored config against both services **synchronously** and answers with per-target outcomes
  (environment `CREATED`/`ALREADY_EXISTS`/`FAILED`; domain
  `REGISTERED`/`NO_MATCHING_ZONE`/`NOT_CONFIGURED`/`FAILED`) — a manual step whose result you can
  see is a remedy, a warn line in an unwatched log is not. Both receivers being idempotent is what
  makes re-asserting legitimate. It doubles as the retro-fire for pre-existing projects, the
  already-seeded qits project included. A periodic/startup reconcile can be layered on the same
  seam later if manual proves too manual.
