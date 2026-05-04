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
  end
end
