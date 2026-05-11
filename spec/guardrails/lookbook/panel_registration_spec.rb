# frozen_string_literal: true

require "guardrails/lookbook/panel_registration"

RSpec.describe Guardrails::Lookbook::PanelRegistration do
  # Lookbook's panel block exposes label / partial / locals as plain
  # accessors, so a Struct stands in cleanly. The same shape is used
  # both inside the capture class below and in `falls back…` further
  # down — defined once at the top so both reuse it.
  panel_struct = Struct.new(:label, :partial, :locals)

  # Captures `panels.add(:guardrails) { |panel| ... }` invocations.
  panels_capture = Class.new do
    define_method(:initialize) { @registered = {} }
    attr_reader :registered

    define_method(:add) do |name, &block|
      panel = panel_struct.new
      block.call(panel)
      @registered[name] = panel
    end
  end

  let(:panels) { panels_capture.new }
  let(:inspector) { Struct.new(:panels).new(panels) }
  let(:lookbook_config) { Struct.new(:preview_inspector).new(inspector) }
  let(:rails_config) { Struct.new(:lookbook).new(lookbook_config) }

  describe ".register_panel" do
    it "adds a :guardrails panel with label, partial, and locals lambda" do
      described_class.register_panel(rails_config)

      panel = panels.registered[:guardrails]
      expect(panel).not_to be_nil
      expect(panel.label).to eq("Guardrails")
      expect(panel.partial).to eq("lookbook_panels/guardrails")
      expect(panel.locals).to be_a(Proc)
    end

    it "is a no-op when config does not expose .lookbook (Lookbook gem missing)" do
      bare_config = Struct.new(:other).new("nope")
      expect { described_class.register_panel(bare_config) }.not_to raise_error
      expect(panels.registered).to be_empty
    end
  end

  describe "locals lambda" do
    let(:preview_class) { double("PreviewClass", name: "ButtonComponent") }
    let(:preview) { double("Preview", preview_class: preview_class) }
    let(:data) { double("PanelData", preview: preview) }

    before do
      described_class.register_panel(rails_config)
    end

    it "resolves preview class name and runs ComponentReport, yielding findings" do
      fake_report = instance_double(Guardrails::Lookbook::ComponentReport)
      allow(Guardrails::Lookbook::ComponentReport).to receive(:new).and_return(fake_report)
      allow(fake_report).to receive(:for).with("ButtonComponent")
                                         .and_return(component: "ButtonComponent", violations: [])
      stub_const("Rails", double("Rails", root: Pathname("/fake/root")))

      result = panels.registered[:guardrails].locals.call(data)

      expect(result[:findings]).to include(component: "ButtonComponent")
    end

    it "yields nil findings when the preview data is unusable" do
      result = panels.registered[:guardrails].locals.call(nil)
      expect(result[:findings]).to be_nil
    end

    it "falls back to data.preview_class.name when data has no .preview" do
      flat_data = double("FlatPanelData", preview_class: preview_class)
      allow(flat_data).to receive(:respond_to?).with(:preview).and_return(false)
      allow(flat_data).to receive(:respond_to?).with(:preview_class).and_return(true)

      fake_report = instance_double(Guardrails::Lookbook::ComponentReport)
      allow(Guardrails::Lookbook::ComponentReport).to receive(:new).and_return(fake_report)
      allow(fake_report).to receive(:for).with("ButtonComponent").and_return(component: "ButtonComponent")
      stub_const("Rails", double("Rails", root: Pathname("/fake/root")))

      result = panels.registered[:guardrails].locals.call(flat_data)
      expect(result[:findings][:component]).to eq("ButtonComponent")
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
      described_class.register!(config: rails_config, view_consumer: consumer)

      expect(panels.registered.keys).to eq([:guardrails])
    end
  end
end
