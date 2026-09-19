# qits-qits

Home repository aggregating the application's submodules.

## Layout

Submodules are grouped by the component they belong to, not by the role they
play:

    components/<component>/<repository>

One directory per technical component, and every submodule lives in one. A
component is any cohesive unit of the product — it does not need a deployable.
`components/qits-ci/` holds the service, its frontend and its daemon side by
side; `components/qits-integrations/` holds two libraries and no service at all.

This replaces the old role directories (`services/`, `daemons/`, `libs/`,
`frontends/`, `cli/`, `images/`). Role was the wrong axis: it scattered the
three or four repositories you change together across four groups, and it made
the archetype — a property of a single repository — decide the whole tree. The
component is what you work on; the role is a detail of one entry inside it.

The component directory name says what the thing is, never how it is built:
`qits-database`, not `qits-postgresql`. The implementation may change, the
component does not.

Repository names follow the `<component>[-<modifier>]-<role>[-<tech>]` grammar:
`qits-ci-service`, `qits-ci-frontend`, `qits-ci-daemon`,
`qits-idp-platform-service`, `qits-eventstream-javalib`. Roles are `service`,
`frontend`, `daemon`, `oci`, `cli`, `javalib` and `jslib`; `platform` is a tier
modifier before the role; a tech suffix appears only where the role alone is
ambiguous. See `wrapper-reorganization-plan.md` for the full map of which
repository belongs to which component.

The repository name is not the application name. A service keeps its deployed
identity — the `qits-ci` application is built from `qits-ci-service` — and so do
maven artifactIds, npm packages, image coordinates, wire names and databases.

## Submodules

This section describes a clone you made yourself — a workstation, or a workspace
container — where the point of the checkout is to write. There, every submodule
sits on its own `main` and follows it, and syncing is automated, so in normal
work you never run a submodule command by hand. A project agent container is the
other case entirely: its `/workspace` is detached at a released version, nothing
in it is on `main`, and none of the commands below belong there. See "The
checkout in a project agent container" before running anything from here.

The gitlinks committed here make `git submodule update --init` work on a fresh
clone, and they name the estate. A gitlink moves the way everything else here
moves: by an ordinary commit on a branch. qits-maintenance writes it — when a
sibling releases, the bump resolves that repository's `refs/tags/<version>` into
a `160000` entry and pushes it onto a `maintenance/*` branch — so a pin never
names a passing branch head, only a version somebody released. From there it is
content like any other: it is folded into a release request, gated by CI (which
checks that every submodule `.gitmodules` declares has a pin, and that every pin
resolves in the sibling), and approved by a person against the fold that ships.
A wrapper version therefore names the estate that was reviewed, and a component
whose work is not released yet is simply absent from it rather than pinned
mid-flight. Never chase a gitlink by hand, and never move one to follow a
release you just made: a hand-written pin asserts an estate nobody gated and
nobody approved, and the next bump overwrites it regardless. Each entry in
`.gitmodules` carries:

    url = ../<name>.git   # relative, never an absolute URL
    ignore = all          # keep the expected drift out of `git status` / `git diff`
    branch = main         # what `--remote` follows
    update = merge        # merge the branch instead of detaching at a commit

The URL is relative to this repository's own origin, so the same `.gitmodules`
resolves the siblings on GitHub and on the platform git host.

### Fresh clone

A clone you made yourself, and only that. Do not run either line in a project
agent container: the checkout there is deliberately detached, and `git switch`
inside the submodules moves them off their recorded gitlinks, which dirties the
tree and silently freezes the checkout follower — see the never-write rule in
"The checkout in a project agent container".

    git submodule update --init
    git submodule foreach -q 'git switch -q main'

`update --init` checks out a *detached* HEAD at the recorded commit. The
`switch` gives each submodule a local `main` tracking `origin/main`; without it
everything still updates, but stays detached and any work committed inside a
submodule lands off-branch.

The underlying sync operation, should you need it directly:

    git submodule update --remote

Avoid `git pull --recurse-submodules` and `submodule.recurse = true`: they check
out the recorded commit and will drag submodules back off `main`.

Note that `ignore = all` hides submodule drift from `git status` and `git diff`,
but not from `git add -A`, which will stage a moved gitlink without showing it.
Prefer committing explicit paths here.

The same suppression reaches `git show` and `git diff --stat`: a commit that
adds or moves a gitlink reports only `.gitmodules` as changed. Confirm the
gitlink itself with `git ls-tree HEAD <path>`, which should show a `160000
commit` entry, or `git submodule status`.

### Adding a submodule

    git submodule add --name <name> ../<name>.git components/<component>/<name>
    git config -f .gitmodules submodule.<name>.ignore all
    git config -f .gitmodules submodule.<name>.update merge
    git submodule set-branch --branch main components/<component>/<name>
    git add .gitmodules components/<component>/<name> && git commit

`--name` is not optional, and the component layout makes it more load-bearing,
not less. Modern git (seen on 2.53) defaults the submodule *name* to the full
path, so adding at `components/qits-ci/qits-ci-frontend` names the entry
`components/qits-ci/qits-ci-frontend` — a three-segment name — while every entry here
uses the bare repository name, which is also the key the platform catalog adopts
by. The mismatch is quiet and costly: the `git config` lines above then write a
*second*, orphan `[submodule "<name>"]` section holding `ignore`/`update` while
the real entry goes without them, and the checkout lands in
`.git/modules/<path>` rather than `.git/modules/<name>`. Pass `--name` and the
whole problem disappears.

Backing that out takes `git submodule deinit -f <path>`, `git rm -f <path>`,
and `rm -rf .git/modules/<name>` — the bare name, not the path: with `--name`
passed the checkout never sat under a nested directory, so nothing deeper than
`.git/modules/<name>` needs removing (without it, look for the three-segment
`.git/modules/components/<component>/<name>` instead). Note `git rm` refuses
while `.gitmodules` has unstaged edits (`fatal: please stage your changes to
.gitmodules`), so restore that file first.

Do not gitignore or `git rm --cached` the gitlink — that breaks `update --init`.

`git submodule add` fails against a remote with no commits (`fatal: you are on a
branch yet to be born`), and leaves a stale `.git/modules/<name>` that blocks the
retry. Seed the remote with an initial commit first, and `rm -rf
.git/modules/<name>` if you hit it.

## The checkout in a project agent container

A project gets one container, and the project's own repository is cloned
directly at `/workspace` — not into a subdirectory beneath it. The clone lives
on the volume `qits_project_<projectId>`, which outlives the container, so
recreating the container does not re-clone.

That checkout is detached at the wrapper's newest released version — a
`YYYY.MMDD.HHMMSS` tag — and every submodule is detached at the gitlink that
release recorded. It is not on `main`, and no submodule is on `main`. That is
the point: the container reads the estate a person approved, not whatever
happens to be at the head of a branch.

It is kept current by a supervised child process, `qits checkout-daemon --path
/workspace`, which the projects daemon spawns and restarts (`CheckoutFollower`).
It subscribes to `SCMRelease` on qits-events and, when a new wrapper version
lands, fetches that tag, `git checkout --detach`es it and re-materialises the
submodules at the gitlinks the new release carries. It is the same stream
`qits events` prints — see "Reaching the platform with the `qits` CLI".

Three lags stack on top of one another, and all three bite quietly. The root
lags `main` by everything that has been merged but not yet released. A submodule
lags further: anything it released after the last wrapper release is not in the
gitlink yet, and work it has not released at all is not anywhere. And
`refs/remotes/origin/main` is itself stale, because the follower fetches
`refs/tags/<version>` and nothing else — so `git log origin/main` in this
container reports whatever main looked like whenever that ref was last written,
which may be weeks ago. Measured in this project's own container on 2026-09-19:
the checkout sat at `2026.919.40352`, released that morning, while
`origin/main` still pointed at a commit from nine days earlier. The ref is
older than the checkout, which is the opposite of what a remote-tracking branch
normally means. Fetch before you believe it.

The never-write rule: never edit, move or delete anything under `/workspace`,
and put new files somewhere else. The follower's precondition for moving the
checkout is that

    git status --porcelain --untracked-files=no --ignore-submodules=none

comes back empty. `--ignore-submodules=none` deliberately overrides this
repository's `.gitmodules` `ignore = all`, so a dirty submodule, or one sitting
off its recorded gitlink, counts as a local change like any other — as do an
edited tracked file and a staged one. Untracked files are excluded on purpose:
`git checkout --detach` never deletes one, so the guard has nothing to protect
there. That exclusion is recent (platform-access CLI `2026.919.80759`); a
container running an older one counts `??` entries too, and a single stranded
directory was enough to freeze its checkout for good. `/etc/qits-cli-version`
says which one you have.

When the tree is dirty the follower declines to move the checkout and says so
only in the projects daemon's log, which you cannot see from inside the
container. The symptom available to you is therefore no symptom at all: a
checkout that stops following releases, for exactly as long as the dirt remains.
Scratch work goes in `/tmp`.

## Seeing what is landing

Because the checkout is pinned to a release, reading what is about to land means
fetching it yourself. Git in this container has no credential helper configured
— `GIT_CONFIG_GLOBAL` and `QITS_GIT_AUTH_HOST` are both empty — so a bare fetch
dies before it reaches the network:

    fatal: could not read Username for 'http://githost.dev.internal:8080': No such device or address

The container does already carry the values the helper needs, under
`QITS_PROJECTS_DAEMON_*` names; derive the four the helper reads from them, then
fetch and open a worktree in `/tmp`:

    export GIT_CONFIG_GLOBAL=/etc/qits-gitconfig
    export QITS_GIT_AUTH_HOST="$(echo "$QITS_PROJECTS_DAEMON_GIT_BASE" | sed -E 's#^[a-z]+://##; s#/.*$##')"
    export QITS_GIT_AUTH_TOKEN_URL="$QITS_PROJECTS_DAEMON_AUTH_TOKEN_URL"
    export QITS_GIT_AUTH_AUDIENCE="$QITS_PROJECTS_DAEMON_GIT_AUTH_AUDIENCE"

    git -C /workspace fetch origin main
    git -C /workspace worktree add /tmp/upcoming origin/main
    # a submodule is a real clone of its own, so the same two commands work there:
    git -C /workspace/components/<component>/<repo> fetch origin main
    git -C /workspace/components/<component>/<repo> worktree add /tmp/upcoming-<repo> origin/main

    git -C /workspace worktree remove /tmp/upcoming

`/etc/qits-gitconfig` names the shell credential helper
`/usr/local/bin/qits-git-credential`, which mints a bearer from the commissioned
client credentials and answers for exactly one host — the one in
`QITS_GIT_AUTH_HOST`. That is why the value has to be a bare `host:port`, with no
scheme and no path: the helper compares it to what git asks about, and a `https://`
prefix or a trailing path makes every request go unanswered.

The fetch is also what repairs `origin/main`: it is the only thing that writes
that ref, so the first one after a long gap will report a jump of days rather
than of commits. A submodule needs its own fetch for the same reason.

A worktree rather than a second clone, because every submodule is already a real
clone under `/workspace/.git/modules/<name>`: the worktree reuses that object
store and fetches only the delta, where a fresh clone would pull the history
again over the same wire.

`/tmp`, and never a path under `/workspace`, because of the never-write rule. A
worktree directory inside the checkout is untracked, which a follower older than
`2026.919.80759` treats as a local change and stops on; and even on a current
one it sits in the way of the next release that wants to write that path. The
bookkeeping `git worktree add` leaves under `.git/worktrees/` is not itself a
problem — `status` reports nothing under `.git` — so it is the directory, not the
metadata, that has to live elsewhere. Remove the worktree when you are done, so
the bookkeeping does not accumulate across container recreations.

The export block is a workaround for the container not injecting those four
names directly; when it does, it goes away and only the `git fetch` and `git
worktree` lines remain.

## Reaching the platform with the `qits` CLI

`qits` is on `PATH` in every agent container and needs no sign-in. Both
`QITS_COMMISSIONED_CLIENT_ID` and `QITS_COMMISSIONED_CLIENT_SECRET` being set put
it in in-platform mode, where it mints a `client_credentials` bearer once per
process, holds it in memory and never writes it to disk. There is no `qits login`
to run in here, and the browser flows are refused outright. It also dials each
service by its wire alias itself, so none of the addressing needs composing by
hand.

The commands an agent reaches for:

    qits projects list
    qits repositories list --project qits
    qits ticket list | new | details | comment
    qits epic list | new | details | update
    qits release-request list | create | join | withdraw
    qits ci runs | run | retry
    qits events
    qits observe --filter ...

The credential is `qits:agent`. Every read door answers; an operator write comes
back, verbatim, as `403 - this credential is qits:agent, which reads but does not
write`. That is the credential doing its job, not a misconfiguration to escalate
or work around. Filing a ticket, commenting on one and `qits ci retry` are all
writes and will answer 403 — a change that matters goes through a release
request, or through a person.

`qits events` is how you watch the platform, and it is the same stream the
checkout follower rides, so what you see there is what will move `/workspace` a
few minutes later — see "The checkout in a project agent container".

`qits observe` works on this credential even though its own generated help text
still claims it needs `qits:admin`: qits-observability grants agents read access
deliberately, and the help string simply has not caught up. Believe the door, not
the help.

`/etc/qits-cli-version` holds a single line, `qits=<version>`, and is the cheap
way to answer which CLI this image actually carries. `qits --version` prints
nothing, because the CLI ships no version provider.

`qits help skill` prints the whole surface as a SKILL.md, and is worth reading
once. Do not install it: in a project agent container `HOME=/workspace`, so
writing it under `~/.claude/skills/` dirties the checkout and trips the
never-write rule, and `CLAUDE_CONFIG_DIR` points at a volume every container on
the estate shares.

One caveat on git. Do not configure git through the CLI: `qits git-credential`
does work in-platform now, but `/etc/qits-gitconfig` names the separate shell
helper `/usr/local/bin/qits-git-credential`, and that is what git actually runs.
