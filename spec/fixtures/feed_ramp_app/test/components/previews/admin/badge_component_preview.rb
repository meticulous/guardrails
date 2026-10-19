# frozen_string_literal: true

module Admin
  class BadgeComponentPreview < ViewComponent::Preview
    def warning
      render BadgeComponent.new(count: 5, tone: :warning)
    end
  end
end
