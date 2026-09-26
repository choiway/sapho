local sse = require('sapho.sse')
local function replay(bytes, cuts)
  local events = {}
  local d = sse.decoder(function(ev) events[#events + 1] = ev end)
  local start = 1
  for _, cut in ipairs(cuts) do
    d:feed(bytes:sub(start, cut))
    start = cut + 1
  end
  d:feed(bytes:sub(start)); d:finish()
  return events
end

local names = { 'text_only', 'reasoning_tool', 'multibyte', 'crlf', 'failed_midstream' }
local function fixture(name)
  local f = assert(io.open('tests/fixtures/sse/' .. name .. '.sse', 'rb'))
  local bytes = f:read('*a'); f:close()
  return bytes
end

local function deltas(events, kind)
  local out = {}
  for _, ev in ipairs(events) do
    if ev.type == kind then out[#out + 1] = ev.delta end
  end
  return table.concat(out)
end

describe('sapho.sse parser', function()
  it('parses comments, multiline data, fields, and resets the event name', function()
    local frames = {}
    local p = sse.parser(function(f) frames[#frames + 1] = f end)
    p:feed(': comment\nevent: ignored\n\nevent: foo\nid: x\nretry: 10\ndata: one\ndata:  two\n\n')
    p:feed('data: last')
    assert.are.equal('data: last', p:buffered())
    p:feed(''); p:finish()
    assert.same({ { event = 'foo', data = 'one\n two' }, { data = 'last' } }, frames)
  end)
  it('handles CRLF split across chunks', function()
    local frames = {}
    local p = sse.parser(function(f) frames[#frames + 1] = f end)
    p:feed('data: ok\r'); p:feed('\n\r'); p:feed('\n')
    assert.same({ { data = 'ok' } }, frames)
  end)
end)

describe('sapho.sse decoder', function()
  local function one(data, event)
    local events = {}
    local d = sse.decoder(function(ev) events[#events + 1] = ev end)
    d:feed((event and 'event: ' .. event .. '\n' or '') .. 'data: ' .. data .. '\n\n')
    return events[1]
  end
  it('emits parse errors instead of throwing', function()
    assert.are.equal('parse_error', one('{bad').type)
    assert.matches('output_index', one('{"type":"response.output_text.delta","delta":"x"}').err)
    assert.are.equal('parse_error', one('{"type":"other"}', 'different').type)
  end)
  it('preserves unknown events, null as nil, and DONE', function()
    assert.is_nil(one('{"type":"future","thing":null}').thing)
    assert.are.equal('future', one('{"type":"future"}').type)
    assert.are.equal('done', one('[DONE]').type)
  end)
end)

for _, name in ipairs(names) do
  describe('fixture ' .. name, function()
    it('contains only synthetic response data', function()
      local bytes = fixture(name)
      assert.matches('resp_fixture_', bytes, 1, true)
      assert.is_nil(bytes:find('gAAAAA', 1, true)) -- live encrypted reasoning
      assert.is_nil(bytes:find('prompt_cache_key', 1, true))
      assert.is_nil(bytes:find('safety_identifier', 1, true))
    end)
    it('replays every single cut, byte-by-byte and seeded multi-cuts', function()
      local bytes = fixture(name)
      local oracle = replay(bytes, {})
      assert.is_true(#oracle > 0)
      for i = 0, #bytes do
        assert.same(oracle, replay(bytes, { i }))
      end
      local cuts = {}
      for i = 1, #bytes do cuts[#cuts + 1] = i end
      assert.same(oracle, replay(bytes, cuts))
      math.randomseed(42)
      for _ = 1, 200 do
        cuts = {}
        for _ = 1, math.random(2, 20) do cuts[#cuts + 1] = math.random(0, #bytes) end
        table.sort(cuts)
        assert.same(oracle, replay(bytes, cuts))
      end
    end)
    it('replays named boundary cuts', function()
      local bytes = fixture(name)
      local oracle = replay(bytes, {})
      local markers = { 'data:', '\n\n', '\r\n' }
      if name == 'reasoning_tool' then
        local args_line = bytes:match('event: response.function_call_arguments.delta\n(data: [^\n]+)')
        assert.is_not_nil(args_line)
        -- Cut inside the JSON-encoded delta string, not just the event name.
        markers[#markers + 1] = args_line
      end
      for _, marker in ipairs(markers) do
        local pos = bytes:find(marker, 1, true)
        if pos then
          for i = pos, pos + #marker - 1 do assert.same(oracle, replay(bytes, { i })) end
        end
      end
      if name == 'multibyte' then
        for i = 1, #bytes do
          if bytes:byte(i) >= 0xC0 then assert.same(oracle, replay(bytes, { i })) end
        end
      end
    end)
    it('has expected content and ordered sequence numbers', function()
      local events = replay(fixture(name), {})
      local last = -1
      for _, ev in ipairs(events) do
        assert.are_not.equal('parse_error', ev.type)
        assert.is_not_nil(ev.sequence_number)
        assert.is_true(ev.sequence_number > last); last = ev.sequence_number
      end
      if name == 'text_only' or name == 'crlf' then
        assert.are.equal('hello world', deltas(events, 'response.output_text.delta'))
        assert.are.equal('response.completed', events[#events].type)
        assert.are.equal('completed', events[#events].response.status)
      elseif name == 'reasoning_tool' then
        assert.is_true(#deltas(events, 'response.reasoning_summary_text.delta') > 0)
        local args, encrypted
        for _, ev in ipairs(events) do
          if ev.type == 'response.output_item.done' then
            if ev.item.type == 'function_call' then args = ev.item.arguments end
            if ev.item.type == 'reasoning' then encrypted = ev.item.encrypted_content end
          end
        end
        assert.is_true(type(encrypted) == 'string' and #encrypted > 0)
        assert.are.equal(args, deltas(events, 'response.function_call_arguments.delta'))
        assert.is_true(type(vim.json.decode(args).city) == 'string')
      elseif name == 'multibyte' then
        assert.matches('日本語 🎉 é — ok', deltas(events, 'response.output_text.delta'), 1, true)
      else
        assert.are.equal('response.failed', events[#events].type)
      end
    end)
  end)
end
