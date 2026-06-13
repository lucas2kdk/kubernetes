#!/usr/bin/env bash
# Validate the Flux GitOps tree the same way the cluster reconciles it.
#
#   1. Every kustomization.yaml is built with --load-restrictor LoadRestrictionsNone
#      (bases reference sibling ../ files, so the default restriction would fail —
#      this matches how Flux builds them in-cluster).
#   2. The build output, plus the cluster Flux Kustomization objects under
#      clusters/, is schema-checked with kubeconform against the upstream
#      Kubernetes schemas, the Flux CRD schemas (flux2-schemas) and the
#      community CRD catalog (cert-manager, kyverno, monitoring, ...).
#
# Runs in CI on every PR; also runnable locally if kustomize + kubeconform are
# on PATH (falls back to `kubectl kustomize` when kustomize is absent).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# kustomize binary, or kubectl's built-in as a fallback (both honour the flag).
if command -v kustomize >/dev/null 2>&1; then
  build() { kustomize build "$1" --load-restrictor LoadRestrictionsNone; }
else
  build() { kubectl kustomize "$1" --load-restrictor LoadRestrictionsNone; }
fi

kubeconform_args=(
  -strict
  -summary
  -verbose
  -ignore-missing-schemas
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/{{.ResourceKind}}{{.KindSuffix}}.json'
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)

passed=0
failed=()

kustomization_targets=0
cluster_targets=0

echo "== building & validating kustomizations =="
# Every directory that holds a kustomization.yaml is something Flux can build.
while read -r dir; do
  kustomization_targets=$((kustomization_targets + 1))
  printf '→ %s\n' "$dir"
  if build "$dir" | kubeconform "${kubeconform_args[@]}"; then
    passed=$((passed + 1))
  else
    failed+=("$dir")
  fi
done < <(find . -name kustomization.yaml -not -path './.git/*' -printf '%h\n' | sort -u)

echo "== validating cluster Flux Kustomization objects =="
# The clusters/<name>/*.yaml Flux Kustomization CRs are not part of an
# aggregating kustomization (only flux-system is), so check them directly.
while read -r f; do
  cluster_targets=$((cluster_targets + 1))
  printf '→ %s\n' "$f"
  if kubeconform "${kubeconform_args[@]}" "$f"; then
    passed=$((passed + 1))
  else
    failed+=("$f")
  fi
done < <(find ./clusters -maxdepth 2 -name '*.yaml' -not -path '*/flux-system/*' | sort)

# Fail safe: a gate that validates nothing must not report success. If either
# discovery turns up zero targets the tree moved or we're in the wrong CWD —
# treat it as a failure rather than a green "0/0 passed".
if [ "$kustomization_targets" -eq 0 ] || [ "$cluster_targets" -eq 0 ]; then
  echo
  echo "✗ discovery found no targets (kustomizations=$kustomization_targets, cluster objects=$cluster_targets) — repo layout changed or wrong working directory" >&2
  exit 1
fi

echo
echo "== summary =="
total=$((passed + ${#failed[@]}))
printf '%d/%d targets passed, %d failed\n' "$passed" "$total" "${#failed[@]}"
if [ "${#failed[@]}" -gt 0 ]; then
  echo "failed:"
  printf '  ✗ %s\n' "${failed[@]}"
  exit 1
fi
echo "✓ all manifests valid"
