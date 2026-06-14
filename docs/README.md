# Documentation

This is a Flux multi-tenancy GitOps repository (based on
[fluxcd/flux2-multi-tenancy](https://github.com/fluxcd/flux2-multi-tenancy)) that
manages a Kubernetes fleet — **prod-fsn** (Hetzner Falkenstein, bare-metal Talos)
and **test-home** (a home-LAN test cluster running a subset) — from a single Git
repository. Terraform owns the infrastructure and CNI; Flux owns everything inside
Kubernetes. The reconcile graph is defined **once** for the whole fleet in
`platform/fleet/`, and each cluster is a thin folder that opts into the components
it runs.

> The [top-level README](../README.md) is the canonical quickstart — repo layout,
> bootstrap, reconcile, validation, and the Tailscale access model. These per-topic
> docs go deeper.

## Contents

| Doc | Covers |
|-----|--------|
| [architecture.md](architecture.md) | The fleet-repo model, the per-cluster variation rule (`cluster-vars` substitution vs overlay + per-cluster Kustomization), the full reconcile / `dependsOn` graph, prod-fsn vs test-home, and how to add a cluster or component. |
| [components.md](components.md) | The platform components Flux installs (Kyverno, ESO, cert-manager, Traefik, Tailscale operator, tsidp, Trivy, kube-prometheus-stack, …) and their bases. |
| [networking.md](networking.md) | The Cilium cluster-wide default-deny, the platform-namespace exclusion lists, ingress (Traefik / Tailscale), and the namespace drift guard. |
| [policies.md](policies.md) | The Kyverno `ClusterPolicy` set, the flux-multi-tenancy guardrail, pod-security rules, baseline NetworkPolicy generation, and the policy unit tests. |
| [secrets-and-identity.md](secrets-and-identity.md) | External Secrets Operator → Vault, the `ClusterSecretStore`, the Tailscale OIDC issuer (tsidp), and the Headlamp/Grafana login model. |
| [monitoring.md](monitoring.md) | kube-prometheus-stack, the bundled dashboards, ServiceMonitors/PodMonitors, and the Alertmanager routing + platform alert rules. |
| [operations.md](operations.md) | Day-2 operations — bootstrap, reconcile, the full `just check` gate (12 recipes), the two-tier PR pipeline, post-merge and drift-detection workflows, adding clusters/components, and access. |
| [testing-strategy.md](testing-strategy.md) | BDD/TDD test strategy — the full catalogue of 29 test cases (structural coherence, policy gaps, security, observability), their CI tier, implementation status, and the rot-prone patterns to avoid. |
| [tools.md](tools.md) | The local tooling (`just`, `kustomize`, `kubeconform`, `kyverno`, `gitleaks`, `trivy`, …) the validation recipes use. |

## How this fits together

```
clusters/<name>/            thin entry point — flux-system bootstrap,
  ├── kustomization.yaml       cluster-vars ConfigMap, the component list,
  ├── cluster-vars.yaml        and per-cluster Flux Kustomization CRs
  └── tenants.yaml
        │ references (never copies)
        ▼
platform/fleet/             the reconcile graph, defined ONCE for the fleet —
  └── <component>.yaml         one Flux Kustomization per component + dependsOn
        │ spec.path → 
        ▼
platform/base/<component>/  reusable Kustomize bases (namespace + HelmRepository
                               source + HelmRelease + extra manifests)
        ▲ structural diffs only
platform/overlays/<cluster>/<component>/

tenants/{base,overlays}/    per-tenant namespaces, RBAC and workloads,
                               reconciled per cluster via clusters/<name>/tenants.yaml
```

A cluster's `kustomization.yaml` selects which `platform/fleet/*.yaml` Flux
Kustomizations apply; those point at `platform/base/<component>` bases (with
`${var}` substitution from the cluster's `cluster-vars` / `fleet-vars` ConfigMaps);
`platform/overlays/` exists only for structural per-cluster differences. See
[architecture.md](architecture.md) for the full model and the dependency graph.
