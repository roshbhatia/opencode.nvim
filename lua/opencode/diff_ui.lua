local M = {}

-- Track active diff sessions
local active_sessions = {}

---Create a diff visualization for the given change
---@param change table Change information from diff.detect_buffer_changes()
---@return table|nil Session info or nil if failed
function M.create_diff_view(change)
  if not change then
    return nil
  end

  -- Create temporary buffers for original and modified content
  local original_buf = vim.api.nvim_create_buf(false, true)
  local modified_buf = vim.api.nvim_create_buf(false, true)

  -- Set buffer names for clarity
  local filename = vim.fn.fnamemodify(change.filepath, ":t")
  vim.api.nvim_buf_set_name(original_buf, string.format("[Original] %s", filename))
  vim.api.nvim_buf_set_name(modified_buf, string.format("[Modified] %s", filename))

  -- Populate buffers with content
  local original_lines = vim.split(change.original_content, "\n")
  local modified_lines = vim.split(change.current_content, "\n")

  vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, original_lines)
  vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, modified_lines)

  -- Make buffers read-only
  vim.api.nvim_set_option_value("readonly", true, { buf = original_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = original_buf })

  -- Modified buffer should be editable for accept/reject operations
  vim.api.nvim_set_option_value("readonly", false, { buf = modified_buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = modified_buf })

  -- Set buffer options for better diff experience
  local diff_options = {
    buftype = "nofile",
    bufhidden = "wipe",
    swapfile = false,
  }

  for opt, value in pairs(diff_options) do
    vim.api.nvim_set_option_value(opt, value, { buf = original_buf })
    vim.api.nvim_set_option_value(opt, value, { buf = modified_buf })
  end

  -- Create session info
  local session = {
    id = change.bufnr .. "_" .. change.timestamp,
    original_buf = original_buf,
    modified_buf = modified_buf,
    source_buf = change.bufnr,
    change = change,
    windows = {},
  }

  active_sessions[session.id] = session
  return session
end

---Open diff buffers in split windows
---@param session table Session info from create_diff_view()
---@return boolean Success
function M.open_diff_windows(session)
  if not session then
    return false
  end

  -- Save current window
  local original_win = vim.api.nvim_get_current_win()

  -- Create vertical split layout
  vim.cmd("vsplit")
  local left_win = vim.api.nvim_get_current_win()
  local right_win = original_win

  -- Set buffers in windows
  vim.api.nvim_win_set_buf(left_win, session.original_buf)
  vim.api.nvim_win_set_buf(right_win, session.modified_buf)

  -- Store window references
  session.windows.left = left_win
  session.windows.right = right_win

  -- Enable diff mode in both windows
  vim.api.nvim_win_call(left_win, function()
    vim.cmd("diffthis")
  end)
  vim.api.nvim_win_call(right_win, function()
    vim.cmd("diffthis")
  end)

  -- Set window options for better diff experience
  local win_options = {
    number = true,
    relativenumber = false,
    wrap = false,
    scrollbind = true,
    cursorbind = true,
  }

  for opt, value in pairs(win_options) do
    vim.api.nvim_set_option_value(opt, value, { win = left_win })
    vim.api.nvim_set_option_value(opt, value, { win = right_win })
  end

  -- Focus on the modified buffer (right window)
  vim.api.nvim_set_current_win(right_win)

  return true
end

---Setup keymaps for diff operations in the current buffer
---@param session table Session info
function M.setup_diff_keymaps(session)
  if not session then
    return
  end

  local config = require("opencode.config").options.diff
  local keymaps = config.keymaps

  -- Only set keymaps in the modified buffer window
  local modified_win = session.windows.right
  if not modified_win or not vim.api.nvim_win_is_valid(modified_win) then
    return
  end

  vim.api.nvim_win_call(modified_win, function()
    local buf = session.modified_buf
    local opts = { buffer = buf, silent = true, nowait = true }

    -- Accept hunk (do - diff obtain from left/original)
    vim.keymap.set("n", keymaps.accept_hunk, "do", opts)

    -- Reject hunk (dp - diff put to left/original)
    vim.keymap.set("n", keymaps.reject_hunk, "dp", opts)

    -- Navigation
    vim.keymap.set("n", keymaps.next_hunk, "]c", opts)
    vim.keymap.set("n", keymaps.prev_hunk, "[c", opts)

    -- Custom keymaps for applying changes back to source
    vim.keymap.set("n", "<leader>da", function()
      M.apply_all_changes(session)
    end, vim.tbl_extend("force", opts, { desc = "Apply all changes to source buffer" }))

    vim.keymap.set("n", "<leader>dr", function()
      M.reject_all_changes(session)
    end, vim.tbl_extend("force", opts, { desc = "Reject all changes" }))

    vim.keymap.set("n", "q", function()
      M.close_diff_session(session)
    end, vim.tbl_extend("force", opts, { desc = "Close diff session" }))
  end)
end

---Apply current state of modified buffer back to source buffer
---@param session table Session info
function M.apply_all_changes(session)
  if not session or not vim.api.nvim_buf_is_valid(session.source_buf) then
    vim.notify("Source buffer is no longer valid", vim.log.levels.WARN, { title = "opencode" })
    return
  end

  -- Get current content from modified buffer
  local modified_lines = vim.api.nvim_buf_get_lines(session.modified_buf, 0, -1, false)

  -- Apply to source buffer
  vim.api.nvim_buf_set_lines(session.source_buf, 0, -1, false, modified_lines)

  vim.notify("Changes applied to source buffer", vim.log.levels.INFO, { title = "opencode" })
  M.close_diff_session(session)
end

---Reject all changes and close session
---@param session table Session info
function M.reject_all_changes(session)
  vim.notify("Changes rejected", vim.log.levels.INFO, { title = "opencode" })
  M.close_diff_session(session)
end

---Close a diff session and clean up windows/buffers
---@param session table Session info
function M.close_diff_session(session)
  if not session then
    return
  end

  -- Close windows
  for _, win in pairs(session.windows or {}) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, false)
    end
  end

  -- Delete temporary buffers
  if vim.api.nvim_buf_is_valid(session.original_buf) then
    vim.api.nvim_buf_delete(session.original_buf, { force = true })
  end
  if vim.api.nvim_buf_is_valid(session.modified_buf) then
    vim.api.nvim_buf_delete(session.modified_buf, { force = true })
  end

  -- Remove from active sessions
  active_sessions[session.id] = nil
end

---Get active diff session for a buffer
---@param bufnr number Buffer number
---@return table|nil Session info or nil
function M.get_session_for_buffer(bufnr)
  for _, session in pairs(active_sessions) do
    if session.source_buf == bufnr then
      return session
    end
  end
  return nil
end

---Close all active diff sessions
function M.close_all_sessions()
  for _, session in pairs(active_sessions) do
    M.close_diff_session(session)
  end
end

---Get info about active sessions (for debugging)
---@return table Session information
function M.get_session_info()
  local info = {}
  for id, session in pairs(active_sessions) do
    info[id] = {
      source_buf = session.source_buf,
      filepath = session.change.filepath,
      windows_valid = {
        left = session.windows.left and vim.api.nvim_win_is_valid(session.windows.left),
        right = session.windows.right and vim.api.nvim_win_is_valid(session.windows.right),
      },
    }
  end
  return info
end

return M
