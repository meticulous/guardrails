# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/stimulus_audit"

RSpec.describe Guardrails::StimulusAudit do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write_file(relative, content = "")
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  def run_audit
    described_class.new(root: root, output: StringIO.new).run
  end

  describe "#run" do
    it "returns empty results when there are no controllers and no views" do
      result = run_audit

      expect(result.orphaned).to be_empty
      expect(result.dead).to be_empty
    end

    it "marks a defined-but-unreferenced controller as dead" do
      write_file "app/javascript/controllers/foo_controller.js"

      expect(run_audit.dead).to eq(["foo"])
    end

    it "marks a referenced-but-undefined controller as orphaned" do
      write_file "app/views/x.html.erb", '<div data-controller="missing">x</div>'

      expect(run_audit.orphaned).to eq(["missing"])
    end

    it "considers a controller healthy when defined and referenced" do
      write_file "app/javascript/controllers/foo_controller.js"
      write_file "app/views/x.html.erb", '<div data-controller="foo">x</div>'

      result = run_audit
      expect(result.dead).to be_empty
      expect(result.orphaned).to be_empty
    end

    it "splits multiple controllers in one data-controller attribute" do
      write_file "app/javascript/controllers/a_controller.js"
      write_file "app/javascript/controllers/b_controller.js"
      write_file "app/views/x.html.erb", '<div data-controller="a b">x</div>'

      result = run_audit
      expect(result.dead).to be_empty
      expect(result.orphaned).to be_empty
    end

    it "converts underscores in filenames to dashes for matching" do
      write_file "app/javascript/controllers/nav_bar_controller.js"
      write_file "app/views/x.html.erb", '<div data-controller="nav-bar">x</div>'

      result = run_audit
      expect(result.dead).to be_empty
    end

    it "uses double-dash separator for namespaced (nested) controllers" do
      write_file "app/javascript/controllers/users/profile_controller.js"
      write_file "app/views/x.html.erb", '<div data-controller="users--profile">x</div>'

      result = run_audit
      expect(result.dead).to be_empty
    end

    it "finds controllers under app/javascript/js/controllers/ (Avo layout)" do
      write_file "app/javascript/js/controllers/foo_controller.js"
      write_file "app/views/x.html.erb", '<div data-controller="foo">x</div>'

      result = run_audit
      expect(result.dead).to be_empty
      expect(result.orphaned).to be_empty
    end

    it "finds controllers under app/javascript/packs/controllers/ (older Webpacker)" do
      write_file "app/javascript/packs/controllers/bar_controller.js"
      write_file "app/views/x.html.erb", '<div data-controller="bar">x</div>'

      result = run_audit
      expect(result.dead).to be_empty
    end

    it "finds controllers under app/frontend/controllers/ (Vite Rails)" do
      write_file "app/frontend/controllers/baz_controller.ts"
      write_file "app/views/x.html.erb", '<div data-controller="baz">x</div>'

      result = run_audit
      expect(result.dead).to be_empty
    end

    it "anchors namespacing on the deepest controllers/ segment" do
      # Avo-style: app/javascript/js/controllers/admin/users_controller.js
      # should map to "admin--users", NOT "js--admin--users"
      write_file "app/javascript/js/controllers/admin/users_controller.js"
      write_file "app/views/x.html.erb", '<div data-controller="admin--users">x</div>'

      result = run_audit
      expect(result.dead).to be_empty
      expect(result.orphaned).to be_empty
    end

    it "scans both app/views and app/components" do
      write_file "app/javascript/controllers/foo_controller.js"
      write_file "app/components/x.html.erb", '<div data-controller="foo">x</div>'

      expect(run_audit.dead).to be_empty
    end

    it "supports .ts controllers as well as .js" do
      write_file "app/javascript/controllers/foo_controller.ts"
      write_file "app/views/x.html.erb", '<div data-controller="foo">x</div>'

      expect(run_audit.dead).to be_empty
    end

    it "detects Ruby helper syntax: tag.div(data: { controller: 'foo' })" do
      write_file "app/javascript/controllers/foo_controller.js"
      write_file "app/views/x.html.erb", "<%= tag.div(data: { controller: 'foo' }) %>"

      expect(run_audit.dead).to be_empty
    end

    it "detects Ruby helper syntax: link_to with data: { controller: }" do
      write_file "app/javascript/controllers/nav_controller.js"
      write_file "app/views/x.html.erb", '<%= link_to "x", "#", data: { controller: "nav" } %>'

      expect(run_audit.dead).to be_empty
    end

    it "splits multiple controllers in Ruby helper syntax" do
      write_file "app/javascript/controllers/a_controller.js"
      write_file "app/javascript/controllers/b_controller.js"
      write_file "app/views/x.html.erb", '<%= tag.div(data: { controller: "a b" }) %>'

      result = run_audit
      expect(result.dead).to be_empty
      expect(result.orphaned).to be_empty
    end

    it "detects hash-rocket syntax: data: { :controller => 'foo' }" do
      write_file "app/javascript/controllers/foo_controller.js"
      write_file "app/views/x.html.erb", '<%= tag.div(data: { :controller => "foo" }) %>'

      expect(run_audit.dead).to be_empty
    end

    it "returns an object that responds to violations?" do
      result = run_audit

      expect(result).to respond_to(:violations?)
      expect(result.violations?).to be(false)
    end
  end
end
