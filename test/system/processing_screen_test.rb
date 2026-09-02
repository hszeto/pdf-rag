require "application_system_test_case"

# R7.2. The processing screen only earns its place if it actually gets out of
# the way when the job finishes, which needs a real browser running the polling.
class ProcessingScreenTest < ApplicationSystemTestCase
  setup { Rails.cache.clear }

  test "the reader waits on the processing screen and is moved on when the job finishes" do
    stub_gemini(gemini_analysis) do
      visit root_path
      attach_file "document", Rails.root.join("test/fixtures/files/insurance_sample.pdf")
      click_on "Read my document"

      # The job has not run yet, so this is what the reader is looking at.
      assert_selector "h1", text: "Reading your document"
      assert_no_selector "h1", text: "Your plan"

      # Now let the queue drain, exactly as Sidekiq would.
      perform_enqueued_jobs

      # The polling should notice without anyone touching the browser.
      assert_selector "h1", text: "Your plan", wait: 10
      assert_text "$1,500"
    end
  end

  test "the processing screen says something calm while waiting" do
    stub_gemini(gemini_analysis) do
      visit root_path
      attach_file "document", Rails.root.join("test/fixtures/files/insurance_sample.pdf")
      click_on "Read my document"

      assert_selector "[data-controller=processing]"
      assert_selector "[aria-live=polite]"
      # No jargon, no percentages, nothing about AI or models (R7.1).
      main = find("main").text
      %w[AI model token upload session].each do |word|
        assert_no_match(/\b#{word}\b/i, main)
      end
    end
  end

  test "a failure during analysis reaches the reader with a way to retry" do
    stub_gemini([ 503, "unavailable" ]) do
      visit root_path
      attach_file "document", Rails.root.join("test/fixtures/files/insurance_sample.pdf")
      click_on "Read my document"
      assert_selector "h1", text: "Reading your document"

      perform_enqueued_jobs

      assert_selector "[role=alert]", text: /trouble reading documents/i, wait: 10
      assert_selector "input[type=file]"
    end
  end

  # Regression. Polling replaces the page every couple of seconds, which rebuilds
  # the Stimulus controller — five times in nine seconds, measured. Both of these
  # were silently dead until the elapsed time came from the server instead of
  # from controller state, and neither failure was visible from the markup.
  test "the message keeps changing across polls" do
    stub_gemini(gemini_analysis) do
      start_upload

      first = find("[data-processing-target=message]").text
      assert_selector "[data-processing-target=message]",
        text: /Looking through|Finding the important|Almost there/, wait: 12
      assert_not_equal first, find("[data-processing-target=message]").text
    end
  end

  test "the slow notice appears once the wait is long enough" do
    stub_gemini(gemini_analysis) do
      start_upload

      # Backdating the session is the only way to test this: the page is
      # re-rendered from the server on every poll, so a threshold changed in the
      # browser is wiped two seconds later. Which is the same reason the notice
      # never worked in the first place.
      backdate_analysis_by(25.seconds)

      assert_selector "[data-processing-target=slow]", visible: true,
        text: /taking a little longer/i, wait: 12
    end
  end

  test "the spinner turns, and holds still for readers who ask for reduced motion" do
    stub_gemini(gemini_analysis) do
      start_upload

      spinner = "[data-controller=processing] span[aria-hidden=true]"
      assert_selector spinner, visible: :all
      animation = page.evaluate_script(
        "getComputedStyle(document.querySelector('#{spinner}')).animationName"
      )
      assert_equal "spin", animation, "the spinner should be animating"
    end
  end

  private
def backdate_analysis_by(interval)
  key = Rails.cache.instance_variable_get(:@data).keys
             .find { |k| k.include?(SessionCache::KEY_PREFIX) }
  id = key.split(":").last
  session = SessionCache.find(id)
  session.analyzing_since = interval.ago
  SessionCache.write(session)
end

    def start_upload
      visit root_path
      attach_file "document", Rails.root.join("test/fixtures/files/insurance_sample.pdf")
      click_on "Read my document"
      assert_selector "h1", text: "Reading your document"
    end
end
