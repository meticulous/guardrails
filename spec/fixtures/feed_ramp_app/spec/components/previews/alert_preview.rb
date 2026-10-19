# frozen_string_literal: true

class AlertPreview < Lookbook::Preview
  def default
    render Components::Alert.new
  end
end
