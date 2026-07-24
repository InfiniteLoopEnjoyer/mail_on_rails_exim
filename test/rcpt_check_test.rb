# frozen_string_literal: true

require "test_helper"
load_bin "rcpt-check"

# RCPT verification: the address arrives base64-wrapped (Exim splits the
# ${run} command on whitespace), is checked against the app's rcpt_check,
# and is "local" iff the endpoint echoes it back in its `local` array
# (matched case/space-insensitively, the same normalization the app and the
# mailroom use). The endpoint URL must not grow a double slash.
class RcptCheckTest < Minitest::Test
  BASE = "https://app.test/mail_on_rails/internal"

  def test_decode_round_trips_addresses_with_specials
    original = "carol+tag@local.test"
    assert_equal original, RcptCheck.decode([ original ].pack("m0"))
  end

  def test_decode_of_blank_argument_is_empty
    assert_equal "", RcptCheck.decode(nil)
    assert_equal "", RcptCheck.decode("")
  end

  def test_endpoint_targets_rcpt_check_without_a_double_slash
    assert_equal "/mail_on_rails/internal/rcpt_check", RcptCheck.endpoint("#{BASE}/").path
    assert_equal "/mail_on_rails/internal/rcpt_check", RcptCheck.endpoint(BASE).path
  end

  def test_local_when_address_is_echoed_back
    body = '{"local":["carol@local.test"]}'
    assert RcptCheck.local?(body, "carol@local.test")
  end

  def test_local_match_is_case_and_space_insensitive
    body = '{"local":["carol@local.test"]}'
    assert RcptCheck.local?(body, "  Carol@Local.Test  ")
  end

  def test_not_local_when_absent_from_the_list
    body = '{"local":[]}'
    refute RcptCheck.local?(body, "nobody@local.test")
  end

  def test_not_local_on_malformed_or_shapeless_json
    refute RcptCheck.local?("not json", "carol@local.test")
    refute RcptCheck.local?('{"local":"carol@local.test"}', "carol@local.test")
    refute RcptCheck.local?("", "carol@local.test")
  end

  # The internal API is a hard requirement (bin/entrypoint aborts without it),
  # so there is no silent-accept path: an unconfigured API defers (exit 2)
  # rather than accepting a recipient it can't verify.
  def test_defers_when_internal_api_is_not_configured
    with_env("INTERNAL_API_URL" => nil, "INTERNAL_API_PASSWORD" => nil) do
      assert_equal 2, RcptCheck.main([ [ "carol@local.test" ].pack("m0") ])
    end
  end

  def with_env(values)
    saved = values.keys.to_h { |k| [ k, ENV[k] ] }
    values.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
