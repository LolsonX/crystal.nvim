require "./declarations"

module NavigationDemo
  # CURRENT: module, class, struct, enum, union, annotation, lib, constants, macros, and fun declarations.
  Widget
  Token
  Status
  NavigationDemo::Native::Payload
  Traced
  Native
  NavigationDemo::Widget::VERSION
  NavigationDemo::Formatting::DEFAULT_WIDTH
  # CURRENT: macro declaration target (macros are compile-time only).
  # NavigationDemo::Formatting.banner

  # CURRENT: .new resolves to initialize; instance receiver created with Type.new resolves to render.
  widget = Widget.new("demo")
  widget.render
  Widget.build("demo")

  # CURRENT: method lookup within its enclosing class/module.
  class Dashboard
    def render
      "dashboard"
    end

    def show
      render
    end
  end

  NavigationDemo.helper(Token.new("demo"))
end
