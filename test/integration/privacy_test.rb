require "test_helper"

# AC 17 and 19. Two promises that are easy to break silently: that a reader's
# content never reaches a log, and that the suite cannot touch the network.
class PrivacyTest < ActionDispatch::IntegrationTest
  # Tested through the filter Rails actually applies rather than by scraping log
  # output, which depends on which subscriber happens to be attached.
  setup { @filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  test "an uploaded document is redacted from logged parameters" do
    filtered = @filter.filter("document" => "PAGEMARKER001 confidential contents")

    assert_equal "[FILTERED]", filtered["document"]
  end

  test "a question is redacted from logged parameters" do
    filtered = @filter.filter("question" => "what is my member id 12345")

    assert_equal "[FILTERED]", filtered["question"]
  end

  test "the things the app was always filtering are still filtered" do
    filtered = @filter.filter("password" => "hunter2", "authenticity_token" => "abc")

    assert_equal "[FILTERED]", filtered["password"]
    assert_equal "[FILTERED]", filtered["authenticity_token"]
  end

  # The upstream diagnostics are deliberately logged; they must carry the quota
  # and status without carrying the prompt, which holds document text.
  test "an upstream failure logs its cause but not the document" do
    log = capture_log do
      client = GeminiClient.new(transport: FakeGeminiTransport.new([ 429, "{}" ]), api_key: "k")
      client.embed([ "PAGEMARKER001 confidential contents" ]) rescue nil
    end

    assert_match(/\[gemini\] request failed status=429/, log)
    assert_no_match(/PAGEMARKER001/, log)
    assert_no_match(/confidential contents/, log)
  end

  test "an API key never reaches the log" do
    log = capture_log do
      client = GeminiClient.new(transport: FakeGeminiTransport.new([ 500, "{}" ]), api_key: "AIzaSecretKeyValue")
      client.embed([ "x" ]) rescue nil
    end

    assert_no_match(/AIzaSecretKeyValue/, log)
  end

  # AC 19: a forgotten stub must fail loudly rather than quietly making a real,
  # billed call with someone's document in it.
  test "the suite refuses to reach the live API" do
    error = assert_raises(RuntimeError) { GeminiClient.new(api_key: "k").embed([ "x" ]) }

    assert_match(/without a stub/i, error.message)
  end

  test "nothing needs a real API key to run" do
    assert_nothing_raised do
      stub_gemini(gemini_embeddings(1)) do
        GeminiClient.new(api_key: "not-a-real-key").embed([ "x" ])
      end
    end
  end

  private
    def capture_log
      io = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
      io.string
    ensure
      Rails.logger = original
    end
end
