local M = {}

M.name = "ameba"

M.meta = {
  url = "https://github.com/crystal-ameba/ameba",
  description = "A static code analysis tool for Crystal",
}

M.cmd = function()
  local bufname = vim.api.nvim_buf_get_name(0)
  local dir = bufname ~= "" and vim.fn.fnamemodify(bufname, ":p:h") or vim.fn.getcwd()
  local local_ameba = vim.fs.joinpath(dir, "bin", "ameba")
  if vim.fn.filereadable(local_ameba) == 1 then
    return local_ameba
  end
  return "ameba"
end

M.args = {
  "--format",
  "json",
  "--stdin-filename",
  function()
    return vim.api.nvim_buf_get_name(0)
  end,
}

M.stdin = true

M.append_fname = false

M.ignore_exitcode = true

local severity_map = {
  Error = vim.diagnostic.severity.ERROR,
  Warning = vim.diagnostic.severity.WARN,
  Convention = vim.diagnostic.severity.HINT,
}

M.parser = function(output)
  local diagnostics = {}
  local decoded = vim.json.decode(output)

  if not decoded or not decoded.sources then
    return diagnostics
  end

  for _, source in ipairs(decoded.sources) do
    if source.issues then
      for _, issue in ipairs(source.issues) do
        local diagnostic = {
          source = "ameba",
          message = issue.message,
          severity = severity_map[issue.severity] or vim.diagnostic.severity.HINT,
          code = issue.rule_name,
        }

        local ok, loc = pcall(function()
          if not issue.location or not issue.location.line then
            return nil
          end
          local col = issue.location.column and issue.location.column - 1 or 0
          return {
            lnum = issue.location.line - 1,
            col = col,
          }
        end)

        if ok and loc then
          diagnostic.lnum = loc.lnum
          diagnostic.col = loc.col
          diagnostic.end_lnum = loc.lnum
          diagnostic.end_col = loc.col
        end

        local ok2, eloc = pcall(function()
          if not issue.end_location or not issue.end_location.line then
            return nil
          end
          return {
            end_lnum = issue.end_location.line - 1,
            end_col = issue.end_location.column and issue.end_location.column - 1 or 0,
          }
        end)

        if ok2 and eloc then
          diagnostic.end_lnum = eloc.end_lnum
          diagnostic.end_col = eloc.end_col
        end

        table.insert(diagnostics, diagnostic)
      end
    end
  end

  return diagnostics
end

return M
