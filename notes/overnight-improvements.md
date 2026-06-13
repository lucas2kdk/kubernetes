# Overnight improvements log

Autonomous improvement session started 2026-06-13. Each entry: what changed,
why, how it was verified. Doubts that need a human / live cluster are filed
under "Open doubts" at the bottom and the work moves on to a different topic.

Ground rules I'm holding to:
- No `git commit`/`push` (not requested). Changes left staged + documented.
- Every change verified with `scripts/validate.sh` (kubeconform, 36 targets)
  and/or `kubectl kustomize --load-restrictor LoadRestrictionsNone`.
- Touch only things that build/validate locally. Anything whose correctness
  depends on live-cluster state → doubt, not a blind change.

## Prior session (recap, see review.md for detail)
- #2 deleted commented-out cluster files (netdata/vector).
- #3 deduped platform namespace exclusion lists via `platform.io/managed` label
  across 6 policy blocks; left `generate-baseline-netpol` static on purpose.
- #5 documented as WON'T FIX (active Flux Kustomization references the scaffold).

## This session

**Summary:** the repo is mature and heavily commented; the clearly-safe,
locally-verifiable work was documentation/consistency. Made changes A, C, D
(below); verified B, E required no change; filed doubts D1–D4 (all need
live-cluster access). Every change kept `scripts/validate.sh` at 36/36. No
commits made (none requested) — all my work is staged for review.

### A. Documented the `platform.io/managed` namespace convention (README) — DONE
My prior-session finding #3 introduced the `platform.io/managed: "true"` label
but nothing told a future maintainer that adding a platform component requires
touching exclusion lists in *three* places (only the Kyverno selector is
automatic). Added a "Platform namespace convention" subsection to README.md
spelling out the onboarding checklist, the Cilium `NotIn` manual step, and the
`longhorn-system` lockstep requirement. Documentation only, zero runtime risk.
Verified: `scripts/validate.sh` still 36/36 (README isn't built, but ran it to
confirm no accidental tree breakage).

### B. Cilium `NotIn` namespace-list duplication — DECIDED: leave as-is (by design)
`default-deny`, `deny-cloud-metadata`, `allow-ingress-from-traefik` each repeat
the same ~16-namespace `NotIn values:` list. Cannot dedupe with the
`platform.io/managed` label: Cilium's `NotIn` matchExpression matches the
`k8s:io.kubernetes.pod.namespace` value (a string set), not arbitrary namespace
labels. A label-based rewrite would mean restructuring to
`io.cilium.k8s.namespace.labels.*` selectors — high-risk on the cluster-wide
default-deny (every comment in these files warns that a wrong selector locks out
CoreDNS/Flux/webhooks and the GitOps recovery path). Not worth it on a
single-node prod cluster. Documented the duplication as accepted in README §B
above and in review.md #3.

### C. Corrected the README "Reconcile order" section (doc-vs-reality) — DONE
The documented reconcile order had drifted from the actual `dependsOn` graph in
`clusters/prod-fsn/*.yaml`. Verified each with `yq` and rewrote the section:
  - `cert-manager` and `kyverno` actually `dependsOn: kube-prometheus-stack`
    (the ServiceMonitor/PodMonitor CRD ordering from commit 55a8822) — README
    had called them independent / undocumented.
  - `headlamp`, `tsidp`, `tailscale-operator`, `cert-manager-issuers` depend on
    `external-secrets-stores` (Vault-synced secrets) — README said
    `external-secrets` (wrong object) or "independent".
  - `monitoring-extras` and `external-secrets-stores` weren't mentioned at all.
  - `netdata`/`vector` were listed as reconciling, but their cluster
    Kustomizations were removed in finding #2 — they have bases but no cluster
    `Kustomization`, so Flux doesn't install them. Fixed both the "Scaffolded
    stubs" bullet and the reconcile-order text to say so.
Documentation only. Verified `scripts/validate.sh` 36/36.

### D. Fixed stale `external-secrets` → `external-secrets-stores` comment refs — DONE
Two code comments described the cert-manager-issuers dependency as
`dependsOn [cert-manager, external-secrets]`; the actual Flux object depends on
`external-secrets-stores` (the ClusterSecretStore overlay), not the ESO
controller release. Same drift I fixed in the README §C. Corrected:
  - `platform/base/cert-manager-issuers/kustomization.yaml` (header comment)
  - `platform/base/cert-manager/release.yaml` (values comment)
Verified 36/36.

### E. HelmRelease consistency audit — VERIFIED, no change needed
Surveyed all 10 HelmReleases: uniform `interval: 1h`, `install/upgrade`
`remediation.retries: 3`. CRD handling differs by chart on purpose —
external-secrets/kube-prometheus-stack use `CreateReplace`; kyverno uses
`install.crds: Create` + `upgrade.crds: CreateReplace`; cert-manager installs
CRDs via `values.crds.enabled: true` (chart-templated, so Flux's `spec.*.crds`
is correctly absent). No inconsistency worth changing — CRD replacement policy
is risk-sensitive and these reflect deliberate per-chart choices.

### F. Added `tsidp` to the README "Live today" component inventory — DONE
`tsidp` is a live, reconciled component (its own `clusters/prod-fsn/tsidp.yaml`
Flux Kustomization) and the OIDC issuer behind both Headlamp and Grafana logins,
but it was missing from the "Live today" component list — only mentioned in
passing as "tsidp OIDC". Added it to the inventory with a one-line description.
Documentation/accuracy only. Verified 36/36.
(`external-secrets-stores` and `monitoring-extras` are also absent from that
bullet but are glue/sub-components documented in the reconcile-order section, so
left as-is.)

## Session 2026-06-13 (later) — Kyverno policy unit tests

### G. Added `tests/policy/` — assert the Kyverno policies actually fire — DONE
**What I found:** `scripts/policy-check.sh` advertises that it evaluates the
ClusterPolicies "against the manifests the cluster actually deploys, the same way
admission would", but in practice it evaluates almost nothing in-scope. I
rendered the cluster's active `path:` targets and counted resource kinds: the
bundle is 62 objects but only **one** is a real workload (the `tsidp/tsidp`
Deployment), and tsidp's namespace is platform-excluded. Every other workload
lives inside a `HelmRelease` that Flux+Helm only expand into Pods at install
time, so the pod-governing rules (`disallow-latest-tag`, `pod-security-baseline`,
`require-pod-probes`, `require-requests`) have nothing matching to chew on —
`kyverno apply` reported `pass: 1, fail: 0, warn: 0`. A broken match/exclude
block (e.g. a typo in the `platform.io/managed` selector introduced by the
finding-#3 dedup) would sail through CI green.

I considered Helm-expanding the charts in policy-check (the way `image-scan.sh`
already does) so real pods get evaluated — but verified that's a dead end: those
pods all land in `platform.io/managed` namespaces, which the pod policies
deliberately exclude, so they'd be skipped anyway. The policies govern *tenant*
workloads, and `tenants/` is an empty scaffold. There is genuinely zero in-scope
workload in the repo today.

**Fix:** added hand-written fixtures + a native `kyverno test` manifest under
`tests/policy/` and wired `kyverno test tests/policy` as a fourth stage in
`scripts/policy-check.sh` (runs under `just policy` / the PR `policy` job, which
already installs the kyverno CLI). The fixtures prove *both directions*:
  - a compliant tenant pod passes every rule;
  - a violating tenant pod (`:latest`, no probes, no requests, privileged +
    hostNetwork) trips latest-tag / probes / requests / pod-security-baseline;
  - the *same* violating pod in a `platform.io/managed` namespace is **skipped** —
    this is the regression guard for the finding-#3 namespace-exclusion dedup;
  - a `default`-namespace pod trips `disallow-default-namespace`.
`tests/policy/values.yaml` supplies the namespace→labels map (kyverno test does
not read labels off inline Namespace objects, unlike `apply --values-file`).

**Verified:** `kyverno test tests/policy` → 14/14 pass. Sensitivity-checked by
temporarily corrupting the `platform.io/managed` selector in
`require-requests.yaml` → the excluded-pod assertion flipped to `fail` and the
suite went red (exit 1); reverted, back to 14/14 (file diff vs HEAD empty).
`scripts/validate.sh` still 36/36 (the `tests/` tree has no `kustomization.yaml`
and isn't referenced by any cluster Kustomization, so Flux never reconciles it
and kubeconform never builds it). No commits made.

### H. Extended `tests/policy/` to cover `flux-multi-tenancy` — DONE
Followed up on the finding-G question (flux-multi-tenancy was the highest-value
gap — it's the Enforce-mode multi-tenancy guardrail and had zero behavioural
coverage). Added `tests/policy/resources-flux.yaml` and 8 new assertions to
`kyverno-test.yaml` covering all three rules:
  - `serviceAccountName` — compliant tenant Kustomization/HelmRelease pass; one
    missing `.spec.serviceAccountName` fails.
  - `kustomizationSourceRefNamespace` / `helmReleaseSourceRefNamespace` — a
    sourceRef reaching into another namespace (`flux-system`) is denied; same-ns
    passes.
  - exclusion guard — the same SA omission in a `platform.io/managed` namespace
    is skipped.
**Verified:** `kyverno test tests/policy` → 22/22 (was 14). Sensitivity-checked
by corrupting the `platform.io/managed` matchLabels value in
`flux-multi-tenancy.yaml` → `excluded-kustomization` flipped to `fail`, suite red
(21/22); reverted → 22/22, diff vs HEAD empty. Full `scripts/policy-check.sh`
exit 0; `scripts/validate.sh` 36/36. No commits made.

### I. Extended `tests/policy/` to cover `generate-baseline-netpol` — DONE
Followed up on the finding-H question (the outage-critical one). Added coverage
for the `generate` rule in two halves, because `kyverno test` can express the
positive but not the negative:
  - **Positive (kyverno test):** `tests/policy/generated-baseline-cnp.yaml` is the
    expected CiliumNetworkPolicy, asserted via a `generatedResource` result on a
    tenant namespace. Comparing the full spec (same-ns ingress/egress + DNS to
    CoreDNS) catches a regression in the baseline connectivity itself. Kyverno's
    volatile `generate.kyverno.io/*` labels are omitted — `kyverno test` ignores
    them in the comparison.
  - **Negative (policy-check.sh):** `kyverno test` has no "must NOT generate"
    assertion (a `result: skip` on an excluded generate trigger reports
    "Not found", red). So the longhorn-system guard — the 2026-06-12 CSI outage
    behaviour — is checked from `kyverno apply -o` output instead: a 5th stage in
    `scripts/policy-check.sh` renders against `tests/policy/netpol-namespaces.yaml`
    (a tenant ns + longhorn-system) and asserts the tenant ns gets a baseline CNP
    while longhorn-system gets none.
**Verified:** `kyverno test tests/policy` → 23/23 (was 22). Sensitivity-checked
the outage guard by deleting the `- longhorn-system` exclude line →
policy-check.sh exited 1 with "baseline CiliumNetworkPolicy leaked into
longhorn-system (CSI outage risk)"; reverted → exit 0, diff vs HEAD empty.
`scripts/validate.sh` 36/36. No commits made.

### Status of policy test coverage (tests/policy/)
Behaviourally covered now: the 5 pod rules, `flux-multi-tenancy` (3 rules),
`generate-baseline-netpol` (generate + outage guard). `kyverno-cilium-rbac` is
**not a ClusterPolicy** — it's a ClusterRole granting Kyverno RBAC to manage
CiliumNetworkPolicies (already schema-checked by validate.sh), so there is
nothing for `kyverno test` to exercise. Policy unit-test coverage is therefore
complete; no follow-up needed.

### J. Documented the validation / CI workflow in README — DONE
Found a doc gap: the repo grew a `justfile`, `scripts/`, `tests/policy/`, and PR
+ weekly CI workflows (prior sessions), but the README still only covered
bootstrap/reconcile — nothing told a contributor how to validate a change before
pushing or what gates a PR. Added a "## Validating changes" section before
"## Bootstrap": a table of the three PR-gate recipes (`just validate|policy|
secrets`) with what each does and its tooling, a note that `just scan` is the
weekly-not-PR image CVE scan, and a "Policy unit tests" subsection explaining why
`tests/policy/` exists (the tree has ~no in-scope workloads so the evaluation
pass is near-vacuous) and the `longhorn-system` must-not-generate guard. Verified
the recipe names/descriptions against `just --list` and the CI triggers against
the workflow files; the outage cross-link points at the existing
`#platform-namespace-convention` section, which I confirmed describes the
longhorn lockstep. Documentation only — `just check` stays green (exit 0, 23/23
policy tests, no leaks). No commits made.

### K. Completed the README "Repository structure" tree — DONE
Small accuracy fix: the structure tree at the top of README.md listed only
`clusters/`, `platform/`, `tenants/` — it predated the tooling added across these
sessions, so it implied the repo was just the GitOps tree. Added `scripts/`,
`tests/`, `.github/`, and `justfile` to the tree with one-line descriptions.
(Left `notes/` and `review.md` out — they're transient autonomous-session
artifacts, not part of how the repo functions.) Also checked `renovate.json`
while here: its CI-tool-version `customManager` already tracks the `# renovate:`
annotations in the workflow files correctly, so the pins won't go stale — no
change needed. Documentation only. No commits made.

### L. Closed a coverage gap in the policy tests (require-image-tag) — DONE
Reviewing the harness I built in finding G, I found `disallow-latest-tag` has two
rules — `require-image-tag` (image must carry a tag) and `validate-image-tag`
(tag must not be `:latest`) — but the fixtures only exercised the `:latest`
failure. `require-image-tag` had **zero failing-case coverage**, so a regression
to that specific rule (e.g. weakening the `*:*` pattern) would have gone
undetected. Added an `untagged-pod` fixture (`image: nginx`, no tag) in the
tenant namespace and asserted it fails `require-image-tag` while passing
`validate-image-tag`.
**Verified:** `kyverno test tests/policy` → 25/25 (was 23). Sensitivity-checked
by weakening the `require-image-tag` pattern to `"*"` → the untagged-pod
assertion flipped red (24/25); reverted → 25/25, diff vs HEAD empty. Full
`scripts/policy-check.sh` exit 0; `scripts/validate.sh` valid. No commits made.

### M. validate.sh now fails safe on zero-target discovery — DONE
Same bug-class as the iteration-1 finding (a gate that passes without doing
work). `scripts/validate.sh` builds whatever `find` discovers; if both finds
returned nothing — repo restructured, kustomization.yaml renamed — the loops ran
zero times and the script printed "0/0 targets passed, 0 failed" and exited 0 via
"✓ all manifests valid", a false green that would let CI pass while validating
nothing. (CWD isn't the trigger — the script `cd`s to its own repo_root — but a
layout change is.) Added per-phase target counters and a guard: if either the
kustomization or the cluster-object discovery finds zero targets, print a diagnostic
to stderr and exit 1.
**Verified:** normal run still 36/36, exit 0. Copied the script into an empty
fake repo (so both finds return nothing) → exit 1 with "discovery found no
targets (kustomizations=0, cluster objects=0)". No commits made.

### Question for discussion (CI — can't verify locally)
The two workflow files repeat the kustomize-install curl block verbatim 3× (and
`extractions/setup-just@v3` 3×). A composite action under `.github/actions/`
(e.g. `setup-tools` taking which binaries + versions to install) would dedupe it.
I did **not** do this autonomously: I can't run GitHub Actions locally to verify
a composite-action refactor, and a broken `action.yml` path would red every PR.
Worth doing? If so I'll write it and you can confirm on the first PR run. This is
the main remaining structural improvement I can see; most other safe,
locally-verifiable work is done (see summary below).

## Open doubts (need human / live cluster)

### D1. Floating HelmRelease chart versions (`X.x`) vs. reproducibility goal
`platform/base/*/release.yaml` mixes exact pins (traefik `40.3.0`, cert-manager
`v1.20.2`, tailscale `1.98.4`, external-secrets `2.6.0`) with floating ranges
that carry `# TODO: pin exact version` markers:
  - kyverno `3.x`, policy-reporter `3.x`, headlamp `0.42.x`,
    kube-prometheus-stack `86.x`, netdata `3.x`, vector `0.x`
The README states GitOps deployments should be "reproducible"; a floating range
means two reconciles of the same Git SHA can install different chart versions.
**Why I didn't fix it:** pinning requires knowing the version *currently running
in the cluster* (`flux get helmreleases -A` / `helm list -A`). Pinning to the
latest published chart instead would silently trigger an upgrade on the next
reconcile — exactly the kind of unreviewed change to avoid overnight. Renovate's
flux manager won't tighten an already-satisfied range on its own either.
**Action for human:** for each floating component, read the live deployed chart
version and set `version:` to it exactly; Renovate then bumps it via PR like the
already-pinned ones. Low effort, but needs cluster read access I don't have.

### D2. tsidp Deployment has no liveness/readiness probes
`platform/base/tsidp/deployment.yaml` runs without probes. The repo enforces
probes on tenant pods (`require-pod-probes`, Audit) but tsidp's namespace is
exempt. **Why I didn't add them:** tsidp serves OIDC over the tailnet via tsnet
+ Funnel, so its listener is on the tailnet interface, not necessarily a plain
port on the pod IP. A kubelet `httpGet`/`tcpSocket` probe against the pod IP
could fail even when tsidp is healthy and crash-loop a critical auth component.
Confirming the right probe target needs `kubectl exec`/`describe` against the
running pod (which port tsnet binds on the pod IP, if any).
**Action for human:** if a pod-IP-reachable port exists, add a `tcpSocket`
readiness probe on it; otherwise leave probeless and consider documenting why in
the deployment comment.

### D3. tsidp container has a memory request but no memory limit (low priority)
`requests: {cpu: 50m, memory: 64Mi}`, no limits. The repo deliberately doesn't
*require* limits (`require-requests` comment: CPU limits cause throttling). A
**memory** limit has no throttling downside and would cap a runaway on the
single node, but setting it too low would OOM-kill the auth provider. Picking a
safe ceiling needs the observed working-set (Prometheus / `kubectl top`). The
`chown-state` initContainer also has no requests (harmless; not policy-checked).
Optional hardening, not a correctness issue.

### D4. `generate-baseline-netpol` not converted to the `platform.io/managed` selector
Finding #3 deduped 6 of the 7 policy blocks but left
`platform/base/policies/generate-baseline-netpol.yaml` on its explicit
`names:` list. **Why:** (1) it matches on `Namespace` kind, where Kyverno's
`namespaceSelector` resolves against the namespace's *own* labels with semantics
I can't confirm without a live Kyverno; (2) its list carries the
outage-critical `longhorn-system` entry (2026-06-12 CSI outage). A wrong
conversion would either stop generating baseline CNPs for tenant namespaces
(breaking their intra-namespace/DNS connectivity) or generate one into
longhorn-system (re-triggering the outage). **Action for human:** if you want it
deduped, validate the converted policy against a live/kind Kyverno with a test
Namespace carrying `platform.io/managed: "true"` before merging, and keep
`longhorn-system` explicit regardless.
