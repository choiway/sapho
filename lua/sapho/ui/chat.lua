local M = {}
local ns = vim.api.nvim_create_namespace('sapho.chat')

function M.new(buf)
  local self = { buf = buf, block = nil, pending = '', timer = nil }
  local function change(fn)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local windows = {}
    local old_count = vim.api.nvim_buf_line_count(buf)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == buf then
        vim.api.nvim_win_call(win, function()
          local view = vim.fn.winsaveview()
          windows[#windows + 1] = { win = win, view = view,
            follow = vim.fn.line('w$') >= old_count and view.lnum >= old_count - 1 }
        end)
      end
    end
    vim.bo[buf].modifiable = true
    local ok, err = pcall(fn)
    vim.bo[buf].modifiable = false
    for _, info in ipairs(windows) do
      if vim.api.nvim_win_is_valid(info.win) then
        vim.api.nvim_win_call(info.win, function()
          if info.follow then
            vim.api.nvim_win_set_cursor(info.win, { vim.api.nvim_buf_line_count(buf), 0 })
          else
            vim.fn.winrestview(info.view)
          end
        end)
      end
    end
    if not ok then error(err) end
  end
  function self:flush()
    if self.timer then self.timer:stop(); self.timer:close(); self.timer = nil end
    if self.pending == '' or not self.block then return end
    local bytes = self.pending
    self.pending = ''
    change(function()
      local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ns, self.block.mark, {})
      if #mark == 0 then return end
      vim.api.nvim_buf_set_text(buf, mark[1], mark[2], mark[1], mark[2],
        vim.split(bytes, '\n', { plain = true }))
    end)
  end
  function self:line(text, dim)
    self:flush()
    change(function()
      local count = vim.api.nvim_buf_line_count(buf)
      local empty = count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ''
      local row = empty and 0 or count
      vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, { text })
      if dim and #text > 0 then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0,
          { end_col = #text, hl_group = 'Comment', priority = 200 })
      end
    end)
  end
  function self:begin(kind)
    self:end_block()
    local title = kind == 'reasoning' and '## Thinking' or '## Assistant'
    local start = vim.api.nvim_buf_line_count(buf)
    local empty = start == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ''
    if empty then start = 0 end
    change(function() vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, { title, '' }) end)
    local mark = vim.api.nvim_buf_set_extmark(buf, ns, start + 1, 0, { right_gravity = true })
    self.block = { kind = kind, start = start, mark = mark }
  end
  function self:delta(kind, text)
    if not self.block or self.block.kind ~= kind then self:begin(kind) end
    self.pending = self.pending .. text
    if not self.timer then
      local timer = assert(vim.uv.new_timer())
      self.timer = timer
      timer:start(40, 0, function() vim.schedule(function()
        if self.timer == timer then self:flush() end
      end) end)
    end
  end
  function self:end_block()
    self:flush()
    if not self.block then return end
    local block = self.block
    self.block = nil
    if block.kind == 'reasoning' and vim.api.nvim_buf_is_valid(buf) then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, block.mark, {})
      local last = pos[1] or block.start + 1
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
          vim.api.nvim_win_call(win, function()
            local view = vim.fn.winsaveview()
            vim.cmd(string.format('silent! %d,%dfold', block.start + 1, last + 1))
            vim.cmd(string.format('silent! %dfoldclose', block.start + 1))
            vim.fn.winrestview(view)
          end)
        end
      end
    end
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_del_extmark(buf, ns, block.mark) end
  end
  function self:close()
    if self.timer then self.timer:stop(); self.timer:close(); self.timer = nil end
    self.pending = ''
  end
  return self
end
return M
