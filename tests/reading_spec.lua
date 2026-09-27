local Context = require('sapho.context')
local Tools = require('sapho.tools')
local Agent = require('sapho.agent')
local Session = require('sapho.session')
describe('sapho reading UX', function()
  local buf
  local function close_floats()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= '' then
        vim.api.nvim_win_close(win, true)
      end
    end
  end
  before_each(function()
    close_floats()
    vim.cmd('only!')
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abcéxyz', 'one two', 'three four' })
  end)
  after_each(function()
    require('sapho')._provider = nil
    require('sapho')._agent = nil
    close_floats()
    vim.cmd('only!')
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end)
  it('extracts reversed character, line, block and bounded selections', function()
    assert.same({ text = 'bcéxy', first = 1, last = 1, truncated = false, mode = 'v' },
      Context.selection(buf, { 0, 1, 7 }, { 0, 1, 2 }, 'v'))
    assert.are.equal('abcéxyz\none two\nthree four', Context.selection(buf, { 0, 3, 1 }, { 0, 1, 1 }, 'V').text)
    assert.are.equal('bc\nne\nhr', Context.selection(buf, { 0, 3, 2 }, { 0, 1, 3 }, '\22').text)
    assert.is_nil(Context.selection(buf, { 0, 1, 9 }, { 0, 1, 9 }, 'v'))
  end)
  it('rejects a forged edit with paired output and never modifies source', function()
    local calls, session = {}, Session.new()
    local provider = { start = function(input, _, done)
      calls[#calls + 1] = { input = vim.deepcopy(input), done = done }
      return { cancel = function() end }
    end }
    local ctx = Context.capture()
    Agent.start(session, 'Explain', ctx, function() end, function() end, { provider = provider })
    calls[1].done({ output = { { type = 'function_call', name = 'buffer_edit', call_id = 'forged',
      arguments = '{"buffer":null}' } } })
    assert.are.equal(2, #calls)
    assert.same({ error = 'Unknown tool' }, vim.json.decode(calls[2].input[3].output))
    assert.are.equal('abcéxyz', vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    calls[2].done({ output = { { type = 'message', content = 'Done' } } })
    assert.are.equal(4, #session.history)
  end)
  it('reads current unsaved text but never redirects after source wipe', function()
    local ctx = Context.capture()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'changed unsaved' })
    local result
    Tools.new():run({ name = 'buffer_read', arguments = '{"buffer":null,"start_line":null,"end_line":null}' }, ctx,
      function(raw) result = vim.json.decode(raw) end)
    assert.are.equal('changed unsaved', result.lines[1])
    assert.are.equal(vim.api.nvim_buf_get_changedtick(buf), result.changedtick)
    vim.api.nvim_buf_delete(buf, { force = true })
    Tools.new():run({ name = 'buffer_read', arguments = '{"buffer":null}' }, ctx,
      function(raw) result = vim.json.decode(raw) end)
    assert.matches('unavailable', result.error)
  end)
  it('returns bounded references and symbols without moving the editor', function()
    local ctx = Context.capture()
    local win = vim.api.nvim_get_current_win()
    local pos = vim.api.nvim_win_get_cursor(win)
    local deps = {
      clients = function() return { { id = 4, offset_encoding = 'utf-8' } } end,
      request_all = function(_, method, _, cb)
        if method == 'textDocument/references' then
          cb({ [4] = { result = { { uri = vim.uri_from_bufnr(buf), range = { start = { line = 0, character = 1 } } } } } })
        else
          cb({ [4] = { result = { { name = 'thing', kind = 12,
            selectionRange = { start = { line = 1, character = 2 } } } } } })
        end
        return function() end
      end,
    }
    local results = {}
    for _, name in ipairs({ 'lsp_references', 'lsp_document_symbols' }) do
      Tools.new(deps):run({ name = name, arguments = name == 'lsp_references' and
        '{"buffer":null,"line":null,"column":null}' or '{"buffer":null}' }, ctx,
        function(raw) results[name] = vim.json.decode(raw) end)
    end
    assert.are.equal(1, results.lsp_references.references[1].line)
    assert.are.equal('thing', results.lsp_document_symbols.symbols[1].name)
    assert.same(pos, vim.api.nvim_win_get_cursor(win))
    assert.are.equal(buf, vim.api.nvim_win_get_buf(win))
  end)
  it('retires a conversation and cancels its request on source wipe', function()
    local sapho = require('sapho')
    local cancelled, started = 0, 0
    sapho._provider = { start = function(_, _, _)
      started = started + 1
      return { cancel = function() cancelled = cancelled + 1 end }
    end }
    sapho.ask()
    local input = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(input, 0, -1, false, { 'explain' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    assert.are.equal(1, started)
    sapho.toggle() -- return to the source before wiping it
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.are.equal(1, cancelled)
  end)
  it('hides and reopens a streaming chat without cancelling or losing the draft', function()
    local sapho = require('sapho')
    local calls, cancelled = {}, 0
    sapho._provider = { start = function(_, event, done)
      calls[#calls + 1] = { event = event, done = done }
      return { cancel = function() cancelled = cancelled + 1 end }
    end }
    local source_win = vim.api.nvim_get_current_win()
    local source_view = vim.fn.winsaveview()
    sapho.ask()
    local input = vim.api.nvim_get_current_buf()
    local input_win = vim.api.nvim_get_current_win()
    assert.are.equal('editor', vim.api.nvim_win_get_config(input_win).relative)
    local chat_win = vim.fn.bufwinid('sapho://chat/' .. buf)
    assert.are.equal('', vim.wo[input_win].winbar)
    assert.are.equal('[Ready] Sapho', vim.wo[chat_win].winbar:sub(1, #'[Ready] Sapho'))
    local available = math.max(6, vim.o.lines - vim.o.cmdheight - 4)
    local expected_height = math.min(math.max(8, math.floor(vim.o.lines * 0.8)), available)
    assert.are.equal(expected_height, vim.api.nvim_win_get_height(chat_win) + vim.api.nvim_win_get_height(input_win) + 2)
    vim.api.nvim_buf_set_lines(input, 0, -1, false, { 'question' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    assert.are.equal(1, #calls)
    assert.are.equal('', vim.wo[input_win].winbar)
    assert.matches('Working]', vim.wo[chat_win].winbar, 1, true)
    vim.api.nvim_buf_set_lines(input, 0, -1, false, { 'next draft' })
    sapho.toggle()
    assert.are.equal(0, cancelled)
    assert.are.equal(source_win, vim.api.nvim_get_current_win())
    assert.same(source_view, vim.fn.winsaveview())
    assert.is_false(vim.api.nvim_win_is_valid(input_win))
    sapho.toggle()
    assert.are.equal('', vim.wo[vim.api.nvim_get_current_win()].winbar)
    assert.matches('Working]', vim.wo[vim.fn.bufwinid('sapho://chat/' .. buf)].winbar, 1, true)
    sapho.toggle()
    calls[1].event({ type = 'response.output_text.delta', delta = 'answer while hidden' })
    sapho.toggle()
    assert.matches('Responding]', vim.wo[vim.fn.bufwinid('sapho://chat/' .. buf)].winbar, 1, true)
    sapho.toggle()
    calls[1].done({ output = { { type = 'message', content = { { type = 'output_text', text = 'answer while hidden' } } } } })
    sapho.toggle()
    assert.matches('[✓ Done]', vim.wo[vim.fn.bufwinid('sapho://chat/' .. buf)].winbar, 1, true)
    assert.are.equal('', vim.wo[vim.api.nvim_get_current_win()].winbar)
    assert.are.equal(input, vim.api.nvim_get_current_buf())
    assert.are.equal('next draft', vim.api.nvim_buf_get_lines(input, 0, 1, false)[1])
    local chat = vim.fn.bufnr('sapho://chat/' .. buf)
    assert.matches('answer while hidden', table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false), '\n'), 1, true)
    assert.are.equal(0, cancelled)
    vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true) -- normal :close hides both floats
    vim.wait(30)
    assert.are.equal(0, cancelled)
    assert.are.equal(source_win, vim.api.nvim_get_current_win())
    sapho.toggle()
    assert.are.equal(input, vim.api.nvim_get_current_buf())
  end)
  it('colors the input border by mode and keeps the transcript border muted', function()
    local sapho = require('sapho')
    sapho.ask()
    local input_win = vim.api.nvim_get_current_win()
    local chat_win = vim.fn.bufwinid('sapho://chat/' .. buf)
    assert.matches('FloatBorder:SaphoInputBorderNormal', vim.wo[input_win].winhighlight, 1, true)
    assert.matches('FloatBorder:SaphoTranscriptBorder', vim.wo[chat_win].winhighlight, 1, true)
    assert.are.equal('Comment', vim.api.nvim_get_hl(0, { name = 'SaphoInputBorderNormal' }).link)
    assert.are.equal('DiagnosticOk', vim.api.nvim_get_hl(0, { name = 'SaphoInputBorderInsert' }).link)
    local seen_insert = false
    local observer = vim.api.nvim_create_autocmd('ModeChanged', { callback = function()
      if vim.v.event.new_mode == 'i' then
        seen_insert = vim.wo[input_win].winhighlight:find('FloatBorder:SaphoInputBorderInsert', 1, true) ~= nil
      end
    end })
    -- A headless feedkeys call returns to Normal mode before it returns to Lua.
    vim.api.nvim_feedkeys('i', 'xt', false)
    vim.api.nvim_del_autocmd(observer)
    assert.is_true(seen_insert)
    assert.matches('FloatBorder:SaphoInputBorderNormal', vim.wo[input_win].winhighlight, 1, true)
    vim.api.nvim_set_current_win(chat_win)
    vim.api.nvim_set_current_win(input_win)
    assert.matches('FloatBorder:SaphoInputBorderNormal', vim.wo[input_win].winhighlight, 1, true)
    sapho.toggle()
    sapho.toggle()
    assert.matches('FloatBorder:SaphoInputBorderNormal', vim.wo[vim.api.nvim_get_current_win()].winhighlight, 1, true)
  end)
  it('animates the transcript header only while visible and working', function()
    local sapho = require('sapho')
    local event, done, phase
    sapho._agent = { start = function(_, _, _, on_event, on_done)
      event, done, phase = on_event, on_done, 'streaming'
      return {
        status = function() return phase end,
        pause = function() phase = 'paused'; event({ type = 'sapho.status', status = 'paused after response' }) end,
        resume = function() phase = 'streaming'; return true end,
        cancel = function() done(nil, 'cancelled') end,
      }
    end }
    sapho.ask()
    vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { 'question' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    local input_win = vim.api.nvim_get_current_win()
    local chat_win = vim.fn.bufwinid('sapho://chat/' .. buf)
    local function displayed(win)
      return vim.api.nvim_eval_statusline(vim.wo[win].winbar,
        { winid = win, use_winbar = true, maxwidth = vim.api.nvim_win_get_width(win) }).str
    end
    assert.are.equal('', vim.wo[input_win].winbar)
    local first = displayed(chat_win)
    assert.are.equal('[⠋ Working] Sapho', first:sub(1, #'[⠋ Working] Sapho'))
    assert.are.equal('DiagnosticInfo', vim.api.nvim_get_hl(0, { name = 'SaphoSpinner' }).link)
    local rendered = vim.api.nvim_eval_statusline(vim.wo[chat_win].winbar,
      { winid = chat_win, use_winbar = true, maxwidth = vim.api.nvim_win_get_width(chat_win), highlights = true })
    local spinner_start = assert(first:find('⠋', 1, true)) - 1
    local spinner_hl
    for i, hl in ipairs(rendered.highlights) do
      if hl.group == 'SaphoSpinner' then spinner_hl = rendered.highlights[i + 1]; assert.are.equal(spinner_start, hl.start) end
    end
    assert.is_not_nil(spinner_hl)
    assert.are.equal(spinner_start + #'⠋', spinner_hl.start)
    assert.are_not.equal('SaphoSpinner', spinner_hl.group)
    assert.is_true(vim.wait(600, function() return displayed(chat_win) ~= first end))
    assert.are.equal('', vim.wo[input_win].winbar)
    event({ type = 'response.output_text.delta', delta = 'hello' })
    assert.matches('Responding]', vim.wo[chat_win].winbar, 1, true)
    sapho.action('pause')
    assert.matches('[Ⅱ Paused]', vim.wo[chat_win].winbar, 1, true)
    local paused = vim.wo[chat_win].winbar
    vim.wait(250)
    assert.are.equal(paused, vim.wo[chat_win].winbar)
    sapho.action('pause')
    assert.matches('Working]', vim.wo[chat_win].winbar, 1, true)
    sapho.toggle()
    assert.is_false(vim.api.nvim_win_is_valid(input_win))
    sapho.toggle()
    input_win = vim.api.nvim_get_current_win()
    chat_win = vim.fn.bufwinid('sapho://chat/' .. buf)
    assert.are.equal('', vim.wo[input_win].winbar)
    first = displayed(chat_win)
    assert.are.equal('[⠋ Working] Sapho', first:sub(1, #'[⠋ Working] Sapho'))
    assert.is_true(vim.wait(600, function() return displayed(chat_win) ~= first end))
    done({ output = {} })
    assert.matches('[✓ Done]', vim.wo[chat_win].winbar, 1, true)
    local finished = vim.wo[chat_win].winbar
    vim.wait(250)
    assert.are.equal(finished, vim.wo[chat_win].winbar)
  end)
  it('clears the working indicator after cancellation or failure', function()
    local sapho = require('sapho')
    local cancelled, fail = 0, nil
    sapho._provider = { start = function(_, _, done)
      fail = done
      return { cancel = function() cancelled = cancelled + 1 end }
    end }
    sapho.ask()
    vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { 'question' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    local input_win = vim.api.nvim_get_current_win()
    local chat_win = vim.fn.bufwinid('sapho://chat/' .. buf)
    assert.are.equal('', vim.wo[input_win].winbar)
    assert.matches('Working]', vim.wo[chat_win].winbar, 1, true)
    sapho.action('cancel')
    assert.are.equal(1, cancelled)
    assert.matches('[× Cancelled]', vim.wo[chat_win].winbar, 1, true)
    assert.is_nil(vim.wo[chat_win].winbar:find('Working]', 1, true))
    vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { 'retry' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    assert.matches('Working]', vim.wo[chat_win].winbar, 1, true)
    fail(nil, 'backend unavailable')
    assert.matches('[× Error]', vim.wo[chat_win].winbar, 1, true)
  end)
  it('starts a fresh model session with Ctrl-N in the input, including Insert mode', function()
    local sapho = require('sapho')
    local calls = {}
    sapho._provider = { start = function(input, _, done)
      calls[#calls + 1] = { input = vim.deepcopy(input), done = done }
      return { cancel = function() end }
    end }
    sapho.ask()
    local input_buf = vim.api.nvim_get_current_buf()
    local chat_win = vim.fn.bufwinid('sapho://chat/' .. buf)
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'old question' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    calls[1].done({ output = { { type = 'message', role = 'assistant',
      content = { { type = 'output_text', text = 'old answer' } } } } })
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'discard this draft' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('i<C-n><Esc>', true, false, true), 'xt', false)
    assert.same({ '' }, vim.api.nvim_buf_get_lines(input_buf, 0, -1, false))
    assert.matches('[Ready] Sapho', vim.wo[chat_win].winbar, 1, true)
    assert.same({ '' }, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(chat_win), 0, -1, false))
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'fresh question' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    assert.are.equal(2, #calls)
    assert.same({ { role = 'user', content = 'fresh question' } }, calls[2].input)
  end)
  it('cancels the old request with Ctrl-N from the transcript and ignores late callbacks', function()
    local sapho = require('sapho')
    local calls = {}
    sapho._provider = { start = function(input, event, done)
      local call = { input = vim.deepcopy(input), event = event, done = done, cancelled = 0 }
      calls[#calls + 1] = call
      return { cancel = function() call.cancelled = call.cancelled + 1 end }
    end }
    sapho.ask()
    local input_buf = vim.api.nvim_get_current_buf()
    local chat_win = vim.fn.bufwinid('sapho://chat/' .. buf)
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'old question' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    calls[1].event({ type = 'response.output_text.delta', delta = 'partially streamed text' })
    vim.api.nvim_set_current_win(chat_win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-n>', true, false, true), 'xt', false)
    assert.are.equal(1, calls[1].cancelled)
    assert.are.equal(input_buf, vim.api.nvim_get_current_buf())
    local chat_buf = vim.api.nvim_win_get_buf(chat_win)
    local before = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
    assert.same({ '' }, before)
    vim.wait(100) -- a queued stream flush must not restore the old text
    assert.same({ '' }, vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false))
    calls[1].event({ type = 'response.output_text.delta', delta = 'late text' })
    calls[1].done(nil, 'cancelled')
    assert.same(before, vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false))
    assert.matches('[Ready] Sapho', vim.wo[chat_win].winbar, 1, true)
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { 'fresh question' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    assert.same({ { role = 'user', content = 'fresh question' } }, calls[2].input)
  end)
  it('opens the chat directly from normal and visual mappings without submitting', function()
    local sapho = require('sapho')
    local requests = 0
    sapho._provider = { start = function() requests = requests + 1; return { cancel = function() end } end }
    sapho.setup({ keymap = '<F9>' })
    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('vll<F9>', true, false, true), 'xt', false)
      local input = vim.api.nvim_get_current_buf()
      local draft = table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n')
      assert.matches('What would you like to know about this selection?', draft, 1, true)
      assert.matches('> abc', draft, 1, true)
      assert.matches('pinned at changedtick', draft, 1, true)
      assert.are.equal(0, requests)
      vim.api.nvim_buf_set_lines(input, 0, 1, false, { 'my unsent question' })
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('vll<F9>', true, false, true), 'xt', false)
      local followup = table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n')
      assert.matches('my unsent question', followup, 1, true)
      assert.matches('> one', followup, 1, true)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<F9>', true, false, true), 'xt', false)
      assert.are.equal(input, vim.api.nvim_get_current_buf())
      assert.are.equal(followup, table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n'))
      assert.are.equal(0, requests)
    end)
    vim.keymap.del('n', '<F9>'); vim.keymap.del('x', '<F9>')
    require('sapho.config').setup({})
    if not ok then error(err) end
  end)
  it('captures a fresh characterwise visual selection from :Sapho, not old normal-mode marks', function()
    vim.cmd('runtime plugin/sapho.lua')
    local sapho = require('sapho')
    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('vlll:Sapho<CR>', true, false, true), 'xt', false)
      local input = vim.api.nvim_get_current_buf()
      local draft = table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n')
      assert.matches('> abcé', draft, 1, true)
      assert.matches('What would you like to know about this selection?', draft, 1, true)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(':Sapho<CR>', true, false, true), 'xt', false)
      assert.are.equal(input, vim.api.nvim_get_current_buf())
      assert.matches('> abcé', table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n'), 1, true)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      assert.is_nil(require('sapho.context').capture().selection) -- no stale visual marks
    end)
    if not ok then error(err) end
  end)
  it('keeps a visual selection even when the user deletes the Ex range before :Sapho', function()
    vim.cmd('runtime plugin/sapho.lua')
    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('vlll:<C-u>Sapho<CR>', true, false, true), 'xt', false)
      local input = vim.api.nvim_get_current_buf()
      local draft = table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n')
      assert.matches('> abcé', draft, 1, true)
      assert.matches('What would you like to know about this selection?', draft, 1, true)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('vll:<C-u><Esc>:Sapho<CR>', true, false, true), 'xt', false)
      assert.are.equal(input, vim.api.nvim_get_current_buf()) -- cancelled selection is not added
      assert.are.equal(draft, table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n'))
    end)
    if not ok then error(err) end
  end)
  it('keeps linewise and blockwise visual :Sapho ranges in the prompt', function()
    vim.cmd('runtime plugin/sapho.lua')
    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('Vj:Sapho<CR>', true, false, true), 'xt', false)
      local input = vim.api.nvim_get_current_buf()
      local draft = table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n')
      assert.matches('> one two\n> three four', draft, 1, true)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-v>jll:Sapho<CR>', true, false, true), 'xt', false)
      draft = table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n')
      assert.matches('> bcé\n> ne ', draft, 1, true)
    end)
    if not ok then error(err) end
  end)
  it('opens :Sapho directly and resumes the existing draft without a picker', function()
    vim.cmd('runtime plugin/sapho.lua')
    vim.cmd('Sapho')
    local input = vim.api.nvim_get_current_buf()
    assert.are.equal('sapho-input', vim.bo[input].filetype)
    vim.api.nvim_buf_set_lines(input, 0, -1, false, { 'my unsent draft' })
    vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
    vim.cmd('Sapho')
    assert.are.equal(input, vim.api.nvim_get_current_buf())
    assert.are.equal('my unsent draft', vim.api.nvim_buf_get_lines(input, 0, 1, false)[1])
  end)
  it('opens the chat without Telescope installed', function()
    local sapho = require('sapho')
    local loaded, preload = package.loaded['telescope.pickers'], package.preload['telescope.pickers']
    package.loaded['telescope.pickers'] = nil
    package.preload['telescope.pickers'] = function() error('missing Telescope') end
    local ok, err = pcall(sapho.open)
    package.loaded['telescope.pickers'], package.preload['telescope.pickers'] = loaded, preload
    if not ok then error(err) end
    assert.are.equal('sapho-input', vim.bo[vim.api.nvim_get_current_buf()].filetype)
  end)
  it('opens a prompt without sending and keeps source and separate sessions', function()
    local sapho = require('sapho')
    local requests = {}
    sapho._provider = { start = function(input, _, done)
      requests[#requests + 1] = { input = input, done = done }
      return { cancel = function() end }
    end }
    sapho.ask()
    assert.are.equal(0, #requests)
    local input = vim.api.nvim_get_current_buf()
    assert.matches('Source:', table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), '\n'))
    assert.is_true(vim.api.nvim_win_is_valid(vim.fn.bufwinid(buf)))
    vim.api.nvim_buf_set_lines(input, 0, -1, false, { 'first question' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    assert.are.equal(1, #requests)
    requests[1].done({ output = { { type = 'message', content = { { type = 'output_text', text = 'answer' } } } } })
    vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, other)
    sapho.ask()
    local second_input = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(second_input, 0, -1, false, { 'second question' })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
    assert.are.equal(2, #requests)
    assert.are.equal(1, #requests[2].input)
    vim.api.nvim_buf_delete(other, { force = true })
  end)
end)
