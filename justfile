# List available recipes
default:
    @just --list

# Run every PR check (what CI runs on a pull request)
# TODO: add check-alerts and check-dashboards once PrometheusRules and dashboards are authored (tasks #1-5)
check: no-secrets-objects secrets namespaces validate policy lint collisions dependson check-rbac check-issuers check-secret-stores image-digests

# Lint the GitHub Actions workflows
lint:
    actionlint

# Build every kustomization the way Flux does and schema-check the output
validate:
    ./scripts/validate.sh

# Evaluate the Kyverno ClusterPolicies against rendered manifests + unit tests
policy:
    ./scripts/policy-check.sh

# Check the four platform-namespace exclusion lists are in lockstep
namespaces:
    ./scripts/check-namespace-lists.sh

# Scan the working tree for committed secrets
secrets:
    gitleaks dir . --no-banner --redact --verbose

# Scan all referenced container images for CVEs (weekly in CI, not a PR gate)
scan:
    @./scripts/image-scan.sh

# Assert no raw kind: Secret objects exist in the repo
no-secrets-objects:
    @! grep -rn 'kind: Secret' . --include='*.yaml' --exclude-dir=.git | grep -v '^\s*#'

# Verify every Flux source is consumed by at least one workload
sources:
    ./scripts/check-source-coherence.sh

# Check no two Kustomizations share the same (namespace, name) pair
collisions:
    ./scripts/check-kustomization-collisions.sh

# Check both clusters reference identical fleet components (uses built output)
parity:
    ./scripts/check-cluster-parity.sh

# Verify every spec.dependsOn reference resolves to a real Kustomization
dependson:
    ./scripts/check-dependson.sh

# Assert directly-authored images are pinned to immutable @sha256: digests
image-digests:
    ./scripts/check-image-digests.sh

# Check Helm source registry URLs against the trusted allowlist
registries:
    ./scripts/check-registries.sh

# Assert no forbidden RBAC verbs (bind, escalate, impersonate, token-create)
check-rbac:
    ./scripts/check-rbac.sh

# Verify ExternalSecret store references resolve within each cluster
check-secret-stores:
    ./scripts/check-secret-stores.sh

# Assert required alert rules exist (Watchdog, Flux, Kyverno, cert expiry)
check-alerts:
    ./scripts/check-alerts.sh

# Validate Alertmanager routing configuration
check-alertmanager:
    ./scripts/check-alertmanager.sh

# Assert required Grafana dashboards exist for all platform components
check-dashboards:
    ./scripts/check-dashboards.sh

# Verify Certificate objects reference existing ClusterIssuers
check-issuers:
    ./scripts/check-issuers.sh

# Validate custom PrometheusRule files with promtool
check-rules:
    ./scripts/check-rules.sh

# Advisory kube-score pass over rendered prod-fsn manifests (non-blocking)
score:
    kustomize build clusters/prod-fsn --load-restrictor LoadRestrictionsNone | kube-score score -
