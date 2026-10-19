# frozen_string_literal: true

module Views
  module Pages
    class ShowView < Phlex::HTML
      def view_template
        render Components::Alert.new(tone: :warning) do |alert|
          alert.title("Heads up")
        end
      end
    end
  end
end
