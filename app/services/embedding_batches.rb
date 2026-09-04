# Groups passages into embedding requests.
#
# The API caps a request at 100 items, but that is rarely what binds. Measured
# against the free tier with a minute between probes, requests of 10, 15 and 20
# chunks (up to ~13,000 tokens) all succeed; a request of 100 chunks (~65,000
# tokens) does not.
#
# Those measurements were taken on the free tier, whose per-minute budget was far
# tighter than the paid one now in use. Batching by tokens is kept regardless: the
# ceiling moved, it did not disappear, and a request sized by item count would
# still be the wrong shape.
#
# The tighter constraint is a *per-minute* token budget rather than a per-request
# one. An earlier reading of this was wrong: those probes were three seconds
# apart and were exhausting the minute, not the request. Pacing is therefore the
# job's problem, handled by retrying with backoff; this class only has to build
# requests the API will accept individually.
#
# One batch is one HTTP request, which is what makes a retry meaningful: the unit
# that fails is the unit that gets tried again.
class EmbeddingBatches
  # The API's hard limit, from its own 400 response: "at most 100 requests can
  # be in one batch". Rarely the binding constraint, but it is a real one.
  MAX_ITEMS = 100

  # Comfortably inside what a single request has been observed to accept
  # (~13,000 tokens), with room for the estimate being rough.
  MAX_TOKENS = 10_000

  # Rough, and intentionally so: an exact count would cost an API call per
  # batch to learn something an estimate already tells us closely enough.
  # Roughly four characters to the token.
  CHARS_PER_TOKEN = 4

  def self.for(texts, max_tokens: MAX_TOKENS, max_items: MAX_ITEMS)
    batches = []
    current = []
    current_tokens = 0

    texts.each do |text|
      tokens = estimate(text)
      too_many = current.length >= max_items
      too_big = current.any? && (current_tokens + tokens) > max_tokens

      if too_many || too_big
        batches << current
        current = []
        current_tokens = 0
      end

      current << text
      current_tokens += tokens
    end

    batches << current if current.any?
    batches
  end

  def self.estimate(text) = (text.to_s.length / CHARS_PER_TOKEN.to_f).ceil
end
