# List available recipes
default:
    @just --list

# Run every PR check (what CI runs on a pull request)
check: validate policy secrets lint

# Lint the GitHub Actions workflows
lint:
    actionlint

# Build every kustomization the way Flux does and schema-check the output
validate:
    ./scripts/validate.sh

# Evaluate the Kyverno ClusterPolicies against rendered manifests + unit tests
policy:
    ./scripts/policy-check.sh

# Scan the working tree for committed secrets
secrets:
    gitleaks dir . --no-banner --redact --verbose

# Scan all referenced container images for CVEs (weekly in CI, not a PR gate)
scan:
    @./scripts/image-scan.sh
