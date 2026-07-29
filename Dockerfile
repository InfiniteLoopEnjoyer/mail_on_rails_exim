# syntax=docker/dockerfile:1
# check=error=true

# Production image for the mail_on_rails_exim mail edge (see
# config/deploy.yml). Exim receives inbound mail and authenticated
# submission; small Ruby helpers (bin/*) hand mail to the Rails app over
# HTTP - the relay ingress for inbound + local submission, the internal
# API for authenticated outbound and AUTH checks. No Rails app code, no
# database, no master key.

# Matches the app image's Ruby (see the sibling repos' .ruby-version).
ARG RUBY_VERSION=4.0.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Exim with content scanning (the -heavy daemon: bin/entrypoint enables a
# DATA-time ClamAV check via av_scanner/malware when EXIM_CLAMAV_ADDR is
# set; heavy also pulls extra lookup/DB libs - a few tens of MB, accepted
# for the native scan path) plus CA certs so the Ruby helpers' HTTPS calls
# to the app verify. The package creates the Debian-exim user/group. The
# helpers use only the Ruby standard library, so there is no
# Gemfile / bundle step.
RUN apt-get update && apt-get install -y --no-install-recommends \
      exim4-daemon-heavy \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The json default gem shipped with this Ruby (2.18.0) carries
# CVE-2026-33210, and the helpers parse/generate JSON (bin/auth-check).
# Install a fixed version (C extension, hence the throwaway compiler), then
# remove the default gem entirely - spec AND stdlib copies. The stdlib
# copy matters: the helpers run plain ruby, and `require "json"` finds a
# file sitting on $LOAD_PATH before rubygems ever considers the newer gem,
# so leaving it would silently keep loading 2.18.0. The trailing ruby -e
# asserts the fix took, failing the build instead of shipping quietly
# vulnerable.
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && gem install json --no-document \
    && rm /usr/local/lib/ruby/gems/*/specifications/default/json-*.gemspec \
    && rm -rf /usr/local/lib/ruby/[0-9]*/json.rb /usr/local/lib/ruby/[0-9]*/json \
              /usr/local/lib/ruby/[0-9]*/*-linux*/json \
    && ruby -e 'require "json"; abort "json #{JSON::VERSION} still vulnerable" unless Gem::Version.new(JSON::VERSION) >= Gem::Version.new("2.19.2")' \
    && apt-get purge -y build-essential && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/healthcheck \
             /usr/local/bin/rails-ingress /usr/local/bin/rails-outbound \
             /usr/local/bin/auth-check

COPY config/exim4.conf.template /etc/exim4/exim4.conf.template

# Mount point for the shared mailconf volume (see config/deploy.yml). Owned
# by the Rails app's uid so that if THIS container is the first to mount the
# fresh named volume, Docker's first-mount copy leaves it writable by the
# app; bin/entrypoint also repairs the perms on every boot.
RUN mkdir -p /var/lib/exim4/dynamic && chown 1000:1000 /var/lib/exim4/dynamic

EXPOSE 25 587 465

# Liveness: the MX listener must answer its banner.
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD ["/usr/local/bin/ruby", "/usr/local/bin/healthcheck"]

ENTRYPOINT ["/usr/local/bin/ruby", "/usr/local/bin/entrypoint"]
