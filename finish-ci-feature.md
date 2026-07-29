# Finish the registry feature: conformance in ci

Status: **planned, not started.** Written 2026-07-29.

The OCI registry (`priority-feature.md`, now implemented) shipped every milestone except one
explicitly optional item: **the OCI distribution-spec conformance suite, wired into qits-ci as a
step.** Everything else — M0's ceiling verification, M1's registry core, M2's real clients through
qits-gateway, M3's `tags/list`, upload status and multi-chunk resumption — is in tree and covered by
`mvn verify`, the native `PackagedProcessIT`, and a manual end-to-end run through the deployment
topology recorded in that document's §9. What is missing is a *standing* check: today the protocol is
proved by our own synthetic client (`registry/OciClient`) plus a hand-run of docker against a live
deployment, so a spec conformance regression would only be found by someone repeating that by hand.

The suite is the upstream `opencontainers/distribution-spec` conformance binary, run against a live
qits-artifacts with a pre-created `oci-images` repository and the four workflow groups it offers
(pull, push, content-discovery, content-management). Two things make it a good fit for a ci step and
one makes it awkward: it is a pure HTTP client, so `CiDockerRunner`'s no-docker-socket rule does not
block it, and its failures are per-spec-clause rather than per-assertion, which is exactly the
granularity we lack — but it ships as a container image that the runner has to pull from a public
registry, and the deletion group will fail by design, since `DELETE` is deliberately unimplemented
while there is no garbage-collection story. So the step needs its group selection pinned and that
exclusion documented as intentional, or the first red build will read as a defect rather than a
decision.

To be extended with the remaining requirements.
