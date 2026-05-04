# frozen_string_literal: true

require "pathname"

module Guardrails
  class Init
    class MediaQueryScaffolder
      DARK_MODE_PATTERN = /@media\s*\(\s*prefers-color-scheme\s*:\s*dark\s*\)/
      HIGH_CONTRAST_PATTERN = /@media\s*\(\s*prefers-contrast\s*:\s*more\s*\)/

      DARK_MODE_STUB = <<~CSS
        @media (prefers-color-scheme: dark) {
          /* TODO: fill this in — define dark-mode token overrides here */
        }
      CSS

      HIGH_CONTRAST_STUB = <<~CSS
        @media (prefers-contrast: more) {
          /* TODO: fill this in — define high-contrast token overrides here */
        }
      CSS

      def initialize(file, output: $stdout)
        @file = file ? Pathname(file) : nil
        @output = output
      end

      def scaffold
        return [:skipped, "no colors_file configured — add prefers-color-scheme / prefers-contrast blocks to your token file manually"] if @file.nil?
        return [:skipped, "configured colors_file does not exist (#{@file.basename}) — skipping media-query scaffold"] unless @file.exist?

        content = File.read(@file, encoding: Encoding::UTF_8)
        additions = []

        unless content.match?(DARK_MODE_PATTERN)
          content = ensure_trailing_newline(content) + "\n" + DARK_MODE_STUB
          additions << "prefers-color-scheme: dark"
        end

        unless content.match?(HIGH_CONTRAST_PATTERN)
          content = ensure_trailing_newline(content) + "\n" + HIGH_CONTRAST_STUB
          additions << "prefers-contrast: more"
        end

        if additions.empty?
          [:already_present, "media-query stubs already present in #{@file.basename}"]
        else
          File.write(@file, content, encoding: Encoding::UTF_8)
          [:appended, "appended stubs (#{additions.join(', ')}) to #{@file.basename}"]
        end
      end

      private

      def ensure_trailing_newline(content)
        content.end_with?("\n") ? content : content + "\n"
      end
    end
  end
end
