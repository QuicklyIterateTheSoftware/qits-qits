# qits-qits

Home repository aggregating the application's submodules.

## Submodules

Add a submodule with `git submodule add <url>`, then set `ignore = all` for it
(`git config -f .gitmodules submodule.<name>.ignore all`) and commit the tracked
gitlink plus `.gitmodules`. This keeps `git submodule update --init` working on a
fresh clone while suppressing drift in `git status`, so nobody feels the need to
bump the pinned pointers. Do not gitignore or `git rm --cached` the gitlink — that
breaks `update --init`.
