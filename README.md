# mail_on_rails_exim

An [Exim](https://www.exim.org/) mail edge for the
[mail_on_rails](https://github.com/InfiniteLoopEnjoyer/mail_on_rails) app,
packaged as a single Docker image and deployed on its own with Kamal.
Exim terminates SMTP (MX + authenticated submission) and hands mail to the
Rails app over HTTP via small **Ruby** helpers; it holds **no Rails app
code, no database, and no master key**.

Built on the same `ruby:4.0.6-slim` base as the sibling repos, with Exim
installed on top. The helper scripts use only the Ruby standard library
(`net/http`, `json`, `uri`) — there is no Gemfile or bundle step.

## How mail flows

```
   internet ──► Exim :25 (MX) ─┬─ RCPT ────► POST internal/rcpt_check     (bin/rcpt-check)
                               │              (unknown local user → 550)
                               └─ DATA ────► POST relay ingress           (bin/rails-ingress)

   iPhone / client ─► Exim :587/:465 ─┬─ AUTH ────► POST internal/authenticate  (bin/auth-check)
                      (submission)     ├─ local ───► POST relay ingress          (bin/rails-ingress)
                                       └─ remote ──► POST internal/outbound_messages (bin/rails-outbound)
```

- **Inbound (port 25).** Each recipient in a domain we host is verified at
  RCPT time against the app ([`bin/rcpt-check`](bin/rcpt-check)): an unknown
  local user gets `550` (so the sender's server bounces it) instead of being
  accepted and silently dropped; an unreachable app defers with `451`. The
  accepted message is then POSTed to the app's Action Mailbox **relay
  ingress** ([`bin/rails-ingress`](bin/rails-ingress)), where Rails matches
  recipients to local accounts and does virus + spam scanning. The internal
  API is **required** — the edge refuses to start without it (see
  [bin/entrypoint](bin/entrypoint)) — so there is no path that accepts a
  recipient without verifying it.
- **Authenticated submission (587 STARTTLS / 465 implicit TLS).** This is
  the outgoing server an IMAP mail client (e.g. iPhone Mail) sends
  through. AUTH LOGIN/PLAIN credentials are checked against the app's
  `authenticate` endpoint ([`bin/auth-check`](bin/auth-check)). **Local**
  recipients go to the relay ingress; **remote** recipients are queued via
  the internal API's `outbound_messages`
  ([`bin/rails-outbound`](bin/rails-outbound)), where the app DKIM-signs
  and delivers them. The envelope sender is forced to the authenticated
  identity.

### Why "accept all recipients" is not an open relay

An open relay accepts anonymous mail and **forwards it onward to other
mail servers**. Unauthenticated mail here is only ever handed to the
**inbound ingress** (Rails), which drops anything with no local account.
The single path that leaves for another server is **authenticated
submission to a remote domain**
([`submission_outbound`](config/exim4.conf.template)), gated on a valid
login.

### The trust boundary (important)

The app's mailroom **trusts** the `X-Original-To`, `Return-Path`, and
`X-MailOnRails-*` headers. [`bin/rails-ingress`](bin/rails-ingress)
therefore **strips any such headers a remote sender forged** before
stamping the authoritative values that only the live SMTP connection
knows:

| Stamped header | Meaning |
| --- | --- |
| `Return-Path` | Envelope sender (`MAIL FROM`). |
| `X-Original-To` | One per envelope recipient, so BCC'd/aliased recipients route. |
| `X-MailOnRails-Authenticated` | The SMTP-AUTH identity, or `no`. |
| `X-MailOnRails-Client-Ip` | The connecting peer's IP. |
| `X-MailOnRails-Helo` | The HELO/EHLO name the client gave. |

Do not remove the stripping step — without it a sender could forge any of
these.

### Spam / spoofing checks (done in Rails)

Exim does no SPF/DKIM/DMARC itself; it just forwards what the connection
told it. The app runs those checks (via rspamd): DKIM needs only the
message bytes + DNS, and **SPF/DMARC** need the connecting IP + HELO +
envelope-sender — which the app reads from the trusted `X-MailOnRails-Client-Ip`
/ `X-MailOnRails-Helo` / `Return-Path` headers above and feeds to rspamd
(e.g. rspamd's `Ip` / `Helo` / `From` request fields). Mail from an
authenticated submitter carries `X-MailOnRails-Authenticated: <id>`, so
the app can skip inbound spoofing checks on it.

## Delivery guarantees

Exim is store-and-forward: it accepts each message onto its own spool and
returns `250` to the sender, then hands it to Rails from the queue. If
that handoff fails temporarily (app down, ingress 5xx, outbound queue full
→ HTTP 507) the helper exits `75`, so Exim keeps the message on its spool
and **retries** on its normal schedule; a permanent rejection (4xx) exits
`1` and bounces. So once a sender has `250`, this Exim owns the message
until Rails accepts it (or it bounces) — the sender is not kept waiting on
Rails.

## Configuration

All configuration is environment variables (see
[config/deploy.yml](config/deploy.yml) and [.env.example](.env.example)):

| Variable | Purpose |
| --- | --- |
| `EXIM_HELO_HOST` | Public mail name (banner/EHLO); match the PTR. |
| `EXIM_LOCAL_DOMAINS` | Domains you host (Exim `:`-separated list). Splits authenticated submission into local (→ ingress) vs remote (→ outbound). Defaults to `EXIM_HELO_HOST`. |
| `INGRESS_URL` / `INGRESS_PASSWORD` | Relay ingress URL + `action_mailbox.ingress_password`. |
| `INTERNAL_API_URL` / `INTERNAL_API_PASSWORD` | Internal API URL + `mail_on_rails.internal_api_password` (AUTH, outbound queueing, and inbound RCPT verification). **Required** — the entrypoint aborts if unset, since every inbound message is verified against it. |
| `EXIM_TLS_CERT` / `EXIM_TLS_KEY` | PEM paths. Unset ⇒ no TLS advertised (dev only; AUTH is then not offered). |

The config file holds no secrets — the Ruby helpers read the passwords
from the environment, which Exim passes to child processes via
`keep_environment`.

## Build and run by hand

```sh
docker build -t mail_on_rails_exim .

docker run -d -p 25:25 -p 587:587 -p 465:465 \
  -e EXIM_HELO_HOST=mail.example.com \
  -e EXIM_LOCAL_DOMAINS=example.com \
  -e INGRESS_URL=https://app.example.com/rails/action_mailbox/relay/inbound_emails \
  -e INGRESS_PASSWORD=... \
  -e INTERNAL_API_URL=https://app.example.com/mail_on_rails/internal \
  -e INTERNAL_API_PASSWORD=... \
  mail_on_rails_exim
```

Validate the rendered config without starting the daemon:

```sh
docker run --rm -e EXIM_HELO_HOST=mail.example.com \
  -e INGRESS_URL=x -e INGRESS_PASSWORD=x \
  -e INTERNAL_API_URL=x -e INTERNAL_API_PASSWORD=x \
  --entrypoint bash mail_on_rails_exim -c \
  'ruby -e "%w[EXIM_HELO_HOST].each{}; t=File.read(%q{/etc/exim4/exim4.conf.template}); ENV[%q{EXIM_LOCAL_DOMAINS}]=ENV[%q{EXIM_HELO_HOST}]; %w[EXIM_TLS_CERT EXIM_TLS_KEY].each{|k| ENV[k]||=%q{}}; File.write(%q{/etc/exim4/exim4.conf}, t.gsub(/@@(\w+)@@/){ENV[$1].to_s})" && exim4 -bV'
```

## Hardening

Because Exim accepts every message and forwards each to Rails (a Ruby
spawn + POST per message), and every AUTH attempt triggers a check, the
main section and ACLs bound that funnel. All values live in
[config/exim4.conf.template](config/exim4.conf.template) — tune them to
your real traffic:

- **Connection/volume caps**: `smtp_accept_max` (100),
  `smtp_accept_max_per_host` (10), `smtp_accept_max_per_connection` (50),
  and `recipients_max` (100 — each RCPT becomes one `X-Original-To` in a
  single ingress POST, so this bounds fan-out).
- **Per-IP recipient rate limit** in `acl_rcpt` (`100 / 1h`), with
  authenticated submitters exempt.
- **Per-IP AUTH throttle** in `acl_auth` (`10 / 1m`) — caps brute force
  and its Ruby-spawn amplification.
- **No version banner** (`smtp_banner`), header-size/loop caps
  (`header_maxsize`, `received_headers_max`).
- **TLS floor**: [bin/entrypoint](bin/entrypoint) asks `exim4 -bV` which
  TLS library this build uses and pins the matching directive
  (`openssl_options` / `tls_require_ciphers`) to TLS 1.2+, or leaves
  Exim's defaults if it can't tell.

The Ruby helpers set `write_timeout` and `min_version: :TLS1_2` on their
HTTP calls (cert verification is already on by default via
`ca-certificates`), and strip CR/LF from every value they stamp.

## Tests

```sh
bin/test
```

Stdlib `minitest`, no Gemfile/bundle. The helper scripts guard their
`main` with `if $PROGRAM_NAME == __FILE__`, so the suite `load`s a script
and exercises its pure methods directly.

- `test/ingress_stamping_test.rb` — test of trust boundary: forged
  `X-Original-To` / `Return-Path` / `X-MailOnRails-*` headers must be
  stripped in every shape (folded, mixed-case, bare-LF), body occurrences
  left alone, and no envelope/connection value (sender, recipient, IP,
  HELO) may inject extra header lines.
- `test/outbound_request_test.rb` — the outbound handoff queues mail as
  the *authenticated* identity (never the client's envelope sender),
  encodes `rcpt[]` the way Rails' `Array(params[:rcpt])` expects, and maps
  the app's status codes to the right Exim exit (507 → retry, 4xx →
  bounce).
- `test/auth_check_test.rb` — AUTH is granted only on a 2xx with a
  non-null `account_id`; base64 arg-wrapping round-trips passwords with
  spaces; malformed/`null`/non-2xx responses deny.
- `test/rcpt_check_test.rb` — a recipient is local only if the endpoint
  echoes it back (matched case/space-insensitively); the URL never doubles
  its slash; and with no internal API configured the check accepts (exit 0)
  rather than deferring everything.

## Deploy with Kamal

1. `cp .env.example .env` and fill in the two passwords.
2. Edit [config/deploy.yml](config/deploy.yml): `servers`, `registry`,
   `EXIM_HELO_HOST`, `EXIM_LOCAL_DOMAINS`, the app URLs, and the TLS paths.
3. `bin/kamal setup` (first time) or `bin/kamal deploy`.

Because the listeners publish host ports, Kamal's boot-new-before-stop
would clash on them, so [.kamal/hooks/pre-app-boot](.kamal/hooks/pre-app-boot)
stops the previous container first (a few seconds of downtime per deploy).

### Logging

Exim can't log to `/dev/stdout` (it requires `%s` in `log_file_path` and
won't open the device), so [bin/entrypoint](bin/entrypoint) makes the
main/reject/paniclog files FIFOs and streams the **main log** to the
container's stdout — `kamal logs` sees everything, and **nothing accumulates
on disk** (the pipes store nothing; reject/panic entries are copied into the
main log anyway, so their pipes are only drained). The stdout side is bounded
by the `logging:` block in [config/deploy.yml](config/deploy.yml)
(`max-size`/`max-file`), so Docker's own JSON log can't fill the host either.

## What the app side must provide

- `config.action_mailbox.ingress = :relay`.
- `action_mailbox.ingress_password` credential = `INGRESS_PASSWORD`.
- `mail_on_rails.internal_api_password` credential (or
  `SMTP_INTERNAL_API_PASSWORD` env) = `INTERNAL_API_PASSWORD`, backing the
  `authenticate`, `outbound_messages`, and `rcpt_check` endpoints. The last
  echoes back which of the submitted addresses are local accounts, matched
  the same way the mailroom routes them (stripped + lowercased).
- Account matching + virus scanning + rspamd filtering in the mailroom,
  and the actual outbound send. ClamAV / rspamd run as the **app's** Kamal
  accessories, not this service's.
- For SPF/DMARC on inbound mail, read `X-MailOnRails-Client-Ip`,
  `X-MailOnRails-Helo`, and `Return-Path` from the stamped message and
  pass them to rspamd (its `Ip`/`Helo`/`From` fields) — the app never sees
  the live connection, so these headers are the only source of that data.

> **Point your mail client's Outgoing (SMTP) server at this host**, port
> 587 (STARTTLS) or 465 (SSL), with the account's email + password. IMAP
> alone cannot send — the client always submits outgoing mail over SMTP.

## License

[MIT](LICENSE).
