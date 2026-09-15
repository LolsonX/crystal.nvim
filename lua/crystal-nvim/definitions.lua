local M = {}
local project_cache = {}
local stdlib_cache = {}
local disk_cache = {}
local disk_cache_write_pending = false
local pending_disk_projects = {}
local cache_clock = 0
local max_cached_projects = 8
local disk_cache_version = 1
local stdlib_enabled = true
local stdlib_paths

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

local function disk_source(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and table.concat(lines, "\n") or ""
end

local function source_for(path, bufnr)
  local absolute = vim.fn.fnamemodify(path, ":p")
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p") == absolute then
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end
  return disk_source(absolute)
end

local function join_scope(scope, name)
  if name:find("::", 1, true) then
    return name
  end
  return scope and scope ~= "" and scope .. "::" .. name or name
end

local function new_index(with_paths)
  return { symbols = {}, by_full = {}, by_name = {}, by_path = with_paths and {} or nil }
end

local function routine_id(symbol)
  return string.format("%s:%d:%d:%s", symbol.path, symbol.row, symbol.col, symbol.kind)
end

local function add_to_index(index, symbol, include_full_name)
  table.insert(index.symbols, symbol)
  index.by_name[symbol.name] = index.by_name[symbol.name] or {}
  table.insert(index.by_name[symbol.name], symbol)
  if include_full_name ~= false then
    index.by_full[symbol.full_name] = index.by_full[symbol.full_name] or {}
    table.insert(index.by_full[symbol.full_name], symbol)
  end
  if index.by_path then
    local path = index.by_path[symbol.path] or { scopes = {}, routines = {} }
    index.by_path[symbol.path] = path
    if scope_kinds[symbol.kind] then
      table.insert(path.scopes, symbol)
    elseif symbol.kind == "method" or symbol.kind == "macro" or symbol.kind == "fun" then
      table.insert(path.routines, symbol)
    end
  end
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
  add_to_index(index, symbol)
  return symbol
end

local function add_parameters(index, method, lines)
  local header = lines[method.row + 1] or ""
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
      add_to_index(index, symbol, false)
      offset = start and start + #name or offset
    end
  end
end

local function parse_source(index, source, path)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "crystal")
  if not ok then
    return false
  end
  local lines = vim.split(source, "\n", { plain = true })
  local tree = parser:parse()[1]
  if not tree then
    return false
  end

  local function visit(node, owner, routine)
    local kind = declaration_kinds[node:type()]
    local symbol = kind and add_symbol(index, node, source, path, kind, owner, routine)
    if symbol and kind == "method" then
      add_parameters(index, symbol, lines)
    end
    local child_owner = symbol and scope_kinds[kind] and symbol.full_name or owner
    local child_routine = symbol and (kind == "method" or kind == "macro" or kind == "fun") and symbol or routine

    for child in node:iter_children() do
      visit(child, child_owner, child_routine)
    end
  end

  visit(tree:root(), nil)
  return true
end

local function parse_file(source, path)
  local index = new_index()
  return index, parse_source(index, source, path)
end

local function restore_index(symbols)
  local index = new_index()
  local routines = {}
  local pending = {}
  for _, stored in ipairs(symbols) do
    local symbol = vim.deepcopy(stored)
    local id = symbol.routine_id
    symbol.routine_id = nil
    add_to_index(index, symbol, symbol.kind ~= "parameter")
    if symbol.kind == "method" or symbol.kind == "macro" or symbol.kind == "fun" then
      routines[routine_id(symbol)] = symbol
    end
    if id then
      table.insert(pending, { symbol = symbol, routine_id = id })
    end
  end
  for _, item in ipairs(pending) do
    item.symbol.routine = routines[item.routine_id]
  end
  return index
end

local function stored_symbols(index)
  local symbols = {}
  for _, symbol in ipairs(index.symbols) do
    local stored = vim.deepcopy(symbol)
    stored.routine_id = symbol.routine and routine_id(symbol.routine) or nil
    stored.routine = nil
    table.insert(symbols, stored)
  end
  return symbols
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

local function file_signature(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  return string.format("%d:%d:%d:%d:%d", stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec, stat.size), stat
end

local function cache_path(root)
  local directory = vim.g.crystal_nvim_cache_dir or vim.fs.joinpath(vim.fn.stdpath("cache"), "crystal-nvim", "definitions")
  return vim.fs.joinpath(directory, vim.fn.sha256(root) .. ".mpack")
end

local function load_disk_cache(root)
  if disk_cache[root] ~= nil then
    return disk_cache[root] or nil
  end
  local ok, lines = pcall(vim.fn.readfile, cache_path(root), "b")
  if not ok then
    disk_cache[root] = false
    return nil
  end
  local decoded_ok, stored = pcall(function()
    return vim.mpack.decode(vim.base64.decode(table.concat(lines)))
  end)
  if decoded_ok and type(stored) == "table" and stored.version == disk_cache_version and stored.root == root and type(stored.files) == "table" then
    disk_cache[root] = stored
    return stored
  end
  disk_cache[root] = false
end

local function save_disk_cache()
  if disk_cache_write_pending then
    return
  end
  disk_cache_write_pending = true
  vim.defer_fn(function()
    disk_cache_write_pending = false
    for root, pending in pairs(pending_disk_projects) do
      local cache = pending.cache
      local files = {}
      for path, file in pairs(cache.files) do
        files[path] = { signature = file.signature, symbols = stored_symbols(file.index) }
      end
      local stored = { version = disk_cache_version, root = root, files = files }
      disk_cache[root] = stored
      pending_disk_projects[root] = nil
      if vim.uv.fs_stat(root) then
        local path = pending.path
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        local temp = path .. "." .. vim.uv.hrtime() .. ".tmp"
        local ok, encoded = pcall(vim.mpack.encode, stored)
        if ok and vim.fn.writefile({ vim.base64.encode(encoded) }, temp) == 0 and vim.uv.fs_rename(temp, path) then
          -- Atomic rename completed.
        else
          vim.uv.fs_unlink(temp)
        end
      end
    end
  end, 10)
end

local function hydrate_project(root)
  local stored = load_disk_cache(root)
  if not stored then
    return { files = {}, buffers = {} }
  end
  local files = {}
  for path, file in pairs(stored.files) do
    if type(path) ~= "string" or type(file) ~= "table" or type(file.signature) ~= "string" or type(file.symbols) ~= "table" then
      return { files = {}, buffers = {} }
    end
    local ok, index = pcall(restore_index, file.symbols)
    if not ok then
      return { files = {}, buffers = {} }
    end
    files[path] = { signature = file.signature, index = index }
  end
  local paths = vim.tbl_keys(files)
  table.sort(paths)
  return { files = files, paths = paths, buffers = {} }
end

local function persist_project(root, cache)
  pending_disk_projects[root] = { cache = cache, path = cache_path(root) }
  save_disk_cache()
end

local function cached_file_index(cache, path, before_parse)
  local signature = file_signature(path)
  if not signature then
    return nil
  end
  local file = cache.files[path]
  if not file or file.signature ~= signature then
    if before_parse then
      before_parse()
    end
    local index, parsed = parse_file(disk_source(path), path)
    if not parsed then
      return nil, false
    end
    file = { signature = signature, index = index }
    cache.files[path] = file
    return file.index, true
  end
  return file.index, false
end

local function indexing_progress(total)
  if total < 25 then
    return function() end
  end
  return function(complete)
    vim.notify(
      complete and "Crystal project indexed." or "Indexing Crystal project...",
      vim.log.levels.INFO,
      { title = "crystal.nvim" }
    )
  end
end

local function cached_files(root, cache)
  local paths = vim.fn.globpath(root, "**/*.cr", false, true)
  local seen = {}
  local changed = false
  local progress
  local function started()
    if not progress then
      progress = indexing_progress(#paths)
      progress()
    end
  end

  for _, path in ipairs(paths) do
    local absolute = vim.fn.fnamemodify(path, ":p")
    local index, file_changed = cached_file_index(cache, absolute, started)
    if index then
      if file_changed then
        changed = true
      end
      seen[absolute] = true
    end
  end

  for path in pairs(cache.files) do
    if not seen[path] then
      cache.files[path] = nil
      changed = true
    end
  end

  cache.paths = vim.tbl_keys(cache.files)
  table.sort(cache.paths)
  if progress then
    progress(true)
  end
  return changed
end

local function cached_project(root)
  local cache = project_cache[root] or hydrate_project(root)
  project_cache[root] = cache
  cache_clock = cache_clock + 1
  cache.last_used = cache_clock
  if cached_files(root, cache) then
    persist_project(root, cache)
  end

  local count = 0
  local oldest_root
  local oldest_used
  for cached_root, cached in pairs(project_cache) do
    count = count + 1
    if not oldest_used or cached.last_used < oldest_used then
      oldest_root = cached_root
      oldest_used = cached.last_used
    end
  end
  if count > max_cached_projects then
    project_cache[oldest_root] = nil
  end

  return cache
end

local function cached_buffer(cache, bufnr, path)
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local buffer = cache.buffers[bufnr]
  if not buffer or buffer.path ~= path or buffer.changedtick ~= changedtick then
    buffer = {
      path = path,
      changedtick = changedtick,
      index = parse_file(source_for(path, bufnr), path),
    }
    cache.buffers[bufnr] = buffer
  end
  return buffer.index
end

local function add_symbols(index, file_index, deduplicate)
  for _, symbol in ipairs(file_index.symbols) do
    local duplicate = false
    if deduplicate then
      local existing_symbols = (symbol.kind == "parameter" and index.by_name[symbol.name] or index.by_full[symbol.full_name]) or {}
      for _, existing in ipairs(existing_symbols) do
        if existing.path == symbol.path and existing.row == symbol.row and existing.col == symbol.col and existing.kind == symbol.kind then
          duplicate = true
          break
        end
      end
    end
    if not duplicate then
      add_to_index(index, symbol, symbol.kind ~= "parameter")
    end
  end
end

local function standard_library_paths()
  if stdlib_paths then
    return stdlib_paths
  end
  if vim.fn.executable("crystal") ~= 1 then
    stdlib_paths = {}
    return stdlib_paths
  end

  local output = vim.fn.systemlist({ "crystal", "env", "CRYSTAL_PATH" })
  if vim.v.shell_error ~= 0 then
    stdlib_paths = {}
    return stdlib_paths
  end

  stdlib_paths = {}
  for _, path in ipairs(vim.split(output[1] or "", ":", { plain = true })) do
    if path:sub(1, 1) == "/" and vim.uv.fs_stat(path .. "/prelude.cr") then
      table.insert(stdlib_paths, path)
    end
  end
  return stdlib_paths
end

local function add_path(paths, name, path)
  paths[name] = paths[name] or {}
  table.insert(paths[name], path)
end

local function same_paths(first, second)
  if not first or #first ~= #second then
    return false
  end
  for index, path in ipairs(first) do
    if path ~= second[index] then
      return false
    end
  end
  return true
end

local function paths_signature(paths)
  local signatures = {}
  for _, path in ipairs(paths) do
    table.insert(signatures, file_signature(path) or "")
  end
  return table.concat(signatures, ";")
end

local function stdlib_source_map(root)
  local cache = stdlib_cache[root] or { files = {} }
  stdlib_cache[root] = cache
  local now = vim.uv.now()
  if cache.paths and now - cache.checked_at < 1000 then
    return cache
  end
  local paths = vim.fn.globpath(root, "**/*.cr", false, true)
  for index, path in ipairs(paths) do
    paths[index] = vim.fn.fnamemodify(path, ":p")
  end
  table.sort(paths)
  local signature = paths_signature(paths)
  cache.checked_at = now
  if same_paths(cache.paths, paths) and cache.source_signature == signature then
    return cache
  end
  cache.paths = paths
  cache.source_signature = signature
  cache.types = {}
  cache.methods = {}
  cache.constants = {}
  for _, path in ipairs(paths) do
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok then
      local scopes = {}
      for _, line in ipairs(lines) do
        local indent = #(line:match("^(%s*)") or "")
        local declaration = line:gsub("^%s*abstract%s+", ""):gsub("^%s*", "")
        local kind, name = declaration:match("^(%a+)%s+([%w_:]+)")
        if kind and declaration_kinds[kind .. "_def"] then
          while #scopes > 0 and scopes[#scopes].indent >= indent do
            table.remove(scopes)
          end
          local full_name = name:find("::", 1, true) and normalize_name(name) or join_scope(scopes[#scopes] and scopes[#scopes].name, name)
          add_path(cache.types, full_name, path)
          if full_name ~= name then
            add_path(cache.types, name, path)
          end
          if scope_kinds[declaration_kinds[kind .. "_def"]] then
            table.insert(scopes, { indent = indent, name = full_name })
          end
        end
        local constant = line:match("^%s*([A-Z][%w_]*)%s*=")
        if constant then
          while #scopes > 0 and scopes[#scopes].indent >= indent do
            table.remove(scopes)
          end
          local full_name = join_scope(scopes[#scopes] and scopes[#scopes].name, constant)
          add_path(cache.constants, full_name, path)
          if full_name ~= constant then
            add_path(cache.constants, constant, path)
          end
        end

        local header = line:match("^%s*def%s+([^%s(]+)") or line:match("^%s*macro%s+([^%s(]+)") or line:match("^%s*fun%s+([^%s(]+)")
        local method = header and header:match("([a-z_][%w_!?=]*)$")
        if method then
          add_path(cache.methods, method, path)
        end
      end
    end
  end
  return cache
end

local function index_stdlib(kind, name)
  local index = new_index()
  for _, root in ipairs(standard_library_paths()) do
    local cache = stdlib_source_map(root)
    local paths = (kind == "type" and cache.types or cache.methods)[name] or {}
    for _, path in ipairs(paths) do
      local file_index = cached_file_index(cache, path)
      if file_index then
        add_symbols(index, file_index)
      end
    end
    if kind == "type" then
      for _, path in ipairs(cache.constants[name] or {}) do
        local file_index = cached_file_index(cache, path)
        if file_index then
          add_symbols(index, file_index)
        end
      end
    end
  end
  return index
end

local function index_project(root, bufnr)
  local cache = cached_project(root)
  local current_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")
  local overlays = {}

  for _, loaded in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.api.nvim_buf_get_name(loaded)
    local absolute = path ~= "" and vim.fn.fnamemodify(path, ":p") or ""
    if vim.api.nvim_buf_is_loaded(loaded) and vim.bo[loaded].modified and absolute:sub(1, #root + 1) == root .. "/" and absolute:match("%.cr$") then
      overlays[absolute] = cached_buffer(cache, loaded, absolute)
    end
  end

  if current_path ~= "" and not cache.files[current_path] then
    overlays[current_path] = cached_buffer(cache, bufnr, current_path)
  end

  for bufnr_key, buffer in pairs(cache.buffers) do
    if not vim.api.nvim_buf_is_valid(bufnr_key) or not vim.api.nvim_buf_is_loaded(bufnr_key) or vim.api.nvim_buf_get_name(bufnr_key) ~= buffer.path then
      cache.buffers[bufnr_key] = nil
    end
  end

  local index = new_index(true)
  for _, path in ipairs(cache.paths) do
    add_symbols(index, overlays[path] or cache.files[path].index)
    overlays[path] = nil
  end
  local overlay_paths = vim.tbl_keys(overlays)
  table.sort(overlay_paths)
  for _, path in ipairs(overlay_paths) do
    add_symbols(index, overlays[path])
  end
  return index
end

function M.clear_cache()
  project_cache = {}
  stdlib_cache = {}
  disk_cache = {}
  pending_disk_projects = {}
  cache_clock = 0
end

local function one(items)
  return items and #items == 1 and items[1] or nil
end

local function scopes_at(index, path, row)
  local scopes = {}
  local available = index.by_path[path] and index.by_path[path].scopes or {}
  for position = #available, 1, -1 do
    local symbol = available[position]
    if symbol.row <= row and row <= symbol.end_row then
      table.insert(scopes, symbol)
    end
  end
  return scopes
end

local function routine_at(index, path, row)
  local routines = index.by_path[path] and index.by_path[path].routines or {}
  for index = #routines, 1, -1 do
    local routine = routines[index]
    if routine.row <= row and row <= routine.end_row then
      return routine
    end
  end
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

local function candidates_from(index, absolute, row, name, receiver, qualified_name)
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

local function stdlib_lookup(index, absolute, row, name, receiver, qualified_name)
  local scopes = scopes_at(index, absolute, row)
  if name:match("^[A-Z]") then
    return "type", qualified_name and normalize_name(qualified_name) or inferred_type(index, scopes, name)
  end
  if receiver and receiver ~= "self" then
    if receiver:match("^[A-Z]") then
      return "type", inferred_type(index, scopes, receiver)
    end
    local variable = local_variable(index, absolute, row, receiver)
    if variable and variable.value_type then
      return "type", inferred_type(index, scopes, variable.value_type)
    end
  end
  return "method", name
end

local function local_targets(targets)
  for _, target in ipairs(targets) do
    if target.kind ~= "variable" and target.kind ~= "parameter" then
      return false
    end
  end
  return #targets > 0
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
  local targets = candidates_from(index, absolute, row, name, receiver, qualified_name)
  if not stdlib_enabled or local_targets(targets) then
    return targets
  end

  local kind, lookup_name = stdlib_lookup(index, absolute, row, name, receiver, qualified_name)
  add_symbols(index, index_stdlib(kind, lookup_name), true)
  return candidates_from(index, absolute, row, name, receiver, qualified_name)
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

local function display_path(path, project_root)
  local absolute = vim.fn.fnamemodify(path, ":p")
  if stdlib_enabled then
    for _, root in ipairs(standard_library_paths()) do
      local prefix = root .. "/"
      if absolute:sub(1, #prefix) == prefix then
        return "stdlib/" .. absolute:sub(#prefix + 1)
      end
    end
  end
  if project_root then
    local prefix = project_root .. "/lib/"
    if absolute:sub(1, #prefix) == prefix then
      return absolute:sub(#prefix + 1)
    end
  end
  return vim.fn.fnamemodify(absolute, ":.")
end

function M.jump(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
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
      return string.format("%s  %s:%d", target.preview, display_path(target.path, M.root(vim.api.nvim_buf_get_name(bufnr))), target.row + 1)
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

function M.setup(options)
  options = options or {}
  stdlib_enabled = options.stdlib ~= false
  stdlib_paths = options.paths
  stdlib_cache = {}
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
