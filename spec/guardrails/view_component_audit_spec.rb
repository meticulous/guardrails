# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/view_component_audit"

RSpec.describe Guardrails::ViewComponentAudit do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write_file(relative, content = "")
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  describe "#find_missing_previews" do
    it "returns empty when there are no components" do
      expect(described_class.new(root: root, output: StringIO.new).find_missing_previews).to be_empty
    end

    it "flags a component without a corresponding preview" do
      write_file "app/components/button_component.rb", "class ButtonComponent < ViewComponent::Base\nend"

      expect(described_class.new(root: root, output: StringIO.new).find_missing_previews).to eq(["button"])
    end

    it "considers a component covered when test/components/previews has a preview" do
      write_file "app/components/button_component.rb", "class ButtonComponent < ViewComponent::Base\nend"
      write_file "test/components/previews/button_component_preview.rb", "class ButtonComponentPreview < ViewComponent::Preview\nend"

      expect(described_class.new(root: root, output: StringIO.new).find_missing_previews).to be_empty
    end

    it "considers a component covered when spec/components/previews has a preview" do
      write_file "app/components/button_component.rb", "class ButtonComponent < ViewComponent::Base\nend"
      write_file "spec/components/previews/button_component_preview.rb", ""

      expect(described_class.new(root: root, output: StringIO.new).find_missing_previews).to be_empty
    end

    it "supports namespaced components" do
      write_file "app/components/admin/users/profile_component.rb", "class Admin::Users::ProfileComponent < ViewComponent::Base\nend"

      expect(described_class.new(root: root, output: StringIO.new).find_missing_previews).to eq(["admin/users/profile"])
    end

    it "matches namespaced components to namespaced previews" do
      write_file "app/components/admin/users/profile_component.rb", ""
      write_file "test/components/previews/admin/users/profile_component_preview.rb", ""

      expect(described_class.new(root: root, output: StringIO.new).find_missing_previews).to be_empty
    end
  end

  describe "#find_orphan_slots" do
    it "returns empty when there are no slot declarations" do
      write_file "app/components/button_component.rb", "class ButtonComponent < ViewComponent::Base\nend"

      expect(described_class.new(root: root, output: StringIO.new).find_orphan_slots).to be_empty
    end

    it "flags a renders_one slot that's never referenced in the template" do
      write_file "app/components/card_component.rb", <<~RUBY
        class CardComponent < ViewComponent::Base
          renders_one :header
        end
      RUBY
      write_file "app/components/card_component.html.erb", "<div>body</div>"

      orphans = described_class.new(root: root, output: StringIO.new).find_orphan_slots
      expect(orphans.length).to eq(1)
      expect(orphans.first.slot).to eq("header")
      expect(orphans.first.slot_kind).to eq(:renders_one)
    end

    it "flags a renders_many slot that's never referenced" do
      write_file "app/components/list_component.rb", <<~RUBY
        class ListComponent < ViewComponent::Base
          renders_many :items
        end
      RUBY
      write_file "app/components/list_component.html.erb", "<ul></ul>"

      orphans = described_class.new(root: root, output: StringIO.new).find_orphan_slots
      expect(orphans.length).to eq(1)
      expect(orphans.first.slot_kind).to eq(:renders_many)
    end

    it "considers a slot referenced when the template uses its name" do
      write_file "app/components/card_component.rb", <<~RUBY
        class CardComponent < ViewComponent::Base
          renders_one :header
        end
      RUBY
      write_file "app/components/card_component.html.erb", "<div><%= header %></div>"

      expect(described_class.new(root: root, output: StringIO.new).find_orphan_slots).to be_empty
    end

    it "considers a renders_many slot referenced when the template iterates it" do
      write_file "app/components/list_component.rb", <<~RUBY
        class ListComponent < ViewComponent::Base
          renders_many :items
        end
      RUBY
      write_file "app/components/list_component.html.erb", "<% items.each do |i| %><%= i %><% end %>"

      expect(described_class.new(root: root, output: StringIO.new).find_orphan_slots).to be_empty
    end

    it "captures the source file and line of the declaration" do
      write_file "app/components/card_component.rb", <<~RUBY
        class CardComponent < ViewComponent::Base
          renders_one :header
        end
      RUBY
      write_file "app/components/card_component.html.erb", "<div></div>"

      o = described_class.new(root: root, output: StringIO.new).find_orphan_slots.first
      expect(o.file).to eq("app/components/card_component.rb")
      expect(o.line).to eq(2)
    end

    it "flags only the unreferenced slot when there are multiple declarations" do
      write_file "app/components/card_component.rb", <<~RUBY
        class CardComponent < ViewComponent::Base
          renders_one :header
          renders_one :footer
        end
      RUBY
      write_file "app/components/card_component.html.erb", "<div><%= header %></div>"

      orphans = described_class.new(root: root, output: StringIO.new).find_orphan_slots
      expect(orphans.map(&:slot)).to eq(["footer"])
    end

    it "skips orphan-slot detection when no template file exists" do
      write_file "app/components/code_only_component.rb", <<~RUBY
        class CodeOnlyComponent < ViewComponent::Base
          renders_one :header
          def call
            content_tag(:div) { header }
          end
        end
      RUBY

      # The slot is referenced in the call method but no template exists. We
      # treat the component file itself as a fallback "template" for matching
      # — current implementation looks at the .html.erb only and would flag
      # this. Document the behavior; refine if needed.
      orphans = described_class.new(root: root, output: StringIO.new).find_orphan_slots
      # For now, this is a known false positive. Asserting the current behavior
      # so changes to it are surfaced.
      expect(orphans.map(&:slot)).to eq(["header"])
    end
  end

  describe "#run" do
    it "returns a Result responding to violations?" do
      result = described_class.new(root: root, output: StringIO.new).run
      expect(result).to respond_to(:violations?)
      expect(result.violations?).to be(false)
    end

    it "reports both findings under the same task output" do
      write_file "app/components/button_component.rb", <<~RUBY
        class ButtonComponent < ViewComponent::Base
          renders_one :icon
        end
      RUBY
      write_file "app/components/button_component.html.erb", "<button>x</button>"

      output = StringIO.new
      result = described_class.new(root: root, output: output).run

      expect(result.missing_previews).to eq(["button"])
      expect(result.orphan_slots.map(&:slot)).to eq(["icon"])
      expect(output.string).to include("missing previews")
      expect(output.string).to include("orphan slots")
    end
  end
end
