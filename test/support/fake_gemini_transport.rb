# Stands in for the HTTP transport so tests can assert what would have gone over
# the wire and drive every failure mode. This project has no mocking library —
# Minitest 6 dropped Minitest::Mock and there is no webmock — so the fake is a
# plain object matching the transport's single method.
class FakeGeminiTransport
  attr_reader :calls

  # Each queued response is either a Hash (returned as a Gemini success envelope
  # wrapping that JSON), a [status, body] pair for raw control, or an exception
  # class to raise.
  def initialize(*responses)
    # Deliberately not flattened: a [status, body] pair is one response, and
    # flattening would split it into two.
    @responses = responses
    @calls = []
  end

  def call(url:, headers:, body:)
    @calls << { url: url, headers: headers, body: JSON.parse(body) }

    response = @responses.shift
    raise "FakeGeminiTransport received an unexpected extra call (#{@calls.length} so far)" if response.nil?
    raise response if response.is_a?(Class)

    build(response)
  end

  def call_count = @calls.length

  # What the model was actually asked, as sent.
  def prompt_for(index = 0) = @calls.dig(index, :body, "contents", 0, "parts", 0, "text").to_s

  def generation_config(index = 0) = @calls.dig(index, :body, "generationConfig") || {}

  private
    def build(response)
      status, body =
        case response
        when Array then response
        when String then [ 200, response ]
        else [ 200, response.to_json ]
        end

      GeminiClient::NetHttpTransport::Response.new(status: status, body: body)
    end
end
