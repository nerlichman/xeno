# H2: `attempts` is the failure ladder (transient errors, crash reclaims) —
# approval/question resumes are human-driven and unbounded, counted apart so
# a much-approved turn can never trip the poison branch.
class AddResumesToXenoTurns < ActiveRecord::Migration[8.1]
  def change
    add_column :xeno_turns, :resumes, :integer, null: false, default: 0
  end
end
