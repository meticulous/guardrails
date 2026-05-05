# frozen_string_literal: true

module Guardrails
  module HexNormalizer
    module_function

    # Normalize a hex color literal for equality comparison:
    # - lowercase
    # - expand 3-char shorthand (#fa3 -> #ffaa33)
    # - strip alpha channel (#ffaa3380 -> #ffaa33)
    # - return non-hex input unchanged (after lowercasing)
    def normalize(value)
      v = value.to_s.downcase.strip
      return v unless v.start_with?("#")

      case v.length
      when 4 # #fa3 -> #ffaa33
        "#" + v[1..].chars.map { |c| c * 2 }.join
      when 5 # #fa3a -> #ffaa33 (drop alpha)
        ("#" + v[1..].chars.map { |c| c * 2 }.join)[0..6]
      when 7 # #ffaa33 (canonical)
        v
      when 9 # #ffaa3380 -> #ffaa33
        v[0..6]
      else
        v
      end
    end

    # Maximum per-channel (R / G / B) difference between two normalized hex
    # colors, on a 0..255 scale. Returns nil if either value isn't a
    # 7-char hex after normalization. Distance 0 = identical color.
    def distance(a, b)
      a_norm = normalize(a)
      b_norm = normalize(b)
      return nil unless a_norm.length == 7 && a_norm.start_with?("#")
      return nil unless b_norm.length == 7 && b_norm.start_with?("#")

      diffs = [
        (a_norm[1..2].to_i(16) - b_norm[1..2].to_i(16)).abs,
        (a_norm[3..4].to_i(16) - b_norm[3..4].to_i(16)).abs,
        (a_norm[5..6].to_i(16) - b_norm[5..6].to_i(16)).abs
      ]
      diffs.max
    end
  end
end
