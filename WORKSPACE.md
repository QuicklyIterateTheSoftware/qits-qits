# Workspace development flow

This checkout is an aggregate workspace. The wrapper and every checked-out submodule use the same workspace branch. Commit and push changes in the repository where they belong; the workspace credential has normal Git push access so each repository can move independently.

A local commit is not automatically part of the running environment. Changes have to be orchestrated by **releasing** them: shared libraries are released into `main`, while applications and services are released into the environment branch that runs them (for example `environment/dev`).

Release dependencies before their consumers, then let the affected application or service release carry the new versions into the environment. Keep the wrapper branch as the map of the workspace, but treat each submodule's own release as the unit that promotes code.
