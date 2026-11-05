require_relative "boot"

require "rails"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module Middleware
  class Application < Rails::Application
    config.load_defaults 8.0
    config.api_only = true

    config.eager_load = ENV.fetch("RAILS_ENV", "development") == "production"
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "bench-not-a-secret")

    # Sem log por request (a versão Go também não loga) para não medir I/O de log
    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "warn")

    # Middlewares de Rack que não fazem sentido atrás do Kong
    config.middleware.delete ActionDispatch::HostAuthorization
    config.hosts.clear
  end
end
