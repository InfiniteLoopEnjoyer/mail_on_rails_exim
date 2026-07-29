# frozen_string_literal: true

require "test_helper"
load_bin "auth-check"

# AUTH is granted iff the internal API answers 2xx with a non-null
# account_id. Credentials arrive base64-wrapped (so spaces/specials in a
# password survive Exim's whitespace-split of the ${run} command), and
# anything that isn't a clean success must deny.
class AuthCheckTest < Minitest::Test
  def test_decode_round_trips_passwords_with_spaces_and_specials
    original = "p@ss word+with=specials/&?"
    encoded = [ original ].pack("m0")
    assert_equal original, AuthCheck.decode(encoded)
  end

  def test_decode_of_blank_argument_is_empty
    assert_equal "", AuthCheck.decode(nil)
    assert_equal "", AuthCheck.decode("")
  end

  def test_valid_when_2xx_with_account_id
    assert AuthCheck.authenticated?(200, '{"account_id":7,"email":"bob@local.test"}')
  end

  def test_denied_when_account_id_is_null
    refute AuthCheck.authenticated?(200, '{"account_id":null,"email":null}')
  end

  def test_denied_on_non_2xx_even_if_body_looks_ok
    # e.g. a 401 means OUR api password is wrong - never treat as authed.
    refute AuthCheck.authenticated?(401, '{"account_id":7}')
  end

  def test_denied_on_malformed_json
    refute AuthCheck.authenticated?(200, "not json")
    refute AuthCheck.authenticated?(200, "")
  end

  # A throttled attempt comes back as a normal denial, so no special
  # handling is needed here - but it must not be mistaken for a success.
  def test_denied_when_the_app_reports_a_throttle
    refute AuthCheck.authenticated?(200, '{"account_id":null,"email":null,"throttled":true,"retry_after":840}')
  end

  # The client address rides along as a third argument so the app can count
  # brute-force attempts per source, and is omitted rather than sent blank
  # when Exim has none (a locally submitted message).
  def test_the_client_ip_is_sent_when_present
    fields = AuthCheck.form_fields("bob@local.test", "pw", "203.0.113.9")
    assert_equal "203.0.113.9", fields[:ip]
  end

  def test_a_blank_client_ip_is_omitted_entirely
    refute_includes AuthCheck.form_fields("bob@local.test", "pw", "").keys, :ip
    refute_includes AuthCheck.form_fields("bob@local.test", "pw", nil).keys, :ip
  end

  def test_credentials_are_always_sent
    fields = AuthCheck.form_fields("bob@local.test", "pw", nil)
    assert_equal "bob@local.test", fields[:email]
    assert_equal "pw", fields[:password]
  end

  # The edge names itself so the app's attempt log can tell SMTP AUTH
  # failures apart from IMAP and web ones.
  def test_the_edge_identifies_itself_as_smtp
    assert_equal "smtp", AuthCheck.form_fields("bob@local.test", "pw", nil)[:source]
  end
end
