#!/usr/bin/env bash
# Evaluate the repo's Kyverno ClusterPolicies against the manifests the cluster
# actually deploys, the same way admission would:
#
#   1. Render every kustomization referenced by an active cluster Kustomization
#      (clusters/<name>/*.yaml `path:` fields) into one resource bundle.
#   2. Build a kyverno Values file mapping each rendered Namespace to its labels,
#      so the policies' `namespaceSelector` excludes resolve in the CLI the way
#      they do at admission (without it, kyverno apply can't see namespace labels
#      and reports false failures for every platform-excluded resource).
#   3. Run `kyverno apply`. Enforce-mode violations fail the build; Audit-mode
#      findings surface as warnings only (mirrors validationFailureAction).
#
# Loading the policies also validates they parse and compile — a malformed
# ClusterPolicy errors here, on top of the schema check in validate.sh.
#
#   4. Run the policy unit tests in tests/policy/ (`kyverno test`). The rendered
#      tree has no in-scope tenant workloads, so step 3 can't prove the
#      pod-governing rules actually fire; the fixtures do, and also guard the
#      platform.io/managed namespace-exclusion against silent regressions.
#   5. Guard generate-baseline-netpol's longhorn-system exclusion (the 2026-06-12
#      CSI outage), which kyverno test can't express, via `kyverno apply` output.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
cluster="${1:-prod-fsn}"

if command -v kustomize >/dev/null 2>&1; then
  build() { kustomize build "$1" --load-restrictor LoadRestrictionsNone; }
else
  build() { kubectl kustomize "$1" --load-restrictor LoadRestrictionsNone; }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== rendering manifests reconciled by clusters/$cluster =="
# Building the cluster's kustomization.yaml emits one Flux Kustomization per
# component it runs — most from the shared platform/fleet/, plus per-cluster CRs
# (tenants, any override). Take each CR's `spec.path` and render it into one
# bundle. Skip the self-referential flux-system sync Kustomization (whose path is
# ./clusters/<name>), which would otherwise re-emit the cluster's own CRs.
build "clusters/$cluster" > "$tmp/cluster-objs.yaml"
while read -r dir; do
  if [ ! -f "$dir/kustomization.yaml" ]; then
    echo "✗ dangling spec.path: $dir has no kustomization.yaml" >&2
    exit 1
  fi
  printf '→ %s\n' "$dir"
  { echo "---"; build "$dir"; } >> "$tmp/resources.yaml"
done < <(python3 - "$tmp/cluster-objs.yaml" <<'PY'
import sys, yaml
seen = set()
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(d, dict):
        continue
    if not d.get("apiVersion", "").startswith("kustomize.toolkit.fluxcd.io"):
        continue
    if d.get("kind") != "Kustomization":
        continue
    if d.get("metadata", {}).get("name") == "flux-system":
        continue
    path = ((d.get("spec") or {}).get("path") or "").strip()
    if path.startswith("./"):
        path = path[2:]
    if path and path not in seen:
        seen.add(path)
        print(path)
PY
)

# Namespace → labels map, so namespaceSelector excludes resolve in the CLI.
python3 - "$tmp/resources.yaml" > "$tmp/values.yaml" <<'PY'
import sys, yaml
ns = [{"name": d["metadata"]["name"], "labels": d.get("metadata", {}).get("labels", {}) or {}}
      for d in yaml.safe_load_all(open(sys.argv[1]))
      if isinstance(d, dict) and d.get("kind") == "Namespace"]
print(yaml.safe_dump({"apiVersion": "cli.kyverno.io/v1alpha1", "kind": "Values",
                      "namespaceSelector": ns}, sort_keys=False))
PY

echo "== applying ClusterPolicies (Enforce fails, Audit warns) =="
# --audit-warn: Audit-mode policies report as warnings, not failures.
# --warn-exit-code 0: warnings alone don't fail the build; real Enforce
# violations and errors still exit 1.
kyverno apply platform/base/policies/ \
  --resource "$tmp/resources.yaml" \
  --values-file "$tmp/values.yaml" \
  --audit-warn \
  --warn-exit-code 0

# The rendered tree has no in-scope tenant workloads (chart pods are Helm-expanded
# at install; the lone source Deployment, tsidp, is in a platform-excluded
# namespace), so the apply above never actually exercises the pod-governing rules.
# The unit tests in tests/policy/ assert those rules fire on known-bad input and
# correctly exempt platform.io/managed namespaces — a broken match/exclude block
# (e.g. a typo in the selector) fails here even though apply stays green.
echo
echo "== running policy unit tests (tests/policy) =="
kyverno test tests/policy

# generate-baseline-netpol's longhorn-system exclusion is the 2026-06-12 CSI
# outage guard, but kyverno test can't assert "must NOT generate". Check it from
# `kyverno apply` output instead: a tenant namespace must get a baseline CNP, and
# longhorn-system must get none.
echo
echo "== guarding generate-baseline-netpol longhorn-system exclusion =="
gen="$tmp/generated.yaml"
kyverno apply platform/base/policies/generate-baseline-netpol.yaml \
  --resource tests/policy/netpol-namespaces.yaml -o "$gen" >/dev/null 2>&1 || true
if ! grep -qE '^[[:space:]]*namespace:[[:space:]]*tenant-netpol$' "$gen"; then
  echo "✗ FAIL: no baseline CiliumNetworkPolicy generated for the tenant namespace"
  exit 1
fi
if grep -q 'longhorn-system' "$gen"; then
  echo "✗ FAIL: baseline CiliumNetworkPolicy leaked into longhorn-system (CSI outage risk)"
  exit 1
fi
echo "✓ tenant namespace gets a baseline CNP; longhorn-system is correctly excluded"

echo
echo "== validating generated CiliumNetworkPolicy schema =="
if [ -s "$gen" ]; then
  if kubeconform \
    -strict \
    -summary \
    -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$gen"; then
    echo "✓ generated CiliumNetworkPolicy is schema-valid"
  else
    echo "✗ generated CiliumNetworkPolicy failed schema validation" >&2
    exit 1
  fi
else
  echo "✗ no generated CNP output to validate" >&2
  exit 1
fi

echo
echo "== asserting generated CNP denies cloud metadata endpoint (169.254.169.254) =="
if grep -q '169.254.169.254' "$gen"; then
  echo "✓ generated CNP contains egress deny for 169.254.169.254/32"
else
  echo "✗ FAIL: generated CiliumNetworkPolicy does not deny 169.254.169.254/32" >&2
  echo "  Hetzner instance metadata is reachable — tenant pods can exfiltrate credentials" >&2
  exit 1
fi
