# Stream application logs into qits-observability

Status: **shipped for all platform services** (updated 2026-08-05; written 2026-08-02).
LA–LC are done: every service carries the explicit `quarkus.otel.logs.*` block with an
`OtelLogConfigTest` drift guard, and the behavioral proof lives once in qits-events
(`OtelLogBridgeTest`/`PackagedLogBridgeIT`). LD's platform half is done: qits-cd injects
`service.version` (deploy sha) at `docker run`. LD-b and LE are settled as **not planned**
(user decision 2026-08-05): console capture answers the daemons, and workspace-launched
dev services get no telemetry overlay. LG (durable retention) is settled by the
2026-08-05 decision that qits adds no external component that cannot be embedded into the
Quarkus app: no third-party log backend, no sidecar collector; the bounded live window
stands unless a qits-owned store is ever justified.

## The short answer

Use **OpenTelemetry logs over OTLP/HTTP protobuf**. It is the vendor-neutral version of the old
“install a GELF appender and point it at Graylog” arrangement, and qits is unexpectedly close to
done already:

- every platform Quarkus service carries `io.quarkus:quarkus-opentelemetry`;
- every one sets `quarkus.otel.logs.enabled=true`;
- every one points the common OTLP exporter at
  `${qits.observability.url}/observability/api/otel` using `http/protobuf`;
- Quarkus' OpenTelemetry logging handler bridges JBoss Log Manager records into OTLP and is enabled
  by default once logs are enabled;
- qits-observability already accepts `POST /observability/api/otel/v1/logs`, decodes the standard
  `ExportLogsServiceRequest`, retains bounded records, correlates them with trace/span ids, exposes
  them through REST and MCP, renders them in the SPA, and tees the original OTLP body upstream.

So this is not primarily a receiver implementation. It is a **prove, normalize, and finish the
producer rollout**: demonstrate that a real `Logger.info/error(..., throwable)` emitted by every
shipping form reaches the existing logs page with its severity, exception and active trace context;
make the handful of implicit defaults explicit; fix source identity; then cover processes that are
not platform Quarkus services.

The one caveat is maturity: OpenTelemetry's logs data model and OTLP wire are stable, while Quarkus
still labels its logging integration preview and disables it by default. qits already opted into
that preview. Pinning Quarkus per repository and testing the packaged/native path makes that a
bounded compatibility risk, not a reason to invent and maintain a second protocol.

## What exists today

### Sender side

The ten platform processes below all carry the same relevant shape:

| Process | `quarkus-opentelemetry` | OTLP HTTP endpoint | Logs enabled |
|---|---:|---:|---:|
| qits-artifacts | yes | yes | yes |
| qits-cd | yes | yes | yes |
| qits-ci | yes | yes | yes |
| qits-dns | yes | yes | yes |
| qits-events | yes | yes | yes |
| qits-gateway | yes | yes | yes |
| qits-observability | yes, self-export | yes | yes |
| qits-projects | yes | yes | yes |
| qits-stt | yes | yes | yes |
| qits-workspaces | yes | yes | yes |

The configuration is already the desired operator experience:

```properties
quarkus.otel.exporter.otlp.protocol=http/protobuf
quarkus.otel.exporter.otlp.endpoint=${qits.observability.url}/observability/api/otel
quarkus.otel.logs.enabled=true
```

Quarkus documents that its OTel logging handler publishes ordinary JBoss Logging records, is
enabled by default when OTel logs are enabled, and can be filtered independently with
`quarkus.otel.logs.level`. This covers JBoss Logging plus JUL, SLF4J, Commons Logging and Log4j calls
that enter Quarkus' unified JBoss Log Manager through their existing adapters. Application code
does not need to change logger API.

What is missing is a repository-wide executable assertion. The receiver tests post hand-built OTLP
batches; that proves the server, but not that Quarkus' logging handler constructs and exports them.
The services' existing OTLP stub tests primarily prove traces/metrics. The live system has been
observed carrying telemetry, but the repository does not preserve a named canary log and its exact
decoded fields as evidence.

### Receiver side

`OtelReceiverResource.logs` already implements the required qits receiver route:

```text
POST /observability/api/otel/v1/logs
Content-Type: application/x-protobuf
body: ExportLogsServiceRequest

200 application/x-protobuf
body: ExportLogsServiceResponse
```

It accepts gzip, rejects malformed protobuf with 400, decodes resource attributes, timestamp,
observed timestamp fallback, severity number/text, body, trace id, span id and log attributes, and
returns the signal-specific success response. Its 64 MiB request ceiling matches the OTLP
recommendation. The store is deliberately bounded and ephemeral; `startedAt` and eviction counters
make that visible rather than pretending this is durable history.

That is sufficient for qits' pinned OTLP/HTTP binary-protobuf clients. It is not a general-purpose
collector: it deliberately omits OTLP/JSON and OTLP/gRPC, partial-success responses, durable queues,
transform processors and arbitrary receiver protocols. None is necessary for direct Quarkus
shipping.

## Options considered

### A. Direct OTLP from each application — **choose this**

Dependency: the existing `quarkus-opentelemetry` extension. Configuration: the three properties
above, plus explicit identity and policy described below.

Advantages:

- one protocol for traces, metrics and logs and one endpoint property;
- structured resource/log attributes rather than parsing formatted text;
- trace and span ids travel as first-class fields, so a log links directly to its trace;
- batching, background export, retry behavior and log-manager bridging belong to the SDK/Quarkus,
  not qits application code;
- the existing qits receiver and UI already speak it;
- the sender can later point at any other OTLP-speaking receiver without changing application
  logging calls.

Costs:

- Quarkus' logging bridge remains preview;
- an in-process exporter can lose its final batch on crash and cannot outlive a wedged process;
- every application owns a small exporter queue and connection;
- a receiver outage must never block an application, so some logs will be dropped under prolonged
  failure. Console output remains the durable-at-host fallback if the runtime captures it.

### B. OpenTelemetry Collector/Alloy beside the applications — **ruled out: external, not embeddable**

Applications still emit OTLP, but aim at a local agent/sidecar/host collector. It batches, queues,
enriches, samples/redacts and forwards to qits-observability or durable storage. Alternatively it
can tail container stdout and translate existing console logs without an in-process log exporter.

The 2026-08-05 no-non-embeddable-components decision removes this option: a per-host or sidecar
collector is exactly the kind of external process qits does not add. The needs it would have
served — disk-backed buffering, fan-out, central redaction — must, if they ever materialize, be
met inside qits-observability itself. The receiver wire stays standard OTLP regardless.

### C. Built-in syslog handler — **compatible fallback, not the platform contract**

Quarkus can send RFC 5424/3164 over TCP, UDP or TLS directly with no extra dependency:

```properties
quarkus.log.syslog.enabled=true
quarkus.log.syslog.endpoint=qits-observability:6514
quarkus.log.syslog.protocol=ssl-tcp
quarkus.log.syslog.syslog-type=rfc5424
```

The server would need a framed TCP/TLS syslog listener, RFC parser, severity/facility mapping,
connection limits, backpressure policy and an adapter into `StoredLog`. UDP is unacceptable for
application errors; TCP still leaves structured attributes and trace correlation dependent on a
format convention. This duplicates an already-working OTLP route and makes the server broader for
less information.

### D. GELF/Graylog-style appender — **reject**

This exactly matches the remembered operational model: add `quarkus-logging-gelf`, enable its
handler and point it at a GELF input. The receiver would implement GELF UDP/TCP (chunking,
compression, null framing and additional fields) or HTTP and map the result into the store.

Quarkus now deprecates its GELF extension and explicitly directs users toward OpenTelemetry logging.
Choosing it would add a second dependency and protocol, retain weaker trace correlation, and create
server work solely to recreate a path already present through OTLP.

### E. Custom qits logging extension/HTTP appender — **reject unless Quarkus drops its bridge**

A qits extension could register a JBoss Log Manager handler and POST a small qits JSON envelope.
That seems simple until it must solve recursive exporter logging, bounded queues, batch timing,
shutdown flush, retry/backoff, throwable serialization, MDC/context propagation, secrets,
backpressure and native-image initialization. Those are precisely the responsibilities the OTel
SDK and Quarkus integration already own. A custom bridge is only a contingency if the preview
Quarkus bridge proves unusable in a measured packaged/native test.

### F. Direct push to a third-party log backend — **rejected outright**

Ruled out 2026-08-05: qits adds no external component that cannot be embedded into the Quarkus
app, so there is no third-party log store for applications to target. Even before that decision,
coupling every producer to one storage engine's push API and label policy would have bypassed
qits' existing trace/log view.

## Settled design

### 1. The platform wire is OTLP/HTTP protobuf

Keep one base endpoint and let the SDK append `/v1/logs`. qits' non-default prefix remains:

```text
OTEL exporter base: http://qits-observability:8080/observability/api/otel
logs request:       http://qits-observability:8080/observability/api/otel/v1/logs
```

Make these implicit sender defaults explicit in every service so a Quarkus upgrade cannot quietly
change the behavior:

```properties
quarkus.otel.logs.enabled=true
quarkus.otel.logs.handler.enabled=true
quarkus.otel.logs.exporter=cdi
quarkus.otel.logs.level=INFO
```

`INFO` is the shipping default. Per-category Quarkus levels still decide which records are created;
the OTel handler level is a second outbound floor, useful for making the export cost explicit.
Console logging stays enabled: remote shipping is an additional handler, never the only copy.

### 2. Identity is a resource concern, not text formatting

Every platform service already has `quarkus.application.name`, which becomes `service.name` and is
why the observability source list works. Add stable deployment resource attributes through the
existing OTel resource configuration/environment rather than prefixing messages:

- `service.name` — existing `qits-*` application name;
- `service.version` — released version/image identity when known;
- `deployment.environment.name` — qits environment;
- `service.instance.id` or `container.id` — runtime instance when available;
- `qits.repository.id` and `qits.workspace.id` — only for workspace-launched processes where those
  values genuinely exist.

Do not stamp fake workspace attributes onto platform services merely to fit the old query model;
service-name buckets already solve that. Resource attributes must be low-cardinality and stable for
the process lifetime. Request/user/build ids belong on individual log attributes or MDC, not in the
resource identity.

### 3. Preserve trace correlation and structured errors

A log emitted while an OTel span is current must arrive with `traceId` and `spanId`. A throwable
must retain, at minimum, the OTel exception semantic attributes (`exception.type`,
`exception.message`, `exception.stacktrace`) rather than only a formatted body. Measure Quarkus'
actual mapping first; do not design field names from memory.

The current decoder flattens every `AnyValue` to strings. That is adequate for the present UI but
loses typed/nested attributes. Record the loss explicitly and defer a typed DTO/store migration
until a real producer demonstrates a field the UI or query layer must preserve.

### 4. Delivery is asynchronous and fail-open

Logging must not make service availability depend on qits-observability. Bound the SDK queue and
batch size; export asynchronously; drop after bounded retry/queue exhaustion; keep console output.
Exporter diagnostics must not re-enter the same OTel handler recursively.

The acceptance test for an unreachable receiver is therefore: application startup and request
handling stay healthy, exporter failure is rate-limited/diagnosable locally, memory remains bounded,
and recovery resumes new exports. It is not “every log is eventually delivered.” If that guarantee
ever becomes necessary, it means persistent queueing on the receiver side — never blocking
application threads or growing an in-process queue without bound.

### 5. qits-observability remains a bounded live window

Direct shipping does not turn the existing in-memory store into durable logging. A restart empties
it, per-source caps evict old entries and the UI reports both facts. That is suitable for the current
“what just failed?” operator/agent use case.

Durable/searchable history is a separate phase (§LG). Do not add a database to `TelemetryStore`
as an accidental consequence of enabling producers. A retention plan must settle retention
duration, tenant/isolation model, query ownership, indexing/cardinality, redaction and deletion
before choosing storage.

### 6. The receiver stays deliberately narrow

For the chosen clients it must continue to implement:

- `POST .../v1/logs` with `application/x-protobuf`;
- binary `ExportLogsServiceRequest` decoding and binary `ExportLogsServiceResponse` success;
- gzip request bodies;
- timestamp/observed-timestamp fallback, severity, body, trace/span ids, record attributes and
  resource attributes;
- 400 for malformed/non-retryable data and 413 for the decompressed body ceiling;
- bounded ingestion and truthful eviction accounting;
- no authentication on the internal ingest route, while the public gateway cannot expose an
  unauthenticated internet write path accidentally.

Before calling it strictly OTLP-compliant, audit response/error behavior against the current OTLP
spec: correct content type, signal response body, retryable 429/502/503/504 semantics,
`Retry-After`, and partial-success behavior. qits can continue to support only HTTP/protobuf; the
standard permits configurable non-default paths, while OTLP/JSON and gRPC add no value for the
pinned senders.

## Workstreams

### LA — Prove the bridge in one packaged Quarkus service

Use qits-events or qits-ci as the canary; both already have the dependency and configuration.

1. Extend its offline OTLP stub to capture `/v1/logs` and decode `ExportLogsServiceRequest`.
2. Emit one INFO record and one ERROR with a throwable through the logger the service already uses.
3. Emit the error inside a request/server span.
4. Assert service/resource identity, timestamps, severity, body, exception fields, trace id and span
   id from the actual exported protobuf.
5. Assert the console handler still receives output.
6. Repeat against the packaged native binary. A JVM-only proof is insufficient because every
   shipping service is native and logger/exporter initialization is build-time-sensitive.
7. Point at an unreachable stub and prove requests remain healthy and memory is bounded.

This workstream is the decision gate. If ordinary JBoss logs do not reach the stub in the pinned
Quarkus version, diagnose the handler/exporter configuration first. Only if the documented bridge
cannot work in the packaged binary does a custom qits extension become eligible.

### LB — Prove the real receiver end to end

Add a packaged `qits-observability` integration fixture that starts a canary sender or posts the
captured canary payload, then queries the normal API:

- the source is the canary's `service.name`, not `_unscoped`;
- INFO and ERROR appear on the logs endpoint;
- the error appears in the errors feed with its stack trace;
- the correlated log appears on its trace page;
- a second batch is accepted after an idle connection/reconnect;
- malformed protobuf is 400 and oversized decompressed input is 413;
- receiver restart truthfully resets `startedAt` and data.

Preserve the receiver's clone-alone rule: the canary/stub is local test machinery, no live collector,
Docker or network dependency.

### LC — Normalize all platform Quarkus producers

Across the ten services:

- explicitly set handler enabled, `cdi` exporter and INFO export floor;
- keep the shared HTTP/protobuf base endpoint and service name;
- add an unreachable-receiver test where a repo does not already inherit equivalent evidence;
- add one lightweight configuration assertion so dependency/property drift cannot silently disable
  logs;
- run each repository's normal JVM and native/package gates;
- deploy one at a time and confirm a uniquely named canary log in the live source bucket before
  moving to the next.

Do not copy the full LA protocol test ten times. Put reusable test support in a test-scoped artifact
or keep one exhaustive canary plus small per-repo configuration tests; production code must not gain
a qits logging library when the Quarkus extension already is that library.

### LD — Add resource identity at the deployment boundary

Set `service.version`, environment and instance/container identity where containers are assembled,
not as ten divergent application-property copies. Confirm qits-observability's source bucketing and
UI expose the intended distinctions without exploding source count.

For workspace services, restore the missing `ServiceSupervisor` OTLP environment overlay as its own
workstream:

- reintroduce an explicit workspace config toggle (default off until proven);
- inject `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`,
  `OTEL_SERVICE_NAME`, and `OTEL_RESOURCE_ATTRIBUTES` containing the real repository/workspace ids;
- ensure the address resolves from the workspace container network;
- cover Java/Quarkus first; other frameworks opt in through their public OTel SDKs;
- verify stop/restart does not orphan exporter processes.

This is the missing sender already recorded in qits-observability's README. It is not required for
the ten platform services, which export directly today.

### LE — Cover daemons and non-Quarkus processes deliberately

Inventory the qits-ci daemon, workspace daemon and any host/bootstrap scripts. For Java daemons,
choose either the OpenTelemetry Java logging appender/SDK configured for OTLP HTTP or console capture
by a future Collector. Do not pull Quarkus into a standalone daemon merely for logging.

Prefer console capture when a supervisor already owns stdout/stderr and can add resource identity;
prefer an in-process OTel appender when trace correlation exists inside the daemon and is valuable.
Native-image compatibility, bounded shutdown flush and daemon bootstrap availability are acceptance
criteria either way.

Browser code remains separate: `@qits/angular` already uses the OTel logs SDK for uncaught errors.
Do not reinterpret `console.log` as an application-log stream or ship arbitrary browser console
content, which is noisy and can contain user data.

### LF — Production validation and operating contract

Run a controlled canary per shipping form and record:

- time from logger call to query visibility;
- batch size/request rate at ordinary and burst load;
- queue/drop behavior during a receiver outage and recovery;
- receiver CPU, heap, source counts and eviction counters;
- whether secrets or credentials appear in bodies, exception messages, MDC or framework logs;
- trace/log linking and identity correctness;
- self-export behavior of qits-observability without recursion.

Set alerts/health around dropped exports and receiver evictions, but do not log exporter failures
through the exporter itself. Document that the UI is a bounded recent window, not an audit log.

### LG — Optional durable retention, separately approved

Constrained 2026-08-05: qits adds no external component that cannot be embedded into the Quarkus
app. That removes third-party log backends and sidecar collectors from the option list. If the
bounded live window ever proves insufficient, the only path is a qits-owned persistent store
inside qits-observability — a much larger build than receiving logs, so it waits for a compelling
query/isolation requirement. Until then the live window stands.

Nothing in LA–LF waits for LG.

## Acceptance criteria

- An unchanged `org.jboss.logging.Logger` call in a packaged native service appears in
  qits-observability through OTLP/HTTP without a custom application logging dependency.
- INFO/WARN/ERROR/FATAL mapping, throwable/stack trace, resource identity and active trace/span ids
  are verified from the actual exported protobuf and from the query API.
- All ten platform services explicitly enable the same bounded, asynchronous, fail-open exporter.
- Console output remains enabled.
- A receiver outage neither blocks requests nor grows producer memory without bound; recovery sends
  new records.
- qits-observability's ingest remains bounded, its restart/eviction truth remains visible, and its
  self-export does not recurse.
- Workspace and daemon coverage is explicit rather than implied by the platform-service rollout.
- No GELF, syslog, Loki-specific or qits-private log wire is added.
- Native/package tests and a live canary prove every shipping form included in the rollout.

## References checked 2026-08-02

- Quarkus, “Using OpenTelemetry Logging” — the JBoss Log Manager bridge, required dependency and
  properties; still marked preview:
  https://quarkus.io/guides/opentelemetry-logging
- Quarkus, “Using OpenTelemetry” — current exporter/handler configuration reference:
  https://quarkus.io/guides/opentelemetry
- Quarkus, “Logging configuration” and “Centralized log management” — built-in syslog and the
  deprecated GELF alternative:
  https://quarkus.io/guides/logging
  https://quarkus.io/guides/centralized-log-management
- OpenTelemetry, OTLP 1.11 specification — HTTP/protobuf paths, responses, compression, retry and
  body limits:
  https://opentelemetry.io/docs/specs/otlp/
- OpenTelemetry, stable Logs Data Model — timestamps, severity, resources, attributes and trace
  context:
  https://opentelemetry.io/docs/specs/otel/logs/data-model/
