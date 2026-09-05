require "test_helper"

class HealthEndpointTest < ActionDispatch::IntegrationTest
  # AC2: the criterion is that nothing is named, so the test checks the shape
  # rather than a string someone eyeballed once.
  test "the body is a run of numbers and names none of them" do
    get usage_health_path

    assert_response :success
    assert_match(/\A\{"status":"ok( \d+(\.\d+)?)+"\}\z/, response.body)
    assert_no_match(/upload|visitor|refusal|byte|size|count/i, response.body)
  end

  test "the figures are the ones recorded" do
    UsageEvent.record_upload(byte_size: 2.megabytes, address: "203.0.113.1")
    UsageEvent.record_upload(byte_size: 4.megabytes, address: "203.0.113.2")
    UsageEvent.record_refusal(address: "203.0.113.3")

    get usage_health_path

    # uploads, visitors, refusals, average MB, maximum MB
    assert_equal "ok 2 3 1 3.0 4.0", JSON.parse(response.body)["status"]
  end

  test "it answers before anything has happened" do
    get usage_health_path

    assert_equal "ok 0 0 0 0.0 0.0", JSON.parse(response.body)["status"]
  end

  # The point of the endpoint is being read from a terminal, so the things that
  # read it are exactly the things ApplicationController's browser guard was
  # never written for.
  test "answers a request with no User-Agent at all" do
    get usage_health_path, headers: { "HTTP_USER_AGENT" => nil }

    assert_response :success
  end

  test "answers curl" do
    get usage_health_path, headers: { "HTTP_USER_AGENT" => "curl/8.7.1" }

    assert_response :success
  end

  # This is the assertion that earns the ActionController::Base inheritance: the
  # same User-Agent that gets a 406 on a page gets the figures here. An uptime
  # monitor claiming to be an old browser must not be turned away.
  test "answers a browser the rest of the app refuses" do
    old_safari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " \
                 "(KHTML, like Gecko) Version/15.0 Safari/605.1.15"

    get root_path, headers: { "HTTP_USER_AGENT" => old_safari }
    assert_response :not_acceptable, "the guard should still refuse old browsers on pages"

    get usage_health_path, headers: { "HTTP_USER_AGENT" => old_safari }
    assert_response :success
  end

  # /up is Rails' own, and Render polls it as the service health check.
  test "the platform health check is untouched" do
    get rails_health_check_path

    assert_response :success
    assert_no_match(/\d+ \d+ \d+/, response.body)
  end
end
