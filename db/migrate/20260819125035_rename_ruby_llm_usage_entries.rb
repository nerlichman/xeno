class RenameRubyLlmUsageEntries < ActiveRecord::Migration[8.1]
  OLD_TABLE = :ruby_llm_usage_entries
  NEW_TABLE = :ruby_llm_usages

  # Baked, not read from RubyLLM::Usage::Entry::OPERATIONS: a migration has to
  # describe the schema at the moment it ran, whatever the constant grows into.
  RECORDED_OPERATIONS = %w[chat embedding moderation image speech transcription ocr rerank].freeze

  def up
    rename_usage_table
    widen_operation_constraint
  end

  # The wider constraint stays behind: it rejects nothing the narrower one
  # allowed, and narrowing it again would fail on any entry already recorded
  # under an operation the old list never knew about.
  def down
    return unless table_exists?(NEW_TABLE)

    rename_table NEW_TABLE, OLD_TABLE
  end

  private

  def rename_usage_table
    return unless table_exists?(OLD_TABLE)

    if table_exists?(NEW_TABLE)
      raise "Both #{OLD_TABLE} and #{NEW_TABLE} exist. Merge or remove one before running this migration."
    end

    rename_table OLD_TABLE, NEW_TABLE
  end

  # Found by the column it constrains rather than by its expression, so the name
  # Rails derived for it — under whichever table name it was added — never has to
  # be guessed. Runs whether or not the rename above did anything.
  def widen_operation_constraint
    connection.check_constraints(NEW_TABLE).each do |constraint|
      next unless constraint.expression.include?("operation")

      remove_check_constraint NEW_TABLE, constraint.expression, name: constraint.name
    end

    operations = RECORDED_OPERATIONS.map { |operation| connection.quote(operation) }.join(', ')
    add_check_constraint NEW_TABLE, "operation IN (#{operations})"
  end
end
