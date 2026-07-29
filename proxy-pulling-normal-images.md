# Pull-through cache: qits-artifacts as a registry mirror

Status: **planned, not started.** Written 2026-07-29.

Now that qits-artifacts speaks the OCI Distribution API (`priority-feature.md`), the same routes can
serve images it did not author: point a docker daemon's `registry-mirrors` (or podman/containerd's
`registries.conf` mirror block) at the deployment, and every `docker pull alpine` in every workspace
container and ci step is fetched from upstream **once** and served from local disk thereafter. The
storage side is nearly free — a cached layer is a `BlobStore` blob like any other, and the manifest
tables already scope things per name — so the work is a miss path: on a manifest or blob GET that
this registry does not have, fetch it from the configured upstream, verify the digest while
streaming (`BlobStore.stage` does that anyway), promote, and serve. A hit is the existing code
unchanged.

Four things to settle before building. **Namespacing:** cached upstream images must not collide with
pushed ones, so the mirrored content wants its own repository (or its own `RepositoryType`) and the
mirror namespace must reject pushes outright rather than merging the two. **Upstream credentials and
rate limits:** anonymous Docker Hub pulls are rate-limited per IP, and a mirror concentrates every
consumer behind one address, which makes the limit *easier* to hit rather than harder — so an
upstream token is part of the feature, not a nicety. **Client reach:** docker's `registry-mirrors`
only applies to Docker Hub, while podman and containerd can mirror any registry, so the docker case
is narrower than it first looks and should be stated in the deployment doc. **Garbage collection:**
a cache grows without bound, and the registry is deliberately append-only today with `DELETE`
unimplemented — a mirror is the first use that genuinely forces the GC story, so it should be
designed here rather than deferred again.

To be extended with the remaining requirements.
