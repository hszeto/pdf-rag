require "test_helper"

# The legacy provider is loaded by an initializer, which means it is easy to
# delete without anything failing until someone uploads an encrypted PDF — the
# same silent-until-production shape as the missing Postgres schema. This test
# is here to make that impossible; DatabaseNamespaceTest exists for the same
# reason.
class OpenSslProvidersTest < ActiveSupport::TestCase
  # D1
  test "RC4 is available, so Origami can open an encrypted PDF" do
    assert_nothing_raised { OpenSSL::Cipher::RC4.new }
  end

  # Loading a provider adds to the set in use rather than replacing it. If that
  # ever stopped being true, Rails' own message encryption would break long
  # before anything in this app noticed.
  test "loading the legacy provider leaves AES available" do
    assert_nothing_raised { OpenSSL::Cipher.new("aes-256-gcm") }
  end
end
