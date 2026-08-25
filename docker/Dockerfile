FROM ruby:3.3-bookworm AS builder

ADD ./ /app/
WORKDIR /app
RUN gem install bundler
RUN bundle update --bundler
RUN bundle install

RUN bundle exec rake build -t -v

FROM registry.access.redhat.com/ubi9/ruby-33

ARG VERSION

LABEL name="Splunk Connect for Kubernetes Objects container" \
      maintainer="DataEdge@splunk.com" \
      vendor="Splunk Inc." \
      version=${VERSION} \
      release=${VERSION} \
      summary="Splunk Connect for Kubernetes Objects container" \
      description="Splunk Connect for Kubernetes Objects container"

ENV VERSION=${VERSION}
ENV FLUENT_USER=fluent

# GEM_HOME AND BUNDLE_PATH MUST BE PINNED, or the image builds clean, scans clean, and cannot boot.
#
# The UBI Ruby images do not set GEM_HOME, so Gem.dir is derived per-user. Measured in this image:
#     as root    Gem.dir=/usr/local/share/gems
#     as fluent  Gem.dir=/opt/app-root/src/.local/share/gem/ruby
# `bundle install` below runs as root; CMD runs as $FLUENT_USER. Without a pinned GEM_HOME the two
# resolve different directories and the container dies with:
#     bundler: command not found: fluentd
#     Install missing gem executables with `bundle install`
# Nothing in a vulnerability scan catches this — the gems are present, just not where the runtime user
# looks.
#
# BUNDLE_PATH IS DELIBERATELY NOT SET. Setting it alongside GEM_HOME is what broke the first attempt:
# bundler then installs application-locked binstubs to its own path while RubyGems resolves against
# GEM_HOME, and the two disagree. RubyGems' own Docker guide is explicit that BUNDLE_PATH and
# BUNDLE_BIN should be left unset so GEM_HOME takes precedence:
#   https://guides.rubygems.org/bundler_docker_guide
# PATH carries BOTH ${GEM_HOME}/bin and ${GEM_HOME}/gems/bin, per that guide — the second is where
# gem-provided executables land, and omitting it is another way to get 'command not found'.
ENV GEM_HOME=/usr/local/bundle
ENV BUNDLE_APP_CONFIG=/usr/local/bundle
ENV PATH=/usr/local/bundle/bin:/usr/local/bundle/gems/bin:$PATH

USER root

COPY --from=builder /app/pkg/fluent-plugin-*.gem /tmp/

RUN mkdir /licenses
COPY --from=builder /app/LICENSE /licenses/LICENSE

RUN dnf install -y jq

COPY --from=builder /app/docker/Gemfile* ./

# ESSENTIAL STEPS, IN THEIR OWN RUN, WITH NO `|| true`. This was one long &&-chain ending in `|| true`,
# and that shape caused a shipped image that scanned clean and could not boot: pinning GEM_HOME moved
# bundler out of /usr/share/gems, so `gem uninstall -i /usr/share/gems bundler` failed with
# Gem::FilePermissionError, the && chain short-circuited, `bundle install` NEVER RAN, and `|| true`
# reported the whole thing as success. A vulnerability scan cannot see that — the image is simply
# missing its application.
#
# The `gem install bundler` / `gem uninstall bundler` dance from the original is gone with it: it
# existed to swap the system bundler, which a pinned GEM_HOME makes unnecessary.
RUN dnf update -y \
 && dnf clean all \
 && gem install bundler -v '~> 2.0' --no-document \
 && gem unpack /tmp/*.gem --target gem \
 && bundle install

# PROVE THE IMAGE CAN RUN, AT BUILD TIME. One line, and it is the difference between finding a broken
# image here and finding it in a cluster. `bundle exec fluentd --version` exercises the same resolution
# path the CMD uses, so a GEM_HOME/BUNDLE_PATH mismatch fails the build instead of shipping.
RUN bundle exec fluentd --version

# ATTACK-SURFACE REDUCTION, deliberately separate and deliberately NOT `rpm -e --nodeps ... || true`.
# Force-removing ~25 packages with --nodeps leaves a broken dependency graph and lowers a scanner count
# without lowering risk; swallowing the result with `|| true` means it silently does nothing when it
# breaks. These are removed by name, through dnf so dependencies are respected, and the step is allowed
# to fail the build if it cannot do so cleanly. Each one is here because nothing in a fluentd image
# needs it: no compilation at runtime, no source checkouts, no remote shells.
RUN dnf remove -y nodejs npm git binutils openshift-clients openssh-clients \
 && dnf clean all \
 && rm -rf /var/cache/dnf /tmp/*.gem

RUN mkdir -p ${GEM_HOME} && chmod -R a+rX ${GEM_HOME}

RUN groupadd -r $FLUENT_USER && \
  useradd -r -g $FLUENT_USER $FLUENT_USER && \
  mkdir -p /fluentd/log fluentd/etc /fluentd/plugins &&\
  chown -R $FLUENT_USER /fluentd && chgrp -R $FLUENT_USER /fluentd && \
  chmod +t /tmp

USER $FLUENT_USER
# EXEC FORM, NOT SHELL FORM. With `CMD bundle exec ...` docker runs it via /bin/sh -c, so PID 1
# is the shell and fluentd is its child. The shell does not forward signals, so a Kubernetes
# SIGTERM on pod deletion never reaches fluentd: it is not flushed, in-flight events are lost,
# and the kubelet SIGKILLs it after the grace period. Exec form makes fluentd PID 1 and gives it
# the signal directly. This also silences docker's JSONArgsRecommended warning, but the reason
# to do it is the lost telemetry, not the warning.
CMD ["bundle", "exec", "fluentd", "-c", "/fluentd/etc/fluent.conf"]
