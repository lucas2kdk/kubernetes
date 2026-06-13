# kubernetes

Flux multi-tenancy GitOps repository, based on the
[fluxcd/flux2-multi-tenancy](https://github.com/fluxcd/flux2-multi-tenancy)
example.

It manages the cluster fleet — currently **prod-fsn** (Hetzner Falkenstein,
bare-metal Talos) — from a single Git repository, with a platform admin defining
the tenants and the policies that constrain them. The layout stays per-cluster
so new regions join as new `clusters/<name>` + `overlays/<name>` entries.

## Repository structure

```
├── clusters         # Flux entry point per cluster
│   └── prod-fsn     #   one Flux Kustomization per platform component + tenants
├── platform         # All in-cluster platform components
│   ├── base         #   reusable component bases (HelmRelease + source + ns)
│   └── overlays     #   per-cluster presence/patches (prod-fsn)
├── tenants          # Per-tenant namespaces, RBAC and workloads
│   ├── base
│   └── overlays     #   per-cluster tenant presence (prod-fsn)
├── scripts          # Validation/scan scripts run by the justfile and CI
├── tests            # Kyverno policy unit tests (tests/policy/)
├── .github          # CI workflows: PR gate + weekly image CVE scan
└── justfile         # Local entry points (just check / validate / policy / secrets / scan)
```

This follows the fleet-repo layout from the platform spec: Terraform owns
infrastructure, **Flux owns everything inside Kubernetes**, organized as
`platform/{base,overlays}` + `tenants/{base,overlays}`.

- **clusters/** — the per-cluster reconciliation entry points. Each cluster's
  folder holds the Flux `Kustomization` objects, one per platform component
  plus `tenants`, pointing at the component's `base` (or a per-cluster overlay
  where one is needed for patches). `flux-system/` is the bootstrap (do not
  hand-edit).
- **platform/** — every component Flux installs. `base/<component>` is a
  Kustomize base (`namespace.yaml` + `source.yaml` `HelmRepository` +
  `release.yaml` `HelmRelease`) that the cluster `Kustomization` reconciles
  directly. A per-cluster overlay (`overlays/<cluster>/<component>`) is added
  only where a value must be patched for that cluster — today just
  `tailscale-operator` (per-cluster API hostname) and `external-secrets-stores`
  (per-cluster Vault auth mount); everything else points straight at `base`.
  Components:
  - **Live today:** `kyverno` (admission controller), `policies` (the
    `ClusterPolicy` set — starting with the flux-multi-tenancy guardrail that
    blocks cross-namespace source references), `policy-reporter`
    ([Policy Reporter](https://kyverno.github.io/policy-reporter/) + web UI),
    `network` (a Cilium cluster-wide default-deny
    `CiliumClusterwideNetworkPolicy`), `headlamp` (dashboard),
    `external-secrets` (ESO → Vault), `cert-manager` +
    `cert-manager-issuers` (Let's Encrypt via Cloudflare DNS-01), `traefik`
    (ingress, ClusterIP-only for now), `tailscale-operator` (API-server
    proxy in auth mode — see [Tailscale access](#tailscale-access-api-server-proxy)),
    `tsidp` (Tailscale OIDC identity provider — the issuer behind Headlamp and
    Grafana logins; a plain Deployment that joins the tailnet and exposes its
    discovery/JWKS endpoints via Funnel), `trivy-operator` (weekly on-cluster
    CIS Kubernetes Benchmark plus workload vulnerability, config-audit and RBAC
    assessments — surfaces as `ClusterComplianceReport`, `VulnerabilityReport`,
    `ConfigAuditReport`, `RbacAssessmentReport`), and `kube-prometheus-stack`
    (Prometheus + Grafana). Grafana is reached on
    the tailnet at `https://grafana.<tailnet>.ts.net` (Tailscale ingress, tsidp
    OIDC — same model as Headlamp); Prometheus keeps a self-pruning ≤100Gi
    Longhorn TSDB (`retentionSize` 85GiB / 30d). Bundled dashboards (Kubernetes,
    Flux, cert-manager, Kyverno, Longhorn) provision from the committed
    ConfigMaps under `kube-prometheus-stack/dashboards/` via the Grafana
    sidecar, fed by per-component ServiceMonitor/PodMonitors.
  - **Scaffolded stubs (bases present, not reconciled — see `# TODO` markers):**
    `netdata`, `vector`. The component bases exist under `platform/base/` but
    have no cluster `Kustomization`, so Flux does not install them yet. Re-add a
    `clusters/prod-fsn/<name>.yaml` and fill in the cluster-specific config
    (Humio sink) to enable them.

  The `network` default-deny policy denies all ingress/egress for **workload**
  namespaces while excluding the platform namespaces (`kube-system`,
  `flux-system`, `kyverno`, `policy-reporter`, ...) so the control plane, GitOps
  and admission webhooks keep working. It permits DNS and host/API-server
  traffic; everything else needs an explicit allow policy. Requires Cilium as the
  CNI (managed via Terraform).
- **tenants/** — tenant definitions (namespaces, service accounts, RBAC and the
  Flux sources/Kustomizations each tenant manages). Empty until the first tenant
  is onboarded; `tenants` reconciles per cluster from `overlays/<cluster>`.

`base` directories are the shared component definitions clusters reconcile
directly. A per-cluster overlay (`overlays/<cluster>/<component>`) is introduced
only when that cluster must patch a value, keeping environment-specific
configuration out of the shared definitions without adding empty pass-through
layers. When a second cluster arrives (or a component needs a per-cluster
patch), re-add an overlay for just that component and repoint its cluster
`Kustomization` at it.

### Platform namespace convention

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

`longhorn-system` (Terraform-managed storage) is a special case: it must appear
in **all three** Cilium lists *and* `generate-baseline-netpol.yaml` in lockstep
— it has no baseline CNP and relies on being outside every policy to keep CSI
↔ kube-apiserver traffic flowing (see the 2026-06-12 outage note in
`generate-baseline-netpol.yaml`).

### Reconcile order

Per cluster, Flux applies one `Kustomization` per component (auto-discovered
from the loose YAML files under `clusters/<env>/`). `dependsOn` enforces
ordering where it matters. The roots have no dependencies —
`external-secrets`, `kube-prometheus-stack`, `network-policies` and `tenants`
— and everything else chains off them:

- **Prometheus-Operator CRDs first.** `kube-prometheus-stack` installs the
  `ServiceMonitor`/`PodMonitor` CRDs, so every component that ships a monitor
  waits on it: `kyverno`, `cert-manager` and `monitoring-extras`
  (`dependsOn: kube-prometheus-stack`). This breaks the chicken-and-egg where a
  component's ServiceMonitor would fail to apply before the operator's CRDs
  exist.
- **Kyverno before its policies/reporter.** `kyverno-policies` (the
  `ClusterPolicy` set) and `policy-reporter` both `dependsOn: kyverno`.
- **Secret stores before secret consumers.** `external-secrets-stores` (the
  Vault `ClusterSecretStore`, a per-cluster overlay) `dependsOn:
  external-secrets`; then everything that reads a Vault-synced secret waits on
  the store: `headlamp`, `tsidp`, `tailscale-operator` and
  `cert-manager-issuers` (`dependsOn: external-secrets-stores`).
- **cert-manager before issuers/ingress.** `cert-manager-issuers` (the Let's
  Encrypt `ClusterIssuer`s + the ESO-synced Cloudflare token) also
  `dependsOn: cert-manager` and sets `wait: true`, so it only reads Ready once
  the issuers register with ACME. `traefik` `dependsOn: cert-manager`.
- `network-policies` (Cilium cluster-wide default-deny) has no `dependsOn` but
  needs the Cilium CRDs, which Terraform installs out-of-band.

`netdata` and `vector` have component bases under `platform/base/` but **no
cluster `Kustomization`** today, so Flux does not reconcile them. Re-add a
`clusters/prod-fsn/<name>.yaml` to enable one (the Flux Kustomization template
is in this repo's git history).

Reach the Policy Reporter UI with a port-forward (no Ingress configured yet):

```bash
kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080
# then open http://localhost:8082
```

> **Note:** The cluster CNI (Cilium) and its Hubble observability layer are
> managed out-of-band via Terraform, not by this repository.

## Tailscale access (API-server proxy)

> For the full access-layer overview — CLI **and** Headlamp UI paths, tags,
> OAuth clients, and the ACL source of truth — see
> [`bootstrap/terraform/docs/tailscale.md`](../bootstrap/terraform/docs/tailscale.md).
> This section covers the CLI / API-proxy path only.

Cluster access runs through the Tailscale operator's API-server proxy in
**auth mode**: the proxy authenticates your tailnet identity and impersonates
it against the Kubernetes API, so standard RBAC applies and the audit trail
carries your real login. No per-user kubeconfig secrets, no public API
endpoints.

- Each cluster's operator device is the API endpoint:
  `k8s-api-prod-fsn` (hostname patched per cluster in
  `platform/overlays/<cluster>/tailscale-operator/`).
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
which runs three independent checks. All of them are runnable locally through
the [`justfile`](justfile) (`just <recipe>`):

| Recipe          | What it does                                                             | Tooling                  |
|-----------------|--------------------------------------------------------------------------|--------------------------|
| `just validate` | Builds every `kustomization.yaml` the way Flux does (`--load-restrictor LoadRestrictionsNone`) and schema-checks the output, plus the cluster Flux Kustomization objects. | `kustomize` (or `kubectl`), `kubeconform` |
| `just policy`   | Renders the manifests each cluster reconciles, evaluates the Kyverno `ClusterPolicies` against them, then runs the policy unit tests in `tests/policy/` (see below). | `kustomize`, `kyverno`, `python3` |
| `just secrets`  | Scans the working tree for committed secrets.                            | `gitleaks`               |

`just check` runs all three (what CI runs). `just` with no recipe lists them.

A fifth recipe, `just scan`, renders the charts + manifests the cluster actually
reconciles (not scaffolded stubs) and scans the referenced container images for
CVEs with Trivy (`--ignore-unfixed`, so it flags only criticals a version bump
can resolve). It is **not** a PR gate — CVEs are disclosed independently of
commits — so it runs weekly instead (`.github/workflows/image-scan.yaml`,
Mondays 06:00 UTC) and on demand.

### Policy unit tests (`tests/policy/`)

The rendered GitOps tree contains almost no in-scope workloads — every chart's
pods are expanded by Helm at install time, and the only source-tree Deployment
(`tsidp`) sits in a platform-excluded namespace — so `just policy`'s evaluation
pass never actually exercises the tenant-governing rules. The fixtures in
`tests/policy/` close that gap with a `kyverno test` suite that asserts, on
hand-written known-good/known-bad resources, that the pod rules,
`flux-multi-tenancy`, and `generate-baseline-netpol` fire as intended **and**
correctly exempt `platform.io/managed` namespaces. The `longhorn-system`
exclusion on `generate-baseline-netpol` (the [2026-06-12 CSI outage](#platform-namespace-convention)
guard) is checked separately in `scripts/policy-check.sh`, since `kyverno test`
can't express a "must-not-generate" assertion.

When you add or change a `ClusterPolicy`, add or update the matching fixture so
the behaviour stays pinned.

## Bootstrap

Flux is normally installed by Terraform (`flux_bootstrap_git` in the
bootstrap repo's `cluster-addons` module) as part of `terraform apply` — no
manual step. To (re)bootstrap by hand instead, set your `kubectl` context to
the target cluster and export a GitHub PAT with `repo` scope:

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
