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

COPY bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/healthcheck \
             /usr/local/bin/rails-ingress /usr/local/bin/rails-outbound \
             /usr/local/bin/auth-check /usr/local/bin/rcpt-check

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
