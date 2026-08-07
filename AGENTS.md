# qits-qits

Home repository aggregating the application's submodules.

## Layout

Submodules are grouped by the role a module plays, not by its technology:

    services/      deployable backend services
    daemons/       long-running background agents
    libs/          shared code consumed by other modules
    frontends/     anything served to a user at a URL
    cli/           command-line tools
    images/        build definitions for published platform OCI images

These six directories are the whole set. Framework-specific glue —
`qits-integrations-angular`, `qits-integrations-quarkus` — is shared code, so it
lives in `libs/` like any other lib.

Role-named directories outlive the tech inside them: an entry that stops being
a SPA and becomes server-rendered still belongs in `frontends/`, so nothing has
to move. The repository name stays free to be specific about shape where that
helps — `frontends/qits-spa-home` is a fine pairing, and so would be
`frontends/qits-ssr-docs` beside it.

`frontends/` holds one entry per thing served at a URL. Shared frontend code —
component libraries and the like — is a lib, which is what keeps the category
from collecting anything merely written in JavaScript.

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

    git submodule add --name <name> ../<name>.git <dir>/<name>
    git config -f .gitmodules submodule.<name>.ignore all
    git config -f .gitmodules submodule.<name>.update merge
    git submodule set-branch --branch main <dir>/<name>
    git add .gitmodules <dir>/<name> && git commit

`--name` is not optional. Modern git (seen on 2.53) defaults the submodule
*name* to the full path, so adding at `frontends/qits-spa-home` names the entry
`frontends/qits-spa-home`, while every entry here uses the bare repository
name. The mismatch is quiet and costly: the `git config` lines above then write
a *second*, orphan `[submodule "<name>"]` section holding `ignore`/`update`
while the real entry goes without them, and the checkout lands in
`.git/modules/<path>` rather than `.git/modules/<name>`. Pass `--name` and the
whole problem disappears.

Backing that out takes `git submodule deinit -f <path>`, `git rm -f <path>`,
and `rm -rf .git/modules/<dir>`. Note `git rm` refuses while `.gitmodules` has
unstaged edits (`fatal: please stage your changes to .gitmodules`), so restore
that file first.

Do not gitignore or `git rm --cached` the gitlink — that breaks `update --init`.

`git submodule add` fails against a remote with no commits (`fatal: you are on a
branch yet to be born`), and leaves a stale `.git/modules/<name>` that blocks the
retry. Seed the remote with an initial commit first, and `rm -rf
.git/modules/<name>` if you hit it.
