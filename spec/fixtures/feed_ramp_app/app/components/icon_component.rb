# frozen_string_literal: true

class IconComponent < ApplicationComponent
  def initialize(name, size = 16)
    @name = name
    @size = size
  end

  def call
    tag.svg(tag.use(href: "#icon-#{@name}"), width: @size, height: @size)
  end
end
