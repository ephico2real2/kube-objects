#!/usr/bin/env bash
#
# Regenerate docker/Gemfile.lock — the file that decides what actually ships.
#
# CANONICAL COPY, installed into all four forks as ci_scripts/relock.sh. Edit it in
# splunk-sck-hardening/ and re-install; do not let the four copies drift.
#
# WHY THIS SCRIPT HAS TO EXIST, and why `bundle lock` on its own does not work here.
# docker/Gemfile declares the plugin itself as a path dependency:
#
#     gem 'fluent-plugin-<name>', path: 'gem/'
#
# That directory does not exist in the repository. It is created *during the image build*, by the
# runtime stage unpacking the .gem the builder stage produced. So running bundler against
# docker/Gemfile in a clean checkout fails with:
#
#     The path `/src/docker/gem` does not exist.
#
# and the lock is left untouched — which reads like success if you are not checking. The three stages
# below reproduce what the Dockerfile does, in the same order, so the resolve can actually complete.
#
# WHY IT RUNS IN A CONTAINER. The lock must be resolved against the SAME Ruby that will run it. The
# runtime base is a UBI Ruby image; a laptop resolving with a different Ruby can pick different gem
# versions, and the mismatch only surfaces at image build time or, worse, at runtime. The base is read
# out of docker/Dockerfile rather than hardcoded, so this cannot drift when the Dockerfile is bumped.
#
# USAGE
#   ci_scripts/relock.sh                 re-resolve, honouring existing constraints
#   ci_scripts/relock.sh kubeclient      update ONE gem and its transitives
#   ci_scripts/relock.sh rack oj         update these, one at a time, in order
#
# PREFER ONE GEM AT A TIME. A blanket update moves forty gems at once and makes a later test failure
# impossible to attribute. Updating one gem, re-locking, testing and scanning means a failure names its
# own cause.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
REPO_NAME="$(basename "$REPO_ROOT")"

# The runtime base, read from the Dockerfile's LAST FROM — the stage that actually ships. Taking the
# first FROM would give the builder image and resolve against the wrong Ruby.
#
# BASE_IMAGE overrides it, and that override is not a convenience — it is required during a base
# migration. To move from ruby-31 to ruby-33 you must resolve the lock against 3.3 BEFORE the
# Dockerfile says 3.3, or you lock against the Ruby you are leaving. Chicken-and-egg; the override is
# the egg:
#     BASE_IMAGE=registry.access.redhat.com/ubi9/ruby-33:latest ci_scripts/relock.sh kubeclient
BASE="${BASE_IMAGE:-$(grep -E '^\s*FROM ' docker/Dockerfile | tail -1 | awk '{print $2}')}"
if [ -z "${BASE}" ]; then
  echo "ERROR: could not read a FROM line from docker/Dockerfile, and BASE_IMAGE is unset" >&2
  exit 1
fi

RUNTIME="${CONTAINER_RUNTIME:-docker}"
command -v "${RUNTIME}" >/dev/null 2>&1 || {
  echo "ERROR: ${RUNTIME} not found. Set CONTAINER_RUNTIME=podman to use podman." >&2
  exit 1
}

echo "==> repo:    ${REPO_NAME}"
if [ -n "${BASE_IMAGE:-}" ]; then
  echo "==> base:    ${BASE}   (from BASE_IMAGE override)"
else
  echo "==> base:    ${BASE}   (from the last FROM in docker/Dockerfile)"
fi
if [ "$#" -gt 0 ]; then
  echo "==> updating: $*"
else
  echo "==> re-resolving without changing any constraint"
fi

# --platform is explicit because these images ship linux/amd64. On an ARM host the resolve would
# otherwise happen under emulation for a different architecture, and native-extension gems can differ.
# GEM_HOME AND BUNDLE_PATH ARE POINTED AT WRITABLE SCRATCH, and this is not optional. The UBI Ruby
# images run as a non-root uid whose GEM_HOME is /usr/share/gems — owned by root, not writable. The
# lockfile records `BUNDLED WITH <version>`, bundler tries to install exactly that version into
# GEM_HOME to honour it, and the write fails:
#
#     Bundler::PermissionError: There was an error while trying to write to
#     `/usr/share/gems/cache/bundler-2.3.11.gem`
#
# It then emits a hundred-line error report and leaves the lock UNTOUCHED — which is easy to read as
# "nothing to do" rather than "this failed". Redirecting both to /tmp sidesteps it without running as
# root, so nothing in the bind mount ends up root-owned.
"${RUNTIME}" run --rm --platform linux/amd64 \
  -v "${REPO_ROOT}":/src -w /src \
  -e GEMS="$*" \
  -e GEM_HOME=/tmp/relock-gems \
  -e BUNDLE_PATH=/tmp/relock-bundle \
  -e BUNDLE_APP_CONFIG=/tmp/relock-bundle/.bundle \
  "${BASE}" bash -lc '
    set -euo pipefail
    export PATH="${GEM_HOME}/bin:${PATH}"

    # The repo is bind-mounted and owned by a different uid inside the container; without this, git
    # refuses to read it and any gemspec that shells out to `git ls-files` returns an empty file list,
    # producing a silently EMPTY gem.
    git config --global --add safe.directory /src 2>/dev/null || true

    # BUNDLER MUST SATISFY THE GEMSPEC, so pin the major series rather than taking the newest.
    # Every gemspec here declares `add_development_dependency bundler, ~> 2.0`. A bare
    # `gem install bundler` now installs 4.x, and once it is first on PATH the resolve fails on
    # something that has nothing to do with the gem being updated:
    #
    #     Because the current Bundler version (4.0.19) does not satisfy bundler ~> 2.0
    #       and Gemfile depends on bundler ~> 2.0, version solving has failed.
    #
    # Read literally that error blames the Gemfile, which sends you looking in the wrong place.
    # Installing the newest 2.x keeps the tool consistent with what the gemspecs were written against.
    gem install bundler -v "~> 2.0" --no-document >/dev/null 2>&1
    echo "    bundler $(bundle --version | awk "{print \$3}")"

    echo "--> stage 1/3: build the plugin gem (what the Dockerfile builder stage does)"
    # THERE ARE TWO LOCKFILES AND BOTH MOVE. The repo root has its own Gemfile/Gemfile.lock used to
    # build the gem; docker/ has a second pair used to assemble the image. A gem constrained in the
    # gemspec appears in both, so updating only docker/Gemfile.lock leaves the root lock contradicting
    # the gemspec and this stage dies before it ever reaches the docker/ resolve:
    #
    #     Bundler could not find compatible versions for gem "kubeclient":
    #       In snapshot (Gemfile.lock): kubeclient (= 4.9.3)
    #       In Gemfile: ... was resolved to 1.2.3, which depends on kubeclient (~> 4.13)
    #
    # Updating the root lock first keeps the pair consistent. Guarded on the file existing, because
    # not every repo here checks a root Gemfile.lock in.
    # NOT EVERY GEM IS IN BOTH FILES. docker/Gemfile declares gems the root Gemfile never mentions —
    # `oj` is one — and `bundle lock --update=oj` at the root then dies with "Could not find gem oj",
    # taking the whole script down under `set -e` before the docker/ resolve is even attempted. Only
    # update at the root what the root actually knows about; the docker/ stage handles the rest.
    if [ -n "${GEMS}" ] && [ -f Gemfile.lock ]; then
      for g in ${GEMS}; do
        if grep -qE "^\s{4}${g} \(" Gemfile.lock; then
          bundle lock --update="${g}"
        else
          echo "    (${g} not in the root Gemfile — updating it in docker/ only)"
        fi
      done
    fi
    bundle install --quiet
    bundle exec rake build 2>&1 | grep -E "built to|rake aborted" || true
    ls -1 pkg/*.gem >/dev/null 2>&1 || { echo "ERROR: rake build produced no .gem in pkg/" >&2; exit 1; }

    echo "--> stage 2/3: unpack it into docker/gem (what the runtime stage does)"
    cd docker
    rm -rf gem
    gem unpack ../pkg/*.gem --target gem >/dev/null
    ls -d gem/*/ >/dev/null 2>&1 || { echo "ERROR: unpack produced no directory in docker/gem" >&2; exit 1; }

    echo "--> stage 3/3: resolve the lock"
    if [ -n "${GEMS}" ]; then
      # One at a time, deliberately: each pass re-resolves and its effect stays attributable.
      for g in ${GEMS}; do
        echo "    bundle lock --update=${g}"
        bundle lock --update="${g}"
      done
    else
      bundle lock
    fi
  '

echo
echo "==> docker/Gemfile.lock regenerated. Review the diff before committing:"
echo "      git diff -- docker/Gemfile.lock"
echo
echo "    docker/gem/ and pkg/ are build artifacts and are gitignored; they are left in place so a"
echo "    following image build can reuse them. Remove them with: rm -rf docker/gem pkg"
