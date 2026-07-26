# qits-qits

Home repository aggregating the application's submodules.

## Submodules

Every submodule tracks the tip of its own `main`. The pinned gitlinks in this
repo are deliberately left stale — they exist so `git submodule update --init`
works on a fresh clone, not as version pins, and nobody should be bumping them
in day-to-day work.

### Fresh clone

    git submodule update --init
    git submodule foreach -q 'git switch -q main'
    git submodule update --remote --merge
    git config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}' \
      | xargs git update-index --skip-worktree

The `foreach ... switch main` step matters: `update --init` checks out a
*detached* HEAD at the pinned commit, and `--remote --merge` on a detached HEAD
lands you at the right commit but still detached, so any work you commit inside
a submodule ends up off-branch. Switching first gives each submodule a local
`main` tracking `origin/main`, and later `--remote --merge` runs fast-forward on
that branch.

The `skip-worktree` pass is per clone — it lives in `.git/index`, not
`.gitmodules` — so repeat it after every fresh clone.

### Staying current

    git submodule update --remote --merge

Use `--merge` (or `--rebase`). Bare `--remote` re-detaches HEAD.

Avoid `git pull --recurse-submodules` and `submodule.recurse = true`: they check
out the *pinned* commit and will drag submodules back off `main`.

### Why both `ignore = all` and `skip-worktree`

`ignore = all` only hides drift from `git status` and `git diff`. It does *not*
stop `git add -A` or `git commit -a` from staging a moved gitlink — and once
staged, it hides the bump from `git diff --cached` too, so a pointer bump can
ride along in an unrelated commit unnoticed. `skip-worktree` is what actually
freezes the pin; `ignore = all` just keeps the drift out of your face.

### Adding a submodule

    git submodule add <url> <path>
    git config -f .gitmodules submodule.<name>.ignore all
    git submodule set-branch --branch main <path>
    git add .gitmodules <path> && git commit
    git update-index --skip-worktree <path>

Do not gitignore or `git rm --cached` the gitlink — that breaks `update --init`.

`git submodule add` fails against a remote with no commits (`fatal: you are on a
branch yet to be born`), and leaves a stale `.git/modules/<name>` that blocks the
retry. Seed the remote with an initial commit first, and `rm -rf
.git/modules/<name>` if you hit it.

### Bumping a pin on purpose

    git update-index --no-skip-worktree <path> && git add <path>
    git commit -m "Bump <name>" && git update-index --skip-worktree <path>
