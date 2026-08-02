# Track last access per artifact, and expose it for cleanup

Status: **implemented 2026-08-02.** Backend `qits-artifacts` `9d60d23` + `2481398`, frontend
`qits-spa-artifacts` `bd77eb5`, embedded by `qits-artifacts` `9fe23c0`.

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

## Implemented contract

- `accessed_at` is nullable on `artifact_record`, `oci_manifest`, and `oci_tag`; null means never
  read. Successful reads update it at most once per hour using conditional bulk updates.
- A CI blob GET touches every record for that repository and digest. OCI manifest GET/HEAD by tag
  touches that tag and the resolved manifest; by digest it touches only the manifest. OCI layer
  reads remain deliberately unattributed because the request cannot identify a tag or manifest.
- Existing CI blob and OCI tag listings expose `accessedAt` and strict filters for access/creation
  times, size, and never-accessed state. Invalid filter values answer 400.
- `GET /repositories/{repository}/images/{image}/manifests` exposes every manifest, including
  untagged/displaced digest-addressable manifests, with tags, media type, size, creation, and access
  metadata. This is the cleanup-complete OCI view the tag listing cannot provide alone.
- The artifacts explorer renders CI inventories and OCI tag/manifest inventories, the filters and
  explicit Never state, and explains why layer transfers do not imply exact tag access.

Verification: backend `./mvnw verify` passed 180 artifacts, 18 git-storage, and 230 service tests
plus Angular/Quinoa packaging. Frontend passed 100 tests, lint, formatting, and production build;
the final embedded package build also passed.
