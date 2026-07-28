# The workspace-daemon does not build as a native image

Status: **open.** Found 2026-07-28 while running the reachability plan's real-container gate.
Blocks the daemon's *shipping* form; nothing about its behaviour.

## The bug

`qits-workspace-daemon` compiles and runs correctly as a JVM fast-jar and fails to compile to a
GraalVM native image. `native-image` aborts in its points-to analysis on `ForeignPty`'s libc
downcalls:

```
Fatal error: com.oracle.graal.pointsto.util.AnalysisError$ParsingError:
  Error encountered while parsing eu.wohlben.qits.workspacedaemon.commands.ForeignPty.open(ForeignPty.java:125)
Parsing context:
   at eu.wohlben.qits.workspacedaemon.commands.CommandRegistry.startSession(CommandRegistry.java:149)
   at eu.wohlben.qits.workspacedaemon.commands.CommandService.launchAgent(CommandService.java:146)
   ...
   at eu.wohlben.qits.workspacedaemon.WorkspaceApi.dispatchAgent(WorkspaceApi.java:565)

Caused by: com.oracle.svm.core.util.VMError$HostedError:
  should not reach here: unexpected input could not be handled: linkToNative
	at com.oracle.svm.hosted.substitute.PolymorphicSignatureWrapperMethod.buildGraph(PolymorphicSignatureWrapperMethod.java:170)
```

`ForeignPty.java:125` is the first downcall in `open`:

```java
fd = (int) OPEN.invokeExact(path, O_RDWR | O_NOCTTY);
```

`linkToNative` is the polymorphic-signature method behind an FFM downcall. The builder is saying it
reached that call site and could not turn it into a stub.

## Reproducing it

```bash
cd daemons/qits-workspace-daemon
./mvnw -B -ntp -pl workspace-daemon -am package -Dnative -DskipTests \
  -Dquarkus.native.container-build=true \
  -Dquarkus.native.builder-image=quay.io/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-25
```

Takes ~10 minutes to reach the failure. **Capture the whole log** — the fatal error is in the middle
of the `native-image` output, and a `| tail` will show only Maven's own stack trace, which says
nothing.

Observed with **Mandrel 25.0.3.0 / JDK 25.0.3+9-LTS** (the builder image the monolith's
`docker/qits/Dockerfile` `workspace-daemon-build` stage uses).

## What is known, and what is not

Known:

- **The fast-jar is fine.** `./mvnw verify` is green (171 tests) and a fast-jar in a real workspace
  container passes the full gate — provisioning, files, commands, an interactive PTY that echoes a
  keystroke and survives a client reconnect. So the FFM code is *correct*; only the AOT compilation
  of it fails.
- **The repo's stated invariant is already upheld.** `README.md` says every `FunctionDescriptor` is
  a `static final` constant so the downcall stubs register at build time "with no `Feature` and no
  config file". They are, and so are the `MethodHandle`s. Following that rule is evidently not
  sufficient here, which is itself worth writing down.
- **`qits/workspace:latest` on this machine has no daemon binary at all** — its entrypoint is
  `bash`. Consistent with this stage never having produced one, though that is inference, not
  evidence.

Not known — establish these first, they change the shape of the fix:

- **Did this ever build?** Check `git log` on the monolith's `docker/qits/Dockerfile` for when the
  `workspace-daemon-build` stage landed, and whether any published image carries the binary. If it
  once worked, this is a regression and bisecting Mandrel/Quarkus versions is the cheapest route.
- **Is it version-specific?** A local `25.0.2-graalce` build also failed, but that log was truncated
  before the error was captured, so it is *not* confirmed to be this same failure. Re-run it and
  look. If 25.0.2 succeeds, the answer may be as small as pinning the builder image.
- **Is `ioctl` the trigger, or all of them?** It is the one downcall built with
  `Linker.Option.firstVariadicArg(2)` rather than the plain `downcall(...)` helper. The stack names
  `open`, but analysis order is not evidence of cause.

## The most likely cause, to test first

**The downcall handles are probably not compile-time constants at image build time**, because
`ForeignPty` is initialized at *runtime* by default. GraalVM can only generate a downcall stub when
it can constant-fold the `MethodHandle` at the `invokeExact` site; a `static final` field is only
constant to the builder if its holder was initialized during the build. That would explain a failure
that survives every source-level rule being followed.

Things to try, cheapest first:

1. `--initialize-at-build-time=eu.wohlben.qits.workspacedaemon.commands.ForeignPty` (via
   `quarkus.native.additional-build-args`). Note this makes `LIBC.find(...)` run in the builder,
   which may be what is wanted or may itself fail — either outcome is informative.
2. The reverse: force it to runtime explicitly and see whether the error moves or changes.
3. Register the downcalls the supported way for the toolchain in use — a `Feature` calling
   `RuntimeForeignAccess.registerForDowncall(...)` for each descriptor. This contradicts the
   README's "no `Feature`" claim, so if it is the answer, **amend the README** rather than leaving
   a rule that no longer holds.
4. A different builder image (Oracle GraalVM `container-registry.oracle.com/graalvm/native-image:25`
   is named in the Dockerfile as the fallback toolchain).

## Constraints on the fix

- **No new dependency.** `ForeignPty` exists precisely because pty4j is JNA plus per-platform `.so`
  files extracted at runtime — the worst case for a native image. Reintroducing that is not a fix.
- **The PTY behaviour must not change.** `setsid --ctty` for terminals, `O_NOCTTY` on the master,
  `ptsname_r` over `ptsname` (the latter races two concurrent launches) — the class javadoc and
  `README.md`'s "Things that look wrong and are not" explain each; none is incidental.
- **A clone of the daemon repo alone must still build and test green**, with no monorepo and no
  docker.

## Correct outcome

1. `cd daemons/qits-workspace-daemon && ./mvnw package -Dnative` produces
   `workspace-daemon/target/qits-workspace-daemon`, and that binary boots: run it with
   `QITS_WORKSPACE_DAEMON_URL` unset and it logs the "no url configured — idle" warning and stays
   alive, rather than dying on first use of the PTY.
2. The monolith's `docker/qits/Dockerfile` `workspace-daemon-build` stage completes, so
   `qits/workspace:latest` entrypoints to `/usr/local/bin/qits-workspace-daemon`.
3. **The gate passes against that image**, which is the real acceptance test because a native-image
   defect only shows up when the binary runs:

   ```bash
   cd services/qits-workspaces
   ./mvnw test -Dtest='DaemonApiGateIT' -Dsurefire.failIfNoSpecifiedTests=false \
     -Dqits.workspace.image=qits/workspace:latest
   ```

   It launches a real command through a real PTY and drives an interactive terminal, so it exercises
   exactly the code that fails to compile. It self-skips unless the image's entrypoint names the
   daemon, so a stale image reads as a skip rather than a failure.
4. If the fix needed a `Feature`, build-time initialization, or a pinned toolchain, **`README.md`'s
   downcall paragraph says so.** The current text tells the next person that `static final` is
   sufficient, and that is what made this failure surprising.

## Working around it meanwhile

The gate can run today against a fast-jar layered onto the existing toolchain image. This tests the
daemon's behaviour but **not** native-image, which is the one thing this bug is about:

```bash
cd daemons/qits-workspace-daemon && ./mvnw -o package -pl workspace-daemon -am -DskipTests
# then: FROM qits/workspace:latest, COPY the quarkus-app dir in, and
# ENTRYPOINT ["/usr/lib/jvm/temurin-25/bin/java","--enable-native-access=ALL-UNNAMED",
#             "-jar","/opt/qits-workspace-daemon/quarkus-run.jar"]
```

`--enable-native-access=ALL-UNNAMED` is required — the PTY is `java.lang.foreign`, the same reason
the surefire `argLine` carries it.
