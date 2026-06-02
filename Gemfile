source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Database-backed Action Cable adapter (used in development only; production
# uses the redis adapter — see cable.yml). solid_cache was removed: both
# environments use :memory_store. Keeping solid_cache around with our
# single-DB production setup made it auto-connect to a non-existent
# `cache` DB at boot and crash Puma startup.
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

# S3 service backend for Active Storage in production. `require: false`
# keeps the gem out of dev boot (we use the local Disk service there);
# storage.yml's amazon entry loads it lazily on first use.
gem "aws-sdk-s3", require: false

# Redis client for ActionCable's `:redis` adapter in production. Sidekiq
# already uses Redis (via redis-client), so reusing the same Redis instance
# for Action Cable broadcasts keeps the infra simple — one Redis service
# powers both background jobs AND real-time Turbo Stream updates.
gem "redis", "~> 5.0"

# === Controlcar challenge ===

# OpenAI client — used for both chat completions (GPT-5) and embeddings
gem "ruby-openai"

# PDF text extraction for the knowledge ingest pipeline
gem "pdf-reader"

# pgvector adapter for ActiveRecord — semantic search on KnowledgeChunk
gem "neighbor"

# Background jobs (replaces the default solid_queue)
gem "sidekiq"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # RSpec — test framework. Proyecto creado con --skip-test, así que esto
  # es la primera test stack (no hay Minitest preexistente).
  gem "rspec-rails", "~> 7.1"
end

group :test do
  # Bloquea HTTP real en tests. Crítico: varios services llaman OpenAI
  # (translator, embedder, agent) — sin webmock cada `rspec` quemaría
  # tokens reales.
  gem "webmock", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

gem "figaro", "~> 1.3"
