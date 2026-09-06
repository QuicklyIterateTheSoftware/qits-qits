# Release priorities on participating branches — shipped 2026-09-06

A priority now lives on each **participating branch** of a release request (the
`ReleaseRequestSource` row behind the octopus fold), not on the request itself:
`LOWEST, LOW, MEDIUM, HIGH, HIGHER, BLOCKING`, default `MEDIUM`. The request's
effective priority is the max over its branch sources, exposed on its DTO. A
source's priority is declared at create/add-source time and can be re-declared
on any open request via
`POST /projects/api/repositories/{repoId}/release-requests/{id}/sources/priority`
(body `{branch, priority, requester?}`; 404 unknown branch, 400 unknown word,
409 once RELEASED/WITHDRAWN). Implicit released-tag sources carry no priority.

The value rides the chain as inert data: `ReleaseRequestChanged` and
`SCMRelease` gained a trailing nullable `priority`; qits-ci transcribes it
through the release join (`ci_scm_release.priority`) onto `SoftwareRelease` and
**acts on it nowhere** — the run queue is untouched; qits-deployments records it
on `pd_deployment_request.priority` (and `pd_owed_release`, so the re-drive
keeps it), display-only. qits-maintenance opens every bump's release request at
`LOWEST`, unconditionally — a dependency bump is never what anybody is waiting
for. Queue *ordering* by priority is deliberately the next feature; this one
only makes the signal exist and survive every hop.

Estate: projects-frontend 2026.906.114002, projects-service .145210 (+ webui
bump .150120), ci-service .154111, deployments-frontend .150914,
deployments-service .151734 (+ webui bump .153444), maintenance .152645.
End-to-end proof: maintenance .154915 — created HIGH, escalated to BLOCKING on
the open request, released, and the deployment request records BLOCKING.

## Debts surfaced by the rollout (pre-existing, documented here with owners open)

- **SPA repositories publish no release.** qits-projects-frontend and
  qits-deployments-platform-frontend carry only `ci-event-release-request.yml` —
  no `ci-event-release.yml` — so an SPA release ends at the tag: no tag build,
  no `SoftwareRelease`, invisible to release trains and to `mt_latest`'s
  package ecosystems. The webui follow works anyway (gitlink `mt_latest` moves
  on `SCMRelease`; the bump is nightly-02:00 or manual — `BumpTrigger` has no
  ON_RELEASE), but "release the SPA, wait minutes" is really "wait for the
  next bump".
- **A `CONFLICTED` bump release request can deadlock.** The bump branch keeps
  the pin commit, so a re-triggered bump answers `NOTHING_TO_DO` ("the branch
  did not move") and the request never re-arms, while the branch's stale base
  keeps the fold conflicting after a competing pin reaches `main`. Observed
  live on qits-projects-service; unblocked by withdraw + branch delete +
  fresh bump. The machinery wants either branch recreation on re-bump or a
  re-fold when a blocking released tag merges back.
- **Release trains spawn with zero nodes so far** — correct per derivation
  (INTERNAL pins + SBOM dependents; gitlink excluded thrice by design), but
  untested with a real consumer set: no javalib has released since the feature
  landed. The first `eu.wohlben.qits` maven release is the real test.
- **`dev-qits-artifacts: Name or service not known`** killed three SCMRelease
  tag builds inside their image builds on 2026-09-06 (~11:55–12:30); all three
  retried green. Intermittent DNS on the build network, the known
  buildkit-network debt's shape.
