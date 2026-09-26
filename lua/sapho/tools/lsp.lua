local Buffer = require('sapho.tools.buffer')
local M = {}

function M.diagnostics(args, context, deps)
  local buf, err = Buffer.resolve(args.buffer, context)
  if not buf then return { error = err } end
  local list = (deps.diagnostics or vim.diagnostic.get)(buf)
  table.sort(list, function(a, b)
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    if a.col ~= b.col then return a.col < b.col end
    return (a.severity or 0) < (b.severity or 0)
  end)
  local result = {}
  for i = 1, math.min(#list, 100) do
    local d = list[i]
    result[#result + 1] = { line = d.lnum + 1, column = d.col + 1,
      end_line = (d.end_lnum or d.lnum) + 1, end_column = (d.end_col or d.col) + 1,
      severity = d.severity, message = tostring(d.message or ''):sub(1, 1000),
      source = d.source, code = d.code }
  end
  return { buffer = vim.api.nvim_buf_get_name(buf), buffer_id = buf, source = 'lsp diagnostics',
    encoding = 'utf-8 byte column', diagnostics = result, truncated = #list > #result }
end

local function delay(ms, cb)
  local timer = assert(vim.uv.new_timer())
  timer:start(ms, 0, function() timer:stop(); timer:close(); vim.schedule(cb) end)
  return function() if not timer:is_closing() then timer:stop(); timer:close() end end
end

--- Asynchronously query all definition clients; returns an idempotent cancel function.
local function query(kind, args, context, cb, deps)
  local buf, err = Buffer.resolve(args.buffer, context)
  if not buf then cb({ error = err }); return function() end end
  local clients = (deps.clients or vim.lsp.get_clients)({ bufnr = buf, method = 'textDocument/' .. kind })
  if #clients == 0 then cb({ error = 'No ' .. kind .. '-capable LSP client attached to this buffer' }); return function() end end
  local same = context and context.buf == buf
  local line = args.line or (same and context.line) or 1
  local column = args.column or (same and context.column) or 1
  local count = vim.api.nvim_buf_line_count(buf)
  if type(line) ~= 'number' or line % 1 ~= 0 or line < 1 or line > count or
      type(column) ~= 'number' or column % 1 ~= 0 or column < 1 or
      column > #vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] + 1 then
    cb({ error = 'Invalid position (1-based line and byte column)' })
    return function() end
  end
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1]
  -- Params are per client: UTF-16 and UTF-8 columns differ for non-ASCII text.
  local function params(client)
    return { textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = line - 1,
        character = vim.str_utfindex(text, client.offset_encoding or 'utf-16', column - 1) } }
  end
  local active, cancel_request, cancel_timer = true, nil, nil
  local function finish(value)
    if not active then return end
    active = false
    if cancel_timer then cancel_timer(); cancel_timer = nil end
    if vim.in_fast_event() then vim.schedule(function() cb(value) end) else cb(value) end
  end
  local request = deps.request_all or vim.lsp.buf_request_all
  local ok, cancel_or_err = pcall(request, buf, 'textDocument/' .. kind, function(client)
    local p = params(client)
    if kind == 'references' then p.context = { includeDeclaration = true } end
    return p
  end, function(results)
    local locations, seen, errors = {}, {}, {}
    local ids = vim.tbl_keys(results)
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    for _, id in ipairs(ids) do
      local entry = results[id]
      local encoding = 'utf-16'
      for _, client in ipairs(clients) do
        if tostring(client.id) == tostring(id) then encoding = client.offset_encoding or 'utf-16'; break end
      end
      if entry.err or entry.error then
        errors[#errors + 1] = tostring((entry.err or entry.error).message or 'LSP error'):sub(1, 200)
      else
        local items = entry.result
        if items and items.uri then items = { items } end
        if items and items.targetUri then items = { items } end
        if type(items) == 'table' then
          for _, loc in ipairs(items) do
            local uri = loc.uri or loc.targetUri
            local range = loc.range or loc.targetSelectionRange or loc.targetRange
            if type(uri) == 'string' and type(range) == 'table' and range.start then
              local row, col = range.start.line, range.start.character
              if uri:match('^file://') and type(row) == 'number' and type(col) == 'number' and
                  row >= 0 and col >= 0 and row < 10000000 and col < 10000000 then
                local path = vim.uri_to_fname(uri)
                local cwd = vim.fn.getcwd()
                local relative = path:sub(1, #cwd + 1) == cwd .. '/' and path:sub(#cwd + 2) or nil
                local preview
                if relative then
                  local read = require('sapho.tools.repo').read({ path = relative, start_line = row + 1, end_line = row + 1 })
                  preview = read.lines and read.lines[1]
                end
                local byte_col = col
                if preview then
                  local ok_byte, result = pcall(vim.str_byteindex, preview, encoding, col)
                  if ok_byte then byte_col = result end
                end
                local key = uri .. ':' .. row .. ':' .. col
                if not seen[key] then
                  seen[key] = true
                  locations[#locations + 1] = { uri = uri, path = path, line = row + 1,
                    column = byte_col + 1, character = col, encoding = encoding,
                    preview = preview and preview:sub(1, 180) or '', source = 'lsp' }
                end
              end
            end
          end
        end
      end
    end
    table.sort(locations, function(a, b)
      if a.uri ~= b.uri then return a.uri < b.uri end
      if a.line ~= b.line then return a.line < b.line end
      return a.column < b.column
    end)
    local truncated = #locations > 30
    while #locations > 30 do table.remove(locations) end
    finish({ [kind == 'definition' and 'definitions' or 'references'] = locations, source = 'lsp',
      buffer = vim.api.nvim_buf_get_name(buf), buffer_id = buf, encoding = 'utf-8 byte column (per-location original LSP encoding)', truncated = truncated,
      error = #locations == 0 and (#errors > 0 and table.concat(errors, '; ') or 'No ' .. kind .. ' found') or nil })
  end)
  if not ok then finish({ error = 'LSP ' .. kind .. ' request failed' })
  else
    cancel_request = cancel_or_err
    if active then cancel_timer = (deps.delay or delay)(5000, function()
      if cancel_request then pcall(cancel_request) end
      finish({ error = 'LSP ' .. kind .. ' request timed out' })
    end) end
  end
  return function()
    if not active then return end
    active = false
    if cancel_timer then cancel_timer(); cancel_timer = nil end
    if cancel_request then pcall(cancel_request) end
  end
end
function M.definition(args, context, cb, deps) return query('definition', args, context, cb, deps) end
function M.references(args, context, cb, deps) return query('references', args, context, cb, deps) end
function M.symbols(args, context, cb, deps)
  local buf, err = Buffer.resolve(args.buffer, context)
  if not buf then cb({ error = err }); return function() end end
  local clients = (deps.clients or vim.lsp.get_clients)({ bufnr = buf, method = 'textDocument/documentSymbol' })
  if #clients == 0 then cb({ error = 'No document-symbol-capable LSP client attached' }); return function() end end
  local active, cancel_timer, cancel_request = true, nil, nil
  local function finish(value)
    if not active then return end
    active = false
    if cancel_timer then cancel_timer() end
    cb(value)
  end
  local ok, stop = pcall(deps.request_all or vim.lsp.buf_request_all, buf, 'textDocument/documentSymbol',
    { textDocument = { uri = vim.uri_from_bufnr(buf) } }, function(results)
      local symbols = {}
      local encoding = 'utf-16'
      local function collect(items, depth)
        for _, item in ipairs(items or {}) do
          if #symbols >= 100 or depth > 8 then return end
          local range = item.selectionRange or item.range or (item.location and item.location.range)
          if range and range.start and type(range.start.line) == 'number' and
              type(range.start.character) == 'number' and range.start.line >= 0 and
              range.start.line < vim.api.nvim_buf_line_count(buf) then
            local text = vim.api.nvim_buf_get_lines(buf, range.start.line, range.start.line + 1, false)[1]
            local ok_byte, byte = pcall(vim.str_byteindex, text, encoding, range.start.character)
            symbols[#symbols + 1] = { name = tostring(item.name or ''):sub(1, 200), kind = item.kind,
              line = range.start.line + 1, column = (ok_byte and byte or range.start.character) + 1,
              end_line = (range['end'] and range['end'].line or range.start.line) + 1,
              end_column = (range['end'] and range['end'].character or range.start.character) + 1,
              path = vim.api.nvim_buf_get_name(buf), source = 'lsp', encoding = encoding }
          end
          collect(item.children, depth + 1)
        end
      end
      for id, entry in pairs(results or {}) do
        for _, client in ipairs(clients) do
          if tostring(client.id) == tostring(id) then encoding = client.offset_encoding or 'utf-16'; break end
        end
        if entry.result then collect(entry.result, 0) end
      end
      finish({ symbols = symbols, truncated = #symbols >= 100, source = 'lsp',
        buffer = vim.api.nvim_buf_get_name(buf), buffer_id = buf })
    end)
  if not ok then finish({ error = 'LSP document symbol request failed' }) else
    cancel_request = stop
    if active then cancel_timer = (deps.delay or delay)(5000, function()
      if cancel_request then pcall(cancel_request) end
      finish({ error = 'LSP document symbol request timed out' })
    end) end
  end
  return function()
    active = false
    if cancel_timer then cancel_timer() end
    if cancel_request then pcall(cancel_request) end
  end
end
return M
