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

Every submodule sits on its own `main` and follows it. Syncing is automated, so
in normal work you never run a submodule command by hand.

The gitlinks committed here are not version pins — they exist so
`git submodule update --init` works on a fresh clone, and they are expected to
lag behind the branches. Each entry in `.gitmodules` carries:

    url = ../<name>.git   # relative, never an absolute URL
    ignore = all          # keep the expected drift out of `git status` / `git diff`
    branch = main         # what `--remote` follows
    update = merge        # merge the branch instead of detaching at a commit

The URL is relative to this repository's own origin, so the same `.gitmodules`
resolves the siblings on GitHub and on the platform git host.

### Fresh clone

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
