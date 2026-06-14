#!/usr/bin/env bash
# Guard against undeclared Flux Kustomizations appearing in clusters.
#
# The platform fleet is defined in platform/fleet/ as a set of Flux Kustomization
# objects. Clusters may opt in to a SUBSET of the fleet (e.g. test-home runs a
# lighter set than prod-fsn — this is intentional and documented). What is NOT
# allowed is a cluster containing Kustomization objects that are not in the fleet
# at all — these represent undeclared platform components that bypass the standard
# fleet lifecycle (versioning, Renovate, policy review).
#
# This script compares BUILT OUTPUT, not file lists:
#
#   1. Build platform/fleet/ → extract all Flux Kustomization metadata.name values
#      → this is the authoritative fleet set.
#   2. Build each cluster → extract all Flux Kustomization metadata.name values.
#   3. Fail if any cluster contains a name NOT in the fleet set (unexpected
#      addition). Missing fleet components are allowed — clusters can be subsets.
#
# Exclusions:
#   - kustomize.config.k8s.io Kustomizations (build configs, not API objects).
#   - flux-system: Flux bootstrap self-reference, always present, not fleet-managed.
#   - tenants: per-cluster tenant aggregation Kustomization, not a fleet component.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v python3 >/dev/null 2>&1; then
  echo "✗ FAIL: python3 is required but not found on PATH" >&2
  exit 1
fi

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "✗ FAIL: python3 PyYAML is required (pip install pyyaml)" >&2
  exit 1
fi

if command -v kustomize >/dev/null 2>&1; then
  build() { kustomize build "$1" --load-restrictor LoadRestrictionsNone; }
else
  build() { kubectl kustomize "$1" --load-restrictor LoadRestrictionsNone; }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Helper: extract Flux Kustomization names from a built YAML stream, excluding
# flux-system (the Flux bootstrap self-reference).
extract_names() {
  local yaml_file="$1"
  python3 - "$yaml_file" <<'PY'
import sys, yaml

FLUX_API = "kustomize.toolkit.fluxcd.io"

with open(sys.argv[1]) as f:
    for doc in yaml.safe_load_all(f):
        if not doc:
            continue
        if doc.get("kind") != "Kustomization":
            continue
        if FLUX_API not in doc.get("apiVersion", ""):
            continue
        meta = doc.get("metadata") or {}
        name = meta.get("name", "")
        # Exclude flux-system (bootstrap self-ref) and tenants (per-cluster, not fleet).
        if name and name not in ("flux-system", "tenants"):
            print(name)
PY
}

echo "== building platform/fleet =="
printf '→ platform/fleet\n'
build platform/fleet > "$tmp/fleet.yaml"
extract_names "$tmp/fleet.yaml" | sort -u > "$tmp/fleet.set"
printf '  %d Flux Kustomization objects in fleet\n' "$(wc -l < "$tmp/fleet.set")"

clusters=(
  clusters/prod-fsn
  clusters/test-home
)

overall_fail=0

for cluster in "${clusters[@]}"; do
  echo
  echo "== comparing $cluster against fleet =="
  printf '→ building %s\n' "$cluster"

  if [ ! -d "$cluster" ]; then
    echo "✗ FAIL: cluster directory not found: $cluster" >&2
    overall_fail=1
    continue
  fi

  build "$cluster" > "$tmp/$(basename "$cluster").yaml"
  extract_names "$tmp/$(basename "$cluster").yaml" | sort -u > "$tmp/$(basename "$cluster").set"
  printf '  %d Flux Kustomization objects in %s\n' "$(wc -l < "$tmp/$(basename "$cluster").set")" "$cluster"

  fleet_set="$tmp/fleet.set"
  cluster_set="$tmp/$(basename "$cluster").set"

  # Names in cluster but not in fleet — these are the problem.
  # Missing fleet components in a cluster are allowed (clusters can be subsets).
  extra="$(comm -13 "$fleet_set" "$cluster_set")"
  missing="$(comm -23 "$fleet_set" "$cluster_set")"

  if [ -n "$extra" ]; then
    overall_fail=1
    echo "  ✗ components in $cluster not in fleet (undeclared — must be added to fleet or removed):"
    printf '    ✗ %s\n' $extra
  else
    echo "✓ $cluster contains no undeclared fleet components"
  fi
  if [ -n "$missing" ]; then
    echo "  (note: $cluster runs a subset — $(echo "$missing" | wc -l | tr -d ' ') fleet components not deployed here, which is allowed)"
  fi
done

echo

if [ "$overall_fail" -ne 0 ]; then
  echo "✗ FAIL: cluster parity check failed — see above." >&2
  exit 1
fi

echo "✓ all clusters contain only fleet-declared components"
