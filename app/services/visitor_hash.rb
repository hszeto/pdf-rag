# A countable stand-in for a visitor, which is not an identity and cannot become
# one (D3).
#
# RateLimitKey deliberately keeps addresses out of the database — "held only in
# the cache for the length of a window and never written". Counting people needs
# something durable, so this is the compromise: an HMAC keyed by the application's
# secret and today's date.
#
# What that buys, precisely:
#
#   - countable    two requests from one address on one day give one value
#   - unreadable   the address cannot be recovered from the digest
#   - unlinkable   the key changes at midnight, so yesterday's value and today's
#                  cannot be matched to each other even by us
#
# The cost, accepted in the spec: a visitor spanning midnight counts twice. That
# is the same property as unlinkability, seen from the other side.
#
# The address is masked through RateLimitKey first, so an IPv6 subscriber handed a
# whole /64 counts once rather than once per address they happen to use.
class VisitorHash
  def self.for(address, on: Date.current)
    key = "#{Rails.application.secret_key_base}#{on}"

    OpenSSL::HMAC.hexdigest("SHA256", key, RateLimitKey.for(address))
  end
end
