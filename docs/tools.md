# Tooling reference

The CLI tools this repo's pipeline depends on, plus the ones used to build and
verify the GitOps tree. Everything in the **Pipeline** section is installed and
run automatically in CI (`.github/workflows/`) and reproducibly via the
[`justfile`](../justfile) — you only need them locally if you want to run the
checks yourself before pushing.

## Pipeline tools (run by `just` / CI)

| Tool | Role in this repo | Where | Docs |
|------|-------------------|-------|------|
| **just** | Task runner. `just check` runs the whole PR gate; individual recipes (`validate`, `policy`, `secrets`, `lint`, `scan`) wrap the scripts. Think "Makefile without the tab pain." | `justfile`, every CI job | <https://just.systems/man/en/> |
| **kustomize** | Builds each `kustomization.yaml` into final YAML the way Flux does (`--load-restrictor LoadRestrictionsNone`, because bases reference sibling `../` files). | `scripts/validate.sh`, `policy-check.sh`, `image-scan.sh` | <https://kubectl.docs.kubernetes.io/references/kustomize/> |
| **kubeconform** | Schema-validates the built manifests against upstream Kubernetes schemas + Flux CRD schemas + the community CRD catalog. Catches malformed/typo'd resources before they reach the cluster. | `scripts/validate.sh` | <https://github.com/yannh/kubeconform> |
| **kyverno (CLI)** | Two jobs: `kyverno apply` evaluates the `ClusterPolicies` against rendered manifests (like admission would); `kyverno test` runs the unit-test fixtures in `tests/policy/` that assert each policy fires/exempts correctly. | `scripts/policy-check.sh`, `tests/policy/` | <https://kyverno.io/docs/kyverno-cli/> |
| **gitleaks** | Scans the working tree for committed secrets (API keys, tokens). PR gate. | `just secrets` | <https://github.com/gitleaks/gitleaks> |
| **trivy** | Scans every container image referenced by the charts/manifests for HIGH/CRITICAL CVEs. Weekly schedule, **not** a PR gate (CVEs are disclosed independently of commits). | `scripts/image-scan.sh` | <https://trivy.dev/> |
| **actionlint** | Lints the GitHub Actions workflow files — shellcheck on `run:` blocks, expression syntax, `uses:` references. Added so the workflows are checked like everything else. | `just lint`, PR `lint` job | <https://github.com/rhysd/actionlint> |
| **helm** | Templates each `HelmRelease` (chart + version + inline values) so the image scanner can see the images that live *inside* the charts, not just the ones pinned in the repo. Preinstalled on GitHub runners. | `scripts/image-scan.sh` | <https://helm.sh/docs/> |
| **yq** | YAML query/extract in shell — pulls chart/version/repo fields out of `HelmRelease`/`HelmRepository` objects. Preinstalled on GitHub runners. | `scripts/image-scan.sh` | <https://mikefarah.gitbook.io/yq/> |
| **python3 + PyYAML** | Builds the namespace→labels map kyverno needs to resolve `namespaceSelector` excludes in the CLI, and tallies CVE counts from Trivy JSON. | `scripts/policy-check.sh`, `image-scan.sh` | <https://pyyaml.org/wiki/PyYAMLDocumentation> |

### Version pinning

CI tool versions are pinned as env vars in the workflow files, each carrying a
`# renovate:` annotation so [Renovate](https://docs.renovatebot.com/) opens a PR
when a new release lands (see the `customManagers` block in `renovate.json`).
The pins are passed into the shared composite action
`.github/actions/setup-tools` as inputs — keep the pins in the workflow `env:`
blocks, not in the action, or Renovate stops tracking them.

## Tools used to build & verify this repo (beyond the pipeline)

| Tool | Why | Docs |
|------|-----|------|
| **git** | Version control. | <https://git-scm.com/doc> |
| **kubectl** | `kubectl kustomize` is the fallback builder in the scripts when the standalone `kustomize` binary isn't on PATH (both honour `--load-restrictor`). | <https://kubernetes.io/docs/reference/kubectl/> |
| **curl / tar** | How the composite action fetches and unpacks each pinned tool release in CI. | — |
| Standard Unix (`grep`, `sed`, `find`, `awk`) | Discovery and text wrangling inside the scripts. | — |

## Cluster-side (not CLI tools, but the things the pipeline validates *for*)

These run *in* the cluster and are configured by this repo — listed for context;
they're not installed locally.

- **Flux** — the GitOps reconciler that applies everything under `clusters/`. <https://fluxcd.io/flux/>
- **Kyverno** — the in-cluster admission controller the `tests/policy/` fixtures mirror. <https://kyverno.io/>
- **Cilium** — the CNI enforcing the `CiliumClusterwideNetworkPolicy` default-deny. <https://docs.cilium.io/>
- **Renovate** — runs as a workflow (`.github/workflows/renovate.yaml`) to keep chart and tool versions current. <https://docs.renovatebot.com/>
