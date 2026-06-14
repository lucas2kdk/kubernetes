#!/usr/bin/env bash
# Guard against orphaned Flux source objects and dead consumer sourceRefs.
#
# Flux source objects (GitRepository, HelmRepository, OCIRepository) are
# declared once and referenced by consumers: Kustomization objects reference
# them via spec.sourceRef, and HelmRelease objects via spec.chart.spec.sourceRef.
# When a source is declared but never referenced, Flux reconciles it on every
# interval and emits warnings — pure noise that masks real problems. Conversely,
# when a consumer's sourceRef points to a source that doesn't exist in the repo,
# the consumer will fail to reconcile in-cluster, breaking the component silently
# until someone checks the Flux controller logs.
#
# This script catches both directions:
#
#   S1a — orphaned sources: a source object with no consumer pointing at it.
#   S1b — dead references: a consumer whose sourceRef names a non-existent source.
#
# The special case: the self-referential flux-system GitRepository (the source
# that holds THIS repo, bootstrapped by flux) is consumed by the flux-system
# Kustomization that Flux injects into every cluster's flux-system/ directory.
# That Kustomization IS in the built output (clusters/*/flux-system/gotk-sync.yaml)
# and so is the GitRepository — both are found. However the flux-system
# Kustomization's sourceRef points at flux-system, which is also declared, so the
# reference resolves fine. We only skip the flux-system Kustomization's own ref
# as a fallback in case gotk-sync is excluded from the build target set.
#
# Algorithm:
#   1. Build every kustomization.yaml target; collect all output into one stream.
#   2. Parse with Python + PyYAML to extract:
#        - source tuples:   (kind, namespace, name)
#        - consumer refs:   (kind, namespace, name) from spec.sourceRef /
#                           spec.chart.spec.sourceRef
#   3. Compare both sets; report orphans and dead refs. Fail if any found.
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

echo "== building all kustomization targets =="

combined="$tmp/all-resources.yaml"
: > "$combined"

targets=0
while read -r dir; do
  targets=$((targets + 1))
  printf '→ %s\n' "$dir"
  # Prefix each build with --- so yaml.safe_load_all sees clean document boundaries.
  { echo "---"; build "$dir"; } >> "$combined"
done < <(find . -name kustomization.yaml -not -path './.git/*' -not -path './.claude/*' -printf '%h\n' | sort -u)

# clusters/*/flux-system/ contains gotk-sync.yaml (GitRepository + flux-system
# Kustomization) but has no kustomization.yaml — kustomize cannot build it. Cat
# the raw files directly so the bootstrap GitRepository is in the source set.
while read -r f; do
  printf '→ %s (raw)\n' "$f"
  { echo "---"; cat "$f"; } >> "$combined"
done < <(find ./clusters -path '*/flux-system/*.yaml' -not -name kustomization.yaml | sort)

if [ "$targets" -eq 0 ]; then
  echo "✗ FAIL: no kustomization.yaml targets found — wrong working directory?" >&2
  exit 1
fi

echo
echo "== checking source coherence =="

python3 - "$combined" <<'PY'
import sys, yaml

all_docs = []
with open(sys.argv[1]) as f:
    for doc in yaml.safe_load_all(f):
        if doc:
            all_docs.append(doc)

SOURCE_KINDS = {"GitRepository", "HelmRepository", "OCIRepository"}
FLUX_KUSTOMIZATION_API = "kustomize.toolkit.fluxcd.io"
FLUX_HELMRELEASE_API   = "helm.toolkit.fluxcd.io"

# Collect declared sources: key = (kind, namespace, name)
sources = {}
for doc in all_docs:
    kind = doc.get("kind", "")
    api  = doc.get("apiVersion", "")
    if kind in SOURCE_KINDS and "source.toolkit.fluxcd.io" in api:
        ns   = (doc.get("metadata") or {}).get("namespace", "flux-system")
        name = (doc.get("metadata") or {}).get("name", "")
        sources[(kind, ns, name)] = True

# Collect consumer sourceRefs.
# Each entry: (consumer_kind, consumer_ns, consumer_name, ref_kind, ref_ns, ref_name)
consumer_refs = []

for doc in all_docs:
    api  = doc.get("apiVersion", "")
    kind = doc.get("kind", "")
    meta = doc.get("metadata") or {}
    consumer_ns   = meta.get("namespace", "flux-system")
    consumer_name = meta.get("name", "")
    spec = doc.get("spec") or {}

    if kind == "Kustomization" and FLUX_KUSTOMIZATION_API in api:
        sr = spec.get("sourceRef") or {}
        if sr.get("kind") and sr.get("name"):
            ref_ns = sr.get("namespace", consumer_ns)
            consumer_refs.append((
                kind, consumer_ns, consumer_name,
                sr["kind"], ref_ns, sr["name"]
            ))

    elif kind == "HelmRelease" and FLUX_HELMRELEASE_API in api:
        chart = spec.get("chart") or {}
        cspec = chart.get("spec") or {}
        sr    = cspec.get("sourceRef") or {}
        if sr.get("kind") and sr.get("name"):
            ref_ns = sr.get("namespace", consumer_ns)
            consumer_refs.append((
                kind, consumer_ns, consumer_name,
                sr["kind"], ref_ns, sr["name"]
            ))

# Build the set of referenced source keys from all consumers.
referenced = set()
for (ck, cns, cn, rk, rns, rname) in consumer_refs:
    referenced.add((rk, rns, rname))

# S1a: orphaned sources (declared but never referenced).
orphans = [(k, ns, name) for (k, ns, name) in sources if (k, ns, name) not in referenced]

# S1b: dead references (referenced but not declared).
# Skip the self-referential flux-system Kustomization → flux-system GitRepository
# reference only when that GitRepository is absent from the built output (e.g. if
# clusters/*/flux-system/ is excluded from the find targets). Normally gotk-sync.yaml
# is built and the GitRepository is in the combined output, so this skip is a no-op.
dead = []
for (ck, cns, cn, rk, rns, rname) in consumer_refs:
    key = (rk, rns, rname)
    if key not in sources:
        # Grace: skip flux-system self-reference if not declared.
        if ck == "Kustomization" and cn == "flux-system" and rname == "flux-system":
            continue
        dead.append((ck, cns, cn, rk, rns, rname))

fail = 0

if orphans:
    print()
    print(f"  orphaned sources ({len(orphans)} — declared but no consumer references them):")
    for (k, ns, name) in sorted(orphans):
        print(f"    ✗ {k}/{ns}/{name}")
    fail = 1

if dead:
    print()
    print(f"  dead consumer sourceRefs ({len(dead)} — no matching source declared):")
    for (ck, cns, cn, rk, rns, rname) in sorted(dead):
        print(f"    ✗ {ck}/{cns}/{cn}  →  {rk}/{rns}/{rname}")
    fail = 1

if not fail:
    print(f"  sources declared:        {len(sources)}")
    print(f"  consumer refs checked:   {len(consumer_refs)}")
    print()
    print("✓ all sources are referenced and all consumer sourceRefs resolve")
else:
    sys.exit(1)
PY
