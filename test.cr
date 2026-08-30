module ManualDefinitions
  class Widget
    VERSION = "1.0"

    def self.build
      new
    end

    def render
      puts VERSION
    end

    def render_again
      render
    end

    macro greeting
      "hello"
    end
  end

  struct Token
    getter value : String

    def initialize(@value)
    end
  end
end

# Put the cursor on each marked reference and press gd.
widget = ManualDefinitions::Widget.new        # -> Widget class
built = ManualDefinitions::Widget.build       # -> build class method
version = ManualDefinitions::Widget::VERSION  # -> VERSION constant
token = ManualDefinitions::Token.new("token") # -> Token struct

# Inside Widget, gd on render resolves its local method.
# Inside Widget, gd on greeting resolves its macro.
# On widget.render, gd resolves Widget#render because widget was constructed with Widget.new.
# Receivers with no directly known constructor type intentionally do not jump.
widget.render
