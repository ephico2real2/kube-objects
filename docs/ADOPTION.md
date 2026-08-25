# Adoption record — fluent-plugin-kubernetes-objects

Upstream `splunk/fluent-plugin-kubernetes-objects` was archived by Splunk on 2025-06-24 (End of Support was
2024-01-01) and its published Docker Hub image was deleted. A cluster that loses its cached copy
cannot pull the image again, so every existing install was one pod reschedule away from
`ImagePullBackOff`. This fork exists to keep the connector deployable, and the rebuild was used to
pay down the accumulated debt properly.

## What changed in this fork

- **Base image migration**: `registry.access.redhat.com/ubi9/ruby-*` -> Red Hat Hardened Images
  (`hi/ruby:3.4`, Ruby 3.4.10). Measured on the shipped image: ~880 scanner findings -> **5**
  (all gem-level, all documented). Three-stage Dockerfile; the runtime stage contains no `RUN`.
- **No dependency drift**: gem versions are byte-identical to the hardened, verified lockfile —
  proven by re-resolving the lock under the new Ruby and diffing.
- **Publishing pipeline**: GitHub Actions workflow builds, scans (trivy, gate on fixable
  CRITICAL/HIGH), pushes to Docker Hub and mirrors registry-to-registry to Quay with digest
  equality verified. Two tags per release: immutable (`-g<sha>`) and rolling.
- **CI functional tests resurrected**: the suite was dead on arrival (unsupported k8s 1.23,
  retired runners, Splunk 10 licensing and non-root changes). Fixes, each diagnosed from its own
  logs: Kubernetes pinned to v1.31.2 (measured — newer kubelets drop the per-container cAdvisor
  metrics the tests assert), minikube pinned with the docker runtime, Splunk General Terms
  acceptance, the Splunk pod runs non-root with a sudoers drop-in for a measured PAM/EACCES
  failure on GitHub runners, and every wait is bounded with a diagnostic dump.
- **Local test harness**: `ci_scripts/local-func-test.sh` replays the CI pipeline on a local kind
  cluster — cluster, Splunk, image build/load, chart deploy, pytest — without the CI round-trip.
- **Tooling**: `ci_scripts/relock.sh` (lockfile maintenance against the real runtime Ruby) and
  `ci_scripts/scan-local.sh` (dated scan history in `trivy-local-scan/`).

## jq and the two image flavors

The chart's rendered fluentd config uses `jq_transformer` filters, and `fluent-plugin-jq` runs the
external `jq` binary through a shell. The default image therefore carries jq 1.8.2 plus a minimal
shell (measured cost over the shell-less build: +3 MB, zero additional scanner findings). The
fully shell-less build — for deployments that use a jq-free config — is preserved:

| pass | tag family | contents | source branch |
|---|---|---|---|
| h2 (default) | `ephico2real/kube-objects:1.2.3-h2` | hardened base + jq + minimal shell | `develop` / `main` |
| h1 (frozen) | `ephico2real/kube-objects:1.2.3-h1` | hardened base, no shell at all | `feat/jq-free` |

A jq-free variant of the Helm chart config (the same enrichment via `record_transformer`, verified
with live indexed data) exists on the chart fork's `feat/jq-free-chart` branch.

## Images

```
docker.io/ephico2real/kube-objects:1.2.3-h2      # rolling — jq-capable (jq 1.8.2 + minimal shell)
docker.io/ephico2real/kube-objects:1.2.3-h2-g<sha>   # immutable — pin this in production
quay.io/ephico2real/kube-objects:1.2.3-h2      # mirror, same digest
```

## Related repositories

The connector is five repos, adopted together: the
[chart](https://github.com/ephico2real2/splunk-connect-for-kubernetes) and the four image sources
([fluentd-hec](https://github.com/ephico2real2/fluentd-hec),
[kube-objects](https://github.com/ephico2real2/kube-objects),
[k8s-metrics](https://github.com/ephico2real2/k8s-metrics),
[k8s-metrics-aggr](https://github.com/ephico2real2/k8s-metrics-aggr)).
