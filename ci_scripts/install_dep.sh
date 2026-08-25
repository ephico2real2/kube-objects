#!/usr/bin/env bash
set -euo pipefail

# NO `gem update --system` HERE, and do NOT call this with sudo.
#
# On GitHub's ubuntu runners RubyGems is installed from APT, and `gem update --system` refuses:
#     ERROR: Your RubyGems was installed trough APT, and upgrading it through RubyGems
#     is not supported. ...
# exiting 5 and failing the job before a single test runs. It is also unnecessary: the workflow uses
# ruby/setup-ruby, which provides its own Ruby and RubyGems already.
#
# `sudo` was the second half of the problem. setup-ruby puts its Ruby on the invoking user's PATH;
# running under sudo picks up the SYSTEM ruby instead, so the gems get installed against the wrong
# interpreter and the tests then run against a third one.
#
# Bundler is pinned to the 2.x series because every gemspec in this repo declares
# `add_development_dependency 'bundler', '~> 2.0'`. A bare `gem install bundler` now fetches 4.x, and
# the resolve fails with an error that blames the Gemfile.
gem install bundler -v '~> 2.0' --no-document
bundle install
