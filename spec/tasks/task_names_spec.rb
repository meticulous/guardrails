# frozen_string_literal: true

require "rake"

RSpec.describe "rake task names" do
  around do |example|
    original = Rake.application
    Rake.application = Rake::Application.new
    example.run
  ensure
    Rake.application = original
  end

  let(:tasks_dir) { File.expand_path("../../lib/tasks", __dir__) }

  def load_tasks(*files)
    files.each { |file| load File.join(tasks_dir, file) }
  end

  def task_names
    Rake::Task.tasks.map(&:name)
  end

  it "defines every task under ui_guardrails:" do
    load_tasks("ui_guardrails.rake")

    expect(task_names).to include("ui_guardrails:audit", "ui_guardrails:init", "ui_guardrails:hooks:install",
                                  "ui_guardrails:a11y:deep", "ui_guardrails:feed_ramp:manifest",
                                  "ui_guardrails:feed_ramp:rules", "ui_guardrails:feed_ramp:score",
                                  "ui_guardrails:feed_ramp:mcp", "ui_guardrails:feed_ramp:mcp:install",
                                  "ui_guardrails:feed_ramp:modern_web:install")
    expect(task_names.grep(/\Aguardrails:/)).to be_empty
  end

  it "keeps a guardrails: alias for each task, as the Railtie loads them" do
    load_tasks("ui_guardrails.rake", "guardrails.rake")

    new_names = task_names.grep(/\Aui_guardrails:/)
    expect(task_names.grep(/\Aguardrails:/)).to match_array(new_names.map { |name| name.delete_prefix("ui_") })
  end

  it "loads the real tasks when the alias file is the only one given (1.x sidecar command)" do
    load_tasks("guardrails.rake")

    expect(task_names).to include("ui_guardrails:audit", "guardrails:audit")
  end

  it "leaves aliases out of rake -T" do
    # Rake records `desc` only when listing tasks, as `rake -T` does.
    allow(Rake::TaskManager).to receive(:record_task_metadata).and_return(true)
    load_tasks("guardrails.rake")

    expect(Rake::Task["guardrails:audit"].comment).to be_nil
    expect(Rake::Task["ui_guardrails:audit"].comment).not_to be_nil
  end

  it "warns on stderr and runs the new task" do
    load_tasks("guardrails.rake")
    ran = false
    Rake::Task["ui_guardrails:tokens"].clear_actions
    Rake::Task["ui_guardrails:tokens"].enhance { ran = true }

    expect { Rake::Task["guardrails:tokens"].invoke }
      .to output(/`guardrails:tokens` is deprecated .* use `ui_guardrails:tokens`/).to_stderr
      .and output("").to_stdout
    expect(ran).to be true
  end
end
