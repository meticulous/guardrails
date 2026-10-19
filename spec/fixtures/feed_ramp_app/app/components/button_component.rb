# frozen_string_literal: true

# The app's button. Use it for every clickable action that isn't a link.
#
# @param label [String] the visible text
# @param variant [Symbol] :primary, :secondary or :danger
class ButtonComponent < ApplicationComponent
  renders_one :icon, IconComponent

  def initialize(label:, variant: :primary, size: :md, **html_options)
    @label = label
    @variant = variant
    @size = size
    @html_options = html_options
  end

  private

  def classes
    "btn btn--#{@variant}"
  end
end
