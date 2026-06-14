#!/usr/bin/env bash
# Guard against dangling dependsOn references in Flux Kustomization objects.
#
# Flux Kustomization objects can declare spec.dependsOn to order reconciliation:
# a Kustomization will not be applied until all its named dependencies have
# reconciled successfully. If a dependency name in spec.dependsOn[].name does
# not match any actual Kustomization in the same cluster, Flux will wait forever
# for it to become ready — the dependent component never reconciles, and the only
# signal is a controller log line ("dependency not found"). This is silent enough
# to be missed in a PR and only discovered when a component fails to come up in
# the cluster.
#
# This script builds each cluster's full rendered output, collects the set of
# Flux Kustomization metadata.name values (the "available set"), then verifies
# that every spec.dependsOn[].name in every Kustomization is present in that set.
#
# Scope: per-cluster. A dependency is only valid if the referenced Kustomization
# is present in THE SAME CLUSTER. Cross-cluster dependencies are not a Flux
# concept and are not checked here.
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
  echo "== checking dependsOn in $cluster =="

  if [ ! -d "$cluster" ]; then
    echo "✗ FAIL: cluster directory not found: $cluster" >&2
    overall_fail=1
    continue
  fi

  printf '→ building %s\n' "$cluster"
  build_out="$tmp/$(basename "$cluster").yaml"
  build "$cluster" > "$build_out"

  python3 - "$build_out" "$cluster" <<'PY'
import sys, yaml

build_file = sys.argv[1]
cluster    = sys.argv[2]

all_docs = []
with open(build_file) as f:
    for doc in yaml.safe_load_all(f):
        if doc:
            all_docs.append(doc)

FLUX_API = "kustomize.toolkit.fluxcd.io"

# Step 1: collect the available set of Flux Kustomization names in this cluster.
available = set()
for doc in all_docs:
    if doc.get("kind") != "Kustomization":
        continue
    if FLUX_API not in doc.get("apiVersion", ""):
        continue
    meta = doc.get("metadata") or {}
    name = meta.get("name", "")
    if name:
        available.add(name)

# Step 2: for each Kustomization with dependsOn, check every entry.
dangling = []
for doc in all_docs:
    if doc.get("kind") != "Kustomization":
        continue
    if FLUX_API not in doc.get("apiVersion", ""):
        continue
    meta        = doc.get("metadata") or {}
    owner_name  = meta.get("name", "")
    owner_ns    = meta.get("namespace", "flux-system")
    spec        = doc.get("spec") or {}
    depends_on  = spec.get("dependsOn") or []
    for dep in depends_on:
        dep_name = dep.get("name", "")
        if dep_name and dep_name not in available:
            dangling.append((owner_ns, owner_name, dep_name))

if dangling:
    print(f"  dangling dependsOn references in {cluster} ({len(dangling)}):")
    for (ns, owner, dep) in sorted(dangling):
        print(f"    ✗ Kustomization {ns}/{owner}  dependsOn  '{dep}'  (not found in cluster)")
    sys.exit(1)
else:
    deps_total = sum(
        len((doc.get("spec") or {}).get("dependsOn") or [])
        for doc in all_docs
        if doc.get("kind") == "Kustomization" and FLUX_API in doc.get("apiVersion", "")
    )
    print(f"  {len(available)} Kustomization(s) available, {deps_total} dependsOn edge(s) checked")
    print(f"✓ all dependsOn references resolve in {cluster}")
PY
  if [ $? -ne 0 ]; then
    overall_fail=1
  fi

  echo
done

if [ "$overall_fail" -ne 0 ]; then
  echo "✗ FAIL: dangling dependsOn references detected — see above." >&2
  exit 1
fi

echo "✓ all clusters pass dependsOn check"
