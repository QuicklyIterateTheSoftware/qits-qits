# Finish the ci feature — outline

Status: **phases A–C implemented and pushed; phase D open; phase E named only.** Written
2026-07-29, iterated and implemented the same day. §1's "what finished means" is delivered except
the conformance step: live step output, cancellation, per-step timeouts, and the structured step
lifecycle all run through a `qits-ci-daemon` inside each step container, and `CiDockerRunner` was
eradicated rather than retired, per decision 5. Decision 1's deferred checksum question is settled —
the shipped binary url is qits-artifacts' OCI blob route, so the version pin and the integrity pin
are the same field. Decision 7 landed as **one** socket: chunks carry a correlation id from day one,
so the split stays additive and unforced.

Proven on a live stack, not only by tests: a `git push` to qits-artifacts drove a two-step run whose
containers downloaded the daemon from qits-artifacts' own blob route, cloned the pushed sha, streamed
output observable mid-run, and were reaped — and a `SIGKILL` of qits-ci mid-run left an orphan that
the next boot swept while marking the run `FAILED`.

The phase A–C implementation document is **retired**: that work is in tree, and the corrections it
accumulated live where they are load-bearing rather than in a plan — the musl builder's rationale in
qits-ci-daemon's `docker/Dockerfile.musl-builder` and `README.md`, the wire contract's decode
strictness in `CiDaemonSocket`, the null-reason obligation in `CiDaemonStepRunner`, the seven step
outcomes on `CiStepRunner`, and the daemon binary url in qits-ci's shipped config. What it left
behind is [`ship-the-ci-daemon.md`](ship-the-ci-daemon.md).

This file started as the conformance-suite plan alone; that content survives as phase D. This
outline owns the decisions and their rationale. Phase D needs no further document; §7 holds the
remaining confirmations. Precedent throughout is
[`final-workspaces-and-agent-communication-migration-plan.md`](final-workspaces-and-agent-communication-migration-plan.md)
— cited below by its section numbers.

---

## 1. What "finished" means

qits-ci today records a per-step pass/fail per push, advisory, with each step's output captured as
a rolling tail **after the step ends**. Finished means:

- **Live step output** — a running step's stdout is observable while it runs, streamed to the host
  so a user can follow along; persisted output is a separate, second thing (§2).
- **Cancellation** — a run (and its running step's container) can be terminated on request.
- **Per-step timeouts** — declared in the pipeline config, enforced in-band, distinguishable from
  failure (today one global `qits.ci.step-timeout-seconds` and a host-side kill).
- **Structured step lifecycle** — per step: launched → registered → initialized → running →
  finished, visible on the run, replacing the prelude-sentinel inference
  (`PRELUDE_FAILED_MARKER`).
- **The OCI conformance suite as a standing step** — the one open item of the registry feature
  (phase D).
- Explicitly still follow-ups, not part of finished: retries, a non-advisory gate,
  clone/dependency caching across the per-step containers. Phase E names them so they stay named.

## 2. The architectural move

**qits-ci gets the same relationship to its containers that qits-workspaces has to workspace
containers.** ci initializes the container; the container runs a `qits-ci-daemon`
(github.com/QuicklyIterateTheSoftware/qits-ci-daemon, seeded, to be added as
`daemons/qits-ci-daemon`) that handles the execution of code inside it; the daemon **dials
outbound** and the host never dials in.

### The lifecycle, concretely

**One container per step.** The run is a host-side sequence: ci launches a container for step 1,
and only that step's completion notification triggers the launch of step 2's container, which
starts off the same way — it registers, it is supplied what it has to do, it returns. Theoretically
unbounded, realistically limited by the step count a pipeline config sanely declares. Each step
keeps its own repo-declared image and its own fresh clone, so today's documented isolation
property — "no state crosses steps" — survives unchanged.

Per step, then:

1. **Launch.** qits-ci starts the step's container from the step's declared image, with the daemon
   injected (§4 decision 1) and
   the contract passed as env: `$QITS_CI_DAEMON_ID` (the registration identity, host-minted),
   `$QITS_CI_DAEMON_SECRET` (§4 decision 4), `$QITS_CI_DAEMON_URL` (the control URL, dialled
   verbatim), `$QITS_CI_DAEMON_BINARY_URL` (the run-pinned daemon version's download url, §4
   decision 1), `$QITS_CI_REPOSITORY_URL`, `$QITS_CI_BRANCH`, `$QITS_CI_SHA`, `$QITS_CI_REPO_ID` —
   plus `CI=true` (the de-facto convention step tooling already checks for non-interactive mode)
   and `QITS_CI=true` (so a script can tell *this* CI from any other), both set for the step
   scripts' benefit rather than the daemon's.
   Note `$QITS_CI_SHA` is not in the original sketch and must be: a daemon that clones by branch
   name alone tests whatever the branch points at by the time the container boots, so a racing
   push silently changes what the run row claims was tested. The daemon checks out the sha; the
   host keeps its existing ancestor verification before launching at all.
2. **Register.** The daemon dials the control socket and registers in qits-ci's **ci-daemon
   registry** (the `WorkspaceDaemonRegistry` analog), presenting id + secret.
3. **Initialize.** The daemon does its own setup — shallow clone of `$QITS_CI_REPOSITORY_URL` at
   `$QITS_CI_BRANCH`, checkout of `$QITS_CI_SHA` — and reports `Initialized` (or a structured
   failure, which is what retires the prelude sentinel).
4. **The step arrives as the answer.** The host replies to `Initialized` with this step's script —
   the pipeline config stays host-parsed (`GitConfigFetcher` against ci's bare cache, unchanged);
   the container receives only its script, never the config file. This is a nice property of the
   pull shape: the host never initiates anything toward the container, the work rides a reply on
   the socket the daemon opened.
5. **Execute and stream.** The daemon runs the script in the checkout, streaming stdout/stderr
   over the socket as it is produced, then the completion (exit code) — the notification "for
   completeness" that the registry turns into the next step's launch. Timestamps are
   **host-stamped at message receipt**, not daemon-reported — the daemon is hostile once step code
   runs (below), and a clock claim is the cheapest thing to forge.
6. **Persist at finish, relay while running.** Live chunks feed an in-memory, bounded relay so a
   user can follow along; **the step's DB entity is created only when the step finishes**, one row
   per step with timestamps, exit code, and the bounded output tail. Mid-run, the run row carries
   the lifecycle state and the relay carries the output; the DB never holds a half-written step.
7. **Teardown, advance.** On the step result (or cancellation, timeout, lost socket), the host
   reaps the container — `--rm` plus an explicit `rm -f` on the abnormal paths, as today — and
   launches the next step's container, or closes the run after the last one.

> ### qits-ci never executes anything — it starts containers, and that is all.
>
> The invariant, stated so a review can check a diff against it: **no code path in qits-ci runs
> repo-controlled code as a host process, and none runs it through `docker exec`.** Step scripts
> reach a container only as the reply on the socket that container's daemon dialled, and execute
> only as that daemon's child. qits-ci's entire docker vocabulary is container lifecycle —
> `run`/`create`/`cp`/`start`/`rm`, `network inspect`/`create` — and `exec` is not in it, not
> even as a delivery mechanism for the daemon binary (§4 decision 1's candidates are chosen
> inside this rule). The moment `CiDockerRunner` is retired (phase C), the only host processes
> qits-ci spawns are the `docker` CLI for that lifecycle and its own `git` against its bare cache
> for config fetch and ancestor verification — ci tooling over ci-owned state, never pipeline
> content. `bash -c <anything from a repo>` appearing anywhere in qits-ci, host-side or in a
> docker argv, is the regression this box exists to make unambiguous.

What does **not** change: a step's script is repo-controlled hostile code and the container is a
sandbox — `--cap-drop=ALL`, `no-new-privileges`, resource caps, no docker socket. The daemon lives
*inside* the sandbox and executes the hostile code as its child, so from the moment step 5 begins,
everything arriving from that container is attacker-influenceable data about the run — recorded,
never trusted (the host-side stamping above is one consequence; the secret's scope in §4 decision
4 is another).

## 3. What transfers from the workspace migration, and what does not

The workspace document earned its conclusions expensively; the point of this section is to spend
them rather than re-derive them — and to mark where the analogy stops.

**Transfers unchanged:**

- **Outbound-only, from day one.** There is **no inbound listener in the container at all** — not
  at any stage. ci gets to skip the workspace design's entire stage-1 history (inbound port,
  bearer token, proxy route) because unlike the workspace daemon it has no shipped REST surface
  to keep reachable.
- **Told, never derived.** The daemon dials `$QITS_CI_DAEMON_URL` verbatim, parses nothing out of
  it, and announces no address of its own (workspace §3, "the host never learns an address from a
  container").
- **The daemon is never a gateway route** (workspace §3, first invariant). One process per
  container, one container lifetime, nothing stable to configure. The control-socket endpoint is
  qits-ci's own route under `/ci`, dialled directly on the shared network.
- **The protocol module pattern.** Message records + codec over a plain `Map`, `Type`/`Field`
  constants, a `CAPABILITY_VERSION`, round-trip codec tests — the `workspace-daemon-protocol`
  recipe, as a *new* module in qits-ci-daemon. Not a reuse of the workspace protocol: the messages
  are disjoint and coupling the two repos' wire contracts would make every workspace capability
  bump a ci event.
- **Distinguishable failure states** (workspace §9, second risk). A run whose container never
  started, a container whose daemon never registered, a daemon that registered but never
  initialized, and a socket lost mid-step are different states and must record differently — not
  one generic step failure.
- **The gate is a cross-process IT** (workspace §5 step 6). A real container from a real image,
  registration, initialization, one step streamed and persisted, a cancellation honored.
  `mvn verify` stays docker-free (`FakeCiStepRunner` and the clone-alone rule are untouched); the
  gate is the ci analog of `DaemonApiGateIT`, opt-in like `CiDockerRunnerIT`.

**Does not transfer — and why, since each of these will look like a mistake to whoever reads only
the workspace document:**

- **The one-socket rejection (workspace §4) mostly does not apply — but its core concern does.**
  The workspace design rejected multiplexing because of terminals, per-browser-tab backpressure,
  and bulk file bodies sharing a wire with keystrokes. ci has no terminals and no tabs; its flows
  are replies inbound and chunks/results outbound. What *does* survive of the concern: a chatty
  step's stdout sharing the wire with registration, heartbeats and completion messages. Hence §4
  decision 7 — the control socket carries lifecycle, and step output may ride **a second
  outbound-dialled socket** dedicated to streaming, opened the same way with the same identity.
  Two sockets, both outbound, is still nothing like the multiplexer §4 rejected. No HTTP API in
  the container, no reverse tunnel, no `OpenStream`, ever — a browser follows along via qits-ci's
  own read surface fed from the relay, never from the container.
- **The shared-constant token posture (workspace §5 step 1) is not inherited.** The workspace
  token defends a bind precondition under a trusted-`qits-net` posture and stage 2 made it moot.
  ci's control socket accepts connections *from* containers that run hostile code by design, and
  the workspace document's §9 item 22 records exactly what a path-parameter identity is worth
  there: anything on the network can claim to be any daemon. ci must not reproduce that bug in a
  second place — **a host-minted per-container secret, injected at launch**, from the first
  commit. This is the workspace design's own stage-2 nonce argument applied at the layer item 22
  says still needs it.
- **The daemon is not baked into the image.** The workspace daemon ships as the entrypoint of one
  host-built image. ci runs **arbitrary repo-chosen images** — that is the feature — so the
  daemon has to be *injected* into an image ci does not control. §4 decision 1; this is the
  largest genuinely new design ground in the whole feature.

## 4. Decisions the phase documents must settle

1. **Daemon delivery into an arbitrary image: settled — the container downloads it.** The
   entrypoint is overridden with a **fixed, host-authored bootstrap script** (a few lines of bash,
   a constant in qits-ci, no repo content ever interpolated into it): download
   `$QITS_CI_DAEMON_BINARY_URL` to a scratch path, `chmod +x`, `exec`. The binary is published on
   qits-artifacts and versioned; the URL rides the env so updating the daemon across runs
   is a config change, not a code change. **The version is frozen per run**: resolved once at run
   creation from qits-ci's config, persisted on the run entity alongside its other metadata, and
   every step container of that run downloads that same version — a deploy mid-run cannot make
   step 3 speak a different protocol than step 1, and the run row records forever which daemon
   produced its results. What this shape buys over the bind-mount and `docker cp` candidates it
   replaces: **no host mount and no file injection at all**, so the sandbox rules stay unedited —
   the container fetches over the same network path it already uses for its clone. Consequences
   owned here: the binary must still be a fully static native build (musl — a glibc-linked binary
   dies on `alpine`-family images); the image contract becomes "git, bash, and a downloader
   (`wget` or `curl` — the bootstrap probes for either)"; a failed download is a container that
   never registers, so the never-registered failure state should capture a `docker logs` tail
   before reaping (container lifecycle, inside the invariant) — the bootstrap's own error output
   is the diagnosis. Whether the run entity also pins a checksum/digest next to the version is a
   phase-A detail worth a paragraph there.
2. **Container granularity: settled — one per step** (§2), today's granularity, so the pipeline
   schema is untouched: per-step images stay, per-step fresh clones stay. What remains to settle
   is only the sequencing mechanics host-side: the next launch is triggered by the previous
   step's completion notification, so the registry (or the run orchestrator behind it) owns "what
   happens next", including a stalled container's timeout standing in for a completion that never
   comes, and a sane upper bound on declared steps so "theoretically unlimited" stays theoretical.
3. **Protocol placement.** A `ci-daemon-protocol` module in qits-ci-daemon, **vendored
   byte-identical into qits-ci** with the mirror-and-`diff -r` recipe. This knowingly creates a
   third mirrored-protocol pair (`migration-plan.md` §9 item 19 records the workspace pair
   drifting once already); the alternative — a shared `libs/` artifact — would be the first
   compile-time dependency between qits repos and breaks both clone-alone rules. Accepted, but
   the outline says it out loud so the decision is revisitable when the count grows again.
4. **The per-container secret's mechanics.** Minted per container at launch, passed as env
   alongside `$QITS_CI_DAEMON_ID`, presented on every dial (control socket and stream socket
   alike), bound host-side to the (run, step) it was minted for, expired when the container is
   reaped. No
   storage beyond the in-memory launch record — **which settles the restart story too: fail and
   reap on boot.** A qits-ci restart forgets every secret and launch record by construction, so on
   startup it marks in-flight runs failed ("host restarted", a distinguishable state, not a step
   failure), `docker rm -f`s the orphans by the existing `qits.ci.run` label, and refuses any dial
   presenting a secret it does not know. No durability is added for this: a restart mid-run costs
   that run, honestly recorded, and nothing else. Scope caveat: the secret authenticates *the
   container*, and the container turns hostile the moment step code runs — so it authorizes
   exactly "deliver data about this run" and nothing else, ever. This also quietly produces the
   mechanism workspace item 22 still needs — worth a pointer, not a dependency.
5. **What happens to `CiDockerRunner`: settled — the approach is eradicated, not retired.** No
   fallback, no compatibility layer, no config toggle selecting the old path, no deprecation
   window: when phase C lands, the docker-run-a-script approach **does not exist** in any form.
   The `CiStepRunner` seam survives only as a name — its shape moves from "run one step, return
   one result" to "run one step, emit events (chunks, then a result)", and the daemon runner is
   its sole implementation. The deletion inventory, so nothing lingers by omission:
   `CiDockerRunner` whole (network ensure moves into the new launch path; it is container
   lifecycle, not part of the old approach); the composite prelude and `PRELUDE_FAILED_MARKER`
   with every mention in docs and javadoc (the daemon's structured `Initialized`-or-failure
   replaces the sentinel); the `StepResult.ready` inference built on the marker;
   `CiDockerRunnerIT`, superseded by the phase-B/C gate IT. **The service module's
   `FakeCiStepRunner` dies with it**: it performs the old approach's real semantics (host-process
   clone, `bash -c <script>`) as a test fixture, and a fake that keeps the dead approach's code
   shape alive is exactly the residue this decision forbids. Both fakes are rewritten as
   scripted-event fakes against the new seam; after phase C, `bash -c` of repo content appears
   nowhere in either module, `src/main` or `src/test` — real step semantics are proven only by
   the gate IT against a real container. Config keys are re-derived, not inherited: what the new
   path needs it keeps (caps, network, `container-git-url` becomes the daemon's
   `$QITS_CI_REPOSITORY_URL` source), and any key only the old path read is deleted with it.
6. **Where the daemon binary comes from: settled — collapsed into decision 1.** It is published
   on qits-artifacts and downloaded by the container itself; there is no
   deploy-artifact-beside-qits-ci variant. The dependency this creates — a step container cannot
   start its daemon while qits-artifacts is down — is accepted, and it is the same dependency
   the clone already has on the same host. qits-ci itself never touches the binary.
7. **One socket or two.** Lifecycle messages (register, initialized, step started/finished,
   cancel) on the control socket; step stdout on a second outbound-dialled stream socket, so a
   step emitting megabytes cannot queue ahead of a cancellation or make heartbeats jitter.
   Leaning: two, per the invitation to "plan for extra sockets if sensible" — but phase B may
   legitimately start with one socket carrying everything and split in phase C when streaming
   lands, since both sockets are dialled the same way and the split is additive. The thing to fix
   now is only that the protocol's chunk messages carry a correlation id from day one, so moving
   them between sockets never changes their shape.
8. **The live relay and its read surface.** Chunks land in a bounded in-memory relay per running
   step (the `CommandLogBuffer` idea, host-side); the DB row appears only at step finish. To be
   settled in phase C: how a user actually follows along — poll an ephemeral endpoint over the
   relay vs. SSE/WebSocket on qits-ci's read surface. Leaning poll-first; the daemon makes live
   possible, it does not oblige a push transport. Either way the run read surface must make
   "step running, no row yet" legible rather than looking like a run with missing steps.

## 5. Phases and the document split

Each phase is one implementation document, written when its predecessor's decisions are fixed. The
split lines are where the repos change:

- **Phase A — the daemon skeleton.** qits-ci-daemon becomes a repo with the house shape:
  clone-alone `mvnw verify`, framework-free capability modules, a `ci-daemon-protocol` module, a
  static native image as the shipping form, added as submodule `daemons/qits-ci-daemon` (the
  `--name` recipe in `CLAUDE.md`). Deliverable: a binary that, given the env contract of §2,
  dials back, registers, and exits cleanly on socket close. Decisions 1, 3, 6.
- **Phase B — the communication path.** The qits-ci side: control-socket route under `/ci`, the
  ci-daemon registry, vendored protocol, the launch path (entrypoint-override bootstrap, env
  contract set, run-pinned daemon version persisted on the run entity), secret mint/verify, the
  register → initialize → step-as-reply handshake, liveness, reaping — including the fail-and-reap
  boot reconciliation (decision 4) — and the distinguishable failure states. Ends at the gate IT
  proving the handshake against a real container. Decisions 2, 4, 7 (at least the message shapes); touches
  qits-ci only, plus the daemon image contract from A.
- **Phase C — step execution over the daemon.** Each daemon runs its delivered step and streams;
  host-side the relay, persist-at-finish rows with host-stamped timestamps, cancellation and
  per-step timeout end-to-end, the lifecycle states on the run read surface, and the follow-along
  surface (decision 8). The old approach is **eradicated** here per decision 5's deletion
  inventory, and the phase-C document's done-when includes the grep proving it: no `bash -c` of
  repo content in either module, main or test, and no config key, fake, doc sentence or javadoc
  left that describes running a step any way but through a daemon. This is the phase the
  SPA-facing wins land in.
- **Phase D — the conformance suite step.** The original content of this file, unchanged in
  substance: the upstream `opencontainers/distribution-spec` conformance binary as a standing ci
  step against a live qits-artifacts with a pre-created `oci-images` repository. It is a pure HTTP
  client, so the no-docker-socket rule does not block it, and its per-spec-clause failures are the
  granularity our synthetic `registry/OciClient` coverage lacks. Two knowns to pin in the step
  config: the image must be pullable by the runner, and the **content-management group will fail
  by design** (`DELETE` deliberately unimplemented, no GC story) — so the group selection excludes
  it and the exclusion is documented as a decision, or the first red build reads as a defect.
  Blocked only on ci being able to run steps at all — it does not need phases A–C and could run on
  today's runner; sequencing it after C is a choice about not writing the step twice, not a
  dependency.
- **Phase E — follow-ups unlocked, pointers only.** Retries, the non-advisory gate,
  clone/dependency caching across the per-step containers (volume-shaped — it cannot be
  daemon-shaped, since nothing survives a step's container), registry-pulled daemon binary
  (decision 6's second half). Named here so they are findable; not designed here.

## 6. Deliberately out of scope for the whole feature

- **No workspace involvement.** Pipelines run in their own throwaway containers; a workspace is
  never involved. Unchanged from the extraction, restated because the two daemons will now rhyme.
- **No change to the intake contract.** `POST /ci/api/events/post-receive`, the token guard, and
  the fire-and-forget notifier in qits-artifacts stay as they are.
- **No network split.** Containers keep `qits.ci.network` and the trusted-network residual
  (hostile step code can reach what the network reaches) stays a documented accepted exposure —
  the existing issue file remains the record of it.
- **No durability change beyond step rows.** Runs and steps are rows; the relay is memory and
  dies with the process, and that is fine — the persisted tail is the record, the relay is a
  live convenience.

## 7. Open questions for iteration

- ~~Env naming: `$project-id` vs repo id~~ — settled: repo id only, `$QITS_CI_REPO_ID`; the
  container needs nothing from the projects context.
- ~~Which service publishes the daemon binary~~ — settled: **qits-artifacts** ("qits-repository"
  in the settling answer meant it). The URL shape is its concern; ci only carries the resolved
  url in config and env.
- Does anything ever need host→daemon traffic beyond the step-reply and `Cancel`? If yes it
  rides the control socket as new message types; naming it early keeps the protocol honest.
- Shallow clone vs. the sha: a shallow fetch of the branch may not contain `$QITS_CI_SHA` after a
  force-push — the host's existing ancestor check before launch covers the common case, but the
  daemon's checkout-failure path is the backstop and should report as "sha gone", not as a broken
  clone.
- How many runs may be in flight concurrently (one container each at a time, but N pushes = N
  runs)? Today's behaviour is whatever the pipeline's threading does; the phase-B document should
  state a bound rather than inherit one by accident.
- Per-step timeouts (§1) are an additive optional field on the pipeline config schema — phase C
  should say what an absent field means (the current global default) and that unknown fields in
  old configs stay rejected or ignored per the existing parser's behaviour, whichever it is.
- The conformance image is pulled from a public registry by the runner host — does that pull go
  through `proxy-pulling-normal-images.md`'s machinery once that exists?
