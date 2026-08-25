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
# image base is a Red Hat Ruby image; a laptop resolving with a different Ruby can pick different gem
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

# WHICH STAGE TO RESOLVE IN. The Ruby that ships is the runtime stage — the LAST `FROM` in
# docker/Dockerfile — but that is the WRONG stage to run bundler in. On Red Hat Hardened Images the
# runtime has NO SHELL: /bin/sh, /bin/bash and /usr/bin/sh are all absent, deliberately (verified as
# root too). Running bundler there fails with a message that names none of this:
#
#     docker: Error response from daemon: ... exec: "bash": executable file not found in $PATH
#
# and because it is the container that fails rather than this script, the output simply stops after
# the banner lines with no error of the script's own. So take the last `-builder` stage instead: it
# carries the SAME Ruby as the runtime, plus a shell, dnf and a compiler — exactly what resolving a
# lock needs. If the Dockerfile has no `-builder` stage (a non-hardened base, where the runtime does
# have a shell), fall back to the last `FROM` as before.
#
# BASE_IMAGE overrides both, and that override is not a convenience — it is required during a base
# migration. To move from ruby-31 to ruby-33 you must resolve the lock against 3.3 BEFORE the
# Dockerfile says 3.3, or you lock against the Ruby you are leaving. Chicken-and-egg; the override is
# the egg:
#     BASE_IMAGE=registry.access.redhat.com/ubi9/ruby-33:latest ci_scripts/relock.sh kubeclient
BUILDER_FROM="$(grep -E '^\s*FROM ' docker/Dockerfile | grep -- '-builder' | tail -1 | awk '{print $2}')"
BASE="${BASE_IMAGE:-${BUILDER_FROM:-$(grep -E '^\s*FROM ' docker/Dockerfile | tail -1 | awk '{print $2}')}}"
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
elif [ -n "${BUILDER_FROM}" ]; then
  echo "==> base:    ${BASE}   (last -builder stage in docker/Dockerfile)"
else
  echo "==> base:    ${BASE}   (last FROM in docker/Dockerfile — no -builder stage found)"
fi
if [ "$#" -gt 0 ]; then
  echo "==> updating: $*"
else
  echo "==> re-resolving without changing any constraint"
fi

# THE CONTAINER SCRIPT IS BUILT FROM A QUOTED HEREDOC, NOT A SINGLE-QUOTED STRING. A single-quoted
# `bash -lc '...'` block cannot contain an apostrophe ANYWHERE — including inside a comment — without
# the apostrophe closing the quote and splicing the rest of the file into the outer script; that exact
# mistake has broken this script twice. With the delimiter quoted (<<'...'), the outer shell expands
# NOTHING in the body, so any character is safe here, and every ${VAR} below is expanded by bash
# INSIDE the container, which is where GEM_HOME, GEMS and the loop variables actually exist.
CONTAINER_SCRIPT="$(cat <<'RELOCK_CONTAINER_SCRIPT'
set -euo pipefail
export PATH="${GEM_HOME}/bin:${PATH}"

# BUILD DEPENDENCIES, matching what the Dockerfile's builder stage installs. Resolving a lock
# compiles native extensions, so the headers have to be here too — without them bundler dies on:
#
#     An error occurred while installing openssl (4.0.2), and Bundler cannot continue.
#
# git-core is needed because two of these repos source kubeclient from a git: URL, and bundler
# refuses outright without git: "You need to install git to be able to use gems from git
# repositories." Hardened builder images ship neither by default.
#
# `|| true` is deliberate here and ONLY here: on a base that already has them this is a no-op, and
# a missing repo should not stop a resolve that may not need the headers at all. The failure it
# would otherwise mask is reported by bundler a moment later, in terms that name the actual gem.
if command -v dnf >/dev/null 2>&1; then
  dnf install -y git-core openssl-devel libffi-devel >/dev/null 2>&1 || true
fi

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
# On failure the log is shown rather than swallowed — a silent death here is unattributable.
gem install bundler -v "~> 2.0" --no-document >/tmp/relock-bundler-install.log 2>&1 \
  || { echo "ERROR: gem install bundler failed:" >&2; cat /tmp/relock-bundler-install.log >&2; exit 1; }
echo "    $(bundle --version)"

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
    # TRY, DO NOT PREDICT. Deciding in advance whether the root knows a gem needs a rule that
    # holds for every case, and two attempts at one were wrong: matching the lock at a 4-space
    # indent missed GIT stanzas (indented 6), and matching any indent then matched a gem the root
    # Gemfile does not declare, so the update failed and `set -e` killed the run before the
    # docker/ resolve — the part that actually matters. Attempt it and carry on; the authoritative
    # answer is whether bundler can resolve it, not whether a grep found a line.
    if bundle lock --update="${g}" >/dev/null 2>&1; then
      echo "    root lock: ${g} updated"
    else
      echo "    root lock: ${g} not declared there — updating it in docker/ only"
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
RELOCK_CONTAINER_SCRIPT
)"

# --platform is explicit because these images ship linux/amd64. On an ARM host the resolve would
# otherwise happen under emulation for a different architecture, and native-extension gems can differ.
#
# --user 0 IS REQUIRED BY dnf. The hardened builder image defaults to uid 65532, and installing the
# build dependencies above needs root. (On a Linux host this means the files written into the bind
# mount — the lockfiles, docker/gem, pkg/ — come back root-owned; chown them after. Docker Desktop
# on macOS maps ownership back to the host user, so nothing is needed there.)
#
# GEM_HOME AND BUNDLE_PATH ARE POINTED AT WRITABLE SCRATCH. On the stock UBI Ruby images the
# container uid cannot write its own GEM_HOME (/usr/share/gems, root-owned): the lockfile records
# `BUNDLED WITH <version>`, bundler tries to install exactly that version into GEM_HOME to honour
# it, and the write fails:
#
#     Bundler::PermissionError: There was an error while trying to write to
#     `/usr/share/gems/cache/bundler-2.3.11.gem`
#
# It then emits a hundred-line error report and leaves the lock UNTOUCHED — which is easy to read as
# "nothing to do" rather than "this failed". Running as root sidesteps that too, but the redirect
# stays regardless: it keeps the resolve out of the image's system gem tree, and it keeps a
# BASE_IMAGE override pointing at a non-hardened, non-root base working unchanged.
# BUNDLE_APP_CONFIG is redirected for a different reason — without it bundler writes .bundle/config
# into the bind-mounted checkout.
"${RUNTIME}" run --rm --platform linux/amd64 \
  -v "${REPO_ROOT}":/src -w /src \
  --user 0 \
  -e GEMS="$*" \
  -e GEM_HOME=/tmp/relock-gems \
  -e BUNDLE_PATH=/tmp/relock-bundle \
  -e BUNDLE_APP_CONFIG=/tmp/relock-bundle/.bundle \
  "${BASE}" bash -lc "${CONTAINER_SCRIPT}"

echo
echo "==> docker/Gemfile.lock regenerated. Review the diff before committing:"
echo "      git diff -- docker/Gemfile.lock"
echo
echo "    docker/gem/ and pkg/ are build artifacts and are gitignored; they are left in place so a"
echo "    following image build can reuse them. Remove them with: rm -rf docker/gem pkg"
