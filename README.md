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
├── infrastructure   # Cluster add-ons (Cilium + Hubble)
│   ├── base
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
  folder holds the Flux `Kustomization` objects that point at the
  `infrastructure`, `policies` and `tenants` overlays for that environment.
- **infrastructure/** — cluster-wide add-ons. `base/cilium` installs Cilium with
  Hubble (relay + UI) enabled for network observability, delivered as a Flux
  `HelmRelease`. Every cluster reconciles it.
- **policies/** — guardrails applied to tenant namespaces. `base/kyverno`
  installs the Kyverno controller (Helm) and `base/policies` holds the
  `ClusterPolicy` set (starting with the flux-multi-tenancy guardrail that blocks
  cross-namespace source references). Every cluster runs Kyverno.
- **tenants/** — tenant definitions (namespaces, service accounts, RBAC and the
  Flux sources/Kustomizations each tenant manages).

`base` directories are Kustomize bases that the per-cluster overlays
(`admin` / `dev` / `prod`) build on, keeping environment-specific configuration
out of the shared definitions.

### Reconcile order

Per cluster, Flux applies three Kustomizations:

1. `infrastructure` → Cilium + Hubble
2. `kyverno` → the Kyverno controller and CRDs
3. `kyverno-policies` → the `ClusterPolicy` resources (`dependsOn: kyverno`, so
   they only apply once the CRDs exist)

> **Note:** Cilium is the cluster CNI. On a brand-new cluster it is normally
> installed at bootstrap time; reconciling it through Flux assumes the cluster
> already has enough connectivity for the helm-controller to run.

## Reference

- [Flux multi-tenancy guide](https://github.com/fluxcd/flux2-multi-tenancy)
- [Flux documentation](https://fluxcd.io/flux/)
