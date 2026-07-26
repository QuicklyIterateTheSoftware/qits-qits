# qits-qits

Home repository aggregating the application's submodules.

## Submodules

Add a submodule with `git submodule add <url>`, then set `ignore = all` and
`branch = main` for it and commit the tracked gitlink plus `.gitmodules`:

    git config -f .gitmodules submodule.<name>.ignore all
    git submodule set-branch --branch main <path>

This keeps `git submodule update --init` working on a fresh clone while
suppressing drift in `git status`, so nobody feels the need to bump the pinned
pointers. Do not gitignore or `git rm --cached` the gitlink — that breaks
`update --init`.

Track the tip of each submodule's `main` without recording the movement:

    git submodule update --remote --merge          # pull latest main into every submodule
    git update-index --skip-worktree <path>        # per clone: stop `git add -A` bumping the pin

`ignore = all` only hides drift from `git status` and `git diff` — it does *not*
stop `git add -A` or `git commit -a` from staging a moved gitlink, and it hides
the bump once staged. `skip-worktree` is what actually pins it. It lives in
`.git/index`, not `.gitmodules`, so every clone sets it once:

    git config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}' \
      | xargs git update-index --skip-worktree

To bump a pin on purpose, clear the flag, commit the gitlink, then set it again:

    git update-index --no-skip-worktree <path> && git add <path>
    git commit -m "Bump <name>" && git update-index --skip-worktree <path>

Avoid `git pull --recurse-submodules` and `submodule.recurse = true`: they check
out the *pinned* commit and will drag submodules back off `main`.
