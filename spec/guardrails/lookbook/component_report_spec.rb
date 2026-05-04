# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "guardrails/lookbook/component_report"

RSpec.describe Guardrails::Lookbook::ComponentReport do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write_file(relative, content = "")
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  describe "#for" do
    it "returns nil when the component class file does not exist" do
      expect(described_class.new(root: root).for("MissingComponent")).to be_nil
    end

    it "resolves a top-level component class to its source files" do
      write_file "app/components/button_component.rb", "class ButtonComponent < ViewComponent::Base\nend"
      write_file "app/components/button_component.html.erb", "<button>x</button>"

      report = described_class.new(root: root).for("ButtonComponent")

      expect(report[:component]).to eq("ButtonComponent")
      expect(report[:class_file]).to eq("app/components/button_component.rb")
      expect(report[:template_file]).to eq("app/components/button_component.html.erb")
    end

    it "resolves a namespaced component class" do
      write_file "app/components/admin/users/profile_component.rb", ""
      write_file "app/components/admin/users/profile_component.html.erb", ""

      report = described_class.new(root: root).for("Admin::Users::ProfileComponent")

      expect(report[:class_file]).to eq("app/components/admin/users/profile_component.rb")
    end

    it "leaves template_file nil when the component has no sidecar" do
      write_file "app/components/code_only_component.rb", "class CodeOnlyComponent < ViewComponent::Base\n  def call; end\nend"

      report = described_class.new(root: root).for("CodeOnlyComponent")

      expect(report[:template_file]).to be_nil
    end

    it "includes view violations from the component's template" do
      write_file "app/components/icon_component.rb", "class IconComponent < ViewComponent::Base\nend"
      write_file "app/components/icon_component.html.erb", '<svg fill="#0066ff"></svg>'

      report = described_class.new(root: root).for("IconComponent")

      expect(report[:violations].length).to eq(1)
      expect(report[:violations].first[:type]).to eq(:raw_color)
    end

    it "scopes violations to the requested component's template" do
      write_file "app/components/icon_component.rb", ""
      write_file "app/components/icon_component.html.erb", '<svg fill="#0066ff"></svg>'
      write_file "app/components/other_component.rb", ""
      write_file "app/components/other_component.html.erb", '<svg fill="#fa3"></svg>'

      report = described_class.new(root: root).for("IconComponent")

      expect(report[:violations].length).to eq(1)
      expect(report[:violations].first[:file]).to eq("app/components/icon_component.html.erb")
    end

    it "includes orphan slots from the component class" do
      write_file "app/components/card_component.rb", <<~RUBY
        class CardComponent < ViewComponent::Base
          renders_one :unused_header
        end
      RUBY
      write_file "app/components/card_component.html.erb", "<div></div>"

      report = described_class.new(root: root).for("CardComponent")

      expect(report[:orphan_slots].length).to eq(1)
      expect(report[:orphan_slots].first[:slot]).to eq("unused_header")
    end

    it "includes similar templates" do
      structure = "<article><h1>X</h1><p>1</p><p>2</p><p>3</p></article>"
      write_file "app/components/user_card_component.rb", ""
      write_file "app/components/user_card_component.html.erb", structure
      write_file "app/components/admin_card_component.rb", ""
      write_file "app/components/admin_card_component.html.erb", structure

      report = described_class.new(root: root).for("UserCardComponent")

      expect(report[:similar_templates].length).to eq(1)
      expect(report[:similar_templates].first[:partner]).to eq("app/components/admin_card_component.html.erb")
      expect(report[:similar_templates].first[:score]).to eq(1.0)
    end
  end
end
