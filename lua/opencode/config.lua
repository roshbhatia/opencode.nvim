local M = {}

---@class opencode.Config
---@field port? number The port opencode's server is running on. If `nil`, searches for an opencode process inside Neovim's CWD — usually you can leave this unset unless that fails. Embedded instances will automatically use this — launch external instances with `opencode --port <port>`.
---@field auto_reload? boolean Automatically reload buffers edited by opencode. Requires `vim.opt.autoread = true`.
---@field auto_fallback_to_embedded? boolean Automatically open an embedded opencode instance if none found when `prompt`ing.
---@field auto_register_cmp_sources? string[] Completion sources to automatically register with [blink.cmp](https://github.com/Saghen/blink.cmp) in the `ask` input.
---@field prompts? table<string, opencode.Prompt> Prompts to select from.
---@field contexts? table<string, opencode.Context> Contexts to inject into prompts.
---@field input? snacks.input.Opts Input options — see [snacks.input](https://github.com/folke/snacks.nvim/blob/main/docs/input.md).
---@field terminal? snacks.terminal.Opts Terminal options — see [snacks.terminal](https://github.com/folke/snacks.nvim/blob/main/docs/terminal.md).
---@field diff? opencode.DiffConfig Diff functionality configuration.
local defaults = {
  port = nil,
  auto_reload = true,
  auto_fallback_to_embedded = true,
  auto_register_cmp_sources = { "opencode", "buffer" },
  prompts = {
    ---@class opencode.Prompt
    ---@field description? string Description of the prompt
    ---@field prompt? string The prompt to send to opencode, with placeholders for context like `@cursor`, `@buffer`, etc.
    explain = {
      description = "Explain code near cursor",
      prompt = "Explain @cursor and its context",
    },
    fix = {
      description = "Fix diagnostics",
      prompt = "Fix these @diagnostics",
    },
    optimize = {
      description = "Optimize selection",
      prompt = "Optimize @selection for performance and readability",
    },
    document = {
      description = "Document selection",
      prompt = "Add documentation comments for @selection",
    },
    test = {
      description = "Add tests for selection",
      prompt = "Add tests for @selection",
    },
    review_file = {
      description = "Review buffer",
      prompt = "Review @buffer for correctness and readability",
    },
    review_diff = {
      description = "Review git diff",
      prompt = "Review the following git diff for correctness and readability:\n@diff",
    },
  },
  contexts = {
    ---@class opencode.Context
    ---@field value fun(): string|nil Function that returns the context value for replacement
    ---@field description? string
    ["@buffer"] = { value = require("opencode.context").buffer, description = "Current buffer" },
    ["@buffers"] = { value = require("opencode.context").buffers, description = "Open buffers" },
    ["@cursor"] = { value = require("opencode.context").cursor_position, description = "Cursor position" },
    ["@selection"] = { value = require("opencode.context").visual_selection, description = "Selected text" },
    ["@visible"] = { value = require("opencode.context").visible_text, description = "Visible text" },
    ["@diagnostic"] = {
      value = function()
        return require("opencode.context").diagnostics(true)
      end,
      description = "Current line diagnostics",
    },
    ["@diagnostics"] = { value = require("opencode.context").diagnostics, description = "Current buffer diagnostics" },
    ["@quickfix"] = { value = require("opencode.context").quickfix, description = "Quickfix list" },
    ["@diff"] = { value = require("opencode.context").git_diff, description = "Git diff" },
  },
  input = {
    prompt = "Ask opencode",
    icon = "󱚣 ",
    -- Built-in completion as fallback.
    -- It's okay to enable simultaneously with blink.cmp because built-in completion
    -- only triggers via <Tab> and blink.cmp keymaps take priority.
    completion = "customlist,v:lua.require'opencode.cmp.omni'",
    win = {
      title_pos = "left",
      relative = "cursor",
      row = -3, -- Row above the cursor
      col = -5, -- First input cell is directly above the cursor
      b = {
        -- Enable blink completion
        completion = true,
      },
      bo = {
        -- Custom filetype to configure blink with
        filetype = "opencode_ask",
      },
      ---@param win snacks.win
      on_buf = function(win)
        require("opencode.highlight").setup(win.buf)

        -- Wait as long as possible to check for blink.cmp loaded - many users lazy-load on `InsertEnter`.
        -- OptionSet :runtimepath didn't seem to fire for lazy.nvim.
        vim.api.nvim_create_autocmd("InsertEnter", {
          buffer = win.buf,
          callback = function()
            if package.loaded["blink.cmp"] then
              require("opencode.cmp.blink").setup(M.options.auto_register_cmp_sources)
            end
          end,
        })
      end,
    },
  },
  terminal = {
    -- No reason to prefer normal mode - can't scroll TUI like a normal buffer
    auto_insert = true,
    auto_close = true,
    win = {
      position = "right",
      -- I usually want to `toggle` and then immediately `ask` - seems like a sensible default
      enter = false,
    },
    env = {
      -- Other themes have visual bugs in embedded terminals: https://github.com/sst/opencode/issues/445
      OPENCODE_THEME = "system",
    },
  },
  diff = {
    ---@class opencode.DiffConfig
    ---@field auto_open? boolean Automatically open diff view when changes are detected
    ---@field auto_populate_quickfix? boolean Automatically populate quickfix list with detected changes
    ---@field keymaps? opencode.DiffKeymaps Keymaps for diff functionality
    auto_open = false,
    auto_populate_quickfix = true,
    keymaps = {
      ---@class opencode.DiffKeymaps
      ---@field review_changes? string Keymap to manually review changes
      ---@field accept_hunk? string Keymap to accept current diff hunk (uses vim default 'do')
      ---@field reject_hunk? string Keymap to reject current diff hunk (uses vim default 'dp')
      ---@field next_hunk? string Keymap to go to next diff hunk (uses vim default ']c')
      ---@field prev_hunk? string Keymap to go to previous diff hunk (uses vim default '[c')
      review_changes = "<leader>od",
      accept_hunk = "do",
      reject_hunk = "dp",
      next_hunk = "]c",
      prev_hunk = "[c",
    },
  },
}

---@type opencode.Config
M.options = vim.deepcopy(defaults)

---@param opts? opencode.Config
---@return opencode.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})

  return M.options
end

return M
