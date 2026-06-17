# GitLab CI: rootless container image builds

How to build container images in GitLab CI on this cluster. The short version:
**rootless, no Docker-in-Docker.**

## Why no DinD

CI jobs run as pods in the `gitlab` tenant namespace via the GitLab Runner
Kubernetes executor. That namespace is governed by:

- **Cilium `default-deny`** + the Kyverno-generated baseline CNP (same-namespace
  + DNS), plus an explicit `allow-egress-internet` rule (80/443) so jobs can
  pull dependencies. See [networking.md](networking.md).
- The **Kyverno `pod-security-baseline` / `pod-security-restricted`** policies.
  Baseline forbids privileged containers and host namespaces — so a privileged
  `docker:dind` sidecar is off the table by design (see [policies.md](policies.md)).

To keep that posture, the runner is configured so **every CI job pod (build +
helper container) is `restricted`-compliant**: `runAsNonRoot`, `runAsUser 1000`,
`allowPrivilegeEscalation: false`, all capabilities dropped. The
`seccompProfile: RuntimeDefault` is added automatically by the
`add-seccomp-runtime-default` Kyverno mutate. This config lives in
`tenants/base/gitlab/release.yaml` under `gitlab-runner.runners.config`.

Because job pods run non-root with no privilege escalation, **DinD cannot work**
— and that's intentional. Use a rootless builder instead.

## Building with rootless BuildKit

[`moby/buildkit:rootless`](https://github.com/moby/buildkit) runs fine as uid
1000 with `RuntimeDefault` seccomp. Example `.gitlab-ci.yml` job that builds a
Dockerfile and pushes to the project's GitLab Container Registry:

```yaml
build-image:
  image:
    name: moby/buildkit:rootless
    entrypoint: [""]
  variables:
    # No process sandbox -> no need for unconfined seccomp/apparmor, so the job
    # stays within the restricted PodSecurity profile.
    BUILDKITD_FLAGS: --oci-worker-no-process-sandbox
  script:
    - mkdir -p ~/.docker
    - |
      echo "{\"auths\":{\"$CI_REGISTRY\":{\"username\":\"$CI_REGISTRY_USER\",\"password\":\"$CI_REGISTRY_PASSWORD\"}}}" > ~/.docker/config.json
    - |
      buildctl-daemonless.sh build \
        --frontend dockerfile.v0 \
        --local context=. \
        --local dockerfile=. \
        --output type=image,name=$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA,push=true
```

Kaniko works too, but it generally wants to run as root, which this cluster's
restricted profile disallows — so rootless BuildKit is the recommended path.

## Notes / current limitations

- Jobs run as **uid 1000**: images that assume root (e.g. `apt-get` at job time)
  need adjusting or a non-root base. This is the cost of the hardened posture.
- The Container Registry's external host (`registry.<tailnet>.ts.net`) is a
  MagicDNS name and **not resolvable from inside the cluster** (same constraint
  the runner hit — it registers against the internal webservice Service). Until
  the registry has an in-cluster-resolvable endpoint wired up, pushing from CI to
  `$CI_REGISTRY` needs that addressed; building images works regardless.
