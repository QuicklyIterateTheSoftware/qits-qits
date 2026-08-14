# Authenticated reads: close the anonymous-read exemption at edge

Status: PLANNED, opened 2026-08-14. Successor to the unify-ingress campaign,
which shipped method-scoped auth (writes gated, reads anonymous on the
registry and mirror vhosts) and left this flag as the escape hatch:
`qits.edge.auth.anonymous-read-apps=registry,mirror`.

**Goal: that list becomes empty.** Every request through edge authenticates —
docker pulls, `FROM` pulls inside builds, maven and npm resolution, mirror
cache reads. No port changes; this is credential plumbing only.

## Why reads stayed anonymous (what this plan must solve)

The unify-ingress investigation found five pull points, none with a safe
credential home:

1. **Maven inside `docker build`.** ~19 release recipes run
   `docker build --network host --build-arg QITS_MAVEN_REPOSITORY_URL=…` and
   Maven resolves qits jars from that URL inside the build. A credential via
   `--build-arg` is recorded verbatim in layer metadata by the legacy
   builder, and the built images are pushed to the registry — publishing the
   secret through the very door it protects. The clean channel is BuildKit's
   `RUN --mount=type=secret`, which persists nothing; the platform still
   builds partly on the legacy builder.
2. **`FROM mirror.dev.localhost:8080/…` base pulls** in every CI build — the
   docker client sends its own stored auth for base images, so this follows
   the step's `DOCKER_CONFIG` (which pushes already use).
3. **The deployer's pulls.** `SwarmDeploymentDriver` runs `docker pull` as
   uid 1001 with no `HOME` and no `DOCKER_CONFIG`, and never passes
   `--with-registry-auth`, so swarm task pulls carry no credential either.
   Bonus defect: a `pull access denied` is classified `IMAGE_MISSING`
   ("nothing published this build"), which would misreport every auth
   failure.
4. **qits-containers' pulls** (workspace and agent images):
   `DockerArgv.java:298` — plain `docker pull` argv, same missing config
   home as the deployer.
5. **The host dev loop**: `docker pull`, `mvn`, `npm` on the workstation.
   No `~/.m2/settings.xml` or `~/.npmrc` exists; every registry address is
   committed per repo, and credentials must never be.

One protocol gap sits above all of them: **edge accepts only
`Authorization: Bearer <jwt>`** on protected paths. Docker does the
token-endpoint dance itself; maven, npm, git and curl do not, and idp's
300-second no-refresh tokens cannot be stored as a static password.

## Design

- **D1 — edge accepts Basic on protected requests.** A request carrying
  `Authorization: Basic <client-id:secret>` is validated by brokering
  client_credentials to idp (the `/token` machinery edge already has),
  with a small positive-decision cache (TTL ≤ the idp token TTL) so idp
  stays off the per-request path. Bearer keeps working unchanged; docker
  keeps its dance. This one change makes maven (`<server>` credentials
  answer the 401), npm (`//host/:_auth` sends Basic), git (credential
  helper instead of the extraHeader dance) and humans-with-curl all work
  with ONE durable credential shape: an idp client id + secret.
  Ride-along: fix the anonymous-`docker push` hang (the /token 401 arm).
- **D2 — finish the BuildKit exit first.** Secret mounts require BuildKit;
  the legacy-builder exit is already doctrine ([[containerd-store memory]])
  and becomes a hard precondition here. No secret work lands on a
  legacy-builder path.
- **D3 — secrets enter builds as BuildKit secret mounts, exposed as env.**
  Dockerfile: `RUN --mount=type=secret,id=qits-maven,env=QITS_MAVEN_AUTH …`
  on the maven lines; `.qits-maven-settings.xml` gains a `<server>` for the
  `qits-maven-network` mirror id reading `${env.QITS_MAVEN_AUTH_*}`. The ci
  launcher materializes the secret file next to the DOCKER_CONFIG it
  already writes, and the recipes pass `--secret id=qits-maven,src=…`.
  Nothing lands in a layer, nothing in the build cache key.
- **D4 — pull credentials are docker client config, in three homes.**
  Step containers: already have `DOCKER_CONFIG` (covers FROM pulls).
  Deployer: `DOCKER_CONFIG=/work/config` (the config volume, self-update
  inherited), a `config.json` written by the bootstrap's pd-extras phase,
  plus `--with-registry-auth` on service create AND update so task pulls
  get the credential. qits-containers: same pattern on its own config
  volume. Fix the deployer's `pull access denied` → its own outcome, not
  `IMAGE_MISSING`.
- **D5 — host credentials are per-user files, never committed.**
  `docker login registry.dev.localhost:8080` + `mirror…`, a `~/.m2/
  settings.xml` server block, and `~/.npmrc` `_auth` lines. The committed
  per-repo files stay credential-free (an env-expansion line in a
  committed `.npmrc` breaks CI when the variable is unset — do not do it).
  The bootstrap summary prints the three snippets.
- **D6 — which client.** Reads authenticate as `dev-qits-artifacts` like
  everything else for now; per-audience read clients are a later idp-plan
  concern, not this campaign's.

## Work packages

- **WP0 — verify.** Which repos/steps still build via the legacy builder
  (build images, `DOCKER_BUILDKIT`, node-docker-base state); that maven
  answers edge's 401 with configured Basic credentials (resolver
  transport); npm `_auth` against a path-prefixed registry; qits-containers'
  container filesystem/volume for a config home; whether `--with-registry-auth`
  is accepted with `--no-resolve-image`.
- **WP1 — edge: Basic acceptance + broker cache** (+ the push-hang fix).
  Tests: Basic read 200, wrong secret 401, cache expiry, Bearer unchanged,
  env vhost untouched.
- **WP2 — BuildKit everywhere.** Finish the legacy-builder exit for every
  repo still on it; prove the containerd-store race class stays closed.
- **WP3 — fleet build-secret sweep** (~19 repos, one commit each):
  Dockerfile secret mounts, settings `<server>`, recipe `--secret` flags.
  Buildable BEFORE the flip (secret present but registry still anonymous —
  the mount is inert), so this lands incrementally through normal releases.
- **WP4 — ci launcher: materialize the maven secret** beside the existing
  DOCKER_CONFIG; same all-or-nothing config keys, same masking.
- **WP5 — deployer + qits-containers credentials** (D4), released in
  order: deployer first (its `--with-registry-auth` is inert against an
  anonymous registry, so it can ship early).
- **WP6 — bootstrap.** ComposeTemplate: emit the new env/keys, write the
  two `config.json`s, print the D5 host snippets; seed phases are
  UNAFFECTED (loopback ports, pre-edge). Flip
  `QITS_EDGE_AUTH_ANONYMOUS_READ_APPS` to empty in the template LAST,
  in the same commit as the boot-order proof.
- **WP7 — the flip, gated like a port drop.** On the live platform: set
  the edge env empty, redeploy edge, then prove in order — anonymous pull
  DENIED, credentialed pull, full release train, a deploy, a workspace
  launch, host `mvn -U` + `npm ci` with per-user credentials. Only then
  rebootstrap to prove from-zero. Rollback is the config flag back to
  `registry,mirror` — one env change, no code.

## What blocks what

    WP0 ─ WP1 (edge Basic) ────────────┐
    WP2 (BuildKit exit) ─ WP3/WP4 ─────┤
    WP5 (deployer/containers creds) ───┤
    WP6 (bootstrap wiring) ────────────┤
                                       ▼
    WP7 flip (live, gated) ─ rebootstrap proof

## Risks and accepted costs

- idp joins the read path at cache granularity; its outage window narrows
  to the cache TTL. The db-patience work covers idp's own store; edge must
  fail CLOSED but with the broker-patience lesson from 2026-08-14 (a
  deploy-fanout racing an idp redeploy) answered — retry inside the broker
  before denying.
- Secret rotation: the idp client secrets live on config volumes and
  survive unwraps; a rotation means re-login in three config homes + the
  per-user host files. Document it in WP6's summary text; no automation in
  this campaign.
- The break-glass is unaffected: its port bypasses edge entirely and stays
  the anonymous recovery path while open.
- The env vhost (browser traffic via gateway) is out of scope — that is
  the qits-idp-plan phase 2/3 user-auth track.
