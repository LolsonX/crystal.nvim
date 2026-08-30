local M = {}

local declaration_kinds = {
  module_def = "module",
  class_def = "class",
  struct_def = "struct",
  enum_def = "enum",
  lib_def = "lib",
  union_def = "union",
  annotation_def = "annotation",
  method_def = "method",
  macro_def = "macro",
  fun_def = "fun",
  top_level_fun_def = "fun",
  const_assign = "constant",
  assign = "variable",
}

local scope_kinds = {
  module = true,
  class = true,
  struct = true,
  enum = true,
  lib = true,
  union = true,
  annotation = true,
}

local function normalize_name(name)
  return name:gsub("^::", ""):gsub("%b()", ""):gsub("%.$", "")
end

local function source_for(path, bufnr)
  local absolute = vim.fn.fnamemodify(path, ":p")
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p") == absolute then
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end

  local loaded = vim.fn.bufnr(absolute, false)
  if loaded ~= -1 and vim.api.nvim_buf_is_loaded(loaded) and vim.bo[loaded].modified then
    return table.concat(vim.api.nvim_buf_get_lines(loaded, 0, -1, false), "\n")
  end

  local ok, lines = pcall(vim.fn.readfile, absolute)
  return ok and table.concat(lines, "\n") or ""
end

local function join_scope(scope, name)
  if name:find("::", 1, true) then
    return name
  end
  return scope and scope ~= "" and scope .. "::" .. name or name
end

local function add_symbol(index, node, source, path, kind, owner, routine)
  local field = (kind == "constant" or kind == "variable") and "lhs" or "name"
  local name_node = node:field(field)[1]
  if not name_node then
    return nil
  end

  local name = normalize_name(vim.treesitter.get_node_text(name_node, source))
  if name == "" then
    return nil
  end

  local full_name
  if kind == "method" then
    local receiver = node:field("class")[1]
    local receiver_name = receiver and normalize_name(vim.treesitter.get_node_text(receiver, source)) or owner
    if receiver_name == "self" then
      receiver_name = owner
    elseif receiver_name and receiver_name ~= owner and not receiver_name:find("::", 1, true) then
      receiver_name = join_scope(owner, receiver_name)
    end
    full_name = receiver_name and receiver_name .. "." .. name or name
  elseif kind == "macro" or kind == "fun" then
    full_name = owner and owner .. "." .. name or name
  else
    full_name = join_scope(owner, name)
  end

  local sr, sc, er, ec = node:range()
  local preview = vim.treesitter.get_node_text(node, source):match("[^\r\n]+") or name
  local symbol = {
    name = name,
    full_name = full_name,
    kind = kind,
    owner = owner,
    path = path,
    row = sr,
    col = sc,
    end_row = er,
    end_col = ec,
    routine = routine,
    preview = vim.trim(preview),
  }
  if kind == "variable" then
    local rhs = node:field("rhs")[1]
    local value = rhs and vim.treesitter.get_node_text(rhs, source) or ""
    symbol.value_type = value:match("^%s*([A-Z][%w_:]*)%.new%f[%W]")
  end
  table.insert(index.symbols, symbol)
  index.by_full[full_name] = index.by_full[full_name] or {}
  table.insert(index.by_full[full_name], symbol)
  index.by_name[name] = index.by_name[name] or {}
  table.insert(index.by_name[name], symbol)
  return symbol
end

local function add_parameters(index, method, source)
  local header = vim.split(source, "\n", { plain = true })[method.row + 1] or ""
  local parameters = header:match("%b()")
  if not parameters then
    return
  end

  local offset = 1
  for parameter in parameters:sub(2, -2):gmatch("[^,]+") do
    local name = parameter:match("^%s*[*&]*%s*([a-z_][%w_]*)")
    if name then
      local start = header:find(name, offset, true)
      local symbol = {
        name = name,
        full_name = method.full_name .. "." .. name,
        kind = "parameter",
        owner = method.full_name,
        path = method.path,
        row = method.row,
        col = start and start - 1 or method.col,
        end_row = method.row,
        end_col = start and start - 1 + #name or method.col + #name,
        routine = method,
        preview = vim.trim(header),
      }
      table.insert(index.symbols, symbol)
      index.by_name[name] = index.by_name[name] or {}
      table.insert(index.by_name[name], symbol)
      offset = start and start + #name or offset
    end
  end
end

local function parse_source(index, source, path)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "crystal")
  if not ok then
    return
  end
  local tree = parser:parse()[1]
  if not tree then
    return
  end

  local function visit(node, owner, routine)
    local kind = declaration_kinds[node:type()]
    local symbol = kind and add_symbol(index, node, source, path, kind, owner, routine)
    if symbol and kind == "method" then
      add_parameters(index, symbol, source)
    end
    local child_owner = symbol and scope_kinds[kind] and symbol.full_name or owner
    local child_routine = symbol and (kind == "method" or kind == "macro" or kind == "fun") and symbol or routine

    for child in node:iter_children() do
      visit(child, child_owner, child_routine)
    end
  end

  visit(tree:root(), nil)
end

function M.root(path)
  local current = vim.fn.fnamemodify(path, ":p")
  if not current:match("/$") then
    current = vim.fs.dirname(current)
  end
  local git_root

  while current and current ~= "" do
    if vim.uv.fs_stat(current .. "/shard.yml") then
      return current
    end
    if not git_root and vim.uv.fs_stat(current .. "/.git") then
      git_root = current
    end
    local parent = vim.fs.dirname(current)
    if parent == current then
      break
    end
    current = parent
  end

  return git_root or vim.fn.fnamemodify(path, ":p:h")
end

local function index_project(root, bufnr)
  local index = { symbols = {}, by_full = {}, by_name = {} }
  local paths = vim.fn.globpath(root, "**/*.cr", false, true)
  local current_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
  local seen = {}

  for _, path in ipairs(paths) do
    local absolute = vim.fn.fnamemodify(path, ":p")
    local stat = vim.uv.fs_stat(absolute)
    if stat and stat.type == "file" then
      parse_source(index, source_for(absolute, bufnr), absolute)
      seen[absolute] = true
    end
  end
  if current_path ~= "" and not seen[current_path] then
    parse_source(index, source_for(current_path, bufnr), current_path)
    seen[current_path] = true
  end
  for _, loaded in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.api.nvim_buf_get_name(loaded)
    local absolute = path ~= "" and vim.fn.fnamemodify(path, ":p") or ""
    if vim.api.nvim_buf_is_loaded(loaded) and vim.bo[loaded].modified and absolute:sub(1, #root + 1) == root .. "/" and absolute:match("%.cr$") and not seen[absolute] then
      parse_source(index, source_for(absolute, bufnr), absolute)
      seen[absolute] = true
    end
  end

  return index
end

local function one(items)
  return items and #items == 1 and items[1] or nil
end

local function scopes_at(index, path, row)
  local scopes = {}
  for _, symbol in ipairs(index.symbols) do
    if symbol.path == path and scope_kinds[symbol.kind] and symbol.row <= row and row <= symbol.end_row then
      table.insert(scopes, symbol)
    end
  end
  table.sort(scopes, function(a, b)
    return a.row > b.row
  end)
  return scopes
end

local function routine_at(index, path, row)
  local routine
  for _, symbol in ipairs(index.symbols) do
    if symbol.path == path and (symbol.kind == "method" or symbol.kind == "macro" or symbol.kind == "fun") and symbol.row <= row and row <= symbol.end_row and (not routine or symbol.row > routine.row) then
      routine = symbol
    end
  end
  return routine
end

local function local_variable(index, path, row, name)
  local routine = routine_at(index, path, row)
  local nearest
  for _, symbol in ipairs(index.by_name[name] or {}) do
    if (symbol.kind == "variable" or symbol.kind == "parameter") and symbol.path == path and symbol.routine == routine and symbol.row <= row and (not nearest or symbol.row > nearest.row) then
      nearest = symbol
    end
  end
  return nearest
end

local function inferred_type(index, scopes, name)
  if name:find("::", 1, true) then
    return normalize_name(name)
  end
  for _, scope in ipairs(scopes) do
    local candidate = scope.full_name .. "::" .. name
    if index.by_full[candidate] then
      return candidate
    end
  end
  return name
end

local function token_at_cursor(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  local column = cursor[2]
  local patterns = { "[A-Z][%w_:]*", "[a-z_][%w_]*[!?=]?" }

  for _, pattern in ipairs(patterns) do
    local start, finish = line:find(pattern)
    while start do
      if column >= start - 1 and column < finish then
        local receiver = line:sub(1, start - 1):match("([%w_:]+)%s*%.$")
        local token = line:sub(start, finish)
        if token:find("::", 1, true) then
          local segment_start = 1
          while segment_start <= #token do
            local segment_end = token:find("::", segment_start, true) or (#token + 1)
            local absolute_start = start + segment_start - 1
            local absolute_end = start + segment_end - 2
            if column >= absolute_start - 1 and column < absolute_end then
              return token:sub(segment_start, segment_end - 1), receiver, token:sub(1, segment_end - 1)
            end
            segment_start = segment_end + 2
          end
        end
        return token, receiver
      end
      start, finish = line:find(pattern, finish + 1)
    end
  end

  local operators = { "[]?", "[]=", "[]", "<=>", "===", "&**", "**", "//", "<<", ">>", "<=", ">=", "==", "!=", "!~", "=~", "&+", "&-", "&*", "+", "-", "*", "/", "%", "&", "|", "^", "<", ">", "!", "~" }
  for _, operator in ipairs(operators) do
    local start, finish = line:find(operator, 1, true)
    while start do
      if column >= start - 1 and column < finish then
        return operator
      end
      start, finish = line:find(operator, finish + 1, true)
    end
  end
end

function M.candidates(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return {}
  end
  local name, receiver, qualified_name = token_at_cursor(bufnr)
  if not name then
    return {}
  end

  local absolute = vim.fn.fnamemodify(path, ":p")
  local index = index_project(M.root(absolute), bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local scopes = scopes_at(index, absolute, row)
  local method_name = name == "new" and "initialize" or name

  if name:match("^[A-Z]") then
    if qualified_name then
      return index.by_full[normalize_name(qualified_name)] or {}
    end
    for _, scope in ipairs(scopes) do
      local matches = index.by_full[scope.full_name .. "::" .. name]
      if matches then
        return matches
      end
    end
  else
    if receiver and receiver ~= "self" then
      if receiver:match("^[A-Z]") then
        return index.by_full[inferred_type(index, scopes, receiver) .. "." .. method_name] or {}
      end
      local variable = local_variable(index, absolute, row, receiver)
      if variable and variable.value_type then
        return index.by_full[inferred_type(index, scopes, variable.value_type) .. "." .. method_name] or {}
      end
      return {}
    end
    local variable = local_variable(index, absolute, row, name)
    if variable then
      return { variable }
    end
    for _, scope in ipairs(scopes) do
      local matches = index.by_full[scope.full_name .. "." .. name]
      if matches then
        return matches
      end
    end
  end

  return index.by_name[name] or {}
end

function M.find(bufnr)
  return one(M.candidates(bufnr))
end

local function jump_to(target)
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target.path))
  if not ok then
    vim.notify("crystal.nvim: could not open definition: " .. err, vim.log.levels.WARN)
    return false
  end
  vim.api.nvim_win_set_cursor(0, { target.row + 1, target.col })
  return true
end

function M.jump(bufnr)
  local targets = M.candidates(bufnr)
  if #targets == 0 then
    vim.notify("crystal.nvim: definition not found", vim.log.levels.INFO)
    return false
  end
  if #targets == 1 then
    return jump_to(targets[1])
  end

  vim.ui.select(targets, {
    prompt = "Select Crystal definition",
    format_item = function(target)
      return string.format("%s  %s:%d", target.preview, vim.fn.fnamemodify(target.path, ":."), target.row + 1)
    end,
  }, function(target)
    if target then
      jump_to(target)
    end
  end)
  return true
end

local function map_definition(bufnr)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if mapping.lhs == "gd" then
      return
    end
  end
  vim.keymap.set("n", "gd", function()
    M.jump(bufnr)
  end, { buffer = bufnr, desc = "Crystal definition" })
end

function M.setup()
  local group = vim.api.nvim_create_augroup("CrystalNvimDefinitions", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "crystal",
    callback = function(event)
      map_definition(event.buf)
    end,
  })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "crystal" then
      map_definition(bufnr)
    end
  end
end

return M
