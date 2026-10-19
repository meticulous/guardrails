# frozen_string_literal: true

# A bordered panel with an optional header and actions.
class CardComponent < ApplicationComponent
  renders_one :header, ->(title:, level: 2) { HeadingComponent.new(title, level: level) }
  renders_many :actions, "ButtonComponent"
  renders_one :visual, types: { icon: IconComponent, image: "ImageComponent" }

  def initialize(title: nil)
    @title = title
  end
end
