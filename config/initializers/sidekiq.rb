# Sidekiq client (web process) and server (worker process) share the same
# Redis instance. Local dev defaults to localhost; production reads REDIS_URL.

redis_config = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }

Sidekiq.configure_server do |config|
  config.redis = redis_config
end

Sidekiq.configure_client do |config|
  config.redis = redis_config
end
