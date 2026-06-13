# List available recipes
default:
    @just --list

# Run every PR check (what CI runs on a pull request); fails if any sub-recipe fails
check: validate policy namespaces secrets lint

# Lint the GitHub Actions workflows (actionlint); fails on invalid workflow YAML/shell
lint:
    actionlint

# Build every kustomization the way Flux does and schema-check the output.
# scripts/validate.sh — fails on a kustomize build error or a kubeconform schema
# violation (a malformed manifest), or if discovery finds zero targets.
validate:
    ./scripts/validate.sh

# Evaluate the Kyverno ClusterPolicies against rendered manifests + unit tests.
# scripts/policy-check.sh — fails on an Enforce-mode violation, a policy that won't
# compile, a failing tests/policy fixture, or longhorn-system getting a baseline CNP.
policy:
    ./scripts/policy-check.sh

# Check the four platform-namespace exclusion lists are in lockstep.
# scripts/check-namespace-lists.sh — fails if the lists diverge (the drift guard
# for the 2026-06-12 CSI-outage class of bug), naming the missing/extra namespaces.
namespaces:
    ./scripts/check-namespace-lists.sh

# Scan the working tree for committed secrets (gitleaks); fails if any secret matches
secrets:
    gitleaks dir . --no-banner --redact --verbose

# Scan all referenced container images for CVEs (weekly in CI, not a PR gate).
# scripts/image-scan.sh — fails (exit 1) if any CRITICAL with an available fix is found.
scan:
    @./scripts/image-scan.sh
