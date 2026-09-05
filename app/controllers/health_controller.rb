# Usage, as a run of numbers that means nothing without the key (D1).
#
# Inherits from ActionController::Base rather than ApplicationController, which
# is what Rails' own health controller does and for the same reason: this is read
# by terminals and uptime monitors, not browsers, and it should not inherit the
# request handling meant for people.
#
# Concretely that avoids `allow_browser versions: :modern`, whose callback is an
# anonymous lambda and therefore cannot be skipped by name. A monitor sending an
# old browser's User-Agent would get a 406 page instead of the figures.
#
# Separate from /up, which Rails owns and Render polls as its health check — that
# one must keep answering exactly as Render expects.
class HealthController < ActionController::Base
  def show
    render json: { status: "ok #{figures}" }
  end

  private
    # Position is the key: uploads, visitors, refusals, average MB, maximum MB.
    #
    # Worth being clear about what that protects against. Someone who opens the
    # URL learns nothing. Someone who reads this repository learns everything —
    # the order is here, in the tests, and in ai/feature-specs/usage-metrics.md.
    # The figures are counts, so that is an accepted trade rather than a hole.
    #
    # Cached briefly because the endpoint is public and unauthenticated. The
    # queries are counts over a small table, but there is no reason to run them
    # once per request for something that changes this slowly.
    def figures
      Rails.cache.fetch("usage_events/summary", expires_in: 60.seconds) do
        summary = UsageEvent.summary

        summary.values_at(:uploads, :visitors, :refusals, :average_mb, :maximum_mb).join(" ")
      end
    end
end
