# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repository.

## What this repo is

A **Flux multi-tenancy GitOps** repo that manages a cluster fleet (`prod-fsn`,
`test-home`) from one Git tree. Terraform owns infrastructure; **Flux owns
everything inside Kubernetes**. There is no application code here — it is
declarative YAML (Flux `Kustomization`s, Helm `HelmRelease`s, Kyverno
`ClusterPolicy`s, Cilium network policies) plus validation scripts.

Read [`README.md`](README.md) for the quickstart and [`docs/`](docs/) for the
per-topic deep reference ([architecture](docs/architecture.md),
[components](docs/components.md), [networking](docs/networking.md),
[policies](docs/policies.md), [secrets-and-identity](docs/secrets-and-identity.md),
[monitoring](docs/monitoring.md), [operations](docs/operations.md),
[gitlab-ci-image-builds](docs/gitlab-ci-image-builds.md)).

## Platform vs tenant: the dividing line

**Platform provides capabilities; tenants are the instances that consume them.**

If a thing gives tenants the ability to create their own resources — an
operator, a shared controller, cluster-wide infrastructure (ingress, secrets,
certs, storage classes) — it is **platform**. If it is a concrete instance of a
workload — a Deployment, an app, a database `Cluster` CR — it is a **tenant**.

Rule of thumb: **the operator is platform; the CRs that operator reconciles are
tenant.** Installing the CloudNativePG or Redis operator (so any tenant can
declare a Postgres/Redis) is platform. A bare StatefulSet running Redis for one
app is *not* platform — that's a tenant workload. "Giving the tenant the
resources to make their own things is platform."

This also maps to the two sync sources: platform ships via the OCI
release+promote flow, tenants reconcile from `main` directly (see
[docs/architecture.md](docs/architecture.md)). A change spanning both layers
(e.g. add an operator, then a tenant instance of it) goes live in two stages.

### Datastore & storage operators (platform-provided capability)

The platform runs three operators so tenants can declare their own stateful
backends — the operators own no data, the instance CRs live in the tenant:

- **CloudNativePG** (`platform/base/cloudnative-pg`, ns `cnpg-system`) —
  `postgresql.cnpg.io` `Cluster`/`Database` CRDs for Postgres.
- **Redis operator** (`platform/base/redis-operator`, ns `redis-operator`,
  OT-Container-Kit) — `redis.redis.opstreelabs.in` `Redis` CRD.
- **MinIO operator** (`platform/base/minio-operator`, ns `minio-operator`) —
  `minio.min.io` `Tenant` CRD for S3-compatible object storage.

All three operator namespaces are in the four namespace-exclusion lists (they
reach the instance pods they manage in tenant namespaces). The `gitlab` tenant
is the first consumer of all three. New stateful tenant → declare the CR against
the operator; don't hand-roll a StatefulSet.

## Validate before you finish

Every change must pass the same gate CI runs. Run it locally:

```bash
just check        # validate + policy + namespaces + secrets + lint (the PR gate)
```

Individual recipes when iterating:

```bash
just validate     # kustomize build + kubeconform schema-check (falls back to kubectl)
just policy       # kyverno eval of rendered manifests + tests/policy/ unit tests
just namespaces   # the four-list namespace-exclusion drift guard
just secrets      # gitleaks scan of the working tree
just lint         # actionlint on the workflows
```

`just check` is the source of truth — **do not call a YAML change done until it
passes.** `just scan` (weekly image CVE scan) is not part of the gate.

## Layout (where things live)

- `clusters/<name>/` — thin per-cluster entry point: `flux-system/` (bootstrap,
  generated — **never hand-edit**), `cluster-vars.yaml`, `kustomization.yaml`
  (which components this cluster runs), per-cluster Flux CRs (`tenants.yaml`).
- `platform/fleet/` — one Flux `Kustomization` per component, **the `dependsOn`
  reconcile graph defined once for the whole fleet.** `_defaults.yaml` patches
  shared spec defaults onto all of them.
- `platform/base/<component>/` — reusable Kustomize base (`namespace.yaml`,
  `source.yaml`, `release.yaml`, or plain manifests).
- `platform/overlays/<cluster>/<component>/` — **structural** per-cluster diffs
  only (currently just test-home's `external-secrets-stores` AppRole auth).
- `tenants/{base,overlays}/` — tenant namespaces, RBAC, workloads.
- `scripts/`, `tests/policy/`, `.github/workflows/`, `justfile`.

## Critical conventions and gotchas

These are the things that have caused real incidents or that the tooling
enforces. Violating them breaks the build or the cluster.

1. **Never hand-edit `clusters/*/flux-system/`.** Those files are Flux-bootstrap
   generated.

2. **The four namespace-exclusion lists must stay set-identical.** The three
   Cilium `NotIn` lists (`platform/base/network/{default-deny,
   deny-cloud-metadata,allow-ingress-from-traefik}.yaml`) plus
   `platform/base/policies/generate-baseline-netpol.yaml`'s `names:` list. They
   cannot be deduplicated (Flux list substitution breaks `kubeconform`).
   `scripts/check-namespace-lists.sh` (`just namespaces`) fails the build on any
   drift. Editing one means editing all four. `longhorn-system` must be in all
   four (a 2026-06-12 CSI storage outage came from this drifting).
   `allow-ingress-from-monitoring.yaml` is **not** part of the guarded set —
   don't assume its list matches.

3. **New platform component → exclude its namespace in three places.** Label its
   `namespace.yaml` with `platform.io/managed: "true"` (covers most Kyverno
   policies automatically), then add it to `generate-baseline-netpol.yaml`'s
   `names:` and all three Cilium `NotIn` lists by hand. See README "Platform
   namespace convention".

4. **Per-cluster variation rule.** Per-cluster *values* → put a `${var}` token in
   the base and add it to the cluster's `cluster-vars` ConfigMap (Flux substitutes
   it via the fleet `Kustomization`'s `postBuild.substituteFrom`). Per-cluster
   *structure* → an overlay plus a per-cluster Flux `Kustomization` CR (because
   `spec.path` can't be substituted). Don't add empty pass-through overlay layers.

5. **Reconcile order lives in `platform/fleet/` `dependsOn`, defined once.** Don't
   copy ordering into cluster folders. If a component ships a ServiceMonitor/
   PodMonitor/PrometheusRule it must `dependsOn: kube-prometheus-stack` (the
   Prometheus-Operator CRDs). See README "Reconcile order" /
   [docs/architecture.md](docs/architecture.md).

6. **Helm chart versions are Renovate-managed and pinned** (`version: "x.y.z"
   # Renovate-managed`). Use full `registry/repository/tag` for any image so
   Renovate can bump it and the CVE scan tracks a fixed ref. Don't use `:latest`
   (a Kyverno policy forbids it).

7. **Resource limits matter on this single-node cluster.** Kyverno controller
   memory limits were raised to 512Mi after a 2026-06-12 page-cache thrash
   incident; `forceFailurePolicyIgnore` is on so a node drain can't deadlock on
   the webhook. Don't lower these without understanding the incident notes in
   `platform/base/kyverno/release.yaml`.

8. **When you add/change a `ClusterPolicy`, update its `tests/policy/` fixture.**
   `just policy` runs the `kyverno test` suite; an unpinned policy change fails it.

## Commenting and documentation style

Inline comments in this repo explain **why**, not what — rationale, gotchas,
ordering, cross-file coupling, and links to the incident that motivated a value.
Match the density of `platform/base/kyverno/release.yaml` and
`scripts/check-namespace-lists.sh`. Do **not** restate obvious YAML keys. When
you change behaviour, update both the inline comment and the relevant `docs/`
page so they don't drift.

## Workflow

- Work on a branch, never commit directly to `main`.
- Run `just check` and make it pass before opening a PR.
- Commit/push only when asked.
- **GitHub CLI must use the `lucas2kdk` account** — it owns write access to this
  repo. If `gh` PR/merge calls fail with "must be a collaborator", the active
  account drifted (e.g. to `lucas-christensen`, which is read-only here); fix it
  with `gh auth switch --user lucas2kdk`.
