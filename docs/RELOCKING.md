# Regenerating `Gemfile.lock` — two ways, and when to use each

`docker/Gemfile.lock` decides what actually ships in the image. It is a reviewed artefact, not a build
by-product, so it is regenerated deliberately and committed. This describes the two ways to do that.

**The short version:** use `ci_scripts/relock.sh` (container). Reach for a local Ruby only if you are
iterating and want the faster loop — and re-run the container version before you commit.

---

## 0. Why you cannot just run `bundle lock`

Two reasons, and both bite silently.

**The host Ruby is too old.** This machine has **Ruby 2.6.10**. The stack being targeted needs 3.2+:

```
$ ruby -e 'print RUBY_VERSION'
2.6.10

$ ruby -e 'puts Gem::Requirement.new(">= 3.2").satisfied_by?(Gem::Version.new(RUBY_VERSION))'
false          # fluentd 1.19.3 requires >= 3.2
```

Bundler will still produce *a* lockfile on 2.6 — it will just quietly resolve older versions that satisfy
the old Ruby, and the result fails at image build or, worse, at runtime.

**`docker/Gemfile` has a `path:` dependency that does not exist in a checkout:**

```ruby
gem 'fluent-plugin-<name>', path: 'gem/'
```

`docker/gem/` is created *during the image build*, when the runtime stage unpacks the `.gem` the builder
stage produced. Run bundler against `docker/Gemfile` in a clean checkout and you get:

```
The path `/src/docker/gem` does not exist.
```

and **the lock is left untouched** — which reads like "nothing to do" rather than "this failed". Both
approaches below solve this the same way: build the plugin gem, unpack it, *then* resolve.

---

## 1. Container (default) — `ci_scripts/relock.sh`

Resolves against the exact image the container will run.

```sh
cd /Users/olasumbo/gitRepos/<repo>

ci_scripts/relock.sh                    # re-resolve, no constraint changes
ci_scripts/relock.sh kubeclient         # update ONE gem and its transitives
ci_scripts/relock.sh rack oj            # update these, one at a time, in order
```

**During a base migration you must override the image.** The script reads the base from the last `FROM`
in `docker/Dockerfile`. To move *to* ruby-33, you have to resolve against 3.3 *before* the Dockerfile
says 3.3 — otherwise you lock against the Ruby you are leaving:

```sh
BASE_IMAGE=registry.access.redhat.com/ubi9/ruby-33:latest ci_scripts/relock.sh kubeclient
```

Podman instead of Docker:

```sh
CONTAINER_RUNTIME=podman ci_scripts/relock.sh kubeclient
```

**Use this when:** producing a lock you intend to commit; changing the base image; anything that touches a
gem with a native extension (`oj`, `msgpack`, `yajl-ruby`, `http-parser` are all in this stack).

**Cost:** roughly 60–90 seconds per repo. Requires a running container runtime and network.

### What it does, and the three traps it handles

Each is a bug that cost real time; the script carries the reasoning in comments so nobody re-derives it.

| stage | what | why |
|---|---|---|
| 1 | `bundle lock --update=<gem>` at repo root, then `bundle install`, then `rake build` | There are **two** lockfiles. The root pair builds the gem, `docker/` assembles the image. A gem constrained in the gemspec appears in both, so updating only `docker/Gemfile.lock` leaves the root lock contradicting the gemspec and stage 1 dies before the docker resolve is reached. |
| 2 | `gem unpack ../pkg/*.gem --target gem` | Creates the `path: 'gem/'` directory the Gemfile needs — §0. |
| 3 | `bundle lock --update=<gem>` in `docker/` | The actual relock. |

Two more, both non-obvious:

- **`GEM_HOME`/`BUNDLE_PATH` are redirected to `/tmp`.** UBI Ruby images run as a non-root uid whose
  `GEM_HOME` is `/usr/share/gems`, owned by root. The lock records `BUNDLED WITH <version>`, bundler tries
  to install exactly that into `GEM_HOME`, and the write fails with `Bundler::PermissionError` — after
  which it prints a hundred-line report **and leaves the lock unchanged**.
- **Bundler is pinned to `~> 2.0`.** Every gemspec here declares `add_development_dependency bundler,
  '~> 2.0'`. A bare `gem install bundler` now gives 4.x, and the resolve then fails with
  `the current Bundler version (4.0.19) does not satisfy bundler ~> 2.0` — an error that blames the
  Gemfile and sends you looking in the wrong place.

---

## 2. Local Ruby via rbenv — the fast iteration loop

**Nothing is installed on this machine today.** No `rbenv`, `rvm`, `chruby`, `asdf` or `mise`. Homebrew
offers Ruby 4.0.6, which is the wrong version. So this path requires setup first.

### Setup, once

```sh
brew install rbenv ruby-build
echo 'eval "$(rbenv init - zsh)"' >> ~/.zshrc && exec zsh

rbenv install 3.3.12        # matches ubi9/ruby-33 exactly — check with the command below
rbenv versions
```

Confirm the target before installing, so this cannot silently drift from the image:

```sh
docker run --rm --platform linux/amd64 --entrypoint ruby \
  registry.access.redhat.com/ubi9/ruby-33:latest -e 'print RUBY_VERSION'
# 3.3.12
```

### Per repo

```sh
cd /Users/olasumbo/gitRepos/<repo>
rbenv local 3.3.12                      # writes .ruby-version — DO NOT COMMIT IT, see below
gem install bundler -v '~> 2.0'

# stage 1 — root lock, then build the gem
bundle lock --update=kubeclient
bundle install
bundle exec rake build

# stage 2 — create the path dependency
cd docker && rm -rf gem && gem unpack ../pkg/*.gem --target gem

# stage 3 — the actual relock
bundle lock --update=kubeclient
```

That is the same three stages the script runs; you are doing them by hand against a local interpreter.

**Use this when:** iterating on constraints and re-resolving repeatedly, where 60–90s per attempt is
annoying. Re-run the container version before committing.

### Two things to be careful about

**Do not commit `.ruby-version`.** It becomes a second place the Ruby version is declared, and when it
drifts from the Dockerfile the lock resolves cleanly on your laptop and breaks in the image. The
Dockerfile's last `FROM` is the single source of truth — which is exactly why `relock.sh` reads it rather
than taking an argument.

**A locally compiled Ruby is not the image's Ruby.** rbenv builds against Homebrew's OpenSSL and your
system toolchain; the image ships Red Hat's. Same version number, different build. For pure-Ruby gems the
resolution is identical. For native extensions it is not guaranteed — and this stack has eight:
`oj`, `msgpack`, `yajl-ruby`, `ffi`, `ffi-compiler`, `cool.io`, `strptime`, `sigdump` (plus
`http_parser.rb`/`llhttp-ffi` pulling `ffi-compiler`). That is the whole reason the container is the
default.

---

## 3. Which to use

| | container (`relock.sh`) | local rbenv |
|---|---|---|
| matches the shipped image | **exactly** | same version, different build |
| setup needed | none (Docker/Podman) | brew + rbenv + ruby-build |
| speed | 60–90s per repo | faster after warm-up |
| safe for native-extension gems | **yes** | not guaranteed |
| safe for a base-image change | **yes**, via `BASE_IMAGE` | no — resolves against local Ruby |
| **produces the lock you commit** | **yes** | re-verify with the container first |

The container path is not slower in any way that matters: this runs a handful of times per hardening
pass. Correctness is worth 90 seconds.

---

## 4. Committing

Always read the diff — the point of one-gem-at-a-time is that it stays small enough to read:

```sh
git diff -- Gemfile.lock docker/Gemfile.lock
```

Check both: the gem you asked for, **and every transitive that moved with it**. The transitives are where
the surprises are. Then run the tests and scan before committing.

`pkg/` and `docker/gem/` are build artefacts and are gitignored in all four repos. They are left in place
so a following image build can reuse them; remove with `rm -rf docker/gem pkg`.
