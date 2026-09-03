ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

Dir[Rails.root.join("test/support/**/*.rb")].sort.each { |f| require f }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    include ActiveJob::TestHelper
    include GeminiStubbing

    # No test may reach the live API. Without this a forgotten stub would make a
    # real billed call, and on the free tier would send document text to a
    # third party from CI (D8).
    setup do
      GeminiClient.transport_factory = -> {
        raise "GeminiClient was called without a stub. Wrap the call in stub_gemini."
      }

      # The client checks for a key before it reaches the transport, so without
      # this every call fails as "no api key configured" wherever the credentials
      # do not decrypt — which is every CI runner. Nothing is ever sent: the
      # transport above refuses, and stub_gemini replaces it with a fake.
      GeminiClient.api_key_source = -> { "test-key-never-sent" }
    end

    # Add more helper methods to be used by all tests here...
  end
end
