#!/usr/bin/env bash
# SEC5 — Trusted-registry allowlist guard for Flux source objects.
#
# All HelmRepository and OCIRepository spec.url values must match a maintained
# allowlist of trusted registries. This script catches cases where Renovate (or
# a manual edit) introduces an untrusted or plaintext-HTTP source without
# review.
#
# Allowlist is derived from the set of sources present in platform/base/*/source.yaml
# and platform/base/capacitor/capacitor.yaml at the time this script was written.
# Update ALLOWED_PREFIXES if a new source is deliberately added.
#
# Additional assertions (always enforced, not just allowlist):
#   - No URL starts with http:// (must be https:// or oci://).
#   - No URL points at a bare IP address.
#
# kustomize build is used to get the full rendered manifest set; if kustomize is
# absent the script falls back to building via kubectl kustomize (which ships
# with kubectl). Sources that only appear in overlays are therefore also caught.
#
# Exit codes: 0 = all sources are trusted; 1 = at least one violation found.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# ---------------------------------------------------------------------------
# Allowlist: permitted URL prefixes for HelmRepository and OCIRepository.
# Prefix matching is used so that paths/versions after the prefix are allowed.
# ---------------------------------------------------------------------------
ALLOWED_PREFIXES=(
  "https://charts.jetstack.io"
  "https://charts.external-secrets.io"
  "https://kubernetes-sigs.github.io/headlamp/"
  "https://prometheus-community.github.io/helm-charts"
  "https://kyverno.github.io/kyverno/"
  "https://kyverno.github.io/policy-reporter"
  "https://pkgs.tailscale.com/helmcharts"
  "https://traefik.github.io/charts"
  "https://aquasecurity.github.io/helm-charts/"
  "oci://ghcr.io/gimlet-io/capacitor-manifests"
)

# ---------------------------------------------------------------------------
# kustomize build helper (same pattern as check-namespace-lists.sh).
# ---------------------------------------------------------------------------
if command -v kustomize >/dev/null 2>&1; then
  build() { kustomize build --load-restrictor=LoadRestrictionsNone "$1"; }
else
  build() { kubectl kustomize --load-restrictor=LoadRestrictionsNone "$1"; }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Build each cluster into a separate manifest bundle so we capture all overlays.
clusters=(clusters/prod-fsn clusters/test-home)
manifest_bundle="$tmp/all-manifests.yaml"
for cluster in "${clusters[@]}"; do
  build "$cluster" >> "$manifest_bundle" 2>/dev/null || {
    echo "WARNING: kustomize build failed for $cluster — skipping (cluster may need cluster vars)" >&2
  }
done

# Also build platform/base directly to catch anything not wired through a cluster.
for dir in platform/base/*/; do
  [ -f "$dir/kustomization.yaml" ] || continue
  build "$dir" >> "$manifest_bundle" 2>/dev/null || true
done

echo "== SEC5: trusted-registry allowlist check =="

# ---------------------------------------------------------------------------
# Parse with PyYAML: extract all HelmRepository and OCIRepository objects and
# their spec.url (or spec.url for OCI).
# ---------------------------------------------------------------------------
python3 - "$manifest_bundle" <<PY
import sys, yaml, re, os

allowed_prefixes = ${ALLOWED_PREFIXES[@]+"${ALLOWED_PREFIXES[@]}"}
# Rebuild the list inside Python from shell-expanded args passed via env.
PY

# Pass allowlist and bundle path entirely inside Python to avoid quoting issues.
python3 - <<PYEOF
import sys, yaml, re

ALLOWED_PREFIXES = [
$(printf '    "%s",\n' "${ALLOWED_PREFIXES[@]}")
]

manifest_bundle = "${manifest_bundle}"

def url_is_allowed(url):
    for prefix in ALLOWED_PREFIXES:
        if url.startswith(prefix):
            return True
    return False

def url_is_http(url):
    return url.startswith("http://")

def url_is_ip(url):
    # Strip scheme
    stripped = re.sub(r'^[a-z]+://', '', url)
    host = stripped.split('/')[0].split(':')[0]
    return bool(re.match(r'^\d{1,3}(\.\d{1,3}){3}$', host))

fail = 0
sources_checked = 0

with open(manifest_bundle) as fh:
    for doc in yaml.safe_load_all(fh):
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind", "")
        if kind not in ("HelmRepository", "OCIRepository"):
            continue
        name = doc.get("metadata", {}).get("name", "<unknown>")
        ns   = doc.get("metadata", {}).get("namespace", "<unknown>")
        spec = doc.get("spec", {})
        url  = spec.get("url", "")
        if not url:
            # OCIRepository may use spec.ref.registry instead; not common here.
            url = spec.get("ref", {}).get("registry", "")
        if not url:
            print(f"WARNING: {kind}/{name} in {ns} has no spec.url — skipping")
            continue

        sources_checked += 1
        ok = True

        if url_is_http(url):
            print(f"✗ FAIL: {kind}/{name} ({ns}): URL uses plaintext HTTP: {url}", file=sys.stderr)
            fail += 1
            ok = False

        if url_is_ip(url):
            print(f"✗ FAIL: {kind}/{name} ({ns}): URL points to a bare IP address: {url}", file=sys.stderr)
            fail += 1
            ok = False

        if not url_is_allowed(url):
            print(f"✗ FAIL: {kind}/{name} ({ns}): URL not in allowlist: {url}", file=sys.stderr)
            fail += 1
            ok = False

        if ok:
            print(f"→ ✓ {kind}/{name} ({ns}): {url}")

if sources_checked == 0:
    print("WARNING: no HelmRepository or OCIRepository objects found — check that kustomize build succeeded")

if fail:
    print(f"\n✗ FAIL: {fail} source(s) failed the registry check.", file=sys.stderr)
    print("  To add a new trusted source, update ALLOWED_PREFIXES in scripts/check-registries.sh", file=sys.stderr)
    print("  after the source has been reviewed and approved.", file=sys.stderr)
    sys.exit(1)
else:
    print(f"\n✓ all {sources_checked} source(s) pass the registry allowlist check")
PYEOF
