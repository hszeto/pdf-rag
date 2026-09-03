require "test_helper"
require "rake"

# demo:clear once deleted every document in the database, not just the seeded
# ones, and took a real upload with it. The scoping is the whole point of the
# task, so it is tested rather than trusted.
class DemoTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["demo:clear"].reenable
  end

  test "clearing removes seeded documents" do
    seeded = Document.create!(status: "ready", title: "seed.pdf", content_hash: "demo-seed")

    capture_io { Rake::Task["demo:clear"].invoke }

    assert_not Document.exists?(seeded.id)
  end

  test "clearing leaves a real upload alone" do
    real = Document.create!(status: "ready", title: "real.pdf",
                            content_hash: Digest::SHA256.hexdigest("real"))

    capture_io { Rake::Task["demo:clear"].invoke }

    assert Document.exists?(real.id), "a document that was not seeded must survive"
  end

  test "clearing leaves a document with no content hash alone" do
    pending = Document.create!(status: "pending", title: "just-uploaded.pdf")

    capture_io { Rake::Task["demo:clear"].invoke }

    assert Document.exists?(pending.id), "a document still being ingested must survive"
  end
end
