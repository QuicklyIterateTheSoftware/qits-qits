# Handoff — epic "Remove the platform service concept" (qits-111)

Epic id `68687654-cd64-4bec-bc4e-f3fa9fee68a1`, slug `remove-the-platform-service-concept`.
Status: **IMPLEMENTATION**. Do not mark the epic implemented — that is a person's press.

Written 2026-09-23 by the previous implementing agent. **19 of 29 tasks implemented, 13 released.**
The workspace has NOT been integrated and must not be until everything below is released.

Read `docs/development-flow.md`, then `get_epic`, then `list_dossier_pages` / `get_dossier_page`.
The dossier is read-only; where it is wrong, this file records it rather than correcting it there.

---

## 0-TODAY. STATE AT 2026-09-24 13:00 — READ THIS FIRST, IT SUPERSEDES §3 AND §4.2

Written by the agent that picked this up after the last one stopped. Three things below change what
the rest of this file tells you to do.

### The epic is further along than §1 records

**Slice D is WRITTEN and GREEN, not "NOT STARTED".** qits-deployments' epic branch carries three
commits past the `ba8db60` §1 records:

    88a1625  Pin the SPA at 2026.924.85739, the release without the plane
    f9385ad  The platform plane is deleted          ← this is qits-347, slice D
    379fe24  The catalogue answers which plane a service is on, not the file

Built from a clean tree: **BUILD SUCCESS, 59 test suites, zero failures.** It is unreleased, and
deliberately so — releasing it arms the cutover (see below), so it goes out when somebody is ready
to run that, not before. Its AGENTS.md carries the hand steps, the order they have to happen in and
the two directions the ordering bites; read "Retiring the plane's bare-named services" there before
releasing anything.

Also true, and worth knowing before you look for work that is already done: **nothing is in flight.**
Zero open release requests across every repository on the estate, and all nine qualified aliases
resolve (re-probed today). The queue §2a agonised over is empty.

### §4.2 IS VOID — NO CONSUMER READS THE DISCOVERY DOCUMENT

This is the finding that unblocks the orphan removal, so it is worth stating exactly what was
checked. §4.2 says the bare alias cannot be withdrawn until the idp's discovery document's own
endpoints move, because a consumer that discovers from the qualified address is sent back to the
bare one for JWKS and tokens. **That is true of the document and false of the estate**, because
nothing discovers:

- `quarkus.oidc.discovery-enabled=false` is set on **every** OIDC consumer on the estate — 37
  occurrences across 13 repositories, tenants and named oidc-clients alike. `discovery-enabled=true`
  appears **nowhere**.
- The only code that fetches `/.well-known/openid-configuration` is the idp's own controller that
  serves it and `MockIdp` in the test library. No service, no frontend, no CLI.
- The `qits` CLI composes `/idp/token` onto a configured base (`QITS_GIT_AUTH_TOKEN_URL`); it does
  not discover either.

So the document's endpoints are not on the critical path, and **the bare name can be withdrawn
without moving the `iss` string at all.** An `iss` is compared for equality, never dialled — §4.3
already says dual DNS buys a string comparison nothing, and the converse holds too: a claim that
names a host nobody resolves is still a claim that compares.

What DID have to move is every place that *dials* the idp. Those are enumerated in the qits-350
section below, and the edge's was the awkward one — see §12.

### The order that follows from all of the above

1. **qits-350** — every dialer derives its address; the stored rows that override it are deleted.
   In progress today, see §12.
2. **qits-351** — reduced to the edge's issuer/dial split (done, §12). Moving the `iss` STRING is
   no longer a prerequisite for anything and belongs with qits-361, where `qits-platform-idp`
   becomes `qits-idp` and the string has to change anyway.
3. **Slice D released**, then the nine hand cutovers from an admin workspace.
4. **qits-123's sweep**, last of the deployment work, for the reason §10 gives.
5. **Feature 5**, then the live verifications.

---

## 0-NEW. STATE AT 2026-09-24 08:00, AND THE TWO THINGS THAT BIT

The deployer wedge of §2a is **fixed and live** (`2026.924.4755`, installed by hand — see §2a). **All
nine** platform services now answer on BOTH their bare alias and `<env>-<application>`, and the edge
carries the grammar cutover — see §10 for the finished state; this section is how each piece got
there:

| service | qualified alias | how |
|---|---|---|
| idp, mirror, events, configuration, maintenance, orchestrator | resolve | released + deployed, one release each |
| edge | `dev-qits-platform-edge` | already had it |
| deployments | `dev-qits-deployments` | **by hand**, see below |
| system | `dev-qits-platform-system` | released 2026.924.74737; its first ask died IMAGE_MISSING during the pipeline outage below |

**The alias is `<env>-<application>`, so the three services whose application is not `qits-platform-*`
take the short spelling: `dev-qits-events`, `dev-qits-configuration`, `dev-qits-deployments`.** §4.6
below is WRONG to say those cannot be probed from this container — it was probing
`dev-qits-platform-events`, which is not a name anything ever had. All of them resolve here.

### The machine vhosts are read by the grammar too, and that took the pipeline down

`registry.<env>.localhost`, `mirror.<env>.localhost`, `githost.<env>.localhost` and
`githost.<env>.internal` are **network aliases of the edge service** (ComposeTemplate renders them in
both the seed stack and `extras.qits-platform-edge.aliases[0..3]`). None is under the public domain,
and the new right-to-left reading answers a name outside the stated domain with *"this name serves
nothing"*. So the cutover killed, at once:

- every `docker pull` (image refs are `registry.dev.localhost:8080/qits/<app>:<version>`),
- every maven build (`mirror.dev.localhost:8080`),
- every container's git (`githost.dev.internal:8080` — the oauth2 transport that turns git's Basic
  into a Bearer; the service alias `dev-qits-githost` answers 401 to the same credential).

Which means **a fixed edge could be neither built nor deployed**: the same shape as the deployer
wedge, one layer out. §4.5 checked CI recipes for public URLs and concluded the byte plane "does NOT
strand the pipeline"; it missed that these names are edge VHOSTS, so they are read by the very
grammar being changed. One `curl --resolve <name>:8080:<edge ip> http://<name>:8080/v2/` before
releasing would have caught it — that probe is the regression test a person can run, and the four
names are now pinned in `HostEnvironmentsTest`.

Recovery was a hand rollback of the edge to `2026.923.140208` (already on the node, so
`--no-resolve-image` and no registry needed). **FIXED** in `5c42190`, released as `2026.924.80607`: a
name outside the stated domain is read as `<app>[.<env>].<machine-suffix>`, the leftmost label joined
against the configured application set. Verified live after that deploy — all four answer 401 and a
real `git fetch` through `githost.dev.internal` succeeds.

### An admin workspace is how a hand step happens, and an agent can create one

    POST http://dev-qits-workspaces:8080/workspaces/api/workspaces
    {"repositoryId":"<uuid>","id":"<label>","branch":"epic/<slug>","admin":true}

`admin: true` binds the host's `/var/run/docker.sock` into the container
(`WorkspaceContainerFactory`, ADMIN MODE), decided at creation and never promotable. The create door
is `qits:admin`, so a workspace credential is refused **403** — the owner authorised using the
forward-auth headers (`X-Qits-User` + `X-Qits-Roles: qits:admin`) for this epic, which is what made
it possible from here. Then launch an agent inside it:

    POST http://dev-qits-workspaces:8080/workspaces/container/<rowId>/agents
    {"scope":"REPOSITORY","surface":"ticket.dispatch","mode":"CHAT","deliverTaskPrompt":false,
     "initialContext":"<the whole instruction>"}

Read its transcript at `…/commands/<id>/log` (JSON, `lines[].content` are transcript frames). **Give
it the SWARM SERVICE NAME, never the wire alias** — `qits_qits-deployments` (stack-prefixed),
`qits-platform-edge`, not `qits-deployments`. I burned a lap on `no such service: qits-deployments`.

Three doors that do NOT work for this, so do not spend time on them: the deployer's
`events/software-released` intake is `machineAuth.require()` and answers **401** to forward-auth
headers (it needs a real `qits:system` bearer, which a workspace client cannot mint);
`pipeline/DEPLOY/rerun` answers **503** (`qits.projects.release-requests.deployments-url` unset on the
deployed qits-projects); and no platform door replaces a service's image at all — only
`SwarmDeploymentDriver` calls `docker service update`.

### The deployer's own qualified alias, handoff §6, is closed

§6 said someone with host access had to do this. Done, 2026-09-24 07:40, and the shape matters:

    docker service update --network-rm qits-net \
      --network-add name=qits-net,alias=qits-deployments,alias=dev-qits-deployments \
      qits_qits-deployments

**Both aliases, because the deployer is stack-prefixed.** For every other platform service the bare
name is the SERVICE name and swarm publishes it for free, so the spec carries only the qualified
alias — but `qits_qits-deployments`'s bare record comes from the explicit alias compose derives from
the un-prefixed service name, and `--network-add` replaces the whole attachment. Naming only the
qualified alias would have deleted `qits-deployments` from DNS and broken every dialer on the estate.
Verified: both resolve to the same address and the API answers on both. It is a bridge, not the fix —
`PlatformModel.seedNetworks` already writes the same pair into the seed stack, so a cold bootstrap
produces it properly; a `docker stack deploy` before that lands would revert the hand alias.

---

## 0. THE ONE THING THAT CAN CAUSE DAMAGE

**LIFTED 2026-09-24 — all nine aliases resolve and this was released. Kept for the reasoning.**

**`qits-bootstrap-cli` must NOT be released until `dev-qits-platform-*` resolves.**

Two commits sit on its `epic/remove-the-platform-service-concept` branch with **no release request
open, deliberately**:

    ce947ac  Browser addresses are generated in the project-first grammar
    5d11038  Qualify every platform-service address with the environment

`5d11038` points every dialer at `dev-qits-platform-<app>`. Those names **do not resolve yet**.
Releasing it before they do configures the estate to dial names that do not exist — token
validation, config reads and service-to-service calls all fail at once.

Check before releasing it, from this container:

    getent hosts dev-qits-platform-idp

Empty output = not yet. Non-empty = safe.

**Read §4.6 before trusting that probe** — it is only valid for six of the nine services.
(And §4.6 is itself wrong about why: see §0-NEW. The other three take the short spelling.)

---

## 1. State of the branches

Every submodule is on `epic/remove-the-platform-service-concept`. Heads at handoff:

| repository | head | released? |
|---|---|---|
| qits-projects-service | `ddba2cda` landing convention in template | RR `4bc57300` gating |
| qits-edge-platform-service | `ab0964f` landing door | RR `7635564e` gating (carries grammar cutover + landing) |
| qits-deployments-platform-service | `ba8db60` recreate on missing alias | released |
| qits-bootstrap-cli | `ce947ac` | **HELD — see §0** |
| qits-workspaces-service | `18958fb` editor row readable by id | released |
| qits-workspaces-frontend | `7b6126b` | released |
| qits-workspace-daemon | `9a8d9a9` | released |
| wrapper (qits-qits) | `efa4739` project.yml | ships at workspace resolution |

Six platform-service redeploys were queued to force the alias onto the running fleet; all are
RELEASED and draining through the deployer's **single serial worker**. Both CI runs on each are
SUCCESS — the outstanding gate is DEPLOYMENT, and it is slow, not failing.

There is a local-only branch in qits-deployments:

    wip/remove-platform-service-task2   at 5ac3ecf   "WIP (does not compile)"

It is ~40% of the plane deletion (task qits-347) and **cannot be pushed** (the credential only
allows epic/feature/task refs), so it exists only in this container's volume. It is good raw
material for slice D — see §3. Do not merge it as-is; it does not compile.

---

## 2. What was done, and the one structural decision

Feature 2 ("Delete the platform plane") was **re-planned into additive slices** on the owner's
instruction, because this component is the platform's deployer: a release of it that is broken
means nothing can deploy, including the fix, and the rest of the epic becomes unreachable. The
dossier's single big-bang change was attempted first and could not be made to compile in one pass.

    A  (released)  parser stops reading deployment_target, key retained as a RETIRED tolerance
    B  (released)  PdNetworks gives a PLATFORM service <env>-<app> IN ADDITION to its bare alias
    B2 (released)  a declared alias the live service lacks forces a service rm + create
    C  (BUILT, HELD) dialers move to the qualified spelling  ← bootstrap-cli, and qits-350/351
    D  (NOT STARTED) delete PdDeploymentTarget and sweep the eighteen deployments.yml

Every release so far has been **additive — nothing deleted** — and the platform has served
throughout. Keep that property.

**Completed features:** 1 (The project declaration, 5/5, released) and 3 (One editor, 4/4,
released). Feature 4 (Hostname grammar) is 5/5 implemented with the cutover gating. Feature 6's
two implementation tasks are done; only live verification remains.

---

## 0b. THE CERTIFICATE IS NOT YET RIGHT FOR THE GRAMMAR — WATCH THIS

Measured on the live edge at handoff:

    openssl s_client -servername qits.wohlben.eu -connect qits.wohlben.eu:443 \
      | openssl x509 -noout -ext subjectAltName

    *.dev.wohlben.eu, *.qits.dev.wohlben.eu, *.qits.wohlben.eu, *.wohlben.eu, wohlben.eu

That is the **old** derivation (`2 + E + P + P·E`). The new grammar puts the environment INSIDE the
project, so the platform's own addresses become `projects.dev.qits.wohlben.eu` — which needs
**`*.dev.qits.wohlben.eu`**. The installed certificate does not have it; it has
`*.qits.dev.wohlben.eu`, the old swapped shape.

**Consequence if the grammar cutover deploys before the certificate reissues: every browser address
on the platform fails the TLS handshake.** That is the failure the dossier ordered "certificate
first, routing second" to prevent, and it is a browser page nobody can act on.

Two things make this survivable, neither of which is a guarantee:
- the certificate release (`21e3be23`) is AHEAD of the grammar release (`7635564e`) in the edge's
  serial deploy order, so it should install first;
- `EdgeCertificateManager`'s due-check is a **superset** test, so once the re-tiered code is live it
  will see `*.dev.qits.wohlben.eu` missing and place exactly one order (30s debounce).

**Verify the SAN set contains `*.dev.qits.wohlben.eu` BEFORE declaring the cutover good**, and if
the grammar has deployed while the certificate has not, that is the one situation in this epic
worth escalating to a person immediately rather than waiting out.

Note also: a staging-mode ACME check is a **no-op on a live edge** — `reconcile()` returns early
when the mode is staging and the installed certificate has a production issuer, logging "Keeping
the production edge certificate while ACME mode is staging". The dossier's suggestion to verify in
staging first cannot be followed on this platform.

---

## 2a. WHY IT WAS STUCK — SOLVED 2026-09-24, and the answer is not what is written below

**Slice A wedged the estate.** `e12f717` made `DeploymentSpecParser` hardcode the spec target to
`ENVIRONMENT`, but `DeployService.register()` still branches on `spec.target() == PLATFORM`, and
`registerInEnvironments` refuses any application the CATALOGUE holds as a platform service. So from
the moment that release went live (`2026.923.142928`, ACTIVE 14:42 on 2026-09-23) **every deployment
of all nine platform services is refused**, including qits-deployments' own next version — the
running deployer refuses to deploy its own fix.

    [refused: qits-platform-edge is a platform service and this commit asks for
     deployment_target: environment. …]

Ten such rows, read from the deployer's own API. Environment-tier apps (qits-projects,
qits-workspaces) kept deploying throughout, which is why nothing else looked wrong. The eight
release requests are not queued behind a slow worker: their DEPLOYMENT gate is `PENDING` on a
`DeploymentActive` that can never arrive, `mergedToMainAt` is null, and the images are all in the
registry with CI and PUBLISH green.

**The deployer's API IS reachable from this container** — the handoff below is wrong on that point.
The alias is bare `qits-deployments` (not `qits-platform-deployments`), and its reads take
forward-auth headers:

    curl -H 'X-Qits-User: agent' -H 'X-Qits-Roles: qits:admin' \
      'http://qits-deployments:8080/platform-deployments/api/deployments?environmentId=platform'

Two more corrections worth having:

- **A RELEASED-but-unfinalized request does NOT block the repository.** `ReleaseRequests.request`
  reads `UNRELEASED`, and a RELEASED request cannot be joined because its content is already tagged
  — a fresh ask mints a new request. So a stranded release is cleared by re-releasing the branch,
  not by withdrawing (`withdraw` answers 409 on a RELEASED request anyway). The six redeploy
  releases already deleted their epic branches on origin; the local branches still carry the
  content, so a push recreates each one.
- **`pipeline/{phase}/rerun` is `qits:agent`-allowed** (the note saying it needs admin is stale),
  but `DEPLOY` answers **503** on this estate: `qits.projects.release-requests.deployments-url` is
  not configured on the deployed qits-projects, so a deploy cannot be re-fired from there.

**The one thing that needs a person: installing a fixed deployer image by hand.** Nothing else
installs images, so the loop cannot be opened from inside.

    docker service update --image qits-platform-artifacts:8080/qits/qits-deployments:<version> qits-deployments

The startup sweep adopts what is running (`[adopted at startup: …]` on the current row), so this is
an ordinary path and not a special one. **Do not install `2026.923.160704`** — that image carries
the defect and re-wedges the estate.

**Do not run the qits-123 sweep until the fixed deployer is live and settled.** Removing
`deployment_target:` from the eighteen files makes a pre-slice-A deployer parse every spec as
ENVIRONMENT, which is the same wedge from the other direction — the sweep burns the rollback.

Everything from here to the end of this section is the previous agent's diagnosis, kept because it
records what the evidence looked like before the deployer's API was read. Its conclusion — a slow
serial deploy worker — is wrong.

Established at handoff, 2026-09-23 ~18:40:

- Slice **A+B** (`b8397e4e`) has **FINALIZED** — the deployer declares the qualified alias.
- Slice **B2** (`eee462d8`, version `2026.923.160704`) released at **16:07** and is **still
  RELEASED 2.5 hours later**. Both its CI runs are SUCCESS (`4a29ec1b`, `90603106`). The
  outstanding gate is DEPLOYMENT.

**This is why no alias has appeared, and the causation is exact.** With B live but B2 not, the
deployer *declares* the `<env>-<app>` alias but does not yet *recreate* a live service that lacks
one. An ordinary deployment is a swarm **update**, and an update restates no networks — so the six
redeploys I queued are landing as updates and granting no alias. That is correct behaviour for the
code that is actually running, not a fault.

**Everything downstream hangs on `eee462d8` finalizing.** Until it does, re-queuing redeploys
achieves nothing — they will keep landing as updates. Do not fire more.

Likely cause of the delay, not confirmed: the deploy worker is single-threaded and platform-wide,
and I queued six redeploys into it at 16:54–17:23 on top of B2's own self-deploy. A self-update is
`HANDED_OFF` and settled by the successor's startup sweep, so it can also sit in `STARTING` for a
while by design. 2.5 hours is at the long end of plausible.

If it has not moved when you pick this up, that is the first thing to investigate — and note you
**cannot reach the deployer's API from this container**: `qits-platform-deployments` has no DNS
here, and the public edge refuses forwarded `X-Qits-User`/`X-Qits-Roles` on an application vhost
(`https://deployments.dev.wohlben.eu` answers `UNAUTHORIZED`). You will need either host access or
a container that is on that network.

### This probably needs a person

By the end of the handoff session the queue had not advanced in ~2.5 hours: `eee462d8` still
RELEASED, the certificate SAN set unchanged, no qualified alias, and **eight** release requests
across the epic sitting on deployment gates with every CI gate green. Nothing is REJECTED or
FAILED — they are all simply not being deployed.

Three doors that would diagnose or clear it are all shut to a `qits:agent` credential:

- the deployer's read surface (no DNS here; the edge refuses the forwarded-header route);
- re-running a died gate — `pipeline/{phase}/rerun` needs `qits:admin`;
- any redeploy/restart verb — `qits --help` lists none for this credential.

So if the queue is genuinely wedged rather than slow, **escalate to a person** rather than
withdrawing and re-filing: `withdraw` is final, and a wedged deploy worker is not fixed by a new
request. Do NOT queue further redeploys — with B live and B2 not, they land as updates and grant
no alias, so they only lengthen the queue that is already the problem.

---

## 3. What remains (10 tasks)

### Immediate, and it unblocks everything else
Wait for the six redeploys to finalize, then confirm:

    for h in dev-qits-platform-idp dev-qits-platform-mirror dev-qits-platform-events \
             dev-qits-platform-configuration dev-qits-platform-maintenance \
             dev-qits-platform-orchestrator; do
      printf "%-36s " "$h"; getent hosts $h >/dev/null 2>&1 && echo RESOLVES || echo "-"
    done

Once they resolve:
1. Release `qits-bootstrap-cli` (§0 lifted). This is slice C.
2. **qits-350** — qits-configuration service-to-service URLs to the qualified spelling. Lands
   through `ComposeTemplate`'s bootstrap declarations, never an ad-hoc config PUT (the next
   bootstrap overwrites those).
3. **qits-351** — the idp issuer. **Read §4.2 first; this is not a simple address move.**
4. **qits-347 + qits-123** — slice D: delete `PdDeploymentTarget` and everything downstream, then
   sweep `deployment_target:` from the eighteen `deployments.yml`. Start from `5ac3ecf`.
   **Blocked on §4.2** — the bare alias cannot be withdrawn until the issuer moves.
5. **qits-126** — cold bootstrap, the acceptance test for Feature 2.
6. **qits-134** — verify the grammar cutover live. **Read §4.4** — part of it cannot pass until
   the workspace resolves.
7. **Feature 5** (qits-135, 138, 360, 361, 362) — seventeen repository renames, the package root,
   the config namespace, `PdEnvironment.platform` → `designated`, and the two prose tasks.
   Depends on Feature 2 completing. The two prose tasks (qits-138 wrapper `CLAUDE.md`, qits-362
   project template `components/README.md`) are ordered **last on purpose**: writing "platform is
   no longer a tier modifier" while seventeen repositories still carry it ships documentation that
   contradicts the estate.
8. **qits-330** — verify the landing door live. Also needs `qits-landing-app` deployed, which is
   epic 53095bee's deliverable, not this one's.

---

## 4. Findings the dossier does not contain

All five were found by probing the running platform, not by reading. Each cost real time.

### 4.1 A declared alias reaches a service only on its OWN next deploy
`buildUpdateArgv` deliberately states no networks, and swarm restates a network attachment whole
or not at all. The repo's own javadoc says it: *"a declared alias reaches a LIVE service only on
its next create."* Verified live — `qits-platform-idp` resolved while `dev-qits-platform-idp` did
not. This is why slice B2 exists and why six redeploys were queued.

Deploying a *reader* does not recreate the *target*. So "redeploy the nine, then move the config"
is a hard ordering, not a suggestion.

### 4.2 The idp discovery document sends consumers back to the BARE address
Measured:

    curl -s http://qits-platform-idp:8080/idp/.well-known/openid-configuration

returns `issuer`, `jwks_uri` AND `token_endpoint` all at the **bare** `qits-platform-idp`. So
"dial qualified, validate bare" works — but a consumer that discovers from the qualified address
is then sent back to the bare one for JWKS and tokens.

**Consequence: the bare alias cannot be withdrawn until the issuer and the document's own
endpoints move.** That couples qits-351 to slice D; the dossier treats them as independent.

### 4.3 `QITS_IDP_ISSUER` is not an address and must not move with the others
It is the `iss` claim, stamped into every token and compared **for equality** by every consumer.
Dual DNS resolution buys a string comparison nothing, and the key cannot hold two values. Moving
it rejects every token in flight, estate-wide, at once.

The bootstrap work split `${IDP}` (issuer, still bare) from `${IDP_DIAL}` (address, qualified) so
consumers now *discover* from the qualified address while validating the old issuer string. That
is the enabling step: the issuer can then move on its own. **Do not re-merge those two concepts** —
`AGENTS.md` in qits-bootstrap-cli records the rule.

### 4.4 The grammar cutover lands in two steps, and one dossier task cannot pass until the end
On the live platform the `qits` project still has `supportsEnvironments = true`, because the
wrapper's `.config/qits/project.yml` declaring `false` only ships when the workspace resolves —
and task qits-121 explicitly forbids anything depending on it earlier.

So addresses are `<app>.dev.qits.<domain>` now, and become `<app>.qits.<domain>` only after the
workspace resolves and a `ProjectChanged` frame flips the flag.

**qits-134 asks for `projects.qits.wohlben.eu` to serve**, which needs that flag. It therefore
cannot fully pass until the workspace resolves. Plan the verification in two parts, or accept that
its last assertions are the post-resolution state.

DNS is not in the way — verified, every depth resolves to the edge:

    projects.dev.wohlben.eu / projects.qits.wohlben.eu /
    projects.dev.qits.wohlben.eu / anything.deep.qits.wohlben.eu   → 46.224.171.33

### 4.6 The `getent` alias probe is only valid for SIX of the nine services
This workspace container is not attached to every network. Measured here:

| bare alias resolves from this container | does not |
|---|---|
| idp, mirror, edge, system, orchestrator, maintenance | **events, configuration, deployments** |

For those three, `getent hosts dev-qits-platform-configuration` will return empty **forever**,
whether or not the alias exists — it is a network-attachment fact, not a statement about the
alias. Do not read it as failure. `qits-platform-deployments` has no DNS here at all while
`https://deployments.dev.wohlben.eu` answers 401, which is how this was established.

So probe the alias on a service you can actually reach — **idp and mirror are the good ones**,
since both are in the redeploy set:

    getent hosts dev-qits-platform-idp
    getent hosts dev-qits-platform-mirror

For events, configuration and deployments, confirm through the release request finalizing
(disappearing from `qits release-request list`) rather than through DNS.

### 4.5 The byte plane has no project label
`registry.<env>.…`, `mirror.<env>.…`, `githost.<env>.…` carry no project label, so under the new
positional reading they read as UNKNOWN_PROJECT. These are machine names — dockerd
`insecure-registries`, Dockerfile `FROM`, clone urls, `QITS_CI_DOCKER_AUTH_HOSTS`.

**Checked before letting the cutover proceed, and it does NOT strand the pipeline:** CI recipes
hardcode no public URLs (they use in-network aliases like `dev-qits-artifacts:8080`), and the
real-domain occurrences are confined to `qits-platform-access-cli`'s docs, defaults and tests —
which derive the githost from the idp host (`idp` swapped for `githost`), so they follow the
cutover automatically. It remains unfinished business for human-facing addresses, and it is not
in any task on this epic.

---

## 5. Where the dossier asks for something that cannot be delivered as written

The dossier is read-only during implementation, so these are recorded rather than corrected.

**qits-348 — "Deleted, not parsed-and-ignored."** `DeploymentSpecParser` refuses unknown keys, and
a spec is fetched at the **built sha** — so a rollback pin or a redeploy of any older commit
presents a file carrying `deployment_target:`. Strict deletion would make every historical sha
permanently undeployable, not merely for the sweep window. The key is therefore retained as a
RETIRED tolerance (accepted, unvalidated, reaching nothing, marked RETIRED in the header) while the
*concept* is deleted everywhere a person reads it. The task's stated reason — the `deployments.yml`
files a person reads — is served.

**qits-328 — "Log an ERROR naming the project, the label and both applications."** The edge cannot
name the project: `DeploymentActive` carries `applicationName` and `environmentName` and nothing
else, so the projection has no project axis at all. The ERROR names the environment, the label and
both applications instead. The same blindness means `serviceHost(env, host)` is project-blind, so a
`landing` published in an environment is that environment's landing for **every** project — exactly
as two projects' `ci` apps would already collide. Harmless at one project; real at two.
Project-scoping that projection is a larger change than the task and was not started.

---

## 6. A gap that needs host access this container does not have

`SwarmDeploymentDriver` exempts a **self-update** from the recreate path — correctly, since there
would be nothing left to create the successor. So **`qits-platform-deployments` can never gain its
own tier-qualified alias** through slice B2's mechanism.

The repository's own `README.md` already documents the one-time hand step for exactly this shape
during the plane flip:

    docker service rm <env>-qits-deployments    # once the successor is healthy

Someone with host access has to do the equivalent for the deployer, or it keeps only its bare name.
Flagging rather than working around it.

---

## 7. Working rules that cost time to learn

- **Never pipe a build through `tail`/`grep` and trust `$?`.** The pipe returns the *filter's*
  exit code. This produced a false green twice. Redirect to a file, `echo "EXIT=$?"`, read it.
- **Never run your own verification build while a subagent is building the same tree.** Two
  `clean verify` runs in one `target/` delete each other's classes; the symptom is
  `ClassNotFoundException` and `IllegalAccessError` with a classloader mismatch, which reads
  exactly like a real defect. Cost one wasted diagnosis here.
- **`-pl <module>` without `-am` builds a module's dependencies, not its dependents.** It once
  reported 136 green while `service/` had four real failures.
- **`mvn compile` without `clean`** reported BUILD SUCCESS against stale classes over sixteen
  genuine compile errors.
- **`origin/main` lags.** Main only moves when a release FINALIZES, so the newest release tag is
  often not an ancestor of main. When a release consumes the epic branch, rebase onto the newest
  **tag**, not onto `origin/main`.
- **A release deletes its source branches.** The next push recreates the branch and needs its own
  request. A push *during* gating refolds the open request instead — which is useful, and is how
  the landing-door commit joined the grammar cutover's request.
- **Never `git add -A` in the wrapper.** `ignore = all` hides moved gitlinks from `status` and
  `diff` but not from `add -A`. Commit explicit paths.
- **Verification is not delegated.** Build it yourself, read the reactor summary and the counts,
  read the diff. A subagent's report is a claim.

---

## 8. Useful commands

    # what is open
    qits release-request list --project qits --repository <repo>

    # CI runs for a request (both --project and --repository are required)
    qits ci runs --project qits --repository <repo> --release-request <id>

    # release
    qits release-request create --project qits --repository <repo> \
      --branch epic/remove-the-platform-service-concept --summary '<what this release is>'

    # the alias probe — the live proof of slices B and B2
    getent hosts dev-qits-platform-idp

    # the idp discovery document (see §4.2)
    curl -s http://qits-platform-idp:8080/idp/.well-known/openid-configuration

---

## 9. Finishing

The workspace is resolved **last**, and only once every component is released and the epic is
transitioned to VERIFIED. For this wrapper that means its own release request — a release deletes
its source branches, and a workspace branch that is gone is a workspace that is resolved.

Note the wrapper carries real content for this epic: `.config/qits/project.yml` (`efa4739`, already
committed) and, once Feature 5 lands, the `CLAUDE.md` grammar sentence. Both ship at resolution,
which is also what finally flips `supportsEnvironments` to false and completes §4.4.

---

## 10. What 2026-09-24 landed, and where the epic actually is

Written by the agent that unwedged the deployer. Read §0-NEW and §2a first; this is the state that
followed from them.

**Feature 2's wire-address groundwork is COMPLETE on the estate.** All nine platform services answer
on both names — the bare alias they always had and `<env>-<application>` — so no dialer has been
forced to move and none can break by moving:

    for a in dev-qits-platform-idp dev-qits-platform-mirror dev-qits-platform-maintenance \
             dev-qits-platform-orchestrator dev-qits-platform-system dev-qits-platform-edge \
             dev-qits-events dev-qits-configuration dev-qits-deployments; do
      printf "%-32s " $a; getent hosts $a >/dev/null && echo RESOLVES || echo MISSING
    done

Eight arrived by releasing each repository once (six carried nothing but an empty commit — the
deployment IS the change, because an alias reaches a live service only on its own next deploy); the
ninth, the deployer's, is the hand step in §0-NEW.

**Feature 4's cutover is LIVE** (qits-edge `2026.924.80607`). Verified:

| name | answer | meaning |
|---|---|---|
| `projects.dev.qits.wohlben.eu` | 401, TLS clean | the new grammar serves |
| `qits.wohlben.eu` | 302 | the project door; becomes the landing app when 53095bee ships |
| `editor.dev.qits.wohlben.eu` | 401 | the editor as an ordinary app vhost |
| `projects.dev.wohlben.eu` | TLS failure | the old name, and see the warning below |
| SAN | `wohlben.eu, *.wohlben.eu, *.qits.wohlben.eu, *.dev.qits.wohlben.eu` | the `2 + P` derivation |

**qits-134 says the old name "404s. No redirect." It does not 404 — it fails the TLS handshake**,
because the new SAN set deliberately drops the `*.<env>.<domain>` tier, so there is no certificate to
complete a handshake with before a 404 could be sent. That is a consequence of `2 + P` and not a
defect, but the task's wording cannot be satisfied as written and somebody should decide whether it
wants rewording or whether the old tier stays on the certificate for a deprecation window.

`editor.qits.wohlben.eu` still 404s and `projects.qits.wohlben.eu` is not yet the address: both need
`supportsEnvironments: false`, which ships when the workspace resolves (§4.4). That part of qits-134
can only be checked after resolution — plan it as the last verification, not a blocker.

### The order these have to keep

1. ~~deployer fix~~, ~~the nine aliases~~, ~~grammar cutover~~ — done.
2. **qits-bootstrap-cli** (slice C) — released 2026-09-24. Note what it does NOT do: its entries reach
   the estate when a bootstrap RUNS, not when the CLI releases, so every dialer is still on the bare
   alias until then. That is why the bare aliases must stay until the cold bootstrap (qits-126).
3. **qits-350** is then a VERIFICATION, not an edit: the qualified URLs are already in
   `ComposeTemplate`'s extras. Read the running container's env after the bootstrap rather than
   writing anything.
4. **qits-351, the idp issuer** — still the most dangerous change in the epic. §4.2/§4.3 stand: the
   issuer is compared for equality, the discovery document sends consumers back to the bare address,
   and the bare alias cannot be withdrawn until both move.
5. **Slice D (qits-347)** deletes the plane. It removes the bare alias, so it may only land after a
   bootstrap has moved every dialer to the qualified spelling, and it needs a hand step for the
   deployer again (a self-update cannot recreate the service doing the updating).
6. **qits-123's sweep** stays last of the deployment work: while it is undone, a pre-slice-A deployer
   remains a valid rollback, and the sweep is what burns that.

### The issuer must move BEFORE any bare name is removed (found 2026-09-24, slice D)

Slice D renames each service's wire alias to `<env>-<application>` and, because the predecessor
lookup is `serviceExists(spec.wireAlias())` against a service NAME while the running service merely
carries that name as a network ALIAS, the old bare-named swarm service is **not found and not
retired**. It keeps running and keeps answering the bare name. That orphan is a nuisance — and it is
also the only reason the estate survives the release, because:

- **the idp discovery document still sends every consumer to the bare address** for `jwks_uri` and
  `token_endpoint` (§4.2), so the moment `qits-platform-idp` stops resolving, JWKS fetches fail and
  every request on the platform fails with it;
- `HttpIdpClientProvisioner.baseUrl` in qits-deployments is a bare `qits-platform-idp` too — the
  `IdpClientProvisioner` seam carries no tier, so qualifying it means widening all three of its
  verbs. Documented in that class and in AGENTS.md.

So the order is forced, and it is the opposite of "tidy up the orphans after the release":

    slice D releases  →  new services under the qualified names, old bare-named ones still serving
                      →  qits-351 moves the issuer and the discovery document's own endpoints
                      →  the idp client seam is widened
                      →  ONLY THEN remove the bare-named services by hand

Removing an orphan early is not tidying up; it is switching off the address every token validation
still resolves through. The orphans with a host-mode published port or a single-writer volume are the
exception in the other direction — those must go BEFORE their successor deploys, or the successor's
task sits `Pending` on the port, or two tasks share one postgres volume, which is the WAL corruption
this estate has already paid for twice. Read each of the nine before moving it.

**qits-deployments' own self-update exemption stops firing** after slice D: `apply` compares
`ownServiceName()` (`qits-deployments`) against the new alias (`dev-qits-deployments`), so it is no
longer recognised as itself and would create a second deployer beside the running one. Its cutover is
a hand step from an admin workspace — inspect the live spec, `service rm`, `service create` — and it
is written up in the repo's AGENTS.md.

---

## 11. THE OWNER'S CONFIG RULE, and what it did to qits-350 (2026-09-24)

**Ruled by the owner, and it overrides the dossier's approach:** almost nothing belongs in
qits-configuration. Only genuinely ENVIRONMENT-SPECIFIC values do; secrets belong in the
qits-deployments DB; everything else is hardcoded in the service.

Two of my working assumptions were wrong and are corrected here so nobody rebuilds them:

- **There is no bootstrap run, and config does not arrive by bootstrapping.** `qits-bootstrap` is for
  bringing a platform UP. A running platform's config lives in qits-configuration and the deployer
  applies it at each deploy. I had "wait for a bootstrap" as a blocker across half this plan; it was
  never one, and qits-126's cold run is a different thing entirely — the owner's position is that we
  are not deleting and rebuilding the platform to satisfy an acceptance task.
- **qits-350 is therefore not "move 73 entries to the qualified spelling".** It is: the service derives
  the address, and the entry stops existing. `QITS_ENVIRONMENT` is injected into every container
  (`BootResourceRegistration.ENVIRONMENT_VARIABLE`), so

      quarkus.oidc.auth-server-url=http://${QITS_ENVIRONMENT:dev}-qits-platform-idp:8080/idp

  is the whole mechanism. It is strictly better for this epic than editing entries: the bare→qualified
  cutover becomes a property default, and Feature 5's rename to `<env>-qits-idp` lands the same way
  with nothing to chase a second time.

### The inventory, measured on the live platform

**73 entries across 13 applications** name one of the nine by its bare alias. By target:
41 idp, 24 orchestrator, 12 deployments, 10 maintenance, 7 events, 6 configuration, 5 mirror,
3 system, 2 edge. By application: orchestrator 17, idp 12, projects 9, deployments 7, workspaces 6,
maintenance 6, ci 5, system 2, edge 2, containers 2, configuration 2, artifacts 2, githost 1.

Read it back for one application with:

    curl -s -H 'X-Qits-User: <you>' -H 'X-Qits-Roles: qits:admin' \
      'http://qits-configuration:8080/configuration/api/applications/<app>/envs/dev/resolved'

(The route is `/applications/{application}/envs/{env}/resolved` — `/applications/{app}/entries` is a
404, which reads like the application having no config.)

**An entry beats a property**, so changing the default alone changes nothing on a deployed container:
the entry has to be deleted as well, and the container redeployed. Deleting first is safe in either
order, because a container's env is frozen at creation and both aliases resolve today.

### Three things NOT to fold into this

- **`QITS_IDP_CLIENTS` and the `QITS_IDP_CLIENT_*_AUDIENCES` lists** name client ids and audiences,
  not addresses. They look derivable and are not: an audience is a security decision. Note the live
  keys are inconsistent already — `QITS_IDP_CLIENT_QITS_DEPLOYMENTS_AUDIENCES` (bare) sits beside
  `QITS_IDP_CLIENT_DEV_QITS_CI_AUDIENCES` (qualified) — so renaming them has re-commissioning
  consequences and wants its own change.
- **A live client secret is in qits-configuration**, not in the deployments DB:
  `QUARKUS_OIDC_CLIENT_CREDENTIALS_SECRET` on `qits-ci` (and the githost client's copy beside it).
  That contradicts the rule above and is worth its own ticket; moving a live secret is not an address
  cleanup.
- **`quarkus.oidc.token.issuer` and anything that IS the `iss` claim.** Still §4.3: compared for
  equality, so moving it rejects every token in flight at once.

### §11 ADDENDUM (2026-09-24 13:00): the inventory had a mechanism in it nobody had looked at

§11 counts 73 entries and treats them all as stored rows somebody wrote. **Some of them are not
stored at all — they are RENDERED**, and that half is fixed in code rather than by deleting rows.

`qits-configuration` supports a declared key of type `serviceAddress` (`.config/qits/configuration.yml`
in the addressing repository: `{type: serviceAddress, service: <application>, port: <n>}`). Its value
is never read from the store — `ConfigurationService.renderAddress` composes it per environment at
every resolved read, and a stored row on such a key is ignored and reported `orphaned`. That renderer
**branched on the addressed application's plane**: bare alias for a platform-plane target,
`<env>-<application>` for an environment one, and a target that had declared no plane at all was a
422 naming it.

Three things follow, and only the first is obvious:

- The branch is deleted. One shape of alias, derived from the env and the name, no lookup.
- **The 422 was a live trap.** Five of the nine former platform services — idp, mirror, events,
  system, edge — have no governing declaration on this platform at all, so any `serviceAddress`
  pointing at one of them answered 422 rather than an address. Deleting the lookup removes that.
- It changes nothing on the estate TODAY, and that is worth knowing rather than discovering:
  `serviceAddress` is declared in exactly one repository (qits-docs, for `QITS_DOCS_ARTIFACTS_URL`
  and `QITS_OBSERVABILITY_URL`), and both of its targets are environment applications, so the
  platform arm never fired in production. It is correctness and a trap removed, not a cutover.

The rest of the 73 ARE stored rows, and §11's rule applies to them unchanged.

### One finding that makes qits-351 cheaper than the dossier thinks

qits-ci sets `quarkus.oidc.discovery-enabled=false` and gives the JWKS path explicitly, joined onto
`auth-server-url`. For every consumer shaped that way, §4.2's "the discovery document sends consumers
back to the bare address" **does not apply** — the consumer never reads the document. Moving the fetch
address is then sufficient and the issuer string stays independent. Check each consumer for that
setting before assuming the issuer must move first.

---

## 12. WHAT qits-350 AND qits-351 ACTUALLY CHANGED (2026-09-24)

### The rule, restated so the next reader does not re-derive it

`QITS_ENVIRONMENT` is injected into every container (`BootResourceRegistration.ENVIRONMENT_VARIABLE`),
so a service DERIVES the tier's peer rather than being told it:

    quarkus.oidc.auth-server-url=http://${QITS_ENVIRONMENT:dev}-qits-platform-idp:8080/idp

and the qits-configuration row that used to state it is deleted. **An entry beats a property**, so
neither half works alone. Deleting first is safe in either order (a deployed container's env is
frozen at creation, and both aliases resolve today), which is why the rows go first and the releases
follow — one deploy per application instead of two.

The edge is the exception in one place: `qits.edge.apps.<app>.host-pattern` uses `{env}`, the EDGE's
OWN placeholder substituted per request in `EdgeRouter.appUpstream`, NOT Quarkus expansion.
`${QITS_ENVIRONMENT}` there would resolve once at startup and name a tier rather than the requested
one. The mirror's pattern is `{env}-qits-platform-mirror`.

### Every shipped default that moved

| repository | key |
|---|---|
| qits-artifacts | `quarkus.oidc.auth-server-url`; gc `pins.cd-base-url`, `pins.maintenance-base-url`, `pins.configuration-base-url` |
| qits-containers | `quarkus.oidc.auth-server-url`; buildkit `registry-mirrors` + `http-registries` |
| qits-events | `quarkus.oidc.auth-server-url` |
| qits-githost | `quarkus.oidc.auth-server-url` |
| qits-maintenance | `quarkus.oidc.auth-server-url`; `oidc-client.qits` + `oidc-client.projects` auth-server-url; `mirror.maven-url`, `mirror.npm-url`; `registries.{maven,npm,oci}-url` |
| qits-mirror | `quarkus.oidc.auth-server-url` |
| qits-observability | `quarkus.oidc.auth-server-url` |
| qits-system | `quarkus.oidc.auth-server-url` |
| qits-deployments | `quarkus.oidc.auth-server-url`, `oidc-client.configuration.auth-server-url` |
| qits-edge | `qits.edge.apps.mirror.host-pattern`; NEW `qits.idp.dial-url` |
| qits-configuration | `ConfigurationService.renderAddress` — the plane branch deleted |
| qits-eventstream-javalib | `qits.events.url` |

**qits-containers' buildkit lines also had a hardcoded `dev-` for the registry** — not a plane
artefact, just a literal tier — and it is derived now too. Same for qits-maintenance's
`registries.*-url`, which named a bare `qits-artifacts` that resolves nowhere on a tiered estate and
only worked because a deployment override covered it.

### The two that are DELIBERATELY still bare, and must stay that way

- `quarkus.oidc.token.issuer` (qits-events, qits-observability) and `qits.idp.issuer` (qits-idp).
  These ARE the `iss` claim. §4.3.
- `qits.idp.url` in qits-edge. Same reason — and see the split below, which is what let the edge's
  DIAL address move without it.

### qits-351, and why it came out small

The edge had ONE key doing two jobs: `qits.idp.url` was both the `iss` it compares tokens against
(`EdgeAuth`) and the base it dials for `/jwks`, `/token` and `/api/sessions/introspect` (`IdpKeys`,
`IdpGrants`, the session introspection). Moving it would have moved the claim; not moving it would
have left the edge dialling a name that is about to stop existing.

So `Idp` now reads two keys — `qits.idp.url` (the claim, unchanged and still bare) and
`qits.idp.dial-url` (the address, derived and qualified) — with the dial falling back to the issuer
when unset, which is what makes the split additive. That is the same split qits-bootstrap-cli made
between `${IDP}` and `${IDP_DIAL}`, and **DO NOT RE-MERGE THEM**: they read identically on a platform
that has not cut over, which is exactly how somebody tidying up collapses them back into one.
`IdpTest` exists to fail if that happens — every case sets the two to different hosts.

With that and §4.2's voiding, **moving the `iss` string is no longer a prerequisite for withdrawing
the bare names.** It should ride qits-361, where `qits-platform-idp` becomes `qits-idp` and the
string has to change regardless; the consumers to move in that one window are exactly three —
qits-events, qits-observability (`quarkus.oidc.token.issuer`) and qits-edge (`qits.idp.url`) —
because nobody else validates `iss` at all.

### The live half: 40 rows

`/tmp/cfgmove.py` (dry-run by default, `--apply` to write) holds the disposition of every stored row
that names one of the nine by a bare alias: **33 DELETE** — the service derives it now — and **7
UPDATE** to the qualified spelling, because no default can answer for them yet:

- `QITS_EVENTS_URL` on six applications. Its default lives in qits-eventstream-javalib, so consumers
  only pick it up after a dependency bump reaches each one, and the cutover must not wait on that
  chain.
- `QITS_WORKSPACE_NPM_PROXY_URL`, whose shipped default is deliberately EMPTY.

One thing checked before the deletes were written down, because getting it wrong is a boot failure:
seven of the rows feed oidc-clients that have **no shipped `auth-server-url` at all**
(orchestrator's `ci`/`containers`/`deployments`/`projects`/`workspaces`, qits-ci's `githost`,
qits-workspaces' `githost` and `projects`). Every one of those clients is `client-enabled=false` —
they are the neutralised legacy blocks — so the rows reach a disabled client and deleting them is
removing dead config rather than starving a live one. Note the standing rule that goes with it:
**delete the entries before the neutralising lines**, never the other way round, because the env var
alone is enough to mint a dialling client.

### A trap that cost a diagnosis here

`MAVEN_ARGS=-s /etc/qits/maven-settings.xml` is already in this container's environment. Passing your
own `-s` overrides it, and a path that does not exist costs every credential silently: the maven
registry answers **401**, and surefire surfaces that as **"Could not load class ... during test
discovery"**, which reads exactly like a broken build rather than a missing settings file. Run
`./mvnw -B clean verify` with no `-s` at all.

And the one from §7 confirmed again: **one repository at a time.** Two concurrent Quarkus reactors on
this container starve the forked surefire JVMs and produce the same ClassNotFoundException.

---

## 13. TWO THINGS TO KNOW BEFORE FEATURE 5 IS PLANNED (2026-09-24)

Not started, but both were established while doing qits-350 and both change how big a task looks.

**qits-360's config-namespace rename is NOT a data migration, and it looks like one.** The live rows
read back as `qits.platform.deployments.extras.<app>.env.<KEY>`, which invites the conclusion that
every stored key has to be rewritten. It does not: the stored key is the SUFFIX (`env.QITS_EVENTS_URL`
— that is what the entries API path takes), and `ExtrasProperties.PREFIX` composes the rest at
RESOLVE time. So `qits.platform.deployments.*` -> `qits.deployments.*` is a constant in two
repositories that must move in the same window (qits-configuration's `ExtrasProperties` and
qits-deployments' own `@ConfigMapping` namespace), and the store is untouched.

The one thing that DOES need checking with it is the import path: `ImportController` parses
`qits.platform.deployments.extras.<application>.<key>=<value>` lines and strips the prefix to get the
stored key. It has to keep accepting the old spelling for as long as anything sends it, on the same
RETIRED-tolerance reasoning as `deployment_target` — a bootstrap file is read at a version, and older
ones state the old prefix forever.

**qits-361 is the THIRD wire-address cutover of the same nine swarm services**, and under swarm a
rename is a `service rm` + `service create`. Slice D's cutover is the second. The epic's decision
records both deliberately ("Wire addresses twice ... then `dev-qits-idp` when the repository is
renamed") and forbids the two windows being open at once, so they stay sequential — but somebody
should decide knowingly whether the estate takes the identical nine-service rm-and-create twice or
whether qits-361's rename rides slice D's window. Doing them together halves the exposure; doing
them apart is what the dossier says. It is an owner's call and it is not recorded anywhere yet.

The `iss` string moves in that same window (see §12), and the consumers that compare it are exactly
three: qits-events, qits-observability, qits-edge.

---

## 14. WHERE THIS SESSION LEFT IT (2026-09-24, ~13:55)

### qits-350 and qits-351 are BUILT, COMMITTED, PUSHED and RELEASE-REQUESTED

Sixteen repositories were committed on `epic/remove-the-platform-service-concept`; fifteen have an
open release request, all PENDING as of writing. Every one of the sixteen was built green from a
clean tree, one at a time, before anything was committed.

**qits-deployments is committed and pushed but deliberately has NO release request.** Its branch
carries slice D, so asking for it arms the nine-service cutover. It is the LAST of this group to be
released, and only once the other fifteen are live. Its commit message says so too.

### The 40 config rows are applied

`/tmp/cfgmove.py` ran with `--apply`: 33 rows deleted, 7 updated, all 204/200. Re-inventoried
afterwards against every application: **no stored row anywhere on the platform still names one of the
nine by a bare alias as an ADDRESS.** What is left, and is correct to leave, is exactly §11's three
categories — client ids (`QUARKUS_OIDC_CLIENT_*_CLIENT_ID`), audiences (`QITS_AUTH_MACHINE_AUDIENCE`,
`QITS_IDP_CLIENT_*_AUDIENCES`), the `QITS_IDP_ISSUER` claim, and one volume name on
qits-platform-system's mounts.

Note the deletions take effect at each application's NEXT deploy, which its own release request is.
Until then the running containers keep their frozen env, which still names a bare alias — and that
still resolves, because the orphans are not retired yet. That is the whole reason this order is safe.

### Two test findings worth keeping

**qits-workspaces holds a rule no sibling does.** `OwnDeclarationTest.everyRawEnvNameThisServiceInterpolatesIsDeclared`
asserts that every raw env name the shipped config interpolates is declared in
`.config/qits/configuration.yml`, exempting `QITS_RESOURCE_*` as "the deployer's to inject and
configuration's never to state". Introducing `${QITS_ENVIRONMENT:dev}` broke it. **Declaring the
variable would have been the wrong fix** — a declared key is one an operator may set, and there is no
entry behind it on any application (checked: qits-workspaces, qits-ci and qits-projects all have
zero), so it would report `orphaned` forever, which is the confusion the rest of that test exists to
prevent. `QITS_ENVIRONMENT` joins the exemption instead, for the identical reason, with
`BootResourceRegistration.ENVIRONMENT_VARIABLE` named as what injects it. qits-ci's and
qits-projects' `OwnDeclarationTest`s carry no equivalent check, which is why they have derived
addresses for some time without ever hitting this.

**qits-containers had a test that could not fail.** `PlatformBuildkitTest` assigns `registryMirrors`
and `httpRegistries` as fixtures on a hand-built `PlatformBuildkit`, so a bare alias could be
restored to `META-INF/microprofile-config.properties` with every assertion in that suite still
passing — and that file is what every image build on the platform dials. `BuildkitShippedConfigTest`
is new and reads the shipped config: the resolved values AND the raw property text, because an
assertion on the resolved string alone would pass against a file with `dev-` typed back in.

### Two flakes, verified as flakes rather than assumed

`ForeignPtyTest.closingTheMasterHangsUpTheChild` (qits-system, qits-projects) and
`TerminalSessionTest`'s two terminate cases failed under concurrent builds — 30-second hangup
assertions, and one child taking SIGKILL's 143 where it expected a graceful 7. Both repositories were
re-run alone on a quiet machine and both are **BUILD SUCCESS**. If you see these again, look at load
before looking at the code — but re-run, do not assume.

### What is next, in order

1. **Watch the fifteen finalize.** A deployable finalizes only when the deployer reports it live, and
   the deploy worker is serial and platform-wide, so this is hours rather than minutes.
2. **Then release qits-deployments** — slice D — and run the nine hand cutovers from an admin
   workspace, per its AGENTS.md "Retiring the plane's bare-named services". Remove a service holding
   a host port or a single-writer volume BEFORE its successor deploys; leave every other one until
   last. The deployer moves itself by hand.
3. **Then the bare-named orphans can go**, and §4.2 is no longer in the way (see §0-TODAY).
4. Then qits-123's sweep, then Feature 5, then the live verifications.

---

## 15. CORRECTION — DELETING A CONFIG ROW DOES NOT REMOVE THE VARIABLE (2026-09-24, measured)

**§11's mechanism is wrong on this estate, and §14 reported the config half as done when it was
not.** Both are corrected here. The rows now hold the QUALIFIED value rather than being absent.

### What was measured

`dev-qits-artifacts` released, deployed and went ACTIVE at **14:42:37** — after the rows were
deleted. qits-configuration resolves **four** env keys for it. The live swarm service, updated at
14:43:53, carries **six**: those four plus exactly the two that had been deleted. So the container
still holds `QUARKUS_OIDC_AUTH_SERVER_URL=http://qits-platform-idp:8080/idp` and still dials the
bare idp, which is precisely what the cutover would strand.

### Why

**The deployer builds each argv from the served store LAYERED WITH AN EXTRAS FILE on its own config
volume.** `qits.platform.deployments.extras-file` names it; qits-bootstrap-cli's `ComposeTemplate`
renders it at bootstrap; `ExtrasSnapshot` takes one snapshot per argv build. The union is what
reaches `ServiceExtras.env()` — so a key the FILE states is "stated", `envRemovals` never sees it as
unstated, and no `--env-rm` is emitted for it. The deployer's `--env-rm` logic is present and
correct (checked against the running tag `2026.924.90840`, not just the branch); it simply never
applies to a key the file still carries.

`ComposeTemplate` lines 1633-1634 write exactly the two keys that survived on qits-artifacts. The
file was rendered at the last bootstrap, so it holds the PRE-slice-C spelling — bare.

**The same shape explains leftovers that predate this epic entirely**, which is the corroboration
that makes this a mechanism rather than a one-off: `qits-configuration` still carries
`QITS_CONFIGURATION_LEGACY_ENV`, and `qits-platform-maintenance` carries fourteen stale keys
including the old `QUARKUS_OIDC_CLIENT_CI_*` / `GITHOST_*` client secrets that its own
`.config/qits/configuration.yml` says to delete "once C5 has landed". Every one of them is a key
removed from the store while the file went on stating it.

### What was done, and why it is a step back from the rule

The 33 deleted rows were restored with the QUALIFIED value (`/tmp/cfgrestore.py`, 33×200). An entry
beats a property AND beats the file, so an entry holding the right address is the only lever that
actually moves a dialer on this estate. The derived defaults stay in the images, which makes the
rows redundant rather than load-bearing — they can be deleted for real once the file stops being
layered or a bootstrap re-renders it.

This contradicts §11's "the entry stops existing", and deliberately. That rule assumed deleting a
row removes the variable; it does not, and a rule that is right in principle is still wrong to
follow on an estate where it silently does nothing.

### The lesson worth carrying

**"The row is deleted" and "the container stopped seeing it" are different claims.** The first was
verified — 33 clean 204s and a re-inventory of qits-configuration showing zero bare addresses — and
reported as though it were the second. The source of truth was checked; the effect was not. On this
platform the effect needs a service that has actually redeployed:

    # keys the live service carries that config no longer states
    # (exclude QITS_ENVIRONMENT/QITS_APPLICATION/OTEL_*/QUARKUS_OTEL_* and QITS_RESOURCE_*)
    GET qits-platform-system:8080/system/api/swarm/services/<id>     -> envKeys
    GET qits-configuration:8080/configuration/api/applications/<app>/envs/dev/resolved

Anything in the difference is a variable the file is still supplying.

### Follow-up this leaves open

- The layering is arguably a defect: a store that is documented AUTHORITATIVE cannot remove a key.
  **Filed as qits-375** (BUG, REPORTED) — either the file stops being layered once a store is
  configured, or a row deletion has to be expressible. It is not this epic's to fix.
- Filing it also settled a question this file gets wrong elsewhere: **the MCP `repository` tools
  write.** `create_ticket` succeeded as `mcp-agent` while the `qits` CLI refuses the same operation
  403 to `qits:agent`. Use them to record a finding rather than leaving it in prose nobody queries.
- Until then, **never delete an extras row expecting it to reach a container.** Update it.

---

## 16. THE CUTOVER GATE, AS A COMMAND (2026-09-24 ~15:50)

§15 leaves one thing that has to be true before any bare-named service is retired, and it is NOT a
diff of env keys against config — restoring the rows made those agree again while a container
deployed earlier still holds the old VALUE. **A container's environment is frozen at creation, so
the only reliable question is whether the application has DEPLOYED since the entries were
corrected** (~15:30 UTC on 2026-09-24, qits-configuration revisions ~424-451).

    timeout 120 python3 - <<'PY'
    import json,subprocess
    H=["-H","X-Qits-User: agent","-H","X-Qits-Roles: qits:admin"]
    ENV="5a0a10fc-f971-4497-9e05-35a9893ee994"   # the one environment, `dev`
    CORRECTION="2026-09-24T15:30:00Z"
    rows=json.loads(subprocess.run(["curl","-s",*H,
      f"http://qits-deployments:8080/platform-deployments/api/deployments?environmentId={ENV}"],
      capture_output=True,text=True).stdout)["deployments"]
    for app in ["qits-platform-orchestrator","qits-projects","qits-workspaces",
                "qits-platform-maintenance","qits-ci","qits-platform-system",
                "qits-containers","qits-artifacts","qits-platform-edge"]:
        mine=[r for r in rows if r.get("applicationName")==app and r.get("status")=="ACTIVE"]
        if not mine: print(f"{app:<30} no ACTIVE row"); continue
        n=max(mine,key=lambda r:r.get("createdAt") or "")
        print(f"{app:<30} {n['version']:<20} {n.get('createdAt')}  "
              f"{'OK' if (n.get('createdAt') or '')>CORRECTION else '<-- STALE'}")
    PY

State when this was written — one OK, eight stale:

| application | deployed | |
|---|---|---|
| qits-platform-maintenance | 15:37:14 | **OK** — the first proof the restore reaches a container |
| qits-platform-orchestrator, qits-projects, qits-workspaces, qits-ci, qits-platform-system, qits-containers, qits-platform-edge | earlier | stale, but each has a release IN FLIGHT that clears it on deploy |
| **qits-artifacts** | 14:42:37 | stale with **NOTHING in flight** |

**qits-artifacts is the one that will not clear itself.** Its release already finalized, and it does
not depend on qits-eventstream, so no maintenance bump will reach it either. It needs an empty commit
on its epic branch and a release request of its own before the cutover. That is house practice for
exactly this shape — releasing content already on main by pushing an empty commit on your own branch.

---

## 17. THE CUTOVER IS RUNNING (2026-09-24 19:45+)

**Slice D is LIVE**: qits-deployments `2026.924.185508`, ACTIVE 19:31:57. Its publish run failed once
first — BuildKit `graceful_stop` mid-build, because qits-containers redeployed underneath it at 19:01
and bounced the builder. That is the same signature as qits-observability's earlier rejection and it
is worth knowing as a class: **your own deploys bounce the builder other releases are using.** The
`PUBLISH` rerun fixed it; the code was never at fault.

**The cutover gate opened** before any of this: all nine consumers redeployed after the ~15:30 entry
correction, verified by the §16 command. qits-artifacts needed an empty-commit release of its own to
get there.

### The mechanism is proven on the estate

`qits-platform-orchestrator` was the first, and it went exactly as AGENTS.md said it would: its bump
release deployed under the live slice D, the deployer found no service named
`dev-qits-platform-orchestrator`, **created** it, and left the bare-named predecessor running at 1/1.
Both answered 200 for a while. Removing the predecessor left the successor serving and the bare name
no longer resolving.

**The load-bearing result: a bare platform name has been withdrawn while the `iss` claim is still
spelled bare, and nothing broke.** That is §4.2's claim tested rather than argued — see §0-TODAY for
why it was safe to expect.

### How the steps are executed, and the one thing that made it safe

Docker is reached through an ADMIN workspace (row **1301**, `plane-cutover`, `admin: true`, on branch
`task/plane-cutover`). Note the create door refuses a branch that already has an active workspace —
this epic's own branch is taken by the working container, hence a `task/` branch.

There is **no arbitrary-command door**: `POST /workspaces/container/{row}/commands` runs only actions
declared in `.qits-config.yml`, and no repository on the estate has one. So each step is a scoped
agent launched at `POST /workspaces/container/{row}/agents`, transcript at `.../commands/{id}/log`.

**Write every instruction as a GATE plus an action, and say "stop and report" rather than "make it
work".** The first removal attempt refused to run, correctly: the gate I gave it was
`docker service ls --filter name=qits-platform-orchestrator`, which is a PREFIX match and so could
never list the `dev-` prefixed successor. The agent saw its precondition unmet and stopped instead of
deciding what I must have meant. That is the property the edge step depends on — improvising there is
an outage. **Verify the outcome yourself through qits-platform-system's swarm API; the transcript is
a claim.**

### State

| service | state |
|---|---|
| qits-platform-orchestrator | **DONE** — predecessor removed, bare name retired |
| idp, configuration, events, mirror, maintenance | empty-commit releases open; successor appears on deploy, then remove the predecessor |
| qits-platform-system | holds `qits-platform-system-config` + docker.sock — remove FIRST, then release |
| qits-deployments | cannot rename itself after slice D — `rm` + `create` by hand from its inspected spec |
| qits-platform-edge | publishes 8080 and 443 **ingress** (measured: `[{8080->8080},{443->8443}]`) and fronts the registry — pull the image first, then `rm`, then `create --no-resolve-image`. REAL OUTAGE WINDOW, wants a person |

---

## 18. WHAT THE CONTAINERS ACTUALLY HELD — AND WHY §16's GATE WAS NOT ENOUGH (2026-09-24 20:00)

§16's gate asked whether every consumer had REDEPLOYED since the entries were corrected, and treated
that as proof none still dialled a bare alias. **It is not proof, and two separate mechanisms defeat
it.** Both were found by reading the live container environments through the admin workspace —
`docker service inspect --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}...'` — which is the
only check that actually answers the question. The system API exposes env KEYS and never values, so
nothing short of docker can do this.

**1. A hardcoded Java address survives any number of redeploys.**
`HttpIdpClientProvisioner.baseUrl` was `"http://" + "qits-platform-idp" + ":8080/idp/api/service-clients"`
— a string literal, not a property and not an entry, so sweeping `application.properties` and the
qits-configuration store both came back clean while the deployer went on dialling the plane-era name.
Retiring `qits-platform-idp` would have failed every `idp:client` provisioning with an unresolvable
host, at the next deploy of any service declaring one. Its own javadoc said so; fixed in `d7df16a`.
A sweep of every Java source on the estate confirms it was the ONLY one — everything else matching is
a log string, an `X-Qits-User` identity header, or an application name passed through
`PdNetworks.alias`.

**2. An application whose STORE key holds nothing takes the file's bare value, redeploy or not.**
The §11 inventory queried `qits-platform-deployments` and `qits-platform-configuration` and found
zero entries — but those applications are keyed **`qits-deployments`** and **`qits-configuration`**.
So their addresses were never corrected, and they came from the extras file alone. Measured on the
running containers:

    qits_qits-deployments   QITS_EVENTS_URL=http://qits-events:8080
                            QITS_PLATFORM_DEPLOYMENTS_EXTRAS_URL=http://qits-configuration:8080
                            QUARKUS_OIDC_AUTH_SERVER_URL=http://qits-platform-idp:8080/idp
                            QUARKUS_OIDC_CLIENT_CONFIGURATION_AUTH_SERVER_URL=…bare idp
    dev-qits-configuration  QUARKUS_OIDC_AUTH_SERVER_URL=http://qits-platform-idp:8080/idp
    qits-platform-maintenance  QUARKUS_OIDC_CLIENT_{CI,GITHOST}_AUTH_SERVER_URL=…bare idp

**The deployer was the dangerous one**: removing qits-events, qits-configuration or qits-platform-idp
would have broken the component that reads the configuration needed to repair it. All seven entries
are now set to the qualified spelling and the affected services are redeploying.

**THIS WAS THE WRONG DIRECTION, and the owner has said so.** qits-configuration is for
environment-specific values — the root domain is the example — and everything else is hardcoded in
the service. A peer's ADDRESS is derivable from `QITS_ENVIRONMENT`, so it belongs in the service's
own properties and nowhere else. Setting entries to out-vote the file is a workaround, not a design:
the real fix is that `ComposeTemplate` stops rendering address `env.*` lines into the deployer's
config-volume file at all, after which every address entry — including the 33 restored here and the 7
added — is deleted for good. Ordered fix and the full list of rows to remove: **qits-375**. Do not
add more entries; if a bare address turns up, record it there rather than out-voting it.

**A store entry BEATS the file — measured, not assumed.** `dev-qits-artifacts` shows no bare value at
all, because the entry restored at 15:30 won over the file's bare one. That is what makes setting an
entry a real fix rather than a hope.

### The gate that actually holds

Redeployment is necessary and not sufficient. Before retiring any bare-named service, read the live
environments and require the answer to be empty:

    for s in $(docker service ls --format '{{.Name}}'); do
      echo "=== $s"
      docker service inspect "$s" --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' \
        | grep -E 'qits-platform-(idp|mirror|events|configuration|maintenance|orchestrator|system|edge)|qits-(events|configuration|deployments)' \
        | grep -vE '=.*dev-qits' || echo '  (none)'
    done

Ignore three families in the output, which are identity rather than address and are correct as they
stand: `QITS_APPLICATION`, `QITS_AUTH_MACHINE_AUDIENCE` / `*_GRANT_OPTIONS_CLIENT_AUDIENCE` /
`*_CLIENT_ID`, and `QITS_IDP_ISSUER` (§4.3 — the `iss` claim is compared, never dialled).
