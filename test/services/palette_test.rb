require "test_helper"

# AC 14, contrast half. The palette lives in app/assets/tailwind/application.css;
# these read the real declarations rather than a copy, so a colour changed there
# and not here fails the suite instead of silently dropping below AA.
class PaletteTest < ActiveSupport::TestCase
  THEME_FILE = Rails.root.join("app/assets/tailwind/application.css")

  # WCAG 2.1: 4.5:1 for body text, 3:1 for large text and non-text UI.
  PAIRS = [
    [ "body text on paper",       :ink,        :paper,     4.5 ],
    [ "muted text on paper",      :"ink-muted", :paper,    4.5 ],
    [ "accent on paper",          :accent,     :paper,     4.5 ],
    [ "button label on accent",   :"accent-ink", :accent,  4.5 ],
    [ "notice text on notice bg", :"notice-ink", :"notice-bg", 4.5 ],
    [ "alert text on alert bg",   :"alert-ink", :"alert-bg",   4.5 ],
    [ "rule on paper",            :rule,       :paper,     3.0 ]
  ].freeze

  PAIRS.each do |label, fg, bg, minimum|
    test "#{label} meets #{minimum}:1" do
      actual = contrast(palette.fetch(fg), palette.fetch(bg))

      assert_operator actual, :>=, minimum,
        "#{label} is #{actual}:1 (#{palette.fetch(fg)} on #{palette.fetch(bg)}), below the #{minimum}:1 minimum"
    end
  end

  test "body copy is at least 18px" do
    assert_operator rem_size("--text-body"), :>=, 1.125,
      "body copy must be at least 18px for this audience"
  end

  test "key figures are at least 24px" do
    assert_operator rem_size("--text-fact"), :>=, 1.5,
      "copays and the deductible must be at least 24px"
  end

  private
    def css = @css ||= File.read(THEME_FILE)

    def palette
      @palette ||= css.scan(/--color-([a-z-]+):\s*(#[0-9A-Fa-f]{6})/)
                      .to_h { |name, hex| [ name.to_sym, hex ] }
    end

    def rem_size(token)
      css[/#{Regexp.escape(token)}:\s*([0-9.]+)rem/, 1].to_f
    end

    def luminance(hex)
      channels = hex.delete("#").scan(/../).map { |c| c.to_i(16) / 255.0 }
      r, g, b = channels.map { |c| c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
      (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    end

    def contrast(a, b)
      high, low = [ luminance(a), luminance(b) ].minmax.reverse
      (((high + 0.05) / (low + 0.05)) * 100).floor / 100.0
    end
end
