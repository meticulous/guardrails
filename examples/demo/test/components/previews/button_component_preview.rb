# frozen_string_literal: true

class ButtonComponentPreview < ViewComponent::Preview
  def primary
    render(ButtonComponent.new(label: "Save"))
  end

  def with_icon
    render(ButtonComponent.new(label: "Search", variant: :secondary)) do |c|
      c.with_icon { tag.svg(tag.use(href: "/sprite.svg#icon-check")) }
    end
  end
end
