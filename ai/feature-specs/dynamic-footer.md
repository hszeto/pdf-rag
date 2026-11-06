# Feature Spec: Dynamic Footer

## Summary
Add a footer to every page displaying "© [current year]". The year updates automatically without code changes when the calendar year changes.

## Requirements
- Footer appears at the bottom of every page (in the main application layout)
- Displays copyright symbol and current year (e.g., "© 2026")
- Year is calculated dynamically at page render time, not hardcoded
- Styled consistently with the app's design system (Tailwind + existing spacing/typography)
- Footer is centered and uses muted text color to stay visually secondary to main content

## Non-Goals
- Organization name or legal text beyond copyright symbol and year
- Links in the footer
- Multiple copyright holders or versioning info

## Edge Cases
- None anticipated; year calculation is straightforward

## Acceptance Criteria
- Footer renders on the home page (document upload)
- Footer renders on document detail pages (questions/answers)
- Copyright year matches `Date.current.year`
- Footer styling is consistent with the app's existing color palette and typography
- Year updates without code changes when the calendar rolls over to a new year
