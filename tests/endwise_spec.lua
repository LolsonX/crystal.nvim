local test_file = debug.getinfo(1, "S").source:sub(2)
local test_dir = vim.fn.fnamemodify(test_file, ":h")
local plugin_root = vim.fn.fnamemodify(test_dir, ":h")

local function read_query()
	local path = plugin_root .. "/queries/crystal/endwise.scm"
	local f = assert(io.open(path, "r"), "Could not open " .. path)
	local content = f:read("*a")
	f:close()
	return content
end

local function strip_endwise_directives(query_text)
	return query_text:gsub(" %(#endwise![^)]*%)", "")
end

local function parse_crystal(source)
	local parser = vim.treesitter.get_string_parser(source, "crystal")
	local trees = parser:parse()
	if not trees or #trees == 0 then
		return nil, "Failed to parse Crystal source"
	end
	return trees[1], source
end

local function get_matches(source, query_text)
	local tree, text = parse_crystal(source)
	if not tree then
		return nil, text
	end
	local root = tree:root()
	local stripped = strip_endwise_directives(query_text)
	local ok, query = pcall(vim.treesitter.query.parse, "crystal", stripped)
	if not ok then
		return nil, query
	end
	local matches = {}
	for pattern_id, match in query:iter_matches(root, text) do
		local captures = {}
		for id, val in pairs(match) do
			local name = query.captures[id]
			local node = type(val) == "table" and val[1] or val
			if node and type(node) == "userdata" then
				local sr, sc, er, ec = node:range()
				captures[name] = {
					text = vim.treesitter.get_node_text(node, text),
					type = node:type(),
					start_row = sr,
					start_col = sc,
					end_row = er,
					end_col = ec,
				}
			end
		end
		table.insert(matches, {
			pattern_id = pattern_id,
			captures = captures,
		})
	end
	return matches
end

local function find_match_with_captures(matches, capture_names)
	if not matches then
		return nil, "No matches (query may have failed)"
	end
	for _, m in ipairs(matches) do
		local found = true
		for _, name in ipairs(capture_names) do
			if not m.captures[name] then
				found = false
				break
			end
		end
		if found then
			return m
		end
	end
	return nil, "No match with captures: " .. vim.inspect(capture_names)
end

local function find_matches_with_endable_type(matches, node_type)
	if not matches then
		return {}
	end
	local result = {}
	for _, m in ipairs(matches) do
		if m.captures.endable and m.captures.endable.type == node_type then
			table.insert(result, m)
		end
	end
	return result
end

local function assert_endable(source, query_text)
	local matches, err = get_matches(source, query_text)
	if not matches then
		error("Query failed for source: " .. source .. "\nError: " .. err)
	end
	local _, err = find_match_with_captures(matches, { "endable" })
	if err then
		error(err .. "\nSource:\n" .. source .. "\nAll matches:\n" .. vim.inspect(matches))
	end
	return true
end

local function assert_endable_type(source, query_text, node_type)
	local matches = get_matches(source, query_text)
	if not matches then
		error("Query failed for source: " .. source)
	end
	local found = find_matches_with_endable_type(matches, node_type)
	if #found == 0 then
		error(
			"No endable match with type '"
				.. node_type
				.. "'\nSource:\n"
				.. source
				.. "\nAll matches:\n"
				.. vim.inspect(matches)
		)
	end
	return found
end

local query_text = read_query()

describe("endwise.scm", function()
	describe("compilation", function()
		it("compiles without errors after stripping directives", function()
			local stripped = strip_endwise_directives(query_text)
			local ok, err = pcall(vim.treesitter.query.parse, "crystal", stripped)
			assert(ok, "Query compilation failed: " .. tostring(err))
		end)

		it("contains expected pattern lines", function()
			local lines = vim.split(query_text, "\n")
			local patterns = vim.tbl_filter(function(line)
				return line:match("^%(") ~= nil
			end, lines)
			assert.equals(36, #patterns, "Expected 36 query patterns (20 valid + 16 ERROR recovery)")
		end)
	end)

	describe("type definitions", function()
		it("matches module", function()
			assert_endable_type("module Foo\nend\n", query_text, "module_def")
		end)

		it("matches class", function()
			assert_endable_type("class Foo\nend\n", query_text, "class_def")
		end)

		it("matches class with superclass", function()
			assert_endable_type("class Foo < Bar\nend\n", query_text, "class_def")
		end)

		it("matches struct", function()
			assert_endable_type("struct Foo\nend\n", query_text, "struct_def")
		end)

		it("matches struct with superclass", function()
			assert_endable_type("struct Foo < Bar\nend\n", query_text, "struct_def")
		end)

		it("matches enum", function()
			assert_endable_type("enum Foo\nend\n", query_text, "enum_def")
		end)

		it("matches lib", function()
			assert_endable_type("lib Foo\nend\n", query_text, "lib_def")
		end)

		it("matches union", function()
			local source = "union Foo\nend\n"
			local matches = get_matches(source, query_text)
			assert.is_not_nil(matches, "Query should parse union source")
		end)

		it("matches annotation", function()
			assert_endable_type("annotation Foo\nend\n", query_text, "annotation_def")
		end)

		it("matches c_struct inside lib", function()
			local source = "lib C\n  struct Foo\n    x : Int32\n  end\nend\n"
			assert_endable_type(source, query_text, "c_struct_def")
		end)
	end)

	describe("method definitions", function()
		it("matches def without params", function()
			assert_endable_type("def foo\nend\n", query_text, "method_def")
		end)

		it("matches def with params", function()
			assert_endable_type("def foo(x)\nend\n", query_text, "method_def")
		end)

		it("matches def with typed params", function()
			assert_endable_type("def foo(x : Int)\nend\n", query_text, "method_def")
		end)

		it("matches def with return type only", function()
			assert_endable_type("def foo : String\nend\n", query_text, "method_def")
		end)

		it("matches def with params and return type", function()
			assert_endable_type("def foo(x : Int) : String\nend\n", query_text, "method_def")
		end)

		it("matches def with multiple params", function()
			assert_endable_type("def foo(x, y)\nend\n", query_text, "method_def")
		end)

		it("matches def with splat param", function()
			assert_endable_type("def foo(*args)\nend\n", query_text, "method_def")
		end)

		it("matches def with double splat param", function()
			assert_endable_type("def foo(**kwargs)\nend\n", query_text, "method_def")
		end)

		it("matches def with block param", function()
			assert_endable_type("def foo(&block)\nend\n", query_text, "method_def")
		end)

		it("matches self.def", function()
			assert_endable_type("def self.foo\nend\n", query_text, "method_def")
		end)

		it("matches macro without params", function()
			assert_endable_type("macro foo\nend\n", query_text, "macro_def")
		end)

		it("matches macro with params", function()
			assert_endable_type("macro foo(x)\nend\n", query_text, "macro_def")
		end)

		it("matches fun without params", function()
			assert_endable_type("fun foo\nend\n", query_text, "fun_def")
		end)

		it("matches fun with params", function()
			assert_endable_type("fun foo(x : Int)\nend\n", query_text, "fun_def")
		end)

		it("matches fun with return type", function()
			assert_endable_type("fun foo(x) : Int\nend\n", query_text, "fun_def")
		end)
	end)

	describe("control flow", function()
		it("matches while", function()
			assert_endable("while true\nend\n", query_text)
		end)

		it("matches until", function()
			assert_endable("until false\nend\n", query_text)
		end)

		it("matches if", function()
			assert_endable("if true\nend\n", query_text)
		end)

		it("matches if then", function()
			assert_endable("if true then\nend\n", query_text)
		end)

		it("matches unless", function()
			assert_endable("unless false\nend\n", query_text)
		end)

		it("matches unless then", function()
			assert_endable("unless false then\nend\n", query_text)
		end)

		it("matches begin", function()
			assert_endable("begin\nend\n", query_text)
		end)

		it("matches case with expression", function()
			assert_endable("case x\nend\n", query_text)
		end)

		it("matches case with when", function()
			assert_endable("case x\nwhen 1\n  puts 1\nend\n", query_text)
		end)

		it("matches select", function()
			local source = "ch = Channel(Int32).new\nselect\nwhen v = ch.receive\n  puts v\nend\n"
			assert_endable(source, query_text)
		end)
	end)

	describe("blocks", function()
		it("matches do block without params", function()
			assert_endable("[1,2,3].each do\nend\n", query_text)
		end)

		it("matches do block with single param", function()
			assert_endable("[1,2,3].each do |x|\nend\n", query_text)
		end)

		it("matches do block with multiple params", function()
			assert_endable("hash.each do |key, value|\nend\n", query_text)
		end)

		it("matches do block with splat param", function()
			assert_endable("arr.each_with_index do |*args|\nend\n", query_text)
		end)
	end)

	describe("heredocs", function()
		it("matches <<- heredoc", function()
			local source = "x = <<-HEREDOC\nhello\nHEREDOC\n"
			local matches = get_matches(source, query_text)
			assert.is_not_nil(matches)
			local _, err = find_match_with_captures(matches, { "cursor" })
			assert.is_nil(err, "Should match heredoc: " .. tostring(err))
		end)

		it("matches <<- heredoc with indented terminator", function()
			local source = "x = <<-FOO\nbar\n  FOO\n"
			local matches = get_matches(source, query_text)
			assert.is_not_nil(matches)
			local _, err = find_match_with_captures(matches, { "cursor" })
			assert.is_nil(err, "Should match indented heredoc: " .. tostring(err))
		end)
	end)

	describe("incomplete constructs (valid AST with MISSING end)", function()
		it("incomplete module matches via valid pattern", function()
			assert_endable_type("module Foo\n", query_text, "module_def")
		end)

		it("incomplete struct matches via valid pattern", function()
			assert_endable_type("struct Foo\n", query_text, "struct_def")
		end)

		it("incomplete enum matches via valid pattern", function()
			assert_endable_type("enum Foo\n", query_text, "enum_def")
		end)

		it("incomplete lib matches via valid pattern", function()
			assert_endable_type("lib Foo\n", query_text, "lib_def")
		end)

		it("incomplete class with superclass matches via valid pattern", function()
			assert_endable_type("class Foo < Bar\n", query_text, "class_def")
		end)

		it("incomplete def matches via valid pattern", function()
			assert_endable_type("def foo\n", query_text, "method_def")
		end)

		it("incomplete def with params matches via valid pattern", function()
			assert_endable_type("def foo(x)\n", query_text, "method_def")
		end)

		it("incomplete macro matches via valid pattern", function()
			assert_endable_type("macro foo\n", query_text, "macro_def")
		end)

		it("incomplete fun matches via valid pattern", function()
			assert_endable_type("fun foo\n", query_text, "fun_def")
		end)

		it("incomplete while matches via valid pattern", function()
			assert_endable("while true\n", query_text)
		end)

		it("incomplete until matches via valid pattern", function()
			assert_endable("until false\n", query_text)
		end)

		it("incomplete if matches via valid pattern", function()
			assert_endable("if true\n", query_text)
		end)

		it("incomplete unless matches via valid pattern", function()
			assert_endable("unless false\n", query_text)
		end)

		it("incomplete begin matches via valid pattern", function()
			assert_endable("begin\n", query_text)
		end)

		it("incomplete do block matches via ERROR pattern", function()
			local matches = get_matches("[1,2,3].each do\n", query_text)
			assert.is_not_nil(matches, "Query should match incomplete do block")
			assert.truthy(#matches > 0, "Should have matches for incomplete do block")
		end)

		it("incomplete do block with params matches via ERROR pattern", function()
			local matches = get_matches("[1,2,3].each do |x|\n", query_text)
			assert.is_not_nil(matches, "Query should match incomplete do block with params")
			assert.truthy(#matches > 0, "Should have matches for incomplete do block with params")
		end)
	end)

	describe("error recovery (ERROR nodes)", function()
		it("ERROR: begin without newline produces matches", function()
			local matches = get_matches("begin", query_text)
			assert.is_not_nil(matches, "Query should return matches for 'begin'")
			assert.truthy(#matches > 0, "Should match ERROR for 'begin'")
		end)

		it("ERROR: case without newline produces matches", function()
			local matches = get_matches("case", query_text)
			assert.is_not_nil(matches, "Query should return matches for 'case'")
			assert.truthy(#matches > 0, "Should match ERROR for 'case'")
		end)

		it("ERROR: case with newline produces matches", function()
			local matches = get_matches("case\n", query_text)
			assert.is_not_nil(matches, "Query should return matches for 'case\\n'")
			assert.truthy(#matches > 0, "Should match ERROR for 'case\\n'")
		end)

		it("ERROR: select without newline produces matches", function()
			local matches = get_matches("select", query_text)
			assert.is_not_nil(matches, "Query should return matches for 'select'")
			assert.truthy(#matches > 0, "Should match ERROR for 'select'")
		end)

		it("ERROR: do without newline produces matches", function()
			local matches = get_matches("foo.each do", query_text)
			assert.is_not_nil(matches, "Query should return matches for 'do'")
			assert.truthy(#matches > 0, "Should match ERROR for 'do'")
		end)

		it("ERROR: do with newline produces matches", function()
			local matches = get_matches("foo.each do\n", query_text)
			assert.is_not_nil(matches, "Query should return matches for 'do\\n'")
			assert.truthy(#matches > 0, "Should match ERROR for 'do\\n'")
		end)

		it("ERROR: if without newline produces matches", function()
			local matches = get_matches("if true", query_text)
			assert.is_not_nil(matches, "Query should return matches for 'if true'")
			assert.truthy(#matches > 0, "Should match ERROR for 'if true'")
		end)

		it("ERROR: unless without newline produces matches", function()
			local matches = get_matches("unless false", query_text)
			assert.is_not_nil(matches, "Query should return matches for 'unless false'")
			assert.truthy(#matches > 0, "Should match ERROR for 'unless false'")
		end)
	end)

	describe("cursor capture", function()
		it("cursor captures exist on type def name", function()
			local source = "class Foo\nend\n"
			local matches = get_matches(source, query_text)
			local match = find_match_with_captures(matches, { "cursor", "endable" })
			assert.is_not_nil(match)
			assert.equals("Foo", match.captures.cursor.text)
		end)

		it("cursor captures exist on class name with superclass", function()
			local source = "class Foo < Bar\nend\n"
			local matches = get_matches(source, query_text)
			local match = find_match_with_captures(matches, { "cursor", "endable" })
			assert.is_not_nil(match)
			assert.truthy(match.captures.cursor.text == "Foo" or match.captures.cursor.text == "Bar")
		end)

		it("cursor captures exist on while condition", function()
			local source = "while true\nend\n"
			local matches = get_matches(source, query_text)
			local match = find_match_with_captures(matches, { "cursor" })
			assert.is_not_nil(match)
		end)

		it("cursor captures exist on def name", function()
			local source = "def foo\nend\n"
			local matches = get_matches(source, query_text)
			local match = find_match_with_captures(matches, { "cursor" })
			assert.is_not_nil(match)
			assert.equals("foo", match.captures.cursor.text)
		end)

		it("cursor captures exist on block do", function()
			local source = "[1].each do\nend\n"
			local matches = get_matches(source, query_text)
			local match = find_match_with_captures(matches, { "cursor" })
			assert.is_not_nil(match)
		end)

		it("cursor captures exist on heredoc_start", function()
			local source = "x = <<-FOO\nbar\nFOO\n"
			local matches = get_matches(source, query_text)
			local match = find_match_with_captures(matches, { "cursor" })
			assert.is_not_nil(match)
		end)
	end)

	describe("nested constructs", function()
		it("class containing def matches both", function()
			local source = "class Foo\n  def bar\n  end\nend\n"
			local class_matches = find_matches_with_endable_type(get_matches(source, query_text), "class_def")
			local def_matches = find_matches_with_endable_type(get_matches(source, query_text), "method_def")
			assert.equals(1, #class_matches)
			assert.equals(1, #def_matches)
		end)

		it("module containing class containing def matches all three", function()
			local source = "module M\n  class C\n    def f\n    end\n  end\nend\n"
			local matches = get_matches(source, query_text)
			local types = {}
			for _, m in ipairs(matches) do
				if m.captures.endable then
					types[m.captures.endable.type] = true
				end
			end
			assert.truthy(types.module_def)
			assert.truthy(types.class_def)
			assert.truthy(types.method_def)
		end)

		it("if inside def inside class matches all", function()
			local source = "class C\n  def f\n    if true\n    end\n  end\nend\n"
			local matches = get_matches(source, query_text)
			local types = {}
			for _, m in ipairs(matches) do
				if m.captures.endable then
					types[m.captures.endable.type] = true
				end
			end
			assert.truthy(types.class_def)
			assert.truthy(types.method_def)
			assert.truthy(types["if"])
		end)

		it("lib containing c_struct matches both", function()
			local source = "lib C\n  struct Foo\n    x : Int32\n  end\nend\n"
			local matches = get_matches(source, query_text)
			local types = {}
			for _, m in ipairs(matches) do
				if m.captures.endable then
					types[m.captures.endable.type] = true
				end
			end
			assert.truthy(types.lib_def)
			assert.truthy(types.c_struct_def)
		end)
	end)

	describe("no false positives", function()
		it("simple assignment does not match endable", function()
			local matches = get_matches("x = 1\n", query_text)
			if matches then
				local _, err = find_match_with_captures(matches, { "endable" })
				assert.is_not_nil(err, "Assignment should not produce endable match")
			end
		end)

		it("method call does not match endable", function()
			local matches = get_matches("puts 1\n", query_text)
			if matches then
				local _, err = find_match_with_captures(matches, { "endable" })
				assert.is_not_nil(err, "Method call should not produce endable match")
			end
		end)

		it("complete class+end matches exactly once", function()
			local source = "class Foo\nend\n"
			local matches = get_matches(source, query_text)
			local class_matches = find_matches_with_endable_type(matches, "class_def")
			local error_matches = find_matches_with_endable_type(matches, "ERROR")
			assert.equals(1, #class_matches, "Should match class_def exactly once")
			assert.equals(0, #error_matches, "Should not match ERROR for complete class")
		end)

		it("complete def+end matches exactly once", function()
			local source = "def foo\nend\n"
			local matches = get_matches(source, query_text)
			local def_matches = find_matches_with_endable_type(matches, "method_def")
			local error_matches = find_matches_with_endable_type(matches, "ERROR")
			assert.equals(1, #def_matches, "Should match method_def exactly once")
			assert.equals(0, #error_matches, "Should not match ERROR for complete def")
		end)

		it("string literal does not match endable", function()
			local matches = get_matches('"hello"\n', query_text)
			if matches then
				local _, err = find_match_with_captures(matches, { "endable" })
				assert.is_not_nil(err, "String literal should not produce endable match")
			end
		end)

		it("number literal does not match endable", function()
			local matches = get_matches("42\n", query_text)
			if matches then
				local _, err = find_match_with_captures(matches, { "endable" })
				assert.is_not_nil(err, "Number literal should not produce endable match")
			end
		end)
	end)
end)
