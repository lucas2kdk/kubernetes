#!/usr/bin/env bash
# SEC3 — Image digest pin guard for directly-authored manifests.
#
# Every image: field in a directly-authored manifest (i.e. not a Helm chart
# values file) must be pinned to an immutable @sha256: digest. Mutable tags
# like :latest or :v1.2.3 are unacceptable because a registry push can silently
# replace the image between deploy and the next pod restart, making rollbacks
# non-deterministic and bypassing supply-chain attestation.
#
# Scope: platform/base/tsidp/ — the only directly-authored Deployment in this
# repo. Helm-managed images are excluded here; Trivy handles those at runtime.
#
# Additionally, the script broadly scans platform/base/ for any image: field
# outside of Helm-managed component directories (those containing a release.yaml
# alongside them). Such files are printed as warnings — the guard does not fail
# on them in case the scope legitimately expands — but they should be reviewed.
#
# Exit codes: 0 = all scoped images are digest-pinned; 1 = at least one is not.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# ---------------------------------------------------------------------------
# Helper: extract image: values from a YAML file, skipping comment lines.
# ---------------------------------------------------------------------------
extract_images() {
  python3 - "$1" <<'PY'
import sys, re

path = sys.argv[1]
with open(path) as fh:
    for line in fh:
        stripped = line.strip()
        if stripped.startswith('#'):
            continue
        m = re.match(r'.*\bimage:\s*(\S+)', line)
        if m:
            print(m.group(1))
PY
}

# ---------------------------------------------------------------------------
# Phase 1 — mandatory check on the tsidp directory (the authoritative scope).
# ---------------------------------------------------------------------------
echo "== SEC3: image digest pins — platform/base/tsidp/ =="

fail=0
found=0
while IFS= read -r -d '' yaml_file; do
  images=$(extract_images "$yaml_file") || true
  [ -z "$images" ] && continue
  while IFS= read -r img; do
    [ -z "$img" ] && continue
    found=$((found + 1))
    if printf '%s' "$img" | grep -q '@sha256:'; then
      printf '→ ✓ %s  (%s)\n' "$img" "$yaml_file"
    else
      printf '→ ✗ %s  (%s)\n' "$img" "$yaml_file" >&2
      fail=1
    fi
  done <<< "$images"
done < <(find platform/base/tsidp -name '*.yaml' -print0)

if [ "$found" -eq 0 ]; then
  echo "✗ FAIL: no image: fields found under platform/base/tsidp/ — expected at least one." >&2
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "✗ FAIL: one or more images in platform/base/tsidp/ are not pinned to @sha256: digests." >&2
  echo "  Re-tag with: crane digest <image>:<tag>  then use  <image>@sha256:<hash>" >&2
  exit 1
fi

echo
echo "✓ all $found image(s) in platform/base/tsidp/ are digest-pinned"

# ---------------------------------------------------------------------------
# Phase 2 — broad advisory scan across platform/base/ (warns, does not fail).
# Helm-managed dirs are identified by the presence of a release.yaml sibling.
# ---------------------------------------------------------------------------
echo
echo "== SEC3: advisory scan — platform/base/ (non-Helm directories) =="

warn=0
while IFS= read -r -d '' yaml_file; do
  dir="$(dirname "$yaml_file")"
  # Skip dirs that contain a release.yaml — those are Helm-managed.
  [ -f "$dir/release.yaml" ] && continue
  images=$(extract_images "$yaml_file") || true
  [ -z "$images" ] && continue
  while IFS= read -r img; do
    [ -z "$img" ] && continue
    if ! printf '%s' "$img" | grep -q '@sha256:'; then
      printf '→ WARNING: unpinned image %s  (%s)\n' "$img" "$yaml_file"
      warn=1
    fi
  done <<< "$images"
done < <(find platform/base -name '*.yaml' -print0)

if [ "$warn" -ne 0 ]; then
  echo
  echo "  The above images are outside the primary scope (Helm dirs excluded) but"
  echo "  are not digest-pinned. Review whether they should be added to the scope."
else
  echo "✓ no unpinned images found outside Helm-managed directories"
fi
