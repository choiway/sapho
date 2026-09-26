local Markdown = require('sapho.ui.markdown')
local Chat = require('sapho.ui.chat')

describe('sapho Markdown transcript', function()
  local buf
  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
  end)
  after_each(function()
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end)

  it('highlights fenced Lua and Python without changing global Markdown settings', function()
    local previous = vim.deepcopy(vim.g.markdown_fenced_languages)
    Markdown.setup(buf)
    assert.same(previous, vim.g.markdown_fenced_languages)
    assert.are.equal('sapho-markdown', vim.bo[buf].filetype)
    assert.are.equal('markdown', vim.bo[buf].syntax)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      '## Assistant', '```lua', 'local result = true', '```',
      '```python', 'def answer():', '    return 42', '```',
      '```js', 'const answer = 42', '```',
      '```tsx', 'const answer = 42', '```',
    })
    vim.api.nvim_buf_call(buf, function()
      local function group(row, col)
        return vim.fn.synIDattr(vim.fn.synID(row, col, 1), 'name')
      end
      assert.matches('markdownH2', group(1, 4))
      assert.matches('lua', group(3, 1))
      assert.matches('python', group(6, 1))
      assert.matches('javaScript', group(10, 1))
      assert.matches('typescript', group(13, 1):lower())
    end)
  end)

  it('does not invoke third-party Markdown filetype hooks', function()
    local group = vim.api.nvim_create_augroup('sapho.test.markdown_ft', { clear = true })
    local called = false
    vim.api.nvim_create_autocmd('FileType', { group = group, pattern = 'markdown', callback = function()
      called = true
    end })
    Markdown.setup(buf)
    vim.api.nvim_del_augroup_by_id(group)
    assert.is_false(called)
  end)

  it('dims metadata without dimming answers or important messages', function()
    Markdown.setup(buf)
    local chat = Chat.new(buf)
    chat:line('## You')
    chat:line('[Reading buffer]', true)
    chat:line('[read failed]')
    chat:delta('text', 'The answer is **important**.')
    chat:end_block()
    local ns = vim.api.nvim_get_namespaces()['sapho.chat']
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.are.equal(1, #marks)
    assert.are.equal(1, marks[1][2]) -- only the activity line
    assert.are.equal('Comment', marks[1][4].hl_group)
    assert.are.equal(200, marks[1][4].priority) -- wins over Markdown syntax groups
    assert.are.equal(#'[Reading buffer]', marks[1][4].end_col)
    chat:close()
  end)

  it('highlights streamed fenced code, not just static Markdown', function()
    Markdown.setup(buf)
    local chat = Chat.new(buf)
    chat:delta('text', '```lua\nlocal x')
    chat:delta('text', ' = 1')
    chat:flush() -- show code colors before the closing fence has streamed
    vim.api.nvim_buf_call(buf, function()
      assert.matches('lua', vim.fn.synIDattr(vim.fn.synID(3, 1, 1), 'name'))
    end)
    chat:delta('text', '\n```')
    chat:end_block()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.same({ '## Assistant', '```lua', 'local x = 1', '```' }, lines)
    vim.api.nvim_buf_call(buf, function()
      assert.matches('lua', vim.fn.synIDattr(vim.fn.synID(3, 1, 1), 'name'))
    end)
    chat:close()
  end)
end)
