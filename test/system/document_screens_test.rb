require "application_system_test_case"

# Nothing else in the suite looks at a rendered screen. These check the things
# only a browser can answer: that text is large enough to read, that the page
# does not scroll sideways, and that the processing screen gets out of the way.
class DocumentScreensTest < ApplicationSystemTestCase
  test "the upload screen is readable and says how long documents are kept" do
    visit root_path

    assert_selector "h1", text: "Understand any document"
    assert_text(/#{Document::RETENTION.inspect} after you add it/i)
    assert_selector "input[type=file]"

    too_small = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('main *'))
        .filter(el => el.children.length === 0 && el.textContent.trim().length > 0)
        .map(el => ({ text: el.textContent.trim().slice(0, 30),
                      size: parseFloat(getComputedStyle(el).fontSize) }))
        .filter(el => el.size < 18)
    JS
    assert_empty too_small, "these fall below 18px: #{too_small.inspect}"
  end

  test "a ready document shows its summary and a way to ask" do
    document = ready_document
    visit document_path(document)

    assert_selector "h2", text: "What this document is"
    assert_text "It explains what the plan covers."
    assert_selector "h2", text: "Ask about this document"
    assert_selector "input[name=question]"
  end

  test "an answer shows where in the document it came from" do
    document = ready_document
    document.messages.create!(role: "user", content: "What is the deductible?")
    document.messages.create!(role: "assistant", content: "It is $1,500.", citations: [ "page 4" ])

    visit document_path(document)

    assert_text "What is the deductible?"
    assert_text "It is $1,500."
    assert_text(/From page 4 of your document/)
  end

  test "the links found in a document are shown as text, not as links" do
    document = ready_document(links: [ "http://example.gov/", "mailto:a@b.com" ])
    visit document_path(document)

    assert_text "http://example.gov/"
    assert_no_selector "a[href='http://example.gov/']"
  end

  test "the page does not scroll sideways on a narrow screen" do
    Capybara.page.driver.browser.manage.window.resize_to(360, 900)
    visit document_path(ready_document)

    overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    assert_operator overflow, :<=, 0, "the page overflows horizontally by #{overflow}px"
  end

  test "the processing screen spins, and gets out of the way when the document is ready" do
    document = Document.create!(status: "embedding", title: "doc.pdf")
    visit document_path(document)

    assert_selector "h2", text: "Reading your document"
    animation = page.evaluate_script("getComputedStyle(document.querySelector('[data-controller=processing] span')).animationName")
    assert_equal "spin", animation

    document.update!(status: "ready", summary: "It is ready now.")

    # The polling should notice without anyone touching the browser.
    assert_selector "h2", text: "What this document is", wait: 15
  end

  private
    def ready_document(links: [])
      Document.create!(
        status: "ready", title: "A Policy Document", links: links,
        summary: "It explains what the plan covers.\nIt lists what you pay."
      ).tap do |document|
        3.times { |i| document.chunks.create!(content: "passage #{i}", position: i, page: i + 1) }
      end
    end
end
