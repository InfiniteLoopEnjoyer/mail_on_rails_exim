# frozen_string_literal: true

require "test_helper"
load_bin "rails-outbound"

# The outbound handoff must queue mail as the AUTHENTICATED identity (never
# the client-supplied envelope sender) and encode recipients so Rails'
# `Array(params[:rcpt])` sees each one; and it must turn the app's status
# codes into the right Exim exit code (507 -> retry, 4xx -> bounce).
class OutboundRequestTest < Minitest::Test
  BASE = "https://app.test/mail_on_rails/internal"

  def uri(sender: "", auth: "", rcpts: [])
    RailsOutbound.request_uri(BASE, sender: sender, auth: auth, rcpts: rcpts)
  end

  def params(u)
    URI.decode_www_form(u.query)
  end

  def test_mail_from_is_the_authenticated_identity_not_the_envelope_sender
    p = params(uri(sender: "spoofed@evil.test", auth: "bob@local.test", rcpts: [ "x@remote.test" ]))
    assert_equal "bob@local.test", p.assoc("mail_from").last
  end

  def test_mail_from_falls_back_to_envelope_sender_when_unauthenticated
    p = params(uri(sender: "bob@local.test", auth: "", rcpts: [ "x@remote.test" ]))
    assert_equal "bob@local.test", p.assoc("mail_from").last
  end

  def test_one_rcpt_param_per_recipient_url_encoded
    u = uri(auth: "bob@local.test", rcpts: [ "carol+tag@remote.test", "dave@remote.test" ])
    # Encoded on the wire the way Rails expects an array param.
    assert_includes u.query, "rcpt%5B%5D=carol%2Btag%40remote.test"
    assert_includes u.query, "rcpt%5B%5D=dave%40remote.test"
    # ...and decodes back to exactly the two addresses.
    rcpts = params(u).select { |k, _| k == "rcpt[]" }.map(&:last)
    assert_equal [ "carol+tag@remote.test", "dave@remote.test" ], rcpts
  end

  def test_targets_the_outbound_messages_endpoint_without_a_double_slash
    assert_equal "/mail_on_rails/internal/outbound_messages",
                 RailsOutbound.request_uri("#{BASE}/", sender: "s@x", auth: "", rcpts: []).path
  end

  def test_classify_maps_status_to_exit_code
    assert_equal 0,  RailsOutbound.classify(201)  # created
    assert_equal 0,  RailsOutbound.classify(200)
    assert_equal 75, RailsOutbound.classify(507)  # queue full -> retry
    assert_equal 1,  RailsOutbound.classify(422)  # rejected -> bounce
    assert_equal 1,  RailsOutbound.classify(400)
    assert_equal 75, RailsOutbound.classify(500)  # server error -> retry
    assert_equal 75, RailsOutbound.classify(302)  # unexpected -> retry
  end
end
