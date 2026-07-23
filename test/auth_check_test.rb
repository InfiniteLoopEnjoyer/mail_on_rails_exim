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
end
