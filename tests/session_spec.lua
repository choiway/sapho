local Session = require('sapho.session')
describe('sapho.session', function()
  it('keeps an append-only authoritative history and returns isolated snapshots', function()
    local s = Session.new()
    assert.same({ { role = 'user', content = 'first' } }, s:input('first'))
    local output = {
      { type = 'reasoning', encrypted_content = 'ciphertext', summary = { { type = 'summary_text', text = 'thinking' } } },
      { type = 'message', role = 'assistant', content = { { type = 'output_text', text = 'answer' } } },
    }
    s:commit('first', { output = output, usage = { input_tokens = 10, output_tokens = 5 } })
    output[1].encrypted_content = 'changed'
    local input = s:input('second')
    assert.are.equal('ciphertext', input[2].encrypted_content)
    assert.same({ role = 'user', content = 'second' }, input[4])
    input[2].encrypted_content = 'corrupt'
    assert.are.equal('ciphertext', s:input('third')[2].encrypted_content)
    s:commit('second', { output = {}, usage = { input_tokens = 15, output_tokens = 3 } })
    local last, total = s:usage()
    assert.are.equal(15, last.input_tokens)
    assert.same({ input_tokens = 25, output_tokens = 8 }, total)
    assert.are.equal('ciphertext', s:input('third')[2].encrypted_content)
  end)
  it('pairs unexpected function calls with synthetic errors, without a tool execution', function()
    local s = Session.new()
    s:commit('use tool', { output = {
      { type = 'reasoning', encrypted_content = 'encrypted' },
      { type = 'function_call', call_id = 'c1', name = 'run', arguments = '{}' },
      { type = 'function_call', call_id = 'c2', name = 'read', arguments = '{}' },
    } })
    local input = s:input('followup')
    assert.same({ type = 'function_call_output', call_id = 'c1', output = 'Tool execution not available yet.' }, input[5])
    assert.same({ type = 'function_call_output', call_id = 'c2', output = 'Tool execution not available yet.' }, input[6])
    assert.are.equal('followup', input[7].content)
    assert.are.equal('encrypted', input[2].encrypted_content)
  end)
  it('atomically commits an answered tool turn with aggregated usage', function()
    local s = Session.new()
    local items = { { type = 'reasoning', encrypted_content = 'opaque' },
      { type = 'function_call', call_id = 'one', name = 'buffer_read', arguments = '{}' },
      { type = 'function_call_output', call_id = 'one', output = '{"lines":["a"]}' },
      { type = 'message', role = 'assistant', content = 'done' } }
    s:commit_turn('inspect', items, {
      { input_tokens = 3, output_tokens = 2, input_tokens_details = { cached_tokens = 1 } },
      { input_tokens = 10, output_tokens = 4, input_tokens_details = { cached_tokens = 7 } },
    })
    local next_input = s:input('next')
    assert.are.equal(6, #next_input)
    assert.are.equal('opaque', next_input[2].encrypted_content)
    assert.are.equal('function_call_output', next_input[4].type)
    items[1].encrypted_content = 'changed'
    assert.are.equal('opaque', s:input('next')[2].encrypted_content)
    local last, totals = s:usage()
    assert.are.equal(13, last.input_tokens)
    assert.are.equal(6, last.output_tokens)
    assert.are.equal(8, last.input_tokens_details.cached_tokens)
    assert.are.equal(13, totals.input_tokens)
  end)
  it('retains a hundred turns in order', function()
    local s = Session.new()
    for i = 1, 100 do
      local input = s:input('prompt ' .. i)
      assert.are.equal(2 * i - 1, #input)
      s:commit('prompt ' .. i, { output = { { type = 'message', role = 'assistant', content = i } } })
    end
    local input = s:input('next')
    assert.are.equal(201, #input)
    assert.are.equal('prompt 1', input[1].content)
    assert.are.equal('prompt 100', input[199].content)
  end)
  it('does not commit a turn if its usage is invalid', function()
    local s = Session.new()
    assert.has_error(function() s:commit_turn('broken', {}, { vim.NIL }) end)
    assert.same({ { role = 'user', content = 'next' } }, s:input('next'))
  end)
  it('does not alter history until a successful turn is committed', function()
    local s = Session.new()
    s:input('failed')
    assert.same({ { role = 'user', content = 'next' } }, s:input('next'))
    assert.is_nil(select(1, s:usage()))
  end)
end)
