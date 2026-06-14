# Secrets and identity

How the fleet pulls secrets out of HashiCorp Vault, issues TLS certificates, and
authenticates humans into the clusters. The two halves are coupled: every
human-facing entry point (kubectl, Headlamp, Grafana) rides Tailscale identity,
and every workload secret is synced from Vault by the External Secrets Operator.

See also: [architecture](architecture.md) (the reconcile graph and the
per-cluster variation rule), [components](components.md) (the full component
list), [operations](operations.md) (bootstrap / reconcile / access), and the
[top-level README](../README.md) (the canonical Tailscale access model and ACL).

## External Secrets Operator → Vault

The External Secrets Operator (ESO) is the controller that reconciles
`ExternalSecret` custom resources by reading from Vault and writing native
Kubernetes `Secret`s. It is a reconcile root in the fleet graph (no `dependsOn`);
its base is `platform/base/external-secrets/` (HelmRelease, chart
`external-secrets` `2.6.0`, namespace `external-secrets`).

> **CRD/API note.** The chart is pinned to `2.6.0` on purpose: it still serves
> `external-secrets.io/v1`. The 2.x line drops `v1beta1`; the remaining
> `v1beta1` manifests (the `ClusterSecretStore` and the tailscale
> `ExternalSecret`) must be migrated before that bump. (See the comment in
> `release.yaml`.)

### The ClusterSecretStore

`platform/base/external-secrets-stores/cluster-secret-store.yaml` defines a
single cluster-wide `ClusterSecretStore` named `vault` that every
`ExternalSecret` in the fleet points at:

| Field | Value |
|-------|-------|
| `provider.vault.server` | `https://vault.rosenvold.tech` |
| `provider.vault.path` | `secret` (KV v2 engine) |
| `provider.vault.version` | `v2` |
| Vault role | `eso-platform` (grants `read` on `secret/platform/*`) |

The store lives in its **own** component (`external-secrets-stores`), split out
from the ESO controller component. The `ClusterSecretStore` CR cannot be applied
until the ESO HelmRelease has installed its CRDs, so its fleet Kustomization
carries `dependsOn: external-secrets` (mirroring the kyverno / kyverno-policies
split). Everything that reads a Vault-synced secret then waits on the store:
`headlamp`, `tsidp`, `tailscale-operator`, `cert-manager-issuers`
(`dependsOn: external-secrets-stores`). See [architecture](architecture.md).

### Kubernetes / TokenReview auth (the default path)

On `prod-fsn` the store authenticates to Vault with Vault's **kubernetes** auth
backend:

```yaml
auth:
  kubernetes:
    mountPath: kubernetes/${cluster_name}
    role: eso-platform
    serviceAccountRef:
      name: external-secrets
      namespace: external-secrets
```

ESO's controller ServiceAccount presents its projected token; Vault validates it
by calling **back** to the cluster's `TokenReview` API. Vault ≥ 1.16 removed
offline JWT validation (`pem_keys` is ignored) and always validates logins via
`TokenReview`. With no `token_reviewer_jwt` configured, Vault authenticates the
review using the login JWT itself — which only works if ESO's ServiceAccount is
allowed to **create** `TokenReview`s.

That permission is granted by `platform/base/external-secrets/rbac-token-review.yaml`,
a `ClusterRoleBinding` that binds the `external-secrets` ServiceAccount to the
built-in `system:auth-delegator` ClusterRole. Without it, the Vault callback
fails and every secret sync 403s.

### The `${cluster_name}` mountPath substitution

The base manifest is kept cluster-agnostic: the auth mount is written as
`mountPath: kubernetes/${cluster_name}`. Vault's per-cluster kubernetes auth
mount, role and policy plus the `secret/` KV engine
(`secret/platform/*`, `secret/tenants/<tenant>/*`) are provisioned by Terraform.
Flux substitutes the `${cluster_name}` token in-cluster from each cluster's
`cluster-vars` ConfigMap via `postBuild.substituteFrom` on the Kustomization, so
`prod-fsn` resolves to `kubernetes/prod-fsn`. This is the "per-cluster *value* →
`cluster-vars` substitution" rule from the [architecture](architecture.md).

### test-home: the AppRole overlay

`test-home` runs on a home LAN, so its apiserver isn't reachable from
`vault.rosenvold.tech`. The `TokenReview` callback Vault ≥ 1.16 always issues
therefore fails with 403, and kubernetes auth can't work. This is a *structural*
difference, not a value swap (`${var}` can't express "remove this auth block and
add a different one"), so it gets the fleet's one remaining overlay:
`platform/overlays/test-home/external-secrets-stores/`.

The overlay JSON-patches the `ClusterSecretStore`: it **removes**
`/spec/provider/vault/auth/kubernetes` and **adds** an `appRole` block instead:

```yaml
auth:
  appRole:
    path: approle/test-home
    roleRef:    { name: vault-approle, namespace: external-secrets, key: role_id }
    secretRef:  { name: vault-approle, namespace: external-secrets, key: secret_id }
```

The `role_id` / `secret_id` are written into the `vault-approle` Secret by
`bootstrap/terraform/clusters/test-home/vault.tf`.

Because a Flux `Kustomization`'s `spec.path` **cannot** be substituted, test-home
can't reuse the shared fleet Kustomization that points at the base — it needs its
own per-cluster Flux `Kustomization` CR pointing at the overlay path. That CR is
`clusters/test-home/external-secrets-stores.yaml`: same `dependsOn:
external-secrets`, `wait: true`, and `postBuild.substituteFrom: cluster-vars`,
but `path: ./platform/overlays/test-home/external-secrets-stores`. This is the
"per-cluster *structure* → overlay + per-cluster Kustomization CR" half of the
variation rule.

## Every ExternalSecret in the fleet

Verified against `kind: ExternalSecret` manifests under `platform/base/`. All
read from the shared `vault` `ClusterSecretStore`, refresh hourly, and use
`creationPolicy: Owner`. Vault paths are relative to the store's `secret` KV-v2
mount (i.e. `platform/tailscale` is `secret/platform/tailscale`).

| Manifest | Vault path | Produced `Secret` | Keys / shape | Consuming workload |
|----------|-----------|-------------------|--------------|--------------------|
| `tailscale-operator/external-secret.yaml` (`tailscale-operator-oauth`) | `platform/tailscale` | `operator-oauth` (ns `tailscale`) | `client_id`, `client_secret` | Tailscale operator chart (referenced as the pre-existing OAuth secret) |
| `cert-manager-issuers/external-secret.yaml` (`cloudflare-api-token`) | `platform/cloudflare` | `cloudflare-api-token` (ns `cert-manager`) | `api-token` | cert-manager `ClusterIssuer`s' DNS-01 solver |
| `tsidp/external-secret.yaml` (`tsidp-auth`) | `platform/tsidp` | `tsidp-auth` (ns `tsidp`) | `TS_AUTHKEY` = `{{ .client_secret }}?ephemeral=false&preauthorized=true` (templated) | tsidp Deployment (`envFrom`) |
| `headlamp/external-secret.yaml` (`headlamp-oidc`) | `platform/headlamp-oidc` | `headlamp-oidc` (ns `headlamp`) | `client_id`, `client_secret` | Headlamp HelmRelease OIDC config (`valuesFrom`) |
| `headlamp/external-secret-kubeconfigs.yaml` (`headlamp-kubeconfigs`) | `platform/kubeconfigs/*` (`dataFrom.find`) | `headlamp-kubeconfigs` (ns `headlamp`) | one file per cluster, rewritten to `<cluster>` | Headlamp multi-cluster picker (`KUBECONFIG`) |
| `kube-prometheus-stack/external-secret.yaml` (`grafana-oidc`) | `platform/grafana-oidc` | `grafana-oidc` (ns `monitoring`) | `client_id`, `client_secret` | Grafana `generic_oauth` (`envValueFrom`) |

Notes:

- **tsidp** stores a Tailscale OAuth client secret (scope: Auth Keys write, tag
  `tag:tsidp`) and uses an ESO `template` to assemble a never-expiring,
  reusable, pre-approved `TS_AUTHKEY`.
- **headlamp-kubeconfigs** uses `dataFrom.find` to walk `secret/platform/kubeconfigs`
  and land one kubeconfig per cluster, rewriting the Vault path key (which
  contains `/`, invalid in Secret keys) down to the bare cluster name. Each
  cluster's `bootstrap/terraform/clusters/<name>/vault.tf` publishes its admin
  kubeconfig there; adding a cluster needs no edit here.
- The AppRole-backed `vault-approle` Secret on test-home is **not** an
  `ExternalSecret` — it is written directly by Terraform (it is the credential
  ESO uses *to reach* Vault).

## cert-manager and the Let's Encrypt issuers

`platform/base/cert-manager/` is the controller + CRDs only (chart
`cert-manager` `v1.20.2`, namespace `cert-manager`, `crds.enabled: true`). It
also enables a controller ServiceMonitor (`prometheus.servicemonitor.enabled`)
so the cert-manager Grafana dashboard has data — see [monitoring](monitoring.md).

The issuers and the token they need are a **separate** component,
`platform/base/cert-manager-issuers/` (plain CRs only), reconciled behind
`dependsOn: [cert-manager, external-secrets-stores]` with `wait: true` so it only
reads Ready once the issuers register with ACME.

### DNS-01 via Cloudflare

Both `ClusterIssuer`s solve ACME challenges with **DNS-01** against Cloudflare
(authoritative for `rosenvold.tech`). DNS-01 needs no public ingress and can
issue wildcards. The solver references the `cloudflare-api-token` Secret
(`api-token` key) that ESO syncs from `secret/platform/cloudflare` (Cloudflare
token scope: Zone/DNS/Edit + Zone/Zone/Read, scoped to `rosenvold.tech`). The
Secret lands in the `cert-manager` namespace because `ClusterIssuer` secret refs
resolve in cert-manager's cluster-resource-namespace.

| `ClusterIssuer` | ACME endpoint | Account key Secret | When to use |
|-----------------|---------------|--------------------|-------------|
| `letsencrypt-production` | `acme-v02.api.letsencrypt.org` | `letsencrypt-production-account-key` | real certs; rate-limited (50/registered domain/week) |
| `letsencrypt-test` | `acme-staging-v02.api.letsencrypt.org` | `letsencrypt-test-account-key` | plumbing checks; chains to an untrusted root |

Both register `email: lucas@rosenvold.tech`. If DNS-01 self-checks ever stall
behind cluster DNS, the cert-manager `release.yaml` has a commented
`dns01RecursiveNameservers` knob.

## Identity and access

There are three human entry points, and they share an identity backbone:
Tailscale identity for transport, and a tsidp-issued OIDC token for the two
dashboards. Nobody is granted access by individual email — access attaches to a
**group**.

### kubectl: the Tailscale API-server proxy (auth mode)

`platform/base/tailscale-operator/` runs the operator's API-server proxy in
**auth mode** (`apiServerProxyConfig: { mode: "true", allowImpersonation: "true" }`).
The proxy authenticates your tailnet identity and **impersonates** it against the
Kubernetes API, so standard RBAC applies and the audit trail carries your real
login — no per-user kubeconfig secrets, no public API endpoint. The operator
device itself is the API endpoint, named `k8s-api-${cluster_name}`
(`hostname` in `release.yaml`, substituted per cluster — e.g. `k8s-api-prod-fsn`).

The admin-console ACL grant maps your tailnet identity to the Kubernetes group
`maintainers`. `platform/base/tailscale-operator/rbac-maintainers.yaml` binds
that group to:

- the built-in `view` ClusterRole (cluster-wide read; **no Secret read** by
  design), and
- a curated `maintainers-operations` ClusterRole: pod `delete` /
  `exec` / `portforward` / `eviction`, Deployment/StatefulSet/DaemonSet `patch`
  (rollout-restart) + `*/scale`, and node `patch` (cordon/drain).

Flux still owns desired state — these verbs are for fixing incidents, not
changing config. Per-tenant groups (`tenant:<name>`) arrive with tenant
onboarding. Secret read and Flux suspend/resume are deliberately excluded.

The operator's OAuth client (Vault `secret/platform/tailscale` →
`operator-oauth`) needs **Devices Core (write)** + **Auth Keys (write)** scopes
and the `tag:k8s-operator` + `tag:k8s` tags. The full ACL JSON, the
kubeconfig-generation flow (`tailscale configure kubeconfig k8s-api-prod-fsn`),
and the `kubectl auth can-i` verification are the canonical copy in the
[top-level README → Tailscale access](../README.md#tailscale-access-api-server-proxy)
— not duplicated here.

### tsidp: the Tailscale OIDC issuer

`platform/base/tsidp/` is [tsidp](https://github.com/tailscale/tsidp), a plain
Deployment (no chart) that joins the tailnet as `idp.<tailnet>.ts.net`
(`tag:tsidp`) and issues the OIDC `id_token`s behind **both** Headlamp and
Grafana logins.

- **Funnel is on** (`TSIDP_USE_FUNNEL=1`) for exactly one reason: the
  kube-apiserver and Grafana validate OIDC tokens by fetching the issuer's
  discovery doc + JWKS, and the node has no tailnet access (operator-mode only,
  no host `tailscaled`). Funnel makes those discovery/JWKS endpoints publicly
  reachable. Actual **logins** still require tailnet identity — tsidp resolves
  the caller via `whois`, which Funnel traffic doesn't carry.
- **No probes**: tsidp serves over the tailnet via tsnet + Funnel and binds no
  port on the pod IP / has no Service, so a kubelet probe would crash-loop a
  healthy provider.
- **State** lives on a `hostPath` (`/var/mnt/tsidp`, single-node, no CSI): tsnet
  node identity + dynamically registered OIDC clients. Lost only on cluster
  rebuild — re-register clients then. The namespace is therefore
  `pod-security.kubernetes.io/enforce: privileged`.
- **Group injection**: tsidp does not expose a `groups` *scope* (requesting it
  fails with `invalid_scope`). Instead the group claim is injected via a tailnet
  policy `tailscale.com/cap/tsidp` extraClaims cap grant
  (`group:k8s-admins → {"groups":["k8s-admins"]}`). Adding a teammate is just
  putting them in `group:k8s-admins` in the tailnet policy — no RBAC change in
  this repo.

### Headlamp

`platform/base/headlamp/` (chart `headlamp` `0.42.0`) is reached on the tailnet
**only**: `ingress.yaml` uses `ingressClassName: tailscale`, so the operator
provisions a `headlamp.<tailnet>.ts.net` proxy device (`tag:k8s`) with a tailnet
TLS cert. No Traefik route, no public DNS, zero public attack surface.

- **Login** is tsidp OIDC: `issuerURL: https://idp.${tailnet}.ts.net`, scopes
  `openid,email,profile`, client id/secret from the `headlamp-oidc` Secret via
  `valuesFrom`.
- **RBAC** (`rbac-oidc.yaml`) is granted to the **group** `oidc:k8s-admins` (the
  apiserver applies `oidc-groups-prefix=oidc:`, set in the Talos machine config
  by the bootstrap repo). It binds that group to `view`, to the shared
  `maintainers-operations` ClusterRole, and to an extra `oidc-cluster-read` role
  that adds the cluster-scoped reads `view` omits (nodes, PVs, storage classes,
  CRDs) so the dashboard overview and the Flux / cert-manager plugins render.
- **Multi-cluster**: the `headlamp-kubeconfigs` ESO feeds the cluster picker
  (remote clusters via `KUBECONFIG`); `prod-fsn` stays on the in-cluster
  ServiceAccount so the OIDC group RBAC keeps applying rather than being bypassed
  by an embedded admin cert.

### Grafana

Grafana (in `kube-prometheus-stack`) uses the **same** model: Tailscale ingress
(`grafana.<tailnet>.ts.net`), tsidp `generic_oauth`, the native login form
disabled (`disable_login_form: true`, `oauth_auto_login: true`) so tailnet
identity is the only door. Client id/secret come from the `grafana-oidc` Secret
(`envValueFrom`); the `k8s-admins` group claim drives the Grafana role
(`role_attribute_path` → Admin if in `k8s-admins`, else Viewer). Details and the
TSDB/dashboard plumbing are in [monitoring](monitoring.md).
