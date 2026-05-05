# frozen_string_literal: true

require_relative "hex_normalizer"

module Guardrails
  class TokenMatcher
    NEAR_MATCH_THRESHOLD = 4

    Match = Struct.new(:token, :kind, :distance, keyword_init: true)

    def initialize(tokens, near_match_threshold: NEAR_MATCH_THRESHOLD)
      @tokens = tokens
      @lookup = tokens.to_h { |t| [HexNormalizer.normalize(t.value), t] }
      @near_match_threshold = near_match_threshold
    end

    def match(value)
      return nil if value.nil?

      exact = @lookup[HexNormalizer.normalize(value)]
      return Match.new(token: exact, kind: :exact, distance: 0) if exact

      best = nil
      best_distance = @near_match_threshold + 1
      @tokens.each do |t|
        d = HexNormalizer.distance(value, t.value)
        next unless d
        next if d.zero?

        if d < best_distance
          best = t
          best_distance = d
        end
      end
      return nil unless best

      Match.new(token: best, kind: :near, distance: best_distance)
    end
  end
end
