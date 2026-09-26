local M = {}

function M.locations(items, source_win)
  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    vim.notify('Sapho requires telescope.nvim for :SaphoLocations', vim.log.levels.ERROR)
    return
  end
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  pickers.new({}, { prompt_title = 'Sapho locations (Enter to jump)',
    finder = finders.new_table({ results = items, entry_maker = function(item)
      local path = item.path or (item.uri and vim.uri_to_fname(item.uri)) or ''
      local preview = tostring(item.preview or ''):gsub('[%c]', ' '):sub(1, 180)
      local display = string.format('%s:%d %s', path:gsub('[%c]', ' '), item.line or 1, preview)
      return { value = item, display = display, ordinal = display, filename = path, lnum = item.line }
    end }), sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt)
        if entry then
          local item = entry.value
          local path = item.path or (item.uri and vim.uri_to_fname(item.uri))
          if path then
            if source_win and vim.api.nvim_win_is_valid(source_win) then vim.api.nvim_set_current_win(source_win) end
            vim.cmd.edit(vim.fn.fnameescape(path))
            pcall(vim.api.nvim_win_set_cursor, 0, { item.line or 1, math.max(0, (item.column or 1) - 1) })
          end
        end
      end)
      return true
    end,
  }):find()
end

return M
