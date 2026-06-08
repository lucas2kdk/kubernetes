# kubernetes

Flux multi-tenancy GitOps repository, based on the
[fluxcd/flux2-multi-tenancy](https://github.com/fluxcd/flux2-multi-tenancy)
example.

It manages three clusters — **admin**, **dev**, and **prod** — from a single
Git repository, with a platform admin defining the tenants and the policies that
constrain them.

## Repository structure

```
├── clusters      # Flux entry point per cluster
│   ├── admin
│   ├── dev
│   └── prod
├── policies      # Guardrails enforced across tenants
│   ├── base
│   ├── admin
│   ├── dev
│   └── prod
└── tenants       # Per-tenant namespaces, RBAC and workloads
    ├── base
    ├── admin
    ├── dev
    └── prod
```

- **clusters/** — the per-cluster reconciliation entry points. Each cluster's
  folder contains the Flux `Kustomization`/`GitRepository` objects that point at
  the `policies` and `tenants` overlays for that environment.
- **policies/** — guardrails applied to tenant namespaces (e.g. Kyverno or
  network policies). `base` holds the shared Kustomize base; `admin`, `dev` and
  `prod` overlay per-cluster differences.
- **tenants/** — tenant definitions (namespaces, service accounts, RBAC and the
  Flux sources/Kustomizations each tenant manages). `base` is the shared base;
  the environment folders overlay it.

`base` directories are Kustomize bases that the per-cluster overlays
(`admin` / `dev` / `prod`) build on, keeping environment-specific configuration
out of the shared definitions.

## Reference

- [Flux multi-tenancy guide](https://github.com/fluxcd/flux2-multi-tenancy)
- [Flux documentation](https://fluxcd.io/flux/)
