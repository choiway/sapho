local M = {}
local MAX_LINES, MAX_BYTES = 50, 2000
local commandline_selection

local function valid(buf)
  if not buf then return false end
  return require('sapho.tools.buffer').resolve(nil, { buf = buf }) ~= nil
end
M.valid = valid
local function utf_end(text, col)
  local byte = math.min(#text, math.max(1, col))
  -- A visual endpoint includes the entire character even if it is multibyte.
  while byte < #text and text:byte(byte + 1) >= 128 and text:byte(byte + 1) < 192 do byte = byte + 1 end
  return byte
end
function M.selection(buf, anchor, cursor, mode)
  local first, last = math.min(anchor[2], cursor[2]), math.max(anchor[2], cursor[2])
  if first < 1 or last > vim.api.nvim_buf_line_count(buf) then return nil end
  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, math.min(last, first + MAX_LINES - 1), false)
  local truncated = last - first + 1 > MAX_LINES
  local ac, cc = anchor[3], cursor[3]
  if mode == 'v' then
    local start_col = anchor[2] < cursor[2] and ac or (anchor[2] > cursor[2] and cc or math.min(ac, cc))
    local end_col = anchor[2] < cursor[2] and cc or (anchor[2] > cursor[2] and ac or math.max(ac, cc))
    if first == last then lines[1] = lines[1]:sub(start_col, utf_end(lines[1], end_col))
    else
      lines[1] = lines[1]:sub(start_col)
      if not truncated then lines[#lines] = lines[#lines]:sub(1, utf_end(lines[#lines], end_col)) end
    end
  elseif mode == '\22' then
    local left, right = math.min(ac, cc), math.max(ac, cc)
    for i, line in ipairs(lines) do lines[i] = line:sub(left, utf_end(line, right)) end
  end
  local text = table.concat(lines, '\n')
  if #text > MAX_BYTES then
    text = text:sub(1, MAX_BYTES)
    while #text > 0 and not pcall(vim.str_utfindex, text, 'utf-8', #text) do text = text:sub(1, -2) end
    truncated = true
  end
  if text == '' then return nil end
  return { text = text, first = first, last = last, truncated = truncated, mode = mode }
end
function M.capture()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if not valid(buf) then return nil, 'Open a normal source buffer first' end
  local pos = vim.api.nvim_win_get_cursor(win)
  local ctx = { buf = buf, win = win, line = pos[1], column = pos[2] + 1,
    path = vim.api.nvim_buf_get_name(buf), filetype = vim.bo[buf].filetype,
    changedtick = vim.api.nvim_buf_get_changedtick(buf) }
  if ctx.path == '' then ctx.path = '[unnamed buffer ' .. buf .. ']' end
  local mode = vim.fn.mode()
  if mode == 'v' or mode == 'V' or mode == '\22' then
    local mark = vim.fn.getpos('v')
    ctx.selection_info = M.selection(buf, mark, { 0, pos[1], pos[2] + 1 }, mode)
    ctx.selection = ctx.selection_info and ctx.selection_info.text
  end
  return ctx
end
--- A visual :Sapho arrives as an Ex range after Visual mode has ended. Only
--- consult visual marks for this explicitly ranged invocation, never for a
--- plain normal-mode :Sapho (whose marks may belong to an older selection).
function M.capture_command(cmd)
  local ctx, err = M.capture()
  if not ctx then commandline_selection = nil; return nil, err end
  local captured = commandline_selection
  commandline_selection = nil
  if not cmd or not cmd.range or cmd.range == 0 then
    if captured and captured.buf == ctx.buf and valid(captured.buf) then
      captured.commandline_visual = true
      return captured
    end
    return ctx
  end
  local first, last = math.min(cmd.line1, cmd.line2), math.max(cmd.line1, cmd.line2)
  local start_mark, end_mark = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local mode = vim.fn.visualmode()
  local matching = cmd.range == 2 and
    math.min(start_mark[2], end_mark[2]) == first and
    math.max(start_mark[2], end_mark[2]) == last and
    (mode == 'v' or mode == 'V' or mode == '\22')
  ctx.selection_info = matching and M.selection(ctx.buf, start_mark, end_mark, mode) or
    M.selection(ctx.buf, { 0, first, 1 }, { 0, last, 1 }, 'V')
  ctx.selection = ctx.selection_info and ctx.selection_info.text
  return ctx
end
--- Visual ':' inserts the '<,'> range into the command line. Capture it as
--- soon as it appears: users may delete that prefix before running :Sapho.
--- This state belongs only to the current command line, not to stale marks.
function M.track_commandline()
  local group = vim.api.nvim_create_augroup('sapho.visual_commandline', { clear = true })
  vim.api.nvim_create_autocmd('CmdlineEnter', { group = group, callback = function()
    commandline_selection = nil
  end })
  vim.api.nvim_create_autocmd('CmdlineChanged', { group = group, callback = function()
    if commandline_selection or vim.fn.getcmdtype() ~= ':' or vim.fn.getcmdline() ~= "'<,'>" then return end
    local first, last = vim.fn.getpos("'<")[2], vim.fn.getpos("'>")[2]
    local ctx = M.capture_command({ range = 2, line1 = first, line2 = last })
    if ctx and ctx.selection then commandline_selection = ctx end
  end })
  vim.api.nvim_create_autocmd('CmdlineLeave', { group = group, callback = function()
    if not vim.fn.getcmdline():match('^%s*Sapho%s*$') then commandline_selection = nil; return end
    local captured = commandline_selection
    vim.schedule(function()
      if commandline_selection == captured then commandline_selection = nil end
    end)
  end })
end
function M.live(ctx)
  if not valid(ctx.buf) then return ctx end
  local copy = vim.deepcopy(ctx)
  copy.changedtick = vim.api.nvim_buf_get_changedtick(ctx.buf)
  copy.cursor_live = false
  if ctx.win and vim.api.nvim_win_is_valid(ctx.win) and vim.api.nvim_win_get_buf(ctx.win) == ctx.buf then
    local pos = vim.api.nvim_win_get_cursor(ctx.win)
    copy.line, copy.column = pos[1], pos[2] + 1
    copy.cursor_live = true
  end
  return copy
end
return M
