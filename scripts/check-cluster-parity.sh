#!/usr/bin/env bash
# Guard against cluster drift: every cluster must include all platform fleet components.
#
# The platform fleet is defined in platform/fleet/ as a set of Flux Kustomization
# objects. Each cluster opts in to the fleet by referencing platform/fleet/ in its
# kustomization.yaml. If a cluster omits a fleet component (or adds one not in the
# fleet), it silently diverges from the intended platform baseline. This drift is
# hard to spot by reading files because a cluster's kustomization.yaml might
# reference the whole fleet directory, an overlay might drop entries, or a patch
# might alter names — you cannot trust the file list alone.
#
# This script compares BUILT OUTPUT, not file lists:
#
#   1. Build platform/fleet/ → extract all Flux Kustomization metadata.name values
#      → this is the authoritative fleet set.
#   2. Build each cluster → extract all Flux Kustomization metadata.name values
#      → compare against the fleet set.
#   3. Report any names in the fleet but missing from a cluster (dropped component)
#      or in a cluster but absent from the fleet (unexpected addition).
#
# Exclusions:
#   - kustomize.config.k8s.io Kustomizations (build configs, not API objects).
#   - The flux-system Kustomization (Flux bootstrap self-reference; it is always
#     present in clusters but is not a fleet-managed platform component).
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
        if name and name != "flux-system":
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

  # Names in fleet but missing from the cluster.
  missing="$(comm -23 "$fleet_set" "$cluster_set")"
  # Names in cluster but not in fleet.
  extra="$(comm -13 "$fleet_set" "$cluster_set")"

  if [ -n "$missing" ] || [ -n "$extra" ]; then
    overall_fail=1
    if [ -n "$missing" ]; then
      echo "  fleet components missing from $cluster:"
      printf '    ✗ %s\n' $missing
    fi
    if [ -n "$extra" ]; then
      echo "  components in $cluster not present in fleet (unexpected additions):"
      printf '    ✗ %s\n' $extra
    fi
  else
    echo "✓ $cluster matches fleet set exactly"
  fi
done

echo

if [ "$overall_fail" -ne 0 ]; then
  echo "✗ FAIL: cluster parity check failed — see above." >&2
  exit 1
fi

echo "✓ all clusters include exactly the fleet set"
