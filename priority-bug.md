# The workspace-daemon does not build as a native image

Status: **fixed** in `daemons/qits-workspace-daemon` on 2026-07-28. Found the same day while
running the reachability plan's real-container gate.

`./mvnw -pl workspace-daemon -am package -Dnative` now produces
`workspace-daemon/target/qits-workspace-daemon`, verified on **both** toolchains: GraalVM CE
25.0.2 locally and Mandrel 25.0.3.0 / JDK 25.0.3+9-LTS in the builder image the Dockerfile names.
The binary boots, logs the "no url configured — idle" warning and stays alive.

## What it was

Two independent defects, one of which was hiding the other.

**1. The build aborted because `ForeignPty` was initialized in the builder.** Quarkus initializes
application classes at build time. `ForeignPty`'s static initializer calls `Linker.downcallHandle`,
and a `MethodHandle` built in the builder cannot be lowered: analysis reaches the `invokeExact` site,
tries to lower the `linkToNative` behind it, and kills the image with `should not reach here:
unexpected input could not be handled: linkToNative`.

**2. No downcall was ever registered.** `native-image` reported `0 downcalls and 0 upcalls
registered for foreign access`. Had only defect 1 been fixed, the build would have gone green and
the binary would have died on first PTY use with `MissingForeignRegistrationError`.

The report's leading hypothesis was right in substance — the handles were not compile-time
constants — but the fix is not one change. **Registering the descriptors does not rescue the build**:
with the stubs registered and the class still initialized at build time, it fails identically. Both
halves are needed and they fix different things.

**The README's stated invariant was false, and that is what made this surprising.** It said a
`static final` `FunctionDescriptor` was what let GraalVM register the stubs automatically, with no
`Feature` and no config file. GraalVM registers automatically only where it can constant-fold the
descriptor at the `Linker.downcallHandle` call site, and a `static final` field is not constant to
the builder unless its holder was initialized during the build. Following the rule bought nothing.
The README now says so, at length, and so does `ForeignPty`'s javadoc.

## The fix

Two files, both in the module that owns the downcalls, so a clone of the daemon repo alone still
builds — `qits-commands/src/main/resources/META-INF/native-image/eu.wohlben/qits-commands/`:

| | |
|---|---|
| `native-image.properties` | `--initialize-at-run-time` for `ForeignPty` — makes the build complete |
| `reachability-metadata.json` | a `foreign.downcalls` entry per distinct descriptor — makes the binary work |

No `Feature`, no new dependency, no toolchain pin. An exact class name outranks the blanket
`--initialize-at-build-time` Quarkus passes, so Quarkus needs to be told nothing and the fix sits
next to the class it is about rather than in `workspace-daemon`'s `application.properties`.

Five entries, not eight: registration is keyed on the descriptor, so the three `int(int)` calls
(`grantpt`, `unlockpt`, `close`) share one and `read`/`write` share another.

## The three unknowns, now answered

- **Did this ever build? No, and it was never a regression.** `ForeignPty` has never existed in the
  monolith (`git log --all -- '*ForeignPty*'` is empty there), and the Dockerfile's
  `workspace-daemon-build` stage builds the monolith's *own* `workspace-daemon` module — the Part 1
  daemon, which has no FFM code at all. The failing combination had never been built anywhere, by
  anyone. Bisecting Mandrel/Quarkus would have found nothing.
- **Is it version-specific? No.** The local `25.0.2-graalce` build reproduces the failure exactly —
  same class, same line, same `linkToNative` — which is what the truncated log had left open. Both
  versions fail before the fix and both pass after it.
- **Is `ioctl` the trigger? No.** Nothing was registered, so every downcall was equally broken; the
  stack named `open` only because analysis reached it first. The variadic `ioctl` needs nothing
  special beyond matching `firstVariadicArg: 2` in its metadata entry, which it now does.

## How it was verified

- Both toolchains build green; before the fix both failed identically.
- The build now reports **`5 downcalls and 0 upcalls registered for foreign access`**, against `0
  downcalls` before. Five matches the five distinct descriptors, so the count is what says the
  metadata was read rather than silently ignored.
- **The PTY actually runs in a native image.** A smoke harness over the real `ForeignPty`, compiled
  to a binary, allocates a PTY, gets a real `/dev/pts/N` from `ptsname_r`, resizes through the
  variadic `ioctl`, and round-trips `hello-pty` through `write`/`read` — all five descriptors,
  no `MissingForeignRegistrationError`. Booting the daemon idle does not touch the PTY, so on its
  own it proves nothing about this bug.
- **`DaemonApiGateIT` passes against a real container running the real native daemon** — 2 tests, 0
  skipped, the original report's acceptance criterion. See the next section for how to get the image;
  it does not need the monolith. Real containers were confirmed with `docker events` rather than
  inferred from a green suite, because a self-skipping gate and a passing one read alike.
- **The variadic `ioctl` was checked separately, and the gate cannot check it.** `ForeignPty.resize`
  ends in `catch (Throwable ignored)` by contract, and `MissingForeignRegistrationError` is a
  `Throwable` — so an unregistered `ioctl` is swallowed and the gate still passes green. Since
  `open` sets the initial size through that same call, pointing the fixture action at `stty size`
  and reading the terminal stream answers it: `24 80`, exactly `INITIAL_COLUMNS`/`INITIAL_ROWS`,
  where an unregistered `ioctl` would have left `0 0`. **If you touch that entry, this is the only
  thing that will tell you** — re-run that probe rather than trusting the gate.
- `./mvnw verify` green, 171 tests, unchanged.

## Two traps worth keeping written down

- The fatal error is in the **middle** of the `native-image` output. A `| tail` shows only Maven's
  own stack trace, which says nothing. This is what truncated the original 25.0.2 log.
- The per-entry `reason` field is **in the published metadata schema and rejected by the 25.0.2
  parser** (`Unknown attribute(s) [reason] in foreign call`). The explanation lives in one top-level
  `comment` instead.

## What is still open — and it is not this bug

Outcomes 2 and 3 of the original report cannot be reached by fixing `ForeignPty`, because they rest
on an assumption that turned out to be false: **the monolith's `workspace-daemon-build` stage does
not build this daemon.** It `COPY . .`s the monolith's own build context and runs `-pl
workspace-daemon -am` against the monolith's stale Part 1 module — no `qits-commands`, no PTY. The
extracted repo is not in that build context at all.

So today `qits/workspace:latest` has `Entrypoint=[]`, `Cmd=[bash]`, built 2026-07-20: it carries no
daemon binary, as the report observed, and against it `DaemonApiGateIT` **self-skips** rather than
failing — exactly as designed, since `dockerAndImageAvailable()` requires the entrypoint to name
`qits-workspace-daemon`.

**That blocks shipping, not verifying.** The gate needs an image whose entrypoint is the binary, and
building one takes three lines and no monolith at all:

```bash
cd daemons/qits-workspace-daemon
./mvnw -pl workspace-daemon -am package -Dnative -DskipTests \
  -Dquarkus.native.container-build=true \
  -Dquarkus.native.builder-image=quay.io/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-25
cp workspace-daemon/target/qits-workspace-daemon .
printf 'FROM qits/workspace:latest\nCOPY qits-workspace-daemon /usr/local/bin/qits-workspace-daemon\nENTRYPOINT ["/usr/local/bin/qits-workspace-daemon"]\n' > Dockerfile.native
docker build -f Dockerfile.native -t qits/workspace:native .

cd ../../services/qits-workspaces
./mvnw test -pl service -Dtest=DaemonApiGateIT -Dsurefire.failIfNoSpecifiedTests=false \
  -Dqits.workspace.image=qits/workspace:native
```

That is how the acceptance criterion above was met: a real container provisioning from a served bare
repo, a real terminal echoing a keystroke and surviving a reconnect, on the real native binary.

What is genuinely left is pointing the `workspace-daemon-build` stage at
`daemons/qits-workspace-daemon` so `qits/workspace:latest` carries this binary by default. That is a
migration step about build context and repository layout, not about native-image. The native-image
defect is gone.
