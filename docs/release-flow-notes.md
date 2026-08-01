# Release flow: what survives the retired plan

Shipped 2026-07-31, extended 2026-08-01 (the release/integrate split, tags, SCMRelease), verified
fully implemented and retired 2026-08-01. The living contracts are in qits-workspaces
(ReleaseIntegrator, gitmirror, VersionStamp, the bumpers) and qits-artifacts (ProtectedRefHook).
These three records had no other home. VersionStamp's javadoc points here for the measurements.

## The calver measurements (why `YYYY.MMDD.HHMMSS`, the range/resolution half)

The morning leading-zero landmine is in VersionStamp's javadoc; this is the other half — what a
dashed prerelease form would have done to RESOLUTION, measured against npm's bundled semver and
Maven's ComparableVersion (maven-artifact 3.9.12):

```
semver.maxSatisfying(['2026.7.31-93059','2026.7.31-193059','2026.8.1-93059'], '*')  ->  null
semver.satisfies('2026.8.1-93059', '^2026.7.31-193059')                             ->  false
semver.satisfies('2026.8.1-93059', '>=2026.7.31')                                   ->  false
```

A package whose versions are all prereleases resolves to NOTHING under `*`, and a caret range
stops matching the day after it was written. And the two stacks disagree about the same string:

```
                                       semver          ComparableVersion
2026.7.31-193059  vs  2026.7.31        -1 (BEFORE)     a > b   (AFTER)
```

A dashed suffix is a prerelease to npm and an unknown qualifier to Maven — one string, two
opposite meanings. Plus the leading-zero half: `-HHMMSS` before 10:00 is an all-digit identifier
with a leading zero, invalid semver — a format that works every afternoon and is invalid every
morning, 42% of the day. Hence: fold month+day and the time into integer-arithmetic identifiers,
`2026.731.193059`, a real release in both comparators, totally ordered, leading zeros impossible
by construction.

## The rejected `qits.override` design (the road not taken)

The original bypass was a well-known permanent push option, `-o qits.override` — a seatbelt
anyone could unbuckle, justified by "a platform whose own bootstrap cannot push without a running
workspaces service has a circular dependency", and by the measurement that 22 of 26 submodules
had never had a second branch. The user replaced it with the token (`-o qits.token=<value>` vs
`qits.repositories.git.push-token`, unset OR empty = nothing matches), deliberately trading the
seatbelt framing for a latch that defaults to locked: production may configure no token and then
direct pushes to main are simply impossible. If anyone proposes a well-known override option
again, this is the record of it being considered and replaced.

## Settled decision 2: the published packages switched to CalVer deliberately

`@qits/ui-components` (then 0.0.4) and `@qits/angular` (0.0.1) were INCLUDED in the calver bump
on their first release — one scheme, no exceptions. The alternative (excluding
`projects/*/package.json` from the bump) was weighed and rejected because it would make release a
no-op for the two repos where a version means something. Known consequence, live today: consumer
SPAs pinning `^0.0.4` never cross into the calver line — the frozen pins are exactly the pressure
the release train exists to relieve, and unfreezing them is the train fan-out's job.
(NpmVersionBumper cites "settled decision 2" — this is it.)
