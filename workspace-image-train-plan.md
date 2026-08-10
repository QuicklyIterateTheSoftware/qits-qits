# Workspace images join the release train

Settled (user, 2026-08-10): no hand-built `qits/*:latest` images. A daemon repo
builds and publishes its own RUNNABLE image through its CI (sha-tagged on push,
calver on release), and every version pin is bumped by the TRAIN — the same
`ci-event-upstream-*.yml` machinery the jar and SPA follow-bumps use. No new
repositories.

## Today's disease (measured)

`qits/workspace:latest` (and `qits/projects-daemon:latest`,
`qits/project-agent:native`) are hand-built local docker tags: no version, no
registry, no pipeline. `unwrap` sweeps `qits/*`, nothing rebuilds them, and the
next workspace launch dies with "no workspace-daemon dialed home". The BASE is
already done right: `images/qits-oci-workspace` publishes the toolchain base
through the train.

## Target shape

1. **qits-workspace-daemon** carries `ci-post-receive.yml`: one docker build —
   builder stage compiles the native daemon, final stage `FROM` the registry's
   toolchain base at a PINNED version, copies the binary, entrypoints — pushed
   as `$QITS_REGISTRY/$QITS_IMAGE_REPOSITORY/qits-workspace-daemon:$QITS_CI_SHA`.
   `ci-event-release.yml` re-tags the released calver (the edge/dns shape,
   artifacts declaring `{type: docker}`). The base pin lives in the Dockerfile
   and is bumped by `ci-event-upstream-oci-workspace.yml` when the base
   releases (sed on the FROM line, maintenance branch, the eventstream-bump
   file's shape verbatim — version allowlist and all).
2. **qits-workspaces** stops defaulting `qits.workspace.image` to a local
   `latest`: the shipped default becomes the registry reference at a pinned
   calver, and `ci-event-upstream-workspace-daemon.yml` bumps that pin when the
   daemon releases — so the workspaces service rolls with the new image the way
   a service follows its SPA. The launcher must PULL a registry reference it
   does not hold locally (today it assumes a local tag).
3. **qits-projects-daemon / qits-projects**: the identical pattern for the
   projects-daemon and project-agent images and their pins (second wave, after
   1+2 prove the shape).
4. **qits-cli-bootstrap**: a fresh platform must re-publish the images its pins
   name — add the image-publishing repos to the bootstrap's release-replay set
   (the publisher-jar precedent, phases 35-38), so a full wipe rebuilds them
   from docker's layer cache instead of leaving dangling pins.

## Registry addressing

Inside a CI step and for the host daemon the registry is `localhost:8081`
(`$QITS_REGISTRY`); base-image pulls in Dockerfiles go through the mirror
prefix exactly as every other seed/CI Dockerfile does. The published NAME for
the base stays what its consumers already write (`qits-oci-workspace`'s README
records the naming decision) — the daemon repo's FROM line follows whatever
that repo's pipeline actually pushes.

## Order

Package 1 and 2 land together (2's pin names 1's first published version;
until 1 has released once on the live platform, 2's pin is minted by hand at
1's first calver). 3 follows the proven shape. 4 rides the next
qits-cli-bootstrap change.
