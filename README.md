# kubernetes

Flux multi-tenancy GitOps repository, based on the
[fluxcd/flux2-multi-tenancy](https://github.com/fluxcd/flux2-multi-tenancy)
example.

It manages three clusters — **admin**, **dev**, and **prod** — from a single
Git repository, with a platform admin defining the tenants and the policies that
constrain them.

## Repository structure

```
├── clusters         # Flux entry point per cluster
│   ├── admin        #   one Flux Kustomization per platform component + tenants
│   ├── dev
│   └── prod
├── platform         # All in-cluster platform components
│   ├── base         #   reusable component bases (HelmRelease + source + ns)
│   └── overlays     #   per-cluster presence/patches (admin / dev / prod)
└── tenants          # Per-tenant namespaces, RBAC and workloads
    ├── base
    └── overlays     #   per-cluster tenant presence (admin / dev / prod)
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
    `CiliumClusterwideNetworkPolicy`), `headlamp` (dashboard, **admin
    cluster only**), `external-secrets` (ESO → Vault), `cert-manager` +
    `cert-manager-issuers` (Let's Encrypt via Cloudflare DNS-01), `traefik`
    (ingress, ClusterIP-only for now), and `tailscale-operator` (API-server
    proxy in auth mode — see [Tailscale access](#tailscale-access-api-server-proxy)).
  - **Scaffolded stubs (V1, wired but minimal — see `# TODO` markers):**
    `kube-prometheus-stack`, `netdata`, `vector`. These reconcile to
    minimal installs; cluster-specific config (remote-write, Humio sink) is
    left to fill in.

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
(`overlays/admin` / `overlays/dev` / `overlays/prod`) build on, keeping
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
  `netdata`, `vector`, `headlamp` on admin) reconciles independently

Reach the Policy Reporter UI with a port-forward (no Ingress configured yet):

```bash
kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080
# then open http://localhost:8082
```

> **Note:** The cluster CNI (Cilium) and its Hubble observability layer are
> managed out-of-band via Terraform, not by this repository.

## Tailscale access (API-server proxy)

Cluster access runs through the Tailscale operator's API-server proxy in
**auth mode**: the proxy authenticates your tailnet identity and impersonates
it against the Kubernetes API, so standard RBAC applies and the audit trail
carries your real login. No per-user kubeconfig secrets, no public API
endpoints.

- Each cluster's operator device is the API endpoint:
  `k8s-api-admin` / `k8s-api-dev` / `k8s-api-prod` (hostname patched per
  cluster in `platform/overlays/<cluster>/tailscale-operator/`).
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
tailscale configure kubeconfig k8s-api-dev
kubectl auth whoami                      # tailnet login + group `maintainers`
kubectl auth can-i delete pods -A        # yes
kubectl auth can-i get secrets -A        # no
```

## Bootstrap

Run once per cluster to install Flux and point it at that cluster's path. Set
your `kubectl` context to the target cluster first, and export a GitHub PAT with
`repo` scope:

```bash
export GITHUB_TOKEN=<your-pat>
```

```bash
# admin
kubectl config use-context <admin-context>
flux bootstrap github \
  --owner=lucas2kdk \
  --repository=kubernetes \
  --branch=main \
  --path=clusters/admin \
  --personal

# dev
kubectl config use-context <dev-context>
flux bootstrap github \
  --owner=lucas2kdk \
  --repository=kubernetes \
  --branch=main \
  --path=clusters/dev \
  --personal

# prod
kubectl config use-context <prod-context>
flux bootstrap github \
  --owner=lucas2kdk \
  --repository=kubernetes \
  --branch=main \
  --path=clusters/prod \
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
