#!/usr/bin/env bash
# Guard against duplicate Flux Kustomization names within a cluster.
#
# Every Flux Kustomization object is identified by (metadata.namespace,
# metadata.name). If two Kustomization objects in the same cluster share that
# pair, the Flux controller silently overwrites the first with the second during
# reconciliation. The overwritten one never runs, the component it manages stops
# being reconciled, and there is no error — only drift. This is particularly
# likely when the same platform/fleet component is included both via the fleet
# directory reference and as an individual file reference in a cluster's
# kustomization.yaml, or when two platform components are given the same name.
#
# This script builds the full rendered output for each cluster and asserts that
# no two Flux Kustomization objects share a (namespace, name) pair.
#
# Only kustomize.toolkit.fluxcd.io Kustomization objects are checked — the
# kustomize.config.k8s.io kind is a build config, not an API object.
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

clusters=(
  clusters/prod-fsn
  clusters/test-home
)

overall_fail=0

for cluster in "${clusters[@]}"; do
  echo "== checking Kustomization name collisions in $cluster =="

  if [ ! -d "$cluster" ]; then
    echo "✗ FAIL: cluster directory not found: $cluster" >&2
    overall_fail=1
    continue
  fi

  printf '→ building %s\n' "$cluster"
  build_out="$tmp/$(basename "$cluster").yaml"
  build "$cluster" > "$build_out"

  python3 - "$build_out" "$cluster" <<'PY'
import sys, yaml, collections

build_file = sys.argv[1]
cluster    = sys.argv[2]

all_docs = []
with open(build_file) as f:
    for doc in yaml.safe_load_all(f):
        if doc:
            all_docs.append(doc)

FLUX_API = "kustomize.toolkit.fluxcd.io"

# Collect (namespace, name) for every Flux Kustomization.
counts = collections.Counter()
for doc in all_docs:
    if doc.get("kind") != "Kustomization":
        continue
    if FLUX_API not in doc.get("apiVersion", ""):
        continue
    meta = doc.get("metadata") or {}
    ns   = meta.get("namespace", "flux-system")
    name = meta.get("name", "")
    counts[(ns, name)] += 1

total = sum(counts.values())
collisions = {k: v for k, v in counts.items() if v > 1}

if collisions:
    print(f"  ✗ collisions found in {cluster} ({len(collisions)} pair(s)):")
    for (ns, name), count in sorted(collisions.items()):
        print(f"      namespace={ns}  name={name}  (appears {count} times)")
    sys.exit(1)
else:
    print(f"  {total} Flux Kustomization object(s), all names unique")
    print(f"✓ no collisions in {cluster}")
PY
  if [ $? -ne 0 ]; then
    overall_fail=1
  fi

  echo
done

if [ "$overall_fail" -ne 0 ]; then
  echo "✗ FAIL: Kustomization name collisions detected — see above." >&2
  exit 1
fi

echo "✓ all clusters pass collision check"
