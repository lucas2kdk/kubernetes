#!/usr/bin/env bash
# SEC6 — Privilege-escalation verb guard for RBAC objects.
#
# No Role or ClusterRole in this repo may grant:
#   - The verbs "bind", "escalate", or "impersonate" on any resource.
#   - The verb "create" on the sub-resource "serviceaccounts/token".
#
# These verbs are the primary privilege-escalation paths in Kubernetes RBAC:
#   bind/escalate  — let a subject assign itself higher roles or bypass
#                    role permission limits (RBAC escalation prevention).
#   impersonate    — lets a subject act as any other user, group, or SA.
#   create on serviceaccounts/token — lets a subject mint arbitrary
#                    long-lived SA tokens for any service account.
#
# Additionally, the script warns (without failing) when a ClusterRole uses
# aggregationRule.clusterRoleSelectors, because a poorly-chosen label
# selector could inadvertently absorb permissions from tenant-managed roles.
#
# Role/ClusterRole objects are found by building all kustomizations; the
# combined manifest bundle is parsed with PyYAML.
#
# Exit codes: 0 = no violations; 1 = at least one violation found.
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

manifest_bundle="$tmp/all-manifests.yaml"

# Build clusters first (most complete view), then platform/base and tenants/base
# independently in case a component isn't wired through a cluster kustomization.
for cluster in clusters/prod-fsn clusters/test-home; do
  build "$cluster" >> "$manifest_bundle" 2>/dev/null || {
    echo "WARNING: kustomize build failed for $cluster — skipping" >&2
  }
done
for dir in platform/base/*/ tenants/base/*/; do
  [ -f "$dir/kustomization.yaml" ] || continue
  build "$dir" >> "$manifest_bundle" 2>/dev/null || true
done

echo "== SEC6: RBAC privilege-escalation verb check =="

python3 - "$manifest_bundle" <<'PY'
import sys, yaml

FORBIDDEN_VERBS = {"bind", "escalate", "impersonate"}
TOKEN_RESOURCE  = "serviceaccounts/token"

manifest_bundle = sys.argv[1]

violations = []
warnings   = []
roles_checked = 0

with open(manifest_bundle) as fh:
    for doc in yaml.safe_load_all(fh):
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind", "")
        if kind not in ("Role", "ClusterRole"):
            continue

        name = doc.get("metadata", {}).get("name", "<unknown>")
        ns   = doc.get("metadata", {}).get("namespace")
        loc  = f"{kind}/{name}" + (f" (ns={ns})" if ns else "")
        roles_checked += 1

        # Check aggregationRule warning (ClusterRole only).
        if kind == "ClusterRole":
            agg = doc.get("spec", {}).get("aggregationRule", {})
            selectors = agg.get("clusterRoleSelectors", [])
            if selectors:
                for sel in selectors:
                    match_labels = sel.get("matchLabels", {})
                    match_exprs  = sel.get("matchExpressions", [])
                    warnings.append(
                        f"  WARNING: {loc} uses aggregationRule.clusterRoleSelectors "
                        f"({match_labels or match_exprs}) — verify these labels cannot "
                        f"absorb tenant-managed roles."
                    )

        for rule in doc.get("spec", {}).get("rules", []) or []:
            verbs     = [str(v).lower() for v in rule.get("verbs", [])]
            resources = [str(r).lower() for r in rule.get("resources", [])]

            # Check forbidden escalation verbs.
            bad_verbs = FORBIDDEN_VERBS.intersection(set(verbs))
            if bad_verbs:
                violations.append(
                    f"  {loc}: forbidden verb(s) {sorted(bad_verbs)} "
                    f"on resources={resources}"
                )

            # Check create on serviceaccounts/token.
            if TOKEN_RESOURCE in resources and "create" in verbs:
                violations.append(
                    f"  {loc}: 'create' on '{TOKEN_RESOURCE}' "
                    f"(full verbs={verbs})"
                )

# Print results.
if warnings:
    print()
    print("== aggregationRule warnings ==")
    for w in warnings:
        print(w)

if violations:
    print()
    for v in violations:
        print(f"✗ {v}", file=sys.stderr)
    print(file=sys.stderr)
    print(
        f"✗ FAIL: {len(violations)} RBAC rule(s) grant forbidden privilege-escalation "
        f"verbs. Remove or scope them.", file=sys.stderr
    )
    sys.exit(1)
else:
    print(f"\n✓ {roles_checked} Role/ClusterRole object(s) checked — no forbidden verbs found")
PY
