class GeminiClient
  # The real HTTP path, kept behind a one-method interface so tests can drive the
  # client without a network or a mocking library (Minitest 6 dropped
  # Minitest::Mock, and this project has no webmock).
  class NetHttpTransport
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 60

    Response = Struct.new(:status, :body, keyword_init: true) do
      def ok? = status == 200
    end

    def call(url:, headers:, body:)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      headers.each { |k, v| request[k] = v }
      request.body = body

      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
      ) { |http| http.request(request) }

      Response.new(status: response.code.to_i, body: response.body)
    rescue Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError => e
      # Network trouble is not exceptional here — it is one of the outcomes the
      # caller has to render a friendly message for.
      raise ProcessingError::ServiceUnavailable, e.message
    end
  end
end
