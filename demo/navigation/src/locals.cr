require "./declarations"

module NavigationDemo
  class LocalScopes
    def render(value : String, count = 1)
      # CURRENT: both identifiers resolve to this method's parameter declaration.
      value
      count

      # CURRENT: local identifier resolves to its nearest preceding assignment.
      widget = Widget.new(value)
      widget.render
    end

    def unknown_receiver(widget)
      # CURRENT: a receiver without direct-construction inference does not resolve.
      widget.render
    end
  end
end
