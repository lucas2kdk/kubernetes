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
│   ├── admin
│   ├── dev
│   └── prod
├── policies         # Guardrails enforced across tenants (Kyverno)
│   ├── base
│   ├── admin
│   ├── dev
│   └── prod
└── tenants          # Per-tenant namespaces, RBAC and workloads
    ├── base
    ├── admin
    ├── dev
    └── prod
```

- **clusters/** — the per-cluster reconciliation entry points. Each cluster's
  folder holds the Flux `Kustomization` objects that point at the `policies` and
  `tenants` overlays for that environment.
- **policies/** — guardrails applied to tenant namespaces. `base/kyverno`
  installs the Kyverno controller (Helm), `base/policies` holds the
  `ClusterPolicy` set (starting with the flux-multi-tenancy guardrail that blocks
  cross-namespace source references), and `base/policy-reporter` installs
  [Policy Reporter](https://kyverno.github.io/policy-reporter/) with its web UI
  for browsing results. Every cluster runs Kyverno.
- **tenants/** — tenant definitions (namespaces, service accounts, RBAC and the
  Flux sources/Kustomizations each tenant manages).

`base` directories are Kustomize bases that the per-cluster overlays
(`admin` / `dev` / `prod`) build on, keeping environment-specific configuration
out of the shared definitions.

### Reconcile order

Per cluster, Flux applies two Kustomizations:

1. `kyverno` → the Kyverno controller and CRDs
2. `kyverno-policies` → the `ClusterPolicy` resources (`dependsOn: kyverno`, so
   they only apply once the CRDs exist)
3. `policy-reporter` → Policy Reporter + UI (`dependsOn: kyverno`)

Reach the Policy Reporter UI with a port-forward (no Ingress configured yet):

```bash
kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080
# then open http://localhost:8082
```

> **Note:** The cluster CNI (Cilium) and its Hubble observability layer are
> managed out-of-band via Terraform, not by this repository.

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
