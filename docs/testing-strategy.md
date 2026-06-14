# Testing Strategy: BDD and TDD for the GitOps Repository

This document maps out a production-grade testing strategy for this Flux GitOps
tree. The artifacts under test are YAML manifests, Kyverno policies, Kustomize
overlays, and Flux reconciliation objects — not application code.

All scenarios are production requirements. The priority table in Part 9 orders
them by risk and implementation cost.

---

## Test Case Overview

| ID | Name | Category | Status | Pipeline tier | Effort | Failure mode prevented |
|---|---|---|---|---|---|---|
| **BASE-1** | Kustomize build + kubeconform | Structural | ✅ Exists | PR gate | — | Invalid manifests reach cluster |
| **BASE-2** | Kyverno apply + unit tests | Policy | ✅ Exists | PR gate | — | Policy regressions go undetected |
| **BASE-3** | Namespace exclusion drift guard | Network | ✅ Exists | PR gate | — | Tenant policy leaks into platform namespaces |
| **BASE-4** | gitleaks secret scan | Security | ✅ Exists | fast-fail | — | Credentials committed to repo |
| **BASE-5** | actionlint workflow lint | CI | ✅ Exists | PR gate | — | Broken CI workflows merge silently |
| **S1** | Every Flux source has a consumer | Structural | ❌ Missing | post-merge | ~60 lines Python | Orphaned sources cause reconciliation warnings |
| **S2** | `spec.path` resolves to real directory | Structural | ❌ Missing | PR gate | 1 line fix | Dangling path silently fails reconciliation |
| **S3** | No duplicate Kustomization `(namespace, name)` | Structural | ❌ Missing | PR gate | ~20 lines Python | Second reconciliation silently overwrites first |
| **S4** | Both clusters include all fleet components | Structural | ❌ Missing | post-merge | ~30 lines Python | Component silently dropped from a cluster |
| **S5** | Every `dependsOn` reference resolves | Structural | ❌ Missing | PR gate | ~25 lines Python | Component stuck in dependency-not-found forever |
| **S6** | Exclusion guard covers all network policy files | Network | ❌ Missing | PR gate | ~10 lines bash | New CNP file drifts silently, unguarded |
| **S7** | CRD-shipping HelmReleases have `crds: CreateReplace` | Structural | ❌ Missing | PR gate | grep | Major upgrade corrupts stored API objects |
| **S8** | Generated CiliumNetworkPolicies pass kubeconform | Policy | ❌ Missing | PR gate | pipe to kubeconform | Invalid CNP silently ignored by Cilium |
| **S9** | Traefik IngressRoute objects are schema-validated | Structural | ❌ Missing | PR gate | 1 `--schema-location` flag | Malformed IngressRoute breaks service silently |
| **P1** | Missing HelmRelease `serviceAccountName` is rejected | Policy | ❌ Missing | PR gate | 20 lines YAML | Tenant HelmRelease bypasses SA isolation |
| **P2** | Platform exclusion does not suppress `disallow-default-namespace` | Policy | ❌ Missing | PR gate | 10 lines YAML | Future exclusion refactor suppresses wrong rule |
| **P3** | Individual pod-security fields rejected (containers + initContainers) | Policy | ❌ Missing | PR gate | YAML fixtures | Policy typo allows one privileged field through |
| **SEC1** | No raw `kind: Secret` objects in repo | Security | ❌ Missing | fast-fail | 2 lines bash | Raw Secret breaks ExternalSecrets-only model |
| **SEC2** | Kyverno `failurePolicy` is never `Ignore` | Security | ❌ Missing | PR gate | 1 grep | Kyverno outage → cluster fails open |
| **SEC3** | Authored workload images pinned to `@sha256:` digest | Security | ❌ Missing | PR gate | grep | Mutable tag replaced by compromised registry |
| **SEC4** | Generated CNPs deny egress to `169.254.169.254/32` | Security | ❌ Missing | PR gate | extend policy-check.sh | Tenant pod exfiltrates Hetzner instance credentials |
| **SEC5** | Helm source registries match allowlist | Security | ❌ Missing | weekly | ~25 lines bash | Renovate introduces untrusted or HTTP chart source |
| **SEC6** | RBAC forbids `bind`, `escalate`, `impersonate`, token-create | Security | ❌ Missing | PR gate | ~40 lines Python | Privilege escalation path survives ClusterRole checks |
| **SEC7** | ExternalSecret references an existing ClusterSecretStore | Security | ❌ Missing | PR gate | ~30 lines Python | Misnamed store → secret never syncs → cert renewal fails |
| **OBS1** | Watchdog alert exists and is not disabled | Observability | ❌ Missing | PR gate | 1 yq/grep | Prometheus down → all alerts silent |
| **OBS2** | Alertmanager routing is non-null | Observability | ❌ Missing | PR gate | ~10 lines bash | All alerts routed to `/dev/null` |
| **OBS3** | Flux reconciliation failure alert rule exists | Observability | ❌ Missing | PR gate | 1 grep | Failed HelmRelease retries silently for hours |
| **OBS4** | Kyverno audit violation alert rule exists | Observability | ❌ Missing | PR gate | 1 grep | Policy violations accumulate with no signal |
| **OBS5** | Dashboard completeness (Traefik, external-secrets missing) | Observability | ❌ Missing | PR gate | ~10 lines bash | No visibility during incidents for key components |
| **OBS6** | Certificate objects reference an existing ClusterIssuer | Observability | ❌ Missing | PR gate | ~15 lines Python | Cert never issued; TLS breaks silently at expiry |
| **OBS7** | Cert expiry + ingress latency SLO alert rules exist | Observability | ❌ Missing | PR gate | grep + threshold | Expiring cert reaches production with no warning |
| **OBS8** | PrometheusRule syntax is valid (`promtool check rules`) | Observability | ❌ Missing | PR gate | ~5 lines bash | Silent inactive rule; alert never fires |
| **DRIFT** | Cluster drift detection | Operations | ❌ Missing | nightly | new workflow | Cluster diverges from repo with no signal |

---

## What Already Exists (Baseline)

| Check | Tool | What it covers |
|---|---|---|
| `just validate` | kustomize + kubeconform | every kustomization builds; all objects match upstream CRD schemas |
| `just policy` | kyverno apply + kyverno test | ClusterPolicies apply correctly; unit fixtures assert fire/skip/pass |
| `just namespaces` | bash + yq/python | the four-place platform-namespace exclusion lists stay set-identical |
| `just secrets` | gitleaks | no credentials committed |
| `just lint` | actionlint | CI workflow YAML is syntactically and semantically correct |

---

## Part 1 — Critical Architecture Finding: No Staging Gate

Both clusters point at `main` with `interval: 1m0s`. `test-home` and `prod-fsn`
reconcile simultaneously. A bad manifest that merges reaches production in
under a minute with no intermediate verification step.

**Required change:** Set `prod-fsn`'s Flux Kustomization interval to 10–15
minutes and add a post-merge CI job that polls `test-home` health via
`flux get kustomizations` over a kubeconfig secret before that window expires.
`prod-fsn` should only reconcile after `test-home` is confirmed `Ready`.

Until this is in place, the PR test suite is the only gate between a commit and
production — every other item in this document operates under that constraint.

---

## Part 2 — CI Pipeline Architecture

### Current shape (all parallel, all PR-gated)

```
PR → validate | policy | secrets | namespaces | lint
```

### Target shape

**Fast-fail tier** (pure filesystem, < 5 seconds — block the rest):
```
secrets, namespaces, no-secrets-objects
```

**Static analysis tier** (depends on rendered output):
```
validate, policy, lint, check-rbac, check-issuers, check-dependson
```

**Post-merge workflow** (`push` to `main`, runs before prod-fsn interval fires):
```
check-source-coherence, cluster-parity, test-home readiness gate
```

**Scheduled workflows** (weekly):
```
image-scan, check-registries (network-dependent, unreliable in PR CI)
```

**Advisory / nightly**:
```
drift-detection (flux get all --status-selector ready=false)
kube-score (graduate to blocking after initial triage)
```

### Additional pipeline requirements

- **`main` branch protection:** required status checks = `validate`, `policy`,
  `secrets`, `namespaces`, `lint`, `check-rbac`. Squash-merge only (keeps
  `git log` as a changelog; avoids Flux re-apply/skip on force-push).
- **No force-push to `main`:** Flux polls by commit SHA; a force-push can cause
  it to re-apply or skip reconciliation unpredictably.
- **`kube-score`:** run as a PR annotation (non-blocking) on day one; triage
  findings; graduate to blocking. Do not start blocking — the first run against
  full rendered output will surface dozens of findings needing triage.

---

## Part 3 — Structural Flux Coherence

These tests catch reconciliation failures before they reach the cluster. They
track structural invariants, not specific values, so they are stable across
Renovate PRs.

---

### S1 — Every Flux source is consumed by at least one workload

```
Given  all GitRepository, HelmRepository, and OCIRepository objects in the repo
When   all Flux Kustomization and HelmRelease objects are enumerated
Then   every source is referenced by at least one consumer
```

*Why:* An orphaned source is a maintenance hazard and triggers unnecessary Flux
reconciliation warnings.

*Implementation:* Build all kustomizations, extract source names by kind and
namespace, extract consumer `spec.sourceRef` fields, diff the sets. ~60 lines
Python with PyYAML.

*File:* `scripts/check-source-coherence.sh` + `just sources` recipe.
*Pipeline tier:* post-merge.

---

### S2 — Every Flux Kustomization's `spec.path` resolves to a real directory

```
Given  a Flux Kustomization object with spec.path set
When   the path is resolved relative to the repo root
Then   a kustomization.yaml file exists at that path
```

*Why:* A dangling `spec.path` causes a silent reconciliation error that only
surfaces after merge.

*Implementation:* `policy-check.sh` line 46 currently reads
`[ -f "$dir/kustomization.yaml" ] || continue` — it silently skips dangling
paths instead of failing. **One-line fix:** change `continue` to
`echo "✗ dangling path: $dir" >&2; exit 1`.

*Pipeline tier:* PR gate (already inside `just policy`).

---

### S3 — No two Kustomizations share the same `targetNamespace` + `name`

```
Given  all Flux Kustomization objects built for a cluster
When   (targetNamespace, name) pairs are extracted
Then   each pair is unique
```

*Why:* Duplicate names in the same namespace cause the second reconciliation to
silently overwrite the first (the class of bug fixed in commit `6f113fd`).

*Implementation:* Post-build Python: extract `(metadata.namespace, metadata.name)`
from all `kind: Kustomization` objects, assert no duplicates.

*Pipeline tier:* PR gate.

---

### S4 — Both clusters include all platform fleet components

```
Given  the fleet kustomization is built and its Kustomization objects extracted
When   each cluster kustomization is built and its Kustomization objects extracted
Then   both clusters' Kustomization object name sets match the fleet set
```

*Note:* Must operate on **built output** (rendered `kind: Kustomization` object
names), not on `platform/fleet/kustomization.yaml`'s `resources:` file list —
file names and object names can diverge. A strategic-merge-patch in a cluster
overlay could drop a component while the file list stays identical.

*File:* `scripts/check-cluster-parity.sh` + `just parity` recipe.
*Pipeline tier:* post-merge.

---

### S5 — Every `spec.dependsOn` reference resolves to a real Kustomization

```
Given  all Flux Kustomization objects with spec.dependsOn set
When   the referenced name is looked up in the same cluster's built output
Then   a Kustomization with that name exists
```

*Why:* A mistyped or removed `dependsOn` entry causes the dependent
Kustomization to reconcile before its dependency is ready, resulting in
CRD-not-found errors that block cert renewal or secret sync with no clear signal.

*Implementation:* Build each cluster, extract all `spec.dependsOn[].name`
values, assert each matches a `metadata.name` in the same built output.
~25 lines Python.

*Pipeline tier:* PR gate.

---

### S6 — The namespace exclusion guard covers all network policy files

```
Given  all CiliumClusterwideNetworkPolicy files under platform/base/network/
       that contain a NotIn matchExpression
When   the exclusion guard script's file list is inspected
Then   every such file is in the guard's comparison set
```

*Why:* The existing drift guard compares four hard-coded files. If a fifth
network policy file is added with a platform-namespace exclusion, it starts
life unguarded — the guard stays green while the new file drifts silently.

*Implementation:* Assert the `cilium_files` array length in
`check-namespace-lists.sh` equals the count of `CiliumClusterwideNetworkPolicy`
files under `platform/base/network/` containing `operator: NotIn`. A new policy
file added without updating the guard immediately fails CI.

*Pipeline tier:* PR gate (extend `just namespaces`).

---

### S7 — CRD-shipping HelmReleases have `crds: CreateReplace`

```
Given  all HelmRelease objects for charts that ship CRDs
       (cert-manager, Kyverno, external-secrets, kube-prometheus-stack)
When   spec.install.crds and spec.upgrade.crds are inspected
Then   both are set to CreateReplace
```

*Why:* Without `CreateReplace`, Flux does not apply new CRD versions during a
chart upgrade. A major version bump (e.g. Kyverno v2) creates new stored API
versions but does not migrate existing objects, causing admission or
reconciliation failures that are difficult to recover from without manual
intervention.

*Implementation:* Grep built HelmRelease objects for the known CRD-shipping
chart names and assert both fields are present and set to `CreateReplace`.

*Pipeline tier:* PR gate.

---

### S8 — Generated CiliumNetworkPolicies are schema-valid

```
Given  the CiliumNetworkPolicy generated by generate-baseline-netpol
       for a fixture tenant namespace
When   the generated manifest is piped through kubeconform
Then   it passes Cilium CRD schema validation
```

*Why:* `kyverno test` validates that the generate rule fires — it does not
validate that the generated output is structurally valid Cilium YAML. A bad
JMESPath expression in the rule could emit a CNP that Cilium silently ignores,
leaving a namespace with no network policy enforcement while CI stays green.

*Implementation:* In `policy-check.sh`, pipe `kyverno apply --generate` output
for a fixture namespace through `kubeconform` with the Cilium CRD schema
location. This is the same kubeconform invocation already used in `validate.sh`.

*Pipeline tier:* PR gate (extend `just policy`).

---

### S9 — Traefik IngressRoute objects are schema-validated

```
Given  all IngressRoute objects in the repo
When   kubeconform is run against them
Then   no object is silently skipped due to a missing schema location
```

*Why:* Traefik `IngressRoute` CRDs are non-upstream. Without their schema in
`--schema-location`, kubeconform silently skips them. A malformed `IngressRoute`
(wrong `entryPoints` name, missing `routes[].match`) merges, Traefik rejects it
at runtime, and the service becomes unreachable with no CI signal.

*Implementation:* Add Traefik CRD schemas to the `kubeconform_args` in
`validate.sh`. Traefik publishes schemas at their GitHub releases. Verify `just
validate` produces no `skipping` warnings for `IngressRoute` kinds.

*Pipeline tier:* PR gate (extend `just validate`).

---

## Part 4 — Kyverno Policy Gaps

Tests to add to `tests/policy/kyverno-test.yaml`. **Every new fixture namespace
must also get a corresponding entry in `tests/policy/values.yaml`.** Without
it, `kyverno test` cannot resolve `namespaceSelector` labels and produces
silent false greens on exclusion paths.

---

### P1 — Missing HelmRelease serviceAccountName is rejected

```
Given  a HelmRelease in a tenant namespace without spec.serviceAccountName
When   Kyverno evaluates flux-multi-tenancy
Then   the HelmRelease is denied
```

*Status:* `bad-kustomization-nosa` exists. Gap: no `bad-helmrelease-nosa`
fixture. Add it with a corresponding result entry and `values.yaml` entry.

---

### P2 — Policy exemption does not suppress `disallow-default-namespace`

```
Given  a Pod in a platform.io/managed namespace in the "default" namespace
When   Kyverno evaluates disallow-default-namespace
Then   the policy fires (result: fail), not skips
```

*Why:* This is an explicit test of the absence of exclusion on
`disallow-default-namespace`. A future exclusion refactor could accidentally
suppress this rule for platform pods.

---

### P3 — Specific pod-security fields are each individually rejected

```
Given  a Pod with exactly one of: securityContext.privileged: true,
       hostNetwork: true, hostPID: true, allowPrivilegeEscalation: true,
       no seccompProfile, added Linux capabilities
When   Kyverno evaluates pod-security-baseline / pod-security-restricted
Then   each individual violation is denied
And    the same violations in initContainers are also denied
```

*Status:* `bad-pod` covers a combined violation. A typo in the policy's
`containers[]` vs `initContainers[]` path check could let one field through.
Add one fixture per field for both `containers` and `initContainers`.

---

## Part 5 — Security Checks

---

### SEC1 — No raw `kind: Secret` objects exist in the repo

```
Given  all YAML files in the repo
When   they are parsed
Then   no object of kind: Secret appears
```

*Why:* gitleaks catches leaked values but not the presence of a Secret object
with a placeholder or empty value. A Secret object breaks the ExternalSecrets-
only security model.

*Implementation:*
```bash
! grep -rn 'kind: Secret' . --include='*.yaml' --exclude-dir=.git | grep -v '^\s*#'
```

*Pipeline tier:* fast-fail tier.

---

### SEC2 — Kyverno ClusterPolicies do not use `failurePolicy: Ignore`

```
Given  all ClusterPolicy objects in the repo
When   their spec and associated webhook configuration are inspected
Then   no policy uses failurePolicy: Ignore
```

*Why:* If Kyverno's admission webhook becomes unavailable and `failurePolicy`
is `Ignore`, Kubernetes fails open and unvalidated workloads are admitted. This
is the highest-impact single-point failure in the admission control chain.

*Implementation:* `grep -r 'failurePolicy: Ignore' platform/base/policies/`
as a hard gate. Also verify `MutatingWebhookConfiguration` and
`ValidatingWebhookConfiguration` objects have `failurePolicy: Fail`.

*Pipeline tier:* PR gate.

---

### SEC3 — Directly authored workload images are pinned to immutable digests

```
Given  all image: fields in manifests authored in this repo
When   they are inspected
Then   every image reference includes @sha256:
```

*Why:* `disallow-latest-tag` only blocks `:latest` and untagged images. Mutable
tags like `:main`, `:edge`, or `:1.2.3` without a digest allow a compromised
registry to replace a tag silently.

*Scope:* Apply to directly authored manifests (e.g.
`platform/base/tsidp/deployment.yaml`). HelmRelease-managed images are
validated at runtime by Trivy Operator — chart-internal image refs are not
expanded by kustomize and cannot be grepped reliably from the repo tree.

*Pipeline tier:* PR gate.

---

### SEC4 — Cloud metadata endpoint egress is explicitly denied in generated CNPs

```
Given  the CiliumNetworkPolicy generated for a tenant namespace
When   its egress rules are inspected
Then   an egress deny rule exists for 169.254.169.254/32
```

*Why:* On Hetzner (prod-fsn), the instance metadata endpoint exposes cloud
identity tokens. A tenant pod that can reach `169.254.169.254` can exfiltrate
credentials regardless of other namespace isolation controls.

*Implementation:* Extend the `longhorn-system` exclusion check already in
`policy-check.sh` — assert the CIDR deny appears in the generated CNP output.

*Pipeline tier:* PR gate (extend `just policy`).

---

### SEC5 — Helm chart source registries are on an explicit allowlist

```
Given  all HelmRepository and OCIRepository objects in the repo
When   their spec.url values are inspected
Then   every URL matches a maintained allowlist of trusted registries
```

*Why:* Renovate could introduce or alter a chart source URL. An `http://` or
unknown OCI registry bypasses TLS and content verification.

*Implementation:* Hardcode the allowlist; grep all HelmRepository/OCIRepository
`spec.url` values from built output; fail on any mismatch. ~25 lines bash.

*File:* `scripts/check-registries.sh`.
*Pipeline tier:* scheduled (weekly) — network-dependent checks are unreliable
in PR CI due to transient DNS and rate limits.

---

### SEC6 — RBAC does not grant bind, escalate, impersonate, or token-create

```
Given  all Role and ClusterRole objects in the repo
When   their rules are inspected
Then   no rule grants verbs: bind, escalate, or impersonate
And    no rule grants create on serviceaccounts/token
```

*Why:* `bind`/`escalate` allow a role to grant itself higher permissions;
`serviceaccounts/token` create allows manual token minting that bypasses
projected token expiry. These are the RBAC escalation paths that survive
ClusterRoleBinding and cluster-scoped resource checks.

*Implementation:* Build all manifests, extract Role/ClusterRole rules, assert
forbidden verbs are absent. ~40 lines Python.

*Pipeline tier:* PR gate.

---

### SEC7 — ExternalSecret references a ClusterSecretStore present in the same cluster

```
Given  all ExternalSecret objects in a cluster's built output
When   the spec.secretStoreRef.name values are extracted
Then   each name matches a ClusterSecretStore present in that same cluster's output
```

*Why:* If Vault is unreachable during a refresh, the secret goes stale silently.
This check catches the structural precondition: a missing or misnamed store
means the ExternalSecret can never sync, and cert renewals fail hours later with
no alert.

*Implementation:* Build each cluster separately; extract ExternalSecret
`secretStoreRef.name` values and ClusterSecretStore `metadata.name` values from
the same build; assert the former is a subset of the latter. ~30 lines Python.

*Pipeline tier:* PR gate.

---

## Part 6 — Observability and Alerting Tests

The observability stack (kube-prometheus-stack, Flux PodMonitor, Kyverno
metrics, Policy Reporter) is deployed but currently has no Alertmanager routing
configuration and no PrometheusRules in this repo. Every scenario below is
therefore both a platform gap and a test gap simultaneously. Tests in this
section are structured to be addable now (as gates that fail if the thing is
absent) rather than waiting until the configuration exists.

---

### OBS1 — Watchdog alert exists and is not disabled

```
Given  all PrometheusRule objects in the built output
When   their rules are inspected
Then   a rule with alert: Watchdog (or DeadMansSwitch) is present
And    it is not disabled in HelmRelease values
```

*Why:* If Prometheus stops scraping (OOM, PVC full, eviction), all other
alerts also stop firing. The Watchdog is the sentinel that must always fire
and be routed to a dead-man's-switch integration (e.g. Healthchecks.io).
kube-prometheus-stack ships it by default — the test guards against it being
accidentally disabled via values.

*Implementation:* `kustomize build clusters/prod-fsn | yq 'select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(.alert == "Watchdog")'` must produce output. One-liner.

*Pipeline tier:* PR gate.

---

### OBS2 — Alertmanager routing configuration is non-null

```
Given  the rendered Alertmanager configuration
When   amtool check-config is run against it
Then   it exits 0
And    at least one receiver other than "null" exists
And    the default route does not point to the null receiver
```

*Why:* kube-prometheus-stack defaults to a null receiver that silently drops
all alerts. A firing alert emits to `/dev/null` with no error, no page, no
noise. This is the highest-impact silent failure in the alerting chain after
the Watchdog.

*Implementation:* Extract the rendered Alertmanager config from the built
Secret, pipe through `amtool check-config`, and assert receiver count > 1.
`amtool` ships with Alertmanager (already in the cluster; install in CI from
the same binary). ~10 lines bash.

*File:* `scripts/check-alertmanager.sh` + `just check-alertmanager` recipe.
*Pipeline tier:* PR gate (once alertmanager config is in the repo).

---

### OBS3 — Flux reconciliation failure alert rule exists

```
Given  all PrometheusRule objects in the built output
When   their expressions are inspected
Then   at least one rule references gotk_reconcile_condition
```

*Why:* A failed HelmRelease retries silently for hours. Without an alert rule
on `gotk_reconcile_condition{status="False"}`, the only signal is someone
noticing a broken dashboard. The `flux-podmonitor.yaml` already scrapes Flux
metrics — the rule must exist to consume them.

*Implementation:* `grep -r 'gotk_reconcile_condition' <built output> | grep PrometheusRule` exits 0. Fails immediately on a missing rule, costing one grep.

*Pipeline tier:* PR gate.

---

### OBS4 — Kyverno audit violation alert rule exists

```
Given  all PrometheusRule objects in the built output
When   their expressions are inspected
Then   at least one rule references kyverno_policy_results_total
```

*Why:* Kyverno Audit-mode violations log silently. Policy Reporter surfaces
them in a UI but only if someone is watching. Without a firing alert, a
misconfigured workload violates policy indefinitely.

*Implementation:* Same pattern as OBS3 — one grep. The Kyverno dashboard
`15987-kyverno.yaml` confirms the series is scraped.

*Pipeline tier:* PR gate.

---

### OBS5 — Dashboard completeness

```
Given  an explicit list of required platform components
When   Grafana dashboard ConfigMaps in the built output are enumerated
Then   every component has a dashboard with the grafana_dashboard: "1" label
```

*Required list (current state — update as components are added):*
cert-manager, Kubernetes, Kyverno, Flux, Longhorn, Traefik, external-secrets.

*Why:* Traefik and external-secrets currently have no dashboard. Metrics are
collected but invisible until someone builds an ad-hoc panel during an incident.

*Implementation:* Hardcode the required list; extract ConfigMap names and labels
from built output; diff. ~10 lines bash.

*Pipeline tier:* PR gate.

---

### OBS6 — Certificate objects reference an existing ClusterIssuer

```
Given  all Certificate objects in a cluster's built output
When   spec.issuerRef.name values are extracted
Then   each name matches a ClusterIssuer in the same cluster's output
```

*Why:* A Certificate that references a missing ClusterIssuer logs a not-ready
condition; cert-manager issues no certificate; TLS breaks silently at renewal
time — potentially with no alert because the cert is still valid until it
expires.

*Additional assertion:* Every ClusterIssuer with
`acme.server: acme-v02.api.letsencrypt.org` (production) must use DNS-01
solvers only. HTTP-01 on a Hetzner server is unreachable without explicit
firewall rules; a solver misconfiguration hits Let's Encrypt rate limits before
it is caught.

*Implementation:* ~15 lines Python with PyYAML.
*Pipeline tier:* PR gate.

---

### OBS7 — Cert expiry and Flux failure SLO alert rules exist (when authored)

```
Given  all PrometheusRule objects in the built output
When   their expressions are inspected
Then   at least one rule references certmanager_certificate_expiration_timestamp_seconds
And    its threshold is at least 7 days before expiry
```

*Why:* A cert renewal fails (Cloudflare token rotated, rate limit hit). The
first symptom without this alert is a browser TLS error in production.

*Implementation:* Grep + threshold assertion once rules are authored. Wire into
`just check-alertmanager` or its own recipe. Add similarly for
`traefik_router_request_duration_seconds_bucket` ingress latency.

*Pipeline tier:* PR gate (add once rules are authored).

---

### OBS8 — PrometheusRule syntax is valid

```
Given  all PrometheusRule objects authored in this repo (not chart-shipped)
When   promtool check rules is run against each file
Then   every rule file exits 0
```

*Implementation:* `promtool check rules <file>` validates PromQL expression
syntax without a live Prometheus instance. Add as `just check-rules` once
custom rules are authored.

*Pipeline tier:* PR gate.

---

## Part 7 — Drift Detection (Scheduled)

Nothing currently detects cluster drift from the repo state after merge.

Add a nightly workflow (`drift-detection.yaml`) that:
1. Runs `flux get all -A --status-selector ready=false` over a read-only
   kubeconfig stored as a GitHub secret.
2. Fails the workflow job if output is non-empty.
3. Emits results to the GitHub Actions summary.
4. Optionally forwards to Alertmanager via Flux `Alert` + `Provider` objects.

**Prerequisite:** `Alert` and `Provider` objects do not currently exist in
either cluster. Add at least one `Alert`/`Provider` pair per cluster as a
hard gate (see pipeline note in Part 2 — `flux-alerts` check).

---

## Part 8 — TDD Workflow

Write the failing assertion before touching the manifest.

**New Kyverno policy:**
1. *Red* — add result entries to `kyverno-test.yaml` referencing a policy file
   that doesn't exist yet. Add fixture resources and a `values.yaml` entry for
   every new fixture namespace. Run `just policy` → fails.
2. *Green* — write the minimum `ClusterPolicy`. Run `just policy`.
3. *Refactor* — tighten match expressions. Each change re-runs `just policy`.

**New tenant:**
1. *Red* — add tenant to `clusters/<name>/tenants.yaml` before creating
   `tenants/base/<name>/`. Run `just validate` → fails on dangling `spec.path`
   (Scenario S2 fix makes this a hard error rather than a silent skip).
2. *Green* — create `tenants/base/<name>/` with namespace, RBAC, kustomization.
3. *Extend* — add source, release, overlay. Each step is its own green cycle.

**New platform component:**
1. *Red* — parity check fails because the new component is in the fleet but not
   in both cluster builds.
2. *Green* — create `platform/base/<component>/`, fleet Kustomization, add to
   `platform/fleet/kustomization.yaml`, add namespace to the four exclusion lists.
3. *Validate* — `just validate` catches schema issues; `just policy` catches
   missing exclusion; `just namespaces` catches exclusion list drift; OBS5
   check catches missing dashboard.

**New network policy:**
1. *Red* — add fixture namespace to `tests/policy/netpol-namespaces.yaml` and
   result to `kyverno-test.yaml`. Add `values.yaml` entry. Run `just policy`.
2. *Green* — update `generate-baseline-netpol.yaml`.
3. *Validate negative* — extend the `policy-check.sh` generated-CNP check to
   assert any new exclusion namespace produces no CNP.

---

## Part 9 — Implementation Priority

| Priority | What | Effort | Pipeline tier |
|---|---|---|---|
| **1** | Fix silent `continue` → `exit 1` for dangling `spec.path` | 1 line | PR gate (`policy-check.sh:46`) |
| **2** | No `kind: Secret` objects gate | 2 lines | fast-fail |
| **3** | Kyverno `failurePolicy: Ignore` gate | 1 grep | PR gate (`validate.sh`) |
| **4** | Watchdog alert existence check | 1 yq/grep | PR gate |
| **5** | Add Traefik CRD schema to kubeconform | 1 `--schema-location` flag | PR gate (`validate.sh`) |
| **6** | `bad-helmrelease-nosa` fixture + `values.yaml` entry | 20 lines YAML | PR gate (`just policy`) |
| **7** | ExternalSecret → ClusterSecretStore validation | ~30 lines Python | PR gate |
| **8** | Certificate → ClusterIssuer cross-reference check | ~15 lines Python | PR gate |
| **9** | Flux `dependsOn` reference validation | ~25 lines Python | PR gate |
| **10** | `check-source-coherence.sh` | ~60 lines Python | post-merge |
| **11** | Cluster parity check (built object names) | ~30 lines Python | post-merge |
| **12** | `kube-score` as advisory `just score` | install + 1 recipe | advisory |
| **13** | Namespace exclusion guard self-coverage (S6) | ~10 lines bash | PR gate (`namespaces`) |
| **14** | CRD-shipping HelmRelease `crds: CreateReplace` check | grep | PR gate |
| **15** | Generated CNP kubeconform validation (S8) | pipe to existing kubeconform | PR gate |
| **16** | SEC3: image digest pinning for authored manifests | grep | PR gate |
| **17** | SEC4: metadata endpoint egress in generated CNPs | extend `policy-check.sh` | PR gate |
| **18** | Helm registry allowlist | ~25 lines bash | weekly scheduled |
| **19** | SEC6: RBAC forbidden verbs | ~40 lines Python | PR gate |
| **20** | Alertmanager routing: `amtool check-config` | ~10 lines bash | PR gate |
| **21** | Flux reconciliation alert rule existence | 1 grep | PR gate |
| **22** | Kyverno audit violation alert rule existence | 1 grep | PR gate |
| **23** | Dashboard completeness allowlist | ~10 lines bash | PR gate |
| **24** | Drift detection nightly workflow | new workflow file | scheduled |
| **25** | Flux `Alert`/`Provider` existence gate | grep | PR gate |
| **26** | Per-field pod-security fixtures + initContainers | YAML | PR gate (`just policy`) |
| **27** | SLO alert rule assertions (cert expiry, ingress latency) | grep + threshold | PR gate (add when rules authored) |

---

## Part 10 — Tests to Avoid (Rot-Prone)

Do not write assertions against values that change on every Renovate PR:
- Specific image tags or chart versions
- Exact counts of manifests, clusters, or tenants
- Registry URLs embedded in HelmRelease chart values (use the allowlist in
  SEC5 at the source level instead)

---

## Part 11 — Suggested `justfile` Additions

```makefile
# Fast-fail tier
no-secrets-objects:
    @! grep -rn 'kind: Secret' . --include='*.yaml' --exclude-dir=.git | grep -v '^\s*#'

# PR gate additions
check-rbac:
    ./scripts/check-rbac.sh

check-issuers:
    ./scripts/check-issuers.sh

check-dependson:
    ./scripts/check-dependson.sh

check-alertmanager:
    ./scripts/check-alertmanager.sh

check-rules:
    ./scripts/check-rules.sh

# Post-merge
sources:
    ./scripts/check-source-coherence.sh

parity:
    ./scripts/check-cluster-parity.sh

# Scheduled
registries:
    ./scripts/check-registries.sh

# Advisory
score:
    kustomize build clusters/prod-fsn --load-restrictor LoadRestrictionsNone | kube-score score -

# Updated gate (fast-fail → static analysis)
check: no-secrets-objects secrets namespaces validate policy lint check-rbac check-issuers check-dependson
```
