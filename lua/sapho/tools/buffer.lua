local M = {}

local function canonical(path)
  return vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ':p')
end

function M.resolve(name, context)
  if context and context.buf and (not vim.api.nvim_buf_is_valid(context.buf) or not vim.api.nvim_buf_is_loaded(context.buf) or vim.bo[context.buf].buftype ~= '') then
    return nil, 'Source buffer is unavailable'
  end
  local buf
  if name == nil then
    buf = context and context.buf
  elseif type(name) == 'string' and name ~= '' then
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(candidate) then
        local path = vim.api.nvim_buf_get_name(candidate)
        if path ~= '' and (path == name or canonical(path) == canonical(name)) then
          buf = candidate
          break
        end
      end
    end
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) or
      vim.bo[buf].buftype ~= '' then
    return nil, 'Buffer is not a loaded normal editor buffer; open a source buffer first'
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local name = path:match('[^/]+$') or ''
  if path:match('^sapho://') or path:find('/%.git/', 1) or path:find('/%.ssh/', 1) or
      path:find('/%.codex/', 1) or name:sub(1, 1) == '.' or
      name == 'auth.json' or name:match('^credentials[%._]') or
      name:match('^id_[er]sa') or name:match('%.pem$') or
      (path ~= '' and canonical(path) == canonical(require('sapho.auth').path())) then
    return nil, 'This buffer is not available to tools'
  end
  return buf
end

function M.read(args, context)
  local buf, err = M.resolve(args.buffer, context)
  if not buf then return { error = err } end
  local count = vim.api.nvim_buf_line_count(buf)
  local first = args.start_line or 1
  local last = args.end_line or math.min(count, first + 199)
  if type(first) ~= 'number' or first % 1 ~= 0 or first < 1 or first > count or
      type(last) ~= 'number' or last % 1 ~= 0 or last < first or last > count or last - first >= 200 then
    return { error = 'Invalid line range (1-based, inclusive, at most 200 lines)' }
  end
  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  local output, size, truncated = {}, 0, false
  for _, line in ipairs(lines) do
    if size + #line + 1 > 32000 then
      local slice = line:sub(1, math.max(0, 32000 - size))
      -- Do not cut a multibyte character in half in a JSON tool result.
      while #slice > 0 and not pcall(vim.str_utfindex, slice, 'utf-8', #slice) do
        slice = slice:sub(1, -2)
      end
      output[#output + 1] = slice
      truncated = true
      break
    end
    output[#output + 1] = line
    size = size + #line + 1
  end
  return { source = 'unsaved buffer', buffer_id = buf, encoding = 'utf-8', buffer = vim.api.nvim_buf_get_name(buf), changedtick = vim.api.nvim_buf_get_changedtick(buf), start_line = first,
    end_line = first + #output - 1, lines = output, truncated = truncated }
end
return M
