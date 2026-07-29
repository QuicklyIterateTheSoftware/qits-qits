# How qits-ci reaches a step container

Status: **phases A–C implemented, unpushed.** Written 2026-07-29, implemented the same day. Every
§8 done-when is met and verified: `mvn verify` green and docker-free in both repos, `CiDaemonGateIT`
4/4 and `CiDaemonHandshakeIT` 3/3 against a real musl-static binary in real containers, `-Dnative`
green on real GraalVM with the gate ITs excluded, and the eradication grep clean. The `Amended as
built` blocks in §2, §3, §5 and §6 record where implementation corrected this document.

**Not done, and not part of A–C:** phase D (the conformance step). **Open operational items:** no
commit has been pushed to any remote; the daemon binary is built but published nowhere, so the
shipped `qits.ci.daemon-version` is blank and its url 404s (honestly, as never-registered) until a
binary is uploaded and the digest configured; and the musl builder image is local-only, so whatever
builds the released binary must build it first. This is the implementation document for
phases A–C of [`finish-ci-feature.md`](finish-ci-feature.md); that outline owns the decisions and
their rationale, this document owns the files, names, and order. Where the two disagree, the
outline's decision stands and this document is the bug. Phase D (the conformance step) is specified
in the outline and needs nothing from this document beyond "ci can run steps". Precedent citations
(`workspace §N`) refer to
[`final-workspaces-and-agent-communication-migration-plan.md`](final-workspaces-and-agent-communication-migration-plan.md).

---

## 1. What is actually true today

Audited, not assumed:

| | Finding |
|---|---|
| Orchestration | `CiRunService.execute` on a **single-threaded** daemon worker; runs across all repos are serialized. The intake returns immediately. This answers the outline's concurrency question: the bound is 1 and stays 1. |
| Step rows | **Persisted upfront** as `PENDING` in `persistRun`, updated in place through `RUNNING` to a terminal state. The outline's persist-at-finish contradicts this; §6 changes it. |
| `CiStep` columns | id, runId, stepIndex, image, status, exitCode, output. **No timestamps.** The outline requires per-step timestamps; §6 adds them. |
| Step execution | `CiDockerRunner.run` blocks on one `docker run --rm <image> bash -c <prelude+script>`; output is a rolling tail read after exit; the prelude failure is inferred from `PRELUDE_FAILED_MARKER` in the tail. |
| The commit-gone dance | When the prelude fails, `CiRunService` re-reads the config source to ask whether the sha was force-pushed away, and **discards the whole run** if so. This semantic must survive the runner swap (§6). |
| Startup sweep | `CiRunService.onStart` already fails runs left `RUNNING` by a crash. The outline's fail-and-reap extends this with container reaping; today nothing reaps. |
| WebSockets in qits-ci | None. `service/pom.xml` has no websockets-next; the host side of the control socket is greenfield. |
| The precedent classes | `DaemonControlSocket` (`@WebSocket(path)` literal carrying its own segment, `@RunOnVirtualThread`, codec + registry split), `WorkspaceDaemonRegistry` (state and correlated traffic), daemon-side `ControlSocket` (vert.x `WebSocketClient`, dial-verbatim, capped backoff). All three are the models to mirror, with the deviations §3 names. |
| `CiTokenFilter` | Matches `UriInfo.getPath()` relative to `quarkus.rest.path`. A `@WebSocket` path is **outside** `quarkus.rest.path`, so the control socket is structurally out of the filter's reach — its auth is the per-container secret, not the intake token, and no filter change is needed or wanted. |
| qits-ci-daemon repo | One seed commit. Everything is greenfield. |

## 2. The wire contract (phase A, module `ci-daemon-protocol`)

The `workspace-daemon-protocol` recipe verbatim: records over a plain `Map`, `Type`/`Field`
constants, `CiDaemonCodec` with encode/decode arms and a round-trip test per message,
`CiDaemonProtocol.CAPABILITY_VERSION = 1`. Package `eu.wohlben.qits.cidaemon.protocol`. Vendored
byte-identical into qits-ci (`services/qits-ci/ci-daemon-protocol/` as a third maven module, or the
package mirrored into `ci/` — match how qits-workspaces vendors, which is a whole mirrored module),
kept honest with `diff -r`.

**Dial.** `GET $QITS_CI_DAEMON_URL` upgraded to WebSocket, with two headers:
`X-Qits-Ci-Daemon-Id`, `X-Qits-Ci-Daemon-Secret`. No identity in the path — the workspace control
socket identifies its caller by path parameter and workspace §9 item 22 records that as its known
impersonation bug; ci does not reproduce it. The host validates both headers against the in-memory
launch record in `@OnOpen` (websockets-next exposes the handshake via
`connection.handshakeRequest()`) and closes with 1008 on any mismatch, before processing a single
frame.

**Messages, daemon → host:**

| Message | Fields | Meaning |
|---|---|---|
| `Hello` | `daemonId`, `capabilityVersion` | First frame after upgrade. Host replies `Ack`. |
| `Initialized` | — | Clone + checkout done, ready for the step. |
| `InitFailed` | `reason` (`CLONE_FAILED` \| `SHA_GONE` \| `TOOLING_MISSING`), `detail` | Setup failed; `SHA_GONE` is what carries the commit-gone semantic (§6). `detail` is bounded (one tail, same budget as a chunk). |
| `StepChunk` | `correlationId`, `seq` (`long`), `stream` (`OUT`\|`ERR`), `text` | Live output. `correlationId` from day one per outline decision 7, so a later second-socket split never changes the shape. `seq` is a per-correlation monotonic counter — ordering assertion, gap detection in tests. |
| `StepFinished` | `correlationId`, `exitCode`, `timedOut` | The step's terminal frame. `timedOut=true` means the daemon killed its child at the deadline; `exitCode` is then the kill's, not the script's. |
| `Heartbeat` | — | Every 10s from dial until close. |

**Messages, host → daemon:**

| Message | Fields | Meaning |
|---|---|---|
| `Ack` | `capabilityVersion` | Handshake close. A daemon seeing a version it does not know exits nonzero (the log is the diagnosis; there is no compat mode at version 1). |
| `RunStep` | `correlationId`, `script`, `timeoutSeconds` | The reply to `Initialized`. Exactly one per container lifetime. |
| `Cancel` | `correlationId` | Kill the child, answer with `StepFinished`. |

Everything else — repository url, branch, sha, ids — arrives as env, not as messages: the daemon
needs it before the socket exists.

**Amended as built (wave 0).** Two shapes this table left open, settled in the module and recorded
here rather than left to drift:

- **Enum wire form is `name()`**, the `workspace-daemon-protocol` convention (`DaemonCodec` writes
  `m.stream().name()` and reads `Stream.valueOf`). So `stream` is `OUT`/`ERR` and `InitFailed`'s
  `reason` is `CLONE_FAILED`/`SHA_GONE`/`TOOLING_MISSING`, uppercase on the wire. The lowercase
  `out`|`err` above was prose, not a contract.
- **Types:** `seq` is `long`; `capabilityVersion`, `exitCode`, `timeoutSeconds` are `int`;
  `timedOut` is `boolean`; `detail` is a nullable `String`.

**Decode strictness, which the host socket must be built against:** an unknown or missing `type`
and an unknown `reason` both throw `IllegalArgumentException`, and an absent `stream` NPEs — the
precedent's strictness, deliberately not softened. `CiDaemonSocket` therefore catch-and-logs an
undecodable frame the way `DaemonControlSocket` does; without that, one malformed frame from a
container kills the connection.

One asymmetry inside that, deliberate and worth knowing before it surprises someone: an **absent**
`reason` decodes to `null` rather than throwing, where an absent `stream` NPEs. The rationale is
that a malformed `InitFailed` should still reach the host as a recordable failure instead of
vanishing into the undecodable-frame log. The consequence is a host-side obligation: **§6's outcome
mapping must treat `InitFailed{reason=null}` as a generic `INIT_FAILED`**, never dereference it,
and never let it fall through the `SHA_GONE` branch that drives the commit-gone discard. A hostile
daemon can send exactly that frame.

Note `Ack` carries `capabilityVersion` where the workspace protocol's `Ack` is field-less. The host
must send it: a daemon reading no version reads 0, mismatches, and exits nonzero.

## 3. Phase A — the daemon (repo qits-ci-daemon)

Two modules, the workspace-daemon shape at one-fifth the size:

- **`ci-daemon-protocol/`** — §2. Framework-free, depends on nothing.
- **`ci-daemon/`** — the Quarkus application. Mirrors `ControlSocket`'s dial mechanics (vert.x
  `WebSocketClient`, URL dialled verbatim from `QITS_CI_DAEMON_URL`) with one deliberate
  inversion: **the workspace daemon never exits; this daemon always exits.** One step, one
  container lifetime. Any terminal condition — `StepFinished` sent, `InitFailed` sent, `Ack`
  version mismatch, dial failure after a short capped retry (~30s total, not infinite: a daemon
  that cannot reach its host is a container the host will reap on timeout anyway) — ends the
  process. Exit code 0 only on the clean paths (result delivered); nonzero otherwise, so
  `docker logs` of a reaped container reads honestly.

Internals, all plain classes with plain constructors, wired by the one CDI shell:

- `Workspace` — `git clone --depth 50 --branch $QITS_CI_BRANCH $QITS_CI_REPOSITORY_URL /workspace`
  then `git checkout $QITS_CI_SHA`, shelling the image's own git (the image contract). Depth 50
  rather than 1 so a recent-but-not-tip sha is still present; a checkout failure after a
  successful clone reports `SHA_GONE` (the outline's force-push backstop), a clone failure
  `CLONE_FAILED`, a missing `git`/`bash` binary `TOOLING_MISSING`.
- `StepProcess` — `bash /workspace/.qits-ci-step.sh`? No: `bash -c <script>` with CWD
  `/workspace`, the script passed as one argv element exactly as today's composite does — inside
  the container this is the designed execution of the hostile code, and the daemon is its parent.
  stdout/stderr pumped as separate streams into bounded chunking (flush on newline or 8KiB or
  100ms, whichever first — chatty steps must not produce a frame per byte). Enforces
  `timeoutSeconds` locally: SIGTERM, 5s grace, SIGKILL, then `StepFinished{timedOut=true}`.
- `DaemonMain` flow: dial → `Hello`/`Ack` → initialize → `Initialized` → await `RunStep` →
  stream → `StepFinished` → close → exit. A `Cancel` at any point after `RunStep` kills the
  child. A socket close before `RunStep` is an exit, not a retry — the host has reaped us.

**The shipping form is a fully static musl native image** (`--static --libc=musl` via the
container build). This is the phase's named spike, gated before anything else is built on it:
`file` reports a statically linked binary, and the same binary runs `--version` in `alpine:3` and
`debian:bookworm-slim` containers. If musl static fails in spike, **stop and re-plan delivery** —
do not quietly ship glibc and shrink the image contract.

**Spike result (wave 0): PROVEN.** Quarkus 3.34.6, a vert.x `WebSocketClient` in the image,
`--static --libc=musl`, running in both distros. The gate does not trigger and the outline's
`docker cp` fallback stays superseded. What the spike changed:

- **The builder image is NOT the one qits-workspace-daemon uses, and cannot be.** Mandrel ships
  static JDK libs for glibc only (`.../static/linux-amd64/glibc`); a musl static build dies at
  `[1/8] Initializing` with *"target libc: musl is not supported on your platform. Missing
  libraries: java, nio, net"*, and those `.a` files are part of the JDK distribution, so it is not
  installable after the fact. GraalVM CE ships both. Base is therefore
  `quay.io/quarkus/ubi10-quarkus-graalvmce-builder-image:jdk-25` **plus a locally added musl
  toolchain and musl-built zlib** — no musl-flavoured builder tag exists on quay for any Quarkus
  builder image, so the image is built locally and is local-only. **Carry a comment saying why**,
  or someone will helpfully harmonize this back to the Mandrel image the sibling repo uses and
  break the build.
- **Expose the musl toolchain through a shim directory** holding only the `x86_64-linux-musl-*`
  symlinks. Putting `/opt/musl/bin` on PATH shadows the system `gcc` and breaks any glibc build in
  the same image.
- **`quarkus.native.pull-always` is dead and silently ignored on 3.34** — the key is
  `quarkus.native.builder-image.pull=missing`, and without it every build fails trying to `docker
  pull` an image that only exists locally.
- **The acceptance check must not grep for the literal `statically linked`.** `file` reports
  `static-pie linked` on this binary; it is genuinely fully static (`ldd` says `statically linked`,
  and it runs in `distroless/static-debian12`). Assert on `ldd`, or on `static-pie`.
- Reflection/resource registration for vert.x: **none needed**, zero config. Size cost is
  negligible (+4.8% over glibc-dynamic, which does not run in alpine at all).
- Probed beyond the mandate and clear: DNS on a real docker network, a real WebSocket handshake,
  and `ProcessBuilder` fork/exec returning child stdout/stderr/exit — the last matters because a
  static image ships no `jspawnhelper` and both `Workspace` and `StepProcess` shell out.

Open, and a packaging decision rather than a technical one: the builder image is local-only, so
whatever builds the released binary must build or pull it first.

**The bootstrap** is not in this repo — it is a constant in qits-ci (§5) — but its contract is
fixed here: the daemon binary is served at `$QITS_CI_DAEMON_BINARY_URL`, is the direct output of
this repo's native build, and takes no arguments (env only).

Conventions carried over wholesale: clone-alone `./mvnw verify`, plain JUnit 5, no Mockito, real
processes and real sockets in tests (`StepProcessTest` drives a real `bash`; `DaemonMainTest`
dials a real in-JVM vert.x server), `@EnabledOnOs(LINUX)` where OS-bound, sentence test names,
FFM downcall registration rules if a PTY ever appears (it should not — steps get pipes, not
terminals).

**Repo docs:** a `README.md` (boundary: everything inside the step container; one binary, one
step, one container lifetime) and `CLAUDE.md` (the two rules, module conventions, protocol-change
recipe including the vendor-mirror step into qits-ci).

## 4. Phase A tail — the submodule (repo qits-qits)

The `CLAUDE.md` recipe, `--name` included:

    git submodule add --name qits-ci-daemon https://github.com/QuicklyIterateTheSoftware/qits-ci-daemon daemons/qits-ci-daemon
    git config -f .gitmodules submodule.qits-ci-daemon.ignore all
    git config -f .gitmodules submodule.qits-ci-daemon.update merge
    git submodule set-branch --branch main daemons/qits-ci-daemon
    git add .gitmodules daemons/qits-ci-daemon && git commit

Confirm with `git ls-tree HEAD daemons/qits-ci-daemon` (a `160000 commit` entry) — `ignore = all`
hides the gitlink from `show`/`diff`.

## 5. Phase B — the communication path (repo qits-ci)

New package `eu.wohlben.qits.ci.daemonhost` in the **service** module — the transport lives beside
the API exactly as qits-workspaces keeps `daemonhost` in its service module. This amends the
CLAUDE.md sentence "`service/` — `api` only"; update it in the same commit rather than leaving the
docs claiming a boundary the tree no longer has. The `ci/` module keeps the seam (`CiStepRunner`)
and the orchestrator; it gains no web dependency.

- **`CiDaemonSocket`** — `@WebSocket(path = "/ci/daemon")`, the `DaemonControlSocket` split:
  lifecycle and JSON framing only, registry owns everything else. The path literal carries `/ci`
  itself (a `@WebSocket` path ignores `quarkus.rest.path`). Dialled directly on
  `qits.ci.network` at qits-ci's own port; it is not a gateway route and no gateway change
  exists in this plan. `@OnOpen` validates the two headers against the registry and closes 1008
  on unknown id, wrong secret, or a re-dial for a daemon already connected.
  Adds `io.quarkus:quarkus-websockets-next` to `service/pom.xml` — a native-image-supported
  extension; `CiPackagedSurfaceIT` under `-Dnative` is what proves that claim.
- **`CiDaemonRegistry`** — the in-memory launch table: `daemonId → {secret, runId, stepIndex,
  connection, phase, listener}`. Minting (`registerLaunch`), header validation, message dispatch,
  and the blocking bridge the runner uses: the worker thread parks on a `CompletableFuture` per
  lifecycle transition (registered, initialized, finished) with the timeout for that transition,
  while chunks flow to the step's listener as they arrive. Secrets are `SecureRandom`, compared
  with `MessageDigest.isEqual`, deleted on reap.
- **`CiDaemonLauncher`** — the docker argv, everything `CiDockerRunner.buildArgv` does minus the
  script and plus the contract: same sandbox flags (`--cap-drop=ALL`, `no-new-privileges`,
  memory/pids/cpus caps, `--network`, `--label qits.ci.run=<runId>`, `--add-host`), the
  entrypoint override to the **bootstrap constant** (`--entrypoint /bin/sh`, args `-c <BOOTSTRAP>`
  — a `static final String`, host-authored, zero interpolation of repo content, checked by an
  argv-assembly test exactly like today's), and the env contract:
  `QITS_CI_DAEMON_ID`, `QITS_CI_DAEMON_SECRET`, `QITS_CI_DAEMON_URL`,
  `QITS_CI_DAEMON_BINARY_URL`, `QITS_CI_REPOSITORY_URL` (from `qits.ci.container-git-url` +
  `/git/<repoId>`, the `cloneUrl` logic moved here), `QITS_CI_BRANCH`, `QITS_CI_SHA`,
  `QITS_CI_REPO_ID`, `CI=true`, `QITS_CI=true`.
  The bootstrap: probe `wget` then `curl`, download `$QITS_CI_DAEMON_BINARY_URL` to
  `/tmp/qits-ci-daemon`, `chmod +x`, `exec`. Its failure output goes to the container's stdout,
  which is why the never-registered reap below captures `docker logs`.
  `ensureNetwork` moves here from `CiDockerRunner` unchanged. Containers run **detached**
  (`docker run -d`) — the host no longer reads a pipe, it reads a socket — so `--rm` goes away
  and every teardown path is an explicit `docker rm -f` (detached `--rm` would race the
  `docker logs` capture).
- **Config keys** (in `ci/`'s `microprofile-config.properties` with the existing ones):
  `qits.ci.daemon-version` (the label persisted per run),
  `qits.ci.daemon-binary-url-template` (contains `{version}`; resolved once per run and injected
  — the two keys move together and the template keeps them from drifting).
  **Wave-0 scout result, which settles decision 1's deferred checksum paragraph:** qits-artifacts
  has no raw-file surface, but its OCI blob route already is one — `GET /v2/<name>/blobs/sha256:<hex>`
  requires no manifest and no tag, and reads are never authenticated (`RegistryAuthGuard` guards
  only write verbs). So the shipped default is
  `http://qits-artifacts:8080/v2/qits/ci-daemon/blobs/sha256:{version}` with `{version}` being the
  binary's **sha256** — the version pin and the integrity pin are the same field, re-verified by the
  registry at publish time, and no separate checksum column is needed on the run. Publishing is one
  `POST /v2/qits/ci-daemon/blobs/uploads/?digest=sha256:<hex>`; the `qits` repository row must exist
  as `oci-images` (the seeder makes only `ci-screenshots`/`ci-videos`). Accepted cost: a run row
  shows a digest, not a version number. A version-addressed `RELEASES` type in qits-artifacts is
  ~one commit if that ever matters, and would be a config edit here, not a code change.
  `qits.ci.container-daemon-url` (default `ws://qits-ci:8080/ci/daemon`, the told-never-derived
  dial target), `qits.ci.daemon-register-timeout-seconds` (default 60 — covers image pull +
  download), `qits.ci.daemon-init-timeout-seconds` (default 120 — covers the clone).
- **Failure states, distinguishable by construction** (workspace §9's second risk): launch
  failed (docker error) / never registered (timeout — reap **after** capturing a bounded
  `docker logs` tail, which is the bootstrap's own error report) / registered but never
  initialized (timeout, same capture) / `InitFailed{reason}` / socket lost mid-step. Each maps
  to a distinct recorded outcome in §6; none of them is "the step failed with exit −1" except
  the ones that genuinely are.
- **Boot reconciliation** — extend the existing `onStart` sweep: after failing `RUNNING` rows,
  `docker ps -q --filter label=qits.ci.run` and `docker rm -f` the results. The registry starts
  empty, so a daemon from a previous life dialling in presents an unknown secret and is closed
  1008; its container is already gone or about to be.
- **The phase-B gate** — `CiDaemonHandshakeIT` (tag `extended`, `-DskipITs=false`, same
  host-networking assumption as today's `CiDockerRunnerIT`, documented the same way): real
  docker, an image satisfying the contract (`buildpack-deps:scm` has git+bash+curl; pin whatever
  the implementer verifies), a file-served daemon binary standing in for qits-artifacts
  (`$QITS_CI_DAEMON_BINARY_URL` can point anywhere — that is the point of it being env), one
  full register → initialize → `RunStep`(trivial script) → `StepFinished` round-trip through a
  real container, plus one wrong-secret dial closed 1008 and one never-registered reap with its
  `docker logs` capture asserted.

Phase B lands **behind the existing runner**: `CiDockerRunner` still executes production steps
until phase C swaps the seam. The registry, socket, and launcher are inert until then — reachable
only by the gate IT. That keeps phase B one honest commit without a half-migrated pipeline.

## 6. Phase C — step execution over the daemon (repo qits-ci)

- **The seam reshapes** (outline decision 5): `CiStepRunner` becomes
  `StepResult run(StepSpec spec, StepListener listener)` — still one blocking call per step, so
  `CiRunService.runSteps`' sequential loop and transaction shape survive intact. `StepSpec` gains
  `daemonBinaryUrl` and `timeoutSeconds`; `StepResult` becomes
  `{exitCode, timedOut, outcome, output}` where `outcome` is
  `OK | SHA_GONE | INIT_FAILED | NEVER_INITIALIZED | LAUNCH_FAILED | NEVER_STARTED |
  CONNECTION_LOST` — `workspaceReady` and the sentinel die here. The commit-gone dance keys on
  `outcome == SHA_GONE` (the daemon's checkout is now the probe) with the existing config-source
  re-read kept as confirmation before discarding the run.

  > **Amended as built (wave 2).** That list had five constants and §5 names five *failure* states
  > it must keep distinguishable — "launch failed (docker error)" and "never registered" are
  > separate there, as are "registered but never initialized" and `InitFailed{reason}`, and §5 says
  > each maps to a distinct recorded outcome. Five names cannot carry five failures plus success,
  > so the built enum has seven: `LAUNCH_FAILED` (docker refused; no container, so no log to
  > capture) is split from `NEVER_STARTED` (the container ran and nothing ever dialled — its own
  > `docker logs` tail becomes the step's output), and `NEVER_INITIALIZED` (registered, then silent
  > past the deadline) is split from `INIT_FAILED` (a structured `InitFailed`, including the
  > null-reason frame §2's amendment requires be handled generically). Folding any pair back
  > together would delete exactly the distinction §5 asks for.
  >
  > `StepSpec` also gains **`branch`**, which the list above omits: the launcher's env contract
  > needs `$QITS_CI_BRANCH` and the spec is the only thing crossing the seam. Mechanical, recorded
  > so the field list is not read as exhaustive.
- **`CiDaemonStepRunner`** (in `daemonhost`) is the sole implementation: mint → launch → await
  register/init → send `RunStep` → relay chunks to the listener while accumulating the bounded
  tail (`CiRunService.tail`'s budget, applied incrementally) → await `StepFinished` → reap →
  return. Host-side step timeout = `timeoutSeconds` + grace as the backstop behind the daemon's
  own enforcement; on breach, `Cancel`, then `docker rm -f`.
- **Persist-at-finish**: `persistRun` stops creating step rows. A `CiStep` row is inserted
  terminal — `SUCCESS`/`FAILED` with exitCode and output at `StepFinished`, `FAILED` with the
  outcome's message on the failure states, `SKIPPED` rows for the never-run remainder written
  when the run closes. `PENDING`/`RUNNING` remain in the enum for legacy rows but are never
  written again; the startup sweep keeps handling them.
- **Migration `V2__daemon_runs.sql`**: `ci_run.daemon_version varchar(64)`;
  `ci_step.started_at timestamp`, `ci_step.finished_at timestamp` — both host-stamped
  (started = `RunStep` sent, finished = terminal frame received or timeout fired), per the
  outline's forged-clock rule. Appended to the existing lineage, never edited.
- **The live relay**: `CiStepRelay` in `daemonhost` — per running step, the last
  `qits.ci.output-max-chars` of chunk text plus `currentStepIndex`, fed by the listener, dropped
  when the step's row is written. Read surface (outline decision 8, poll-first): the existing
  `GET /ci/api/runs/{runId}` answer gains a nullable `live` object
  (`{stepIndex, output}`) populated from the relay while `status == RUNNING` — so a mid-run poll
  is legible instead of looking like a run with missing steps. No SSE, no WebSocket, no new
  endpoint for reading.
- **Cancellation**: `POST /ci/api/runs/{runId}/cancel` → 202, `@Operation(hidden = true)` is
  **not** applied — unlike the machine surfaces this one is for the user. It sits on the same
  deployment-policy-guarded surface as the run reads (single-user stance; no token). It flags the
  registry; the runner's in-flight await completes with the cancelled outcome, the run records
  `FAILED` with the running step `FAILED` ("cancelled" in its output tail) and the rest
  `SKIPPED`. Cancelling a non-running run is a 409.
- **Per-step timeout**: `timeout-seconds` as an optional per-step key in
  `.config/qits/ci-post-receive.yml` (additive over the `steps` core, exactly the extension path
  `CiPipeline`'s javadoc reserved), defaulting to `qits.ci.step-timeout-seconds`. Absent field =
  current behaviour; the parser's existing unknown-field stance is untouched.
- **Eradication** (outline decision 5's inventory, executed here): delete `CiDockerRunner`,
  `CiDockerRunnerIT`, the `PRELUDE_FAILED_MARKER` constant and every doc/javadoc mention,
  `StepResult.workspaceReady`; rewrite both `FakeCiStepRunner`s as scripted-event fakes (invoke
  the listener with declared chunks, return the declared result — no processes, no `bash`);
  re-derive config (`container-git-url`, caps, network, `step-timeout-seconds`,
  `output-max-chars` all survive with new call sites; no old-path-only key remains); rewrite the
  README/CLAUDE.md sections that describe the old runner (the "Host-side by design" section
  becomes the daemon story; the never-executes invariant from the outline goes into CLAUDE.md's
  untrusted-input section). Done-when grep, both modules, main and test:
  `grep -rn "bash -c\|PRELUDE_FAILED\|docker exec"` finds only the daemon-side `StepProcess`
  reference in vendored protocol docs — i.e. nothing that executes.
- **The phase-C gate** — `CiDaemonGateIT` extends the phase-B gate to the full outline §2
  lifecycle: a two-step pipeline through the real intake path with live chunks observed via the
  `live` object mid-run, per-step rows with timestamps after, a cancellation honored mid-step,
  and a step timeout recorded as timed-out rather than failed.

## 7. Order

1. **Phase A** in qits-ci-daemon: protocol module + codec tests first, then the static-musl spike
   (**stop/re-plan on failure**), then the daemon app, `./mvnw verify` green and a manual
   `docker run` smoke against a hand-started ws server.
2. **Submodule commit** in qits-qits (§4).
3. **Phase B** in qits-ci: vendor the protocol, `daemonhost` package, config keys, boot
   reconciliation, gate IT. One commit; production behaviour unchanged.
4. **Phase C** in qits-ci: seam reshape + runner + persist-at-finish + migration + relay + cancel
   + timeout + eradication + gate. This is the large commit; if it needs splitting, the seam
   reshape with fakes goes first and the eradication goes **in the same commit as the swap**,
   never after (a window where both runners exist is the thing decision 5 forbids).
5. Docs: qits-ci README/CLAUDE.md rewrites ride the phase-C commit; the outline's status line
   flips per phase.

## 8. Done when

A push to a repo with a two-step config produces, with no human in the loop: two containers run in
sequence, each registering with its minted secret, cloning its own shallow checkout at the pushed
sha, receiving its script as the reply to `Initialized`, streaming output the run read surface
exposes live mid-run, and dying reaped; a run row pinned to one daemon version; two terminal step
rows with host-stamped timestamps written only at each step's end; a cancellation mid-step-1
recording step 1 failed-cancelled and step 2 skipped; a qits-ci restart mid-run yielding a failed
run, zero orphaned containers, and a refused stale dial; the eradication grep clean; `mvn verify`
green with no docker; `-Dnative` green with the gate ITs excluded exactly as today.

## 9. Risks

- **The musl static build is load-bearing and unproven.** It is step 1 inside phase A for that
  reason. Known sharp edges: the build container needs the musl toolchain; vert.x native config
  is exercised by workspace-daemon already, but not `--static`. If it fails, delivery re-plans
  (the outline's superseded `docker cp` candidate is the fallback shape) — nothing downstream
  changes except the launcher.
- **websockets-next in a native qits-ci.** Supported extension, but this repo's rule is that the
  binary's ITs are the proof; `CiPackagedSurfaceIT` gains a route-presence assertion for
  `/ci/daemon` so a native build that silently dropped the endpoint fails loud.
- **The single worker thread now parks on sockets, not processes.** Same blocking discipline,
  new failure mode: a registry future that never completes would wedge all CI. Every await in
  `CiDaemonRegistry` carries its transition's timeout; there is no untimed `get()` anywhere in
  `daemonhost` — worth a dedicated test.
- **Chunk flood.** A step spraying output must cost bounded memory (relay and tail are both
  capped) and must not starve the event loop — chunks are handled on virtual threads like the
  workspace registry's traffic, and the daemon's 8KiB/100ms flush bounds frame rate at the
  source. The gate IT includes a noisy step (`yes` for a second) for exactly this.
- **Two documents can drift.** This one restates outline decisions as mechanics; if
  implementation contradicts either, amend the document in place and say why (the workspace
  plan's own rule), in the same PR as the contradiction.

## 10. Delegation — who can work in parallel, and where the fences are

§7's commit order is the truth about *landing*; this section is about *working*. The dependency
graph has exactly two hard edges — everything references the protocol module, and phase C swaps
what phase B built — and one soft edge (phase B's gate needs phase A's binary to *run*, not to be
written). That yields three waves. The fences that make the waves safe:

> **One writer per repo per wave.** The submodules are separate git repos, which is the natural
> isolation boundary — two agents in different repos cannot conflict; two agents in one repo will.
> Never split one repo's wave-work across agents to chase parallelism inside a pom.
>
> **The vendored protocol has one author.** Only the qits-ci-daemon agent edits
> `ci-daemon-protocol`; the qits-ci agent copies it whole and runs `diff -r`, never edits it. A
> "small fix" applied to the vendored copy is the drift §9 item-19 precedent warns about.
>
> **Scouts return findings, not commits.** The spike and scout tasks below deliver a written
> result the implementing agent applies; merging scratch work from a spike is how a pom gets two
> parents.

**Wave 0 — three agents, fully parallel, all small:**

- **Protocol agent** (qits-ci-daemon): the `ci-daemon-protocol` module of §2, codec, round-trip
  tests, `mvnw` scaffolding for the repo. Everything else waits on this, so it goes first and
  stays minimal — no daemon app code.
- **Musl-spike agent** (isolated worktree or scratch checkout, *not* the repo's main): prove
  `--static --libc=musl` on a hello-world Quarkus native build with a vert.x WebSocket client in
  it; deliver the exact build args, builder-image choice, and the two-image run check of §3 as a
  findings note. **Stop/re-plan on failure applies here** — this agent failing halts wave 1's
  daemon work and reopens the outline's delivery decision; nothing else is invalidated.
- **Artifacts scout** (read-only, qits-artifacts): confirm how a raw versioned binary gets
  published and served at a stable URL, or report that no such surface exists — in which case
  serving it is a *separate qits-artifacts change* to schedule, and the gate ITs proceed
  regardless on their file-served stand-in. Findings only; touches nothing.

**Wave 1 — after the protocol module is merged; two implementing agents in different repos,
plus one trivial commit:**

- **Daemon agent** (qits-ci-daemon): the `ci-daemon` app of §3, applying the spike's findings.
  Owns the protocol module from here on (any message-shape correction discovered while
  implementing is its commit, followed by a re-vendor ping to the phase-B agent — expect one or
  two of these; that channel existing is why the mirror rule matters).
- **Phase-B agent** (qits-ci): everything in §5. Builds and tests the socket, registry and
  launcher against an **in-JVM fake daemon dialler** (real websocket, scripted frames — the
  registry cannot tell), so no part of its work blocks on the daemon existing. Writes
  `CiDaemonHandshakeIT` last, against whatever binary the daemon agent has published; if wave 1's
  daemon finishes later, the IT is the sync point, not the package.
- **Submodule commit** (qits-qits, §4): any agent or the orchestrator, once the daemon repo's
  first commits are pushed. Thirty seconds; do not parallelize around it, just do it.

**Sync point:** `CiDaemonHandshakeIT` green against the real daemon binary. This is the only
moment both wave-1 tracks must exist at once, and nothing in wave 2 starts before it — phase C
builds directly on both sides of that handshake being real, not faked.

**Wave 2 — one agent, deliberately serial:**

- **Phase-C agent** (qits-ci): all of §6 as one atomic swap, per §7 step 4. Not split, and not
  paired with a parallel docs agent — the README/CLAUDE.md rewrites describe the code this agent
  is changing and belong in its commit. The temptation to fan out here (relay to one agent,
  persistence to another) buys merge conflicts inside one package in exchange for nothing: the
  swap commit is indivisible by decision 5.

**Reviews ride the boundaries, in parallel with the next wave:** a review agent on the protocol
module while wave 1 starts (the wire contract is the most expensive thing to get wrong and the
cheapest to review — it is two tables in §2); a review agent on phase B's `daemonhost` — argv
assembly and secret handling foremost — while the daemon agent finishes; a full review after
phase C, before the docs flip to done. A review never blocks the wave it reviews, only the next
one.
