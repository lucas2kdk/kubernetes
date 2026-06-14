#!/usr/bin/env bash
# Observability gate: validate custom PrometheusRule files with promtool (OBS8).
#
# Finds all YAML files in the repo containing kind: PrometheusRule (excluding
# files under dashboards/ subdirectories, which are Grafana JSON ConfigMaps).
# If none are found, exits 0 — no custom rules is a valid starting state.
# If promtool is not available, falls back to structural YAML validation.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== OBS8: PrometheusRule validation =="

# Find all YAML files with kind: PrometheusRule, skipping dashboards/ dirs.
# (Grafana dashboard ConfigMaps live in dashboards/ and are not Prometheus rules.)
mapfile -t rule_files < <(
  grep -rl 'kind: PrometheusRule' . --include='*.yaml' 2>/dev/null \
    | grep -v '/dashboards/' \
    | sort
)

if [ "${#rule_files[@]}" -eq 0 ]; then
  echo "→ no custom PrometheusRule files found in repo"
  echo "  (this is expected while observability is being bootstrapped)"
  echo
  echo "✓ OBS8: no custom rules to validate — skipping"
  exit 0
fi

echo "→ found ${#rule_files[@]} PrometheusRule file(s):"
for f in "${rule_files[@]}"; do
  printf '    %s\n' "$f"
done
echo

fail=0

for src_file in "${rule_files[@]}"; do
  echo "→ checking $src_file"

  # Extract PrometheusRule documents from potentially multi-doc YAML.
  doc_count="$(python3 - "$src_file" "$tmp" <<'PY'
import sys, yaml, os

src = sys.argv[1]
outdir = sys.argv[2]
slug = src.replace("/", "-").lstrip("-")
count = 0

with open(src) as f:
    for doc in yaml.safe_load_all(f):
        if not doc:
            continue
        if doc.get("kind") != "PrometheusRule":
            continue
        out_path = os.path.join(outdir, f"{slug}-rule{count}.yaml")
        with open(out_path, "w") as out:
            yaml.dump(doc, out, default_flow_style=False)
        count += 1

print(count)
PY
)"

  if [ "$doc_count" -eq 0 ]; then
    echo "  ✓ no PrometheusRule documents (grep matched non-rule content)"
    continue
  fi

  # Validate each extracted PrometheusRule document.
  slug="${src_file//\//-}"
  slug="${slug#-}"
  for i in $(seq 0 $((doc_count - 1))); do
    rule_doc="$tmp/${slug}-rule${i}.yaml"

    # Structural validation: spec.groups[].rules[] must be present and non-empty.
    struct_ok="$(python3 - "$rule_doc" <<'PY'
import sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
groups = doc.get("spec", {}).get("groups", [])
if not groups:
    print("FAIL:spec.groups is empty or missing")
    sys.exit(0)
for j, g in enumerate(groups):
    rules = g.get("rules", [])
    if not isinstance(rules, list):
        print(f"FAIL:groups[{j}].rules is not a list")
        sys.exit(0)
    for k, r in enumerate(rules):
        if "alert" not in r and "record" not in r:
            print(f"FAIL:groups[{j}].rules[{k}] has neither 'alert' nor 'record' key")
            sys.exit(0)
        if "expr" not in r:
            print(f"FAIL:groups[{j}].rules[{k}] is missing 'expr'")
            sys.exit(0)
print("OK")
PY
)"

    if [[ "$struct_ok" == FAIL:* ]]; then
      echo "  ✗ structural validation failed (doc $i): ${struct_ok#FAIL:}" >&2
      fail=1
      continue
    fi
    echo "  ✓ structural validation passed (doc $i)"

    # Run promtool if available.
    if command -v promtool >/dev/null 2>&1; then
      if ! promtool check rules "$rule_doc" 2>&1 | sed 's/^/    /'; then
        echo "  ✗ promtool check rules failed for doc $i" >&2
        fail=1
      else
        echo "  ✓ promtool check rules passed (doc $i)"
      fi
    else
      echo "  → promtool not available; structural validation only"
    fi
  done
done

echo

if [ "$fail" -ne 0 ]; then
  echo "✗ FAIL: one or more PrometheusRule files failed validation (OBS8)" >&2
  exit 1
fi

echo "✓ OBS8: all PrometheusRule files are valid"
