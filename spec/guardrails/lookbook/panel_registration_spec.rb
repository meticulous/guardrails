# frozen_string_literal: true

require "guardrails/lookbook/panel_registration"

RSpec.describe Guardrails::Lookbook::PanelRegistration do
  # Captures `Lookbook.add_panel(name, partial, opts)` invocations.
  # That's the Lookbook 2.x module-level API (Engine.panels.add_panel
  # underneath); previous releases tried the config-level chain
  # `config.lookbook.preview_inspector.panels.add`, which doesn't
  # exist — caught while wiring the bootable demo in 0.7.0.
  lookbook_double = Class.new do
    attr_reader :registered

    def initialize
      @registered = nil
    end

    def add_panel(name, partial_path, opts)
      @registered = { name: name, partial_path: partial_path, opts: opts }
    end
  end

  let(:lookbook) { lookbook_double.new }

  describe ".register_panel" do
    it "calls Lookbook.add_panel with name :guardrails, the bundled partial path, and label/locals opts" do
      described_class.register_panel(lookbook)

      reg = lookbook.registered
      expect(reg).not_to be_nil
      expect(reg[:name]).to eq(:guardrails)
      expect(reg[:partial_path]).to eq("lookbook_panels/guardrails")
      expect(reg[:opts][:label]).to eq("Guardrails")
      expect(reg[:opts][:locals]).to be_a(Proc)
    end

    it "is a no-op when the lookbook target doesn't respond to add_panel" do
      bare = Object.new
      expect { described_class.register_panel(bare) }.not_to raise_error
    end
  end

  describe "locals lambda" do
    let(:preview_class) { double("PreviewClass", name: "ButtonComponentPreview") }
    let(:preview) { double("Preview", preview_class_name: "ButtonComponentPreview") }
    let(:data) { double("PanelData", preview: preview) }

    before { described_class.register_panel(lookbook) }

    it "strips the Preview suffix and runs ComponentReport against the component class" do
      fake_report = instance_double(Guardrails::Lookbook::ComponentReport)
      allow(Guardrails::Lookbook::ComponentReport).to receive(:new).and_return(fake_report)
      allow(fake_report).to receive(:for).with("ButtonComponent")
                                         .and_return(component: "ButtonComponent", violations: [])
      stub_const("Rails", double("Rails", root: Pathname("/fake/root")))

      result = lookbook.registered[:opts][:locals].call(data)
      expect(result[:findings]).to include(component: "ButtonComponent")
    end

    it "yields nil findings when the preview data is unusable" do
      result = lookbook.registered[:opts][:locals].call(nil)
      expect(result[:findings]).to be_nil
    end

    it "falls back to data.preview.preview_class.name when 2.x accessor missing" do
      legacy_preview = double("LegacyPreview", preview_class: preview_class)
      allow(legacy_preview).to receive(:respond_to?).with(:preview_class_name).and_return(false)
      allow(legacy_preview).to receive(:respond_to?).with(:preview_class).and_return(true)
      legacy_data = double("LegacyData", preview: legacy_preview)

      fake_report = instance_double(Guardrails::Lookbook::ComponentReport)
      allow(Guardrails::Lookbook::ComponentReport).to receive(:new).and_return(fake_report)
      allow(fake_report).to receive(:for).with("ButtonComponent").and_return(component: "ButtonComponent")
      stub_const("Rails", double("Rails", root: Pathname("/fake/root")))

      result = lookbook.registered[:opts][:locals].call(legacy_data)
      expect(result[:findings][:component]).to eq("ButtonComponent")
    end

    it "yields nil findings when the preview class has no Preview suffix" do
      flat_preview = double("FlatPreview", preview_class_name: "RandomClass")
      flat_data = double("FlatData", preview: flat_preview)

      result = lookbook.registered[:opts][:locals].call(flat_data)
      expect(result[:findings]).to be_nil
    end
  end

  describe ".append_view_path" do
    it "appends the gem's view directory on the provided consumer" do
      consumer = Class.new do
        attr_reader :appended

        def append_view_path(path)
          @appended = path
        end
      end.new

      described_class.append_view_path(consumer)

      expect(consumer.appended).to eq(described_class::VIEW_PATH)
      expect(consumer.appended).to end_with("/lookbook/views")
    end

    # Append (not prepend) keeps host `app/views/lookbook_panels/_guardrails.html.erb`
    # ahead of the gem's bundled default. This is the contract the
    # README and CHANGELOG advertise; lock it in.
    it "appends rather than prepends so host views keep precedence" do
      consumer = Class.new do
        attr_reader :appended

        def append_view_path(path)
          @appended = path
        end

        def prepend_view_path(_path)
          raise "host overrides break if we prepend"
        end
      end.new

      expect { described_class.append_view_path(consumer) }.not_to raise_error
      expect(consumer.appended).to eq(described_class::VIEW_PATH)
    end

    it "is a no-op when no consumer is available" do
      expect { described_class.append_view_path(nil) }.not_to raise_error
    end
  end

  describe ".register!" do
    it "calls both append_view_path and register_panel" do
      consumer = Class.new { def self.append_view_path(_); end }
      described_class.register!(lookbook: lookbook, view_consumer: consumer)

      expect(lookbook.registered[:name]).to eq(:guardrails)
    end
  end
end
