# frozen_string_literal: true

module Xeno
  module Standalone
    module_function

    # First boot only (the registry table is empty): pull the live model
    # catalog from the configured providers so current model ids resolve
    # without a manual RubyLLM.models.refresh!. Loading the definition first
    # runs agent.rb's RubyLLM.configure — the refresh needs those provider
    # keys. Never fatal, never repeated once the table has rows; skippable
    # with XENO_SKIP_MODEL_REFRESH=1 (deterministic scripts, offline boots).
    def refresh_models!
      return if ENV["XENO_SKIP_MODEL_REFRESH"]

      Xeno.definition
      store = RubyLLM.config.model_registry_store
      return unless store.respond_to?(:none?) && store.none?

      Rails.logger.info "xeno: first boot — refreshing the model registry"
      RubyLLM.models.refresh!
      Rails.logger.info "xeno: model registry ready (#{store.count} models)"
    rescue StandardError => error
      Rails.logger.warn "xeno: model registry refresh failed (#{error.class}: #{error.message}). " \
                        "Continuing; run RubyLLM.models.refresh! manually if a model fails to resolve."
    end
  end
end
