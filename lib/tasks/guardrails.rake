# frozen_string_literal: true

# The pre-2.0 task names. Every task is `ui_guardrails:*` since 2.0, after
# the gem's name; `guardrails:<task>` still runs `ui_guardrails:<task>`,
# with a notice on stderr (stdout may be FORMAT=json), until 3.0.
#
# Loads the real tasks itself, so the sidecar command from 1.x
# (`rake -f lib/tasks/guardrails.rake guardrails:audit`) keeps working.
load File.expand_path("ui_guardrails.rake", __dir__) unless Rake::Task.task_defined?("ui_guardrails:audit")

Rake::Task.tasks.map(&:name).grep(/\Aui_guardrails:/).each do |name|
  old_name = name.delete_prefix("ui_")
  next if Rake::Task.task_defined?(old_name)

  # No `desc`, so `rake -T` lists only the new names.
  task old_name do
    warn "`#{old_name}` is deprecated and will be removed in ui_guardrails 3.0; use `#{name}`."
    Rake::Task[name].invoke
  end
end
