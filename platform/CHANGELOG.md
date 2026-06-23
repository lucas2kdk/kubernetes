# Changelog

## [1.10.0](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.9.0...platform/v1.10.0) (2026-06-23)


### Features

* **homepage:** theme + bookmarks; fix(excalidraw): pod selector for status ([2114a33](https://github.com/lucas2kdk/kubernetes/commit/2114a33f33a5a6d1f7907e65eecae832c2401566))

## [1.9.0](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.8.0...platform/v1.9.0) (2026-06-20)


### Features

* **homepage:** add auto-discovery dashboard + light metrics ([#110](https://github.com/lucas2kdk/kubernetes/issues/110)) ([d00d455](https://github.com/lucas2kdk/kubernetes/commit/d00d455d5c2294ccad1db47d1599d8a54701b443))
* **monitoring:** GitLab datastore metrics + Pod Security enforcement ([#111](https://github.com/lucas2kdk/kubernetes/issues/111)) ([1e13029](https://github.com/lucas2kdk/kubernetes/commit/1e130299f493bb67ed3275563ec847daa278ea96))

## [1.8.0](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.7.0...platform/v1.8.0) (2026-06-18)


### Features

* **policy:** enforce baseline + restricted PodSecurity ([#107](https://github.com/lucas2kdk/kubernetes/issues/107)) ([886dd9d](https://github.com/lucas2kdk/kubernetes/commit/886dd9daaa44827a83e7c52186c05128c03ae4ab))

## [1.7.0](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.6.0...platform/v1.7.0) (2026-06-17)


### Features

* **platform:** add MinIO operator ([#91](https://github.com/lucas2kdk/kubernetes/issues/91)) ([36982b2](https://github.com/lucas2kdk/kubernetes/commit/36982b26903aeb5a222c2aa579c2739d5152ac37))

## [1.6.0](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.5.2...platform/v1.6.0) (2026-06-17)


### Features

* **platform:** add CloudNativePG and Redis operators ([#88](https://github.com/lucas2kdk/kubernetes/issues/88)) ([392b23b](https://github.com/lucas2kdk/kubernetes/commit/392b23b994e48a0e914e7faea2e67f38e47f53af))

## [1.5.2](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.5.1...platform/v1.5.2) (2026-06-17)


### Miscellaneous Chores

* release platform 1.5.2 ([#82](https://github.com/lucas2kdk/kubernetes/issues/82)) ([c8b05fe](https://github.com/lucas2kdk/kubernetes/commit/c8b05fe386e96dbdbc90b27630f9ea0190208e70))

## [1.5.1](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.5.0...platform/v1.5.1) (2026-06-15)


### Bug Fixes

* **gateway:** give the HTTP listener a hostname so the redirect renders ([#78](https://github.com/lucas2kdk/kubernetes/issues/78)) ([7233782](https://github.com/lucas2kdk/kubernetes/commit/7233782ffffb28d50ee78527fdcc6e89acb28943))

## [1.5.0](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.4.0...platform/v1.5.0) (2026-06-15)


### Features

* **flux:** Discord alert on drift of Flux-managed resources ([#72](https://github.com/lucas2kdk/kubernetes/issues/72)) ([9adec29](https://github.com/lucas2kdk/kubernetes/commit/9adec29fe757d2fcc645fdb630704c5b7533be0e))
* **gateway:** TLS on the Cilium Gateway for draw.rosenvold.tech ([#74](https://github.com/lucas2kdk/kubernetes/issues/74)) ([00e389e](https://github.com/lucas2kdk/kubernetes/commit/00e389efe5178885d199da23ba18ac67553708b2))
* **monitoring:** add OOMKilled and Longhorn volume-full alerts ([#73](https://github.com/lucas2kdk/kubernetes/issues/73)) ([0067003](https://github.com/lucas2kdk/kubernetes/commit/0067003bc23c604a9e067ad3b0de307450301771))


### Bug Fixes

* **network:** allow the Cilium Gateway proxy through default-deny ([#71](https://github.com/lucas2kdk/kubernetes/issues/71)) ([39ac386](https://github.com/lucas2kdk/kubernetes/commit/39ac38667e40d681f85650e1672b242b75386918))

## [1.4.0](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.3.0...platform/v1.4.0) (2026-06-15)


### Features

* **gateway:** add Cilium Gateway API trial alongside Traefik ([#69](https://github.com/lucas2kdk/kubernetes/issues/69)) ([ebfc3b7](https://github.com/lucas2kdk/kubernetes/commit/ebfc3b73b85a03aea7e8c4f3829c74bb41a77d4e))
* **monitoring:** Alertmanager Discord routing + platform alert rules ([#16](https://github.com/lucas2kdk/kubernetes/issues/16)) ([7076395](https://github.com/lucas2kdk/kubernetes/commit/7076395443074c729f5976b33876625762876dbb))
* **platform:** add platform-critical and tenant-default PriorityClasses ([#62](https://github.com/lucas2kdk/kubernetes/issues/62)) ([777f4aa](https://github.com/lucas2kdk/kubernetes/commit/777f4aa3f10ec9f0dd4eb825128ecd6b5f31aade)), closes [#47](https://github.com/lucas2kdk/kubernetes/issues/47)
* **policies:** add seccomp RuntimeDefault mutate (CIS 5.7.2) ([#68](https://github.com/lucas2kdk/kubernetes/issues/68)) ([6d1b59a](https://github.com/lucas2kdk/kubernetes/commit/6d1b59afead594b5984480705f1aedced2e215ad))
* **policies:** restrict ClusterIssuer to platform namespaces ([#61](https://github.com/lucas2kdk/kubernetes/issues/61)) ([8df3634](https://github.com/lucas2kdk/kubernetes/commit/8df36341eafe51d491f2e439b76a8c0da7972b65)), closes [#53](https://github.com/lucas2kdk/kubernetes/issues/53)

## [1.3.0](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.2.0...platform/v1.3.0) (2026-06-14)


### Features

* **monitoring:** add dashboard pack (node, prometheus, cilium, traefik, ESO, trivy) ([#41](https://github.com/lucas2kdk/kubernetes/issues/41)) ([0febd21](https://github.com/lucas2kdk/kubernetes/commit/0febd2162f0c11b214e872fa7c43c6b9f47e11fd))

## [1.2.0](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.1.1...platform/v1.2.0) (2026-06-14)


### Features

* **monitoring:** make Grafana dashboards multi-cluster aware ([#38](https://github.com/lucas2kdk/kubernetes/issues/38)) ([fa35c20](https://github.com/lucas2kdk/kubernetes/commit/fa35c20dd49d0a67b90934cc5e169245ff031b00))

## [1.1.1](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.1.0...platform/v1.1.1) (2026-06-14)


### Bug Fixes

* **kyverno:** force-recreate ClusterPolicies so generate-rule changes stop needing manual deletes ([#34](https://github.com/lucas2kdk/kubernetes/issues/34)) ([6180105](https://github.com/lucas2kdk/kubernetes/commit/618010510a387b6c22ebd2646d7f0b9bd89c39ea))
* **tailscale:** allow privileged egress proxies in the tailscale namespace ([#36](https://github.com/lucas2kdk/kubernetes/issues/36)) ([c3e4bc1](https://github.com/lucas2kdk/kubernetes/commit/c3e4bc17961bbe3f43d2f55fa7a3b36c4d0ae4a2))

## [1.1.0](https://github.com/lucas2kdk/kubernetes/compare/platform/v1.0.0...platform/v1.1.0) (2026-06-14)


### Features

* **test-home:** expand to near-full fleet with cross-cluster observability ([#30](https://github.com/lucas2kdk/kubernetes/issues/30)) ([f4521f1](https://github.com/lucas2kdk/kubernetes/commit/f4521f131a3634b95852362f1130faadc188be50))

## 1.0.0 (2026-06-14)


### Features

* **headlamp:** add flux and cert-manager plugins via pluginsManager ([7e30867](https://github.com/lucas2kdk/kubernetes/commit/7e30867f0a3759593a77195a207dac0c645130be))
* **headlamp:** add kubebeam trivy-operator plugin ([a9e6eb3](https://github.com/lucas2kdk/kubernetes/commit/a9e6eb340d8fa242c65403d25e2a7c299e939106))
* **headlamp:** auto-discover remote cluster kubeconfigs from Vault ([892a0d3](https://github.com/lucas2kdk/kubernetes/commit/892a0d38a9cfe4efa20f46ef985e75fe092180b6))
* **monitoring:** enable in-cluster Grafana + dashboards + scrape targets ([f6a8954](https://github.com/lucas2kdk/kubernetes/commit/f6a89545e278cd38dab39e0123be6de2449cefcd))
* **platform:** add capacitor to fleet on both clusters ([#19](https://github.com/lucas2kdk/kubernetes/issues/19)) ([734a19e](https://github.com/lucas2kdk/kubernetes/commit/734a19ed52cf5f828364f5ca47aa1416a6163550))
* **platform:** add versioned OCI release pipeline ([#23](https://github.com/lucas2kdk/kubernetes/issues/23)) ([a71214e](https://github.com/lucas2kdk/kubernetes/commit/a71214edaca14474b9510adbab9be869d813549a))
* **policies:** add PSS restricted policy and monitoring scrape allow ([4b5b38c](https://github.com/lucas2kdk/kubernetes/commit/4b5b38c8eafd768ec578ba489993518ca3c58988))
* **policies:** add PSS restricted policy and monitoring scrape allow ([59275ef](https://github.com/lucas2kdk/kubernetes/commit/59275eff52666d1cbe7fc25ab1580d40280f0f74))
* **test-home:** onboard new cluster to Flux ([6d15353](https://github.com/lucas2kdk/kubernetes/commit/6d15353950db96dcaadac6714d02d334b13ae602))
* **trivy-operator:** add CIS Kubernetes Benchmark + workload scanning ([1cd5226](https://github.com/lucas2kdk/kubernetes/commit/1cd5226d3e89e25fe646f0e82782540e63cf9abf))


### Bug Fixes

* **bootstrap:** break PodMonitor/ServiceMonitor CRD chicken-and-egg ([55a8822](https://github.com/lucas2kdk/kubernetes/commit/55a88221c138050cc5ff9429d5c0d210c19b03f5))
* **capacitor:** rename inner Kustomization to avoid collision ([#21](https://github.com/lucas2kdk/kubernetes/issues/21)) ([6f113fd](https://github.com/lucas2kdk/kubernetes/commit/6f113fd117982244b1e2539a5445a89cc8a6cd7c))
* **capacitor:** use source v1 for OCIRepository ([#20](https://github.com/lucas2kdk/kubernetes/issues/20)) ([f0e9160](https://github.com/lucas2kdk/kubernetes/commit/f0e916033b86ab13f8f9ba7d9b713aa8053e0958))
* **grafana:** drop unsupported `groups` OAuth scope from tsidp login ([396ad28](https://github.com/lucas2kdk/kubernetes/commit/396ad28cd21cb3a62295b788d8de8748af821ca8))
* **headlamp:** enable watchPlugins so sidecar-installed plugins load ([6607392](https://github.com/lucas2kdk/kubernetes/commit/66073926a3d48e4b72a29c76ec7a5b9eb7449e80))
* **headlamp:** grant OIDC viewers read on CRDs for Flux/cert-manager plugins ([9e24543](https://github.com/lucas2kdk/kubernetes/commit/9e24543f6d70a5d302e287fea0b7d994a2206036))
* **headlamp:** rewrite regexp matches actual Vault path keys ([66ffdc5](https://github.com/lucas2kdk/kubernetes/commit/66ffdc520c635b4fab5af3022a4f453f1d96cd4a))
* **kyverno:** force failurePolicy Ignore — fail-closed webhooks deadlock single-node drains ([b6ad4c7](https://github.com/lucas2kdk/kubernetes/commit/b6ad4c7c1ee416381d03f3bb7c270a4c1ee9b3a4))
* **kyverno:** pin helm-test readiness-checker image off :latest ([d52d9c9](https://github.com/lucas2kdk/kubernetes/commit/d52d9c95d602a7be0ad3d49b5a60017a2bf1e1a6))
* **kyverno:** raise controller memory limits — 128Mi default thrashes page cache ([6b9d79f](https://github.com/lucas2kdk/kubernetes/commit/6b9d79f5434a21dc50584a4ca158262a394964b9))
* **network:** exclude longhorn-system from allow-ingress-from-traefik ([2b10cb5](https://github.com/lucas2kdk/kubernetes/commit/2b10cb5fb354ef1c93a5e57bc069c39dc5ebd7b8))
* **network:** exclude longhorn-system from deny-cloud-metadata CCNP ([966c725](https://github.com/lucas2kdk/kubernetes/commit/966c725bb30cb16e1476fb7b1adeab6871461672))
* **pdb:** use maxUnavailable instead of minAvailable; add ESO webhook PDB ([5fb7c2a](https://github.com/lucas2kdk/kubernetes/commit/5fb7c2a2cd2b05e4cf8b4c4d3cd7e7960a3acd71))
* **platform-meta:** pin version-exporter image and enforce SEC3 scope ([#28](https://github.com/lucas2kdk/kubernetes/issues/28)) ([50dc847](https://github.com/lucas2kdk/kubernetes/commit/50dc84711e00e7f2173a81f8d9c40a66cf603965))
* **platform:** pin floating chart versions to the deployed versions ([00c8fc8](https://github.com/lucas2kdk/kubernetes/commit/00c8fc86544bef236bc5b88cde5608be29aefb38))
* **policies:** exclude longhorn-system from baseline netpol generation ([e4d16d6](https://github.com/lucas2kdk/kubernetes/commit/e4d16d655814b852ddf085c9d4b2f9b4f8c33fda))
* **test-home:** switch ESO Vault auth from kubernetes to AppRole ([8e398db](https://github.com/lucas2kdk/kubernetes/commit/8e398db38673e568a743115a42e3b4b15950fbd5))
* **trivy-operator:** aggregate missing report kinds into view ([dbe76b6](https://github.com/lucas2kdk/kubernetes/commit/dbe76b6ff32ef3101c459d139390931fff5aedac))
* **tsidp:** add memory limit, bump request, document no-probe decision ([021bc46](https://github.com/lucas2kdk/kubernetes/commit/021bc4616b3efe5b93aedbc07800e28276e301a1))
* **tsidp:** pin image to a semver tag instead of :latest ([33ce0d1](https://github.com/lucas2kdk/kubernetes/commit/33ce0d18506979b91a493c2c5e7ceafa1dc70606))
