#!/usr/bin/env bash
#
# Build the image locally. CI does the same thing in .github/workflows/publish-image.yaml; this is for
# building on a laptop without pushing.
#
#   docker/build.sh                 -> ephico2real/kube-objects:<VERSION>-h1-g<sha>
#   docker/build.sh 1.2.3-test      -> ephico2real/kube-objects:1.2.3-test
#
# WHAT CHANGED, AND WHY THE OLD STEPS ARE GONE. This script used to run `bundle install` and
# `rake build` on the HOST, copy the resulting .gem and LICENSE into docker/, and then build with
# docker/ as the context. Every one of those steps is now done by the Dockerfile's builder stage —
# `ADD ./ /app/`, `rake build`, then `COPY --from=builder` for the .gem and the LICENSE. Doing it twice
# is not merely redundant: the host build resolved gems against whatever Ruby the laptop happens to
# have, which is 2.6.10 here, while the gemspecs now target >= 3.2. It would fail before it ever
# reached docker.
#
# The context is therefore the REPO ROOT with -f ./docker/Dockerfile, not ./docker. The builder stage
# needs the gemspec, Rakefile, lib/ and VERSION, and none of those live under docker/.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
SHA="$(git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
TAG="${1:-${VERSION}-h3-g${SHA}}"  # default pass tracks the current hardening pass of this repo
IMAGE="ephico2real/kube-objects"

# --build-arg VERSION is stamped into the version/release LABELs and ENV VERSION, so a running
# container reports the same identity as its tag. Without it the labels read "null".
# --platform is explicit because these images ship linux/amd64.
echo "==> building ${IMAGE}:${TAG}"
docker build \
  --platform linux/amd64 \
  --pull \
  --build-arg "VERSION=${TAG}" \
  -f ./docker/Dockerfile \
  -t "${IMAGE}:${TAG}" \
  .

echo
echo "==> built ${IMAGE}:${TAG}"
echo "    scan before pushing:  trivy image --ignore-unfixed --severity CRITICAL,HIGH ${IMAGE}:${TAG}"
echo "    push:                 docker push ${IMAGE}:${TAG}"
