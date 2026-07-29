# Ship the ci daemon — outline

Status: **open.** Written 2026-07-29, the day phases A–C of
[`finish-ci-feature.md`](finish-ci-feature.md) landed. This is what the retired A–C implementation
document left behind: the feature is implemented, tested, and demonstrated on a live stack, and it
still cannot be deployed by anyone but the person who built it. An outline to extend, not a design.

---

## 1. Nothing publishes the daemon binary

A step container downloads `qits-ci-daemon` from `$QITS_CI_DAEMON_BINARY_URL` and executes it. That
url is resolved from two config keys qits-ci ships:

    qits.ci.daemon-binary-url-template = http://qits-artifacts:8080/v2/qits/ci-daemon/blobs/sha256:{version}
    qits.ci.daemon-version             = (blank)

Blank is deliberate — this repo has no binary to point at, and an invented digest would be a lie. A
blank version yields a url that 404s, which surfaces honestly as the never-registered failure state
with the bootstrap's own error captured from `docker logs`. But it means **a fresh deployment runs
no CI at all until someone publishes a binary and sets the digest**, and nothing in the tree does
that or tells them to at the moment it matters.

Proven to work, by hand, once:

    curl --data-binary @qits-ci-daemon \
      -X POST 'http://<host>/v2/qits/ci-daemon/blobs/uploads/?digest=sha256:<hex>'

with the `qits` repository row created as `oci-images` first — the artifacts seeder makes only
`ci-screenshots` and `ci-videos`, so that row does not exist on a fresh deployment either.

What to settle:

- **Who runs that upload.** A release job in qits-ci-daemon is the obvious home, since the digest is
  a property of the binary it just built. That makes qits-ci-daemon the first repo here that
  publishes to a running qits-artifacts, which is a new dependency direction worth naming out loud.
- **How the digest reaches qits-ci's config**, given the two keys move together and the version *is*
  the integrity pin. Today it is a human copying 64 hex characters.
- **Whether a run row showing a digest instead of a version number is good enough.** It is honest
  and it is unreadable. The alternative is a version-addressed `releases` surface in qits-artifacts
  (~one commit: a `RepositoryType` constant, a Flyway line widening the named check constraint, and
  a streaming resource under `repositories/`) — whose real cost is not the code but introducing a
  **mutable, non-content-addressed pointer** into a store that is otherwise append-only and
  content-addressed. Re-uploading a version must then be either rejected or defined as latest-wins.
- **One supply-chain input.** Building the binary is already a two-line recipe from a committed
  `docker/Dockerfile.musl-builder` (qits-ci-daemon's README has it, with the reasoning), so nothing
  is missing there. But that image fetches its musl toolchain from `more.musl.cc`, a small community
  host, pinned as an overridable `ARG`. Fine as a build input on a laptop; worth mirroring if
  release builds are meant to be reproducible without depending on a third party staying up.

## 2. Restart reconciliation works and has no test

The one behaviour in the feature currently held up by manual verification instead of a test.

Verified by hand on a live stack: `SIGKILL` of qits-ci mid-run leaves the step container behind as
`Exited (6)` — the daemon exits nonzero when it loses its host, so `docker logs` reads honestly — and
the next boot logs `Removed 1 orphaned CI step container(s)` and `Marked 1 CI run(s) left RUNNING by
a previous shutdown as FAILED`, ending at zero orphans and a `FAILED` run with no step rows, which is
persist-at-finish behaving correctly under a crash.

Nothing in either suite covers any of that. `CiDaemonGateIT` covers the two-step pipeline, live
chunks, the flood bound, cancellation, the per-step timeout and the never-started state; the boot
sweep and the orphan reap are untested, so a regression there is found by a human noticing stale
containers. An IT that launches a real step, kills the registry's view of it, and restarts the
observer would close it.

One sub-clause of the original done-when is **not** reachable as written: "a refused stale dial." The
daemon self-terminates the moment its socket drops, so after a host restart no daemon survives to
dial back staleley. The refusal mechanism itself is covered (`CiDaemonHandshakeIT` asserts a
wrong-secret dial closed 1008) and the registry starts empty by construction. Worth recording as
unreachable rather than leaving someone to hunt for the test.

## 3. Smaller things, named so they are findable

- **`qits.ci.daemon-version` is the only run-pinned value with no validation.** A malformed digest
  produces a 404 and the never-registered state — honest, but a startup-time shape check would move
  the diagnosis from "every run fails mysteriously" to a boot log line.
- **The OTLP exporter logs a warning per export** against a `qits-observability` that need not exist,
  loudly enough to bury real log lines on a small deployment. `OTEL_SDK_DISABLED=true` is the escape
  hatch; whether a deployment without observability should have to know that is the question.
