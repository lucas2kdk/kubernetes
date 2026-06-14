#!/usr/bin/env bash
# SEC7 — ExternalSecret → SecretStore reference integrity check.
#
# Every ExternalSecret in a cluster's built output must reference a
# ClusterSecretStore (or SecretStore) that also exists in that cluster's built
# output. A dangling reference causes the ExternalSecret controller to error and
# leaves the target Secret absent, which can silently break workloads that
# depend on it (e.g., missing TS_AUTHKEY crashes tsidp; missing Prometheus
# remote-write credentials disables metrics shipping).
#
# Algorithm per cluster:
#   1. Build the cluster kustomization into a temp file.
#   2. Collect ExternalSecret objects:
#        - spec.secretStoreRef.kind == "ClusterSecretStore" → checked against
#          ClusterSecretStore names (cluster-scoped).
#        - spec.secretStoreRef.kind == "SecretStore" (or kind absent, which
#          defaults to SecretStore) → checked against SecretStore names in the
#          SAME namespace as the ExternalSecret.
#   3. Collect ClusterSecretStore and SecretStore objects.
#   4. Assert every reference resolves.
#
# Clusters checked: clusters/prod-fsn, clusters/test-home.
#
# Exit codes: 0 = all references resolve; 1 = at least one dangling reference.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# ---------------------------------------------------------------------------
# kustomize build helper.
# ---------------------------------------------------------------------------
if command -v kustomize >/dev/null 2>&1; then
  build() { kustomize build --load-restrictor=LoadRestrictionsNone "$1"; }
else
  build() { kubectl kustomize --load-restrictor=LoadRestrictionsNone "$1"; }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== SEC7: ExternalSecret → SecretStore reference integrity =="

overall_fail=0

for cluster in clusters/prod-fsn clusters/test-home; do
  echo
  printf '→ building %s\n' "$cluster"

  manifest_file="$tmp/$(printf '%s' "$cluster" | tr '/' '-').yaml"

  if ! build "$cluster" > "$manifest_file" 2>/dev/null; then
    echo "  WARNING: kustomize build failed for $cluster — skipping" >&2
    continue
  fi

  cluster_fail=0

  python3 - "$manifest_file" "$cluster" <<'PY'
import sys, yaml, collections

manifest_file = sys.argv[1]
cluster       = sys.argv[2]

# Accumulate objects by kind.
external_secrets   = []          # list of dicts
cluster_stores     = set()       # ClusterSecretStore metadata.name values
namespaced_stores  = collections.defaultdict(set)  # namespace -> set of SecretStore names

with open(manifest_file) as fh:
    for doc in yaml.safe_load_all(fh):
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind", "")
        meta = doc.get("metadata", {})
        name = meta.get("name", "<unknown>")
        ns   = meta.get("namespace", "")

        if kind == "ExternalSecret":
            external_secrets.append(doc)
        elif kind == "ClusterSecretStore":
            cluster_stores.add(name)
        elif kind == "SecretStore":
            namespaced_stores[ns].add(name)

fail = 0

if not external_secrets:
    print(f"  WARNING: no ExternalSecret objects found in {cluster} — nothing to check")
    sys.exit(0)

print(f"  found {len(external_secrets)} ExternalSecret(s), "
      f"{len(cluster_stores)} ClusterSecretStore(s), "
      f"{sum(len(v) for v in namespaced_stores.values())} SecretStore(s)")

for es in external_secrets:
    meta   = es.get("metadata", {})
    es_name = meta.get("name", "<unknown>")
    es_ns   = meta.get("namespace", "<unknown>")
    ref     = es.get("spec", {}).get("secretStoreRef", {})
    ref_name = ref.get("name", "")
    ref_kind = ref.get("kind", "SecretStore")  # default per ESO spec

    if not ref_name:
        print(f"  WARNING: ExternalSecret {es_name} (ns={es_ns}) has no secretStoreRef.name")
        continue

    if ref_kind == "ClusterSecretStore":
        if ref_name in cluster_stores:
            print(f"  ✓ ExternalSecret/{es_name} (ns={es_ns}) → ClusterSecretStore/{ref_name}")
        else:
            print(
                f"  ✗ MISSING: ExternalSecret/{es_name} (ns={es_ns}) "
                f"→ ClusterSecretStore/{ref_name} (not found in {cluster})",
                file=sys.stderr,
            )
            fail += 1
    else:
        # SecretStore — namespace-scoped; must exist in same namespace.
        if ref_name in namespaced_stores.get(es_ns, set()):
            print(f"  ✓ ExternalSecret/{es_name} (ns={es_ns}) → SecretStore/{ref_name} (ns={es_ns})")
        else:
            print(
                f"  ✗ MISSING: ExternalSecret/{es_name} (ns={es_ns}) "
                f"→ SecretStore/{ref_name} (ns={es_ns}) (not found in {cluster})",
                file=sys.stderr,
            )
            fail += 1

if fail:
    print(f"\n  ✗ {fail} unresolvable reference(s) in {cluster}", file=sys.stderr)
    sys.exit(1)
else:
    print(f"\n  ✓ all ExternalSecret references resolve in {cluster}")
PY
  cluster_exit=$?
  [ "$cluster_exit" -ne 0 ] && overall_fail=1
done

echo

if [ "$overall_fail" -ne 0 ]; then
  echo "✗ FAIL: one or more ExternalSecret references are unresolvable." >&2
  echo "  Either the ClusterSecretStore/SecretStore is missing from the cluster" >&2
  echo "  kustomization, or the ExternalSecret references the wrong store name." >&2
  exit 1
fi

echo "✓ all ExternalSecret → SecretStore references are resolvable across all clusters"
