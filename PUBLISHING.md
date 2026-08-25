# Publishing this image

This is a **fork** of the archived `splunk/kube-objects`. Upstream is read-only and the image it used to
publish, `splunk/kube-objects:1.2.3`, **has been deleted from Docker Hub** — a cluster that loses its cached
copy cannot pull it again. We build and publish it ourselves.

Images go to the Docker Hub account **`ephico2real`**. This repository lives under the GitHub account
**`ephico2real2`**. The two are one letter apart; using the wrong one produces a reference that looks
right and fails only at pull time, on a cluster.

## One-time setup: two repository secrets

`.github/workflows/publish-image.yaml` authenticates with these. Without them the build and scan still
run, but the push step fails.

Run this **in your own terminal** — not in a chat session, and not in CI logs:

```sh
gh secret set DOCKERHUB_USERNAME --repo "ephico2real2/kube-objects" --body "ephico2real"
gh secret set DOCKERHUB_TOKEN    --repo "ephico2real2/kube-objects"
```

Or all five repos at once:

```sh
for r in fluentd-hec kube-objects k8s-metrics k8s-metrics-aggr; do
  gh secret set DOCKERHUB_USERNAME --repo "ephico2real2/$r" --body "ephico2real"
  gh secret set DOCKERHUB_TOKEN    --repo "ephico2real2/$r"
done
```

`DOCKERHUB_TOKEN` **must be a Docker Hub access token, not the account password.** Create one under
Account Settings -> Personal access tokens with **Read & Write** scope. A token is revocable on its own,
is scoped to registry operations, and does not unlock the Hub web account if a log ever leaks; a password
fails all three.

The second command prompts and reads the value without echoing it. Do not pass the token via `--body` —
that puts it in your shell history. GitHub encrypts it on receipt, so it cannot be read back afterwards,
only overwritten.

Verify the names landed without revealing the values:

```sh
gh secret list --repo "ephico2real2/kube-objects"
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
