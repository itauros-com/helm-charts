# microservice

Shared Helm chart for stateless, single-container workloads: HTTP APIs and
background workers (e.g. Temporal). Workloads don't vendor a chart: they keep
only their values files and reference this chart from Git, pinned to a
release tag.

Defaults are hardened and opinionated, so a typical workload sets little
more than image, env and the occasional toggle:

- non-root uid/gid 65532, read-only root filesystem, all capabilities dropped,
  `RuntimeDefault` seccomp
- container port `8080` named `http`, Service on port `80`
- startup + liveness on `/healthz`, readiness on `/readyz`
- dedicated ServiceAccount with token automount off (EKS Pod Identity friendly)

Workloads that don't fit (stateful, multi-container by design, heavy custom
RBAC, e.g. Backstage) keep their own chart.

## Usage

Releases are Git tags named `microservice-<version>`. To render locally:

```bash
git -C helm-charts checkout microservice-0.1.0
helm template orders helm-charts/charts/microservice -f values.yaml -f values.dev.yaml
```

Minimal values for an API:

```yaml
image:
  repository: registry.example.com/orders-api
  tag: v1.0.0
partOf: shop
args: ["serve"]
env:
  ORDERS_LOG_LEVEL: info
extraEnvFrom:
  - secretRef:
      name: orders-db-credentials
```

Worker (no Service, no HTTP probes):

```yaml
image:
  repository: registry.example.com/orders-worker
  tag: v0.4.0
component: worker
args: ["worker"]
containerPort: null
service:
  enabled: false
probes:
  liveness: { enabled: false }
  readiness: { enabled: false }
  startup: { enabled: false }
terminationGracePeriodSeconds: 120
```

See [`values.yaml`](values.yaml) for every option and
[`ci/`](ci/) for complete examples. `values.schema.json` rejects unknown keys,
so a typo fails the render instead of being silently ignored.

### Argo CD

Use a multi-source Application: the chart comes from the charts repository at
a release tag, the values from the workload repository. Both are plain Git
sources, so the repository credentials Argo CD already uses (including GitHub
App credentials) apply.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: orders-api
  namespace: argocd
spec:
  project: shop
  destination:
    server: https://kubernetes.default.svc
    namespace: shop
  sources:
    - repoURL: https://git.example.com/platform/helm-charts.git
      path: charts/microservice
      targetRevision: microservice-0.1.0   # a release tag, never a branch
      helm:
        releaseName: orders
        valueFiles:
          - $values/deploy/helm/values.yaml
          - $values/deploy/helm/values.dev.yaml
    - repoURL: https://git.example.com/shop/orders-api.git
      targetRevision: main
      ref: values
```

Never point `targetRevision` at a branch: every merge in the charts
repository would roll out to every workload on the next sync. To try an
unreleased chart change, point a dev Application at the PR branch
temporarily, then back to a tag.

To get chart bumps as pull requests in the workload repository, Renovate's
Argo CD manager needs the tag prefix stripped:

```json
{
  "packageRules": [
    {
      "matchDatasources": ["git-tags"],
      "matchPackageNames": ["https://git.example.com/platform/helm-charts.git"],
      "extractVersion": "^microservice-(?<version>.+)$"
    }
  ]
}
```

## Naming

Names default to the **release name**, not the chart name: with release
`orders` you get Deployment, Service and ServiceAccount `orders`.
`nameOverride` sets the workload name (labels, container name) and
`fullnameOverride` the resource names.

The `app.kubernetes.io/name` label is part of the Deployment selector, which
Kubernetes does not allow to change. When migrating a workload from its own
chart, set `nameOverride` to the old chart name so the selector stays the same.

## Image version

There is no `appVersion` to fall back to: `image.tag` (or `image.digest`) is
required and also drives the `app.kubernetes.io/version` label. Release
tooling that used to bump `appVersion` in the workload's `Chart.yaml` should
bump `image.tag` in its values instead, e.g. with semantic-release:

```json
["@semantic-release/exec", {
  "prepareCmd": "yq -i '.image.tag = \"v${nextRelease.version}\"' deploy/helm/values.yaml"
}]
```

## Configuration

| Key | Renders | Use for |
|---|---|---|
| `env` | `env` | plain values (map), sorted by name |
| `extraEnv` | `env` | single variables from a Secret/ConfigMap key (`secretKeyRef`, `configMapKeyRef`), `fieldRef`, `resourceFieldRef` |
| `extraEnvFrom` | `envFrom` | every key of a Secret/ConfigMap as a variable (`secretRef`, `configMapRef`, optional `prefix`) |

```yaml
env:
  ORDERS_LOG_LEVEL: info
extraEnv:
  - name: STRIPE_API_KEY            # one key, any name
    valueFrom:
      secretKeyRef:
        name: stripe
        key: api-key
extraEnvFrom:
  - secretRef:                      # all keys, already named as env vars
      name: orders-db-credentials
```

`extraEnvFrom` fits Secrets made for the workload, whose keys already are the
env var names; `extraEnv` fits Secrets you don't own (e.g. generated by a DB
operator) whose keys need renaming. Note that `envFrom` is implicit: a key
with the wrong name is silently not used.

The chart never creates Secrets: manage them outside (SealedSecrets, External
Secrets, ...). To roll pods when a Secret changes, use Reloader or your
operator's reload mechanism.

Kubernetes gives `env` precedence over `envFrom`: don't set in `env` a
variable meant to come from a Secret, or the literal shadows it.

## Escape hatches

Before forking the chart, check whether one of these covers the case:

- `probes.<name>.spec`: replace a probe body verbatim (exec, grpc, tcpSocket)
- `command`, `args`, `lifecycle`, `strategy`, `terminationGracePeriodSeconds`
- `extraPorts`, `volumes`, `volumeMounts`
- `initContainers`, `extraContainers` (rendered through `tpl`)
- `extraObjects`: any additional manifest, as a map or YAML string, rendered
  through `tpl`

If the same escape hatch shows up in several workloads, promote it to a
first-class value in the chart.

## Recipes

Jobs and CronJobs are not chart values: declare them in `extraObjects`,
starting from these recipes. Both are kept verbatim in
[`ci/recipes-values.yaml`](ci/recipes-values.yaml), so CI lints and tests
them on every chart change.

### Stable helpers

Recipes may rely on these named templates. They are part of the chart's
public interface: renaming or changing them is a breaking change.

| Helper | Renders |
|---|---|
| `microservice.fullname` | resource name prefix |
| `microservice.labels` | standard labels for `metadata.labels` (not for pod templates, see below) |
| `microservice.image` | image reference of the main container |
| `microservice.serviceAccountName` | the chart's ServiceAccount |
| `microservice.containerEnv` | `env` + `envFrom` blocks, exactly as on the main container |

### Indentation

Inside a `|` block YAML strips the common indentation, so `nindent` counts
from the snippet's left margin (`apiVersion` at column 0), **not** from the
values file. A wrong count usually shows up as `did not find expected key`.

### Pod labels

Don't put `microservice.labels` or `microservice.selectorLabels` on Job or
CronJob pod templates: those labels match the Service and PDB selectors, so
the Service would route traffic to job pods. Use a distinct
`app.kubernetes.io/component` instead.

### Migration Job

Runs before every deploy as a Helm `pre-install,pre-upgrade` hook (Argo CD
maps it to `PreSync`). If it fails, the sync fails and the previous version
keeps running. The last Job stays in the cluster for its logs and is deleted
right before the next run.

```yaml
extraObjects:
  - |
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: {{ include "microservice.fullname" . }}-migrate
      labels:
        {{- include "microservice.labels" . | nindent 4 }}
      annotations:
        helm.sh/hook: pre-install,pre-upgrade
        helm.sh/hook-delete-policy: before-hook-creation
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 600
      template:
        metadata:
          labels:
            app.kubernetes.io/component: migration
        spec:
          restartPolicy: Never
          serviceAccountName: default
          automountServiceAccountToken: false
          {{- with .Values.imagePullSecrets }}
          imagePullSecrets:
            {{- toYaml . | nindent 8 }}
          {{- end }}
          securityContext:
            {{- toYaml .Values.podSecurityContext | nindent 8 }}
          containers:
            - name: migrate
              image: {{ include "microservice.image" . }}
              args: ["migrate", "up"]
              {{- include "microservice.containerEnv" . | nindent 10 }}
              resources:
                {{- toYaml .Values.resources | nindent 12 }}
              securityContext:
                {{- toYaml .Values.securityContext | nindent 12 }}
```

Why it looks like this:

- **`backoffLimit: 0`**: a migration that failed halfway must not be retried
  blindly. The sync stops and someone reads the logs.
- **`activeDeadlineSeconds`**: a migration stuck on a lock would otherwise
  hang the sync forever.
- **`serviceAccountName: default`**: a pre-install hook runs before any other
  resource of the release exists, the chart's ServiceAccount included. If the
  migration needs IAM (e.g. RDS IAM auth), point it to a ServiceAccount
  managed outside the release. The Secrets it reads are managed outside the
  release too, so they already exist.

What the application must guarantee:

- **Idempotency.** Argo CD runs `PreSync` hooks on **every** sync, including
  env-only changes and self-heal. `migrate up` with nothing pending must be a
  no-op (golang-migrate and Atlas behave this way).
- **Compatibility with the running version.** Old pods keep serving traffic
  while the migration runs: follow expand → deploy → contract (add first,
  ship the code, remove in a later release).
- **No automatic rollback of the schema.** Rolling back in Argo CD reverts the
  image, not the database. Down migrations are never run automatically.

Prefer this over an initContainer: that would run the migration on every pod
start, concurrently across replicas, and a failure would crash-loop pods
instead of cleanly blocking the deploy.

### CronJob

A normal (non-hook) resource, so it can use the chart's ServiceAccount.
CronJob specs are mutable: no immutability issues on image bumps.

```yaml
extraObjects:
  - |
    apiVersion: batch/v1
    kind: CronJob
    metadata:
      name: {{ include "microservice.fullname" . }}-sync
      labels:
        {{- include "microservice.labels" . | nindent 4 }}
    spec:
      schedule: "0 * * * *"
      concurrencyPolicy: Forbid
      successfulJobsHistoryLimit: 1
      failedJobsHistoryLimit: 3
      jobTemplate:
        spec:
          backoffLimit: 2
          activeDeadlineSeconds: 1800
          template:
            metadata:
              labels:
                app.kubernetes.io/component: sync
            spec:
              restartPolicy: Never
              serviceAccountName: {{ include "microservice.serviceAccountName" . }}
              automountServiceAccountToken: {{ .Values.serviceAccount.automount }}
              {{- with .Values.imagePullSecrets }}
              imagePullSecrets:
                {{- toYaml . | nindent 12 }}
              {{- end }}
              securityContext:
                {{- toYaml .Values.podSecurityContext | nindent 12 }}
              containers:
                - name: sync
                  image: {{ include "microservice.image" . }}
                  args: ["sync"]
                  {{- include "microservice.containerEnv" . | nindent 14 }}
                  resources:
                    {{- toYaml .Values.resources | nindent 16 }}
                  securityContext:
                    {{- toYaml .Values.securityContext | nindent 16 }}
```

To vary the schedule per environment, keep the CronJob in the base values and
override `extraObjects` as a whole in `values.<env>.yaml` only if needed:
lists are replaced, not merged. When several workloads need per-environment
tweaks of the same job, that's the signal to promote it to a chart value.

## Development

```bash
helm lint --strict charts/microservice -f charts/microservice/ci/api-values.yaml
helm unittest charts/microservice
```

Don't edit `version` in `Chart.yaml` or `CHANGELOG.md` by hand: both are
written on release from the commit messages (see the repository README). Mark
breaking changes to values (renamed or removed keys, changed defaults that
alter rendered output) with `!` or a `BREAKING CHANGE:` footer.
