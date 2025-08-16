local M = {}

-- Store original buffer contents for comparison
local buffer_snapshots = {}

---Capture the current state of a buffer for later comparison
---@param bufnr number Buffer number
---@return string|nil The buffer content as a string, or nil if invalid buffer
function M.capture_buffer_snapshot(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")
  local filepath = vim.api.nvim_buf_get_name(bufnr)

  if filepath and filepath ~= "" then
    buffer_snapshots[bufnr] = {
      content = content,
      filepath = filepath,
      timestamp = vim.fn.localtime(),
    }
  end

  return content
end

---Detect changes in a buffer by comparing with stored snapshot
---@param bufnr number Buffer number
---@return table|nil Change information or nil if no changes
function M.detect_buffer_changes(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local snapshot = buffer_snapshots[bufnr]
  if not snapshot then
    return nil
  end

  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local current_content = table.concat(current_lines, "\n")

  if current_content == snapshot.content then
    return nil -- No changes
  end

  -- Generate diff using Neovim's built-in diff
  local diff_result = vim.diff(snapshot.content, current_content, {
    result_type = "unified",
    algorithm = "myers",
  })

  if not diff_result or diff_result == "" then
    return nil
  end

  return {
    bufnr = bufnr,
    filepath = snapshot.filepath,
    original_content = snapshot.content,
    current_content = current_content,
    diff = diff_result,
    timestamp = vim.fn.localtime(),
  }
end

---Get all buffers with detected changes
---@return table[] Array of change information tables
function M.get_all_changes()
  local changes = {}

  for bufnr, _ in pairs(buffer_snapshots) do
    local change = M.detect_buffer_changes(bufnr)
    if change then
      table.insert(changes, change)
    end
  end

  return changes
end

---Clear stored snapshot for a buffer
---@param bufnr number Buffer number
function M.clear_buffer_snapshot(bufnr)
  buffer_snapshots[bufnr] = nil
end

---Clear all stored snapshots
function M.clear_all_snapshots()
  buffer_snapshots = {}
end

---Get snapshot info for debugging
---@return table Snapshot information
function M.get_snapshot_info()
  local info = {}
  for bufnr, snapshot in pairs(buffer_snapshots) do
    info[bufnr] = {
      filepath = snapshot.filepath,
      timestamp = snapshot.timestamp,
      content_length = #snapshot.content,
    }
  end
  return info
end

return M
