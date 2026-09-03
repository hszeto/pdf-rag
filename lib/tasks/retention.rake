namespace :retention do
  desc "Remove documents whose hour has passed (belt and braces for lost delete jobs)"
  task sweep: :environment do
    before = Document.expired.count
    SweepExpiredDocumentsJob.perform_now
    puts "swept #{before} expired document(s)"
  end
end
