# kubernetes

Flux multi-tenancy GitOps repository, based on the
[fluxcd/flux2-multi-tenancy](https://github.com/fluxcd/flux2-multi-tenancy)
example.

It manages the cluster fleet — currently **prod-fsn** (Hetzner Falkenstein,
bare-metal Talos) and **test-home** (a home-LAN test cluster running a subset) —
from a single Git repository, with a platform admin defining the tenants and the
policies that constrain them. The reconcile graph is defined **once** for the
whole fleet in `platform/fleet/`; each cluster is a thin folder — its Flux
bootstrap, a `cluster-vars.yaml` ConfigMap of per-cluster values, and a
`kustomization.yaml` listing which fleet components it runs. Adding a new region
is bootstrap + `cluster-vars.yaml` + a component list, with no copying of the
reconcile graph.

This follows the fleet-repo layout from the platform spec: Terraform owns
infrastructure, **Flux owns everything inside Kubernetes**, organized as
`platform/{fleet,base,overlays}` + `tenants/{base,overlays}`.

## Documentation

The top-level sections below are the quickstart. The [`docs/`](docs/) folder
holds the deep, per-topic reference:

| Doc | Covers |
|-----|--------|
| [docs/README.md](docs/README.md) | Documentation index and orientation |
| [docs/architecture.md](docs/architecture.md) | Fleet-repo model, per-cluster variation rule, the `dependsOn` reconcile graph |
| [docs/components.md](docs/components.md) | Catalogue of every platform component (chart, namespace, config rationale, access) |
| [docs/networking.md](docs/networking.md) | Cilium default-deny, the four-list namespace lockstep, allow policies |
| [docs/policies.md](docs/policies.md) | Kyverno `ClusterPolicy` set and the `tests/policy/` unit tests |
| [docs/secrets-and-identity.md](docs/secrets-and-identity.md) | ESO→Vault, cert-manager, Tailscale API proxy, tsidp OIDC |
| [docs/monitoring.md](docs/monitoring.md) | kube-prometheus-stack, ServiceMonitor discovery, bundled dashboards |
| [docs/operations.md](docs/operations.md) | Bootstrap, reconcile, validation, CI, adding a cluster/component, troubleshooting |
| [docs/tools.md](docs/tools.md) | Local tooling install reference |

## Repository structure

```
├── clusters         # Flux entry point per cluster (thin: which components it runs)
│   ├── prod-fsn     #   flux-system + cluster-vars.yaml + kustomization.yaml + tenants.yaml
│   └── test-home    #   flux-system + cluster-vars.yaml + kustomization.yaml (subset)
├── platform         # All in-cluster platform components
│   ├── fleet        #   the per-component Flux Kustomizations + dependsOn graph (defined ONCE)
│   ├── base         #   reusable component bases (HelmRelease + source + ns)
│   └── overlays     #   per-cluster structural diffs only (test-home AppRole auth)
├── tenants          # Per-tenant namespaces, RBAC and workloads
│   ├── base
│   └── overlays     #   per-cluster tenant presence (prod-fsn)
├── docs             # Per-topic reference documentation (see table above)
├── scripts          # Validation/scan scripts run by the justfile and CI
├── tests            # Kyverno policy unit tests (tests/policy/)
├── .github          # CI workflows: PR gate + weekly image CVE scan + Renovate
└── justfile         # Local entry points (just check / validate / policy / secrets / scan)
```

- **clusters/** — the per-cluster reconciliation entry points, thin by design.
  Each cluster's folder holds its `flux-system/` bootstrap (do **not** hand-edit),
  a `cluster-vars.yaml` ConfigMap of per-cluster substitution values (currently
  just `cluster_name`), a `kustomization.yaml` listing which fleet components the
  cluster runs, and any genuinely per-cluster Flux `Kustomization` CRs
  (`tenants.yaml`, and `test-home`'s structural `external-secrets-stores.yaml`).
  `prod-fsn` runs the full fleet — its `kustomization.yaml` references
  `../../platform/fleet` (the whole set). `test-home` runs a subset — it lists
  individual fleet files plus its own `external-secrets-stores.yaml` override.
- **platform/** — every component Flux installs.
  - `fleet/` holds one Flux `Kustomization` CR per component, defined **once** for
    the whole fleet, and `fleet/kustomization.yaml` aggregates all **16** (the
    "run everything" set) and applies shared spec defaults via `_defaults.yaml`.
    The reconcile-order `dependsOn` graph lives here, once, instead of being
    copied into every cluster folder.
  - `base/<component>` is a Kustomize base (`namespace.yaml` + `source.yaml`
    `HelmRepository` + `release.yaml` `HelmRelease`, or plain manifests) that a
    fleet `Kustomization` reconciles directly. Per-cluster *scalar values* are not
    patched via overlays: base manifests carry `${cluster_name}` tokens (e.g.
    `tailscale-operator/release.yaml` `hostname: k8s-api-${cluster_name}`,
    `external-secrets-stores/cluster-secret-store.yaml`
    `mountPath: kubernetes/${cluster_name}`) and the matching fleet
    `Kustomization`s carry `postBuild.substituteFrom: [{kind: ConfigMap, name:
    cluster-vars}]`, so Flux substitutes the token in-cluster from each cluster's
    `cluster-vars` ConfigMap.
  - `overlays/<cluster>/<component>` is reserved for *structural* differences,
    not value swaps. The only remaining overlay is
    `overlays/test-home/external-secrets-stores`: test-home's home-LAN apiserver
    can't serve Vault's TokenReview callback, so it removes the `kubernetes` auth
    block and adds an `appRole` block. Because a Flux `Kustomization`'s `spec.path`
    can't be substituted, test-home keeps its own
    `clusters/test-home/external-secrets-stores.yaml` CR pointing at that overlay.

  The 16 live components: `kyverno` (admission controller), `kyverno-policies`
  (the `ClusterPolicy` set), `policy-reporter` (Policy Reporter + web UI),
  `network-policies` (Cilium cluster-wide default-deny), `trivy-operator`
  (on-cluster CIS benchmark + vulnerability/config/RBAC assessments),
  `external-secrets` + `external-secrets-stores` (ESO → Vault), `cert-manager` +
  `cert-manager-issuers` (Let's Encrypt via Cloudflare DNS-01), `traefik`
  (ingress, ClusterIP-only for now), `tailscale-operator` (API-server proxy in
  auth mode), `tsidp` (Tailscale OIDC identity provider behind Headlamp/Grafana
  logins), `headlamp` (dashboard), `kube-prometheus-stack` (Prometheus +
  Grafana), `monitoring-extras` (the Flux + Longhorn monitors, split out so they
  apply after the Prometheus-Operator CRDs exist), and `capacitor` (Flux GitOps
  dashboard UI). See [docs/components.md](docs/components.md) for the full
  catalogue.

  > There are **no scaffolded stubs** in the tree today — every `platform/base/`
  > component has a fleet `Kustomization` and is reconciled. To add a new one,
  > follow the add-component flow in [docs/operations.md](docs/operations.md).
- **tenants/** — tenant definitions (namespaces, service accounts, RBAC and the
  Flux sources/Kustomizations each tenant manages). `tenants` reconciles per
  cluster from `overlays/<cluster>`. Because its `spec.path` points at
  `tenants/overlays/<cluster>` and a Flux `Kustomization`'s `path` can't be
  substituted, `tenants` stays a per-cluster Flux `Kustomization`
  (`clusters/<name>/tenants.yaml`): `prod-fsn` has one, `test-home` has none yet.

The rule for where per-cluster variation lives: **per-cluster *values* go in
`cluster-vars` and are applied via `${var}` substitution; per-cluster *structure*
gets an overlay plus a per-cluster Flux `Kustomization` CR.** The full model,
with the reconcile-graph diagram, is in
[docs/architecture.md](docs/architecture.md).

## Platform namespace convention

Platform components run privileged, cluster-level workloads and are exempt from
the tenant-facing guardrails (Kyverno admission policies, the Cilium
default-deny). Every platform namespace carries the label
`platform.io/managed: "true"` on its `platform/base/<component>/namespace.yaml`.

When you add a new platform component, its namespace must be excluded from the
guardrails in **three** places — only the first is automatic:

1. **Kyverno policies** (`platform/base/policies/`) — automatic. The Pod /
   Kustomization / HelmRelease policies exclude via
   `namespaceSelector: matchLabels: platform.io/managed: "true"`, so labelling
   the namespace is enough. *Exception:* `generate-baseline-netpol.yaml` matches
   on `Namespace` kind and keeps an explicit `names:` list — add the new
   namespace there by hand.
2. **Cilium cluster-wide policies** (`platform/base/network/{default-deny,
   deny-cloud-metadata,allow-ingress-from-traefik}.yaml`) — manual. These use
   `NotIn values:` string lists (Cilium can't match arbitrary namespace labels
   in a `NotIn` expression), so add the namespace to all three lists. Forgetting
   this default-denies the new namespace and breaks its egress/ingress.
3. The four non-repo-managed namespaces (`kube-system`, `kube-node-lease`,
   `kube-public`, `flux-system`) have no `namespace.yaml` here to label, so they
   stay explicit in the Kyverno static lists too.

These four lists (the three Cilium `NotIn` lists +
`generate-baseline-netpol.yaml`'s `names:`) must be edited by hand in lockstep —
they can't be deduplicated into one source: `kubeconform` validates the Cilium
CRD, so Flux-substituting a YAML *list* would break validation. A drift guard,
`scripts/check-namespace-lists.sh` (run via `just namespaces`, part of
`just check`), **fails the build if the four lists ever diverge**, printing
exactly which namespace is missing from which file.

`longhorn-system` (Terraform-managed storage) is a special case: it must appear
in **all three** Cilium lists *and* `generate-baseline-netpol.yaml` in lockstep
— it has no baseline CNP and relies on being outside every policy to keep CSI
↔ kube-apiserver traffic flowing (see the 2026-06-12 outage note in
`generate-baseline-netpol.yaml`; that outage is exactly the drift the guard now
prevents). Full detail in [docs/networking.md](docs/networking.md).

## Reconcile order

The reconcile graph is defined once for the whole fleet, in `platform/fleet/`:
one Flux `Kustomization` per component, with `dependsOn` enforcing ordering where
it matters. The roots have no dependencies — `external-secrets`,
`kube-prometheus-stack`, `network-policies` and `tenants` — and everything else
chains off them:

- **Prometheus-Operator CRDs first.** `kube-prometheus-stack` installs the
  `ServiceMonitor`/`PodMonitor`/`PrometheusRule` CRDs, so every component that
  ships a monitor waits on it: `kyverno`, `cert-manager`, `trivy-operator` and
  `monitoring-extras` (`dependsOn: kube-prometheus-stack`).
- **Kyverno before its policies/reporter.** `kyverno-policies` and
  `policy-reporter` both `dependsOn: kyverno`.
- **Secret stores before secret consumers.** `external-secrets-stores`
  `dependsOn: external-secrets`; then `headlamp`, `tsidp`, `tailscale-operator`
  and `cert-manager-issuers` `dependsOn: external-secrets-stores`.
- **cert-manager before issuers/ingress.** `cert-manager-issuers`
  `dependsOn: cert-manager` (and `external-secrets-stores`) with `wait: true`;
  `traefik` `dependsOn: cert-manager`.
- `network-policies` has no `dependsOn` but needs the Cilium CRDs, which
  Terraform installs out-of-band.

The full graph (with a diagram) is in [docs/architecture.md](docs/architecture.md).

> **Note:** The cluster CNI (Cilium) and its Hubble observability layer, and the
> Longhorn storage layer, are managed out-of-band via Terraform — not by this
> repository.

Reach the Policy Reporter UI with a port-forward (no Ingress configured yet):

```bash
kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080
# then open http://localhost:8082
```

## Tailscale access (API-server proxy)

> For the full access-layer overview — CLI **and** Headlamp UI paths, tags,
> OAuth clients, and the ACL source of truth — see
> [`bootstrap/terraform/docs/tailscale.md`](../bootstrap/terraform/docs/tailscale.md)
> and [docs/secrets-and-identity.md](docs/secrets-and-identity.md). This section
> covers the CLI / API-proxy path only.

Cluster access runs through the Tailscale operator's API-server proxy in
**auth mode**: the proxy authenticates your tailnet identity and impersonates
it against the Kubernetes API, so standard RBAC applies and the audit trail
carries your real login. No per-user kubeconfig secrets, no public API
endpoints.

- Each cluster's operator device is the API endpoint: `k8s-api-prod-fsn`
  (hostname is `k8s-api-${cluster_name}` in
  `platform/base/tailscale-operator/release.yaml`, substituted per cluster from
  the `cluster-vars` ConfigMap).
- The operator's OAuth client credentials live in Vault at
  `secret/platform/tailscale` (keys `client_id`, `client_secret`), synced by
  ESO into the `operator-oauth` Secret. The OAuth client needs the
  **Devices Core (write)** and **Auth Keys (write)** scopes and the
  `tag:k8s-operator` + `tag:k8s` tags.
- RBAC: the ACL grant below maps your tailnet identity to the Kubernetes group
  `maintainers`, bound by `platform/base/tailscale-operator/rbac-maintainers.yaml`
  to cluster-wide `view` plus curated operational verbs (pod delete/exec/
  port-forward, rollout restart/scale, cordon/drain). No Secret read.
  Per-tenant groups (`tenant:<name>`) arrive with tenant onboarding.

### Canonical ACL policy (hand-pasted in the admin console)

The tailnet ACLs are edited in the Tailscale admin console; this is the
canonical copy. Verify the grant syntax against the
[Tailscale KB](https://tailscale.com/kb/1437/kubernetes-operator-api-server-proxy)
when pasting.

```jsonc
{
  "tagOwners": {
    "tag:k8s-operator": ["autogroup:admin"],
    "tag:k8s": ["tag:k8s-operator"] // operator must own the per-service proxy tag
  },
  "grants": [
    {
      // tailnet identity -> Kubernetes group `maintainers` on every cluster's
      // API proxy (in-process proxy = the operator device itself)
      "src": ["lucas@rosenvold.tech"],
      "dst": ["tag:k8s-operator"],
      "ip": ["443"],
      "app": {
        "tailscale.com/cap/kubernetes": [
          {"impersonate": {"groups": ["maintainers"]}}
        ]
      }
    }
  ]
}
```

Generate a kubeconfig entry per cluster and verify the identity mapping:

```bash
tailscale configure kubeconfig k8s-api-prod-fsn
kubectl auth whoami                      # tailnet login + group `maintainers`
kubectl auth can-i delete pods -A        # yes
kubectl auth can-i get secrets -A        # no
```

## Validating changes

Every pull request to `main` is gated by `.github/workflows/pull-request.yaml`,
which runs several independent checks. All are runnable locally through the
[`justfile`](justfile) (`just <recipe>`):

| Recipe            | What it does                                                             | Tooling                  |
|-------------------|--------------------------------------------------------------------------|--------------------------|
| `just validate`   | Builds every `kustomization.yaml` the way Flux does (`--load-restrictor LoadRestrictionsNone`) and schema-checks the output, plus the cluster Flux Kustomization objects. | `kustomize` (or `kubectl`), `kubeconform` |
| `just policy`     | Renders the manifests each cluster reconciles, evaluates the Kyverno `ClusterPolicies` against them, then runs the policy unit tests in `tests/policy/`. | `kustomize`, `kyverno`, `python3` |
| `just namespaces` | Checks the four platform-namespace exclusion lists are set-identical (the drift guard). | `yq` or `python3`        |
| `just secrets`    | Scans the working tree for committed secrets.                            | `gitleaks`               |
| `just lint`       | Lints the GitHub Actions workflows.                                      | `actionlint`             |

`just check` runs all of them — `validate`, `policy`, `namespaces`, `secrets`,
`lint` (what CI runs). `just` with no recipe lists them. A separate `just scan`
renders the charts the cluster actually reconciles and scans the referenced
container images for CVEs (`--ignore-unfixed`); it is **not** a PR gate and runs
weekly (`.github/workflows/image-scan.yaml`, Mondays 06:00 UTC) and on demand.
See [docs/operations.md](docs/operations.md) for failure semantics and the CI
breakdown, and [docs/tools.md](docs/tools.md) to install the tooling.

### Policy unit tests (`tests/policy/`)

The rendered GitOps tree contains almost no in-scope workloads, so `just policy`'s
evaluation pass never exercises the tenant-governing rules. The fixtures in
`tests/policy/` close that gap with a `kyverno test` suite that asserts, on
hand-written known-good/known-bad resources, that the pod rules,
`flux-multi-tenancy`, and `generate-baseline-netpol` fire as intended **and**
correctly exempt `platform.io/managed` namespaces. The `longhorn-system`
exclusion is checked separately in `scripts/policy-check.sh`. When you add or
change a `ClusterPolicy`, add or update the matching fixture. Detail in
[docs/policies.md](docs/policies.md).

## Bootstrap

Flux is normally installed by Terraform (`flux_bootstrap_git` in the bootstrap
repo's `cluster-addons` module) as part of `terraform apply` — no manual step.
To (re)bootstrap by hand, set your `kubectl` context to the target cluster and
export a GitHub PAT with `repo` scope:

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

Bootstrap is idempotent — rerunning it upgrades Flux and reconciles the path.

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

Check status:

```bash
flux get kustomizations -A
flux get helmreleases -A
flux logs --follow
```

## Reference

- [Flux multi-tenancy guide](https://github.com/fluxcd/flux2-multi-tenancy)
- [Flux documentation](https://fluxcd.io/flux/)
- [Repository documentation](docs/) — per-topic deep reference
