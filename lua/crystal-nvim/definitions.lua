local M = {}
local project_cache = {}
local stdlib_cache = {}
local disk_cache = {}
local disk_cache_write_pending = false
local pending_disk_projects = {}
local cache_clock = 0
local cache_generation = 0
local max_cached_projects = 8
local disk_cache_version = 3
local stdlib_cache_version = 4
local stdlib_enabled = true
local stdlib_paths
local definition_mapping = "gd"
local implementation_mapping = "gD"
local managed_mappings = {}

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
  alias = "alias",
  alias_def = "alias",
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
  local superclass = kind == "class" and node:field("superclass")[1]
  if superclass then
    symbol.superclass = normalize_name(vim.treesitter.get_node_text(superclass, source))
  end
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
    if node:type() == "include" and owner then
      local target = node:named_child(0)
      if target then
        local name = normalize_name(vim.treesitter.get_node_text(target, source))
        add_to_index(index, {
          name = name,
          full_name = owner .. "::include:" .. name,
          kind = "include",
          owner = owner,
          path = path,
          row = select(1, node:range()),
          col = select(2, node:range()),
          end_row = select(3, node:range()),
          end_col = select(4, node:range()),
          preview = "include " .. name,
        })
      end
    end
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
    local symbol = stored
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

local function stdlib_cache_path(root)
  local directory = vim.g.crystal_nvim_cache_dir or vim.fs.joinpath(vim.fn.stdpath("cache"), "crystal-nvim", "definitions")
  return vim.fs.joinpath(directory, "stdlib-" .. vim.fn.sha256(root) .. ".mpack")
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

local function load_stdlib_cache(root)
  local ok, lines = pcall(vim.fn.readfile, stdlib_cache_path(root), "b")
  if not ok then
    return nil
  end
  local decoded_ok, stored = pcall(function()
    return vim.mpack.decode(vim.base64.decode(table.concat(lines)))
  end)
  if not decoded_ok or type(stored) ~= "table" or stored.version ~= stdlib_cache_version or type(stored.paths) ~= "table" then
    return nil
  end
  local files = {}
  for path, file in pairs(stored.files or {}) do
    if type(path) == "string" and type(file) == "table" and type(file.signature) == "string" and type(file.symbols) == "table" then
      local restored, index = pcall(restore_index, file.symbols)
      if restored then
        files[path] = { signature = file.signature, index = index }
      end
    end
  end
  stored.files = files
  stored.checked_at = vim.uv.now()
  return stored
end

local function persist_stdlib_cache(root, cache)
  local path = stdlib_cache_path(root)
  local generation = cache_generation
  vim.defer_fn(function()
    if generation ~= cache_generation then
      return
    end
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local files = {}
    for file_path, file in pairs(cache.files) do
      files[file_path] = { signature = file.signature, symbols = stored_symbols(file.index) }
    end
    local ok, encoded = pcall(vim.mpack.encode, {
      version = stdlib_cache_version,
      paths = cache.paths,
      types = cache.types,
      methods = cache.methods,
      constants = cache.constants,
      files = files,
    })
    if ok then
      local temp = path .. "." .. vim.uv.os_getpid() .. "." .. vim.uv.hrtime()
      if vim.fn.writefile({ vim.base64.encode(encoded) }, temp) == 0 and vim.uv.fs_rename(temp, path) then
        return
      end
      vim.fn.delete(temp)
    end
  end, 10)
end

local function save_disk_cache()
  if disk_cache_write_pending then
    return
  end
  disk_cache_write_pending = true
  vim.defer_fn(function()
    disk_cache_write_pending = false
    for root, pending in pairs(pending_disk_projects) do
      if pending.generation ~= cache_generation then
        pending_disk_projects[root] = nil
        goto continue
      end
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
      ::continue::
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
  return { files = files, paths = paths, buffers = {}, needs_validation = true }
end

local function persist_project(root, cache)
  pending_disk_projects[root] = { cache = cache, path = cache_path(root), generation = cache_generation }
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

local function start_indexing(root, cache)
  if cache.loading then
    return
  end
  local paths = vim.fn.globpath(root, "**/*.cr", false, true)
  local state = {
    position = 1,
    seen = {},
    changed = false,
    progress = indexing_progress(#paths),
    generation = cache_generation,
  }
  cache.loading = state
  state.progress()

  local function finish()
    if state.generation ~= cache_generation or project_cache[root] ~= cache then
      return
    end
    for path in pairs(cache.files) do
      if not state.seen[path] then
        cache.files[path] = nil
        state.changed = true
      end
    end
    cache.paths = vim.tbl_keys(cache.files)
    table.sort(cache.paths)
    cache.loading = nil
    cache.initialized = true
    cache.checked_at = vim.uv.now()
    if state.changed then
      cache.index = nil
      persist_project(root, cache)
    end
    state.progress(true)
  end

  local function process()
    if cache.loading ~= state or state.generation ~= cache_generation or project_cache[root] ~= cache then
      if cache.loading == state then
        cache.loading = nil
      end
      return
    end
    local last = math.min(state.position + 23, #paths)
    for position = state.position, last do
      local absolute = vim.fn.fnamemodify(paths[position], ":p")
      local index, changed = cached_file_index(cache, absolute)
      if index then
        state.changed = state.changed or changed
        state.seen[absolute] = true
      end
    end
    state.position = last + 1
    if state.position > #paths then
      finish()
    else
      vim.defer_fn(process, 0)
    end
  end

  state.process = process
  vim.defer_fn(process, 0)
end

local function cache_has_changes(root, cache)
  local paths = vim.fn.globpath(root, "**/*.cr", false, true)
  if #paths ~= #cache.paths then
    return true
  end
  for _, path in ipairs(paths) do
    local absolute = vim.fn.fnamemodify(path, ":p")
    local file = cache.files[absolute]
    if not file or file.signature ~= file_signature(absolute) then
      return true
    end
  end
  return false
end

local function cached_project(root)
  local cache = project_cache[root] or hydrate_project(root)
  project_cache[root] = cache
  cache_clock = cache_clock + 1
  cache.last_used = cache_clock
  if not cache.validation_scheduled and (cache.needs_validation or not cache.initialized or (not cache.loading and cache_has_changes(root, cache))) then
    local delay = cache.needs_validation and 250 or 0
    cache.needs_validation = nil
    cache.validation_scheduled = true
    local function begin()
      cache.validation_scheduled = nil
      start_indexing(root, cache)
    end
    if delay == 0 then
      begin()
    else
      vim.defer_fn(begin, delay)
    end
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

local function libc_platform()
  local uname = vim.uv.os_uname()
  local system = uname.sysname:lower()
  if system == "linux" then
    return uname.machine .. "-linux-gnu"
  end
  if system == "darwin" then
    return uname.machine .. "-darwin"
  end
  return uname.machine .. "-" .. system
end

local function stdlib_source_map(root)
  local cache = stdlib_cache[root] or load_stdlib_cache(root) or { files = {} }
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
    local platform = path:match("/lib_c/([^/]+)/")
    if not platform or platform == libc_platform() then
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
  end
  persist_stdlib_cache(root, cache)
  return cache
end

local function index_stdlib(kind, name)
  local index = new_index()
  for _, root in ipairs(standard_library_paths()) do
    local cache = stdlib_source_map(root)
    local changed = false
    local paths = (kind == "type" and cache.types or cache.methods)[name] or {}
    for _, path in ipairs(paths) do
      local file_index, file_changed = cached_file_index(cache, path)
      if file_index then
        changed = changed or file_changed
        add_symbols(index, file_index)
      end
    end
    if kind == "type" then
      for _, path in ipairs(cache.constants[name] or {}) do
        local file_index, file_changed = cached_file_index(cache, path)
        if file_index then
          changed = changed or file_changed
          add_symbols(index, file_index)
        end
      end
    end
    if changed then
      persist_stdlib_cache(root, cache)
    end
  end
  return index
end

local function required_path(root, path, require_path)
  local base = require_path:sub(1, 1) == "." and vim.fs.dirname(path) or root .. "/src"
  local candidate = vim.fn.fnamemodify(vim.fs.joinpath(base, require_path), ":p")
  if not candidate:match("%.cr$") then
    candidate = candidate .. ".cr"
  end
  if candidate:sub(1, #root + 1) == root .. "/" and vim.uv.fs_stat(candidate) then
    return candidate
  end
end

local function required_paths(root, path, source)
  local paths = {}
  local seen = {}
  local has_require = false
  local function visit(current_path, current_source)
    if seen[current_path] then
      return
    end
    seen[current_path] = true
    paths[#paths + 1] = current_path
    for require_path in current_source:gmatch("require%s+[%\"']([^%\"']+)") do
      local resolved = required_path(root, current_path, require_path)
      if resolved then
        has_require = true
        visit(resolved, disk_source(resolved))
      end
    end
  end
  visit(path, source)
  return has_require and paths or nil
end

local function index_project(root, bufnr)
  local cache = cached_project(root)
  if cache.loading then
    while cache.loading do
      cache.loading.process()
    end
    cache = cached_project(root)
    while cache.loading do
      cache.loading.process()
    end
  end
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

  local paths = required_paths(root, current_path, source_for(current_path, bufnr)) or cache.paths

  if paths == cache.paths and not next(overlays) and cache.index then
    return cache.index
  end

  for bufnr_key, buffer in pairs(cache.buffers) do
    if not vim.api.nvim_buf_is_valid(bufnr_key) or not vim.api.nvim_buf_is_loaded(bufnr_key) or vim.api.nvim_buf_get_name(bufnr_key) ~= buffer.path then
      cache.buffers[bufnr_key] = nil
    end
  end

  local index = new_index(true)
  for _, path in ipairs(paths) do
    local file = overlays[path] or cache.files[path]
    if file then
      add_symbols(index, file.index or file)
      overlays[path] = nil
    end
  end
  local overlay_paths = vim.tbl_keys(overlays)
  table.sort(overlay_paths)
  for _, path in ipairs(overlay_paths) do
    add_symbols(index, overlays[path])
  end
  if paths == cache.paths and #overlay_paths == 0 then
    cache.index = index
  end
  return index
end

function M.prewarm(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return
  end
  cached_project(M.root(vim.fn.fnamemodify(path, ":p")))
end

function M.clear_cache()
  project_cache = {}
  stdlib_cache = {}
  disk_cache = {}
  pending_disk_projects = {}
  cache_clock = 0
end

function M.clear_disk_cache()
  cache_generation = cache_generation + 1
  M.clear_cache()
  local directory = vim.g.crystal_nvim_cache_dir or vim.fs.joinpath(vim.fn.stdpath("cache"), "crystal-nvim", "definitions")
  for _, path in ipairs(vim.fn.globpath(directory, "*.mpack", false, true)) do
    local name = vim.fs.basename(path)
    if name:match("^[0-9a-fA-F]+%.mpack$") or name:match("^stdlib%-[0-9a-fA-F]+%.mpack$") then
      vim.fn.delete(path)
    end
  end
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
      local normalized = normalize_name(qualified_name)
      for _, scope in ipairs(scopes) do
        local matches = index.by_full[scope.full_name .. "::" .. normalized]
        if matches then
          return matches
        end
      end
      return index.by_full[normalized] or {}
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

local function hierarchy_name(index, name, owner)
  if index.by_full[name] then
    return name
  end
  local namespace = owner:match("^(.*)::")
  return namespace and index.by_full[namespace .. "::" .. name] and namespace .. "::" .. name or name
end

function M.implementations(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return {}
  end
  local name = token_at_cursor(bufnr)
  if not name or name:match("^[A-Z]") then
    return {}
  end
  local absolute = vim.fn.fnamemodify(path, ":p")
  local index = index_project(M.root(absolute), bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local scopes = scopes_at(index, absolute, row)
  local owner
  for _, scope in ipairs(scopes) do
    if scope.kind == "class" or scope.kind == "module" then
      owner = scope.full_name
      break
    end
  end
  if not owner then
    return {}
  end

  local results = {}
  local seen = {}
  local function visit(type_name)
    if seen[type_name] then
      return
    end
    seen[type_name] = true
    for _, method in ipairs(index.by_full[type_name .. "." .. name] or {}) do
      table.insert(results, method)
    end
    local type_symbol = one(index.by_full[type_name])
    if type_symbol and type_symbol.superclass then
      visit(hierarchy_name(index, type_symbol.superclass, type_name))
    end
    for _, include in ipairs(index.symbols) do
      if include.kind == "include" and include.owner == type_name then
        visit(hierarchy_name(index, include.name, type_name))
      end
    end
  end
  visit(owner)
  return results
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
        return absolute:sub(#prefix + 1)
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

local function target_group(path, project_root)
  local absolute = vim.fn.fnamemodify(path, ":p")
  if stdlib_enabled then
    for _, root in ipairs(standard_library_paths()) do
      if absolute:sub(1, #root + 1) == root .. "/" then
        return "stdlib", 3
      end
    end
  end
  if project_root and absolute:sub(1, #project_root + 5) == project_root .. "/lib/" then
    return "shard", 2
  end
  return "project", 1
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

  local project_root = M.root(vim.api.nvim_buf_get_name(bufnr))
  table.sort(targets, function(first, second)
    local _, first_rank = target_group(first.path, project_root)
    local _, second_rank = target_group(second.path, project_root)
    if first_rank ~= second_rank then
      return first_rank < second_rank
    end
    return first.path < second.path
  end)
  vim.ui.select(targets, {
    prompt = "Select Crystal definition",
    format_item = function(target)
      local group = target_group(target.path, project_root)
      local owner = target.owner and target.owner .. "::" or ""
      return string.format("[%s] %s %s%s  %s:%d", group, target.kind, owner, target.name, display_path(target.path, project_root), target.row + 1)
    end,
  }, function(target)
    if target then
      jump_to(target)
    end
  end)
  return true
end

local function map_definition(bufnr)
  for lhs, rhs in pairs(managed_mappings[bufnr] or {}) do
    if vim.fn.maparg(lhs, "n", false, true).rhs == rhs then
      pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
    end
  end
  managed_mappings[bufnr] = {}
  local mappings = {}
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    mappings[mapping.lhs] = true
  end
  local function set_mapping(lhs, callback, desc)
    if lhs and not mappings[lhs] then
      vim.keymap.set("n", lhs, callback, { buffer = bufnr, desc = desc })
      managed_mappings[bufnr][lhs] = vim.fn.maparg(lhs, "n", false, true).rhs
    end
  end
  if definition_mapping then
    set_mapping(definition_mapping, function()
      M.jump(bufnr)
    end, "Crystal definition")
  end
  if implementation_mapping then
    set_mapping(implementation_mapping, function()
      local target = one(M.implementations(bufnr))
      if target then
        jump_to(target)
      else
        vim.notify("crystal.nvim: implementation not found", vim.log.levels.INFO)
      end
    end, "Crystal implementation")
  end
end

function M.setup(options)
  options = options or {}
  stdlib_enabled = options.stdlib ~= false
  stdlib_paths = options.paths
  local mappings = options.mappings or {}
  if mappings.definition == false then
    definition_mapping = nil
  else
    definition_mapping = mappings.definition or "gd"
  end
  if mappings.implementation == false then
    implementation_mapping = nil
  else
    implementation_mapping = mappings.implementation or "gD"
  end
  stdlib_cache = {}
  vim.api.nvim_create_user_command("CrystalDefinitionsClearCache", function()
    M.clear_disk_cache()
    vim.notify("crystal.nvim: definition caches cleared", vim.log.levels.INFO)
  end, { desc = "Clear Crystal definition caches", force = true })
  local group = vim.api.nvim_create_augroup("CrystalNvimDefinitions", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "crystal",
    callback = function(event)
      map_definition(event.buf)
      M.prewarm(event.buf)
    end,
  })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "crystal" then
      map_definition(bufnr)
      M.prewarm(bufnr)
    end
  end
end

return M
