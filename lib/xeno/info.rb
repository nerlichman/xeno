# frozen_string_literal: true

module Xeno
  # Renders the resolved agent for `rake xeno:info` — the discovery
  # diagnostics surface.
  module Info
    module_function

    def render(definition = Xeno.definition)
      lines = []
      lines << "Agent: #{definition.name}"
      lines << "Root:  #{definition.root}"
      lines << "Model: #{definition.config.resolved_model}#{format_options(definition.config.model_options)}"
      lines << ""

      dynamic_suffix = definition.dynamic_instructions? ? " + dynamic (instructions.rb, resolved per turn)" : ""
      if definition.instructions
        preview = definition.instructions.strip.lines.first&.strip
        lines << "Instructions: instructions.md (#{definition.instructions.bytesize} bytes)#{dynamic_suffix} — #{preview}"
      elsif definition.dynamic_instructions?
        lines << "Instructions: dynamic only (instructions.rb, resolved per turn)"
      else
        lines << "Instructions: MISSING"
      end

      lines << ""
      lines << "Tools (#{definition.tools.size}):"
      if definition.tools.any?
        width = definition.tools.keys.map(&:length).max
        definition.tools.each do |tool_name, klass|
          lines << "  #{tool_name.ljust(width)}  #{klass.name}  — #{klass.description || '(no description)'}"
        end
      else
        lines << "  (none — add agent/tools/*.rb)"
      end

      if definition.schedules.any?
        lines << ""
        lines << "Schedules (#{definition.schedules.size}):"
        width = definition.schedules.keys.map(&:length).max
        definition.schedules.each do |schedule_name, schedule|
          lines << "  #{schedule_name.ljust(width)}  #{schedule.cron}  — #{schedule.prompt.lines.first&.strip}"
        end
      end

      if definition.channels.any?
        lines << ""
        lines << "Channels (#{definition.channels.size} + http built-in):"
        definition.channels.each_key do |channel_name|
          lines << "  #{channel_name}"
        end
      end

      if definition.respond_to?(:hooks) && definition.hooks.any?
        lines << ""
        lines << "Hooks (observe-only, at-least-once):"
        definition.hooks.each do |event_type, handlers|
          lines << "  #{event_type}  — #{handlers.size} handler#{'s' if handlers.size > 1}"
        end
      end

      if definition.diagnostics.any?
        lines << ""
        lines << "Diagnostics:"
        definition.diagnostics.each do |diag|
          lines << "  [#{diag.level.upcase}] #{diag.message}"
        end
      end

      lines.join("\n")
    end

    def format_options(options)
      options.empty? ? "" : " #{options.inspect}"
    end
  end
end
