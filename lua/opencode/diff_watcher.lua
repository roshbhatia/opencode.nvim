local M = {}

-- Track buffers we're watching for changes
local watched_buffers = {}

---Setup diff watching for SSE events
function M.setup()
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("OpencodeDiffWatcher", { clear = true }),
    pattern = "OpencodeEvent",
    callback = function(args)
      local config = require("opencode.config").options.diff

      if args.data.type == "file.edited" then
        M.handle_file_edited(args.data)
      elseif args.data.type == "session.idle" then
        M.handle_session_idle(args.data)
      end
    end,
    desc = "Watch for opencode events to trigger diff detection",
  })
end

---Handle file.edited SSE event
---@param event_data table SSE event data
function M.handle_file_edited(event_data)
  local config = require("opencode.config").options.diff

  -- Look for the edited file in open buffers
  local edited_file = event_data.file
  if not edited_file then
    return
  end

  -- Find buffer for this file
  local bufnr = M.find_buffer_for_file(edited_file)
  if not bufnr then
    return
  end

  -- Ensure buffer has a snapshot for comparison
  -- This will capture the state before opencode's edit
  local diff = require("opencode.diff")
  if not watched_buffers[bufnr] then
    -- We missed the initial snapshot - capture current state as "original"
    -- This isn't ideal but better than nothing
    vim.schedule(function()
      diff.capture_buffer_snapshot(bufnr)
      watched_buffers[bufnr] = true
    end)
  end

  -- File change will be detected when session goes idle
end

---Handle session.idle SSE event (when opencode finishes responding)
---@param event_data table SSE event data
function M.handle_session_idle(event_data)
  local config = require("opencode.config").options.diff

  -- When session becomes idle, check for changes and optionally trigger diff workflow
  vim.schedule(function()
    local all_changes = require("opencode.diff").get_all_changes()

    if #all_changes > 0 then
      -- Auto-populate quickfix if enabled
      if config.quickfix.auto_populate then
        require("opencode.quickfix").populate_quickfix(all_changes, { open_window = true })
      end

      -- Auto-open diff view if enabled
      if config.auto_open then
        -- For auto-open, just open diff for the first changed buffer
        -- Users can navigate to others via quickfix
        local first_change = all_changes[1]
        if first_change then
          -- Switch to the buffer and open diff view
          vim.cmd("buffer " .. first_change.bufnr)
          require("opencode").review_changes()
        end
      end
    end
  end)
end

---Find buffer number for a given file path
---@param filepath string File path to search for
---@return number|nil Buffer number or nil if not found
function M.find_buffer_for_file(filepath)
  -- Normalize the file path
  local normalized_path = vim.fn.fnamemodify(filepath, ":p")

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local buf_name = vim.api.nvim_buf_get_name(bufnr)
      if buf_name ~= "" then
        local buf_path = vim.fn.fnamemodify(buf_name, ":p")
        if buf_path == normalized_path then
          return bufnr
        end
      end
    end
  end

  return nil
end

---Capture snapshots for all open buffers
---This should be called before sending prompts to opencode
function M.capture_all_snapshots()
  local diff = require("opencode.diff")

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
      if buftype == "" then -- Only capture regular file buffers
        diff.capture_buffer_snapshot(bufnr)
        watched_buffers[bufnr] = true
      end
    end
  end

  local count = 0
  for _ in pairs(watched_buffers) do
    count = count + 1
  end

  -- Snapshots captured silently
end

---Stop watching a specific buffer
---@param bufnr number Buffer number
function M.stop_watching_buffer(bufnr)
  watched_buffers[bufnr] = nil
  require("opencode.diff").clear_buffer_snapshot(bufnr)
end

---Stop watching all buffers
function M.stop_watching_all()
  watched_buffers = {}
  require("opencode.diff").clear_all_snapshots()
end

---Get list of watched buffers
---@return table List of watched buffer numbers
function M.get_watched_buffers()
  local buffers = {}
  for bufnr, _ in pairs(watched_buffers) do
    table.insert(buffers, bufnr)
  end
  return buffers
end

---Get info about diff watcher state (for debugging)
---@return table Watcher information
function M.get_watcher_info()
  local info = {
    watched_buffers = {},
    total_watched = 0,
  }

  for bufnr, _ in pairs(watched_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      info.watched_buffers[bufnr] = {
        name = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]",
        valid = true,
      }
      info.total_watched = info.total_watched + 1
    else
      info.watched_buffers[bufnr] = {
        name = "[Invalid Buffer]",
        valid = false,
      }
    end
  end

  return info
end

return M
