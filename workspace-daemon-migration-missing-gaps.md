# workspace-daemon migration: what is done, and what is still owed

Handoff for the in-flight move of `domain/command` and `domain/agent` out of `../qits` and into
`daemons/qits-workspace-daemon`. Written 2026-07-27, after `qits-commands` landed and before
`qits-coding-agents` was started.

Companion to [`migration-plan.md`](migration-plan.md) and
[`migration-api-map.md`](migration-api-map.md) — **but read §1 below before either of them**, because
this pass deliberately diverged from what they describe and neither has been updated yet.

---

## 1. Read this first: the plan is stale for this target

`migration-plan.md` §3.3 says the daemon gains `agents/` and `commands/` as **host-side control
plane**: a `git filter-repo` history replay, a package rename, a port for every cross-context reach,
Flyway lineages squashed per §7, and the `docker exec` transport left in place with the flip to the
control socket deferred to §9 item 3.

**That is not what is being built.** The decision taken instead:

> Both surfaces move **into the container**, as two maven modules inside the daemon repo, and their
> state is **container-lifecycle-scoped** — for now, nothing is kept beyond the life of the
> container.

That removes the persistence layer, removes the docker-exec transport, and dissolves most of §6's
cut sites rather than porting them behind ports. §8's extraction recipe therefore **does not apply**:
no `filter-repo`, no `--allow-unrelated-histories` merge, no Flyway squash. History is not replayed
because the code is not moved intact — it is reimplemented against a different runtime.

The precedent is already in the repo: `workspace-daemon-files` and `workspace-daemon-detection`
(daemon commits `2dbe0ab`, `0b034cc`) took exactly this path one level down — 25 monolith rows
replaced by fresh code, plain JUnit, no history replay, DTO field names kept so the frontend contract
did not move. This pass repeats that shape.

§8 steps 8–10 (verify from a pristine clone, push, register) **do** still apply.

---

## 2. Where things stand

Two commits, **local and unpushed**, on `main` in `daemons/qits-workspace-daemon`:

```
f6fc9a5 Serve commands over the daemon's HTTP API
9a9f365 Bring commands into the container as their own module
```

`./mvnw verify` is green across the whole reactor: 200 tests, of which 44 are new, and nothing
pre-existing was broken or changed in behaviour.

The gitlink in this repo is **untouched** — do not update it until the daemon repo is pushed.

### Module layout now

| Module | State |
|---|---|
| `workspace-daemon-protocol` | untouched — **and must stay that way**, see §4.2 |
| `workspace-daemon-files` | untouched |
| `workspace-daemon-detection` | untouched |
| `qits-commands` | **done** — 33 classes, 29 tests |
| `qits-coding-agents` | **empty** — pom and directories only |
| `workspace-daemon` | gained the commands wiring + 15 tests |

Reactor order is protocol → files → detection → commands → coding-agents → workspace-daemon.

### What works end to end

Five of the API map's ten 🕓 pending REST operations, served over the daemon's existing
bearer-authenticated HTTP API:

```
GET  /commands[?status=]        200  {entries[{command}]}
POST /commands {actionId}       200  {command}
GET  /commands/actions          200  {actions[{id,name,interactive}]}      (new; see §5.3)
GET  /commands/{id}             200  <command>
GET  /commands/{id}/log[?severity=&channel=]
                                200  {lines[{sequence,channel,content,severity?,timestamp}]}
POST /commands/{id}/terminate   200  <command>
```

No `{repoId}/{workspaceId}` prefix — the daemon serves one workspace, so those segments would be a
constant the caller has to get right. `CommandJson` puts both ids back into the response bodies, so
the host's `CommandDto` reconstructs unchanged.

---

## 3. Decisions already made — do not relitigate these

Each of these was decided with a reason. Change them if the reason turns out to be wrong, not
because they look surprising.

### 3.1 No persistence, anywhere

`CommandStore` + `CommandLogBuffer` replace `CommandRepository`, `CommandLogLineRepository` and
Flyway **V8, V9, V12, V13, V18, V28, V29, V32**. The daemon gets no datasource, no Hibernate, no
Panache, no narayana-jta. `qits-coding-agents` must do the same with **V30, V39** and
`agent_session_stat`.

`migration-plan.md` §7 still allocates those lineages to `daemon-commands` / `daemon-agents`. It is
wrong and needs correcting (§7 of this document).

### 3.2 pty4j is out; the PTY is FFM

The daemon compiles to a GraalVM native image (`docker/qits/Dockerfile`, stage
`workspace-daemon-build`, Mandrel, `-Dnative`), and `workspace-daemon/pom.xml` is explicit that it
carries no Jackson, no JAX-RS and no Hibernate because they bloat the image. pty4j is JNA plus
per-platform `.so` files extracted at runtime — the worst case for that.

`ForeignPty` calls `open("/dev/ptmx")`, `grantpt`, `unlockpt`, `ptsname_r`, `ioctl(TIOCSWINSZ)`,
`read`, `write` and `close` through `java.lang.foreign`. **Every `FunctionDescriptor` is a
`static final` constant on purpose** — that is what lets GraalVM register the downcall stubs at
build time with no `Feature` and no config file. If you add a downcall, keep it constant.

Surefire needs `--enable-native-access=ALL-UNNAMED` (already in `qits-commands/pom.xml`). **The
daemon run in JVM mode needs it too and does not have it yet** — see §4.4.

### 3.3 Jackson is out; JSON is `io.vertx.core.json`

vertx-core is already in the image via `quarkus-vertx`, and pulls only `jackson-core` streaming —
no second JSON stack, no databind reflection to register. `WorkspaceJson` and `ConfigJson` already
did this; `CommandJson` follows.

`qits-coding-agents` has the harder version of this job: `AcpChatProtocol` (469 lines),
`KimiEventNormalizer` (402) and `AgentTranscriptService` (745) are all `ObjectMapper`/`JsonNode`
today. `JsonObject.getString(k, default)` / `getJsonObject` / `getJsonArray` map onto most of it;
watch for `JsonNode.path()` chains, which return a missing-node rather than null and therefore never
NPE — the vertx equivalent does, so a naive translation introduces NPEs on absent keys.
`ChatSession.parseQuietly` shows the pattern that was used.

### 3.4 The dead-code list was actually dropped

`migration-plan.md` §3.3 lists `CommandService.launchService`, `beginServiceRun`, `followService`,
`launchAndAwait` and `launchScriptAndAwait` as dead code to drop, and is emphatic about it because
the last extraction left the list in place and an imported socket promptly called back into it,
turning host-side service supervision back on after it had been moved into the daemon.

They were confirmed to have **no production callers** (only tests) and are gone. Do not reintroduce
them. Services belong to `ServiceSupervisor` in the daemon module.

`OtelEnvironment` went with them: its only callers were `launchService` and `beginServiceRun`, so
keeping it would have left precisely that landing pad. It is in `daemon-commands.txt` and the
manifest needs correcting. If service launches ever need the OTLP overlay again, it belongs beside
`ServiceSupervisor`, not in `qits-commands`.

### 3.5 `Command`'s FK to `Workspace` left the model entirely

Not "became a string id", which is what §8 step 4 would require for a cross-context split. Inside the
container every command is this workspace's by construction, so the six `CommandRepository` queries
that navigated `workspace.repository.id` / `workspace.workspaceId` collapsed to filters on `status`
and `kind`. `WorkspaceContext` supplies the identity for the response bodies.

### 3.6 The featureflow edge dissolved

`CommandService.launch` used `featureflow.ActionResolutionService`, and `domain.featureflow` is
monolith-only and deferred (§3.9, §9 item 6) — so a faithful port would have declared a port that
could never be wired, leaving `POST /commands` permanently unusable.

It did not have to. `DaemonQitsConfig` already parses `actions:` out of the checkout's own
`.qits-config.yml` with exactly the fields `ResolvedAction` carried. `ActionResolver` +
`ConfigActionResolver` make resolution a local config read. This is the V42–V45 direction §7 already
noted, where repo-scoped configuration left the host database for the repo.

### 3.7 `domain/setting` stays host-side

§4 offers "follows agents into the daemon repo" as one resolution, and `SettingsService` really is
read only by `AgentTypeResolver` and `AgentLaunchService`. But `agent.default-type` and
`agent.activity-tracking.enabled` are **user preferences that must outlive a container**, and this
daemon keeps nothing.

So agents should resolve the harness as *request parameter > `.qits-config.yml` > daemon default*,
and §4's `domain.setting` row **stays open**. `GET·PUT /api/settings` stay ❔ open in the API map.

---

## 4. What is still owed

Ordered by dependency, not by size.

### 4.1 `qits-coding-agents` — the big one

~4,731 LOC across 28 main classes, 16 tests and 5 controllers. Manifest:
`migration-manifests/daemon-agents.txt`.

Target package `eu.wohlben.qits.workspacedaemon.agents`, framework-free like its siblings (no CDI —
the daemon module constructs the objects, as `ControlSocket.wireCommands` does for commands).

**Ports near-verbatim** (pure rendering/parsing, no host coupling): `LaunchSpec`, `CodingAgent`,
`ClaudeCodeAgent`, `KimiCodeAgent`, `CodingAgentFactory`, `McpServers`, `AgentLaunchMode`,
`AgentMcpScope`, `AgentType`, `acp/AcpSessionConfig`, `acp/KimiChatUuids`.

**Needs the Jackson → vertx conversion**: `acp/AcpChatProtocol`, `acp/KimiEventNormalizer`,
`AgentTranscriptService`, `AgentTranscriptTailService`.

**Coupling to resolve** — from the monolith's imports:

| Class | Reaches | Resolution |
|---|---|---|
| `AgentLaunchService` | `command.*` | in-repo now; depend on `qits-commands` |
| `AgentLaunchService` | `WorkspacePromptDraftService` | **drop** — the launch request carries the prompt text |
| `AgentLaunchService` | `RepositoryRepository`, `Repository` | drop; `WorkspaceContext` has the ids |
| `AgentLaunchService`, `AgentTypeResolver` | `setting.control.SettingsService` | §3.7 — config, not a store |
| `AgentLaunchService` | `service.control.ServiceEventSpool` | `ServiceSupervisor` is in-repo; wire or defer |
| `AgentLaunchService` | `QitsHostResolver` | the daemon knows where qits is — it dialled it |
| `AgentAuthStatus`, `AgentPluginService`, `PromptRefinementService` | `ContainerRuntime.exec` | **local file/process access** — this is the whole win, see below |
| `AgentTranscriptService` | `WorkspaceChangePublisher/Hint` | a listener like `CommandChangeListener` |
| `AgentSessionQueryService` | `WorkspaceRepository` | drop; ambient |

**`/claude-home` becomes local.** It is a shared docker volume (`qits.workspace.claude-volume`)
mounted into every workspace container at `qits.workspace.claude-mount` (default `/claude-home`). The
four classes §3.3 flagged as host-coupled read it directly from inside the container — their coupling
resolves by relocation, exactly as file browsing's did. Note the volume is **shared across
workspaces** and outlives containers, so transcripts survive a recreate even though the index of them
does not.

**`AgentSessionStat` becomes in-memory**, and is therefore lost on recreate. See §6.

### 4.2 The terminal and chat websockets

`WS /api/terminal/commands/{commandId}` and `WS /api/chat/commands/{commandId}` — the interactive
half of commands. The REST surface is complete; these are not started.

Serve them on the daemon's own vertx `HttpServer` (`WorkspaceApi` already creates one;
`HttpServer.webSocketHandler` is native to vertx-core). **Do not route them through the control
socket.** The protocol's `RunCommand`/`CommandChunk`/`CommandExit` are fire-and-collect — no stdin,
no resize — so interactive terminals would need new message types, a
`DaemonProtocol.CAPABILITY_VERSION` bump, and the change mirrored into `qits-workspaces`' vendored
copy of the protocol module. **`CAPABILITY_VERSION` is still 2 and `DaemonCodecTest` passes unchanged
on both sides; keep it that way.**

Everything needed is already in place:

- `CommandRegistry.attach(commandId, CommandOutputSink)` / `detach` / `input(byte[])` /
  `resize(cols, rows)` / `chatSend(commandId, text)`.
- Adapt a `WebSocketBase` to `CommandOutputSink` (`write(String)` + `isOpen()`).
- Wire protocol, from the host's `TerminalSocket` / `ChatCommandSocket`: client sends
  `{"type":"data","data":"…"}` and `{"type":"resize","cols":N,"rows":M}` for terminals,
  `{"type":"user","text":"…"}` for chats; the server sends raw PTY bytes (terminals) or
  newline-delimited JSON envelopes (chats).
- Bearer auth still applies — the client is the host proxying, not the browser, so it can set the
  header.

### 4.3 Manifest correction: `TerminalSocket.java`

`migration-manifests/workspaces.txt:164` assigns
`service/src/main/java/eu/wohlben/qits/domain/repository/api/TerminalSocket.java` to
`qits-workspaces`. It is wrong: the class serves `/api/terminal/commands/{commandId}`, injects only
`CommandRegistry` and `CommandOutputSink`, and `qits-workspaces` deliberately declined it — it
declared the `WorkspaceTerminalSessions` port instead, for `ServiceTerminalSocket`. The API map
already lists it under the commands module. Move the row to `daemon-commands.txt`.

### 4.4 `--enable-native-access` for the daemon in JVM mode

`qits-commands/pom.xml` sets it for surefire. The native image resolves native access at build time
and needs nothing. **But `workspace-daemon` run as a JVM app has neither**, so the first PTY launch
will warn — and, per the JVM's own warning text, will be refused outright in a future release.

Add it to `workspace-daemon/src/main/resources/application.properties` (`quarkus.jvm.args` or the
equivalent for command-mode), or to the Dockerfile's JVM invocation if there is one. The native path
is the one that ships, so this is about dev runs, not production — but it will bite someone.

### 4.5 `commandsChanged` is not wired

`CommandChangeListener` exists and `ControlSocket.wireCommands` passes **null**. Consequence: the
browser refetches the Commands list on its own cadence instead of being nudged, where the host fired
`WorkspaceChangeHint.Topic.COMMANDS` into the workspace SSE stream.

This is the documented absent-listener behaviour, but it **is a real behaviour change** and should be
either wired or written down as accepted. Wiring it properly needs a control-socket EVENT, which
means the `CAPABILITY_VERSION` bump §4.2 argues against — so the honest options are "accept the
refetch cadence" or "do the protocol bump deliberately, once, for both this and anything else that
needs it".

### 4.6 Daemon repo docs

`migration-plan.md` §9 item 10: `daemons/qits-workspace-daemon` has no `README.md` and no
`AGENTS.md`. Every other populated submodule has one, with `CLAUDE.md` a **symlink** to it. Write
both; the pom comments in `qits-commands` and `qits-coding-agents` are a good source for the "what
the daemon does not keep" section §6 needs.

### 4.7 Verify from a pristine clone, then push

`migration-plan.md` §8 step 8: `./mvnw verify` must be green from a **fresh clone of the pushed repo
alone** — no monorepo, no prior `mvn install`, no docker. Verify from that clone, not from the
working one.

Then push to `github.com/QuicklyIterateTheSoftware/qits-workspace-daemon.git`. The remote is
**populated**, so the push must be a fast-forward — the two local commits already descend from
`origin/main`, so this is a plain push, not the `--allow-unrelated-histories` dance §8 step 9
describes for a filtered branch.

Only then update this repo's gitlink, with an **explicit path** (`git add daemons/qits-workspace-daemon`),
never `git add -A` — [`CLAUDE.md`](CLAUDE.md) is explicit that `ignore = all` hides submodule drift
from `status` and `diff` but not from `add -A`.

### 4.8 The three migration documents

**`migration-plan.md`**
- Rewrite §3.3 to what actually happened (§1 of this document).
- Correct §7: drop the `daemon-commands` and `daemon-agents` lineages entirely; they are not squashed,
  they are gone.
- Note in §8 that this target did not use the recipe, and why.
- §9 item 3 (execution-seam flip): the seam did not flip, it **dissolved** — there is no host
  `docker exec` client left to move.
- §9 item 10: closed once §4.6 lands.
- §9 item 15 (**already false**): compiled `.class` files are *not* committed under the daemon's
  `target/` — `target/` is gitignored and `git ls-files | grep target/` returns zero. Strike it.
- §9 item 12: add the assertions this pass dropped — `CommandServiceTest`'s `launchService` and
  `launchAndAwait` coverage (they tested the dead paths), and `AgentSessionLineageIT`, which is
  DB-backed and cannot survive.
- Add a new item for the durability trade (§6).
- §2's file counts for the daemon change.

**`migration-api-map.md`**
- Move rows 17–21 (`/api/commands**`) from 🕓 to ✅ with their new paths.
- Rows 6, 96–99, 121 and the two websockets stay 🕓 until §4.1 and §4.2 land.
- **Row 121 is wrong now**: `POST …/prompt-refinements` is marked ⚠️ stranded → `qits-workspaces`,
  but `PromptRefinementController.java` is in `daemon-agents.txt`. It is 🕓 pending → daemon, not
  stranded.
- Rows 138–140 (`/api/settings`) stay ❔ open — see §3.7.
- **Qualify the "zero drift" claim.** The map's headline property is that no submodule serves an
  operation the monolith does not serve at an identical path — every extraction a move, never a
  redesign. These operations change path *and* semantics (durability). The map needs a third
  category beside "unchanged" and "new path": re-homed and reduced.
- Extend the daemon-endpoint table with the six command routes.

**`migration-manifests/`**
- Move the 48 `daemon-commands.txt` rows into `already-extracted.txt`; the 56 `daemon-agents.txt`
  rows follow when §4.1 lands.
- Move `TerminalSocket.java` out of `workspaces.txt` (§4.3).
- `OtelEnvironment.java` is in `daemon-commands.txt` but was dropped, not carried (§3.4) — record it
  where dropped-rather-than-moved rows go, as `WorkspaceCheckpointService` was.
- Update `assign.py`'s `DAEMON_MOVED` so a rerun cannot silently re-adopt any of these.

---

## 5. Things that will surprise you

### 5.1 `setsid --ctty` is now correct where it used to fail

The host's `CommandRegistry` comments say `setsid -c` "would fail with EPERM re-stealing the
controlling terminal", because `docker exec -it` had already made the shell a session leader owning
the inner TTY. In the container nothing has claimed the terminal yet and the child **must** claim it
— without it `test -t 1` fails and every full-screen TUI (which is what a coding agent in TERMINAL
mode is) drops to line mode. `CommandRegistryTest.theProcessSeesAControllingTerminal` pins this.

The chat path keeps `setsid -w` for the original reason: without `-w` the parent double-forks and
exits, the pipes tear down, and a chat reads EOF before its first turn arrives.

### 5.2 The pid file survived the move, and should have

It looks like docker-era residue and is not. A compound script's children are only reachable through
the process group, so `echo $$ > /tmp/qits-cmd-<id>.pid` plus `kill -- -pgid` is still how a
terminate reaches them — what changed is that reading the file is a local read instead of a
`docker exec cat`. The contents are still validated as digits-only before being interpolated into a
shell line, because the script that wrote it runs from an untrusted checkout.
`CommandRegistryTest.terminateKillsTheWholeProcessGroup` asserts a backgrounded grandchild dies.

The host's last-resort `containers.restart(container)` is gone — a daemon cannot restart the
container it is the process of. `ProcessHandle.descendants()` replaces it.

### 5.3 `GET /commands/actions` is new

The host had no equivalent: actions lived in its featureflow tables and it already knew them. Now
they come from the checkout's `.qits-config.yml`, which only the daemon reads, so it has to be able
to say what it will accept. Nothing consumes it yet.

### 5.4 Response field names are a wire contract, not a naming choice

`CommandJson`'s keys deserialize into the host's existing `CommandDto` / `CommandLogLineDto` /
`AgentSessionRefDto` records, which the SPA consumes unchanged. A renamed key is a broken Commands
view that nothing in the daemon reactor would notice. `CommandsApiTest` asserts them as **literal
strings** for that reason — a test that read them off the records would rename itself along with the
bug. Do the same for the agent DTOs (`AgentSessionNodeDto`, `AgentSubagentDto`,
`InstalledPluginDto`).

Two keys have to be synthesized because they are not on the record: `repoId`/`workspaceId` (ambient,
from `WorkspaceContext`) and `shortCommitHash` (a MapStruct `expression` on the host mapper, not a
stored column).

---

## 6. The durability trade — make sure this stays written down

Nothing in `CommandStore` outlives the container. That is the deliberate scope of the move, and it
costs:

- the Commands list and command logs are **empty** for any workspace whose container was recreated
  or removed;
- `WorkspaceCommandHistory` — the port `qits-workspaces` already declares for the workspace history
  page — can only ever be satisfied for a *running* container. Its contract is keyed on
  `Long workspaceRowId`, which the daemon does not have, so **it needs re-specifying**;
- agent session lineage is lost on recreate, so the resume/fork ownership check
  (`CommandStore.ownsSession`) only holds within one container lifetime. It fails **closed** — a
  resume of a session from a previous container is refused, not allowed;
- `AgentSessionStat` token/cost aggregates are lost.

Transcripts themselves are safe: the harness writes them under `/claude-home`, a volume shared across
workspaces that outlives containers. What became ephemeral is the *index* of them.

Two bounds exist and are tested: `CommandStore.MAX_COMMANDS` (200 finished commands, oldest evicted
first, **running commands never evicted**) and `CommandLogBuffer.DEFAULT_CAPACITY` (50,000 lines per
command, oldest dropped, `dropped()` reports how many). The host had neither — a
`command_log_line` was a CLOB row on a host with a disk; these are heap in a container sized for the
workspace's own build.

---

## 7. Quick checklist

- [ ] `qits-coding-agents` (§4.1)
- [ ] terminal + chat websockets (§4.2)
- [ ] `TerminalSocket.java` manifest row (§4.3)
- [ ] `--enable-native-access` for JVM-mode daemon (§4.4)
- [ ] decide `commandsChanged`: accept or bump the protocol (§4.5)
- [ ] daemon `README.md` + `AGENTS.md` + `CLAUDE.md` symlink (§4.6)
- [ ] `./mvnw verify` from a pristine clone, then push, then gitlink (§4.7)
- [ ] `migration-plan.md`, `migration-api-map.md`, `migration-manifests/` (§4.8)
- [ ] delete this file once the checklist is empty
