require "test_helper"

# The suite had no test that the front page renders at all, which is how a view
# referring to a removed route reached a 500 with everything green.
class HomePageTest < ActionDispatch::IntegrationTest
  test "the front page renders" do
    get root_path

    assert_response :success
    assert_select "h1"
  end

  test "the health check answers" do
    get rails_health_check_path

    assert_response :success
  end
end
