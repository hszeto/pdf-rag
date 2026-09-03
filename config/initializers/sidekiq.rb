# Sidekiq shares the Redis this app already needs, on its own database so job
# state never collides with the session cache (DB 0) or Action Cable (DB 1).
SIDEKIQ_REDIS_URL = ENV.fetch("SIDEKIQ_REDIS_URL") do
  ENV.fetch("REDIS_URL", "redis://localhost:6379").sub(%r{/\d+\z}, "") + "/2"
end

Sidekiq.configure_server do |config|
  config.redis = { url: SIDEKIQ_REDIS_URL }
end

Sidekiq.configure_client do |config|
  config.redis = { url: SIDEKIQ_REDIS_URL }
end
