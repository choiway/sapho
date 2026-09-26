local Tools = require('sapho.tools')
local function run(name, args, ctx)
  local result
  Tools.new():run({ name = name, arguments = vim.json.encode(args) }, ctx or {}, function(raw)
    result = vim.json.decode(raw)
  end)
  return result
end
local function create(path, text)
  local fd = assert(vim.uv.fs_open(path, 'w', 384))
  assert(vim.uv.fs_write(fd, text, 0))
  vim.uv.fs_close(fd)
end
describe('sapho repository exploration', function()
  it('discovers and reads plugin entry points even with an unnamed empty source', function()
    local root = run('repo_list', { directory = vim.NIL }, { buf = vim.api.nvim_create_buf(false, true) })
    assert.is_nil(root.error)
    local found = false
    for _, entry in ipairs(root.entries) do
      if entry.path == 'plugin/sapho.lua' then found = true end
    end
    assert.is_true(found)
    local entry = run('repo_read', { path = 'plugin/sapho.lua', start_line = 1, end_line = 4 })
    assert.is_nil(entry.error)
    assert.are.equal('disk', entry.source)
    assert.matches('vim.g.loaded_sapho', table.concat(entry.lines, '\n'), 1, true)
    local module = run('repo_read', { path = 'lua/sapho/init.lua', start_line = 1, end_line = 10 })
    assert.matches("require('sapho.config')", table.concat(module.lines, '\n'), 1, true)
  end)
  it('uses unsaved buffer content over disk for loaded source files', function()
    local path = vim.fn.getcwd() .. '/plugin/sapho.lua'
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved test' })
    local current = run('repo_read', { path = 'plugin/sapho.lua', start_line = vim.NIL, end_line = vim.NIL })
    assert.same({ 'unsaved test' }, current.lines)
    assert.are.equal(vim.api.nvim_buf_get_changedtick(buf), current.changedtick)
    vim.api.nvim_buf_delete(buf, { force = true })
    local disk = run('repo_read', { path = 'plugin/sapho.lua', start_line = 1, end_line = 1 })
    assert.are.equal('if vim.g.loaded_sapho then return end', disk.lines[1])
  end)
  it('never falls back to disk for a loaded special buffer with the same path', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. '/plugin/sapho.lua')
    vim.bo[buf].buftype = 'nofile'
    local result = run('repo_read', { path = 'plugin/sapho.lua' })
    assert.matches('unavailable', result.error)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  it('blocks traversal, private paths, symlinks to secrets and bounded/binary reads', function()
    local original = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    assert(vim.uv.fs_mkdir(dir, 448))
    local function cleanup()
      vim.fn.chdir(original)
      for _, name in ipairs({ 'alias', '.env', 'auth.json', 'large.lua', 'binary.lua', 'safe.lua' }) do
        pcall(vim.uv.fs_unlink, dir .. '/' .. name)
      end
      vim.uv.fs_rmdir(dir)
    end
    local ok, err = pcall(function()
      create(dir .. '/.env', 'secret')
      create(dir .. '/auth.json', 'secret')
      create(dir .. '/safe.lua', 'one\ntwo\n')
      create(dir .. '/large.lua', string.rep('a', 512 * 1024 + 1))
      create(dir .. '/binary.lua', 'abc\0secret')
      assert(vim.uv.fs_symlink(dir .. '/.env', dir .. '/alias'))
      vim.fn.chdir(dir)
      local entries = run('repo_list', { directory = vim.NIL }).entries
      for _, entry in ipairs(entries) do
        assert.is_not.equal('auth.json', entry.path)
        assert.is_not.equal('.env', entry.path)
        assert.is_not.equal('alias', entry.path)
      end
      for _, path in ipairs({ '../outside', '/etc/passwd', '.env', 'auth.json', 'alias', 'not-there' }) do
        assert.is_not_nil(run('repo_read', { path = path, start_line = vim.NIL,
          end_line = vim.NIL }).error)
      end
      assert.matches('512 KiB', run('repo_read', { path = 'large.lua' }).error)
      assert.matches('text', run('repo_read', { path = 'binary.lua' }).error)
      assert.matches('range', run('repo_read', { path = 'safe.lua', start_line = 0 }).error)
      assert.same({ 'two' }, run('repo_read', { path = 'safe.lua', start_line = 2, end_line = 2 }).lines)
    end)
    cleanup()
    if not ok then error(err) end
  end)
end)
