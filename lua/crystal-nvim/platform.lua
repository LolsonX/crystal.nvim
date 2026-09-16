local M = {}

function M.libc_target(uname, ldd_output)
  local system = uname.sysname:lower()
  local raw_machine = uname.machine:lower()
  local machine = raw_machine:gsub("amd64", "x86_64")
  if system == "linux" then
    local family = ldd_output:lower():find("musl", 1, true) and "musl" or "gnu"
    return machine .. "-linux-" .. family
  end
  if system == "darwin" then
    return machine .. "-darwin"
  end
  if system == "openbsd" then
    return raw_machine .. "-unknown-openbsd"
  end
  if system == "windows_nt" then
    return machine .. "-windows-gnu"
  end
  return machine .. "-" .. system
end

return M
