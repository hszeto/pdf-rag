# Plan: Dynamic Footer

## Confirmed Decisions
- None raised

## Approach
- Create a footer partial (`_footer.html.erb`) using Rails' `Date.current.year` for the dynamic year
- Render the footer in the main application layout, positioned after the main content
- Use Tailwind classes to style it consistently with the app (centered, muted text, appropriate spacing)
- The footer spans full width but respects the same max-width container as header and main content
- Add a system test to verify footer appears and displays the correct year

## Files Touched
- `app/views/shared/_footer.html.erb` — new footer partial with copyright text and dynamic year
- `app/views/layouts/application.html.erb` — render footer before closing `</body>` tag
- `test/system/document_screens_test.rb` — add test verifying footer displays on page

## Checkpoints
- [x] 1. Create footer partial with copyright text, dynamic year, and Tailwind styling → verify: footer renders in browser with correct year
- [x] 2. Add footer to application layout → verify: footer appears at bottom of home and document pages
- [x] 3. Add system test asserting footer text displays → verify: test passes

## Test Plan
- Verify footer displays on the home page (upload screen)
- Verify footer displays on a document detail page (with questions/answers)
- Assert footer contains "©" symbol and current year

## Risks / Rollback
- None identified; footer is a pure addition with no impact on existing functionality
- Rollback: remove footer render from layout and delete the partial
