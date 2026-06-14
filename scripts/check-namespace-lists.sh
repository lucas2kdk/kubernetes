#!/usr/bin/env bash
# Drift guard for the platform-managed namespace exclusion lists.
#
# The set of platform/system namespaces that are EXEMPT from the tenant
# guardrails is hand-maintained in FOUR lockstep places (see the "Platform
# namespace convention" section of README.md, which documents this requirement):
#
#   1. platform/base/network/default-deny.yaml            (Cilium NotIn values)
#   2. platform/base/network/deny-cloud-metadata.yaml     (Cilium NotIn values)
#   3. platform/base/network/allow-ingress-from-traefik.yaml (Cilium NotIn values)
#   4. platform/base/policies/generate-baseline-netpol.yaml  (Kyverno exclude names)
#
# These four lists MUST stay set-identical.
#
# A fifth file, allow-ingress-from-monitoring.yaml, also uses a NotIn
# endpointSelector but intentionally carries a SUPERSET of the platform
# list (it additionally excludes netdata and vector, which run their own
# ingress policies). It is tracked separately to prevent accidental removals
# but is NOT required to be set-identical to the four above. They can't be deduplicated into one
# source: Flux runtime substitution of a YAML list breaks kubeconform, and the
# files live in two different kustomize builds with different field semantics.
# So drift is only caught by this guard.
#
# Why it matters: on 2026-06-12 longhorn-system was present in three lists but
# the lists fell out of lockstep, and generate-baseline-netpol injected a
# baseline CNP into longhorn-system. That flipped it into default-deny and cut
# the CSI sidecars off from the kube-apiserver — the provisioner crash-looped
# and PVCs stuck Pending (a cluster-wide storage outage). A silent one-line
# divergence in any of these files reproduces that class of outage.
#
# This script extracts the namespace set from each file and fails if they are
# not all identical, making such drift impossible to merge unnoticed. It changes
# no policy behaviour — it only compares.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# The four files whose lists MUST be set-identical.
cilium_files=(
  platform/base/network/default-deny.yaml
  platform/base/network/deny-cloud-metadata.yaml
  platform/base/network/allow-ingress-from-traefik.yaml
)
# Files that also use NotIn but carry an intentionally different (superset) list.
# Listed here so the S6 self-coverage check accounts for them.
notin_superset_files=(
  platform/base/network/allow-ingress-from-monitoring.yaml
)
kyverno_file=platform/base/policies/generate-baseline-netpol.yaml

# Extractors. Prefer yq (robust YAML parser); fall back to python3 + PyYAML,
# the same engine scripts/policy-check.sh already relies on.
if command -v yq >/dev/null 2>&1; then
  # Cilium files: the matchExpression whose operator is NotIn -> its values.
  extract_cilium() {
    yq -r '
      .spec.endpointSelector.matchExpressions[]
      | select(.operator == "NotIn")
      | .values[]
    ' "$1"
  }
  # Kyverno file: the exclude resources block -> names.
  extract_kyverno() {
    yq -r '
      .spec.rules[].exclude.any[].resources.names[]
    ' "$1"
  }
else
  extract_cilium() {
    python3 - "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for e in d["spec"]["endpointSelector"]["matchExpressions"]:
    if e.get("operator") == "NotIn":
        for v in e.get("values", []):
            print(v)
PY
  }
  extract_kyverno() {
    python3 - "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for rule in d["spec"]["rules"]:
    for item in rule.get("exclude", {}).get("any", []):
        for n in item.get("resources", {}).get("names", []):
            print(n)
PY
  }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Collect the sorted, unique namespace set for every file, keyed by file path.
slug() { printf '%s' "${1//\//-}"; }

files=("${cilium_files[@]}" "$kyverno_file")
for f in "${cilium_files[@]}"; do
  extract_cilium "$f" | sort -u > "$tmp/$(slug "$f").set"
done
extract_kyverno "$kyverno_file" | sort -u > "$tmp/$(slug "$kyverno_file").set"

# Reference set = the first file; everything is compared against it.
ref="${files[0]}"
ref_set="$tmp/$(slug "$ref").set"

echo "== checking platform-namespace exclusion lists are in lockstep =="
for f in "${files[@]}"; do
  printf '→ %s (%d namespaces)\n' "$f" "$(wc -l < "$tmp/$(slug "$f").set")"
done

drift=0
for f in "${files[@]}"; do
  [ "$f" = "$ref" ] && continue
  cur_set="$tmp/$(slug "$f").set"
  if ! diff -q "$ref_set" "$cur_set" >/dev/null; then
    drift=1
    echo
    echo "✗ DRIFT: $f differs from $ref"
    # Lines only in ref = missing from this file; only in cur = extra here.
    missing="$(comm -23 "$ref_set" "$cur_set")"
    extra="$(comm -13 "$ref_set" "$cur_set")"
    if [ -n "$missing" ]; then
      echo "  missing from $f (present in $ref):"
      printf '    - %s\n' $missing
    fi
    if [ -n "$extra" ]; then
      echo "  extra in $f (absent from $ref):"
      printf '    - %s\n' $extra
    fi
  fi
done

if [ "$drift" -ne 0 ]; then
  echo
  echo "✗ FAIL: the four platform-namespace exclusion lists are NOT set-identical." >&2
  echo "  Fix every file above so all four lists match (see README 'Platform" >&2
  echo "  namespace convention' and the 2026-06-12 longhorn-system CSI outage)." >&2
  exit 1
fi

echo
echo "== canonical platform-namespace set =="
nl -ba -w2 -s'. ' "$ref_set" | sed 's/^/  /'
echo
echo "✓ all four lists are set-identical ($(wc -l < "$ref_set") namespaces)"

echo
echo "== asserting exclusion guard covers all NotIn network policy files =="
# Every file in platform/base/network/ that uses a NotIn matchExpression must
# be declared in either cilium_files (lockstep) or notin_superset_files
# (intentionally different superset). A new such file without a matching entry
# here will fail CI, preventing silent drift outside the guard.
all_known_notin_files=("${cilium_files[@]}" "${notin_superset_files[@]}")
actual_notin_files=$(grep -rl 'operator: NotIn' platform/base/network/ 2>/dev/null | sort | wc -l | tr -d ' ')
declared_files=${#all_known_notin_files[@]}
if [ "$actual_notin_files" -ne "$declared_files" ]; then
  echo "✗ FAIL: $actual_notin_files network policy files contain 'operator: NotIn' but" >&2
  echo "  only $declared_files are declared in this script (cilium_files + notin_superset_files)." >&2
  echo "  Add the new file to cilium_files (if it must match the lockstep set)" >&2
  echo "  or to notin_superset_files (if it intentionally differs)." >&2
  echo "  Files with NotIn:" >&2
  grep -rl 'operator: NotIn' platform/base/network/ | sort | sed 's/^/    /' >&2
  exit 1
fi
echo "✓ exclusion guard covers all $declared_files NotIn network policy files"
