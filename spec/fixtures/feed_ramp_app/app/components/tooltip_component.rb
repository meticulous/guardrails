# frozen_string_literal: true

# Never rendered anywhere: its example stays empty.
class TooltipComponent < ApplicationComponent
  def initialize(text:)
    @text = text
  end

  def call
    tag.span(@text, role: "tooltip")
  end
end
