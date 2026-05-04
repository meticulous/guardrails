# frozen_string_literal: true

# Seeded broken: no preview file, and `unused_actions` slot is declared
# but the template never renders it.
class CardComponent < ViewComponent::Base
  renders_one :header
  renders_many :unused_actions

  def initialize(title:)
    @title = title
  end

  attr_reader :title
end
