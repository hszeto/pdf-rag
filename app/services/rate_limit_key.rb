# The identity a rate limit counts against.
#
# Not an identity in any meaningful sense — the app has no accounts and wants
# none. It is a bucket key, held only in the cache for the length of a window and
# never written to the database.
#
# IPv6 is masked to its /64 because a single subscriber is typically handed a
# whole /64. Counting per exact address would let one person take a fresh
# allowance for every request simply by using the next address they already own.
class RateLimitKey
  IPV6_PREFIX = 64

  def self.for(address)
    ip = IPAddr.new(address.to_s)
    ip.ipv6? ? "#{ip.mask(IPV6_PREFIX)}/#{IPV6_PREFIX}" : ip.to_s
  rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
    # A request whose origin cannot be read still has to be counted against
    # something, or it escapes the limit entirely by being malformed.
    "unknown"
  end
end
