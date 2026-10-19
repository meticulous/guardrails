# frozen_string_literal: true

module Components
  # An inline message. Pass a block for the body.
  class Alert < Base
    def initialize(tone: :info, dismissible: false)
      @tone = tone
      @dismissible = dismissible
    end

    def view_template(&)
      div(class: "alert alert--#{@tone}", &)
    end

    def title(text = nil, &block)
      h3(class: "alert__title") { text || yield }
    end

    private

    def icon(&block)
      span(&block)
    end
  end
end
