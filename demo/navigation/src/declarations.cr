module NavigationDemo
  annotation Traced
  end

  module Formatting
    DEFAULT_WIDTH = 80
    alias Width = Int32

    macro banner(text)
      "== {{text}} =="
    end
  end

  class Widget
    VERSION = "1.0"

    getter name : String

    def initialize(@name : String)
    end

    def render(width = Formatting::DEFAULT_WIDTH)
      "#{@name}: #{width}"
    end

    def inherited_name
      @name
    end

    def self.build(name : String)
      new(name)
    end
  end

  # Deliberately collides with the standard-library type for picker demo.
  class String
  end

  struct Token
    getter value : String

    def initialize(@value : String)
    end
  end

  enum Status
    Queued
    Running
    Complete
  end

  lib Native
    alias SizeT = LibC::SizeT

    union Payload
      text : UInt8*
      size : Int32
    end

    fun strlen(value : UInt8*) : LibC::SizeT
  end

  def self.helper(token : Token)
    token.value
  end
end
