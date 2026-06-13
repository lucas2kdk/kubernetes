# Operations runbook

Day-2 reference for operating this Flux GitOps fleet: bootstrap, reconcile,
local validation, CI, and the procedures for extending and accessing the
clusters. For *what* the components are and how the reconcile graph is shaped,
see [architecture](architecture.md) and [components](components.md). For the
in-cluster network/policy model see [networking](networking.md) and
[policies](policies.md); for identity/secrets see
[secrets-and-identity](secrets-and-identity.md); for the observability stack see
[monitoring](monitoring.md). The canonical bootstrap/reconcile/validation
narrative is the [top-level README](../README.md) — this page is the operational
how-to.

## Prerequisites / tooling

Everything the pipeline needs is installed and run automatically in CI and
reproducibly via the [`justfile`](../justfile). You only need these locally if
you want to run the checks before pushing. See [tools](tools.md) for install
detail, roles, and docs links.

| Tool | Used by | Role |
|------|---------|------|
| `just` | every recipe / CI job | task runner — `just check` is the whole PR gate |
| `kustomize` (or `kubectl kustomize`) | `validate`, `policy`, `scan` | builds each `kustomization.yaml` the way Flux does (`--load-restrictor LoadRestrictionsNone`) |
| `kubeconform` | `validate` | schema-checks built manifests against Kubernetes + Flux + community CRD schemas |
| `kyverno` (CLI) | `policy` | `kyverno apply` evaluates `ClusterPolicies`; `kyverno test` runs `tests/policy/` fixtures |
| `yq` or `python3` (+ PyYAML) | `namespaces`, `policy`, `scan` | YAML extraction / namespace→labels map / CVE tally |
| `gitleaks` | `secrets` | scans the working tree for committed secrets |
| `actionlint` | `lint` | lints the GitHub Actions workflow files |
| `trivy` (+ `helm`, `yq`) | `scan` | container-image CVE scan (weekly, not a PR gate) |

CI pins each tool version in the workflow `env:` blocks (with `# renovate:`
annotations) and passes them to the shared composite action
`.github/actions/setup-tools`. `helm` and `yq` are preinstalled on the
GitHub-hosted runners.

## Bootstrap

Flux is normally installed by **Terraform** (`flux_bootstrap_git` in the
bootstrap repo's `cluster-addons` module) as part of `terraform apply` — there
is no manual step in the happy path.

To (re)bootstrap by hand, set your `kubectl` context to the target cluster,
export a GitHub PAT with `repo` scope, and run `flux bootstrap github` with the
exact flags for that cluster's path:

```bash
export GITHUB_TOKEN=<your-pat>
kubectl config use-context <prod-fsn-context>
flux bootstrap github \
  --owner=lucas2kdk \
  --repository=kubernetes \
  --branch=main \
  --path=clusters/prod-fsn \
  --personal
```

`--path` selects the cluster entry point under `clusters/` (e.g.
`clusters/test-home` for the test cluster). Bootstrap is **idempotent** —
rerunning it upgrades Flux and reconciles the path. It writes/updates
`clusters/<name>/flux-system/` (the `GitRepository` + `flux-system`
Kustomization); that directory is generated, **do not hand-edit it**.

## Reconcile

After bootstrap, push to Git and either wait for the sync interval or force it:

```bash
# pull latest from Git and re-apply everything
flux reconcile source git flux-system
flux reconcile kustomization flux-system --with-source

# a single Kustomization
flux reconcile kustomization kyverno -n flux-system --with-source
flux reconcile kustomization kyverno-policies -n flux-system

# the Kyverno HelmRelease (e.g. after a values change)
flux reconcile helmrelease kyverno -n kyverno --with-source
```

`--with-source` first pulls the latest Git/Helm source; without it Flux
re-applies the last-fetched revision. Fleet `Kustomization` CRs live in
`flux-system`; a `HelmRelease` lives in its component's own namespace.

Check status:

```bash
flux get kustomizations -A
flux get helmreleases -A
flux logs --follow
```

## Local validation — the `justfile` recipes

Each PR check is runnable locally as `just <recipe>`. `just` with no recipe
lists them.

| Recipe | What it runs | Underlying script | Tooling | A failure means |
|--------|--------------|-------------------|---------|-----------------|
| `just validate` | Builds every `kustomization.yaml` the way Flux does and schema-checks the output, plus the cluster Flux Kustomization CRs under `clusters/`. | `scripts/validate.sh` | `kustomize` (or `kubectl`), `kubeconform` | a `kustomize build` error, a `kubeconform` schema violation (malformed/typo'd manifest, rejected under `-strict`), **or** discovery found zero targets (repo layout moved / wrong CWD — fails rather than report a green 0/0). |
| `just policy` | Renders the manifests each cluster reconciles, runs `kyverno apply` against them (Enforce fails, Audit warns), then the `tests/policy/` unit tests, then guards the `longhorn-system` baseline-CNP exclusion. | `scripts/policy-check.sh` | `kustomize`, `kyverno`, `python3` | an Enforce-mode violation, a `ClusterPolicy` that won't parse/compile, a failing `tests/policy/` fixture, **or** `generate-baseline-netpol` leaking a baseline CNP into `longhorn-system`. |
| `just namespaces` | Checks the four platform-namespace exclusion lists are set-identical (the drift guard). | `scripts/check-namespace-lists.sh` | `yq` or `python3` | the four lists diverged — it names exactly which namespace is missing from / extra in which file. See [networking](networking.md). |
| `just secrets` | Scans the working tree for committed secrets: `gitleaks dir . --no-banner --redact --verbose`. | (inline) | `gitleaks` | a secret pattern matched in the tree. See [secrets-and-identity](secrets-and-identity.md). |
| `just lint` | Lints the GitHub Actions workflows: `actionlint`. | (inline) | `actionlint` | invalid workflow YAML, expression syntax, or a shellcheck finding in a `run:` block. |

```bash
just check     # validate + policy + namespaces + secrets + lint  (the full PR gate)
```

`just check` runs all five recipes and fails if any sub-recipe fails — this is
exactly what CI runs on a pull request.

### `just scan` — weekly CVE scan, NOT a gate

```bash
just scan      # scripts/image-scan.sh
```

`just scan` renders the charts + manifests the cluster *actually reconciles*
(not the scaffolded `netdata`/`vector` stubs — scanning undeployed images would
be noise), discovers every container image (by `helm template`-ing each
reconciled `HelmRelease` and scraping the rendered bundle), and scans each with
Trivy (HIGH + CRITICAL, `--ignore-unfixed` so it flags only criticals a version
bump can actually resolve). It **exits 1 if any CRITICAL with an available fix
is found**.

It is **not** a PR gate: CVEs are disclosed independently of commits, so gating
PRs on them would go red for reasons unrelated to the change. It runs weekly in
CI (`.github/workflows/image-scan.yaml`) and on demand. Charts that fail to
template are reported, not skipped silently, so coverage gaps stay visible.

> The `tests/policy/` fixtures pin policy behaviour: the rendered GitOps tree
> has almost no in-scope workloads (chart pods are Helm-expanded at install,
> and the only source-tree Deployment, `tsidp`, is in a platform-excluded
> namespace), so `kyverno apply` never exercises the tenant rules. When you add
> or change a `ClusterPolicy`, add/update the matching fixture. See
> [policies](policies.md).

## CI

### `.github/workflows/pull-request.yaml` — the PR gate

Triggered on `pull_request` to `main`. Five independent jobs — `validate`,
`policy`, `secrets`, `namespaces`, `lint` — one per `just check` recipe, so they
run in **parallel** and a failure points at one check.

- **Least privilege:** `permissions: contents: read` — the checks only read the
  tree, no write scopes.
- **Per-branch concurrency:** `group: ${{ github.workflow }}-${{ github.ref }}`
  with `cancel-in-progress: true` — one in-flight run per branch; a new push
  cancels the superseded run so the PR isn't gated on stale commits.
- **Shared setup:** every job installs only the tools it needs via the composite
  action `./.github/actions/setup-tools` (one place for the pinned install
  steps instead of per-job `curl` blocks). The `namespaces` job needs no
  setup-tools step (only `yq`/`python3`, preinstalled). The `policy` and `scan`
  jobs additionally `pip install pyyaml`.
- **Version pins** live in the workflow `env:` block with `# renovate:`
  annotations and are passed into setup-tools as inputs — keep them in the
  workflow, not in the action, or Renovate stops tracking them. Current pins:
  `KUSTOMIZE_VERSION=5.8.1`, `KUBECONFORM_VERSION=0.8.0`,
  `KYVERNO_VERSION=1.18.1`, `GITLEAKS_VERSION=8.30.1`,
  `ACTIONLINT_VERSION=1.7.12`.

### `.github/workflows/image-scan.yaml` — weekly image CVE scan

- **Schedule:** `cron: "0 6 * * 1"` → **Mondays 06:00 UTC** (after the Renovate
  window so bumped charts get scanned), plus `workflow_dispatch` for on-demand
  runs.
- Single `scan` job runs `just scan | tee -a "$GITHUB_STEP_SUMMARY"`; a CRITICAL
  makes `just scan` exit non-zero, failing the run and triggering GitHub's
  scheduled-workflow-failure notification.
- **Why not a gate:** CVEs are disclosed independently of commits — a PR
  shouldn't go red because a CVE landed upstream. Pins:
  `KUSTOMIZE_VERSION=5.8.1`, `TRIVY_VERSION=0.71.0`.

### `.github/workflows/renovate.yaml` — self-hosted Renovate

- Self-hosted runner using `renovatebot/github-action`, authoring branches/PRs
  with `secrets.RENOVATE_TOKEN`.
- **Triggers:** `workflow_dispatch` (with `logLevel` and `dryRun` inputs) and an
  **hourly** `cron: "0 * * * *"` that just wakes Renovate so it can honour the
  real cadence in `renovate.json`'s `schedule` field.
- **Concurrency:** `group: renovate` (repo-global, no ref) with
  `cancel-in-progress: false` — runs serialize and are never interrupted
  mid-flight.
- `RENOVATE_ONBOARDING=false` + `RENOVATE_REQUIRE_CONFIG=required`: the in-repo
  `renovate.json` is the single source of truth, no org preset, no onboarding
  PR.
- **What it bumps:** the `# renovate:`-annotated tool-version pins in the
  workflow `env:` blocks (kustomize, kubeconform, kyverno, gitleaks, actionlint,
  trivy) via the `customManagers` block in `renovate.json`, plus the Helm chart
  and action versions across the repo.

## Adding a new cluster

The reconcile graph is defined once in `platform/fleet/` and **referenced, never
copied** (see [architecture](architecture.md)). Adding a region is three things:

1. **Bootstrap** Flux into the cluster (Terraform `flux_bootstrap_git`, or the
   manual `flux bootstrap github --path=clusters/<name>` above). This writes
   `clusters/<name>/flux-system/`.
2. **`clusters/<name>/cluster-vars.yaml`** — a `ConfigMap/cluster-vars` in
   `flux-system` with the per-cluster substitution values (currently just
   `cluster_name: <name>`). The fleet Kustomizations substitute `${cluster_name}`
   from this via `postBuild.substituteFrom`.
3. **`clusters/<name>/kustomization.yaml`** — list which fleet components the
   cluster runs. Reference the whole graph (`../../platform/fleet`, as
   `prod-fsn` does) **or** individual fleet files (as `test-home` does:
   `../../platform/fleet/external-secrets.yaml`,
   `.../tailscale-operator.yaml`, ...). If you pick files individually you must
   re-apply the shared spec defaults yourself with a patch on
   `../../platform/fleet/_defaults.yaml` (otherwise those Kustomizations lack
   `interval`/`sourceRef`/`prune`/`wait`).

A per-cluster `tenants.yaml` (and any structural override needing its own Flux
`Kustomization` CR, like `test-home`'s `external-secrets-stores.yaml`) lives in
the cluster folder too, because a Flux `Kustomization`'s `spec.path` can't be
substituted.

## Adding a new platform component

1. **Base** under `platform/base/<component>/`: `namespace.yaml` +
   `source.yaml` (`HelmRepository`) + `release.yaml` (`HelmRelease`).
2. **Fleet Kustomization** `platform/fleet/<component>.yaml` (one Flux
   `Kustomization` CR), with `dependsOn` where ordering matters.
3. **Add it to `platform/fleet/kustomization.yaml`** `resources:` list so the
   aggregate emits it.
4. **Cluster selection:** clusters that reference the whole `../../platform/fleet`
   directory (prod-fsn) pick it up automatically; clusters that list files
   individually must add `../../platform/fleet/<component>.yaml`.

**Platform namespace convention:** label the component's namespace
`platform.io/managed: "true"` in its `namespace.yaml`. That alone satisfies the
Kyverno selector-based excludes, but a new platform namespace must be excluded
from the guardrails in **three** places (only the first is automatic):

1. **Kyverno policies** — automatic via
   `namespaceSelector: matchLabels: platform.io/managed: "true"`. *Exception:*
   `generate-baseline-netpol.yaml` matches on `Namespace` kind with an explicit
   `names:` list — add the namespace there by hand.
2. **Cilium cluster-wide policies** —
   `platform/base/network/{default-deny,deny-cloud-metadata,allow-ingress-from-traefik}.yaml`
   use `NotIn values:` string lists; add the namespace to **all three**.
3. The four non-repo-managed namespaces (`kube-system`, `kube-node-lease`,
   `kube-public`, `flux-system`) have no `namespace.yaml` to label, so they stay
   explicit in the Kyverno static lists too.

Forgetting (2) default-denies the new namespace and breaks its traffic. The
four lists (three Cilium `NotIn` lists + `generate-baseline-netpol`'s `names:`)
must stay set-identical and are guarded by `just namespaces`. See
[networking](networking.md).

## Enabling a scaffolded stub (`netdata` / `vector`)

The bases exist under `platform/base/` but have **no fleet `Kustomization`**, so
Flux does not install them. To enable one:

1. Add `platform/fleet/<name>.yaml` (the Flux `Kustomization`; the template is
   in this repo's git history).
2. List it in `platform/fleet/kustomization.yaml` `resources:`.
3. Fill in the cluster-specific config (e.g. the Humio sink for `vector`).
4. Make sure the cluster's `kustomization.yaml` includes it (automatic for
   clusters referencing the whole `platform/fleet`).

Apply the platform-namespace convention above (label + three exclusion places)
for its namespace.

## Tailscale cluster access

Cluster access runs through the Tailscale operator's API-server proxy in **auth
mode**: the proxy authenticates your tailnet identity and impersonates it
against the Kubernetes API, so standard RBAC applies and no per-user kubeconfig
secrets exist. Each cluster's operator device is the API endpoint
(`k8s-api-${cluster_name}`, e.g. `k8s-api-prod-fsn`).

Generate a kubeconfig entry per cluster and verify the identity mapping:

```bash
tailscale configure kubeconfig k8s-api-prod-fsn
kubectl auth whoami                      # tailnet login + group `maintainers`
kubectl auth can-i delete pods -A        # yes
kubectl auth can-i get secrets -A        # no (maintainers has no Secret read)
```

The ACL grant maps your tailnet identity to the Kubernetes group `maintainers`,
bound by `platform/base/tailscale-operator/rbac-maintainers.yaml` to cluster-wide
`view` plus curated operational verbs (pod delete/exec/port-forward, rollout
restart/scale, cordon/drain). The canonical ACL policy lives in the
[top-level README ACL section](../README.md#canonical-acl-policy-hand-pasted-in-the-admin-console).
For the full access-layer overview (CLI + Headlamp paths, tags, OAuth clients)
see [secrets-and-identity](secrets-and-identity.md).

## Troubleshooting

### Policy Reporter UI

No Ingress is configured yet; reach the UI with a port-forward:

```bash
kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080
# then open http://localhost:8082
```

See [policies](policies.md) / [monitoring](monitoring.md).

### Known incidents → mitigations

| Incident | Class | Mitigation (in repo) | Cross-link |
|----------|-------|----------------------|------------|
| **2026-06-12 `longhorn-system` storage outage** | A baseline CiliumNetworkPolicy leaked into `longhorn-system` after the four exclusion lists fell out of lockstep, flipping it default-deny and severing CSI ↔ kube-apiserver — provisioner crash-looped, PVCs stuck Pending. | The **namespace-lockstep guard** `scripts/check-namespace-lists.sh` (`just namespaces`, part of `just check`) fails the build if the four lists ever diverge, naming the missing/extra namespace; `policy-check.sh` separately asserts `longhorn-system` never gets a baseline CNP. | [networking](networking.md), [policies](policies.md) |
| **Kyverno OOM / page-cache thrash** | The chart-default 128Mi memory limit is smaller than the ~120MB kyverno binary, so the kernel evicts the controller's own executable page cache and re-reads it from disk forever (no OOM kill; `memory.events:max` in the millions). On 2026-06-12 the background + reports controllers read ~3TB this way, pinning the HDD system disk at 100% util → etcd/apiserver brownouts → CSI/PVC failures. | Memory **limits raised to 512Mi** (requests 128Mi) on the background/cleanup/reports controllers in `platform/base/kyverno/release.yaml`; keep limits comfortably above binary size + heap. | [components](components.md) |
| **Single-node drain deadlock** | Fail-closed webhooks assume the admission controller outlives any one node — impossible on a single-node cluster, where every drain evicts Kyverno and its webhook then rejects kubelet's final pod deletions, deadlocking the drain (hit 2026-06-11 during a Talos upgrade). | `forceFailurePolicyIgnore.enabled: true` in `release.yaml` so node lifecycle never depends on Kyverno being up; a PDB (`pdb.yaml`) with `maxUnavailable: 1` (not `minAvailable`) so drain isn't blocked at one replica. When the cluster grows to 3+ nodes, drop the force-ignore and set `admissionController.replicas: 3` to restore fail-closed enforcement. | [policies](policies.md), [architecture](architecture.md) |

For the full incident write-ups see the inline notes in
`platform/base/kyverno/release.yaml`, `platform/base/kyverno/pdb.yaml`, and
`platform/base/policies/generate-baseline-netpol.yaml`.
