#!/usr/bin/env bash
# Weekly container-image CVE scan. NOT a PR gate — CVEs are disclosed
# independently of commits, so this runs on a schedule, not on pull requests.
#
# Image discovery has two sources, because most images live inside the Helm
# charts rather than in the repo:
#   1. helm template each HelmRelease (chart + version + inline values, repo URL
#      from the sibling HelmRepository) and scrape the rendered `image:` fields.
#   2. kustomize build the plain manifests (catches images pinned directly in
#      the repo, e.g. the tsidp Deployment, and anything set in HelmRelease values).
# Charts that fail to template are reported, not skipped silently, so coverage
# gaps are visible.
#
# Each unique image is scanned with Trivy (HIGH + CRITICAL). The script exits 1
# if any CRITICAL is found, so a scheduled run goes red and notifies.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if command -v kustomize >/dev/null 2>&1; then
  build() { kustomize build "$1" --load-restrictor LoadRestrictionsNone; }
else
  build() { kubectl kustomize "$1" --load-restrictor LoadRestrictionsNone; }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Pull every "image:" scalar out of a manifest stream, keeping only plausible
# refs (a registry path; never bare booleans, blank values or pullPolicy).
scrape_images() { grep -oE 'image:[[:space:]]*"?[a-zA-Z0-9][a-zA-Z0-9./_-]+(:[a-zA-Z0-9._-]+)?(@sha256:[a-f0-9]+)?"?' \
                   | sed -E 's/^image:[[:space:]]*"?//; s/"$//' | grep -E '[./]' || true; }

failed_charts=()

echo "== rendering HelmReleases ==" >&2
while read -r rel; do
  dir="$(dirname "$rel")"
  src="$dir/source.yaml"
  name="$(yq -r '.metadata.name' "$rel")"
  ns="$(yq -r '.metadata.namespace' "$rel")"
  chart="$(yq -r '.spec.chart.spec.chart' "$rel")"
  version="$(yq -r '.spec.chart.spec.version' "$rel")"
  url="$(yq -r '.spec.url' "$src" 2>/dev/null || echo '')"
  [ -z "$url" ] && { failed_charts+=("$name (no HelmRepository url)"); continue; }
  yq '.spec.values // {}' "$rel" > "$tmp/values.yaml"
  echo "→ $name ($chart $version)" >&2
  if helm template "$name" "$chart" --repo "$url" --version "$version" \
       -n "$ns" -f "$tmp/values.yaml" --include-crds 2>"$tmp/helmerr"; then
    :
  else
    failed_charts+=("$name ($chart $version)")
    sed 's/^/    /' "$tmp/helmerr" >&2
  fi
done < <(find platform/base -name release.yaml | sort) > "$tmp/rendered.yaml"

echo "== rendering plain manifests ==" >&2
while read -r d; do
  [ -f "$d/kustomization.yaml" ] && build "$d" 2>/dev/null
done < <(find platform tenants -name kustomization.yaml -printf '%h\n' | sort -u) >> "$tmp/rendered.yaml"

scrape_images < "$tmp/rendered.yaml" | sort -u > "$tmp/images.txt"
echo "== discovered $(wc -l < "$tmp/images.txt") unique images ==" >&2

# Scan each image; tally HIGH/CRITICAL from Trivy JSON.
crit_total=0
printf '\n## Weekly image CVE scan\n\n'
printf '| image | HIGH | CRITICAL |\n|---|---:|---:|\n'
while read -r img; do
  [ -z "$img" ] && continue
  trivy image --quiet --scanners vuln --severity HIGH,CRITICAL \
    --format json "$img" > "$tmp/scan.json" 2>/dev/null || { printf '| `%s` | ? | ? (scan error) |\n' "$img"; continue; }
  read -r high crit < <(python3 - "$tmp/scan.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
h=c=0
for r in d.get("Results",[]) or []:
    for v in r.get("Vulnerabilities",[]) or []:
        s=v.get("Severity")
        h+=s=="HIGH"; c+=s=="CRITICAL"
print(h,c)
PY
)
  crit_total=$((crit_total + crit))
  printf '| `%s` | %s | %s |\n' "$img" "$high" "$crit"
done < "$tmp/images.txt"

if [ "${#failed_charts[@]}" -gt 0 ]; then
  printf '\n> ⚠️ charts that failed to template (not scanned): %s\n' "$(IFS=', '; echo "${failed_charts[*]}")"
fi
printf '\n**Total CRITICAL: %d**\n' "$crit_total"

[ "$crit_total" -eq 0 ]
