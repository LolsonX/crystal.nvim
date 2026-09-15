local test_file = debug.getinfo(1, "S").source:sub(2)
local test_dir = vim.fn.fnamemodify(test_file, ":h")
local plugin_root = vim.fn.fnamemodify(test_dir, ":h")

package.path = table.concat({
  plugin_root .. "/lua/?.lua",
  plugin_root .. "/lua/?/init.lua",
  package.path,
}, ";")

local definitions = require("crystal-nvim.definitions")

local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

describe("Crystal definitions", function()
  local root
  local buffer

  before_each(function()
    root = vim.fn.tempname()
    vim.g.crystal_nvim_cache_dir = root .. "/cache"
    write(root .. "/shard.yml", { "name: definitions-spec" })
    write(root .. "/src/types.cr", {
      "module App",
      "  class Widget",
      "    def initialize",
      "    end",
      "",
      "    def render",
      "    end",
      "  end",
      "",
      "  struct Token",
      "  end",
      "",
      "  VERSION = \"1.0\"",
      "",
      "  macro build",
      "  end",
      "end",
    })
    write(root .. "/src/other.cr", {
      "module Other",
      "  class Widget",
      "  end",
      "end",
    })
    write(root .. "/src/external.cr", {
      "App::Widget.new",
    })
    buffer = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buffer, root .. "/src/app.cr")
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "module App",
      "  value = Widget.new",
      "  token = Token.new",
      "  version = VERSION",
      "  build",
      "end",
    })
    vim.bo[buffer].filetype = "crystal"
    vim.api.nvim_set_current_buf(buffer)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_set_current_buf(buffer)
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(bufnr)
      if bufnr ~= buffer and name:sub(1, #root + 1) == root .. "/" then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
    vim.fn.delete(root, "rf")
    vim.g.crystal_nvim_cache_dir = nil
  end)

  it("uses the nearest shard.yml as the project root", function()
    write(root .. "/src/nested/shard.yml", { "name: nested" })

    assert.equals(root .. "/src/nested", definitions.root(root .. "/src/nested/file.cr"))
  end)

  it("falls back to the nearest git root", function()
    vim.fn.delete(root .. "/shard.yml")
    vim.fn.mkdir(root .. "/.git", "p")

    assert.equals(root, definitions.root(root .. "/src/file.cr"))
  end)

  it("maps gd only for Crystal buffers", function()
    definitions.setup()
    vim.api.nvim_exec_autocmds("FileType", { buffer = buffer })

    assert.equals("Crystal definition", vim.fn.maparg("gd", "n", false, true).desc)
  end)

  it("preserves an existing buffer-local gd mapping", function()
    vim.keymap.set("n", "gd", "<cmd>echo 'custom'<cr>", { buffer = buffer })
    definitions.setup()

    assert.equals("<cmd>echo 'custom'<cr>", vim.fn.maparg("gd", "n", false, true).rhs)
  end)

  it("preserves a noncurrent Crystal buffer's gd mapping", function()
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(other, root .. "/src/other-buffer.cr")
    vim.bo[other].filetype = "crystal"
    vim.keymap.set("n", "gd", "<cmd>echo 'other'<cr>", { buffer = other })

    definitions.setup()

    local mappings = vim.api.nvim_buf_get_keymap(other, "n")
    local gd = vim.tbl_filter(function(mapping)
      return mapping.lhs == "gd"
    end, mappings)[1]
    assert.equals("<Cmd>echo 'other'<CR>", gd.rhs)
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("resolves project classes, structs, constants, and macros in the current namespace", function()
    local expected = {
      { 2, 10, "Widget", "class" },
      { 3, 10, "Token", "struct" },
      { 4, 12, "VERSION", "constant" },
      { 5, 2, "build", "macro" },
    }

    for _, case in ipairs(expected) do
      vim.api.nvim_win_set_cursor(0, { case[1], case[2] })
      local target = definitions.find(buffer)
      assert.equals(case[3], target.name)
      assert.equals(case[4], target.kind)
      assert.equals(root .. "/src/types.cr", target.path)
    end
  end)

  it("refuses ambiguous bare names outside their namespace", function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "Widget.new" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })

    assert.is_nil(definitions.find(buffer))
  end)

  it("presents ambiguous definitions and jumps to the selected one", function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "Widget.new" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local original_select = vim.ui.select
    local original_systemlist = vim.fn.systemlist
    local systemlist_calls = 0
    local selected
    vim.ui.select = function(items, options, callback)
      selected = { items = items, options = options }
      callback(vim.tbl_filter(function(item)
        return item.path == root .. "/src/other.cr"
      end, items)[1])
    end
    vim.fn.systemlist = function(...)
      systemlist_calls = systemlist_calls + 1
      return original_systemlist(...)
    end

    assert.is_true(definitions.jump(buffer))
    vim.ui.select = original_select

    assert.equals("Select Crystal definition", selected.options.prompt)
    assert.equals(2, #selected.items)
    assert.matches("class Widget", selected.options.format_item(selected.items[1]))
    assert.equals(root .. "/src/other.cr", vim.api.nvim_buf_get_name(0))
    assert.equals(0, systemlist_calls)
    vim.fn.systemlist = original_systemlist
  end)

  it("resolves a qualified class name outside its namespace", function()
    vim.api.nvim_buf_set_name(buffer, root .. "/src/external.cr")
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "App::Widget.new" })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })

    local target = definitions.find(buffer)
    assert.equals("Widget", target.name)
    assert.equals(root .. "/src/types.cr", target.path)
  end)

  it("resolves a namespace-relative qualified constant", function()
    write(root .. "/src/formatting.cr", {
      "module App",
      "  module Formatting",
      "    DEFAULT_WIDTH = 80",
      "  end",
      "end",
    })
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "module App",
      "  Formatting::DEFAULT_WIDTH",
      "end",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 17 })

    local target = definitions.find(buffer)

    assert.equals("DEFAULT_WIDTH", target.name)
    assert.equals(root .. "/src/formatting.cr", target.path)
  end)

  it("indexes shards installed under the project lib directory", function()
    write(root .. "/lib/example/shard.yml", { "name: example" })
    write(root .. "/lib/example/src/example.cr", {
      "module Example",
      "  class Client",
      "  end",
      "end",
    })
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "Example::Client.new" })
    vim.api.nvim_win_set_cursor(0, { 1, 10 })

    local target = definitions.find(buffer)
    assert.equals("Client", target.name)
    assert.equals(root .. "/lib/example/src/example.cr", target.path)

    write(root .. "/lib/example/src/extension.cr", {
      "module Example",
      "  class Client",
      "  end",
      "end",
    })
    local original_select = vim.ui.select
    local selected
    vim.ui.select = function(items, options)
      selected = { items = items, options = options }
    end
    definitions.jump(buffer)
    vim.ui.select = original_select

    assert.matches("  example/src/[^:]+:%d+$", selected.options.format_item(selected.items[1]))
  end)

  it("resolves Type.new to Type#initialize", function()
    vim.api.nvim_buf_set_name(buffer, root .. "/src/external.cr")
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "App::Widget.new" })
    vim.api.nvim_win_set_cursor(0, { 1, 14 })

    local target = definitions.find(buffer)
    assert.equals("initialize", target.name)
    assert.equals("method", target.kind)
    assert.equals(root .. "/src/types.cr", target.path)
    assert.equals(2, target.row)
  end)

  it("resolves the qualifier or class under the cursor", function()
    vim.api.nvim_buf_set_name(buffer, root .. "/src/external.cr")
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "App::Widget.new" })

    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local module = definitions.find(buffer)
    assert.equals("App", module.name)
    assert.equals("module", module.kind)

    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    local class = definitions.find(buffer)
    assert.equals("Widget", class.name)
    assert.equals("class", class.kind)
  end)

  it("resolves local variables and methods on directly constructed values", function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "widget = App::Widget.new",
      "widget",
      "widget.render",
    })

    vim.api.nvim_win_set_cursor(0, { 2, 1 })
    local variable = definitions.find(buffer)
    assert.equals("widget", variable.name)
    assert.equals("variable", variable.kind)
    assert.equals(0, variable.row)

    vim.api.nvim_win_set_cursor(0, { 3, 8 })
    local method = definitions.find(buffer)
    assert.equals("render", method.name)
    assert.equals("method", method.kind)
    assert.equals(root .. "/src/types.cr", method.path)
  end)

  it("resolves an unqualified constructor through the current namespace", function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "module App",
      "  widget = Widget.new",
      "  widget.render",
      "end",
    })
    vim.api.nvim_win_set_cursor(0, { 3, 9 })

    local method = definitions.find(buffer)
    assert.equals("render", method.name)
    assert.equals(root .. "/src/types.cr", method.path)
  end)

  it("does not use a local variable from a sibling method", function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "class Local",
      "  def first",
      "    widget = App::Widget.new",
      "  end",
      "",
      "  def second",
      "    widget.render",
      "  end",
      "end",
    })
    vim.api.nvim_win_set_cursor(0, { 7, 10 })

    assert.is_nil(definitions.find(buffer))
  end)

  it("resolves a method in its enclosing type", function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "class Local",
      "  def render",
      "  end",
      "",
      "  render",
      "end",
    })
    vim.api.nvim_win_set_cursor(0, { 5, 2 })

    local target = definitions.find(buffer)
    assert.equals("render", target.name)
    assert.equals("method", target.kind)
    assert.equals(1, target.row)
  end)

  it("uses the innermost enclosing scope", function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "module Outer",
      "  class Inner",
      "    def render",
      "    end",
      "",
      "    render",
      "  end",
      "end",
    })
    vim.api.nvim_win_set_cursor(0, { 6, 6 })

    local target = definitions.find(buffer)
    assert.equals("render", target.name)
    assert.equals(2, target.row)
  end)

  it("resolves method arguments", function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "class Local",
      "  def render(value : String, count = 1)",
      "    value",
      "    count",
      "  end",
      "end",
    })

    vim.api.nvim_win_set_cursor(0, { 3, 5 })
    local value = definitions.find(buffer)
    assert.equals("value", value.name)
    assert.equals("parameter", value.kind)
    assert.equals(1, value.row)

    vim.api.nvim_win_set_cursor(0, { 4, 5 })
    local count = definitions.find(buffer)
    assert.equals("count", count.name)
    assert.equals("parameter", count.kind)
    assert.equals(1, count.row)
  end)

  it("refuses an instance receiver that needs type inference", function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "class Local",
      "  def render",
      "  end",
      "",
      "  other.render",
      "end",
    })
    vim.api.nvim_win_set_cursor(0, { 5, 8 })

    assert.is_nil(definitions.find(buffer))
  end)

  it("indexes unsaved source from the current buffer", function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "module App",
      "  class Unsaved",
      "  end",
      "  Unsaved.new",
      "end",
    })
    vim.api.nvim_win_set_cursor(0, { 4, 4 })

    local target = definitions.find(buffer)
    assert.equals("Unsaved", target.name)
    assert.equals(root .. "/src/app.cr", target.path)
    assert.equals(1, target.row)
  end)

  it("indexes an unsaved noncurrent project buffer", function()
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(other, root .. "/src/unsaved.cr")
    vim.api.nvim_buf_set_lines(other, 0, -1, false, {
      "module App",
      "  class FromOther",
      "  end",
      "end",
    })
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "module App",
      "  FromOther.new",
      "end",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 2 })

    local target = definitions.find(buffer)
    assert.equals("FromOther", target.name)
    assert.equals(root .. "/src/unsaved.cr", target.path)
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("reuses unchanged project and unsaved-buffer indexes", function()
    definitions.clear_cache()
    local original_parser = vim.treesitter.get_string_parser
    local parse_count = 0
    vim.treesitter.get_string_parser = function(...)
      parse_count = parse_count + 1
      return original_parser(...)
    end

    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { 2, 12 })
      assert.equals("Widget", definitions.find(buffer).name)
      local initial_count = parse_count
      assert.is_true(initial_count > 0)

      assert.equals("Widget", definitions.find(buffer).name)
      assert.equals(initial_count, parse_count)
    end)
    vim.treesitter.get_string_parser = original_parser
    if not ok then
      error(err)
    end

  end)

  it("hydrates unchanged project indexes from disk", function()
    write(root .. "/src/app.cr", { "App::Widget.new" })
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "App::Widget.new" })
    vim.bo[buffer].modified = false
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    definitions.clear_cache()
    assert.equals("Widget", definitions.find(buffer).name)
    vim.wait(100)

    local original_parser = vim.treesitter.get_string_parser
    local parse_count = 0
    vim.treesitter.get_string_parser = function(...)
      parse_count = parse_count + 1
      return original_parser(...)
    end
    local ok, err = pcall(function()
      definitions.clear_cache()
      assert.equals("Widget", definitions.find(buffer).name)
      assert.equals(0, parse_count)
    end)
    vim.treesitter.get_string_parser = original_parser
    if not ok then
      error(err)
    end

    write(root .. "/src/types.cr", {
      "module App",
      "  class Replacement",
      "  end",
      "end",
    })
    definitions.clear_cache()
    assert.equals("Widget", definitions.find(buffer).name)
    vim.wait(300)
    assert.is_nil(definitions.find(buffer))
  end)

  it("reports progress while indexing large changed projects", function()
    for number = 1, 22 do
      write(root .. "/src/progress_" .. number .. ".cr", {
        "module App",
        "  class Progress" .. number,
        "  end",
        "end",
      })
    end
    definitions.clear_cache()
    local original_notify = vim.notify
    local messages = {}
    vim.notify = function(message)
      table.insert(messages, message)
      return #messages
    end

    vim.api.nvim_win_set_cursor(0, { 2, 12 })
    assert.equals("Widget", definitions.find(buffer).name)
    vim.notify = original_notify

    assert.equals("Indexing Crystal project...", messages[1])
    assert.equals("Crystal project indexed.", messages[#messages])
  end)

  it("does not persist failed Tree-sitter parses", function()
    definitions.clear_cache()
    local original_parser = vim.treesitter.get_string_parser
    vim.treesitter.get_string_parser = function()
      error("parser unavailable")
    end
    vim.api.nvim_win_set_cursor(0, { 2, 12 })
    assert.is_nil(definitions.find(buffer))
    vim.treesitter.get_string_parser = original_parser

    definitions.clear_cache()
    assert.equals("Widget", definitions.find(buffer).name)
  end)

  it("refreshes a cached project file when it changes on disk", function()
    definitions.clear_cache()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "App::Widget" })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    assert.equals("Widget", definitions.find(buffer).name)

    write(root .. "/src/types.cr", {
      "module App",
      "  class Replacement",
      "  end",
      "end",
    })

    assert.is_nil(definitions.find(buffer))
  end)

  it("indexes Crystal files added after the project cache is created", function()
    definitions.clear_cache()
    vim.api.nvim_win_set_cursor(0, { 2, 12 })
    assert.equals("Widget", definitions.find(buffer).name)

    write(root .. "/src/later.cr", {
      "module App",
      "  class Later",
      "  end",
      "end",
    })
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "App::Later" })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })

    assert.equals("Later", definitions.find(buffer).name)
  end)

  it("falls back to an enabled standard library index", function()
    local stdlib = root .. "/stdlib"
    write(stdlib .. "/string.cr", {
      "abstract class String",
      "  def initialize",
      "  end",
      "",
      "  def upcase",
      "  end",
      "end",
      "",
      "STDOUT = \"stdout\"",
      "",
      "module Time",
      "  class Span",
      "    ZERO = 0",
      "  end",
      "end",
      "",
      "module Parent",
      "  class Child",
      "  end",
      "  VALUE = 1",
      "end",
      "",
      "macro helper",
      "end",
    })
    write(stdlib .. "/string_extension.cr", {
      "class String",
      "end",
    })
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "value = String.new",
      "value.upcase",
    })
    definitions.clear_cache()
    definitions.setup({ paths = { stdlib } })

    vim.api.nvim_win_set_cursor(0, { 1, 16 })
    local initialize = definitions.find(buffer)
    assert.equals("initialize", initialize.name)
    assert.equals(stdlib .. "/string.cr", initialize.path)

    vim.api.nvim_win_set_cursor(0, { 2, 9 })
    local upcase = definitions.find(buffer)
    assert.equals("upcase", upcase.name)
    assert.equals(stdlib .. "/string.cr", upcase.path)

    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "STDOUT" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local stdout = definitions.find(buffer)
    assert.equals("STDOUT", stdout.name)
    assert.equals(stdlib .. "/string.cr", stdout.path)

    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "Time::Span::ZERO" })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    local span = definitions.find(buffer)
    assert.equals("Span", span.name)
    assert.equals(stdlib .. "/string.cr", span.path)

    vim.api.nvim_win_set_cursor(0, { 1, 13 })
    local zero = definitions.find(buffer)
    assert.equals("ZERO", zero.name)
    assert.equals(stdlib .. "/string.cr", zero.path)

    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "Parent::VALUE" })
    vim.api.nvim_win_set_cursor(0, { 1, 9 })
    local value = definitions.find(buffer)
    assert.equals("VALUE", value.name)
    assert.equals(stdlib .. "/string.cr", value.path)

    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "helper" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local helper = definitions.find(buffer)
    assert.equals("helper", helper.name)
    assert.equals(stdlib .. "/string.cr", helper.path)

    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "String" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local original_select = vim.ui.select
    local selected
    vim.ui.select = function(items, options)
      selected = { items = items, options = options }
    end
    definitions.jump(buffer)
    vim.ui.select = original_select
    assert.matches("stdlib/string", selected.options.format_item(selected.items[1]))
    definitions.setup()
  end)

  it("discovers standard library roots from CRYSTAL_PATH", function()
    local stdlib = vim.fn.tempname()
    write(stdlib .. "/prelude.cr", { "class String", "end" })
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "String" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    vim.fn.executable = function()
      return 1
    end
    vim.fn.systemlist = function()
      return { stdlib }
    end
    vim.fn.system("true")
    definitions.clear_cache()
    definitions.setup()

    local target = definitions.find(buffer)
    definitions.setup({ stdlib = false })
    assert.is_nil(definitions.find(buffer))
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    definitions.setup()
    vim.fn.delete(stdlib, "rf")

    assert.equals("String", target.name)
    assert.equals(stdlib .. "/prelude.cr", target.path)
  end)

  it("lists project definitions before matching standard library definitions", function()
    local stdlib = root .. "/stdlib"
    write(root .. "/src/local_string.cr", { "class String", "end" })
    write(stdlib .. "/prelude.cr", { "class String", "end" })
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "String" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local original_executable = vim.fn.executable
    local original_systemlist = vim.fn.systemlist
    vim.fn.executable = function()
      return 1
    end
    vim.fn.systemlist = function()
      return { stdlib }
    end
    vim.fn.system("true")
    definitions.clear_cache()
    definitions.setup({ stdlib = true })

    local targets = definitions.candidates(buffer)
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    definitions.setup()

    assert.equals(root .. "/src/local_string.cr", targets[1].path)
    assert.equals(stdlib .. "/prelude.cr", targets[2].path)
  end)

  it("jumps without changing source text", function()
    local source = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
    vim.bo[buffer].modified = false
    vim.api.nvim_win_set_cursor(0, { 2, 12 })

    assert.is_true(definitions.jump(buffer))
    assert.same(source, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    assert.equals(root .. "/src/types.cr", vim.api.nvim_buf_get_name(0))
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("preserves a modified buffer when jumping", function()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "module App",
      "  Widget.new",
      "end",
    })
    local source = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
    vim.api.nvim_win_set_cursor(0, { 2, 2 })

    definitions.jump(buffer)
    assert.same(source, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  end)
end)
