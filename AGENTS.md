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
in it is on a branch, and none of the commands below belong there. See "The
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

A clone you made yourself, and only that. Never run any of these five lines in a
project agent container: every one of them writes `/workspace`, which freezes the
checkout follower — see the never-write rule in "The checkout in a project agent
container".

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

Everything in this section applies to that container and not to a workspace
container, where the whole point is to write, so establish which one you are in
before acting on any of it:

    git -C /workspace status -sb   # `## HEAD (no branch)` → a project agent container
    pgrep -a -x qits               # `qits checkout-daemon --path /workspace` → the same

A workspace container answers with a branch name and no follower, and the
`## Submodules` section above is the one that applies there. Match the process
name exactly, as above: `pgrep -af 'qits checkout-daemon'` also matches the
shell you typed it in, which reads as a running follower when there is none.

That checkout is detached at the wrapper's newest released version — a
`YYYY.MMDD.HHMMSS` tag — and every submodule is detached at the gitlink that
release recorded. What is invariant is that nothing there is on a *branch* —
HEAD is detached at a released tag, and so is every submodule's. That is the
point: the container reads the estate a person approved, not whatever happens
to be at the head of a branch.

Detached is not the same as behind: right after a release the tag *is* main's
head (measured, `git rev-parse HEAD` equalling `git rev-parse origin/main` at
`2026.919.120127`), and the lag grows from zero as main moves on until the next
release collapses it again.

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
the wrapper's own `refs/remotes/origin/main` is itself stale, because what the
follower fetches here is `refs/tags/<version>` — so `git log origin/main` in
this container reports whatever main looked like whenever that ref was last
written, which may be weeks ago. A submodule's remote-tracking refs are the
opposite case and much fresher: materialising the submodules fetches with
`--recurse-submodules-default on-demand`, so each submodule's `origin/*` is
refreshed roughly every time the follower moves, even on days the wrapper's own
`origin/main` never budges. Measured in this project's own container on
2026-09-19: the checkout sat at `2026.919.40352`, released that morning, while
`origin/main` still pointed at a commit from nine days earlier. The ref is
older than the checkout, which is the opposite of what a remote-tracking branch
normally means. Fetch before you believe it.

The never-write rule: never edit, move or delete anything under `/workspace`,
and put new files somewhere else. The follower's precondition for moving the
checkout is that a `git status` comes back empty, and *which* status it runs
depends on the version of the platform-access CLI — the same artifact as the
`qits` CLI on `PATH`, so `/etc/qits-cli-version` answers the question — with
`2026.919.80759` as the cutover:

    # 2026.919.80759 and newer
    git status --porcelain --untracked-files=no --ignore-submodules=none

    # older
    git status --porcelain --ignore-submodules=none

Run the one that matches your version. `/etc/qits-cli-version` reports the CLI
baked into the image, which is not necessarily the binary the running follower
executes; where that distinction matters, read `/proc/<pid>/exe` for the `qits
checkout-daemon` process. `--ignore-submodules=none` deliberately overrides this
repository's `.gitmodules` `ignore = all`, so a dirty submodule, or one sitting
off its recorded gitlink, counts as a local change like any other — as do an
edited tracked file and a staged one. Untracked files are excluded from the
newer guard on purpose: the move itself is a `git checkout --detach`, which
never deletes one, so there is nothing there to protect. The follower also
re-materialises submodules, though, and a directory already occupying a
submodule path can block that — so a stray untracked directory is not
*dangerous* to your work, it is merely in the way, which is why it is worth
removing when it sits on a submodule path and harmless otherwise. On an older
follower it is worse than in the way: a `??` entry counts, and a single stranded
directory was enough to freeze a checkout for good.

When the tree is dirty the follower declines to move the checkout and says so
only in the projects daemon's log, which you cannot see from inside the
container. The symptom available to you is therefore no symptom at all: a
checkout that stops following releases, for exactly as long as the dirt remains.
Scratch work goes in `/tmp`.

If you have landed on such a checkout — which is the likeliest reason to be
reading this — confirm it by running the guard command for your CLI version and
reading what it names. If it names nothing, nothing is wrong: on
`2026.919.80759` or newer the guard can never name an untracked path, so a
stranded `??` directory sitting in the tree is freezing precisely nothing and
you are not stuck. Leave it alone, and do not perform a write to fix a problem
you do not have; `git describe` will confirm the follower is current. Removing
such a directory is the right move only on an older follower, where the `??`
entry does count, or when it occupies a submodule path the follower needs to
materialise. `grep <path> .gitmodules` settles which it is, and it is the whole
test: absent means the estate no longer declares that path, so nothing will ever
be materialised there and it blocks nothing; present means it is a live
submodule path and an occupying directory can stop the follower dead. The one
stranded directory on this estate today,
`components/qits-artifacts/qits-artifacts-cli/`, is the absent case — a retired
submodule's leftovers, declared neither at the release nor on `main`. Weigh the
deletion rather than reaching for it: such a directory is not empty scaffolding
but a real checkout with its own object store and history under
`/workspace/.git/modules/<name>`, so removing it throws that away and is worth
doing only when it is genuinely in the way or you are on a follower that counts
it. In those cases it is the one deletion under `/workspace` that is correct —
remove it and the follower moves again on the next release — and not a breach of
the never-write rule, which exists to protect tracked work. Tracked dirt is the
opposite case: a modified or staged file is somebody's unfinished work, so
report it and let a person decide — never `git reset`, `git checkout --` or
`git stash` it away. The underlying cause, untracked paths counting at all, is
fixed from `2026.919.80759` on, so this is a condition that ages out of
the estate rather than one to live with.

One consequence for this page itself: the copy you are reading in a project
agent container came with the checkout, so it is the released snapshot and by
definition older than `main` — including this very section. The current text is
on `main`, and the fetch-and-worktree recipe below is how you read it. The
section that tells you how to see what is landing is itself only visible once it
has landed.

## Seeing what is landing

Because the checkout is pinned to a release, reading what is about to land means
fetching it yourself — and git in this container is already configured to do it.
`GIT_CONFIG_GLOBAL=/etc/qits-gitconfig` and the three `QITS_GIT_AUTH_*` names its
credential helper reads are injected at container creation, so `git fetch` and
`git worktree` just work, with no exports and no preparation:

    git -C /workspace fetch origin main
    git -C /workspace worktree add /tmp/upcoming origin/main

    # the wrapper at a ticket branch — the commonest reason to open one. Fetch
    # into a ref of your own and name that ref, rather than FETCH_HEAD
    git -C /workspace fetch origin ticket/<slug>:refs/upcoming/<slug>
    git -C /workspace worktree add /tmp/upcoming-wrapper refs/upcoming/<slug>

    # a submodule is a clone of its own: fetch and open the worktree in it
    git -C /workspace/components/<component>/<repo> fetch origin main
    git -C /workspace/components/<component>/<repo> worktree add /tmp/upcoming-<repo> origin/main

    # a submodule at a ticket branch, the same way
    git -C /workspace/components/<component>/<repo> fetch origin ticket/<slug>:refs/upcoming/<slug>
    git -C /workspace/components/<component>/<repo> worktree add /tmp/upcoming-<repo> refs/upcoming/<slug>

    # remove each worktree through the repository that created it
    git -C /workspace worktree remove /tmp/upcoming
    git -C /workspace/components/<component>/<repo> worktree remove /tmp/upcoming-<repo>

A named branch is the usual question, not `main`. Give the fetch a refspec that
writes a ref of your own and hang the worktree on that: `FETCH_HEAD` is the quick
way and works, but it is a single slot that the *next* fetch in that repository
overwrites, so an unrelated `git fetch --tags` mid-session silently moves a
worktree's idea of the branch to something weeks older. Use `FETCH_HEAD` only
immediately after the fetch that wrote it. Such a fetch may also recurse into the
submodules and move their remote-tracking refs — harmless here, and it leaves no
working-tree change, but it is not the no-op the command reads as.

A worktree of the *wrapper* is not a view of the estate. `git worktree add` on
`/workspace` gives you `components/` as a field of empty directories: the
gitlinks are in the tree, nothing is materialised behind them, and `ls -A` on any
submodule path there returns nothing at all. So reading a submodule's upcoming
code means making the worktree in that submodule's own clone, as the block above
does, not in a wrapper worktree. The reflex to run `git submodule update --init`
inside the wrapper worktree is the wrong one: it would pull every submodule down
again over the network to answer a question about one of them.

`/etc/qits-gitconfig` names the shell credential helper
`/usr/local/bin/qits-git-credential`, which mints a bearer from the commissioned
client credentials and answers for exactly one host — the one in
`QITS_GIT_AUTH_HOST`. That is why the value has to be a bare `host:port`, with no
scheme and no path: the helper compares it to what git asks about, and a `https://`
prefix or a trailing path makes every request go unanswered.

Fallback, for a container created before those names were injected: if a fetch
dies with `fatal: could not read Username for 'http://githost.dev.internal:8080'`
they are simply absent on a container that old, and you can derive them from the
`QITS_PROJECTS_DAEMON_*` names the container still carries:

    export GIT_CONFIG_GLOBAL=/etc/qits-gitconfig
    export QITS_GIT_AUTH_HOST="$(echo "$QITS_PROJECTS_DAEMON_GIT_BASE" | sed -E 's#^[a-z]+://##; s#/.*$##')"
    export QITS_GIT_AUTH_TOKEN_URL="$QITS_PROJECTS_DAEMON_AUTH_TOKEN_URL"
    export QITS_GIT_AUTH_AUDIENCE="$QITS_PROJECTS_DAEMON_GIT_AUTH_AUDIENCE"

The `sed` is what strips `QITS_PROJECTS_DAEMON_GIT_BASE` down to the bare
`host:port` the helper insists on.

The fetch is also what repairs the wrapper's `origin/main`: nothing else here
writes that ref, so the first one after a long gap will report a jump of days
rather than of commits. Fetch in a submodule too — not because its refs are as
stale, they are usually days fresher, but because you cannot tell by looking
and the fetch costs a delta.

A worktree rather than a second clone, because every submodule is already a real
clone under `/workspace/.git/modules/<name>`: the worktree reuses that object
store and fetches only the delta, where a fresh clone would pull the history
again over the same wire.

`/tmp`, and never a path under `/workspace`, because of the never-write rule. A
worktree directory inside the checkout is untracked, which a follower older than
`2026.919.80759` treats as a local change and stops on; a current one will not
stop on it, but if it lands on a submodule path it still occupies a directory
the follower has to materialise. The bookkeeping `git worktree add` leaves under
`.git/worktrees/` is not itself a problem — `status` reports nothing under `.git`
— so it is the directory, not the metadata, that has to live elsewhere. Remove
the worktree when you are done, so the bookkeeping does not accumulate: it lives
on the `qits_project_*` volume and outlives every container recreation. Remove it
through the repository that made it, as the block above does; asking the wrapper
to remove a submodule's worktree answers `fatal: '/tmp/upcoming-<repo>' is not a
working tree` (exit 128). Do not answer that with `rm -rf` — the directory goes
and the metadata stays for good; if you already have, `git -C <the right repo>
worktree prune` is what clears it.

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
    qits events                     # open stream, never returns — bound it
    qits observe --filter ...       # the --filter is required

The credential is `qits:agent`. Every read door answers; an operator write comes
back, verbatim, as `403 - this credential is qits:agent, which reads but does not
write`. That is the credential doing its job, not a misconfiguration to escalate
or work around. Filing a ticket, commenting on one and `qits ci retry` are all
writes and will answer 403 — a change that matters goes through a release
request, or through a person.

`qits events` is how you watch the platform, and it is the same stream the
checkout follower rides, so what you see there is what will move `/workspace` a
few minutes later — see "The checkout in a project agent container". It is an
open stream with no replay: it prints what arrives from the moment you start it
and never returns, so run it non-interactively and you hang until something
kills you. Bound it whenever the question is merely whether something arrived —
`timeout 30 qits events`, or put it in the background and read its output.

Believe the door, not the help. `qits ci runs` answers perfectly well on this
credential, while the `qits ci` group's own help (`qits ci --help`, not `qits ci
runs --help`, which names no role at all) and the `qits ci` section of `qits help
skill` both say reading runs needs `qits:admin` or `qits:system` — roles this
credential does not hold. All of the help is hand-written prose that the surface
moved out from under, roles and subcommands alike — `qits --help` still
describes `epic` as list/new/details and omits `update`, which exists — so the
403 you get or do not get, and the command you actually run, are the truth.
`qits observe` likewise works here, though not bare: it exits 2 with `Missing
required option: '--filter=<conditions>'` until you give it one.

`/etc/qits-cli-version` holds a single line, `qits=<version>`, and is the cheap
way to answer which CLI this image actually carries. Every command advertises
`-V, --version  Print version information and exit`, but the CLI ships no version
provider, so `-V` prints nothing and exits 0 — do not spend a command on it.

`qits help skill` prints the whole surface as a SKILL.md, and is worth reading
once. Do not install it: in a project agent container `HOME=/claude-home` and
`CLAUDE_CONFIG_DIR=/claude-home/.claude`, which is a mounted volume
(`QITS_PROJECTS_DAEMON_CLAUDE_MOUNT`) that every container on the estate shares,
so writing under `~/.claude/skills/` installs it into every other project's
agent as well as your own.

One caveat on git. Do not configure git through the CLI: `qits git-credential`
does work in-platform now, but `/etc/qits-gitconfig` names the separate shell
helper `/usr/local/bin/qits-git-credential`, and that is what git actually runs.
