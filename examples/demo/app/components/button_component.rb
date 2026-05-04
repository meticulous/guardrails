# frozen_string_literal: true

class ButtonComponent < ViewComponent::Base
  renders_one :icon

  def initialize(label:, variant: :primary)
    @label = label
    @variant = variant
  end

  attr_reader :label, :variant
end
