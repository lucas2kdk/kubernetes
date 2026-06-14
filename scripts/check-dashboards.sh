#!/usr/bin/env bash
# Observability gate: every required platform component has a Grafana dashboard
# ConfigMap labelled grafana_dashboard="1" (OBS5).
#
# Required dashboards (update this list as components are added):
#   cert-manager, flux, kyverno, longhorn, kubernetes
#
# Currently intentionally FAILING (dashboards not yet committed):
#   traefik, external-secrets
#
# To fix a failing check: add a ConfigMap in
# platform/base/kube-prometheus-stack/dashboards/ whose name or data key
# contains the required name (case-insensitive) and carries the label
# grafana_dashboard: "1".
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

prom_stack_dir="platform/base/kube-prometheus-stack"

# Required dashboard names (case-insensitive substring match against ConfigMap
# name or data keys).
required_dashboards=(
  cert-manager
  flux
  kyverno
  longhorn
  kubernetes
  traefik
  external-secrets
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== OBS5: Grafana dashboard coverage =="

# Build the kube-prometheus-stack kustomization to get the rendered ConfigMaps.
echo "→ building $prom_stack_dir..."
if ! kustomize build "$prom_stack_dir" > "$tmp/rendered.yaml" 2>/dev/null; then
  echo "✗ FAIL: kustomize build $prom_stack_dir failed" >&2
  exit 1
fi

# Extract ConfigMap names and data keys that carry grafana_dashboard: "1".
# Output one token per line: "name:<cm-name>" and "key:<data-key>" for each
# matching ConfigMap. Python handles multi-doc YAML.
python3 - "$tmp/rendered.yaml" "$tmp/dashboard-tokens.txt" <<'PY'
import sys, yaml

tokens = []
with open(sys.argv[1]) as f:
    for doc in yaml.safe_load_all(f):
        if not doc:
            continue
        if doc.get("kind") != "ConfigMap":
            continue
        labels = doc.get("metadata", {}).get("labels", {})
        if str(labels.get("grafana_dashboard", "")) != "1":
            continue
        name = doc.get("metadata", {}).get("name", "")
        tokens.append(f"name:{name.lower()}")
        for key in doc.get("data", {}):
            tokens.append(f"key:{key.lower()}")

with open(sys.argv[2], "w") as f:
    f.write("\n".join(tokens) + "\n")

print(f"  found {sum(1 for t in tokens if t.startswith('name:'))} grafana_dashboard ConfigMap(s)")
PY

echo

# For each required dashboard, check that at least one token contains its name.
fail=0
found_list=()
missing_list=()

for dash in "${required_dashboards[@]}"; do
  dash_lower="${dash,,}"
  if grep -qiF "$dash_lower" "$tmp/dashboard-tokens.txt" 2>/dev/null; then
    found_list+=("$dash")
    printf '  ✓ %-20s found\n' "$dash"
  else
    missing_list+=("$dash")
    printf '  ✗ %-20s MISSING\n' "$dash"
    fail=1
  fi
done

echo

if [ "${#found_list[@]}" -gt 0 ]; then
  echo "→ dashboards present (${#found_list[@]}): ${found_list[*]}"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "✗ FAIL: ${#missing_list[@]} required dashboard(s) missing: ${missing_list[*]}" >&2
  echo "  Add a ConfigMap in $prom_stack_dir/dashboards/ with label" >&2
  echo "  grafana_dashboard: \"1\" whose name or data key contains the" >&2
  echo "  missing component name." >&2
  exit 1
fi

echo "✓ OBS5: all ${#required_dashboards[@]} required Grafana dashboards are present"
