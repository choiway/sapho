local M = {}

-- Built-in Vim syntax highlighting works without a Treesitter parser or plugin.
-- Use a dedicated filetype: third-party Markdown FileType hooks can replace the
-- buffer's syntax with a Markdown Treesitter highlighter that colors code fences
-- as plain text when the fenced language parser is not installed.
-- The Markdown syntax script reads this global at load time; keep the override
-- scoped to Sapho so other Markdown buffers retain user settings.
local languages = {
  'lua', 'python', 'py=python', 'javascript', 'js=javascript', 'jsx=javascript',
  'typescript', 'ts=typescript', 'tsx=typescript', 'go', 'rust', 'rs=rust',
  'sh', 'bash=sh', 'shell=sh', 'zsh=sh', 'json', 'jsonc=json', 'vim',
  'c', 'cpp', 'java', 'ruby', 'rb=ruby', 'html', 'css', 'yaml', 'yml=yaml',
  'sql', 'diff',
}

function M.setup(buf)
  local previous = vim.g.markdown_fenced_languages
  local fenced = type(previous) == 'table' and vim.deepcopy(previous) or {}
  for _, lang in ipairs(languages) do
    if not vim.tbl_contains(fenced, lang) then fenced[#fenced + 1] = lang end
  end
  local ok, err = pcall(function()
    vim.g.markdown_fenced_languages = fenced
    vim.api.nvim_buf_call(buf, function()
      vim.bo[buf].filetype = 'sapho-markdown'
      vim.bo[buf].syntax = 'markdown'
      -- Also load when the user's global `:syntax` setting is off.
      if not vim.b[buf].current_syntax then vim.cmd('runtime syntax/markdown.vim') end
    end)
  end)
  vim.g.markdown_fenced_languages = previous
  if not ok then error(err) end
end

return M
