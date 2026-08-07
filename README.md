# qits-qits

QuicklyIterateTheSoftware (qits) is a self-hosting PaaS. It deploys
applications across environments and automates routine updates.

The platform is built around agentic code editing. It follows Spec Driven
Design with one twist: the code is the spec. The platform only works when
the code is written like one.

Using this approach will most likely not work with brownfield projects.

## Branching model

Deploy branches come in two archetypes:

- `environment/*` — represents what is deployed to that environment. Every
  service repository that deploys to an environment must have the branch
  for it.
- `platform/*` — for services deployed outside the environments, the
  platform singletons. The conventional branch is `platform/main`.

`main` is the final destination of the code. A commit should only reach
`main` once it is fully deployed, meaning all tests passed. This is not
enforced yet.

A merge into a deploy branch triggers an SCMRelease event. That runs the
publish pipeline, which emits a SoftwareRelease event. That event
triggers the deployment.

`maintenance/*` branches are opened automatically. When an upstream
publishes a SoftwareRelease, a pipeline in each dependent bumps the
version pin, commits, and pushes the branch. The pipelines live in
`.config/qits/`. Example from `qits-platform-spa-deployments`, reacting to a new
`@qits/ui-components` release:

```yaml
# .config/qits/ci-event-upstream-ui-components.yml
event: SoftwareRelease
when:
  - repository: { exact: qits-spa-ui-components }
    packageType: { exact: npm }
    packageName: { exact: "@qits/ui-components" }
steps:
  - image: qits/build-images/node-base:latest
    script: |
      npm install "@qits/ui-components@^$version"
      git commit -m "bump(@qits/ui-components@$version)"
      git push --force "$QITS_CI_REPOSITORY_URL" "HEAD:refs/heads/maintenance/$upstream"
```

## How code is iterated

Everything starts with a feature idea. The idea is fleshed out into an
epic. Once the epic is refined, the whole stack branches to
`epic/<epic-slug>` — all submodule repositories included. Everything
done for the epic lives under the `epic/*` prefix.

That branch is the basis for the coding harness's workspace. The
workspace can open sub-branches like `epic/<epic-slug>/<task-slug>`
when it needs to, but that is an edge case.

When the changes are ready for a first deployment, they merge into the
first environment. The rest of the loop is planned but not implemented
yet:

- The merge runs that environment's integration tests.
- The epic is notified of the result.
- On success, the epic is available for the next environment.
- On failure, the ball goes back to the coordinating workspace to
  resolve the error.

