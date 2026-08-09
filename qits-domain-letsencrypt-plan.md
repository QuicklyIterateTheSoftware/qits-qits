# qits-domain: Let's Encrypt on the edge, DNS root from one param

Two changes travel together here:

1. **qits-platform-dns becomes a core service.** The bootstrap seeds, deploys, and
   health-polls it unconditionally — it was simply never wired in, and its
   `deployments.yml` flagged the missing health surface as the blocker.
2. **One new bootstrap param, `QITS_DOMAIN` / `qits.domain`.** Unset — the default —
   the platform behaves as today (dns runs with zero zones and no SOA synthesis,
   which its README documents as a legal state). Set, the platform serves a real
   domain: dns gets its NS/hostmaster identity and the zone row, and the edge gets
   TLS with a Let's Encrypt certificate slot.

Verified against Quarkus 3.34.6 (the platform pin), not the docs on `main`:
`LetsEncryptRecorder` is in quarkus-tls-registry 3.34.6, and
`quarkus.smallrye-health.management.enabled` exists to keep health off the management
interface.

## How Quarkus Let's Encrypt works (and what that fixes for us)

The app is not an ACME client. Build-time flags add an HTTP-01 challenge route to the
main listener and challenge-management endpoints to the management interface. The
`quarkus tls lets-encrypt` CLI does the ACME protocol from outside: it configures the
challenge through the management endpoint, gets the PEMs issued, writes them where the
app's TLS registry reads them, and the registry hot-reloads. Renewal is the same CLI
run again.

Consequences:

- The build-time flags are baked into the image but inert without runtime keystore
  config. "Disabled until a public node exists" is a deployment-config fact, not a
  build fact.
- The challenge-management endpoint is unauthenticated. On the main listener it would
  let anyone on the internet complete their own ACME order for our domain, so it goes
  on the management interface (port 9000), which is never published publicly.
- Enabling the management interface moves `/q/health` to it by default, which would
  break the bootstrap's and the deployer's health polls. `quarkus.smallrye-health.management.enabled=false`
  keeps health on :8080.

## Work package A — services/qits-platform-edge

Build-time, always on, dormant without runtime TLS config:

    quarkus.tls.lets-encrypt.enabled=true
    quarkus.management.enabled=true
    quarkus.management.host=0.0.0.0
    quarkus.smallrye-health.management.enabled=false

Tests:
- Config pin (OtelLogConfigTest style) for the four keys.
- Route precedence: with a stub upstream, `GET /.well-known/acme-challenge/x` is
  answered by the extension, never proxied — assert the stub sees nothing.
- `/q/health/live` and `/q/health/ready` still answer on the main port.

No keystore config in this repo. The deployment supplies it (package C).

## Work package B — services/qits-platform-dns

Settle the health question exactly as the repo's own `deployments.yml` prescribes:
- Add quarkus-smallrye-health to the service module. The endpoint lands under the
  already-configured `quarkus.http.non-application-root-path=/dns/q`.
- Write `health_path: /dns/q/health/ready` in `.config/qits/deployments.yml`; replace
  the open-question comment with the answer.
- Pin test: `/dns/q/health/ready` answers, and DB readiness is part of it (agroal
  registers automatically).

No domain config here — the service stays domain-free by design (zones are rows).

## Work package C — cli/qits-cli-bootstrap

### Unconditional: qits-platform-dns joins the platform

Membership in every set that matters — seed image, repository push, compose entry,
deploy phase, run-args line, health poll (`http://qits-platform-dns:8080/dns/q/health/ready`),
closing report. Deploy order: with the other platform services, before the edge.
Database `qits_platform_dns` provisioned in the seed stack like the other postgres
consumers; the deployed path already works via `resources: postgresql:db`.

Port publish follows the existing port-knob family: `QITS_DNS_PORT`, default `53`,
published as `${QITS_DNS_PORT}:8053/udp` and `${QITS_DNS_PORT}:8053/tcp` (TCP is
mandatory — truncated UDP answers carry zero records).

### New knob

    QITS_DOMAIN / qits.domain    Optional<String>, no default

Full BootstrapConfig pattern: mapping method, OverridableConfig + `--domain` flag,
`.env.example`, README table, tokens, tests. When unset, ComposeTemplateTest asserts
the rendered compose and run-args differ from today only by the dns additions above.

When set:

1. **DNS identity.** Env on the dns container (compose and run-args):
   `QITS_DNS_NS_NAMES=ns1.<domain>`, `QITS_DNS_HOSTMASTER=hostmaster.<domain>`.
   Both or neither — half-configured silently disables SOA/NS synthesis.
2. **Zone seeding.** After dns is healthy, `POST /dns/api/zones {"fqdn":"<domain>"}`,
   idempotent. No records: their values need the public IP, which the bootstrap does
   not know. The registrar delegation (NS ns1.<domain> plus glue A) and the record
   rows are operator steps; the closing report says so.
3. **Edge TLS wiring** (seed compose entry and run-args line, both):
   - ports: keep `${PORT}:8080`, add `80:8080`, `443:8443`, `127.0.0.1:9000:9000`
   - volume: `qits-edge-letsencrypt:/work/.letsencrypt`
   - env: `QUARKUS_TLS_KEY_STORE_PEM_ACME_CERT=/work/.letsencrypt/lets-encrypt.crt`,
     `..._KEY=/work/.letsencrypt/lets-encrypt.key`, `QUARKUS_TLS_RELOAD_PERIOD=1h`
   - `quarkus.http.insecure-requests` stays default for now; the health polls speak
     plain HTTP. Flip to `redirect` later, together with the pollers.
4. **Placeholder certificate.** A keystore pointing at missing files fails startup, so
   before the edge starts with this config the bootstrap seeds the volume with a
   self-signed cert for `<domain>` via a one-off container (the alpine/git image the
   bootstrap already uses carries openssl; verify, else alpine/openssl). Skip if the
   volume already holds a cert.
5. **Closing report** prints the issuance command, staging while we trial it:

       quarkus tls lets-encrypt issue-certificate --staging \
         --domain=<domain> --email=<operator> --management-url=http://localhost:9000

   Renewal is `renew-certificate` with the same management URL. Issued PEMs land in
   the `qits-edge-letsencrypt` volume (same filenames); the registry reloads within
   the reload period.

## Out of scope, recorded

- Real (non-staging) ACME: flip the printed command when the first staging issuance
  has worked end to end.
- A/AAAA record seeding and `insecure-requests=redirect`: both need the public node.
- In-app ACME (acme4j) to drop the host-side CLI: revisit if renewal-by-hand annoys.
