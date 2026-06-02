require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on Amazon S3 in production. Render's filesystem
  # is ephemeral (wiped on every deploy), so local Disk is not an option.
  # Credentials come from env vars — see config/storage.yml.
  config.active_storage.service = :amazon

  # Render terminates SSL at its load balancer, so the Rails app sees
  # plain HTTP internally. assume_ssl makes Rails generate https:// URLs
  # and treat cookies as secure; force_ssl redirects any non-TLS request.
  config.assume_ssl = true
  config.force_ssl = true

  # Skip http-to-https redirect for Render's health checks (they hit /up
  # over HTTP directly against the container before LB routing kicks in).
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Use in-process memory cache. solid_cache would need its own DB table
  # (we collapsed to a single DB for the free Render plan), and we don't
  # have heavy cache demands for this app — Rails fragment/SQL caches
  # are fine in-process per dyno.
  config.cache_store = :memory_store

  # Active Job: queue_adapter is read from ENV["ACTIVE_JOB_ADAPTER"] in
  # config/application.rb. In this deploy (Render free, no background
  # workers available) we run with :async — jobs execute in a thread of
  # the Puma web process. Trade-off: jobs lose persistence across Puma
  # restarts, and we don't get Sidekiq Web UI / retries / rate limiting.
  # For the demo workload (a reviewer creating 1-2 orders) that's fine.

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
