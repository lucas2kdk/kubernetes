#!/usr/bin/env bash
# Observability gate: assert required alert rules exist (OBS1, OBS3, OBS4, OBS7).
#
# OBS1 — Watchdog alert: kube-prometheus-stack ships a Watchdog PrometheusRule
#         by default. Guard against it being disabled via HelmRelease values.
# OBS3 — Flux reconciliation failure alert: assert a PrometheusRule references
#         gotk_reconcile_condition. FAILS until such a rule is added to the repo.
# OBS4 — Kyverno audit violation alert: assert a PrometheusRule references
#         kyverno_policy_results_total. FAILS until such a rule is added.
# OBS7 — Cert expiry SLO alert: assert a PrometheusRule references
#         certmanager_certificate_expiration_timestamp_seconds. FAILS until added.
#
# OBS3, OBS4, and OBS7 are intentionally failing gates: they enforce that alert
# rules for each platform component MUST be committed before the check passes.
# Add the missing PrometheusRule manifests under platform/ to make them green.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

prom_stack_dir="platform/base/kube-prometheus-stack"
release_file="$prom_stack_dir/release.yaml"

# ---------------------------------------------------------------------------
# OBS1 — Watchdog alert
# ---------------------------------------------------------------------------
echo "== OBS1: Watchdog alert =="

# Check that the HelmRelease values do not disable the general default rules
# (which include Watchdog) or explicitly disable Watchdog by name.
watchdog_fail=0

if command -v yq >/dev/null 2>&1; then
  general_disabled="$(yq -r '.spec.values.defaultRules.rules.general // "null"' "$release_file")"
  watchdog_disabled="$(yq -r '.spec.values.defaultRules.disabled.Watchdog // "null"' "$release_file")"
else
  general_disabled="$(python3 - "$release_file" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
v = d.get("spec", {}).get("values", {})
val = v.get("defaultRules", {}).get("rules", {}).get("general", None)
print("false" if val is False else "null" if val is None else str(val))
PY
)"
  watchdog_disabled="$(python3 - "$release_file" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
v = d.get("spec", {}).get("values", {})
val = v.get("defaultRules", {}).get("disabled", {}).get("Watchdog", None)
print("true" if val is True else "null" if val is None else str(val))
PY
)"
fi

if [ "$general_disabled" = "false" ]; then
  echo "✗ FAIL: defaultRules.rules.general is explicitly set to false — Watchdog is disabled" >&2
  watchdog_fail=1
else
  echo "✓ defaultRules.rules.general is not disabled (value: $general_disabled)"
fi

if [ "$watchdog_disabled" = "true" ]; then
  echo "✗ FAIL: defaultRules.disabled.Watchdog is explicitly set to true" >&2
  watchdog_fail=1
else
  echo "✓ defaultRules.disabled.Watchdog is not set to true (value: $watchdog_disabled)"
fi

if [ "$watchdog_fail" -ne 0 ]; then
  echo "  Watchdog is the canary alert; disabling it defeats the dead-man's-switch." >&2
  echo "  Remove the offending values from $release_file." >&2
  exit 1
fi

echo "✓ OBS1: Watchdog alert is enabled"
echo

# ---------------------------------------------------------------------------
# OBS3 — Flux reconciliation failure alert
# ---------------------------------------------------------------------------
echo "== OBS3: Flux reconciliation failure alert =="

if grep -r 'gotk_reconcile_condition' platform/ --include='*.yaml' 2>/dev/null \
    | grep -q 'PrometheusRule\|expr:'; then
  echo "✓ OBS3: found PrometheusRule referencing gotk_reconcile_condition"
else
  echo "✗ FAIL: no PrometheusRule references gotk_reconcile_condition" >&2
  echo "  Add an alert rule for Flux reconciliation failures under platform/." >&2
  echo "  Example expr: gotk_reconcile_condition{status='False'} == 1" >&2
  exit 1
fi
echo

# ---------------------------------------------------------------------------
# OBS4 — Kyverno audit violation alert
# ---------------------------------------------------------------------------
echo "== OBS4: Kyverno audit violation alert =="

if grep -r 'kyverno_policy_results_total' platform/ --include='*.yaml' 2>/dev/null \
    | grep -q 'PrometheusRule\|expr:'; then
  echo "✓ OBS4: found PrometheusRule referencing kyverno_policy_results_total"
else
  echo "✗ FAIL: no PrometheusRule references kyverno_policy_results_total" >&2
  echo "  Add an alert rule for Kyverno audit policy violations under platform/." >&2
  echo "  Example expr: increase(kyverno_policy_results_total{rule_result='fail'}[5m]) > 0" >&2
  exit 1
fi
echo

# ---------------------------------------------------------------------------
# OBS7 — Cert expiry SLO alert
# ---------------------------------------------------------------------------
echo "== OBS7: Certificate expiry SLO alert =="

if grep -r 'certmanager_certificate_expiration_timestamp_seconds' platform/ --include='*.yaml' 2>/dev/null \
    | grep -q 'PrometheusRule\|expr:'; then
  echo "✓ OBS7: found PrometheusRule referencing certmanager_certificate_expiration_timestamp_seconds"
else
  echo "✗ FAIL: no PrometheusRule references certmanager_certificate_expiration_timestamp_seconds" >&2
  echo "  Add a certificate-expiry SLO alert rule under platform/." >&2
  echo "  Example expr: (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 21" >&2
  exit 1
fi
echo

echo "✓ all alert checks passed (OBS1, OBS3, OBS4, OBS7)"
