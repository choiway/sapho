local config = require('sapho.config')
local Context = require('sapho.context')
local Session = require('sapho.session')
local Chat = require('sapho.ui.chat')
local Picker = require('sapho.ui.picker')
local M, states = {}, {}
local function ui_highlights()
  for name, target in pairs({
    SaphoInputBorderNormal = 'Comment',
    SaphoInputBorderInsert = 'DiagnosticOk',
    SaphoInputBorderReplace = 'DiagnosticWarn',
    SaphoTranscriptBorder = 'Comment',
    SaphoSpinner = 'DiagnosticInfo',
  }) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end
ui_highlights()
local highlight_group = vim.api.nvim_create_augroup('sapho.input_border', { clear = true })
vim.api.nvim_create_autocmd('ColorScheme', { group = highlight_group, callback = ui_highlights })
local function safe_label(text)
  return tostring(text or ''):gsub('[%c]', ' '):sub(1, 180)
end
local function scratch(name, readonly)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'; vim.bo[buf].bufhidden = 'hide'; vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, name)
  if readonly then
    require('sapho.ui.markdown').setup(buf)
    vim.bo[buf].modifiable = false
  else
    vim.bo[buf].filetype = 'sapho-input'
  end
  return buf
end
local spinner_frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local function header(state)
  local ctx = state.source
  local activity = state.activity or 'Ready'
  if state.spinner then
    activity = activity:gsub('^●', function()
      return '%#SaphoSpinner#' .. spinner_frames[state.spinner_frame] .. '%*'
    end)
  end
  local range = ctx.selection_info and (' | selection lines ' .. ctx.selection_info.first .. '–' .. ctx.selection_info.last ..
    (ctx.selection_info.truncated and ' (truncated)' or ' (pinned at invocation)')) or ''
  local prior = #state.session.history > 0 and ' | continuing conversation' or ' | new conversation'
  local path = safe_label(ctx.path):gsub('%%', '%%%%')
  -- Keep the activity visible even when the source path or hints exceed the float width.
  return '[' .. activity .. '] Sapho%< · ' .. path .. range .. prior ..
    ' | Ctrl-S send · Ctrl-C cancel '
end
local function visible(win)
  return win and vim.api.nvim_win_is_valid(win)
end
local function render_activity(state)
  if visible(state.chat_win) then vim.wo[state.chat_win].winbar = header(state) end
end
local function stop_spinner(state)
  if not state.spinner then return end
  state.spinner:stop()
  state.spinner:close()
  state.spinner = nil
end
local function set_activity(state, label)
  state.activity = label
  if state.busy and label:match('^●') and visible(state.input_win) and visible(state.chat_win) then
    if not state.spinner then
      local timer = assert(vim.uv.new_timer())
      state.spinner, state.spinner_frame = timer, 1
      timer:start(120, 120, vim.schedule_wrap(function()
        if state.spinner ~= timer then return end
        state.spinner_frame = state.spinner_frame % #spinner_frames + 1
        render_activity(state)
      end))
    end
  else
    stop_spinner(state)
  end
  render_activity(state)
end
local function set_border(win, group)
  if not visible(win) then return end
  local items = {}
  for item in vim.wo[win].winhighlight:gmatch('[^,]+') do
    if not item:match('^FloatBorder:') then items[#items + 1] = item end
  end
  items[#items + 1] = 'FloatBorder:' .. group
  vim.wo[win].winhighlight = table.concat(items, ',')
end
local function update_input_mode(state, mode)
  local group = mode:match('^i') and 'SaphoInputBorderInsert' or
    mode:match('^R') and 'SaphoInputBorderReplace' or 'SaphoInputBorderNormal'
  set_border(state.input_win, group)
end
local function hide(state)
  stop_spinner(state)
  state.hiding = true
  for _, win in ipairs({ state.input_win, state.chat_win }) do
    if visible(win) then vim.api.nvim_win_close(win, true) end
  end
  state.input_win, state.chat_win = nil, nil
  state.hiding = false
  -- Closing the UI does not cancel the request or discard its buffers.
  if visible(state.source.win) and vim.api.nvim_win_get_buf(state.source.win) == state.source.buf then
    pcall(vim.api.nvim_set_current_win, state.source.win)
  end
end
local function show(state)
  if not Context.valid(state.source.buf) then
    vim.notify('Sapho: source buffer is unavailable', vim.log.levels.ERROR); return
  end
  if visible(state.input_win) and visible(state.chat_win) then
    vim.api.nvim_set_current_win(state.input_win)
    update_input_mode(state, vim.api.nvim_get_mode().mode)
    set_activity(state, state.activity or 'Ready')
    return
  end
  local ui = config.get().ui
  local width = math.min(math.max(20, math.floor(ui.width)), math.max(1, vim.o.columns - 4))
  local available = math.max(6, vim.o.lines - vim.o.cmdheight - 4)
  local target_height = ui.height == 0 and math.floor(vim.o.lines * 0.8) or ui.height
  local height = math.min(math.max(8, math.floor(target_height)), available)
  local input_height = math.min(5, math.max(2, height - 5))
  local chat_height = math.max(1, height - input_height - 2)
  local row = math.max(0, math.floor((vim.o.lines - height - 1) / 2))
  local col = math.max(0, vim.o.columns - width - 2)
  local opts = { relative = 'editor', style = 'minimal', border = 'rounded', width = width,
    col = col, zindex = 50 }
  state.chat_win = vim.api.nvim_open_win(state.chat_buf, false,
    vim.tbl_extend('force', opts, { row = row, height = chat_height }))
  state.input_win = vim.api.nvim_open_win(state.input_buf, true,
    vim.tbl_extend('force', opts, { row = row + chat_height + 2, height = input_height }))
  vim.wo[state.chat_win].wrap = true
  vim.wo[state.chat_win].conceallevel = 0 -- never hide model text or code fences
  set_border(state.chat_win, 'SaphoTranscriptBorder')
  vim.wo[state.input_win].wrap = true
  vim.wo[state.input_win].winbar = '' -- keep the input box free of the transcript header
  update_input_mode(state, vim.api.nvim_get_mode().mode)
  set_activity(state, state.activity or 'Ready')
end
local function new_state(ctx)
  local state = { source = ctx, session = Session.new(), busy = false, locations = {}, activity = 'Ready' }
  state.chat_buf = scratch('sapho://chat/' .. ctx.buf, true)
  state.input_buf = scratch('sapho://input/' .. ctx.buf, false)
  state.chat = Chat.new(state.chat_buf)
  states[ctx.buf] = state
  function state.cancel() if state.handle then state.handle.cancel() end end
  function state.submit()
    if not Context.valid(state.source.buf) then vim.notify('Sapho: source buffer is unavailable', vim.log.levels.ERROR); return end
    local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    local prompt = table.concat(lines, '\n')
    if prompt:match('^%s*$') then return end
    if state.busy then
      if state.handle then state.handle.steer(prompt) end
      return
    end
    state.busy = true; state.draft = lines; state.locations = {}
    set_activity(state, '● Working')
    vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { '' })
    state.chat:line('## You · ' .. safe_label(state.source.path) .. ' (changedtick ' .. vim.api.nvim_buf_get_changedtick(state.source.buf) .. ')')
    for _, line in ipairs(lines) do state.chat:line(line) end
    state.chat:line('')
    local live = Context.live(state.source)
    local agent = M._agent or require('sapho.agent')
    local handle = agent.start(state.session, prompt, live, function(ev)
      if not state.busy then return end
      if ev.type == 'response.output_text.delta' then
        set_activity(state, '● Responding')
        state.chat:delta('text', ev.delta)
      elseif ev.type == 'sapho.status' then
        if ev.status == 'paused after response' then set_activity(state, 'Ⅱ Paused') end
        state.chat:line('[Sapho: ' .. ev.status .. ']', true)
      elseif ev.type == 'sapho.tool_start' then
        set_activity(state, '● Reading')
        state.chat:end_block()
        local name = type(ev.name) == 'string' and ev.name:match('^[%w_]+$') and ev.name or 'unknown'
        local labels = { buffer_read = 'Reading', repo_read = 'Reading dependency', repo_list = 'Listing dependencies',
          lsp_definition = 'Checking definitions', lsp_references = 'Checking references',
          lsp_document_symbols = 'Checking symbols', lsp_diagnostics = 'Checking diagnostics',
          editor_context = 'Checking source context' }
        local target = (name == 'buffer_read' or name == 'lsp_definition' or name == 'lsp_references')
          and (' ' .. safe_label(state.source.path)) or ''
        state.chat:line('[' .. (labels[name] or 'Unknown read') .. target .. ']', true)
      elseif ev.type == 'sapho.tool_end' then
        set_activity(state, '● Working')
        -- Routine activity is subdued; errors and scope changes stay legible.
        state.chat:line(ev.error and '[read failed]' or '[read complete]', not ev.error)
        local ok, result = pcall(vim.json.decode, ev.output or '')
        if ok and type(result) == 'table' then
          for _, key in ipairs({ 'definitions', 'references', 'symbols' }) do
            for _, loc in ipairs(result[key] or {}) do
              if #state.locations < 100 and (loc.path or loc.uri) then state.locations[#state.locations + 1] = loc end
            end
          end
          if ev.name == 'repo_read' or ev.name == 'repo_list' then
            state.chat:line('[Expanded scope: ' .. safe_label(result.path or result.buffer or result.directory or 'repository') .. ']')
          end
        end
      end
    end, function(result, err)
      state.busy = false; state.handle = nil
      set_activity(state, err and (err == 'cancelled' and '× Cancelled' or '× Error') or '✓ Done')
      state.chat:end_block()
      state.chat:line(err and ('[incomplete: ' .. err .. ']') or '[complete]', not err)
      if #state.locations > 0 then state.chat:line('[locations: :SaphoLocations to select]') end
      if err and vim.api.nvim_buf_is_valid(state.input_buf) and
          table.concat(vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), '\n') == '' then
        vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, state.draft)
      end
      state.draft = nil
    end, { provider = M._provider, tool_deps = { context = function() return Context.live(state.source) end } })
    if state.busy then state.handle = handle end
  end
  vim.keymap.set('n', '<CR>', state.submit, { buffer = state.input_buf, silent = true })
  vim.keymap.set('i', '<C-s>', function() vim.cmd('stopinsert'); vim.schedule(state.submit) end,
    { buffer = state.input_buf, silent = true })
  for _, buf in ipairs({ state.input_buf, state.chat_buf }) do
    vim.keymap.set({ 'n', 'i' }, '<C-c>', state.cancel, { buffer = buf, silent = true })
    vim.keymap.set('n', 'q', function() hide(state) end, { buffer = buf, silent = true, desc = 'Hide Sapho' })
  end
  state.winclosed_autocmd = vim.api.nvim_create_autocmd('WinClosed', { callback = function(ev)
    local closed = tonumber(ev.match)
    if state.hiding or (closed ~= state.input_win and closed ~= state.chat_win) then return end
    vim.schedule(function()
      if closed == state.input_win or closed == state.chat_win then hide(state) end
    end)
  end })
  state.mode_autocmd = vim.api.nvim_create_autocmd('ModeChanged', { callback = function()
    if visible(state.input_win) and vim.api.nvim_get_current_win() == state.input_win then
      update_input_mode(state, vim.v.event.new_mode)
    end
  end })
  state.winenter_autocmd = vim.api.nvim_create_autocmd('WinEnter', { callback = function()
    if visible(state.input_win) and vim.api.nvim_get_current_win() == state.input_win then
      update_input_mode(state, vim.api.nvim_get_mode().mode)
    end
  end })
  return state
end
local function prompt(ctx, question, append_draft)
  if not Context.valid(ctx.buf) then vim.notify('Sapho: source buffer is unavailable', vim.log.levels.ERROR); return end
  local state = states[ctx.buf] or new_state(ctx)
  state.source = ctx
  local text = question .. '\n\nSource: ' .. ctx.path .. ' (buffer ' .. ctx.buf .. ', cursor ' .. ctx.line .. ':' .. ctx.column .. ')'
  if ctx.selection then
    text = text .. '\n\nQuoted selection (pinned at changedtick ' .. ctx.changedtick .. ') from ' .. ctx.path .. ':' ..
      ctx.selection_info.first .. '–' .. ctx.selection_info.last ..
      (ctx.selection_info.truncated and ' (truncated)' or '') .. ':\n' ..
      table.concat(vim.tbl_map(function(line) return '> ' .. line end,
        vim.split(ctx.selection, '\n', { plain = true })), '\n')
  end
  local question_line
  if text ~= '' and not state.busy then
    local old_lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    local old = table.concat(old_lines, '\n')
    local new_lines = vim.split(text, '\n', { plain = true })
    if old:match('^%s*$') then
      vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, new_lines)
      question_line = 1
    elseif append_draft then
      question_line = #old_lines + 2
      vim.api.nvim_buf_set_lines(state.input_buf, -1, -1, false, vim.list_extend({ '' }, new_lines))
    end
  end
  show(state)
  if question_line and visible(state.input_win) then
    vim.api.nvim_win_set_cursor(state.input_win, { question_line, 0 })
  end
end
function M.setup(opts)
  local cfg = config.setup(opts)
  if cfg.keymap and (vim.fn.maparg(cfg.keymap, 'n') ~= '' or vim.fn.maparg(cfg.keymap, 'x') ~= '') then
    vim.notify('Sapho: keymap already in use; mapping not installed', vim.log.levels.WARN)
  elseif cfg.keymap then
    vim.keymap.set({ 'n', 'x' }, cfg.keymap, function() M.open() end, { desc = 'Open Sapho chat' })
  end
  return cfg
end
local function ask_selection(ctx)
  if states[ctx.buf] and states[ctx.buf].busy then
    vim.notify('Sapho: finish or cancel the active request before asking about another selection', vim.log.levels.INFO)
    return
  end
  prompt(ctx, 'What would you like to know about this selection?', true)
end
function M.open(cmd)
  local ctx, err = cmd and Context.capture_command(cmd) or Context.capture()
  if not ctx then vim.notify('Sapho: ' .. err, vim.log.levels.ERROR); return end
  -- Visual :Sapho carries an explicit Ex range even though Visual mode has ended.
  if cmd and ((cmd.range and cmd.range > 0) or ctx.commandline_visual) then
    if not ctx.selection then
      vim.notify('Sapho: could not capture text in the requested range; select non-empty text in a source buffer', vim.log.levels.WARN)
      return
    end
    ask_selection(ctx)
    return
  end
  if ctx.selection then ask_selection(ctx)
  elseif states[ctx.buf] then show(states[ctx.buf])
  else prompt(ctx, 'What does this buffer do?') end
end
function M.toggle()
  local buf = vim.api.nvim_get_current_buf()
  local state = states[buf]
  if not state then
    for _, entry in pairs(states) do
      if entry.chat_buf == buf or entry.input_buf == buf then state = entry; break end
    end
  end
  if not state then vim.notify('Sapho: no conversation for this buffer', vim.log.levels.INFO); return end
  if visible(state.input_win) and visible(state.chat_win) then hide(state)
  else
    if buf == state.source.buf then state.source.win = vim.api.nvim_get_current_win() end
    show(state)
  end
end
function M.ask() M.open() end
function M.action(kind)
  local buf = vim.api.nvim_get_current_buf()
  local state = states[buf]
  if not state then
    for _, entry in pairs(states) do
      if entry.chat_buf == buf or entry.input_buf == buf then state = entry; break end
    end
  end
  if not state then vim.notify('Sapho: no active source conversation', vim.log.levels.INFO); return end
  if kind == 'cancel' then state.cancel()
  elseif kind == 'locations' then
    if #state.locations == 0 then vim.notify('Sapho: no locations yet', vim.log.levels.INFO)
    else Picker.locations(state.locations, state.source.win) end
  elseif kind == 'new' then
    state.cancel(); state.session = Session.new(); state.locations = {}
    set_activity(state, 'Ready')
    vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { '' })
    state.chat:line('[New conversation · ' .. safe_label(state.source.path) .. ']')
  elseif kind == 'pause' then
    if state.handle then
      if state.handle.status() == 'paused' then
        if state.handle.resume() then set_activity(state, '● Working') end
      else state.handle.pause() end
    else vim.notify('Sapho: no active request', vim.log.levels.INFO) end
  end
end
local function retire(state)
  states[state.source.buf] = nil
  state.cancel()
  stop_spinner(state)
  state.chat:close()
  vim.api.nvim_del_autocmd(state.winclosed_autocmd)
  vim.api.nvim_del_autocmd(state.mode_autocmd)
  vim.api.nvim_del_autocmd(state.winenter_autocmd)
  hide(state)
  for _, buf in ipairs({ state.chat_buf, state.input_buf }) do
    if vim.api.nvim_buf_is_valid(buf) then vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end) end
  end
end
vim.api.nvim_create_autocmd('BufWipeout', { callback = function(ev)
  local state = states[ev.buf]
  if state then retire(state); return end
  for _, entry in pairs(states) do
    if entry.chat_buf == ev.buf or entry.input_buf == ev.buf then
      retire(entry); return
    end
  end
end })
return M
