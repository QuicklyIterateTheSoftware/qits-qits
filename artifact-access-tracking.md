# Track last access per artifact, and expose it for cleanup

Status: **planned, not started.** Written 2026-07-29.

Nothing in qits-artifacts records that an artifact was *used*. A blob GET is a `sendFile` with no
database touch at all, and OCI layers deliberately get no row of their own, so today the only
timestamp anywhere is `created_at`. That is the gap that blocks cleanup: the registry is append-only
with `DELETE` unimplemented precisely because there is no safe basis for deciding what to drop, and
"nothing has pulled this tag in six months" is the basis we actually want. The end state is an API
that lists artifacts **per repository type** — `oci-images` alongside `ci-screenshots` and
`ci-videos` — with their metadata, filterable on `accessed-at` (and plausibly on size and
created-at), so both an operator and a future GC read the same view.

Three things to settle. **What the unit is:** for OCI it is the tag and the manifest, not the blob —
blobs dedupe globally, so one blob is reachable from several repositories and its access time cannot
be attributed to any of them; reachability from tags is what a GC must walk, and a blob is collectable
only when no manifest names it. **Where the rows are:** the two CI types are `artifact_record` rows
while images are `oci_manifest`/`oci_tag` rows with no `artifact_record`, so a cross-type listing API
is either a facade over both shapes or a decision to give images records too — worth choosing
deliberately, since the existing `GET /repositories/{repo}/blobs` query with its `?meta.` predicates
is per-repository and would be generalised rather than replaced. **What a read costs:** exact
last-access means a write on the hottest path in the service, a layer pull; coarsening it (only
update when the stored value is older than an hour, or batch asynchronously) trades precision nobody
needs for a cost that matters, and the choice should be explicit rather than discovered under load.

Related: `proxy-pulling-normal-images.md` — a pull-through cache grows without bound and is the first
feature that genuinely forces this, so the two should be designed together.

To be extended with the remaining requirements.
