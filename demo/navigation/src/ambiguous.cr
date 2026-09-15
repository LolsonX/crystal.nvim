require "./declarations"

def ambiguous_helper(value : String)
  value
end

def ambiguous_helper(value : Int32)
  value
end

# CURRENT: `gd` on ambiguous_helper offers its two overload declarations.
ambiguous_helper("navigation")

# CURRENT: `gd` on a qualified type resolves directly.
NavigationDemo::Widget.new("qualified")
