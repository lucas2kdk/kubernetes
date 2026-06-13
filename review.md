# Ponytail Review — 2026-06-12

## Findings

**1. 14 pass-through overlay kustomizations — RESOLVED 2026-06-13**
`platform/overlays/prod-fsn/{cert-manager,cert-manager-issuers,external-secrets,headlamp,kube-prometheus-stack,kyverno,monitoring-extras,netdata,network,policies,policy-reporter,traefik,tsidp,vector}/kustomization.yaml`

Each file did exactly `resources: - ../../../base/<component>` with no patches. Only `tailscale-operator` and `external-secrets-stores` overlays add real patches; the rest were dead indirection. (Original review said 12 — it missed `cert-manager-issuers` and `monitoring-extras`, which were also pure pass-through; actual count was 14.)

Fixed: repointed the cluster `path:` fields to `./platform/base/<component>` and deleted the 14 overlay dirs. Verified each base renders byte-identically to its former overlay under Flux's `LoadRestrictionsNone` (so reconciliation output is unchanged). README updated to describe the base-direct layout. Re-add an overlay when a second cluster arrives or a real patch is needed.

---

**2. Commented-out cluster files — RESOLVED 2026-06-13**
`clusters/prod-fsn/netdata.yaml`, `clusters/prod-fsn/vector.yaml`

Both files were 100% comments — they compiled to nothing. `clusters/prod-fsn` has no `kustomization.yaml`; Flux globs the directory, and no other Kustomization had a `dependsOn` pointing at `netdata`/`vector`, so deletion changes no reconciliation output.

Fixed: deleted both files. The component manifests still live in `platform/base/{netdata,vector}/`, so re-enabling is just re-adding the Flux Kustomization object (template preserved in this repo's git history).

---

**3. Platform namespace exclusion list duplicated ~9× — RESOLVED 2026-06-13**

The lists turned out to be three distinct variants, not one repeated list (original review oversimplified):
- `flux-multi-tenancy.yaml` (3×) — 12 entries: `flux-system` + the 11 repo-managed namespaces, under `resources.namespaces` (matches Kustomization/HelmRelease).
- `disallow-latest-tag.yaml` (2×), `pod-security-baseline.yaml`, `require-pod-probes.yaml`, `require-requests.yaml` — 15 entries: `kube-system`, `kube-node-lease`, `kube-public`, `flux-system` + the 11 managed, under `resources.namespaces` (matches Pod).
- `generate-baseline-netpol.yaml` (1×) — 16 entries: the 15 **plus `longhorn-system`**, under `resources.names` with `kinds: [Namespace]`.

The common factor across all of them is the same 11 repo-managed namespaces (each has a `platform/base/*/namespace.yaml`).

Fixed: added `platform.io/managed: "true"` to those 11 `namespace.yaml` files, then in the 6 Pod/Kustomization/HelmRelease policy blocks replaced the 11-name managed sub-list with a sibling
```yaml
- resources:
    namespaceSelector:
      matchLabels:
        platform.io/managed: "true"
```
keeping the non-repo-managed namespaces (`kube-system`, `kube-node-lease`, `kube-public`, `flux-system`) as an explicit list — they have no repo manifest to carry the label. Adding a new platform namespace is now a one-line label on its `namespace.yaml` instead of editing 8 policy blocks.

`generate-baseline-netpol.yaml` was **left static on purpose**: it matches on `Namespace` kind (where Kyverno's `namespaceSelector` semantics differ from namespaced-resource matching) and its list carries the outage-critical `longhorn-system` entry (see the 2026-06-12 note in that file). Converting it is a separate, higher-risk change. A new platform namespace still needs a manual add there.

The Cilium `NotIn values:` lists in `default-deny.yaml`, `deny-cloud-metadata.yaml`, and `allow-ingress-from-traefik.yaml` can't use label selectors — those stay explicit.

Verified `kubectl kustomize --load-restrictor LoadRestrictionsNone` builds clean for `platform/base/policies` and the labeled namespace bases. **Before merge, run a `flux diff`/server-side dry-run** — the selector→live-namespace-label binding is a runtime behavior kustomize can't confirm.

---

**4. tsidp uses `:latest` image tag**
`platform/base/tsidp/deployment.yaml` — both container and initContainer

`image: ghcr.io/tailscale/tsidp:latest` on both containers. The tsidp namespace is in the `disallow-latest-tag` exclusion list so the repo's own policy never fires on it. Pin to a semver tag; Renovate can track `ghcr.io/tailscale/tsidp` with a regex `customManager` (same pattern as the Headlamp plugins entry already in `renovate.json`).

---

**5. Empty tenants scaffold — WON'T FIX 2026-06-13 (review was wrong)**
`tenants/base/kustomization.yaml` is `resources: []`, `tenants/overlays/prod-fsn/kustomization.yaml` just includes base, and both dirs have `.gitkeep` files. The whole tree compiles to zero objects.

The original "just delete it" recommendation is a foot-gun: `clusters/prod-fsn/tenants.yaml` is an **active** Flux Kustomization (`path: ./tenants/overlays/prod-fsn`, `prune: true`). Deleting only the scaffold leaves that Kustomization pointing at a missing path — Flux would report it as failed/not-ready on every reconcile. Full removal would mean deleting the cluster `tenants.yaml` too, which tears out the tenant-onboarding entry point.

Decision: **keep it.** An empty Kustomization with `prune: true` reconciles to a clean no-op and costs nothing, while serving as the documented, ready-to-fill slot for the first tenant (the `kustomization.yaml` comments already describe what a tenant base should contain). The marginal `ls`/`grep` noise doesn't justify removing a working mechanism on a single-node cluster. Revisit only if the multi-tenancy direction is abandoned.

---

## Status (2026-06-13)

All five findings are dispositioned:
- #1 overlays collapsed → base-direct (RESOLVED)
- #2 commented cluster files deleted (RESOLVED)
- #3 namespace exclusion lists deduped via `platform.io/managed` label across the
  6 namespaced-resource policy blocks; `generate-baseline-netpol` left static on
  purpose (RESOLVED)
- #4 tsidp pinned to `v0.0.14` + Renovate customManager (RESOLVED)
- #5 empty tenants scaffold kept — the review's "delete it" was a foot-gun given
  the active `tenants` Flux Kustomization (WON'T FIX)
