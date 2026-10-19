# frozen_string_literal: true

class ButtonComponentPreview < ViewComponent::Preview
  # @label Primary button
  def default
    render(ButtonComponent.new(label: "Save"))
  end

  # A destructive action.
  # @param label text
  def danger(label: "Delete")
    render(ButtonComponent.new(label: label, variant: :danger))
  end

  # @hidden
  def x
    render(ButtonComponent.new(label: "X"))
  end

  private

  def helper
    "not a preview"
  end
end
