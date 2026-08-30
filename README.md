# qits-qits

QuicklyIterateTheSoftware (qits) is a self-hosting PaaS. It deploys
applications across environments and automates routine updates.

The platform is built around agentic code editing. It follows Spec Driven
Design with one twist: the code is the spec. The platform only works when
the code is written like one.

Using this approach will most likely not work with brownfield projects.

Set `QITS_DOMAIN` at bootstrap to serve a real domain: qits-platform-dns
becomes its authoritative nameserver and the edge gets HTTPS with a Let's
Encrypt certificate slot. See the qits-bootstrap-cli README for the knobs
and the issuance step.

## Credentials on a development host

Every request through the edge — maven, npm, docker, git, plain curl —
authenticates, reads included. Your personal credential is a client the
idp commissions for this machine: run the one-liner the bootstrap report
prints (a `POST /idp/api/clients` from a container on qits-net,
authorized by the `dev-qits-artifacts` client whose secret is in
`.qits-bootstrap.env`). The answer's `clientId` and `secret` are the
pair; keep them in `~/.qits-workstation-client` and
`~/.qits-workstation-secret`.

The pair is wired in three places, and all three must carry the same
one: `~/.npmrc` with a per-registry `_auth` line (base64 of
`client:secret`) for each of the two npm vhosts, `~/.m2/settings.xml`
with a `<server>` entry whose id matches the `qits-maven-host` mirror,
and `docker login` against the registry and mirror vhosts. Project
`.npmrc` files and poms only pick addresses; the answer to their 401s
always comes from these host-level files.

The rows do not survive a re-bootstrap. When every registry suddenly
answers 401, nothing is broken: commission a fresh client and rewrite
the three consumers. Hand the credential back when the machine is
retired: `DELETE /idp/api/clients/<clientId>`.

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
`.config/qits/`. Example from `qits-deployments-platform-frontend`, reacting to a new
`@qits/ui-components` release:

```yaml
# .config/qits/ci-event-upstream-ui-components.yml
event: SoftwareRelease
when:
  - repository: { exact: qits-ui-components-jslib }
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

