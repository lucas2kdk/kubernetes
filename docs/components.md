# Platform components

A catalog of every platform component Flux installs in the fleet. Each lives as
a Kustomize base under `platform/base/<component>/` and is reconciled by a Flux
`Kustomization` under `platform/fleet/<component>.yaml` (the reconcile graph,
defined once for the whole fleet). The shared `Kustomization` spec defaults
(`interval: 1h`, `retryInterval: 2m`, `timeout: 5m`, `prune: true`, `wait: true`,
`sourceRef: GitRepository/flux-system`) are patched onto every fleet file from
`platform/fleet/_defaults.yaml`, so the per-component files declare only what
differs.

For the architecture, the per-cluster opt-in model and the reconcile-order
rationale, see [architecture](architecture.md) and the top-level
[README](../README.md). Deep dives live in the dedicated docs:
[networking](networking.md), [policies](policies.md),
[secrets-and-identity](secrets-and-identity.md), [monitoring](monitoring.md).

> **Note on per-cluster variation:** per-cluster *values* (e.g. `${cluster_name}`,
> `${tailnet}`) are substituted in-cluster via `postBuild.substituteFrom`
> (`cluster-vars` per cluster, `fleet-vars` fleet-wide). Per-cluster *structure*
> gets an overlay plus its own per-cluster Flux `Kustomization` — today the only
> one is `external-secrets-stores` on `test-home`.

## Summary

| Component | Purpose | Chart / version | Namespace | dependsOn | Access |
|---|---|---|---|---|---|
| [kyverno](#kyverno) | Admission/policy engine | `kyverno` `3.8.1` (kyverno.github.io) | `kyverno` | kube-prometheus-stack | — (webhook) |
| [policies](#policies) | The `ClusterPolicy` guardrail set | plain manifests | cluster-scoped | kyverno (`kyverno-policies`) | — |
| [policy-reporter](#policy-reporter) | Kyverno PolicyReport UI | `policy-reporter` `3.7.4` | `policy-reporter` | kyverno | port-forward `svc/policy-reporter-ui` |
| [network](#network) | Cilium cluster-wide default-deny | plain manifests | cluster-scoped (`network-policies`) | — (Cilium CRDs via Terraform) | — |
| [trivy-operator](#trivy-operator) | CIS benchmark + vuln/config/RBAC scans | `trivy-operator` `0.33.1` (aqua) | `trivy-system` | kube-prometheus-stack | report CRDs / Headlamp plugin |
| [external-secrets](#external-secrets) | ESO controller (→ Vault) | `external-secrets` `2.6.0` | `external-secrets` | — | — |
| [external-secrets-stores](#external-secrets-stores) | Vault `ClusterSecretStore` | plain manifest | cluster-scoped | external-secrets | — |
| [cert-manager](#cert-manager) | ACME cert controller | `cert-manager` `v1.20.2` (jetstack) | `cert-manager` | kube-prometheus-stack | — |
| [cert-manager-issuers](#cert-manager-issuers) | Let's Encrypt `ClusterIssuer`s (DNS-01) | plain manifests | `cert-manager` | cert-manager, external-secrets-stores | — |
| [traefik](#traefik) | Ingress controller (ClusterIP) | `traefik` `40.3.0` | `traefik` | cert-manager | in-cluster / port-forward |
| [tailscale-operator](#tailscale-operator) | API-server proxy (auth mode) + tailnet ingress | `tailscale-operator` `1.98.4` | `tailscale` | external-secrets-stores | tailnet `k8s-api-<cluster>` |
| [tsidp](#tsidp) | Tailscale OIDC identity provider | plain Deployment (`ghcr.io/tailscale/tsidp:v0.0.14`) | `tsidp` | external-secrets-stores | tailnet Funnel `idp.<tailnet>.ts.net` |
| [headlamp](#headlamp) | Kubernetes dashboard | `headlamp` `0.42.0` | `headlamp` | external-secrets-stores | tailnet `https://headlamp.<tailnet>.ts.net` |
| [kube-prometheus-stack](#kube-prometheus-stack) | Prometheus + Grafana + operator CRDs | `kube-prometheus-stack` `86.2.2` | `monitoring` | — | tailnet `https://grafana.<tailnet>.ts.net` |
| [monitoring-extras](#monitoring-extras) | Flux/Longhorn monitors (post-CRD) | plain manifests (reused) | `flux-system` / `longhorn-system` | kube-prometheus-stack | — |
| [capacitor](#capacitor) | Flux GitOps dashboard UI | OCI `ghcr.io/gimlet-io/capacitor-manifests` (`>=0.1.0`) | `flux-system` | — | — |

Every platform namespace carries `platform.io/managed: "true"` (exempts it from
the tenant-facing Kyverno policies). Cilium default-deny exemption is *not*
automatic — see the [networking](networking.md) doc and the README's "Platform
namespace convention".

### Scaffolded stubs

The README references `netdata` and `vector` as scaffolded stubs. **Neither base
directory currently exists** under `platform/base/`, and neither has a fleet
`Kustomization`, so Flux does not reconcile them. Every base directory present
today has a matching fleet entry, except the two that are intentionally split
out and reconciled via `dependsOn` rather than a separate base (none are
orphaned). To enable a future stub, add `platform/base/<name>/`,
`platform/fleet/<name>.yaml`, list it in `platform/fleet/kustomization.yaml`, and
ensure each cluster's `kustomization.yaml` includes it.

---

## kyverno

The admission/policy engine. The HelmRelease installs and owns the Kyverno CRDs
and the four controllers (admission, background, cleanup, reports); the
`ClusterPolicy` set is applied separately by the [policies](#policies) component.

- **Chart:** `kyverno` `3.8.1` from `HelmRepository kyverno`
  (`https://kyverno.github.io/kyverno/`). CRDs `Create` on install,
  `CreateReplace` on upgrade.
- **Namespace:** `kyverno`.
- **Fleet:** `platform/fleet/kyverno.yaml`, `dependsOn: kube-prometheus-stack`
  (it ships per-controller ServiceMonitors that need the Prometheus-Operator
  CRDs). Roots `kyverno-policies` and `policy-reporter`, which both `dependsOn`
  it.
- **Key config decisions (with rationale):**
  - **Memory limits 512Mi (req 128Mi) on background/cleanup/reports
    controllers.** The chart-default 128Mi limit is smaller than the ~120MB
    Kyverno binary, so the kernel satisfies the limit by evicting the
    controller's own executable page cache and re-reading it from disk forever —
    no OOM kill, just `memory.events:max` in the millions. On **2026-06-12** the
    background + reports controllers read ~3TB this way, pinning the HDD system
    disk at 100% util, stalling etcd, and causing apiserver brownouts → CSI/PVC
    failures. Limits must stay comfortably above binary size + heap.
  - **`forceFailurePolicyIgnore: enabled`.** Fail-closed webhooks assume the
    admission controller outlives any one node — impossible on a single-node
    cluster, where every drain evicts Kyverno and its webhook then rejects
    kubelet's final pod deletions, deadlocking the drain (hit **2026-06-11**
    during a Talos upgrade). Force `Ignore` so node lifecycle never depends on
    Kyverno being up. When the cluster grows to 3+ nodes, drop this and set
    `admissionController.replicas: 3` to regain fail-closed enforcement without
    the deadlock.
  - **Webhook `namespaceSelector` `NotIn` `kube-system`, `longhorn-system`.**
    Longhorn recommends keeping policy engines out of its namespace so volume
    attach/rebuild is never gated on them.
  - **Pinned Helm-test readiness-checker image** (`ghcr.io/kyverno/readiness-checker:v1.18.1`)
    so the mutable `:latest` default isn't a moving target for the image CVE scan.

## policies

The Kyverno `ClusterPolicy` set — the tenant-facing guardrails. Plain manifests
(no Helm), reconciled from `platform/base/policies/`.

- **Namespace:** cluster-scoped (`ClusterPolicy`).
- **Fleet:** `platform/fleet/kyverno-policies.yaml`, `dependsOn: kyverno` (CRDs +
  webhook must exist first).
- **The set:** `flux-multi-tenancy` (the cross-namespace sourceRef guardrail,
  **Enforce**), `pod-security-baseline`, `pod-security-restricted`,
  `disallow-default-namespace`, `require-resource-requests`, `disallow-latest-tag`,
  `require-pod-probes` (Tier-1 baseline, rolled out **Audit** until reports are
  clean, promote per-environment), plus `generate-baseline-netpol` +
  `kyverno:manage-ciliumnetworkpolicies` RBAC (generates a baseline
  same-namespace + DNS `CiliumNetworkPolicy` for each tenant namespace under the
  default-deny).
- See [policies](policies.md) for per-policy detail, the `platform.io/managed`
  exemptions, and the `longhorn-system` exclusion guard.

## policy-reporter

Turns Kyverno's `PolicyReport` CRDs into a queryable web UI — where the
Audit-mode policies surface findings before promotion to Enforce.

- **Chart:** `policy-reporter` `3.7.4` from `HelmRepository policy-reporter`
  (`https://kyverno.github.io/policy-reporter`). `ui.enabled: true`,
  `plugin.kyverno.enabled: true`.
- **Namespace:** `policy-reporter`.
- **Fleet:** `platform/fleet/policy-reporter.yaml`, `dependsOn: kyverno`.
- **Access:** no Ingress yet — port-forward:
  `kubectl -n policy-reporter port-forward svc/policy-reporter-ui 8082:8080`.

## network

Cilium cluster-wide network policy base. `default-deny` is the foundation; the
`allow-*` policies are additive grants; `deny-cloud-metadata` is an anti-SSRF
guard. Plain manifests (`CiliumClusterwideNetworkPolicy`).

- **Namespace:** cluster-scoped.
- **Fleet:** `platform/fleet/network-policies.yaml` — a reconcile **root** (no
  `dependsOn`), but it needs the Cilium CRDs, which Terraform installs
  out-of-band (Cilium is not managed by this repo).
- **Files:** `default-deny.yaml`, `deny-cloud-metadata.yaml`,
  `allow-ingress-from-traefik.yaml`, `allow-ingress-from-monitoring.yaml`. All
  scope to workload namespaces via a shared `NotIn` exclusion list; three of
  them plus the Kyverno `generate-baseline-netpol` `names:` list must stay in
  lockstep (drift guard: `scripts/check-namespace-lists.sh`).
- See [networking](networking.md) for the exclusion lists and the 2026-06-12
  `longhorn-system` CSI outage rationale.

## trivy-operator

On-cluster security scanning: weekly CIS Kubernetes Benchmark
(`ClusterComplianceReport`) plus vulnerability, config-audit and RBAC assessments
of what's actually running (`VulnerabilityReport`, `ConfigAuditReport`,
`RbacAssessmentReport`). Pairs with `scripts/image-scan.sh`, which scans images
in Git before they're applied — the operator catches drift between desired state
and runtime reality.

- **Chart:** `trivy-operator` `0.33.1` from `HelmRepository aqua`
  (`https://aquasecurity.github.io/helm-charts/`). CRDs `Create`/`CreateReplace`.
- **Namespace:** `trivy-system`.
- **Fleet:** `platform/fleet/trivy-operator.yaml`,
  `dependsOn: kube-prometheus-stack` (ships a ServiceMonitor).
- **Key config:** `compliance.cron: "0 6 * * 1"` (weekly CIS, Monday 06:00 UTC —
  matches the image-scan cadence); all four scanners enabled explicitly;
  `trivy.ignoreUnfixed: true` (flag only criticals a version bump can resolve).
- **Access:** the report CRDs; `rbac.yaml` widens `view` to the cluster-scoped
  reports so the Headlamp trivy plugin and the tailnet `maintainers` group can
  read them.

## external-secrets

External Secrets Operator (ESO) — the controller that reconciles
`ExternalSecret` CRs against HashiCorp Vault. The `ClusterSecretStore` itself is
split into the sibling [external-secrets-stores](#external-secrets-stores)
component so it only applies after this HelmRelease has installed its CRDs.

- **Chart:** `external-secrets` `2.6.0` from `HelmRepository external-secrets`
  (`https://charts.external-secrets.io`). `installCRDs: true`,
  CRDs `CreateReplace`.
- **Namespace:** `external-secrets`.
- **Fleet:** `platform/fleet/external-secrets.yaml` — a reconcile **root** (no
  `dependsOn`); installs the ESO controller + CRDs that every Vault-backed
  consumer builds on.
- **Note:** chart `2.6.0` still serves `external-secrets.io/v1`. The `2.x` line
  drops `v1beta1`; the remaining `v1beta1` manifests must be migrated before that
  bump. Includes `rbac-token-review.yaml` (grants ESO `system:auth-delegator` so
  Vault's TokenReview callback succeeds) plus PDBs for the controller and webhook.

## external-secrets-stores

The Vault `ClusterSecretStore` named `vault` — the gate every Vault-synced
secret waits on. Plain manifest, split from `external-secrets` because the
`ClusterSecretStore` CR can't be applied until the ESO CRD exists.

- **Namespace:** cluster-scoped.
- **Fleet:** `platform/fleet/external-secrets-stores.yaml`,
  `dependsOn: external-secrets`. Carries
  `postBuild.substituteFrom: ConfigMap/cluster-vars` for the `${cluster_name}`
  token.
- **Config:** points at `https://vault.rosenvold.tech`, KV-v2 under `secret/`.
  Auth is Vault's per-cluster `kubernetes` backend at `mountPath:
  kubernetes/${cluster_name}`, role `eso-platform`, using the
  `external-secrets` ServiceAccount.
- **Overlay:** `test-home`'s home-LAN apiserver isn't reachable for Vault's
  TokenReview callback, so `platform/overlays/test-home/external-secrets-stores`
  swaps the `kubernetes` auth block for `appRole`. test-home reconciles that
  overlay via its own `clusters/test-home/external-secrets-stores.yaml`
  (a Flux `Kustomization`'s `spec.path` can't be substituted).
- See [secrets-and-identity](secrets-and-identity.md) for the Vault layout and
  per-secret paths.

## cert-manager

The ACME certificate controller. The Let's Encrypt `ClusterIssuer`s and the
ESO-synced Cloudflare token are deliberately **not** here — they form the
separate [cert-manager-issuers](#cert-manager-issuers) component.

- **Chart:** `cert-manager` `v1.20.2` from `HelmRepository cert-manager`
  (`https://charts.jetstack.io`). `crds.enabled: true`.
- **Namespace:** `cert-manager` (also the cluster-resource-namespace where
  `ClusterIssuer` secret refs resolve).
- **Fleet:** `platform/fleet/cert-manager.yaml`,
  `dependsOn: kube-prometheus-stack` (ships a ServiceMonitor for `:9402`,
  feeding the cert-manager dashboard). Roots the issuers; prerequisite for
  Traefik.

## cert-manager-issuers

The Let's Encrypt `ClusterIssuer`s (Cloudflare DNS-01) plus the ESO-synced
Cloudflare API token. Plain manifests.

- **Namespace:** `cert-manager` (`ClusterIssuer` secret refs resolve in
  cert-manager's cluster-resource-namespace).
- **Fleet:** `platform/fleet/cert-manager-issuers.yaml`,
  `dependsOn: [cert-manager, external-secrets-stores]`. The cert-manager
  dependency + `wait: true` means it only reads Ready once issuers register with
  ACME; external-secrets-stores must exist before the Cloudflare token
  `ExternalSecret` can resolve.
- **Files:** `issuer-production.yaml`, `issuer-test.yaml`, `external-secret.yaml`.
- **Secret:** `cloudflare-api-token` `ExternalSecret` → Vault
  `secret/platform/cloudflare` (property `api-token`), the Zone/DNS/Edit +
  Zone/Read token the DNS-01 solver uses.

## traefik

Ingress controller. ClusterIP-only today — bare metal with no LB story yet.

- **Chart:** `traefik` `40.3.0` from `HelmRepository traefik`
  (`https://traefik.github.io/charts`).
- **Namespace:** `traefik`.
- **Fleet:** `platform/fleet/traefik.yaml`, `dependsOn: cert-manager` (for the
  eventual TLS story).
- **Key config:** `service.spec.type: ClusterIP` (reachable in-cluster or via
  port-forward; LB-IPAM / Gateway API exposure is a later phase). `web` →
  `websecure` permanent HTTPS redirect. No default TLS cert yet (self-signed
  fallback); `kubernetesGateway` stays disabled — Cilium owns Gateway API.
- **Note:** Headlamp and Grafana are reached over the **tailnet**, not through
  Traefik.

## tailscale-operator

The Tailscale operator running the Kubernetes API-server proxy in **auth mode**,
and providing the `tailscale` IngressClass used by Headlamp and Grafana.

- **Chart:** `tailscale-operator` `1.98.4` from `HelmRepository tailscale`
  (`https://pkgs.tailscale.com/helmcharts`).
- **Namespace:** `tailscale`.
- **Fleet:** `platform/fleet/tailscale-operator.yaml`,
  `dependsOn: external-secrets-stores` (reads OAuth creds from Vault). Carries
  `postBuild.substituteFrom: ConfigMap/cluster-vars` for the hostname token.
- **Key config:** API-server proxy `mode: "true"` + `allowImpersonation: "true"`
  (proxy impersonates the tailnet identity against the Kubernetes API, so
  standard RBAC applies — the operator device *is* the API endpoint). Operator
  `defaultTags: [tag:k8s-operator]`, `hostname: k8s-api-${cluster_name}`.
- **Secret:** `operator-oauth` `ExternalSecret` → Vault
  `secret/platform/tailscale` (keys `client_id`, `client_secret`). The OAuth
  client needs Devices Core (write) + Auth Keys (write) and the
  `tag:k8s-operator` / `tag:k8s` tags. `oauth.clientId/clientSecret` are left
  unset so the chart references the pre-existing Secret.
- **RBAC:** `rbac-maintainers.yaml` binds the tailnet `maintainers` group to
  cluster-wide `view` plus curated operational verbs (no Secret read).
- **Access:** kubectl over the tailnet at `k8s-api-<cluster>`. See the README's
  "Tailscale access" section and the bootstrap repo's `docs/tailscale.md`.

## tsidp

The Tailscale OIDC identity provider (`github.com/tailscale/tsidp`) — the issuer
behind Headlamp and Grafana logins. A plain `Deployment` (no Helm chart) that
joins the tailnet as `idp.<tailnet>.ts.net` (`tag:tsidp`).

- **Image:** `ghcr.io/tailscale/tsidp:v0.0.14`.
- **Namespace:** `tsidp` (`pod-security.kubernetes.io/enforce: privileged` — it
  persists tailnet + OIDC-client state on a hostPath, no CSI on bare-metal Talos
  yet).
- **Fleet:** `platform/fleet/tsidp.yaml`, `dependsOn: external-secrets-stores`
  (auth key from Vault).
- **Key config:** `strategy: Recreate` (single tailnet identity, never two
  instances). **Funnel is on** (`TSIDP_USE_FUNNEL=1`) for one reason: the
  kube-apiserver validates OIDC tokens by fetching the issuer's discovery
  doc + JWKS, and the node has no tailnet access (operator-mode only, no host
  `tailscaled`) — Funnel makes those endpoints publicly reachable. Actual logins
  still require tailnet identity (resolved via `whois`, which Funnel traffic
  lacks). An init container chowns the hostPath state dir to uid 1001 before
  start. State is lost only on cluster rebuild (re-register OIDC clients then).
- **Secret:** `tsidp-auth` `ExternalSecret` → Vault `secret/platform/tsidp`
  (property `client_secret`), templated into `TS_AUTHKEY` with
  `?ephemeral=false&preauthorized=true`.

## headlamp

The Kubernetes dashboard. Reached over the tailnet only; logins go through tsidp
OIDC with group-based RBAC.

- **Chart:** `headlamp` `0.42.0` from `HelmRepository headlamp`
  (`https://kubernetes-sigs.github.io/headlamp/`).
- **Namespace:** `headlamp`.
- **Fleet:** `platform/fleet/headlamp.yaml`, `dependsOn: external-secrets-stores`
  (OIDC client secret from Vault). Carries
  `postBuild.substituteFrom: ConfigMap/fleet-vars` for `${tailnet}`.
- **Key config:**
  - **OIDC** issuer `https://idp.${tailnet}.ts.net` (tsidp), scopes
    `openid,email,profile`; client id/secret wired via `valuesFrom` (the
    `headlamp-oidc` Secret). The kube-apiserver trusts the issuer via the
    `oidc-*` flags in the Talos machine config.
  - **`watchPlugins: true`** fixes a race: the plugin manager runs as a sidecar
    (~12s to download plugins) while the backend scans `pluginsDir` once at
    startup, so without re-reading the dir the freshly-installed plugins never
    appear. Plugins (flux `0.6.0`, cert-manager `0.1.1`) are pinned and fetched
    from Artifact Hub at pod start; the trivy plugin
    (`ghcr.io/kubebeam/trivy-headlamp-plugin:v0.3.2`) ships as an OCI image
    copied in by an init container.
  - **Multi-cluster picker:** `KUBECONFIG=/kubeconfigs/test-home` joins admin
    kubeconfigs synced from Vault (`headlamp-kubeconfigs`); the local cluster
    stays on the in-cluster ServiceAccount + OIDC RBAC.
- **Secrets:** `headlamp-oidc` → Vault `secret/platform/headlamp-oidc`
  (`client_id`, `client_secret`); `headlamp-kubeconfigs` (per-cluster admin
  kubeconfigs, materialized one file per cluster).
- **Access:** Tailscale Ingress (`ingressClassName: tailscale`) — no Traefik
  route, no cert-manager cert, no public DNS:
  `https://headlamp.<tailnet>.ts.net`. RBAC via `rbac-oidc.yaml`.

## kube-prometheus-stack

Prometheus + Grafana for the fleet. This release also owns the
Prometheus-Operator CRDs (`ServiceMonitor`/`PodMonitor`/`PrometheusRule`), so it
is a reconcile **root** that every monitor-shipping component `dependsOn`
(kyverno, cert-manager, trivy-operator, monitoring-extras).

- **Chart:** `kube-prometheus-stack` `86.2.2` from `HelmRepository
  prometheus-community` (`https://prometheus-community.github.io/helm-charts`).
  CRDs `CreateReplace` on both install/upgrade so chart bumps pick up CRD schema
  changes.
- **Namespace:** `monitoring`
  (`pod-security.kubernetes.io/enforce: privileged` — node-exporter needs
  hostNetwork/hostPID/hostPath/hostPort, which Talos baseline rejects).
- **Fleet:** `platform/fleet/kube-prometheus-stack.yaml` — root, with
  `postBuild.substituteFrom: ConfigMap/fleet-vars` for `${tailnet}` (Grafana
  `root_url` + OIDC URLs).
- **Key config (with rationale):**
  - **Prometheus TSDB bounded & self-pruning:** `retention: 30d`,
    `retentionSize: "85GiB"` on a 100Gi Longhorn PVC — `retentionSize` trims
    oldest blocks once the data dir exceeds 85GiB, kept under the 100Gi PVC so
    WAL/compaction has headroom; whichever ceiling hits first wins.
  - **`*SelectorNilUsesHelmValues: false`** for service/pod/probe/rule monitors —
    discover monitors and `PrometheusRule`s across **all** namespaces (the
    cert-manager/kyverno/flux/longhorn scrapers and the repo's platform alert
    rules), not just chart-labelled ones.
  - **Grafana:** 2Gi Longhorn PVC (SQLite state only — datasources + dashboards
    are provisioned). Reached only over the tailnet; native login form disabled,
    `oauth_auto_login: true`, OIDC against tsidp (`groups` is **not** requested
    as a scope — tsidp rejects it as `invalid_scope`; the group claim is injected
    via a cap grant regardless). Role mapping:
    `contains(groups[*], 'k8s-admins') && 'Admin' || 'Viewer'`. The dashboard
    sidecar loads ConfigMaps labelled `grafana_dashboard=1` from `monitoring`
    (committed dashboards under `dashboards/`: Kubernetes, Flux, cert-manager,
    Kyverno, Longhorn). Those ConfigMaps are exempted from Flux envsubst
    (`kustomize.toolkit.fluxcd.io/substitute: disabled`) because their literal
    `${...}` Grafana template tokens would break post-build substitution.
- **Secret:** `grafana-oidc` `ExternalSecret` → Vault
  `secret/platform/grafana-oidc` (`client_id`, `client_secret`), wired via
  `envValueFrom`.
- **Bundled monitors here:** `flux-podmonitor.yaml`,
  `longhorn-servicemonitor.yaml` files live in this base but are *not* applied by
  it — they're reused by [monitoring-extras](#monitoring-extras) so they apply
  after the CRDs exist.
- **Access:** Tailscale Ingress `https://grafana.<tailnet>.ts.net`.
- See [monitoring](monitoring.md) for dashboards, alerting and ServiceMonitors.

## monitoring-extras

Monitors for subsystems that don't ship their own (the Flux controllers and
Longhorn). Kept separate from kube-prometheus-stack so its fleet Kustomization
can `dependsOn` the operator and only apply these `ServiceMonitor`/`PodMonitor`
CRs **after** the CRDs exist — applying them alongside the CRD-installing
HelmRelease would race the CRDs.

- **Namespaces:** the `PodMonitor` lands in `flux-system` (scrapes the Flux
  controllers on the `http-prom` port for the Flux2 dashboard); the
  `ServiceMonitor` lands in `longhorn-system` (scrapes `longhorn-manager` on the
  `manager` port — requires the `longhorn-system` default-deny exemption).
- **Fleet:** `platform/fleet/monitoring-extras.yaml`,
  `dependsOn: kube-prometheus-stack`.
- **Files:** reused (not copied) from the kube-prometheus-stack base via
  relative paths (`../kube-prometheus-stack/flux-podmonitor.yaml`,
  `../kube-prometheus-stack/longhorn-servicemonitor.yaml`).
- The 2026-06-13 Alertmanager Discord routing + platform alert `PrometheusRule`s
  feed in here via the cluster-wide `ruleSelector`. See [monitoring](monitoring.md).

## capacitor

The Flux GitOps dashboard UI (gimlet-io) — a read-only web view of the cluster's
Flux objects (Kustomizations, HelmReleases, sources) and their reconcile status,
useful for debugging the fleet's `dependsOn` graph.

- **Source:** **self-managing**, not a HelmRelease. An `OCIRepository`
  (`oci://ghcr.io/gimlet-io/capacitor-manifests`, `ref.semver: ">=0.1.0"`)
  feeds a nested Flux `Kustomization` (`path: "./"`) that reconciles the upstream
  OCI-packaged manifests into `flux-system`.
- **Namespace:** `flux-system`.
- **Fleet:** `platform/fleet/capacitor.yaml` — a reconcile root (no `dependsOn`).
