require "application_system_test_case"

# AC 14. The integration tests assert the stylesheet declares the right tokens;
# only a browser can confirm what those tokens actually compute to once the
# cascade, the reset and Tailwind's own base styles have had their say.
class PlanScreenTest < ApplicationSystemTestCase
  setup { Rails.cache.clear }

  test "body copy computes to at least 18px and key figures to at least 24px" do
    visit_plan

    body_px = computed_px("dt")
    assert_operator body_px, :>=, 18.0, "row labels compute to #{body_px}px"

    fact_px = computed_px("dd.text-fact")
    assert_operator fact_px, :>=, 24.0, "copay and deductible figures compute to #{fact_px}px"
  end

  test "no visible text anywhere on the plan screen falls below 18px" do
    visit_plan

    too_small = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('main *'))
        .filter(el => el.children.length === 0 && el.textContent.trim().length > 0)
        .map(el => ({ text: el.textContent.trim().slice(0, 40),
                      size: parseFloat(getComputedStyle(el).fontSize) }))
        .filter(el => el.size < 18)
    JS

    assert_empty too_small, "these fall below 18px: #{too_small.inspect}"
  end

  test "the page does not scroll sideways at a narrow width" do
    Capybara.page.driver.browser.manage.window.resize_to(360, 900)
    visit_plan

    overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    assert_operator overflow, :<=, 0, "the page overflows horizontally by #{overflow}px"
  end

  test "the landing screen is usable at 200 percent zoom" do
    Capybara.page.driver.browser.manage.window.resize_to(640, 900)
    visit root_path
    page.evaluate_script("document.body.style.zoom = '2'")

    assert_selector "input[type=file]"
    overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    assert_operator overflow, :<=, 0, "zoomed layout overflows by #{overflow}px"
  end

  private
    def computed_px(selector)
      page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('#{selector}')).fontSize)")
    end

    def visit_plan
      # The wait belongs inside the stub: click_on returns as soon as the click
      # is dispatched, so restoring the transport outside the block races the
      # server thread that is still handling the POST.
      stub_gemini(gemini_analysis) do
        visit root_path
        attach_file "document", Rails.root.join("test/fixtures/files/insurance_sample.pdf")
        click_on "Read my document"
        assert_selector "h1", text: "Your plan"
      end
    end
end
