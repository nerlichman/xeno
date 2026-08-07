namespace :xeno do
  desc "Print the resolved agent: config, instructions, tools, diagnostics"
  task info: :environment do
    require "xeno/info"
    puts Xeno::Info.render
  end

  desc "Sweep turns with no live owner back into the queue (see Xeno::Reaper)"
  task reap: :environment do
    rescued = Xeno::Reaper.sweep!
    puts "reaper: re-enqueued #{rescued.size} turn(s)#{" (ids: #{rescued.map(&:id).join(', ')})" if rescued.any?}"
  end

  namespace :schedules do
    desc "Compile agent/schedules/*.md into Solid Queue recurring.yml entries"
    task sync: :environment do
      require "xeno/schedules"
      result = Xeno::Schedules.sync!
      managed = result.values.flat_map(&:keys).select { |k| k.start_with?(Xeno::Schedules::MANAGED_PREFIX) }.uniq
      puts "recurring.yml synced — managed entries: #{managed.sort.join(', ')} " \
           "(environments: #{result.keys.join(', ')})"
    end
  end
end
