# Publishing this image

This is a **fork** of the archived `splunk/kube-objects`. Upstream is read-only and the image it used to
publish, `splunk/kube-objects:1.2.3`, **has been deleted from Docker Hub** — a cluster that loses its cached
copy cannot pull it again. We build and publish it ourselves.

Images go to the Docker Hub account **`ephico2real`**. This repository lives under the GitHub account
**`ephico2real2`**. The two are one letter apart; using the wrong one produces a reference that looks
right and fails only at pull time, on a cluster.

## One-time setup: four repository secrets

`.github/workflows/publish-image.yaml` authenticates with these. Without the Docker Hub pair the build
and scan still run but the push fails; without the Quay pair the mirror step **skips** rather than
fails, so a fork with no Quay access still publishes to Docker Hub.

Run this **in your own terminal** — not in a chat session, and not anywhere it lands in a log:

```sh
for r in fluentd-hec kube-objects k8s-metrics k8s-metrics-aggr; do
  gh secret set DOCKERHUB_USERNAME --repo "ephico2real2/$r" --body "ephico2real"
  gh secret set DOCKERHUB_TOKEN    --repo "ephico2real2/$r"
  gh secret set QUAY_USERNAME      --repo "ephico2real2/$r" --body 'ephico2real+quay'
  gh secret set QUAY_TOKEN         --repo "ephico2real2/$r"
done
```

| secret | value | where it comes from |
|---|---|---|
| `DOCKERHUB_USERNAME` | `ephico2real` | the Docker Hub account |
| `DOCKERHUB_TOKEN` | access token | Docker Hub -> Account Settings -> Personal access tokens, **Read & Write** |
| `QUAY_USERNAME` | `ephico2real+quay` | the Quay **robot account**, `+`-qualified |
| `QUAY_TOKEN` | robot token | quay.io -> Account Settings -> Robot Accounts |

**Both tokens must be tokens, not passwords.** A token is revocable on its own, is scoped to registry
operations, and does not unlock the web account if a log ever leaks. A password fails all three. The
Quay side is a robot account for the same reason — note the `+` in `ephico2real+quay`; the bare
username will authenticate as nothing and produce a confusing 401.

The `gh secret set` commands without `--body` prompt and read the value without echoing it. Do not pass
a token via `--body` — that puts it in your shell history. GitHub encrypts on receipt, so a secret
cannot be read back, only overwritten.

Verify the names landed without revealing the values:

```sh
gh secret list --repo "ephico2real2/kube-objects"
```

## Where the images go

Both registries receive the same image, and the mirror is registry-to-registry via skopeo rather than a
second build or a second upload — so the two hold the **same digest** by construction. A cluster pulling
from Quay and one pulling from Docker Hub are provably running identical bytes. The workflow verifies
that and fails if the digests differ.

```
docker.io/ephico2real/kube-objects:1.2.3-h1-g<sha>     immutable — pin THIS in a cluster
docker.io/ephico2real/kube-objects:1.2.3-h1            rolling within the hardening pass
quay.io/ephico2real/kube-objects:1.2.3-h1-g<sha>       mirror, same digest
quay.io/ephico2real/kube-objects:1.2.3-h1              mirror, same digest
```

## Publishing

Default is build-and-scan **without** pushing, so a first run is safe:

```sh
gh workflow run publish-image.yaml --repo ephico2real2/kube-objects \
  -f hardening_pass=h1 -f push=false -f fail_on_critical=true
```

Set `push=true` to publish. A release can also be cut by pushing a tag, which always publishes:

```sh
git tag image-v1.2.3-h1 && git push origin image-v1.2.3-h1
```

The workflow **scans before it pushes** and refuses to publish on a fixable CRITICAL or HIGH. That gate is
the reason this fork exists, so prefer fixing the finding over passing `fail_on_critical=false`. It gates
on *fixable* findings only: the UBI base carries thousands with no upstream fix, and a gate that can never
pass is a gate everyone disables.

Login happens **after** the scan, so registry credentials are never present while the image is being
built.

## Tags

Two tags per build, both the same digest:

```
ephico2real/kube-objects:1.2.3-h1-g<sha>   # immutable — pin THIS in a cluster
ephico2real/kube-objects:1.2.3-h1          # rolling within the hardening pass
```

`1.2.3` is the upstream release this forked from (the `VERSION` file). `h1` is the hardening pass — bump
it when re-hardening the same upstream version. `g<sha>` is the fork commit that produced the bytes.
There is deliberately **no `latest`**: a moving tag on an image carrying production telemetry changes
behaviour on a pod reschedule, with nothing in git to explain it.

## Consuming it

In `splunk-connect-for-kubernetes` `values.yaml`, under `splunk-kubernetes-objects`:

```yaml
splunk-kubernetes-objects:
  image:
    registry: docker.io
    name: ephico2real/kube-objects
    tag: 1.2.3-h1-g<sha>
```

Note the metrics subchart declares **two** images — `image` and `imageAgg`. Updating only one leaves the
other on a deleted image.
