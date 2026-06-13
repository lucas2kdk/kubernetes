# Monitoring and observability

The fleet's metrics stack: `kube-prometheus-stack` (Prometheus + Grafana), the
per-component monitors that feed it, the committed Grafana dashboards, and the
alerting wiring.

See also: [architecture](architecture.md) (the reconcile graph / `dependsOn`),
[components](components.md) (the full component list),
[secrets-and-identity](secrets-and-identity.md) (the tsidp OIDC login Grafana
shares with Headlamp), [operations](operations.md), and the
[top-level README](../README.md).

## kube-prometheus-stack

`platform/base/kube-prometheus-stack/` installs the prometheus-community
`kube-prometheus-stack` chart (`86.2.2`) into the `monitoring` namespace:
Prometheus, Grafana, Alertmanager, kube-state-metrics, node-exporter, and the
Prometheus-Operator.

The namespace is `pod-security.kubernetes.io/enforce: privileged` because
node-exporter needs hostNetwork/hostPID/hostPath/hostPort, which Talos's
cluster-wide `baseline` enforcement rejects. Kyverno policies still apply.

### It owns the Prometheus-Operator CRDs

This HelmRelease installs and **owns** the Prometheus-Operator CRDs —
`ServiceMonitor`, `PodMonitor`, `PrometheusRule` — with `crds: CreateReplace` on
both install and upgrade (so chart bumps pick up CRD schema changes). That makes
it a **reconcile root** in the fleet graph with no `dependsOn`, and every
component that ships a monitor must wait on it. From the fleet graph (see
[architecture](architecture.md)):

- `kyverno`, `cert-manager`, `trivy-operator` — `dependsOn: kube-prometheus-stack`
- `monitoring-extras` — `dependsOn: kube-prometheus-stack`

Applying a `ServiceMonitor`/`PodMonitor`/`PrometheusRule` before these CRDs exist
would fail the dry-run; the `dependsOn` edges break that chicken-and-egg.

### Grafana on the tailnet via tsidp OIDC

Grafana is enabled and reached over the tailnet **only**, via the Tailscale
ingress `ingress.yaml` (`ingressClassName: tailscale`,
`grafana.<tailnet>.ts.net`) — the same zero-public-surface model as Headlamp.
Login is tsidp `generic_oauth`: the native login form is disabled
(`disable_login_form: true`, `oauth_auto_login: true`), the OIDC URLs point at
`idp.${tailnet}.ts.net`, and the client id/secret come from the `grafana-oidc`
Secret (synced by ESO, wired through `envValueFrom` →
`GF_AUTH_GENERIC_OAUTH_CLIENT_{ID,SECRET}`). The Grafana role is derived from the
group claim (`role_attribute_path` → `Admin` if in `k8s-admins`, else `Viewer`).
The full identity/login wiring is in
[secrets-and-identity](secrets-and-identity.md). `${tailnet}` is substituted from
the `fleet-vars` ConfigMap by the fleet Kustomization.

Grafana state is a 2Gi Longhorn PVC holding only SQLite — datasources and
dashboards are all provisioned (chart datasource + the sidecar below), so it
stays tiny.

### Prometheus TSDB sizing (Longhorn)

```yaml
prometheus:
  prometheusSpec:
    retention: 30d
    retentionSize: "85GiB"
    storageSpec:                       # 100Gi Longhorn PVC, RWO
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn
          resources: { requests: { storage: 100Gi } }
```

The TSDB is bounded and self-pruning. `retentionSize` trims the oldest blocks
once the data dir exceeds **85GiB** — deliberately under the **100Gi** PVC so
the WAL and compaction have headroom (Prometheus needs free space to compact;
sizing `retentionSize` *at* the PVC size risks a full disk). `retention: 30d` is
the time ceiling; whichever limit hits first wins.

### ServiceMonitor / PodMonitor / Rule discovery

By default the operator only scrapes monitors the chart itself labels. This
fleet flips that off so monitors committed anywhere in the repo are discovered,
via `prometheusSpec`:

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
podMonitorSelectorNilUsesHelmValues:     false
probeSelectorNilUsesHelmValues:          false
ruleSelectorNilUsesHelmValues:           false
```

With these `false`, a nil selector means "match **everything**, cluster-wide"
instead of "match only chart-labelled". So the cert-manager / kyverno / flux /
longhorn `ServiceMonitor`s and any repo `PrometheusRule` are picked up regardless
of chart labels or namespace.

Grafana dashboards use a separate discovery path — the **sidecar label**
mechanism (see below), not the monitor selectors.

## The committed monitors

| Monitor | Kind | Where it lives | Reconciled by | Target |
|---------|------|----------------|---------------|--------|
| `flux-system` | `PodMonitor` | `kube-prometheus-stack/flux-podmonitor.yaml` | `monitoring-extras` | Flux controllers, `http-prom` port (8080) |
| `longhorn` | `ServiceMonitor` | `kube-prometheus-stack/longhorn-servicemonitor.yaml` | `monitoring-extras` | `longhorn-manager`, `manager` port (9500) `/metrics` |
| cert-manager controller | `ServiceMonitor` | emitted by the cert-manager chart (`prometheus.servicemonitor.enabled`) | `cert-manager` | controller `:9402` metrics |
| Kyverno (per controller) | `ServiceMonitor` | emitted by the kyverno chart (`*.serviceMonitor.enabled` on admission / background / cleanup / reports) | `kyverno` | each controller's `:8000` metrics |
| kubelet / node-exporter / kube-state-metrics | built-in | the chart | `kube-prometheus-stack` | core cluster metrics |

The Flux PodMonitor selects the six Flux controllers by `app` label and relabels
the node name; it mirrors `fluxcd/flux2-monitoring-example`. The Longhorn
ServiceMonitor scrapes a Terraform-installed subsystem — `longhorn-system` is in
the Cilium default-deny exclusion list so the scrape isn't blocked (see the
[top-level README](../README.md#platform-namespace-convention)).

### Why `monitoring-extras` is split out

`platform/base/monitoring-extras/` is a thin Kustomization that **reuses** (not
copies) `flux-podmonitor.yaml` and `longhorn-servicemonitor.yaml` from the
`kube-prometheus-stack` base. It exists as a separate component so its fleet
Kustomization can `dependsOn: kube-prometheus-stack` and apply those CRs only
**after** the operator's CRDs exist. If those monitors were applied in the same
Kustomization as the CRD-installing HelmRelease, they would race the CRDs and
fail. (The cert-manager / kyverno ServiceMonitors don't need this split — they're
emitted by their own already-CRD-dependent HelmReleases.)

## Bundled Grafana dashboards

Five dashboards are committed as `ConfigMap`s under
`platform/base/kube-prometheus-stack/dashboards/`, listed as resources in the
`kube-prometheus-stack` Kustomization:

| File | gnetId | Subject | Grafana folder | Fed by |
|------|--------|---------|----------------|--------|
| `15661-k8s.yaml` | 15661 | Kubernetes cluster monitoring | `Kubernetes` | built-in kubelet / node-exporter / kube-state-metrics |
| `16714-flux2.yaml` | 16714 | Flux2 control plane | `Flux` | flux-system PodMonitor (via `monitoring-extras`) |
| `11001-cert-manager.yaml` | 11001 | cert-manager | `Platform` | cert-manager ServiceMonitor |
| `15987-kyverno.yaml` | 15987 | Kyverno | `Platform` | Kyverno per-controller ServiceMonitors |
| `16888-longhorn.yaml` | 16888 | Longhorn | `Storage` | longhorn ServiceMonitor (via `monitoring-extras`) |

### The sidecar auto-load mechanism

Each `ConfigMap` carries the label `grafana_dashboard: "1"` and the annotation
`grafana_folder: "<folder>"`. The chart's Grafana **dashboard sidecar** is
configured to watch for exactly that:

```yaml
grafana:
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: monitoring
      folderAnnotation: grafana_folder
      provider: { foldersFromFilesStructure: true }
```

The sidecar loads any matching ConfigMap in the `monitoring` namespace and files
it under the annotated folder. Each dashboard reads the **default Prometheus
datasource** (provisioned by the chart). Adding a dashboard is: drop a labelled
ConfigMap in `dashboards/`, list it in the Kustomization — no Grafana restart.

> **envsubst gotcha.** The imported dashboard JSON contains literal `${...}`
> tokens (Grafana template variables) that Flux's `postBuild` envsubst can't
> parse and would fail the whole Kustomization on. The base therefore patches
> every `grafana_dashboard=1` ConfigMap with the
> `kustomize.toolkit.fluxcd.io/substitute: disabled` annotation, so only the
> HelmRelease's `${tailnet}` token gets substituted.

## Alerting

Prometheus is configured to **discover** alert rules cluster-wide:
`ruleSelectorNilUsesHelmValues: false` (above) means any `PrometheusRule` in the
fleet is fed into Prometheus regardless of chart labels. The `monitoring-extras`
component is the intended home for committed `PrometheusRule`s + Alertmanager
routing, and `dependsOn: kube-prometheus-stack` so they land only after the
Prometheus-Operator CRDs exist.

> **Current tree state (verify before relying on it).** The discovery plumbing
> is in place, but as committed in this branch the `monitoring-extras` base
> contains **only** the Flux PodMonitor and the Longhorn ServiceMonitor — there
> are **no `PrometheusRule` manifests and no Alertmanager `config`/receiver
> blocks** anywhere in the tree. The `kube-prometheus-stack` `release.yaml` still
> carries a `# TODO: Alertmanager routing/receivers ... alert rules from repo`
> marker, and the `monitoring-extras` Kustomization/fleet comments describe
> "Alertmanager routing (Discord) + platform alert rules" as the work this branch
> introduces. So the **wiring** (cluster-wide rule discovery, the
> dependsOn-ordered component, the Alertmanager that ships with the chart) is
> ready, but the **rules and Discord routing config are not yet present in the
> repository**. When they are added, expect them under `monitoring-extras` as
> `PrometheusRule` CRs plus Alertmanager `config` (a Discord receiver + a route)
> in the `kube-prometheus-stack` values or an `AlertmanagerConfig` CR.

To confirm what is actually shipping at any point:

```bash
# committed alert rules / Alertmanager config in the repo
grep -rl "kind: PrometheusRule" platform/
grep -rn "alertmanager:\|receivers:\|discord" platform/base/kube-prometheus-stack/

# live rules and Alertmanager state in a cluster
kubectl -n monitoring get prometheusrules
kubectl -n monitoring get alertmanagers,secrets -l app=kube-prometheus-stack
```
