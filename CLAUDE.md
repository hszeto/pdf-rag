# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

Rails 8.1 app (`InsuranceHelper`), Ruby 4.0.6, generated but not yet built out: no commits on `main`, no models, no routes beyond `/up`, no root route. Everything under `app/` is still generator default except that `pdf-reader` has been added to the Gemfile — PDF parsing is the intended feature direction.

## Commands

```bash
bin/setup              # install deps, clear logs/tmp, then exec bin/dev
bin/setup --skip-server
bin/dev                # foreman: `bin/rails server` + `bin/rails tailwindcss:watch` (PORT env, default 3000)

bin/ci                 # full pipeline: setup, rubocop, bundler-audit, importmap audit, brakeman, tests
bin/rubocop            # rubocop-rails-omakase style
bin/brakeman --quiet --no-pager
bin/bundler-audit
bin/importmap audit

bin/rails test                                    # all non-system tests
bin/rails test test/models/foo_test.rb            # one file
bin/rails test test/models/foo_test.rb:42         # one test by line
bin/rails test:system                             # Capybara + Selenium (not in bin/ci; is in GitHub CI)
```

Tests run in parallel with `:number_of_processors` workers (`test/test_helper.rb`) — anything sharing global state across tests needs care.

## Architecture notes

- **No database.** `active_record/railtie`, Active Storage, Action Mailbox, and Action Text are all commented out in `config/application.rb`, and no DB adapter gem is in the Gemfile. Anything touching persistence requires re-enabling the railtie and adding an adapter first; until then, use Active Model (`active_model/railtie` is on) for form/value objects.
- **Asset pipeline:** Propshaft + importmap-rails (no bundler/node). Add JS deps via `bin/importmap pin`, not npm. Stimulus controllers in `app/javascript/controllers/` are auto-registered by `pin_all_from`.
- **CSS:** tailwindcss-rails compiles `app/assets/tailwind/application.css` → `app/assets/builds/tailwind.css` (a build artifact). `bin/dev` watches it; otherwise `bin/rails tailwindcss:build`.
- **`ApplicationController`** sets `allow_browser versions: :modern` — legacy browsers get a 406, which can surprise in tests or manual checks.
- **`config.autoload_lib(ignore: %w[assets tasks])`** — `lib/` is autoloaded and eager-loaded; new `lib/` code must follow Zeitwerk naming.
- **Deploy:** Kamal (`config/deploy.yml`) is still at placeholder values (`192.168.0.1`, `localhost:5555` registry) — not deployable as configured.
