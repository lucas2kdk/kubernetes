# Kyverno policy reference

The admission policies that constrain tenant workloads, how each one is scoped
and excluded, and how the policy unit tests keep them honest.

See also: [architecture](architecture.md) · [operations](operations.md) ·
[components](components.md) · [networking](networking.md) ·
[top-level README](../README.md).

## Kyverno as admission controller

[Kyverno](https://kyverno.io/) runs as the cluster's admission controller. The
`ClusterPolicy` set lives in [`platform/base/policies/`](../platform/base/policies/)
and is reconciled by the `kyverno-policies` fleet `Kustomization`, which
`dependsOn: kyverno` so the CRDs and the admission webhook exist before any
policy is applied.

**`forceFailurePolicyIgnore`.** Kyverno's install is configured to force the
webhook failure policy to `Ignore` rather than `Fail`. The rationale is a
single-node drain deadlock: on a one-node cluster (and during maintenance on
small clusters), draining the node evicts the Kyverno pods; with a `Fail`
policy, the now-unreachable webhook would then reject the very pods Kubernetes
needs to *reschedule* Kyverno, deadlocking the node. `Ignore` lets admission
proceed when the webhook is down, trading a brief enforcement gap for the
ability to recover. See [components](components.md) for the HelmRelease install
detail.

## The exclusion model

Platform components run privileged, cluster-level workloads and are exempt from
the tenant-facing guardrails. Two mechanisms, used together:

- **Label selector** — `namespaceSelector: matchLabels: platform.io/managed:
  "true"`. Every platform namespace carries this label on its
  `platform/base/<component>/namespace.yaml`, so labelling a new namespace is
  usually enough.
- **Explicit static lists** — the four non-repo-managed namespaces
  (`kube-system`, `kube-node-lease`, `kube-public`, `flux-system`) have no
  `namespace.yaml` here to label, so they stay enumerated by name.
  `flux-multi-tenancy` adds only `flux-system` explicitly (it has no need for
  the system namespaces); the pod policies enumerate all four.

One policy can't use the label selector at all: `generate-baseline-netpol`
matches on the `Namespace` *kind*, so it keeps a fully explicit `names:` list —
this is list #4 of the [four-list lockstep](networking.md#the-four-list-lockstep).

### Kyverno is not the only Pod Security enforcer

There are **two independent Pod Security layers**, and `platform.io/managed`
exempts a namespace from only the first:

1. **Kyverno** `pod-security-baseline` / `pod-security-restricted` (this repo) —
   exempted by the `platform.io/managed: "true"` label.
2. **Kubernetes' built-in Pod Security Admission** — the cluster-default enforce
   level is `baseline`, set in the Talos apiserver config (out of band from this
   repo). PSA ignores `platform.io/managed` entirely; the only way to relax it on
   a namespace is the **`pod-security.kubernetes.io/enforce`** label on that
   namespace.

So a platform namespace whose workloads need privileged pod features (hostPID,
hostPath, host namespaces) needs **both** labels — `platform.io/managed: "true"`
*and* `pod-security.kubernetes.io/enforce: privileged`. Setting only the former
gets a built-in PSA denial that looks like
`violates PodSecurity "baseline:latest": host namespaces (hostPID=true), ...`
(note: the `"baseline:latest"` wording is built-in PSA, not a Kyverno policy).
The namespaces that carry the `privileged` override today are `monitoring`,
`tsidp`, `tailscale` and `trivy-system` (its `node-collector` runs the CIS
benchmark privileged — it was missing the label until then).

## The policies

| Policy (`metadata.name`) | File | Action | Validates / generates | Exclusions |
|--------------------------|------|--------|-----------------------|------------|
| `flux-multi-tenancy` | [flux-multi-tenancy.yaml](../platform/base/policies/flux-multi-tenancy.yaml) | **Enforce** | Tenant isolation for Flux objects: every `Kustomization`/`HelmRelease` must set `.spec.serviceAccountName`, and a `sourceRef.namespace` (Kustomization) / `chart.spec.sourceRef.namespace` (HelmRelease) must equal the object's own namespace — blocking cross-namespace source references. | `platform.io/managed` label **+** explicit `flux-system` |
| `disallow-default-namespace` | [disallow-default-namespace.yaml](../platform/base/policies/disallow-default-namespace.yaml) | **Audit** | Denies Pods in the `default` namespace. | None — the rule only ever targets `default`, which is neither platform nor tenant |
| `disallow-latest-tag` | [disallow-latest-tag.yaml](../platform/base/policies/disallow-latest-tag.yaml) | **Audit** | Two rules: `require-image-tag` rejects an image with no tag (`*:*`); `validate-image-tag` rejects the mutable `:latest` (`!*:latest`). | `platform.io/managed` label **+** explicit `kube-system`, `kube-node-lease`, `kube-public`, `flux-system` |
| `generate-baseline-netpol` | [generate-baseline-netpol.yaml](../platform/base/policies/generate-baseline-netpol.yaml) | Generate (`generateExisting: true`, `synchronize: true`) | For every tenant namespace, generates a `CiliumNetworkPolicy` (`baseline-allow`) permitting same-namespace ingress/egress + DNS to CoreDNS, restoring the minimum a normal app needs under the Cilium default-deny. | Explicit `names:` list (list #4 of the lockstep), incl. `longhorn-system` |
| `kyverno:manage-ciliumnetworkpolicies` | [kyverno-cilium-rbac.yaml](../platform/base/policies/kyverno-cilium-rbac.yaml) | RBAC (`ClusterRole`) | Not a policy — grants Kyverno's background/admission controllers (via `rbac.kyverno.io/aggregate-to-*` labels) the verbs to create/manage `ciliumnetworkpolicies`, which `generate-baseline-netpol` needs. | n/a |
| `pod-security-baseline` | [pod-security-baseline.yaml](../platform/base/policies/pod-security-baseline.yaml) | **Enforce** | Enforces the PSS **baseline** profile via Kyverno's native `podSecurity` subrule (no privileged containers, host namespaces, hostPath/hostPort, dangerous capabilities; init/ephemeral covered). Promoted from Audit in #107. | `platform.io/managed` label **+** explicit system namespaces |
| `pod-security-restricted` | [pod-security-restricted.yaml](../platform/base/policies/pod-security-restricted.yaml) | **Enforce** | Enforces the PSS **restricted** profile (no privilege escalation, runAsNonRoot, seccomp required, drop all capabilities, safe volume types). Builds on baseline; promoted from Audit in #107. | `platform.io/managed` label **+** explicit system namespaces |
| `require-pod-probes` | [require-pod-probes.yaml](../platform/base/policies/require-pod-probes.yaml) | **Audit** | Requires `livenessProbe` and `readinessProbe` (`periodSeconds > 0`) on every container. | `platform.io/managed` label **+** explicit system namespaces |
| `require-resource-requests` | [require-requests.yaml](../platform/base/policies/require-requests.yaml) | **Audit** | Requires CPU **and** memory `resources.requests` on every container. Limits are intentionally not required (CPU limits cause throttling). | `platform.io/managed` label **+** explicit system namespaces |
| `add-seccomp-runtime-default` | [add-seccomp-runtime-default.yaml](../platform/base/policies/add-seccomp-runtime-default.yaml) | **Mutate** | Adds a pod-level `seccompProfile: RuntimeDefault` when the Pod sets none (`+()` add-anchor, so an explicit profile wins). Closes CIS 5.7.2. | Explicit `kube-system`, `kube-node-lease`, `kube-public`, `flux-system` **only** — platform namespaces are *included* (RuntimeDefault is safe for them and they hold most of the findings) |

Notes:

- **Enforce vs Audit.** `flux-multi-tenancy`, `pod-security-baseline` and
  `pod-security-restricted` are `Enforce` (they block admission); the two Pod
  Security Standards policies were promoted from Audit in #107 once all tenant
  workloads were compliant (MinIO and excalidraw got restricted-compliant
  securityContexts, the GitLab runner spawns restricted-compliant CI pods, and
  the root-on-:80 hello-world tenant was retired). The remaining Tier-1 policies
  (`disallow-default-namespace`, `disallow-latest-tag`, `require-pod-probes`,
  `require-resource-requests`) stay `Audit` — report-only, to be promoted
  per-environment once Policy Reporter shows clean. All `background: true`
  policies also evaluate *pre-existing* resources, surfacing standing violations
  rather than only catching them at admission.
- **Filename vs name.** `require-requests.yaml` defines the policy named
  `require-resource-requests` (the name used in test fixtures and reports).
- **Preconditions.** `flux-multi-tenancy`'s sourceRef rules carry preconditions
  that skip the check when `sourceRef.namespace` is empty (an unset namespace
  defaults to the object's own, which is compliant); the rules only fire when a
  namespace is explicitly set.

## Policy Reporter

Audit findings (and Enforce decisions) surface in
[Policy Reporter](https://kyverno.github.io/policy-reporter/). There is no
Ingress yet; reach the UI via port-forward:

```bash
kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080
# then open http://localhost:8082
```

See [components](components.md) and the
[README](../README.md#reconcile-order) for the install detail.

## Policy unit tests (`tests/policy/`)

`just policy` (→ [`scripts/policy-check.sh`](../scripts/policy-check.sh)) runs
three passes:

1. **Render** the manifests each cluster reconciles (walk the cluster's Flux
   `Kustomization` CRs and `kustomize build` each `spec.path` into one bundle),
   build a Namespace→labels `Values` file, and run `kyverno apply` — Enforce
   violations fail the build, Audit findings warn only.
2. **`kyverno test`** the fixtures in `tests/policy/`.
3. A **separate `longhorn-system` must-not-generate check** (below).

The fixtures exist because **the rendered GitOps tree has almost no in-scope
workloads**: every chart's pods are Helm-expanded at install time, and the only
source-tree Deployment (`tsidp`) sits in a platform-excluded namespace. So the
`kyverno apply` pass never actually exercises the tenant-governing rules. The
hand-written known-good/known-bad fixtures close that gap.

What the fixtures pin
([`tests/policy/kyverno-test.yaml`](../tests/policy/kyverno-test.yaml)):

| Fixture resource | Asserts |
|------------------|---------|
| `good-pod` | Passes every pod rule |
| `bad-pod` | Fails `validate-image-tag`, `pod-security-baseline`, `pod-security-restricted`, `require-probes`, `require-resource-requests` |
| `untagged-pod` | Fails `require-image-tag`, passes `validate-image-tag` |
| `excluded-pod` (in a `platform.io/managed` ns) | All pod rules **skip** — the regression guard for the namespaceSelector exclusion |
| `default-ns-pod` | Only `disallow-default-namespace` fires |
| `good-kustomization` / `good-helmrelease` | Pass `flux-multi-tenancy` SA + sourceRef rules |
| `bad-kustomization-nosa` | Fails the `serviceAccountName` rule |
| `bad-kustomization-xns` / `bad-helmrelease-xns` | Fail the cross-namespace `sourceRef` rules |
| `excluded-kustomization` (platform ns) | `flux-multi-tenancy` **skips** |
| `tenant-app` (Namespace) | `generate-baseline-netpol` generates the expected `CiliumNetworkPolicy` (asserted against [`generated-baseline-cnp.yaml`](../tests/policy/generated-baseline-cnp.yaml)) |

Supporting fixture files: `resources.yaml` (pods, namespaces),
`resources-flux.yaml` (Flux objects), `netpol-namespaces.yaml`,
`values.yaml` (the Namespace→labels map, since `kyverno test` does not read
labels off inline Namespace objects).

### The separate `longhorn-system` must-not-generate check

`kyverno test` has no "must **not** generate" result type, so the
`longhorn-system` exclusion on `generate-baseline-netpol` (the
[2026-06-12 CSI outage](networking.md#the-2026-06-12-longhorn-system-csi-outage)
guard) is checked separately in `policy-check.sh`: it runs `kyverno apply -o` on
`netpol-namespaces.yaml` and asserts the **positive** (the tenant namespace
`tenant-netpol` gets a baseline CNP) and the **negative** (nothing is generated
into `longhorn-system`). Either failing exits non-zero.

> **When you add or change a `ClusterPolicy`, update the matching fixture** in
> `tests/policy/` so its behaviour stays pinned — add the policy to the `Test`'s
> `policies:` list and the expected `results:`, and a new known-good/known-bad
> resource if the rule needs one.
