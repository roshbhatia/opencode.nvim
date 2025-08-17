local M = {}

-- Important to track the port, not just true/false,
-- because opencode may have restarted (usually on a new port) while the plugin is running
local sse_listening_port = nil

---Get the opencode port. Checks, in order:
---1. `opts.port`.
---2. The port of any opencode server running inside Neovim's CWD, prioritizing embedded terminals.
---3. If `auto_fallback_to_embedded` is enabled, opens an embedded opencode terminal and polls for the port.
---@param callback fun(ok: boolean, result: any)
local function get_opencode_port(callback)
  local configured_port = require("opencode.config").options.port
  if configured_port then
    callback(true, configured_port)
    return
  end

  local find_port_ok, find_port_result = pcall(require("opencode.server").find_port)
  if find_port_ok then
    callback(true, find_port_result)
    return
  end

  if require("opencode.config").options.auto_fallback_to_embedded then
    local win, created = require("opencode.terminal").get()
    if not win then
      callback(false, "Failed to open fallback embedded opencode terminal")
      return
    elseif created then
      require("opencode.server").poll_for_port(function(ok, result)
        callback(ok, result)
      end)
      return
    end
  end

  callback(false, find_port_result)
end

---Set up the plugin with your configuration.
---You don't need to call this if you use the default configuration - it does nothing else.
---@param opts opencode.Config
function M.setup(opts)
  -- What if we just received the relevant opts in each function?
  -- But people have come to expect a `setup` function with global `opts`...
  require("opencode.config").setup(opts)
end

---Send a prompt to opencode after injecting contexts.
---
---As the entry point to prompting, this function also:
---1. Sets up `auto_reload` if enabled.
---2. Starts listening for SSEs from opencode to forward as `OpencodeEvent` autocmd.
---@param prompt string
function M.prompt(prompt)
  get_opencode_port(function(ok, result)
    if not ok then
      vim.notify(result, vim.log.levels.ERROR, { title = "opencode" })
      return
    end

    prompt = require("opencode.context").inject(prompt, require("opencode.config").options.contexts)

    -- WARNING: If user never prompts opencode via the plugin, we'll never receive SSEs or register auto_reload autocmds.
    -- Could register in `/plugin` and even periodically check, but is it worth the complexity?
    if require("opencode.config").options.auto_reload then
      require("opencode.reload").setup()
    end

    -- Setup diff watcher for automatic diff detection
    require("opencode.diff_watcher").setup()

    -- Capture snapshots of all open buffers before sending prompt
    -- This ensures we can detect changes made by opencode
    require("opencode.diff_watcher").capture_all_snapshots()
    if result ~= sse_listening_port then
      require("opencode.client").sse_listen(result, function(response)
        vim.api.nvim_exec_autocmds("User", {
          pattern = "OpencodeEvent",
          data = response,
        })
      end)
      sse_listening_port = result
    end

    require("opencode.terminal").show_if_exists()

    require("opencode.client").tui_clear_prompt(result, function()
      require("opencode.client").tui_append_prompt(prompt, result, function()
        require("opencode.client").tui_submit_prompt(result, function()
          --
        end)
      end)
    end)
  end)
end

---Send a command to opencode.
---See https://opencode.ai/docs/keybinds/ for available commands.
---@param command string
function M.command(command)
  get_opencode_port(function(ok, result)
    if not ok then
      vim.notify(result, vim.log.levels.ERROR, { title = "opencode" })
      return
    end

    -- No need to register SSE or auto_reload here - commands trigger neither
    -- (except maybe the `input_*` commands? but no reason for user to use those).

    require("opencode.terminal").show_if_exists()

    require("opencode.client").tui_execute_command(command, result)
  end)
end

---Input a prompt to send to opencode.
---@param default? string Text to prefill the input with.
function M.ask(default)
  require("opencode.input").show(default, function(value)
    M.prompt(value)
  end)
end

---Select a prompt to send to opencode.
function M.select_prompt()
  ---@type opencode.Prompt[]
  local prompts = vim.tbl_filter(function(prompt)
    local is_visual = vim.fn.mode():match("[vV\22]")
    -- WARNING: Technically depends on user using built-in `@selection` context by name...
    -- Could compare function references? Probably more trouble than it's worth.
    local does_prompt_use_visual = prompt.prompt:match("@selection")
    if is_visual then
      return does_prompt_use_visual
    else
      return not does_prompt_use_visual
    end
  end, vim.tbl_values(require("opencode.config").options.prompts))

  vim.ui.select(
    prompts,
    {
      prompt = "Prompt opencode: ",
      ---@param item opencode.Prompt
      format_item = function(item)
        return item.description
      end,
    },
    ---@param choice opencode.Prompt
    function(choice)
      if choice then
        M.prompt(choice.prompt)
      end
    end
  )
end

---Toggle embedded opencode TUI.
function M.toggle()
  require("opencode.terminal").toggle()
end

---Capture a snapshot of the current buffer for diff detection.
function M.capture_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local content = require("opencode.diff").capture_buffer_snapshot(bufnr)
  if not content then
    vim.notify("Failed to capture buffer snapshot", vim.log.levels.WARN, { title = "opencode" })
  end
end

---Detect and display changes in the current buffer.
function M.detect_changes()
  local bufnr = vim.api.nvim_get_current_buf()
  local changes = require("opencode.diff").detect_buffer_changes(bufnr)

  if changes then
    vim.notify(
      string.format("Changes detected in %s", vim.fn.fnamemodify(changes.filepath, ":t")),
      vim.log.levels.INFO,
      { title = "opencode" }
    )

    print(changes.diff)
  else
    vim.notify("No changes detected", vim.log.levels.INFO, { title = "opencode" })
  end
end

---Review changes in the current buffer using diff view.
---Creates a side-by-side diff interface for accepting/rejecting changes.
function M.review_changes()
  local bufnr = vim.api.nvim_get_current_buf()
  local changes = require("opencode.diff").detect_buffer_changes(bufnr)

  if not changes then
    vim.notify("No changes detected in current buffer", vim.log.levels.INFO, { title = "opencode" })
    return
  end

  local diff_ui = require("opencode.diff_ui")

  -- Check if there's already a diff session for this buffer
  local existing_session = diff_ui.get_session_for_buffer(bufnr)
  if existing_session then
    vim.notify("Diff session already open for this buffer", vim.log.levels.WARN, { title = "opencode" })
    return
  end

  -- Populate quickfix if enabled
  local config = require("opencode.config").options.diff
  if config.auto_populate_quickfix then
    require("opencode.quickfix").populate_quickfix({ changes }, { open_window = true })
  end

  -- Create diff view
  local session = diff_ui.create_diff_view(changes)
  if not session then
    vim.notify("Failed to create diff view", vim.log.levels.ERROR, { title = "opencode" })
    return
  end

  -- Open diff windows
  local success = diff_ui.open_diff_windows(session)
  if not success then
    vim.notify("Failed to open diff windows", vim.log.levels.ERROR, { title = "opencode" })
    diff_ui.close_diff_session(session)
    return
  end


  vim.notify(
    string.format(
      "Diff view opened for %s. Use 'do'/'dp' to accept/reject hunks, 'q' to close.",
      vim.fn.fnamemodify(changes.filepath, ":t")
    ),
    vim.log.levels.INFO,
    { title = "opencode" }
  )
end

---Populate quickfix list with all detected changes across open buffers.
function M.populate_quickfix()
  local all_changes = require("opencode.diff").get_all_changes()
  require("opencode.quickfix").populate_quickfix(all_changes, { open_window = true })
end

---Clear opencode-related entries from the quickfix list.
function M.clear_quickfix()
  require("opencode.quickfix").clear_opencode_quickfix()
end

---Manually capture snapshots of all open buffers.
---Useful for preparing diff detection before opencode operations.
function M.capture_all_snapshots()
  require("opencode.diff_watcher").capture_all_snapshots()
end

---Stop watching all buffers for changes and clear snapshots.
---Useful for resetting diff detection state.
function M.clear_all_snapshots()
  require("opencode.diff_watcher").stop_watching_all()
end

---Get information about the current diff watching state.
---@return table Watcher and snapshot information
function M.get_diff_info()
  local watcher_info = require("opencode.diff_watcher").get_watcher_info()
  local snapshot_info = require("opencode.diff").get_snapshot_info()

  return {
    watcher = watcher_info,
    snapshots = snapshot_info,
    watched_count = watcher_info.total_watched,
    snapshot_count = vim.tbl_count(snapshot_info),
  }
end

return M
