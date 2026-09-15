require "./declarations"

module NavigationDemo
  module Renderable
    def label : String
      "renderable"
    end
  end

  class DecoratedWidget < Widget
    include Renderable

    def render(width = 40)
      super
    end
  end

  def accepts_widget(widget : Widget)
    # FUTURE: infer parameter type, then navigate widget.render to Widget#render.
    widget.render
  end

  def chained_receiver
    # FUTURE: infer Widget.build return type, then navigate render.
    Widget.build("future").render
  end

  def inherited_method
    # FUTURE: follow superclass method when DecoratedWidget does not override a member.
    DecoratedWidget.new("future").inherited_name
  end

  def included_method
    # FUTURE: follow methods supplied by included modules.
    DecoratedWidget.new("future").label
  end
end
