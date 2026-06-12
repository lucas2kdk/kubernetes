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
└── tenants          # Per-tenant namespaces, RBAC and workloads
    ├── base
    └── overlays     #   per-cluster tenant presence (prod-fsn)
```

This follows the fleet-repo layout from the platform spec: Terraform owns
infrastructure, **Flux owns everything inside Kubernetes**, organized as
`platform/{base,overlays}` + `tenants/{base,overlays}`.

- **clusters/** — the per-cluster reconciliation entry points. Each cluster's
  folder holds the Flux `Kustomization` objects, one per platform component
  plus `tenants`, pointing at that cluster's overlay. `flux-system/` is the
  bootstrap (do not hand-edit).
- **platform/** — every component Flux installs. `base/<component>` is a
  Kustomize base (`namespace.yaml` + `source.yaml` `HelmRepository` +
  `release.yaml` `HelmRelease`); `overlays/<cluster>/<component>` selects it for
  a cluster and patches values. Components:
  - **Live today:** `kyverno` (admission controller), `policies` (the
    `ClusterPolicy` set — starting with the flux-multi-tenancy guardrail that
    blocks cross-namespace source references), `policy-reporter`
    ([Policy Reporter](https://kyverno.github.io/policy-reporter/) + web UI),
    `network` (a Cilium cluster-wide default-deny
    `CiliumClusterwideNetworkPolicy`), `headlamp` (dashboard),
    `external-secrets` (ESO → Vault), `cert-manager` +
    `cert-manager-issuers` (Let's Encrypt via Cloudflare DNS-01), `traefik`
    (ingress, ClusterIP-only for now), and `tailscale-operator` (API-server
    proxy in auth mode — see [Tailscale access](#tailscale-access-api-server-proxy)),
    and `kube-prometheus-stack` (Prometheus + Grafana). Grafana is reached on
    the tailnet at `https://grafana.<tailnet>.ts.net` (Tailscale ingress, tsidp
    OIDC — same model as Headlamp); Prometheus keeps a self-pruning ≤100Gi
    Longhorn TSDB (`retentionSize` 85GiB / 30d). Bundled dashboards (Kubernetes,
    Flux, cert-manager, Kyverno, Longhorn) provision from the committed
    ConfigMaps under `kube-prometheus-stack/dashboards/` via the Grafana
    sidecar, fed by per-component ServiceMonitor/PodMonitors.
  - **Scaffolded stubs (V1, wired but minimal — see `# TODO` markers):**
    `netdata`, `vector`. These reconcile to minimal installs; cluster-specific
    config (Humio sink) is left to fill in.

  The `network` default-deny policy denies all ingress/egress for **workload**
  namespaces while excluding the platform namespaces (`kube-system`,
  `flux-system`, `kyverno`, `policy-reporter`, ...) so the control plane, GitOps
  and admission webhooks keep working. It permits DNS and host/API-server
  traffic; everything else needs an explicit allow policy. Requires Cilium as the
  CNI (managed via Terraform).
- **tenants/** — tenant definitions (namespaces, service accounts, RBAC and the
  Flux sources/Kustomizations each tenant manages). Empty until the first tenant
  is onboarded; `tenants` reconciles per cluster from `overlays/<cluster>`.

`base` directories are Kustomize bases that the per-cluster overlays
(`overlays/prod-fsn`, plus future clusters) build on, keeping
environment-specific configuration out of the shared definitions.

### Reconcile order

Per cluster, Flux applies one `Kustomization` per component (auto-discovered
from the loose YAML files under `clusters/<env>/`). `dependsOn` enforces
ordering where it matters:

- `kyverno` → the Kyverno controller and CRDs
- `kyverno-policies` → the `ClusterPolicy` resources (`dependsOn: kyverno`)
- `policy-reporter` → Policy Reporter + UI (`dependsOn: kyverno`)
- `network-policies` → Cilium cluster-wide default-deny (requires the Cilium
  CRDs, which Terraform installs out-of-band)
- `cert-manager-issuers` → the Let's Encrypt `ClusterIssuer`s + the
  ESO-synced Cloudflare token (`dependsOn: cert-manager, external-secrets`;
  `wait: true`, so it only reads Ready once the issuers register with ACME)
- `traefik` (`dependsOn: cert-manager`) and `tailscale-operator`
  (`dependsOn: external-secrets`)
- everything else (`cert-manager`, `external-secrets`, `kube-prometheus-stack`,
  `netdata`, `vector`, `headlamp`) reconciles independently

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
