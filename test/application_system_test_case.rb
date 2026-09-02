require "test_helper"

# System tests are not part of bin/ci — they need a real browser — but they are
# the only way to check what the spec actually asks for: sizes and colours as
# the browser computes them, not as the stylesheet declares them.
# .github/workflows/ci.yml runs them separately.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
end
