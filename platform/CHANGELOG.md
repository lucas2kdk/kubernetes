# Changelog

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
