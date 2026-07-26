# qits-qits

Home repository aggregating the application's submodules.

## Submodules

Every submodule sits on its own `main` and follows it. Syncing is automated, so
in normal work you never run a submodule command by hand.

The gitlinks committed here are not version pins — they exist so
`git submodule update --init` works on a fresh clone, and they are expected to
lag behind the branches. Each entry in `.gitmodules` carries:

    ignore = all      # keep the expected drift out of `git status` / `git diff`
    branch = main     # what `--remote` follows
    update = merge    # merge the branch instead of detaching at a commit

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

### Adding a submodule

    git submodule add <url> <path>
    git config -f .gitmodules submodule.<name>.ignore all
    git config -f .gitmodules submodule.<name>.update merge
    git submodule set-branch --branch main <path>
    git add .gitmodules <path> && git commit

Do not gitignore or `git rm --cached` the gitlink — that breaks `update --init`.

`git submodule add` fails against a remote with no commits (`fatal: you are on a
branch yet to be born`), and leaves a stale `.git/modules/<name>` that blocks the
retry. Seed the remote with an initial commit first, and `rm -rf
.git/modules/<name>` if you hit it.
