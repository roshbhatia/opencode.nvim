local M = {}

---Parse a unified diff string to extract hunk information
---@param diff_content string Unified diff content
---@param filepath string File path for the changes
---@return table[] Array of hunk information
local function parse_diff_hunks(diff_content, filepath)
  local hunks = {}

  if not diff_content or diff_content == "" then
    return hunks
  end

  -- Split diff into lines
  local lines = vim.split(diff_content, "\n")
  local current_hunk = nil

  for _, line in ipairs(lines) do
    -- Match hunk headers like "@@ -1,3 +1,4 @@"
    local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")

    if old_start then
      -- Save previous hunk if exists
      if current_hunk then
        table.insert(hunks, current_hunk)
      end

      -- Start new hunk
      current_hunk = {
        old_start = tonumber(old_start),
        old_count = tonumber(old_count) or 1,
        new_start = tonumber(new_start),
        new_count = tonumber(new_count) or 1,
        lines = {},
        additions = 0,
        deletions = 0,
      }
    elseif current_hunk then
      -- Process hunk content lines
      local prefix = line:sub(1, 1)
      local content = line:sub(2)

      if prefix == "+" then
        current_hunk.additions = current_hunk.additions + 1
        table.insert(current_hunk.lines, { type = "add", content = content })
      elseif prefix == "-" then
        current_hunk.deletions = current_hunk.deletions + 1
        table.insert(current_hunk.lines, { type = "remove", content = content })
      elseif prefix == " " then
        table.insert(current_hunk.lines, { type = "context", content = content })
      end
    end
  end

  -- Add the last hunk
  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  return hunks
end

---Generate a description for a diff hunk
---@param hunk table Hunk information
---@return string Description of the changes
local function generate_hunk_description(hunk)
  local desc_parts = {}

  if hunk.additions > 0 and hunk.deletions > 0 then
    table.insert(desc_parts, string.format("Modified: +%d -%d lines", hunk.additions, hunk.deletions))
  elseif hunk.additions > 0 then
    table.insert(desc_parts, string.format("Added: +%d lines", hunk.additions))
  elseif hunk.deletions > 0 then
    table.insert(desc_parts, string.format("Removed: -%d lines", hunk.deletions))
  else
    table.insert(desc_parts, "Context change")
  end

  -- Add a preview of the changes (first few lines)
  local preview_lines = {}
  local preview_count = 0
  for _, line in ipairs(hunk.lines) do
    if line.type ~= "context" and preview_count < 2 then
      local prefix = line.type == "add" and "+" or "-"
      table.insert(preview_lines, prefix .. line.content:sub(1, 40))
      preview_count = preview_count + 1
    end
  end

  if #preview_lines > 0 then
    table.insert(desc_parts, "(" .. table.concat(preview_lines, ", ") .. ")")
  end

  return table.concat(desc_parts, " ")
end

---Convert diff changes to quickfix entries
---@param changes table[] Array of change information from diff.get_all_changes()
---@return table[] Array of quickfix entries
function M.changes_to_quickfix_entries(changes)
  local qf_entries = {}

  for _, change in ipairs(changes) do
    local hunks = parse_diff_hunks(change.diff, change.filepath)

    for _, hunk in ipairs(hunks) do
      local entry = {
        filename = change.filepath,
        lnum = hunk.new_start,
        col = 1,
        text = generate_hunk_description(hunk),
        type = "I", -- Info type
        valid = 1,
        -- Store additional metadata
        user_data = {
          bufnr = change.bufnr,
          hunk = hunk,
          change_id = change.bufnr .. "_" .. change.timestamp,
        },
      }
      table.insert(qf_entries, entry)
    end
  end

  return qf_entries
end

---Populate the quickfix list with detected changes
---@param changes table[] Array of change information
---@param opts? table Options for quickfix population
function M.populate_quickfix(changes, opts)
  opts = opts or {}

  if not changes or #changes == 0 then
    if opts.clear_if_empty ~= false then
      vim.fn.setqflist({}, "r") -- Clear quickfix list
      vim.notify("No changes to populate in quickfix list", vim.log.levels.INFO, { title = "opencode" })
    end
    return
  end

  local qf_entries = M.changes_to_quickfix_entries(changes)

  if #qf_entries == 0 then
    if opts.clear_if_empty ~= false then
      vim.fn.setqflist({}, "r")
      vim.notify("No diff hunks found to populate in quickfix list", vim.log.levels.INFO, { title = "opencode" })
    end
    return
  end

  -- Set quickfix list with our entries
  local action = opts.append and "a" or "r" -- append or replace
  vim.fn.setqflist(qf_entries, action)

  -- Set quickfix title
  local title = string.format("opencode changes (%d hunks across %d files)", #qf_entries, #changes)
  vim.fn.setqflist({}, action, { title = title })

  vim.notify(
    string.format("Populated quickfix with %d change hunks", #qf_entries),
    vim.log.levels.INFO,
    { title = "opencode" }
  )

  -- Optionally open quickfix window
  if opts.open_window then
    vim.cmd("copen")
  end
end

---Update quickfix list when a hunk is accepted/rejected
---@param change_id string The change identifier
---@param hunk_line number The line number of the hunk that was modified
function M.update_quickfix_after_change(change_id, hunk_line)
  local qflist = vim.fn.getqflist()
  local updated = false

  -- Mark the corresponding quickfix entry as resolved
  for i, entry in ipairs(qflist) do
    if entry.user_data and entry.user_data.change_id == change_id and entry.lnum == hunk_line then
      -- Update the entry to show it's been resolved
      entry.text = "[RESOLVED] " .. entry.text
      entry.type = "W" -- Warning type to differentiate
      updated = true
      break
    end
  end

  if updated then
    vim.fn.setqflist(qflist, "r")
  end
end

---Remove all quickfix entries for a specific buffer
---@param bufnr number Buffer number
function M.remove_buffer_from_quickfix(bufnr)
  local qflist = vim.fn.getqflist()
  local filtered = {}

  -- Filter out entries for the specified buffer
  for _, entry in ipairs(qflist) do
    if not (entry.user_data and entry.user_data.bufnr == bufnr) then
      table.insert(filtered, entry)
    end
  end

  vim.fn.setqflist(filtered, "r")

  if #filtered < #qflist then
    vim.notify(
      string.format("Removed %d entries from quickfix list", #qflist - #filtered),
      vim.log.levels.INFO,
      { title = "opencode" }
    )
  end
end

---Clear all opencode-related entries from quickfix list
function M.clear_opencode_quickfix()
  local qflist = vim.fn.getqflist()
  local filtered = {}

  -- Filter out entries that have our user_data
  for _, entry in ipairs(qflist) do
    if not (entry.user_data and entry.user_data.change_id) then
      table.insert(filtered, entry)
    end
  end

  vim.fn.setqflist(filtered, "r")

  if #filtered < #qflist then
    vim.notify(
      string.format("Cleared %d opencode entries from quickfix list", #qflist - #filtered),
      vim.log.levels.INFO,
      { title = "opencode" }
    )
  end
end

---Get statistics about quickfix entries
---@return table Statistics information
function M.get_quickfix_stats()
  local qflist = vim.fn.getqflist()
  local stats = {
    total_entries = #qflist,
    opencode_entries = 0,
    resolved_entries = 0,
    buffers = {},
  }

  for _, entry in ipairs(qflist) do
    if entry.user_data and entry.user_data.change_id then
      stats.opencode_entries = stats.opencode_entries + 1

      if entry.text:match("^%[RESOLVED%]") then
        stats.resolved_entries = stats.resolved_entries + 1
      end

      if entry.user_data.bufnr then
        stats.buffers[entry.user_data.bufnr] = (stats.buffers[entry.user_data.bufnr] or 0) + 1
      end
    end
  end

  return stats
end

return M
