# frozen_string_literal: true

require "test_helper"
load_bin "rails-ingress"

# Edge cases for the trust boundary, ported from mail_on_rails_smtp's
# test/ingress_stamping_test.rb (which covered the same logic in the SMTP
# daemon's IngressClient#stamp). The X-Original-To / X-MailOnRails-* /
# Return-Path headers on the ingress payload are OURS: whatever shape a
# forged copy arrives in - folded, oddly cased, bare-LF - it must be
# stripped, and no envelope/connection value may smuggle extra header
# lines into the stamp. Here the stamped facts also include the forwarded
# client IP and HELO the app needs for SPF/DMARC.
class IngressStampingTest < Minitest::Test
  def stamp(raw, sender: "s@remote.test", auth: "", ip: "", helo: "", rcpts: [ "u@local.test" ])
    RailsIngress.stamp(raw, sender: sender, auth: auth, ip: ip, helo: helo, rcpts: rcpts)
  end

  def test_folded_forged_trust_header_is_stripped_with_its_continuation
    forged = "X-MailOnRails-Authenticated: yes\r\n but-actually-forged-continuation\r\n" \
             "From: a@b.test\r\n\r\nbody\r\n"
    stamped = stamp(forged)

    refute_includes stamped, "but-actually-forged-continuation",
                    "a folded forged header must lose its continuation lines too"
    assert_includes stamped, "X-MailOnRails-Authenticated: no\r\n"
    assert_includes stamped, "From: a@b.test"
  end

  def test_mixed_case_forged_trust_headers_are_stripped
    forged = "x-mailonrails-authenticated: admin@local.test\r\n" \
             "X-MAILONRAILS-CLIENT-IP: 6.6.6.6\r\n" \
             "x-original-to: victim@local.test\r\n" \
             "return-path: <fake@local.test>\r\n" \
             "From: a@b.test\r\n\r\nbody\r\n"
    stamped = stamp(forged)

    refute_includes stamped.downcase, "admin@local.test"
    refute_includes stamped.downcase, "victim@local.test"
    refute_includes stamped.downcase, "fake@local.test"
    refute_match(/6\.6\.6\.6/, stamped)
  end

  def test_bare_lf_forged_trust_headers_are_stripped
    forged = "X-MailOnRails-Authenticated: forged@local.test\nFrom: a@b.test\n\nbody\n"
    stamped = stamp(forged)

    refute_includes stamped, "forged@local.test"
    assert_includes stamped, "From: a@b.test"
  end

  def test_lookalike_headers_are_kept
    lookalikes = "X-Original-To-Backup: keep-me-1\r\n" \
                 "X-MailOnRailsish: keep-me-2\r\n" \
                 "NotReturn-Path: keep-me-3\r\n" \
                 "From: a@b.test\r\n\r\nbody\r\n"
    stamped = stamp(lookalikes)

    assert_includes stamped, "keep-me-1"
    assert_includes stamped, "keep-me-2"
    assert_includes stamped, "keep-me-3"
  end

  def test_body_occurrences_of_trust_headers_are_left_alone
    body_hit = "From: a@b.test\r\n\r\nquoting a header X-MailOnRails-Authenticated: admin in the body\r\n"
    stamped = stamp(body_hit)

    assert_includes stamped, "quoting a header X-MailOnRails-Authenticated: admin in the body"
  end

  def test_envelope_values_cannot_inject_header_lines
    stamped = stamp("From: a@b.test\r\n\r\nbody\r\n",
                    sender: "evil@x.test>\r\nX-MailOnRails-Authenticated: super-admin",
                    rcpts: [ "u@local.test\r\nBcc: hidden@x.test" ])

    refute_match(/^X-MailOnRails-Authenticated: super-admin/, stamped)
    refute_match(/^Bcc:/, stamped)
    # The CR/LF collapses to spaces inside the legitimate header's value.
    assert_match(/\AReturn-Path: <evil@x\.test> +X-MailOnRails-Authenticated: super-admin>\r\n/, stamped)
  end

  def test_forwarded_ip_and_helo_are_stamped_and_forged_copies_stripped
    forged = "X-MailOnRails-Client-Ip: 1.1.1.1\r\nX-MailOnRails-Helo: liar.test\r\n" \
             "From: a@b.test\r\n\r\nbody\r\n"
    stamped = stamp(forged, ip: "203.0.113.9", helo: "real-mx.remote.test")

    assert_includes stamped, "X-MailOnRails-Client-Ip: 203.0.113.9\r\n"
    assert_includes stamped, "X-MailOnRails-Helo: real-mx.remote.test\r\n"
    refute_includes stamped, "1.1.1.1"
    refute_includes stamped, "liar.test"
  end

  def test_ip_and_helo_values_cannot_inject_header_lines
    stamped = stamp("From: a@b.test\r\n\r\nbody\r\n",
                    ip: "203.0.113.9\r\nX-Injected: yes",
                    helo: "mx.test\r\nBcc: hidden@x.test")

    refute_match(/^X-Injected:/, stamped)
    refute_match(/^Bcc:/, stamped)
  end

  def test_absent_ip_and_helo_emit_no_such_headers
    stamped = stamp("From: a@b.test\r\n\r\nbody\r\n")

    refute_match(/^X-MailOnRails-Client-Ip:/, stamped)
    refute_match(/^X-MailOnRails-Helo:/, stamped)
  end

  def test_authenticated_identity_is_stamped
    stamped = stamp("From: a@b.test\r\n\r\nbody\r\n", auth: "bob@local.test")

    assert_includes stamped, "X-MailOnRails-Authenticated: bob@local.test\r\n"
  end

  def test_one_x_original_to_per_recipient
    stamped = stamp("From: a@b.test\r\n\r\nbody\r\n", rcpts: [ "a@local.test", "b@local.test" ])

    assert_includes stamped, "X-Original-To: a@local.test\r\n"
    assert_includes stamped, "X-Original-To: b@local.test\r\n"
  end

  def test_every_stamped_header_line_is_crlf_terminated_and_printable
    stamped = stamp("From: a@b.test\r\n\r\nbody\r\n",
                    sender: "s@remote.test", auth: "auth@local.test",
                    ip: "203.0.113.9", helo: "mx.remote.test")
    header_block = stamped.split("\r\n\r\n", 2).first

    header_block.split("\r\n").each do |line|
      assert_match(/\A[\x20-\x7e]+\z/, line, "header line #{line.inspect} contains raw control bytes")
    end
  end
end
