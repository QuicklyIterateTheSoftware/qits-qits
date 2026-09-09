# Rolling out the agent configuration system

How the ten features of the **agent configuration system** epic reach a running estate, in the one
order the dependencies allow; what "released" does and does not mean for each of them; and how to
prove, on dev, that all eight session surfaces launch what the editor says they will.

Written while doing it, on 2026-09-09, against `dev`. The four things in
[What this rollout measured the hard way](#what-this-rollout-measured-the-hard-way) are not specific
to this epic — they are properties of this estate that cost real hours here, and the next multi-repo
rollout will hit them too.

The doctrine this sits under is the estate's usual one — **branch → door** — and `WORKSPACE.md` is
the short form of it. Nothing below writes `main` or a deploy branch by hand.

## The two facts that make "released" and "in effect" different moments

State these before anything else, because every confusing hour of this rollout traced back to one of
them, and **neither is surfaced anywhere in the UI**.

**1. A daemon runs the library version it was built against.** The two daemons depend on a released
CalVer coordinate, `eu.wohlben.qits:qits-coding-agents:<version>`, pinned in a POM property — a
version, not a range. So a fix to shared harness code is *never* one release. It is: release the
library, bump `<qits-coding-agents.version>` in each daemon, release each daemon. Until the second
step lands, the deployed daemon is still running the old harness code, and its `/agents/available`
will happily tell you the daemon version while saying nothing about the library inside it. This is
the deliberate cost of the two diverged copies becoming one, and it is why the library's own suite —
not a daemon's — is where harness behaviour is proven.

**2. A container carries the document it was created with.** The resolved surface configuration is
written as a JSON file and mounted when a container is *created*. The daemon reads and validates it
once, at boot. There is no push, no poll, and no staleness flag. **A store edit takes effect at the
next container recreate and not before.** A workspace container that has been up since yesterday is
running yesterday's prompts, and the editor will show you today's without a word about it.

Neither is a bug. The first buys a single copy of the harness code; the second buys a launch path
that is a pure local render with no runtime dependency on qits-projects, which is worth more than
immediacy for a container whose life is already scoped to one piece of work. What makes the second
safe rather than opaque is the **launch record**: every launch records what it actually resolved to,
so a session is readable after the fact even after the store has moved on. (See the honest caveat
about reading it in [Verifying the eight surfaces](#verifying-the-eight-surfaces).)

The practical rule that falls out of both: **after any release in this chain, recreate the
containers before you believe what you see.**

## The order, and why each step waits for the one before it

| # | Repository | What it carries | Waits for |
| --- | --- | --- | --- |
| 1 | `qits-coding-agents` | the shared harness library | — |
| 2 | `qits-projects-daemon`, `qits-workspace-daemon` | pinned library bump, `surface` on the wire, capability probe, document reader | 1 (the pin is a released coordinate) |
| 3 | `qits-workspace-oci` | image rebuild carrying the new workspace daemon binary | 2 |
| 4 | `qits-projects-service` | the store, the seeded surfaces, the editor doors, the document door, the capability cache | 2 (the daemons report capabilities into it) |
| 5 | `qits-workspaces-service` | fetch the document at provision and mount it | 4 (there is nothing to fetch before the door exists) |
| 6 | `qits-projects-frontend`, `qits-workspaces-frontend` | send `surface` on every launch, render the sign-in refusal | 2 (the daemons must accept the field first) |
| 7 | `qits-docs-service` | the contract page | 4 |
| 8 | `qits-qits` | the wrapper release, banking the estate | everything |

Two of those edges are worth spelling out because they look reversible and are not.

**The library before the daemons** is fact 1 above. A daemon cannot be released against a library
version that does not exist yet, and there is no snapshot channel to lean on — the coordinate is a
CalVer stamped by the release pipeline. So the library's release request has to be *filed, gated,
released and published to the maven registry* before either daemon's build can even resolve.

**The daemons before the frontends** is the direction the compatibility crutches were built for. A
frontend sending `surface` to a daemon that does not read it is silently ignored, which is the
failure mode where every ticket session quietly becomes an epics session. The reverse — a daemon
that reads `surface` and a frontend that does not send it — was survivable *only* because the
library guessed one from the request's shape, and that guess is exactly what the cutover deletes.
Ship the daemons first and the crutch is never load-bearing.

**qits-projects-service before qits-workspaces-service** because the second one's whole change is a
call to the first one's new door. Note the peer URL that call needs is a `serviceAddress` in
`.config/qits/configuration.yml`, not a literal — the config-declarations epic learned that one the
hard way and it applies here unchanged.

### Filing a release

One door per repository, idempotent per branch:

```sh
token() { curl -fsS -u "$QITS_COMMISSIONED_CLIENT_ID:$QITS_COMMISSIONED_CLIENT_SECRET" \
            -d "grant_type=client_credentials&audience=$1" \
            "$QITS_WORKSPACE_DAEMON_AUTH_TOKEN_URL" | jq -r .access_token; }

PROJECTS=$(token dev-qits-projects)

curl -fsS -X POST "http://dev-qits-projects:8080/projects/api/repositories/$REPO_ID/release-requests" \
  -H "Authorization: Bearer $PROJECTS" -H 'Content-Type: application/json' \
  -d '{"branch":"epic/agent-configuration-system","summary":"…","requester":"…","priority":"NORMAL"}'

# then poll:
curl -fsS "http://dev-qits-projects:8080/projects/api/repositories/$REPO_ID/release-requests/$ID" \
  -H "Authorization: Bearer $PROJECTS" | jq '.request.state, .request.version'

# and, when a gating verdict has gone red (see below), the only way out:
curl -fsS -X POST ".../release-requests/$ID/withdraw" \
  -H "Authorization: Bearer $PROJECTS" -H 'Content-Type: application/json' \
  -d '{"reason":"…"}'
```

The repository ids for this chain, in the order above:

| repository | repoId |
| --- | --- |
| `qits-coding-agents` | `206fbdf0-ea77-42b8-8a6f-15ee6727145c` |
| `qits-workspace-daemon` | `e77909c3-127a-478d-a5b3-7a63ea5d6c71` |
| `qits-projects-daemon` | `b5da1f0e-b4b9-4259-acd5-ebcc8778b078` |
| `qits-workspace-oci` | `9787c5ec-1d2f-4537-b989-4bb09fd66b90` |
| `qits-projects-service` | `19af0fab-5aa6-46b4-a1d9-334588c4bd02` |
| `qits-workspaces-service` | `a6e033e4-a876-4433-a082-5ed599c3ef01` |
| `qits-projects-frontend` | `528816ef-e131-4ec7-82da-f970145f1d1f` |
| `qits-workspaces-frontend` | `877924e3-6c1e-45bb-b7ca-540f43c2eaee` |
| `qits-docs-service` | `f48fabb2-9b85-4e1c-86c6-8f514eecc6f3` |
| `qits-qits` (wrapper) | `4a2ea85b-c245-49dc-8eb9-982c5268115d` |

A library release is confirmed by the artifact, not by the request's state:

```sh
curl -fsSI "$QITS_MAVEN_REPOSITORY_URL/eu/wohlben/qits/qits-coding-agents/$V/qits-coding-agents-$V.pom"
```

## What this rollout measured the hard way

Four things, each of which cost time here and none of which is specific to this epic.

### 1. A CI recipe is decided at `main` and built at the fold

The gating pipeline for a release request is compiled from `.config/qits/release.yml` **as it reads
on `main`**, then run against the folded branch. So a commit that *needs* a new pipeline behaviour
and *ships the recipe providing it* cannot pass its own gate: the recipe it added is on the branch,
and the pipeline that ran was compiled before the branch existed.

The escape is to land the recipe on `main` alone, without a release, using the githost commit
primitive:

```sh
GITHOST=$(token dev-qits-githost)   # needs role qits:system
curl -fsS -X POST "http://dev-qits-githost:8080/githost/api/repositories/$REPO_ID/commits" \
  -H "Authorization: Bearer $GITHOST" -H 'Content-Type: application/json' \
  -d '{"branch":"main","message":"…","files":[{"path":".config/qits/release.yml","content":"…"}]}'
```

The branch must already exist — this primitive commits onto a branch, it does not create one. Then
rebase the work onto the new `main` and re-file.

Hit twice on this rollout. The second time was the same deadlock wearing a different hat: a
**brand-new repository** (`qits-coding-agents`, seeded empty on purpose) has no `release.yml` on
`main` at all, so its first release request has no pipeline to be gated by and the door will not let
it through. Same escape, same primitive, and it is worth doing as the *first* commit of any new
repository rather than discovering it at the first release.

### 2. Taking the released library makes a daemon reactor need the maven registry

Before this epic, both daemons built from sources in their own tree and never talked to the platform
Maven registry. Depending on a released coordinate changes that, and the settings file has a trap in
it: `.qits-maven-settings.xml` defines an **exact-id mirror** named `qits-maven-network` whose URL is
`${env.QITS_MAVEN_REPOSITORY_URL}`. When that variable is unset, Maven does not fail and does not
fall back — **it leaves the property literally unexpanded** and tries to resolve against a URL that
is the string `${env.QITS_MAVEN_REPOSITORY_URL}`. The error you get is a resolution failure that
names a nonsense host, several layers away from the missing variable.

And qits-ci injects the registry under a *different name*: `QITS_MAVEN_REGISTRY_URL`. So the recipe
has to export the one the settings file reads:

```yaml
env:
  QITS_MAVEN_REPOSITORY_URL: ${QITS_MAVEN_REGISTRY_URL}
```

The Dockerfile's native build needs the same value threaded through as a build-arg, because the
build inside the image is a second Maven run with its own environment.

Both daemons' `ci-event-*.yml` recipes carry this now. Any repository that starts depending on a
platform-published artifact will need the same two lines.

### 3. One red gating verdict rejects a request permanently

This is the one that wastes the most time, because every instinct is wrong.

A release request that receives a **red gating verdict is REJECTED, and REJECTED is terminal.**

- Retrying the CI run until it goes green does **not** rescue it. The verdict that mattered was
  already recorded; a later green one is not consulted.
- Re-filing the same branch returns the **same request**, because the door is idempotent per branch.
  You will read back the same id and the same terminal state and conclude, wrongly, that the door is
  broken.

The only path forward is, in this order: **withdraw the request, move the sha (a new commit on the
branch), re-file.** Withdrawing is what frees the branch for a new request; moving the sha is what
makes the new request a different thing to gate.

Which means: **do not file a release request to find out whether CI passes.** Run the repository's
CI command locally first. For this chain:

```sh
# qits-coding-agents
./mvnw -B -ntp -s .qits-maven-settings.xml clean verify

# qits-projects-daemon (and the workspace daemon, same shape)
QITS_MAVEN_CENTRAL_URL="" QITS_MAVEN_REPOSITORY_URL="$QITS_MAVEN_REPOSITORY_URL" \
  ./mvnw -B -ntp -s .qits-maven-settings.xml verify \
  -Dqits.maven.repository.url="$QITS_MAVEN_REPOSITORY_URL"

# the frontends
npm ci && npm run test && npm run build
```

### 4. "Released" and "deployed" are minutes apart

`qits-projects-service` reported `RELEASED` while every new door still answered `404` — for about
seven minutes. The release request's state describes the *release*: the tag, the artifact, the image.
It says nothing about whether the deployer has rolled the running instance yet.

So **verify a release by polling its endpoints, never by reading its state.** A cheap probe per step:

```sh
until curl -fsS -o /dev/null "http://dev-qits-projects:8080/projects/api/agent-surfaces" \
        -H "Authorization: Bearer $PROJECTS"; do sleep 15; done
```

The same applies to a daemon: a released daemon is not a *running* daemon until the container it
lives in has been recreated on the new image, which is fact 2's cousin and step 3 of the order.

## Verifying the eight surfaces

The one check a unit test cannot do. Everything in the library's suite asserts *rendering*; what has
never been provable in a test is that the eight places in the product each reach the daemon with
their own key. Two of them — `epic.chat` and `workspace.chat` — sent **byte-identical requests to two
different containers** before this epic, and telling them apart is the entire point of it.

Do this after step 6 is deployed and after the containers have been recreated.

### The eight, and where to press each

| Surface | Where | Container |
| --- | --- | --- |
| `project.epics` | projects → epics overview → refinement panel → Start | project agent container |
| `project.tickets` | projects → tickets page → Triage agent → Start | project agent container |
| `epic.chat` | refining route → Chat tab | the epic's workspace container |
| `epic.agent` | refining route → Agents tab | the epic's workspace container |
| `workspace.chat` | workspace detail → Chat tab | that workspace's container |
| `workspace.agent` | workspace detail → Agents tab | that workspace's container |
| `epic.autonomous` | the composed task-prompt run (no button — it is started by the autonomous path) | the epic's workspace container |
| `ticket.dispatch` | tickets → Start implementation, which cuts a workspace and dispatches | the freshly cut container |

`epic.chat` vs `workspace.chat` and `epic.agent` vs `workspace.agent` are the pairs that matter.
Run all four. Confirming six and assuming the other two is exactly the assumption this epic exists to
break.

### Step 0 — make the surfaces distinguishable before you look

Give one surface of each ambiguous pair a **visibly different** configuration, so a mix-up is
readable rather than inferable. The cheapest is the system prompt:

```sh
PROJECTS=$(token dev-qits-projects)
BASE=http://dev-qits-projects:8080/projects/api

curl -fsS "$BASE/agent-surfaces" -H "Authorization: Bearer $PROJECTS" | jq -r '.[].surface'
# → the eight keys, which is also the proof the seed landed

curl -fsS -X PUT "$BASE/agent-surfaces/epic.chat" \
  -H "Authorization: Bearer $PROJECTS" -H 'Content-Type: application/json' \
  -d '{"systemPrompt":"MARKER-EPIC-CHAT", …}'
```

Then **recreate the containers** — fact 2. An edit before a recreate proves nothing.

### Step 1 — read the resolved document the container will be born with

```sh
curl -fsS "$BASE/agent-configuration" -H "Authorization: Bearer $PROJECTS" | jq '.surfaces | keys'
```

This is the same read qits-workspaces makes at provision. It must list every surface a container may
serve, with each one's prompt, harness, MCP attachments and permission mode resolved. If a marker you
just set is not in here, nothing downstream will have it either, and the problem is in the store, not
in the container.

### Step 2 — press each surface and read back what launched

```sh
# projects daemon, via the host's proxy
curl -fsS "http://dev-qits-projects:8080/projects/container/$PROJECT_ID/commands" \
  -H "Authorization: Bearer $PROJECTS" | jq '.entries[].command | {id, actionName, agentSurface}'

# workspace daemon, for a refining workspace
curl -fsS "http://dev-qits-projects:8080/projects/refinement-container/$WS_ROW/commands" \
  -H "Authorization: Bearer $PROJECTS" | jq '.entries[].command | {id, actionName, agentSurface}'

# workspace daemon, for an ad-hoc workspace
WORKSPACES=$(token dev-qits-workspaces)
curl -fsS "http://dev-qits-workspaces:8080/workspaces/container/$WS_ROW/commands" \
  -H "Authorization: Bearer $WORKSPACES" | jq '.entries[].command | {id, actionName, agentSurface}'
```

**`agentSurface` is the assertion.** Each of the eight presses must produce a command reporting its
own key, and the two ambiguous pairs must differ. This is the field that did not exist before this
epic, and it replaces the `" (tickets desk)"` substring the frontend used to parse out of
`actionName` — that match is deleted, so `actionName` is now a label and proves nothing.

A command answering **no** `agentSurface` after this cutover is a bug, not an old row: the library
refuses a launch that names no surface (`400`, "A launch must name its agent surface"). The only
commands legitimately without one are the sign-in terminal, which is nobody's surface, and rows that
predate the cutover — and a container's command store does not survive a recreate, so after step 0
there are none of those left.

### Step 3 — the launch record, and the gap this rollout found

The epic's intended evidence is the **launch record**: `Command.agentLaunchRecord`, added by task
`f9f42f47`, holding what the session actually resolved to — surface, harness, model, effort,
permission mode, remote control, and the MCP servers attached by key (never by credential). It is
the right evidence precisely because of fact 2: the store can be edited at any time, and a session
that behaved oddly last week was configured by a document nobody can reconstruct afterwards.

**It is recorded and it is not yet served.** `Command` carries it in the container's in-memory store,
and neither daemon's `CommandJson` puts it on the wire — `GET /commands` and `GET /commands/{id}`
answer `agentSurface` but not the record. The store is per-container and in-memory, so there is no
database to read it out of either. Verified in both daemons' `origin/main` trees on 2026-09-09.

So, today:

- **The check you can run** is `agentSurface` (step 2) plus the visible effect of the configuration —
  the marker prompt in the agent's own behaviour, the model it reports, whether it asks for
  permission. That proves the surface travelled and that the document reached the container, which is
  the substance of the verification.
- **The check the epic specified** — reading the record back as one object — needs the field emitted
  on the command body. That is a small, additive change in three places (both daemons' `CommandJson`,
  the frontends' `CommandDto`) and it should be filed as a follow-up ticket rather than worked around
  here. Reading logs instead is exactly the thing the record exists to replace, and the rendered
  command line is logged, which means an external MCP server's header would be in whatever you
  scraped.

Write this gap down in the ticket rather than leaving it as a verification everyone quietly skips.

### Step 4 — the checks that are easy to forget

- **`project.epics` renders no system prompt.** Empty is a value, not an absence — the epics desk
  steers with nothing, deliberately, and a seed that "helpfully" filled it would change behaviour on
  the surface most used.
- **`project.tickets` renders `TICKETS_DESK_PROMPT` byte for byte.** The seed is the migration; if it
  drifted, the constant and the row disagree and nobody will notice for a month.
- **Remote control is absent, not ignored, on the chat surfaces.** `--print --input-format
  stream-json` is not an interactive session and the flag has nothing to attach to.
- **A Kimi surface shows no effort control.** Kimi has no effort concept; a disabled dropdown
  carrying Claude's levels would be a lie.
- **A container created without a document still launches.** That fallback is permanent, not a
  crutch: it is what a container older than the store does, and it must keep rendering the shipped
  constants. Do not confuse it with the surface guess, which is gone.

## What the cutover removed, and what deliberately stayed

Every step of this epic shipped behind a compatibility crutch so the pieces could release
independently. A crutch left in place after the rollout is a second code path nobody tests, so they
come out together, at the end, with everything released:

- **The shape-implied surface guess** (`AgentLaunchRequest.surfaceOrDefault`) — a launch without a
  surface was read as the epics desk or a workspace chat/agent depending on its shape. Gone: a
  missing surface is now the same typed refusal an unknown one always was. It was lossy in exactly
  the place this epic exists to fix — it collapsed `epic.chat` onto `workspace.chat` — and a default
  that resolves a caller which forgot the key makes a misconfigured caller look like a working one.
- **The `desk` field on `POST /agents`** — a wire-level translation of the retired two-valued enum,
  kept so an unshipped frontend stayed working. Gone: the surface is the only steering key in the
  system.
- **The `"tickets desk"` string match** in the projects frontend — the cross-repo contract that lived
  in a display label. Gone. Sessions launched before the cutover lose their desk grouping, which is
  accepted and better than keeping a display-string contract alive for old rows forever. The command
  name is consequently free to change, because nothing parses it.
- **The adopted login terminal** — the frontend branch that recognised a substituted sign-in REPL
  coming back from a launch and attached to it. Gone: both daemons answer
  `409 {"error":"not-signed-in","agentType","message"}` and serve `POST /agents/sign-in`, so the
  terminal is opened by a press or not at all.

Two things that look like crutches and are not:

- **The library's shipped constants** (`TICKETS_DESK_PROMPT`, the `READ_ONLY_*_TOOLS` lists) stay.
  They are the fallback for a container created *without a document*, which is a permanent and real
  shape, not a dated one. They stopped being the only copy; they did not stop being the last one.
- **`isSignInTerminal` in the frontends** stays. A sign-in terminal still exists — it is opened
  deliberately — and resolution has to recognise it in a container's command list so it attaches to
  the login the container is waiting on instead of starting an agent behind it.

## Adding a ninth surface, later

The vocabulary is open by design, and adding one is an additive change rather than a migration. Three
places have to learn the key, and they are copies rather than a shared type on purpose — the service
depends on no daemon library and the library reads no service, so what crosses between them is the
**string, character for character**:

1. `AgentSurface.KNOWN` in the library.
2. The seeded surface rows in `qits-projects-service`.
3. The caller that sends it — a frontend, or a composed launch path naming its own.

A rename on any one side is a wire break neither repository's suite would notice. Add, do not rename.
