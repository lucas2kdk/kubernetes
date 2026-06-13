# Scaling the fleet: keeping the repo simple at 10+ clusters

> Status: **implemented** on branch `feat/fleet-dry-scaling`. This started as a
> proposal; the as-built notes below record what shipped and the one mechanism
> that changed during implementation (R3 — see its section). Each recommendation
> still stands on its own. Verified behavior-preserving: every changed
> component renders byte-identical after Flux substitution, the per-cluster
> Flux `Kustomization` graph (names + `dependsOn`) is unchanged, and the full
> `just check` gate is green.
>
> **As-built shape:** component Flux Kustomizations live once in `platform/fleet/`;
> each cluster is `flux-system/` + `cluster-vars.yaml` + a `kustomization.yaml`
> selecting which fleet components it runs. Two things stay per-cluster by
> necessity (a Flux Kustomization's `spec.path` cannot be substituted):
> `tenants` (path `tenants/overlays/<cluster>`) and `test-home`'s
> external-secrets-stores (the structural AppRole override).

## The smell

The fleet is now **two clusters** — `prod-fsn` (16 components, incl. the new
`trivy-operator`) and `test-home` (3 components + bootstrap) — so this is no
longer hypothetical. The duplication is already measurable, and three things
are "hand-maintained per cluster" today, all of which scale badly:

1. **~16 near-identical Flux `Kustomization` files per cluster**
   (`clusters/prod-fsn/*.yaml`). Each repeats the same boilerplate (`interval`,
   `retryInterval`, `timeout`, `sourceRef`) and re-encodes the same `dependsOn`
   graph. Adding a cluster means copying these and rewriting paths.
   - **Concrete evidence:** `clusters/prod-fsn/external-secrets.yaml` and
     `clusters/test-home/external-secrets.yaml` are already **byte-for-byte
     identical** — a pure copy. As `test-home` grows toward parity with
     `prod-fsn`, that copy count grows with it.
   - 1 cluster → 16 files. 10 clusters → **~160 files**, all kept in lockstep by
     hand. The reconcile-order graph is identical on every cluster but written
     out 10 times.

2. **Per-cluster values live in overlay directories with JSON6902 patches**
   (`platform/overlays/{prod-fsn,test-home}/{tailscale-operator,external-secrets-stores}`).
   Each per-cluster value needs (a) an overlay dir and (b) a change to the
   cluster `Kustomization`'s `path:` to point at the overlay instead of `base`.
   That's a two-place change, and the `path:` differs per component depending
   on whether an overlay happens to exist — so you can't tell where a component
   reads its config without opening the file.
   - **Concrete evidence:** `external-secrets-stores.yaml` and
     `tailscale-operator.yaml` are identical between the two clusters *except
     for the single `path:` line* (`.../prod-fsn/...` vs `.../test-home/...`).
     The only thing the per-cluster copy carries is which overlay to read.

3. **Platform-namespace exclusions are duplicated across 3–4 hand-edited string
   lists** (the three Cilium `NotIn` lists + `generate-baseline-netpol.yaml`'s
   `names:`). The README already flags this as manual and lockstep-only, and it
   has already caused one outage (the 2026-06-12 `longhorn-system` CSI
   incident). This list is *fleet-wide*, not even per-cluster, yet it's
   maintained by copy-paste in multiple files.

None of these are bugs. They're the kind of duplication that's invisible at
n=1 and becomes the dominant maintenance cost at n=10.

## Design principles for the target

- **Define each fact once.** The reconcile-order graph, a component's config,
  the platform-namespace list — each should have exactly one home. Per-cluster
  variation should be *data* (a short list of values), not *copied structure*.
- **Stay native Flux.** No Argo ApplicationSets, no Helmfile, no Jsonnet/CUE
  layer. Flux already ships the two primitives needed here
  (`postBuild.substituteFrom` and Kustomize composition). Adding a templating
  tool trades one kind of complexity for another and is hard to justify at this
  scale.
- **A new cluster should be a small, obvious diff.** Ideally: one folder
  containing the Flux bootstrap, one ConfigMap of cluster values, and one list
  of which components it runs. Nothing else.
- **Keep `just check` honest.** Any restructure must still be buildable by
  `scripts/validate.sh` (it discovers every `kustomization.yaml` and every
  `clusters/<name>/*.yaml` Flux object). The target below keeps both
  discoverable — see the migration notes.

## Recommendations

### R1 — Define the per-component Flux `Kustomization`s once, in a shared fleet directory

Move the 15 per-component Flux `Kustomization` CRs out of `clusters/prod-fsn/`
and into a single shared, cluster-agnostic location, e.g. `platform/fleet/`:

```
platform/
  fleet/                     # the reconcile graph, defined ONCE for the whole fleet
    kustomization.yaml       #   aggregates all of the below (the "everything" set)
    kyverno.yaml             #   path: ./platform/base/kyverno, dependsOn: [...]
    cert-manager.yaml
    external-secrets.yaml
    ... (one per component, same dependsOn graph as today)
```

Each cluster then references the shared set instead of carrying its own copies.
The cluster folder becomes thin:

```
clusters/prod-fsn/
  flux-system/               # bootstrap, unchanged (do not hand-edit)
  cluster-vars.yaml          # the ONLY meaningfully per-cluster file (see R2)
  kustomization.yaml         # which components this cluster runs (see R4)
```

A standard "runs everything" cluster is then a three-line `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - flux-system
  - cluster-vars.yaml
  - ../../platform/fleet        # the whole fleet set
```

Adding a cluster no longer copies the reconcile graph — it *references* it. The
`dependsOn` ordering, intervals, and timeouts are written once and fixed
everywhere.

### R2 — Replace per-cluster overlay patches with Flux variable substitution

Flux Kustomizations support `postBuild.substituteFrom`, which substitutes
`${var}` tokens in the built manifests from a ConfigMap/Secret. This is the
canonical Flux mechanism for "same manifest, per-cluster value" and it removes
the need for per-cluster overlay directories *and* the `path:`-switching they
force.

Per-cluster values collapse into one ConfigMap per cluster:

```yaml
# clusters/prod-fsn/cluster-vars.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-vars
  namespace: flux-system
data:
  cluster_name: prod-fsn
  region: fsn
  ts_api_hostname: k8s-api-prod-fsn          # was the tailscale-operator overlay patch
  vault_mount: kubernetes/prod-fsn           # was the external-secrets-stores overlay patch
```

Each shared fleet `Kustomization` opts into substitution:

```yaml
# platform/fleet/tailscale-operator.yaml
spec:
  path: ./platform/base/tailscale-operator
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
```

…and the base manifest uses the token directly, so there is no overlay at all:

```yaml
# platform/base/tailscale-operator/release.yaml
operatorConfig:
  hostname: ${ts_api_hostname}
```

**The two live overlays split cleanly along the value-vs-structure line — and
the fleet already contains one of each:**

- **`tailscale-operator` hostname → substitution var.** Both clusters set it to
  `k8s-api-<cluster>` (`k8s-api-prod-fsn`, `k8s-api-test-home`). That's a pure
  value derivable from the cluster name, so the overlay disappears entirely:
  `hostname: k8s-api-${cluster_name}` in the base, one var in `cluster-vars`.
- **`external-secrets-stores` Vault mount → mostly a var, with one real
  exception.** `prod-fsn` swaps the mount path (`kubernetes/prod-fsn`) — a value,
  so a var. But `test-home` does something *structural*: it **removes the
  `kubernetes` auth block and adds an `appRole` block** because its home-LAN
  apiserver can't serve Vault's TokenReview callback. That is not a value swap,
  and substitution should not try to fake it.

So R2 turns the value-only overlays into vars and **legitimately keeps the
`test-home` external-secrets-stores overlay** — it's a different auth *method*,
exactly the carve-out below. Net: `platform/overlays/` shrinks from 4 dirs to 1,
and the one that remains earns its place with a comment explaining why.

> Keep overlays only for the case where a cluster needs *structurally*
> different manifests (a different auth block, extra resources) — not just a
> swapped value. The `test-home` AppRole patch is the canonical example. Value
> differences should be substitution vars; structural differences stay overlays.

### R3 — Guard the platform-namespace exclusion lists against drift

This is the highest-value, lowest-effort fix because it's already burned you
once. The original proposal was to collapse the four lists into one shared
ConfigMap and inject it via Flux `substituteFrom`. **During implementation that
mechanism was rejected** for a concrete reason:

> `kubeconform` *does* have a schema for `CiliumClusterwideNetworkPolicy` (it's
> in the datreeio CRD catalog the validator uses). Flux substitution is textual
> and runs in-cluster, so the committed manifest would read
> `values: ${platform_namespaces}` — a **string** where the schema demands an
> **array**. That fails `just validate` locally and in CI. Substituting a YAML
> *list* is the one case where Flux substitution and schema validation collide.
> (Scalar substitution — R2's hostname and mount path — is fine, because a
> `${var}` string is valid where a string is expected.)

So the shipped R3 is a **drift guard** instead of textual dedup —
`scripts/check-namespace-lists.sh`, wired into `just check` as `just namespaces`.
It parses the four lists (three Cilium `NotIn` `values:` blocks +
`generate-baseline-netpol.yaml`'s `names:`) and **fails the build if they are
not set-identical**, printing exactly which namespace is missing from which
file. This does not remove the four copies, but it makes the hazard the README
warns about — silent divergence causing the 2026-06-12 longhorn-system outage —
**impossible to merge**, with zero change to the working policies (lowest
possible risk). Adding a platform component is still a multi-file edit, but the
guard guarantees you can't get it half-done.

> Kyverno's label-selector path (`platform.io/managed: "true"`) already works
> and needs no change. This R3 only closes the gap Cilium and the netpol
> generator can't express with labels.
>
> **Possible follow-up** (not shipped): true textual dedup of the three Cilium
> lists via Kustomize `replacements` (build-time, so kubeconform sees the real
> array). It can't span the separate `policies/` kustomization, so the guard
> stays regardless — which is why the guard alone was the pragmatic stopping
> point.

### R4 — Make component selection per cluster explicit and data-driven

Today a component is "on" for a cluster if a `clusters/<name>/<comp>.yaml` file
exists, and the scaffolded stubs (`netdata`, `vector`) are "off" by having no
file. With the shared fleet set (R1), make the choice an explicit list in the
cluster's `kustomization.yaml`:

- **Cluster runs everything:** `resources: [flux-system, cluster-vars.yaml, ../../platform/fleet]`
- **Cluster runs a subset:** list the individual fleet files it wants:
  ```yaml
  resources:
    - flux-system
    - cluster-vars.yaml
    - ../../platform/fleet/kyverno.yaml
    - ../../platform/fleet/cert-manager.yaml
    # ...only what this cluster runs
  ```

This keeps "which components on which cluster" as a short, reviewable list in
one file per cluster — the one thing that *legitimately* varies — while the
component *definitions* stay shared.

## Target layout at a glance

```
clusters/
  prod-fsn/                  # runs the full fleet (16 components)
    flux-system/             #   bootstrap (unchanged)
    cluster-vars.yaml        #   per-cluster values (name, region, vault mount, ...)
    kustomization.yaml       #   resources: [flux-system, cluster-vars.yaml, ../../platform/fleet]
  test-home/                 # runs a subset — now ~3 files, not a growing pile of copies
    flux-system/
    cluster-vars.yaml
    kustomization.yaml       #   lists only external-secrets, external-secrets-stores, tailscale-operator
platform/
  fleet/                     # the reconcile graph + dependsOn, defined ONCE
    kustomization.yaml
    *.yaml                   # one Flux Kustomization per component
    platform-namespaces.yaml # the single exclusion list (R3)
  base/                      # component bases — now parameterised with ${vars}
  overlays/                  # only structural diffs (e.g. test-home AppRole auth)
tenants/
  base/ overlays/            # unchanged
```

`test-home` is the ideal first beneficiary: it runs only 3 of the components, so
its `kustomization.yaml` is a short, explicit list (R4), and its one genuinely
structural difference (AppRole auth) is the proof that the overlay carve-out is
correct rather than over-applied.

**Adding cluster #11** becomes: `flux bootstrap` (writes `flux-system/`), copy a
`cluster-vars.yaml` template and fill in ~5 values, write a `kustomization.yaml`
listing components. No reconcile graph copied, no per-component patch files, no
namespace lists touched.

## What to deliberately *not* do

- **Don't reach for Argo CD ApplicationSets, Helmfile, or a CUE/Jsonnet layer.**
  They solve fleet templating, but they add a tool, a DSL, and a new failure
  mode on top of Flux — which already does this natively via substitution. At
  10–20 clusters the native approach is simpler end-to-end.
- **Don't introduce empty pass-through overlays.** The repo already (correctly,
  per commit `c662e09`) collapsed those. Substitution (R2) keeps them gone.
- **Don't template the bootstrap (`flux-system/`).** It's flux-generated; leave
  it per-cluster and untouched.
- **Don't over-parameterise `base`.** Only promote a value to a `${var}` when a
  cluster actually needs it to differ. Premature substitution is just a
  different flavour of complexity.

## Suggested migration order (incremental, each step shippable on its own)

Each step is independently valuable and low-risk — you can stop after any of
them. Do them on a branch and gate with `just check` + a `flux diff` against the
live cluster before merge.

1. **R3 first.** Collapse the four exclusion lists into one ConfigMap +
   `substituteFrom`. Highest safety payoff, smallest blast radius, no layout
   change. Verify with the existing policy tests + `scripts/policy-check.sh`
   (the `longhorn-system` must-not-generate guard).
2. **R2 next.** Convert the two existing overlays to substitution vars in a
   `cluster-vars.yaml`. Delete the overlay dirs. One-cluster change, easy to
   `flux diff`.
3. **R1 + R4 last** (the structural move). Lift the 15 `clusters/prod-fsn/*.yaml`
   into `platform/fleet/`, leave `clusters/prod-fsn/` as the thin
   `kustomization.yaml` + `cluster-vars.yaml`. This is a pure relocation —
   `flux diff` should show *no* change to the applied objects, which is the
   acceptance test.

Then prove it on the cluster you already have: `test-home` is the natural pilot.
It has the fewest components, contains the one structural overlay that exercises
the carve-out, and its `external-secrets.yaml` is already a byte-identical copy
of prod-fsn's — so converting it to the shared-fleet + `cluster-vars` model is a
small, `flux diff`-verifiable change that validates the whole approach before
you touch `prod-fsn`.

## Compatibility notes for `scripts/validate.sh`

The validator discovers (a) every `kustomization.yaml` and (b) every
`clusters/<name>/*.yaml` Flux object (`-maxdepth 2`). After R1 the per-component
Flux objects live under `platform/fleet/*.yaml`, which the current `find` does
**not** scan. Two small adjustments keep coverage:

- Point the cluster-object discovery at `platform/fleet/*.yaml` (or add it
  alongside the existing `clusters/` scan) so the Flux `Kustomization` CRs are
  still schema-checked.
- The `cluster_targets -eq 0` fail-safe still protects against an empty sweep —
  just make sure the new path is one of the counted discoveries.

`postBuild` substitution tokens (`${var}`) are inert to `kustomize build` and
`kubeconform` (they're plain strings until Flux substitutes them in-cluster), so
R2/R3 need no validator change. If you want pre-merge confidence that
substitution resolves, `flux build kustomization <name> --path ... --kustomization-file ...`
or a `flux diff` against the cluster covers it.

## Cost / benefit summary

| Change | Effort | Risk | Payoff at 10 clusters |
|--------|--------|------|------------------------|
| R3 — one exclusion list | Low | Low | Removes the documented outage class; 1 edit instead of 4 |
| R2 — substitution vars | Low–Med | Low | Per-cluster config readable in one file; overlays mostly gone |
| R1 — shared fleet set | Med | Med (pure relocation, `flux diff`-verifiable) | ~160 hand-kept files → ~30 shared + 3/cluster |
| R4 — explicit component list | Low (rides on R1) | Low | "What runs where" is one reviewable list per cluster |

Net: a new cluster goes from "copy and edit ~17 files, hope the reconcile graph
and four namespace lists stay in sync" to "bootstrap + fill in one small
ConfigMap + list the components." The reconcile graph, component config, and
exclusion list each live in exactly one place.
