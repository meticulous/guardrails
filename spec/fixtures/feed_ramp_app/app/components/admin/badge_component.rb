# frozen_string_literal: true

module Admin
  # A count badge for the admin nav.
  class BadgeComponent < ::ApplicationComponent
    def initialize(count:, tone: :info)
      @count = count
      @tone = tone
    end

    def call
      tag.span(@count, class: "badge badge--#{@tone}")
    end
  end
end
