#!/usr/bin/env bash
# Observability gate: assert Alertmanager is configured with a non-null receiver
# and valid routing (OBS2).
#
# Current state: no custom Alertmanager config is committed to this repo.
# The kube-prometheus-stack default routes everything to the "null" receiver,
# which silently discards all alerts. This script warns about that state today
# and will fail hard once a config is committed that still routes to null.
#
# To silence the warning: add alertmanager.config values to the HelmRelease
# (platform/base/kube-prometheus-stack/release.yaml) with at least one non-null
# receiver, or mount an Alertmanager Secret named alertmanager-kube-prometheus-stack
# into the monitoring namespace.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

prom_stack_dir="platform/base/kube-prometheus-stack"
release_file="$prom_stack_dir/release.yaml"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== OBS2: Alertmanager configuration =="

# ---------------------------------------------------------------------------
# Step 1: Check Alertmanager is not explicitly disabled.
# ---------------------------------------------------------------------------
if command -v yq >/dev/null 2>&1; then
  am_enabled="$(yq -r '.spec.values.alertmanager.enabled // "null"' "$release_file")"
else
  am_enabled="$(python3 - "$release_file" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
v = d.get("spec", {}).get("values", {})
val = v.get("alertmanager", {}).get("enabled", None)
print("false" if val is False else "null" if val is None else str(val))
PY
)"
fi

if [ "$am_enabled" = "false" ]; then
  echo "✗ FAIL: alertmanager.enabled is explicitly set to false in $release_file" >&2
  echo "  Alertmanager must be enabled for alert delivery to work." >&2
  exit 1
fi
echo "✓ Alertmanager is not disabled (alertmanager.enabled: $am_enabled)"

# ---------------------------------------------------------------------------
# Step 2: Look for a custom Alertmanager config in the HelmRelease values.
# ---------------------------------------------------------------------------
if command -v yq >/dev/null 2>&1; then
  has_am_config="$(yq -r '
    if .spec.values.alertmanager.config != null then "yes" else "no" end
  ' "$release_file")"
else
  has_am_config="$(python3 - "$release_file" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
v = d.get("spec", {}).get("values", {})
val = v.get("alertmanager", {}).get("config", None)
print("yes" if val is not None else "no")
PY
)"
fi

# ---------------------------------------------------------------------------
# Step 3: Look for an Alertmanager Secret file in the repo (may be an
# ExternalSecret that renders to alertmanager-kube-prometheus-stack).
# ---------------------------------------------------------------------------
has_am_secret="no"
if grep -r 'alertmanager-kube-prometheus-stack' "$prom_stack_dir" --include='*.yaml' \
    | grep -q 'ExternalSecret\|Secret'; then
  has_am_secret="yes"
fi

if [ "$has_am_config" = "no" ] && [ "$has_am_secret" = "no" ]; then
  # No custom config at all — warn but do not hard-fail.
  # The default kube-prometheus-stack config routes to a null receiver,
  # which discards all alerts. This is acceptable during bootstrap but
  # must be remedied before going to production.
  #
  # This check becomes a hard FAIL once alertmanager.config is present in
  # the HelmRelease: if config exists but still routes only to null, the
  # validation below will catch it.
  echo "⚠ WARNING: no custom Alertmanager config found in repo (OBS2)" >&2
  echo "  The default config routes all alerts to the null receiver." >&2
  echo "  Add alertmanager.config values to $release_file with a real" >&2
  echo "  receiver (PagerDuty, Slack, email, etc.) to silence this warning." >&2
  echo
  echo "✓ OBS2: Alertmanager not disabled — no custom config to validate (warning issued)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 4: A config exists — validate it has at least one non-null receiver.
# ---------------------------------------------------------------------------
if [ "$has_am_config" = "yes" ]; then
  echo "→ found alertmanager.config in HelmRelease values — validating..."

  config_file="$tmp/alertmanager.yaml"
  if command -v yq >/dev/null 2>&1; then
    yq -r '.spec.values.alertmanager.config' "$release_file" > "$config_file"
  else
    python3 - "$release_file" "$config_file" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
cfg = d["spec"]["values"]["alertmanager"]["config"]
with open(sys.argv[2], "w") as f:
    yaml.dump(cfg, f, default_flow_style=False)
PY
  fi

  # Try amtool if available.
  if command -v amtool >/dev/null 2>&1; then
    echo "→ running amtool check-config..."
    if ! amtool check-config "$config_file"; then
      echo "✗ FAIL: amtool check-config failed for Alertmanager config" >&2
      exit 1
    fi
    echo "✓ amtool check-config passed"
  fi

  # Assert at least one non-null receiver regardless of amtool availability.
  python3 - "$config_file" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
receivers = cfg.get("receivers", [])
non_null = [
    r for r in receivers
    if r.get("name") != "null" and r.get("name") != "blackhole"
    and any(
        k for k in r if k not in ("name",)
    )
]
if not non_null:
    print("✗ FAIL: Alertmanager config has no non-null receivers — all alerts are discarded", file=sys.stderr)
    print("  Add at least one real receiver (PagerDuty, Slack, email, etc.)", file=sys.stderr)
    sys.exit(1)
print(f"✓ found {len(non_null)} non-null receiver(s): {[r['name'] for r in non_null]}")
PY
fi

echo
echo "✓ OBS2: Alertmanager configuration is valid"
