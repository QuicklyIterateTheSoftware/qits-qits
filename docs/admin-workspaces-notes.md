# Admin workspaces: the docker socket, and the four repositories it took

Shipped 2026-08-20. An **admin workspace** is an ordinary ad-hoc workspace whose container holds the
**host's docker socket**, so platform administration can be done from inside a workspace. It is
asked for at creation — a checkbox on the ad-hoc create form, "Enable docker socket" — and never
afterwards.

The living contracts are in the repositories themselves (qits-workspaces' AGENTS.md has the whole
posture, qits-containers' README has the bind and the group). What has no other home is **why the
change is four repositories**, because each of the four is a place the privilege could have been
made unusable or unbounded, and the split is not obvious from any one of them.

## The one sentence everything follows from

**A container holding the host's docker socket is root-equivalent on that host.** It can start a
container that mounts anything, as root, on the host's behalf — so the sandbox flags around it are
beside the point, and the only question worth asking is *which* containers hold it.

## The four repositories, and what each one refuses to do

**qits-workspaces** — the posture. `Workspace.admin` (V4) is a column on the row, not a flag on a
launch, because the orchestrator has no start verb: a stopped container is started by presenting its
spec *again*, and a spec that differs replaces the container. The credential columns are there for
exactly the same reason and say so. It is written once, by the request that created the workspace,
and there is no promote verb — a workspace that has been running for a week cannot acquire the
socket. Every failure direction of the read falls to *false*: no port wired, no row, a read that
threw. That asymmetry with the credential lookup beside it is the point, and it is tested — a
credential lookup that stumbles costs a container something it was meant to have, while a posture
lookup that stumbles must never **give** it something it was not.

**qits-containers** — the bind, and the group. The socket has always been a boolean on the spec
rather than a path, so no caller chooses what gets mounted. What was missing is that the socket is
`root:docker 0660`: a container holding the bind and running as anybody but root is refused on
`connect`. qits-ci never met it because its opted-in steps run as the image's own root; a workspace
container runs as the host uid, so for it the mount alone was inert. The orchestrator now renders
`--group-add <the socket's gid>` **inside the socket's own arm**, with the gid read off the socket by
the process that holds it — the same `unix:gid` the bootstrap reads when it decides which group to
start that service in. Deliberately *not* a spec field: a caller-supplied group would be the
assembled privilege the spec's shape exists to prevent, and a group with no bind beside it would be
a membership nothing justifies.

**qits-workspace-oci** — the client. `docker-ce-cli` alone, no daemon: a socket with nothing
to speak to it is a bind and not a capability. It is in the base rather than in a second image
because the whole difference between the two would be a CLI that does nothing without a bind only
the platform can grant. In every non-admin workspace the binary is inert and says so ("Cannot
connect to the Docker daemon"), which is the honest state.

**qits-workspaces-frontend** — the asking, and the seeing. The checkbox starts unticked on every press
and is never remembered: the answer belongs to one workspace rather than to a preference. The list
marks the workspaces that hold the socket, because a privilege nobody can see is one nobody gives
back.

## What is deliberately absent

- **No config key that widens it.** Nothing about a repository, an image, a branch name or a
  deployment property can make a workspace admin. The only input is the creating request.
- **No second role.** Creating any workspace already requires `qits:admin` on the controller; the
  socket is granted per workspace rather than per caller, and a role qits-idp does not issue would
  be a gate nothing could pass.
- **No sandbox change.** An admin workspace is an ordinary workspace holding a socket: same image,
  user, limits, mounts, environment. `WorkspaceContainersTest` makes that claim as the admin spec
  with the socket taken back out, so any other field that moved fails it.
- **No promotion, and no revocation verb either.** Ending the privilege is ending the workspace,
  which is what discard already does. If a "drop the socket" verb is ever wanted, note that it is a
  spec change and therefore a container replacement — the checkout survives on its volume, the
  writable layer does not.
