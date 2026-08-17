# frozen_string_literal: true

module Xeno
  # The resolved agent: everything discovered under the app's agent/ directory, plus diagnostics for
  # anything misplaced or broken. Discovery never raises — a broken agent directory yields a
  # definition whose diagnostics say exactly what is wrong (surfaced by `rake xeno:info`).
  class AgentDefinition
    SLOT_DIRS = %w[tools skills channels schedules hooks lib].freeze
    TOOL_SLUG = /\A[a-z][a-z0-9_]*\z/

    Diagnostic = Struct.new(:level, :message) do
      def error? = level == :error
    end

    Schedule = Struct.new(:name, :cron, :prompt, keyword_init: true)

    # What agent/instructions.rb's block receives.
    InstructionContext = Struct.new(:session, :principal, keyword_init: true)

    attr_reader :root, :name, :config, :instructions, :dynamic_instructions,
                :tools, :schedules, :channels, :hooks, :diagnostics

    # Builds the definition for the app's agent root. `resolver` maps a tool file's camelized
    # basename to its constant; the default asks Zeitwerk (via const_get on Xeno::Tools) and is only
    # overridden in tests.
    def self.load(root, name:, resolver: nil)
      new(root: root, name: name, resolver: resolver).tap(&:discover)
    end

    def initialize(root:, name:, resolver: nil)
      @root = Pathname(root)
      @name = name
      @resolver = resolver || method(:resolve_tool_constant)
      @config = AgentConfig.new
      @instructions = nil
      @dynamic_instructions = nil
      @tools = {}
      @schedules = {}
      @channels = {}
      @hooks = {}
      @diagnostics = []
    end

    def discover
      unless root.directory?
        error "no agent/ directory at #{root} — run `rails g xeno:install`"
        return self
      end

      load_agent_config
      load_instructions
      discover_tools
      discover_schedules
      discover_channels
      discover_hooks
      report_misplaced_files
      self
    end

    def tool_classes
      tools.values
    end

    def dynamic_instructions? = !@dynamic_instructions.nil?

    # The system prompt for one turn: static markdown first, then the dynamic block's return,
    # resolved fresh at every turn stage with the session context. A raising block never bricks the
    # session — the turn proceeds on the static instructions and the failure is logged.
    def instructions_for(session: nil)
      parts = [ instructions ]
      if @dynamic_instructions
        context = InstructionContext.new(session: session, principal: session&.principal)
        begin
          parts << @dynamic_instructions.call(context).to_s
        rescue StandardError => e
          Rails.logger.warn(
            "xeno: agent/instructions.rb raised #{e.class}: #{e.message} — using static instructions only"
          )
        end
      end
      combined = parts.compact.map(&:strip).reject(&:empty?).join("\n\n")
      combined.empty? ? nil : combined
    end

    def errors? = diagnostics.any?(&:error?)

    private

    def load_agent_config
      file = root.join("agent.rb")
      return unless file.file?

      Xeno.capture_agent_config { load file.to_s }
      captured = Xeno.captured_agent_config
      if captured
        @config = captured
      else
        warn_diag "agent.rb loaded but never called Xeno.agent — using defaults"
      end
    rescue StandardError, SyntaxError => e
      error "agent.rb failed to load: #{e.class}: #{e.message}"
    end

    def load_instructions
      file = root.join("instructions.md")
      if file.file?
        @instructions = file.read
        error "instructions.md is empty" if @instructions.strip.empty?
      end

      load_dynamic_instructions

      if @instructions.nil? && @dynamic_instructions.nil?
        error "instructions are missing (instructions.md and/or instructions.rb — the agent's always-on system prompt)"
      end
    end

    # agent/instructions.rb — `Xeno.instructions do |context| ... end`, resolved at turn-stage time
    # (context: session, principal) and appended to the static markdown.
    def load_dynamic_instructions
      file = root.join("instructions.rb")
      return unless file.file?

      Xeno.capture_instructions { load file.to_s }
      captured = Xeno.captured_instructions
      if captured
        @dynamic_instructions = captured
      else
        warn_diag "instructions.rb loaded but never called Xeno.instructions — ignored"
      end
    rescue StandardError, SyntaxError => e
      error "instructions.rb failed to load: #{e.class}: #{e.message}"
    end

    def discover_tools
      dir = root.join("tools")
      return unless dir.directory?

      dir.glob("*.rb").sort.each do |file|
        slug = file.basename(".rb").to_s

        unless slug.match?(TOOL_SLUG)
          error "tools/#{file.basename}: invalid tool name #{slug.inspect} (want snake_case: get_weather.rb)"
          next
        end

        klass = begin
          @resolver.call(slug)
        rescue NameError => e
          error "tools/#{file.basename}: expected it to define Xeno::Tools::#{slug.camelize} (#{e.message})"
          next
        end

        # Xeno::Tool required, not just RubyLLM::Tool: a plain RubyLLM subclass leaks a namespaced
        # wire name (`xeno--tools--foo`) that misses the slug-keyed lookup, and it has no approval
        # API — the gate would silently fail open.
        unless klass.is_a?(Class) && klass < Xeno::Tool
          error "tools/#{file.basename}: Xeno::Tools::#{slug.camelize} must subclass Xeno::Tool " \
                "(naming and the approval gate depend on it)"
          next
        end

        tools[slug] = klass
      end
    end

    def resolve_tool_constant(slug)
      Xeno::Tools.const_get(slug.camelize)
    end

    # agent/schedules/*.md — YAML frontmatter with a cron: line, body is the task prompt. Compiled
    # to Solid Queue recurring entries by `rake xeno:schedules:sync`; never fired on cadence in
    # development.
    def discover_schedules
      dir = root.join("schedules")
      return unless dir.directory?

      dir.glob("*.md").sort.each do |file|
        slug = file.basename(".md").to_s

        unless slug.match?(TOOL_SLUG)
          error "schedules/#{file.basename}: invalid schedule name #{slug.inspect} (want snake_case)"
          next
        end

        frontmatter, prompt = parse_frontmatter(file.read)
        cron = frontmatter["cron"].presence

        unless cron
          error "schedules/#{file.basename}: missing `cron:` in the frontmatter"
          next
        end
        if prompt.blank?
          error "schedules/#{file.basename}: no prompt body after the frontmatter"
          next
        end

        schedules[slug] = Schedule.new(name: slug, cron: cron, prompt: prompt)
      end
    end

    # agent/channels/*.rb — DSL files (`Xeno.channel :slack do ... end`). Loading registers the
    # channel globally; the definition records what each file declared for diagnostics and
    # xeno:info.
    def discover_channels
      dir = root.join("channels")
      return unless dir.directory?

      dir.glob("*.rb").sort.each do |file|
        slug = file.basename(".rb").to_s

        channel = begin
          load file.to_s
          Xeno::Channels.registry[slug.to_sym]
        rescue StandardError, SyntaxError => e
          error "channels/#{file.basename}: failed to load: #{e.class}: #{e.message}"
          next
        end

        if channel
          channels[slug] = channel
        else
          error "channels/#{file.basename}: expected it to call Xeno.channel :#{slug}"
        end
      end
    end

    # agent/hooks/*.rb — observe-only handlers (`Xeno.hook "type" do … end`). One file may declare
    # several; they merge across files. Handlers for unknown event types get a warning (typos never
    # fire).
    def discover_hooks
      dir = root.join("hooks")
      return unless dir.directory?

      dir.glob("*.rb").sort.each do |file|
        captured = begin
          Xeno.capture_hooks { load file.to_s }
        rescue StandardError, SyntaxError => e
          error "hooks/#{file.basename}: failed to load: #{e.class}: #{e.message}"
          next
        end

        if captured.empty?
          warn_diag "hooks/#{file.basename}: loaded but never called Xeno.hook — ignored"
          next
        end

        captured.each do |event_type, handlers|
          unless event_type == "*" || Event::TYPES.include?(event_type)
            warn_diag "hooks/#{file.basename}: #{event_type.inspect} is not in the event vocabulary (typo?) — it will never fire"
          end
          (hooks[event_type] ||= []).concat(handlers)
        end
      end
    end

    def parse_frontmatter(content)
      if content =~ /\A---\s*\n(.*?)\n---\s*\n?(.*)\z/m
        [ YAML.safe_load(Regexp.last_match(1)) || {}, Regexp.last_match(2).strip ]
      else
        [ {}, content.strip ]
      end
    rescue Psych::SyntaxError
      [ {}, content.strip ]
    end

    def report_misplaced_files
      root.glob("*.rb").each do |file|
        next if %w[agent.rb instructions.rb].include?(file.basename.to_s)

        warn_diag "#{file.basename}: ruby files at the agent root are not loaded — did you mean tools/#{file.basename}?"
      end

      root.children.select(&:directory?).each do |dir|
        slot = dir.basename.to_s
        warn_diag "#{slot}/: not a known slot (#{SLOT_DIRS.join(', ')})" unless SLOT_DIRS.include?(slot)
      end
    end

    def error(message) = diagnostics << Diagnostic.new(:error, message)
    def warn_diag(message) = diagnostics << Diagnostic.new(:warning, message)
  end
end
