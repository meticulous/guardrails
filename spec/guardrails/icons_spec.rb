# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/icons"

RSpec.describe Guardrails::Icons do
  let(:root) { Pathname(Dir.mktmpdir) }
  after { FileUtils.rm_rf(root) }

  def write_svg(relative, content)
    full = root.join(relative)
    full.dirname.mkpath
    full.write(content)
  end

  def run_icons(**opts)
    described_class.new(root: root, output: StringIO.new, **opts).run
  end

  def sprite_path
    root.join("app/assets/images/icons/sprite.svg")
  end

  describe "#generate_sprite" do
    it "reports no SVGs when source is empty" do
      output = StringIO.new
      described_class.new(root: root, output: output).run

      expect(output.string).to include("No SVGs found")
      expect(sprite_path).not_to exist
    end

    it "writes a sprite with one symbol per source SVG" do
      write_svg "app/assets/images/icons/check.svg", <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M5 13l4 4L19 7"/></svg>
      SVG

      run_icons

      content = sprite_path.read(encoding: Encoding::UTF_8)
      expect(content).to include('<symbol id="icon-check" viewBox="0 0 24 24">')
      expect(content).to include('<path d="M5 13l4 4L19 7"/>')
    end

    it "produces deterministic output (sorted by filename)" do
      write_svg "app/assets/images/icons/zulu.svg", '<svg viewBox="0 0 24 24"><path d="M0 0"/></svg>'
      write_svg "app/assets/images/icons/alpha.svg", '<svg viewBox="0 0 24 24"><path d="M1 1"/></svg>'

      run_icons

      content = sprite_path.read(encoding: Encoding::UTF_8)
      alpha_pos = content.index("icon-alpha")
      zulu_pos = content.index("icon-zulu")
      expect(alpha_pos).to be < zulu_pos
    end

    it "preserves the source viewBox" do
      write_svg "app/assets/images/icons/big.svg", '<svg viewBox="0 0 48 48"><circle cx="24" cy="24" r="20"/></svg>'

      run_icons

      content = sprite_path.read(encoding: Encoding::UTF_8)
      expect(content).to include('viewBox="0 0 48 48"')
    end

    it "falls back to a default viewBox when missing" do
      write_svg "app/assets/images/icons/no-vb.svg", "<svg><path d=\"M0 0\"/></svg>"

      run_icons

      content = sprite_path.read(encoding: Encoding::UTF_8)
      expect(content).to include('viewBox="0 0 24 24"')
    end

    it "skips empty SVG bodies" do
      write_svg "app/assets/images/icons/empty.svg", '<svg viewBox="0 0 24 24"></svg>'
      write_svg "app/assets/images/icons/real.svg", '<svg viewBox="0 0 24 24"><path d="M0 0"/></svg>'

      run_icons

      content = sprite_path.read(encoding: Encoding::UTF_8)
      expect(content).to include("icon-real")
      expect(content).not_to include("icon-empty")
    end

    it "skips the sprite output if it lives in the source directory" do
      write_svg "app/assets/images/icons/check.svg", '<svg viewBox="0 0 24 24"><path d="M0 0"/></svg>'
      run_icons

      run_icons

      content = sprite_path.read(encoding: Encoding::UTF_8)
      expect(content.scan("icon-").length).to eq(1)
    end

    it "honors source and sprite_output overrides" do
      write_svg "lib/icons/x.svg", '<svg viewBox="0 0 24 24"><path d="M0 0"/></svg>'

      described_class.new(
        root: root,
        output: StringIO.new,
        source: "lib/icons",
        sprite_output: "public/sprite.svg"
      ).run

      expect(root.join("public/sprite.svg")).to exist
    end

    it "honors guardrails.yml configuration" do
      write_svg "lib/icons/x.svg", '<svg viewBox="0 0 24 24"><path d="M0 0"/></svg>'
      root.join("guardrails.yml").write(<<~YAML)
        guardrails:
          icons:
            source: lib/icons
            sprite_output: public/sprite.svg
      YAML

      run_icons

      expect(root.join("public/sprite.svg")).to exist
    end

    it "returns the path to the written sprite" do
      write_svg "app/assets/images/icons/x.svg", '<svg viewBox="0 0 24 24"><path d="M0 0"/></svg>'

      result = run_icons

      expect(result).to eq(sprite_path)
    end
  end
end
