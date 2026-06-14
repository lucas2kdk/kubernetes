#!/usr/bin/env bash
# Observability gate: every Certificate references an existing issuer, and
# production ACME issuers use DNS-01 solvers only (OBS6).
#
# Checks:
#   1. For each cluster (prod-fsn, test-home), build the full manifest set and
#      assert every Certificate's spec.issuerRef resolves to a ClusterIssuer or
#      Issuer present in the same build output.
#   2. For every ClusterIssuer whose ACME server is the Let's Encrypt production
#      endpoint (acme-v02.api.letsencrypt.org), assert all solvers use DNS-01.
#      HTTP-01 on Hetzner requires firewall rules that aren't guaranteed; DNS-01
#      via Cloudflare is the safe, wildcard-capable path.
#
# Current repo state: letsencrypt-production and letsencrypt-test both use
# DNS-01 (Cloudflare) — these checks should pass today.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if command -v kustomize >/dev/null 2>&1; then
  build() { kustomize build "$1" --load-restrictor LoadRestrictionsNone; }
else
  build() { kubectl kustomize "$1" --load-restrictor LoadRestrictionsNone; }
fi

clusters=(
  clusters/prod-fsn
  clusters/test-home
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

overall_fail=0

for cluster_dir in "${clusters[@]}"; do
  cluster_name="$(basename "$cluster_dir")"
  echo "== OBS6: issuer resolution — $cluster_name =="

  rendered="$tmp/$cluster_name.yaml"
  echo "→ building $cluster_dir..."
  if ! build "$cluster_dir" > "$rendered" 2>/dev/null; then
    echo "✗ FAIL: kustomize build $cluster_dir failed" >&2
    overall_fail=1
    echo
    continue
  fi

  result_file="$tmp/$cluster_name-result.txt"

  python3 - "$rendered" "$result_file" <<'PY'
import sys, yaml, json

rendered_path = sys.argv[1]
result_path = sys.argv[2]

certificates = []   # list of {name, namespace, issuerRef: {name, kind}}
issuers = {}        # key: (kind_lower, namespace_or_cluster, name) -> doc
cluster_issuers = []  # ClusterIssuer docs for DNS-01 check

with open(rendered_path) as f:
    for doc in yaml.safe_load_all(f):
        if not doc:
            continue
        kind = doc.get("kind", "")
        meta = doc.get("metadata", {})
        name = meta.get("name", "")
        ns = meta.get("namespace", "")

        if kind == "Certificate":
            ref = doc.get("spec", {}).get("issuerRef", {})
            certificates.append({
                "name": name,
                "namespace": ns,
                "issuerRef": ref,
            })
        elif kind == "ClusterIssuer":
            issuers[("clusterissuer", "", name)] = doc
            cluster_issuers.append(doc)
        elif kind == "Issuer":
            issuers[("issuer", ns, name)] = doc

failures = []

# Check 1: every Certificate's issuerRef resolves.
for cert in certificates:
    ref = cert["issuerRef"]
    ref_kind = ref.get("kind", "Issuer").lower()
    ref_name = ref.get("name", "")
    ref_ns = "" if ref_kind == "clusterissuer" else cert["namespace"]
    key = (ref_kind, ref_ns, ref_name)
    if key not in issuers:
        failures.append(
            f"  unresolved issuerRef: Certificate {cert['namespace']}/{cert['name']}"
            f" -> {ref.get('kind', 'Issuer')}/{ref_name}"
            f" (not found in built output)"
        )

# Check 2: production ACME ClusterIssuers must use DNS-01 only.
acme_production_url = "acme-v02.api.letsencrypt.org"
for ci in cluster_issuers:
    ci_name = ci["metadata"]["name"]
    acme = ci.get("spec", {}).get("acme", {})
    server = acme.get("server", "")
    if acme_production_url not in server:
        continue
    solvers = acme.get("solvers", [])
    for i, solver in enumerate(solvers):
        if "dns01" not in solver:
            http01_keys = [k for k in solver if k not in ("selector",)]
            failures.append(
                f"  production ClusterIssuer '{ci_name}' solver[{i}] uses"
                f" non-DNS-01 method: {http01_keys}"
                f" (HTTP-01 requires open port 80; use DNS-01 instead)"
            )

with open(result_path, "w") as f:
    json.dump({
        "cert_count": len(certificates),
        "issuer_count": len(issuers),
        "failures": failures,
    }, f)
PY

  cert_count="$(python3 -c "import json; d=json.load(open('$result_file')); print(d['cert_count'])")"
  issuer_count="$(python3 -c "import json; d=json.load(open('$result_file')); print(d['issuer_count'])")"
  printf '  certificates: %s  issuers/clusterissuers: %s\n' "$cert_count" "$issuer_count"

  # Print failures if any.
  python3 - "$result_file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for f in d["failures"]:
    print(f)
if d["failures"]:
    sys.exit(1)
PY
  cluster_rc=$?

  if [ "$cluster_rc" -ne 0 ]; then
    echo "✗ FAIL: issuer checks failed for $cluster_name" >&2
    overall_fail=1
  else
    echo "✓ $cluster_name: all Certificate issuerRefs resolve and production issuers use DNS-01"
  fi
  echo
done

if [ "$overall_fail" -ne 0 ]; then
  echo "✗ FAIL: one or more issuer checks failed (OBS6)" >&2
  exit 1
fi

echo "✓ OBS6: all issuer checks passed across all clusters"
