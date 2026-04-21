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

M.exit_codes = { 0, 1 }

M.parser = function(output, bufnr)
  if not output or output == "" then
    return {}
  end

  local ok, data = pcall(vim.json.decode, output)
  if not ok or not data or not data.sources then
    return {}
  end

  local diagnostics = {}

  for _, source in ipairs(data.sources) do
    if source.issues then
      for _, issue in ipairs(source.issues) do
        local severity = "info"
        if issue.severity == "Error" then
          severity = "error"
        elseif issue.severity == "Warning" then
          severity = "warning"
        end

        local diagnostic = {
          message = issue.message,
          severity = severity,
          code = issue.rule_name,
          source = "ameba",
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
