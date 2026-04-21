local M = {}

M.name = "ameba"

M.meta = {
  url = "https://github.com/crystal-ameba/ameba",
  description = "A static code analysis tool for Crystal",
}

M.cmd = "ameba"

M.args = { "--format", "json", "--stdin-filename", "$FILENAME" }

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

        if issue.location then
          diagnostic.lnum = issue.location.line - 1
          diagnostic.col = issue.location.column - 1
          diagnostic.end_lnum = diagnostic.lnum
          diagnostic.end_col = diagnostic.col
        end

        if issue.end_location then
          diagnostic.end_lnum = issue.end_location.line - 1
          diagnostic.end_col = issue.end_location.column - 1
        end

        table.insert(diagnostics, diagnostic)
      end
    end
  end

  return diagnostics
end

return M
