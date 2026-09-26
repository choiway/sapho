local Agent = require('sapho.agent')
local Session = require('sapho.session')
local function harness(registry)
  local h = { calls = {}, events = {}, done = {}, session = Session.new(), cancels = 0, tools = registry }
  h.provider = { start = function(input, on_event, on_done, deps)
    local call = { input = vim.deepcopy(input), event = on_event, done = on_done, deps = deps }
    h.calls[#h.calls + 1] = call
    return { cancel = function() h.cancels = h.cancels + 1; on_done(nil, 'cancelled') end }
  end }
  function h:start(prompt)
    self.handle = Agent.start(self.session, prompt or 'question', {}, function(ev)
      assert.is_false(vim.in_fast_event()); self.events[#self.events + 1] = ev
    end, function(result, err)
      assert.is_false(vim.in_fast_event()); self.done[#self.done + 1] = { result, err }
    end, { provider = self.provider, registry = self.tools })
    return self.calls[#self.calls]
  end
  return h
end
local function call(id, name)
  return { type = 'function_call', name = name or 'buffer_read', call_id = id, arguments = '{}' }
end
local function reply(text)
  return { type = 'message', role = 'assistant', content = { { type = 'output_text', text = text } } }
end

describe('sapho.agent', function()
  it('dispatches multiple calls in order, pairs every call in one next request, and commits authoritative history', function()
    local pending, names = {}, {}
    local registry = { run = function(_, item, _, cb)
      names[#names + 1] = item.name
      pending[#pending + 1] = cb
      return function() end
    end }
    local h = harness(registry)
    local first = h:start()
    assert.same({ 'buffer_read', 'lsp_diagnostics', 'lsp_definition', 'editor_context', 'lsp_references', 'lsp_document_symbols', 'repo_list', 'repo_read' },
      vim.tbl_map(function(t) return t.name end, first.deps.tools))
    first.event({ type = 'response.output_text.delta', delta = 'partial' })
    local reasoning = { type = 'reasoning', encrypted_content = 'CIPHERTEXT' }
    first.done({ id = 'r1', output = { reasoning, call('a'), call('b', 'lsp_diagnostics') },
      usage = { input_tokens = 10, output_tokens = 3 } })
    assert.are.equal(1, #pending)
    assert.are.equal(1, #h.calls)
    pending[1]('{"lines":["unsaved"]}')
    assert.are.equal(2, #pending)
    assert.are.equal(1, #h.calls)
    pending[2]('{"diagnostics":[]}')
    assert.same({ 'buffer_read', 'lsp_diagnostics' }, names)
    assert.are.equal(2, #h.calls)
    assert.are.equal('CIPHERTEXT', h.calls[2].input[2].encrypted_content)
    assert.are.equal('a', h.calls[2].input[3].call_id)
    assert.are.equal('b', h.calls[2].input[4].call_id)
    assert.are.equal('function_call_output', h.calls[2].input[5].type)
    assert.are.equal('a', h.calls[2].input[5].call_id)
    assert.are.equal('b', h.calls[2].input[6].call_id)
    h.calls[2].done({ id = 'r2', output = { reply('answer') },
      usage = { input_tokens = 20, output_tokens = 5 } })
    assert.are.equal(1, #h.done)
    assert.are.equal(2, h.done[1][1].tool_calls)
    assert.are.equal(30, h.done[1][1].usage.input_tokens)
    assert.are.equal(8, h.done[1][1].usage.output_tokens)
    local history = h.session:input('follow-up')
    assert.are.equal(8, #history)
    assert.are.equal('CIPHERTEXT', history[2].encrypted_content)
    assert.are.equal('follow-up', history[8].content)
    assert.are.equal('sapho.tool_start', h.events[2].type)
  end)
  it('rolls back on a failed continuation and ignores late events', function()
    local h = harness({ run = function(_, _, _, cb) cb('{}'); return function() end end })
    local first = h:start()
    first.done({ output = { call('a') }, usage = { input_tokens = 2 } })
    assert.are.equal(2, #h.calls)
    local second = h.calls[2]
    second.event({ type = 'response.output_text.delta', delta = 'partial' })
    second.done(nil, 'server failed')
    second.event({ type = 'response.output_text.delta', delta = 'late' })
    second.done({ output = { reply('late') } })
    assert.are.equal(3, #h.events) -- start, completion and partial continuation, not late text
    assert.are.equal(1, #h.done)
    assert.are.equal('server failed', h.done[1][2])
    assert.same({ { role = 'user', content = 'new prompt' } }, h.session:input('new prompt'))
  end)
  it('never dispatches tools from an incomplete response, including partial call events', function()
    local executed = 0
    local h = harness({ run = function() executed = executed + 1 end })
    local first = h:start()
    first.event({ type = 'response.output_item.done', item = call('a') })
    first.done(nil, 'response incomplete')
    assert.are.equal(0, executed)
    assert.are.equal('response incomplete', h.done[1][2])
    assert.are.equal(1, #h.session:input('next'))
  end)
  it('handles synchronous provider and tool callbacks without losing the handle', function()
    local session = Session.new()
    local count, completed = 0, 0
    local provider = { start = function(_, _, done)
      count = count + 1
      if count == 1 then done({ output = { call('sync') } })
      else done({ output = { reply('ok') } }) end
      return { cancel = function() error('already completed') end }
    end }
    Agent.start(session, 'sync request', {}, function() end, function(result)
      assert.is_not_nil(result); completed = completed + 1
    end, { provider = provider, registry = { run = function(_, _, _, cb)
      cb('{}'); return function() end
    end } })
    assert.are.equal(2, count)
    assert.are.equal(1, completed)
    assert.are.equal(5, #session:input('next'))
  end)
  it('cancels during a tool, once, suppressing late callbacks and history', function()
    local callback, cancelled = nil, 0
    local h = harness({ run = function(_, _, _, cb)
      callback = cb; return function() cancelled = cancelled + 1 end
    end })
    local first = h:start()
    first.done({ output = { call('a') } })
    h.handle.cancel(); h.handle.cancel()
    assert.are.equal(1, cancelled)
    callback('{}')
    assert.are.equal(1, #h.calls)
    assert.are.equal(1, #h.done)
    assert.are.equal('cancelled', h.done[1][2])
    assert.are.equal(1, #h.session:input('next'))
  end)
  it('cancels an active provider and requests a final answer when exploration reaches its cap', function()
    local h = harness(); local first = h:start()
    h.handle.cancel(); first.event({ type = 'response.output_text.delta', delta = 'late' })
    first.done({ output = { reply('late') } })
    assert.are.equal(1, h.cancels)
    assert.are.equal(0, #h.events)
    assert.are.equal('cancelled', h.done[1][2])
    local many = harness(); first = many:start()
    local calls = {}
    for i = 1, 9 do calls[#calls + 1] = call('c' .. i) end
    first.done({ output = calls })
    assert.matches('Too many', many.done[1][2])
    assert.are.equal(1, #many.session:input('next'))
    local missing = harness(); first = missing:start()
    first.done({ output = { call(nil) } })
    assert.matches('call_id', missing.done[1][2])
    assert.are.equal(1, #missing.calls)
    local loop = harness({ run = function(_, _, _, cb) cb('{}'); return function() end end })
    loop:start()
    for i = 1, 19 do loop.calls[i].done({ output = { call('c' .. i, 'repo_read') } }) end
    assert.are.equal(20, #loop.calls)
    assert.same({}, loop.calls[20].deps.tools)
    assert.are.equal('c19', loop.calls[20].input[#loop.calls[20].input].call_id)
    assert.are.equal('function_call_output', loop.calls[20].input[#loop.calls[20].input].type)
    loop.calls[20].done({ output = { reply('walkthrough') } })
    assert.are.equal(1, #loop.done)
    assert.is_nil(loop.done[1][2])
    assert.are.equal(19, loop.done[1][1].tool_calls)
    assert.are.equal(40, #loop.session.history)
    assert.are.equal('sapho.status', loop.events[#loop.events].type)
    assert.are.equal('finishing without more tools', loop.events[#loop.events].status)
  end)
  it('does not persist unpaired calls from a nonconforming final-only response', function()
    local loop = harness({ run = function(_, _, _, cb) cb('{}'); return function() end end })
    loop:start()
    for i = 1, 19 do loop.calls[i].done({ output = { call('c' .. i) } }) end
    loop.calls[20].done({ output = { call('unexpected') } })
    assert.matches('final answer', loop.done[1][2])
    assert.are.equal(1, #loop.session:input('follow-up'))
  end)
  it('rejects commit if the UI has closed before completion', function()
    local h = harness()
    local visible = true
    local handle = Agent.start(h.session, 'test', {}, function() end,
      function(result, err) h.done[#h.done + 1] = { result, err } end,
      { provider = h.provider, can_commit = function() return visible end })
    visible = false
    h.calls[1].done({ output = { reply('answer') } })
    assert.are.equal('cancelled', h.done[1][2])
    assert.are.equal(1, #h.session:input('next'))
    handle.cancel()
    assert.are.equal(1, #h.done)
  end)
end)
