require "application_system_test_case"

# Nothing else in the suite looks at a rendered screen. These check the things
# only a browser can answer: that text is large enough to read, that the page
# does not scroll sideways, and that the processing screen gets out of the way.
class DocumentScreensTest < ApplicationSystemTestCase
  test "the upload screen is readable and says how long documents are kept" do
    visit root_path

    assert_selector "h1", text: "Understand any PDF document"
    # Still built from the constant, not a literal: changing Document::RETENTION
    # has to change the page, or the promise and the behaviour drift apart (R3).
    assert_text(/deleted after #{Document::RETENTION.inspect}/i)
    # visible: :all because the enhanced field's input is transparent by design —
    # opacity-0 is what preserves the browser's own `required` check, and
    # Capybara counts that as invisible. It is still present and still the thing
    # that opens the picker; the pill around it is what the reader sees.
    assert_selector "input[type=file]", visible: :all
    assert page.has_selector?("[data-enhanced]"), "the field should be enhanced into a pill"

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

  # D1: minutes, never seconds. A second-by-second counter reads as pressure,
  # and the note is here to be honest about the limit, not to hurry anyone.
  test "the retention note counts down in minutes and shows no clock time" do
    visit document_path(ready_document)

    assert_text(/in \d+ minutes?/)
    assert_no_text(/\d{1,2}:\d{2}\s*(AM|PM)/i)

    # The number pulses on its own; the words around it hold still.
    assert_selector ".retention-pulse", text: /\A\d+\z/
    assert_no_selector ".retention-pulse", text: /minute/
  end

  # D6 and R4.2: when the window closes the document leaves the screen without a
  # request. The replacement arrived with the page, so this holds even if the
  # server has gone to sleep in the meantime.
  test "the document is replaced in place when the countdown runs out" do
    document = ready_document
    # Long enough that a slow runner cannot expire it mid-load — at which point
    # the server would redirect instead, and the swap would never be reached.
    document.update!(expires_at: 15.seconds.from_now)

    visit document_path(document)
    assert_selector "h2", text: "Ask about this document"

    assert_selector "h1", text: "This document has been removed", wait: 30
    assert_no_selector "h2", text: "Ask about this document"
  end

  # The strongest available proof that nothing navigated: a value set on `window`
  # survives only if this document was never torn down and rebuilt.
  test "asking a question appends the answer without reloading the page" do
    document = ready_document
    document.chunks.update_all(embedding: Array.new(GeminiClient::EMBEDDING_DIMENSIONS) { 0.01 })

    stub_gemini(gemini_embeddings(1), gemini_answer(text: "Appended, not reloaded.", used: [ 1 ])) do
      visit document_path(document)
      page.execute_script("window.__notReloaded = true")

      fill_in "question", with: "Does this reload?"
      click_on "Ask"
      assert_text "Appended, not reloaded.", wait: 10

      assert page.evaluate_script("window.__notReloaded === true"),
        "the page navigated — the answer should have been appended in place"
      assert_equal "", find("#ask-form input[name=question]").value,
        "the field should come back empty"
    end
  end

  # The bug this guards: a #fragment redirect cannot survive Turbo's fetch, so
  # the reader was dumped at the top of a long page after every question. Only a
  # browser can see this — the redirect header looked correct the whole time.
  test "asking a question leaves the reader at the new answer, not the top" do
    # ready_document's chunks carry no embedding, so retrieval would find
    # nothing and the question would be refused before an answer exists.
    document = ready_document
    document.chunks.update_all(embedding: Array.new(GeminiClient::EMBEDDING_DIMENSIONS) { 0.01 })
    6.times do |i|
      document.messages.create!(role: "user", content: "Older question #{i}? " * 8)
      document.messages.create!(role: "assistant", content: "Older answer #{i}. " * 25)
    end

    stub_gemini(gemini_embeddings(1), gemini_answer(text: "The newest answer. " * 20, used: [ 1 ])) do
      visit document_path(document)
      fill_in "question", with: "My newest question?"
      click_on "Ask"

      assert_text "The newest answer.", wait: 10

      # scrollIntoView animates, so poll until it settles rather than sampling
      # the instant the text appears.
      offset = 0
      40.times do
        offset = page.evaluate_script("window.scrollY")
        break if offset > 0
        sleep 0.15
      end

      assert_operator offset, :>, 0, "the reader was left at the top of the page"
    end
  end

  # D3: the native control is replaced, so the field has to say what was chosen
  # itself. attach_file needs make_visible because the real input is transparent.
  test "choosing a file shows its name in the field" do
    visit root_path

    assert_text "Choose a PDF"

    attach_file "document", file_fixture("restaurant_menu.pdf"), make_visible: true

    assert_text "restaurant_menu.pdf"
    assert_no_text "Choose a PDF"
  end

  # D1 and R1.2: inside the field's bounds, not below it, and clear of the name.
  test "the upload button sits inside the field" do
    visit root_path

    inside = page.evaluate_script(<<~JS)
      (() => {
        const pill = document.querySelector('[data-enhanced]')
        const button = pill.querySelector('input[type=submit]')
        const p = pill.getBoundingClientRect(), b = button.getBoundingClientRect()
        return b.top >= p.top && b.bottom <= p.bottom && b.right <= p.right
      })()
    JS
    assert inside, "the Submit button should render within the field's bounds"
  end

  # R2.3: opacity hides the input's own ring, so the pill has to draw one.
  test "the upload field shows a focus ring when the input has focus" do
    visit root_path

    page.execute_script("document.querySelector('input[type=file]').focus()")
    width = page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector('[data-enhanced]')).outlineWidth
    JS

    assert_equal "3px", width, "the pill should carry the focus ring"
  end

  # The existing overflow test below visits a document, so the upload screen —
  # the one this feature restructured — was never covered.
  test "the upload screen does not scroll sideways on a narrow screen" do
    Capybara.page.driver.browser.manage.window.resize_to(360, 900)
    visit root_path

    overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    assert_operator overflow, :<=, 0, "the upload screen overflows horizontally by #{overflow}px"
  end

  # R5: three across is only right when there is room for it.
  test "the steps stack into one column on a phone and spread on a laptop" do
    Capybara.page.driver.browser.manage.window.resize_to(360, 900)
    visit root_path
    assert_equal 1, distinct_step_columns

    Capybara.page.driver.browser.manage.window.resize_to(1024, 900)
    visit root_path
    assert_equal 3, distinct_step_columns
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
    # The spinner is motion-safe, so what "correct" means depends on the
    # browser. Asserting it always spins fails on any machine that asks for
    # reduced motion — which many CI browsers do — and, worse, would keep
    # passing if the motion-safe guard were removed. Both halves are checked.
    reduced = page.evaluate_script("window.matchMedia('(prefers-reduced-motion: reduce)').matches")
    animation = page.evaluate_script("getComputedStyle(document.querySelector('[data-controller=processing] span')).animationName")

    if reduced
      assert_equal "none", animation, "reduced motion should hold the spinner still"
    else
      assert_equal "spin", animation
    end

    document.update!(status: "ready", summary: "It is ready now.")

    # The polling should notice without anyone touching the browser.
    assert_selector "h2", text: "What this document is", wait: 15
  end

  private
    # Counting distinct left edges rather than reading the grid property: it is
    # the laid-out result that matters, and a one-column grid and a stacked flex
    # column look identical to a reader.
    def distinct_step_columns
      page.evaluate_script(<<~JS)
        new Set(
          Array.from(document.querySelectorAll('#how-heading + ol > li'))
            .map(li => Math.round(li.getBoundingClientRect().left))
        ).size
      JS
    end

    def ready_document(links: [])
      Document.create!(
        status: "ready", title: "A Policy Document", links: links,
        summary: "It explains what the plan covers.\nIt lists what you pay."
      ).tap do |document|
        3.times { |i| document.chunks.create!(content: "passage #{i}", position: i, page: i + 1) }
      end
    end
end
