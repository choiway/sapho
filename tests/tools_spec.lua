local Tools = require('sapho.tools')
local config = require('sapho.config')

local function run(call, context, deps)
  local output, count = nil, 0
  local cancel = Tools.new(deps):run(call, context, function(json)
    count = count + 1; output = vim.json.decode(json)
  end)
  return output, cancel, function() return count end
end
local function source(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '.lua')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf, { buf = buf, line = 1, column = 1 }
end

describe('sapho.tools', function()
  local buffers = {}
  local function create(lines)
    local buf, ctx = source(lines)
    buffers[#buffers + 1] = buf
    return buf, ctx
  end
  after_each(function()
    for _, buf in ipairs(buffers) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    buffers = {}
    config.setup({})
  end)
  it('exports stable, strict ordered schemas with JSON object properties', function()
    local schemas = Tools.schemas()
    assert.same({ 'buffer_read', 'lsp_diagnostics', 'lsp_definition', 'editor_context', 'lsp_references', 'lsp_document_symbols', 'repo_list', 'repo_read' },
      vim.tbl_map(function(s) return s.name end, schemas))
    for _, schema in ipairs(schemas) do
      assert.are.equal('function', schema.type)
      assert.is_true(schema.strict)
      assert.is_false(schema.parameters.additionalProperties)
      assert.matches('"properties":{', vim.json.encode(schema.parameters), 1, true)
      for _, key in ipairs(schema.parameters.required) do
        assert.is_not_nil(schema.parameters.properties[key])
      end
    end
    schemas[1].name = 'mutated'
    assert.are.equal('buffer_read', Tools.schemas()[1].name)
  end)
  it('reads current unsaved lines with bounds, no filesystem read, and no secret buffers', function()
    local buf, ctx = create({ 'unsaved', 'second', 'third' })
    local call = { name = 'buffer_read', arguments = '{"buffer":null,"start_line":2,"end_line":3}' }
    local out = run(call, ctx)
    assert.same({ 'second', 'third' }, out.lines)
    local defaults = run({ name = 'buffer_read',
      arguments = '{"buffer":null,"start_line":null,"end_line":null}' }, ctx)
    assert.same({ 'unsaved', 'second', 'third' }, defaults.lines)
    assert.are.equal(2, out.start_line)
    assert.are.equal(vim.api.nvim_buf_get_name(buf), out.buffer)
    assert.matches('range', run({ name = 'buffer_read', arguments = '{"start_line":0}' }, ctx).error)
    local other = create(vim.split(string.rep('a\n', 210), '\n'))
    assert.matches('range', run({ name = 'buffer_read', arguments = '{"start_line":1,"end_line":201}' }, { buf = other }).error)
    assert.is_true(run({ name = 'buffer_read', arguments = '{}' }, { buf = other }).end_line <= 200)
    assert.matches('loaded normal', run({ name = 'buffer_read', arguments = '{"buffer":"/not/open"}' }, ctx).error)
    local scratch = vim.api.nvim_create_buf(false, true)
    buffers[#buffers + 1] = scratch
    vim.bo[scratch].buftype = 'nofile'
    assert.matches('unavailable', run({ name = 'buffer_read', arguments = '{}' }, { buf = scratch }).error)
    local dir = vim.fn.tempname(); assert(vim.uv.fs_mkdir(dir, 448))
    config.setup({ codex_home = dir })
    local secret = vim.api.nvim_create_buf(true, false)
    buffers[#buffers + 1] = secret
    vim.api.nvim_buf_set_name(secret, dir .. '/auth.json')
    vim.api.nvim_buf_set_lines(secret, 0, -1, false, { 'private credentials' })
    assert.matches('not available', run({ name = 'buffer_read', arguments = '{}' }, { buf = secret }).error)
    vim.uv.fs_rmdir(dir)
  end)
  it('rejects invalid names/JSON/keys and bounds large responses', function()
    local _, ctx = create({ string.rep('a', 40000) })
    assert.matches('Unknown tool', run({ name = 'shell', arguments = '{}' }, ctx).error)
    assert.matches('Invalid', run({ name = 'buffer_read', arguments = '[' }, ctx).error)
    assert.matches('Invalid', run({ name = 'buffer_read', arguments = '[]' }, ctx).error)
    assert.matches('Unsupported', run({ name = 'buffer_read', arguments = '{"extra":1}' }, ctx).error)
    local out = run({ name = 'buffer_read', arguments = '{}' }, ctx)
    assert.is_true(out.truncated)
    assert.is_true(#vim.json.encode(out) < 40000)
  end)
  it('sorts and limits published diagnostics without starting a server', function()
    local _, ctx = create({ 'a', 'b' })
    local out = run({ name = 'lsp_diagnostics', arguments = '{}' }, ctx, {
      diagnostics = function() return {
        { lnum = 1, col = 3, message = 'later', severity = 2 },
        { lnum = 0, col = 0, message = 'first', severity = 1 },
      } end,
    })
    assert.are.equal('first', out.diagnostics[1].message)
    assert.are.equal(1, out.diagnostics[1].line)
    assert.are.equal(2, out.diagnostics[2].line)
  end)
  it('queries all LSP clients with their individual position encodings', function()
    local _, ctx = create({ 'a😀b' }); ctx.column = 6 -- b starts at byte column 6
    local params, callback, ms, cancel_count = {}, nil, nil, 0
    local deps = {
      clients = function() return { { offset_encoding = 'utf-16' }, { offset_encoding = 'utf-8' } } end,
      request_all = function(_, method, make, cb)
        assert.are.equal('textDocument/definition', method)
        params = { make({ offset_encoding = 'utf-16' }), make({ offset_encoding = 'utf-8' }) }
        callback = cb
        return function() cancel_count = cancel_count + 1 end
      end,
      delay = function(n) ms = n; return function() end end,
    }
    local call = { name = 'lsp_definition', arguments = '{}' }
    local result, count = nil, 0
    local cancel = Tools.new(deps):run(call, ctx, function(raw)
      count = count + 1; result = vim.json.decode(raw)
    end)
    assert.is_nil(result)
    assert.are.equal(5000, ms)
    assert.are.equal(3, params[1].position.character)
    assert.are.equal(5, params[2].position.character)
    callback({ [2] = { result = { { uri = 'file:///b', range = { start = { line = 4, character = 1 } } } } },
      [1] = { result = { { uri = 'file:///a', range = { start = { line = 2, character = 0 } } },
        { uri = 'file:///b', range = { start = { line = 4, character = 1 } } } } } })
    assert.are.equal(1, count)
    assert.are.equal('file:///a', result.definitions[1].uri)
    assert.are.equal('file:///b', result.definitions[2].uri)
    assert.are.equal(2, #result.definitions)
    cancel(); assert.are.equal(0, cancel_count)
  end)
  it('times out/cancels definition requests without late results or hanging without LSP', function()
    local _, ctx = create({ 'word' })
    local empty = run({ name = 'lsp_definition', arguments = '{}' }, ctx, { clients = function() return {} end })
    assert.matches('No definition', empty.error)
    local callback, timeout, stopped, output, calls = nil, nil, false, nil, 0
    local tool = Tools.new({ clients = function() return { { offset_encoding = 'utf-16' } } end,
      request_all = function(_, _, _, cb) callback = cb; return function() stopped = true end end,
      delay = function(_, cb) timeout = cb; return function() end end })
    tool:run({ name = 'lsp_definition', arguments = '{}' }, ctx, function(raw)
      calls = calls + 1; output = vim.json.decode(raw)
    end)
    timeout()
    assert.is_true(stopped); assert.matches('timed out', output.error)
    callback({ [1] = { result = {} } })
    assert.are.equal(1, calls)
    local cancel = tool:run({ name = 'lsp_definition', arguments = '{}' }, ctx, function() calls = calls + 1 end)
    cancel(); callback({ [1] = { result = {} } })
    assert.are.equal(1, calls)
  end)
end)
