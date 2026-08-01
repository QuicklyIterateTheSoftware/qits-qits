# npm registry: two facts rescued from the retired plan

The hosted npm registry + npmjs proxy shipped in services/qits-artifacts; the plan was verified
fully implemented and retired 2026-08-01. The contract lives in the repo's README/CLAUDE.md and
qits-ci's README. These two facts had no other home.

- **What the proxy buys, measured**: cold install 10.6 s / warm 1.7 s over 568 tarballs. The only
  install-time quantification of the pull-through cache anywhere (the GC plan carries sizes only).
- **Why the upstream needs no credential**: npmjs has no Docker-Hub-style anonymous pull limit;
  the upstream config key exists so a token can appear later without a schema change — the README
  documents the key, this is the reason behind it.

Adjacent note: `artifact-access-tracking.md` (still planned, not started) inherited npm-eviction
scope from the retired plan but mentions npm nowhere — `artifacts-gc-plan.md` ⚖1 is what actually
owns the proxy-eviction question now. Update access-tracking's scope when it gets picked up.
