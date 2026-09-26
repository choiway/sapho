local Buffer = require('sapho.tools.buffer')
local Lsp = require('sapho.tools.lsp')
local Repo = require('sapho.tools.repo')
local M = {}

local function nullable(kind, description)
  return { type = { kind, 'null' }, description = description }
end
local entries = {
  { name = 'buffer_read', description = 'Read current unsaved text from a loaded editor buffer. Omit buffer to read the source buffer from which Sapho was opened. Lines are 1-based and inclusive (max 200); returns current changedtick.',
    parameters = { type = 'object', properties = {
      buffer = nullable('string', 'Exact path of an open buffer, or null for source buffer'),
      start_line = nullable('integer', 'First line, or null for line 1'),
      end_line = nullable('integer', 'Last line, or null for up to 200 lines'),
    }, required = { 'buffer', 'start_line', 'end_line' }, additionalProperties = false } },
  { name = 'lsp_diagnostics', description = 'Return published diagnostics for a loaded editor buffer; null selects the source buffer.',
    parameters = { type = 'object', properties = {
      buffer = nullable('string', 'Exact path of an open buffer, or null for source buffer'),
    }, required = { 'buffer' }, additionalProperties = false } },
  { name = 'lsp_definition', description = 'Query attached LSP servers for a definition at a 1-based line and byte column. Null position selects the saved source cursor.',
    parameters = { type = 'object', properties = {
      buffer = nullable('string', 'Exact path of an open buffer, or null for source buffer'),
      line = nullable('integer', 'Line, or null for source cursor'),
      column = nullable('integer', 'Byte column, or null for source cursor'),
    }, required = { 'buffer', 'line', 'column' }, additionalProperties = false } },
  { name = 'editor_context', description = 'Read the current source buffer, cursor and explicit selection.',
    parameters = { type = 'object', properties = vim.empty_dict(), required = {}, additionalProperties = false } },
  { name = 'lsp_references', description = 'Find bounded references at a 1-based line and byte column; null selects source cursor.',
    parameters = { type = 'object', properties = {
      buffer = nullable('string', 'Exact open buffer path or null for source'),
      line = nullable('integer', 'Line or null for source cursor'),
      column = nullable('integer', 'Byte column or null for source cursor'),
    }, required = { 'buffer', 'line', 'column' }, additionalProperties = false } },
  { name = 'lsp_document_symbols', description = 'List bounded document symbols from attached LSP servers.',
    parameters = { type = 'object', properties = {
      buffer = nullable('string', 'Exact open buffer path or null for source'),
    }, required = { 'buffer' }, additionalProperties = false } },
  { name = 'repo_list', description = 'List source files and subdirectories under the working directory without requiring an open buffer. Paths are relative; null lists the repository root. Bounded and excludes private paths.',
    parameters = { type = 'object', properties = {
      directory = nullable('string', 'Relative directory inside the working directory, or null for root'),
    }, required = { 'directory' }, additionalProperties = false } },
  { name = 'repo_read', description = 'Read up to 200 lines of a repository source file by relative path. Uses current unsaved editor text when loaded; otherwise reads bounded disk text. Returns changedtick for loaded buffers.',
    parameters = { type = 'object', properties = {
      path = { type = 'string', description = 'Relative source path found via repo_list' },
      start_line = nullable('integer', '1-based first line, null for line 1'),
      end_line = nullable('integer', '1-based inclusive last line, null for up to 200 lines'),
    }, required = { 'path', 'start_line', 'end_line' }, additionalProperties = false } },
}
local by_name = {}
for _, entry in ipairs(entries) do by_name[entry.name] = entry end

function M.schemas()
  local result = {}
  for _, entry in ipairs(entries) do
    result[#result + 1] = {
      type = 'function', name = entry.name, description = entry.description,
      parameters = vim.deepcopy(entry.parameters), strict = true,
    }
  end
  return result
end

--- Run one function call; cb(output_json_string) once on the main loop.
--- No arbitrary function names, shell commands, writes or code execution.
function M.new(deps)
  deps = deps or {}
  local self = {}
  function self:run(call, context, cb)
    local active = true
    local function deliver(value)
      if not active then return end
      active = false
      local ok, json = pcall(vim.json.encode, value)
      if not ok or #json > 40000 then json = '{"error":"Tool result too large or could not be encoded"}' end
      if vim.in_fast_event() then vim.schedule(function() cb(json) end) else cb(json) end
    end
    if type(call) ~= 'table' or not by_name[call.name] then
      deliver({ error = 'Unknown tool' }); return function() active = false end
    end
    local ok, args = pcall(vim.json.decode, call.arguments or '')
    if not ok or type(args) ~= 'table' or vim.islist(args) then
      deliver({ error = 'Invalid tool arguments JSON object' }); return function() active = false end
    end
    local props = by_name[call.name].parameters.properties
    for key, value in pairs(args) do
      if not props[key] then
        deliver({ error = 'Unsupported tool argument' }); return function() active = false end
      end
      if value == vim.NIL then args[key] = nil end
    end
    if call.name == 'repo_list' or call.name == 'repo_read' then
      local fn = call.name == 'repo_list' and Repo.list or Repo.read
      local worked, value = pcall(fn, args)
      deliver(worked and value or { error = 'Repository read failed' })
      return function() active = false end
    end
    if call.name == 'editor_context' then
      local ctx = deps.context and deps.context() or context
      local buf, err = Buffer.resolve(nil, ctx)
      if not buf then deliver({ error = err }) else
        deliver({ buffer = vim.api.nvim_buf_get_name(buf), buffer_id = buf,
          path = ctx.path or ('[unnamed buffer ' .. buf .. ']'),
          changedtick = vim.api.nvim_buf_get_changedtick(buf),
          line = ctx.line, column = ctx.column, filetype = vim.bo[buf].filetype,
          selection = context and context.selection, selection_pinned = true,
          cursor_live = ctx.cursor_live == true, encoding = 'utf-8' })
      end
      return function() active = false end
    end
    local fn = call.name == 'buffer_read' and Buffer.read or Lsp.diagnostics
    if call.name == 'lsp_definition' or call.name == 'lsp_references' or call.name == 'lsp_document_symbols' then
      local started, cancel_or_err = pcall(Lsp[({ lsp_definition = 'definition', lsp_references = 'references', lsp_document_symbols = 'symbols' })[call.name]], args, context, deliver, deps)
      if not started then deliver({ error = 'LSP definition tool failed' }); return function() end end
      return function() active = false; cancel_or_err() end
    end
    local worked, value = pcall(fn, args, context, deps)
    deliver(worked and value or { error = 'Read-only tool failed' })
    return function() active = false end
  end
  return self
end
return M
