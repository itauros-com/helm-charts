# helm-charts

Shared Helm charts for itauros workloads. Argo CD consumes them straight from
this repository, pinned to a release tag.

| Chart | Description |
|---|---|
| [microservice](charts/microservice) | Stateless single-container workload (HTTP API or worker) |

Workload repositories keep only their values files and pin a chart tag.
Version bumps are proposed by Renovate, never picked up automatically.

## Layout

```
charts/<name>/
  Chart.yaml           version written on release, don't edit it
  CHANGELOG.md         written on release
  values.yaml
  values.schema.json
  templates/
  tests/               helm-unittest suites
  ci/*-values.yaml     example values, linted and validated in CI
```

## Tooling

Tools are pinned in [`mise.toml`](mise.toml), locally and in CI:

```bash
mise install
helm plugin install https://github.com/helm-unittest/helm-unittest.git --verify=false
```

## Releases

Versions come from [conventional commits](https://www.conventionalcommits.org/),
computed by [Cocogitto](https://docs.cocogitto.io) ([`cog.toml`](cog.toml)).
Every push to `main` bumps each chart touched by releasable commits since its
last tag, writes `version` in its `Chart.yaml` and its `CHANGELOG.md`, and
pushes one `chore(version)` commit plus one `<chart>-<version>` tag per chart.

| Commit | Bump |
|---|---|
| `fix:`, `refactor:`, `perf:`, `build:` | patch |
| `feat:` | minor |
| `feat!:` / `BREAKING CHANGE:` footer | major (minor while the chart is `0.x`) |
| `docs:`, `ci:`, `chore:`, `test:`, ... | none |

A chart is bumped only by commits touching its directory: use the chart name
as scope (`fix(microservice): ...`) to keep the changelog readable.

CI checks every commit of a pull request and its title (`cog check`,
`cog verify`): with squash merge the title becomes the commit message on
`main`.

### Repository settings

- **Tag ruleset**: block update and deletion of `*-*.*.*` tags. Argo CD
  Applications pin them, so a moved tag would silently change what is deployed.
- **`main` protection**: the release workflow pushes the bump commit and tags
  with `GITHUB_TOKEN`; if `main` requires pull requests, add GitHub Actions to
  the bypass list.
- **Squash merge** (recommended), so each pull request is one commit whose
  message CI has validated.

### Bootstrap

Cocogitto bumps from the latest `<chart>-<version>` tag. For a new chart,
create its first tag by hand on the commit that adds it:

```bash
git tag microservice-0.1.0 && git push origin microservice-0.1.0
```

## CI

- **Pull requests** (`ci.yaml`): conventional commits and title,
  `helm lint --strict` and kubeconform on every `ci/*-values.yaml`,
  `helm unittest`.
- **Push to `main`** (`release.yaml`): `cog bump --auto`, then push of the
  bump commit and the new tags.
