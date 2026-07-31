# SoftwareRelease: the event a release publishes

Status: SEED (2026-07-31) — scoped by the user, deliberately queued behind two things that must
settle first: **release-flow-plan.md** (the versionbump-merge-push flow this event announces) and
the **qits-eventstream switchover** in qits-ci (the library this event rides; extracted and
renamed at libs/qits-eventstream, consumer switchover pending). Detailed design happens when both
are done; this document pins the intent so nothing drifts in the meantime.

## The feature, as specified

The service that performs the `git push` after the versionbump merge (the integrate flow's
executor, per release-flow-plan.md) gains the **qits-eventstream** dependency, and **as soon as
the push succeeds** publishes a **SoftwareRelease** event:

```json
{
  "name": "SoftwareRelease",
  "payload": {
    "projectId":  "…",
    "repository": "…",          // the repo that released
    "branch":     "…",          // the SOURCE branch that was integrated
    "version":    "2026.7.31-193059"
  }
}
```

- **No target field** — a release lands on `main` by construction (release-flow's whole premise),
  so a target would be a constant pretending to be data.
- The **pushing service is the publisher** because only it knows, atomically, that the push
  succeeded and with which version. Publish-after-push, never before.
- The publish goes through the standard seam pattern (the `RunAnnouncer` precedent): a port in
  the domain module, implemented in the deployable, so the domain stays bus-free and the event
  classes module stays the service's own vocabulary.

## What this unlocks (context, not scope)

- The release train becomes real: the live canary trigger in qits-spa-workspaces
  (`.config/qits/ci-event-upstream-ui-components.yml`) documents itself as waiting for exactly
  this — its `event:` flips from `BuildSuccessful` to `SoftwareRelease` and its echo step becomes
  the version bump, because the payload finally carries a version. (Older docs guessed the name
  "ReleaseEvent"; **SoftwareRelease** is the settled name — update those references when the
  trigger flips, not before.)
- Causation: an integrate initiated by a human is a chain root (no parent); downstream
  event-triggered builds stamp their parents per the shipped causation machinery.

## Out of scope here, named

- Everything about HOW the release happens — that is release-flow-plan.md.
- Artifact publication (still not a thing a release does).
- The trigger-file flip in consuming repos (its own small follow-up once this event flows).
