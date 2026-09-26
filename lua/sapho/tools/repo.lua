-- Explicit, bounded, read-only access to source files under the working directory.
-- Unlike buffer_read, repo_read can inspect a file that is not open in Neovim.
local Buffer = require('sapho.tools.buffer')
local M = {}
local MAX_FILE, MAX_BYTES, MAX_LINES, MAX_ENTRIES = 512 * 1024, 32000, 200, 200

local function private(name)
  return name:sub(1, 1) == '.' or name == 'node_modules' or name == 'auth.json' or
    name:match('^credentials[%._]') ~= nil or name:match('^id_[er]sa') ~= nil
end
local function resolve(relative, directory)
  if type(relative) ~= 'string' or relative == '' or #relative > 1024 or
      relative:sub(1, 1) == '/' or relative:find('[\\%c]') then
    return nil, 'Expected a relative repository path'
  end
  if relative ~= '.' or not directory then
    for part in relative:gmatch('[^/]+') do
      if part == '.' or part == '..' or private(part) then
        return nil, 'Path is not available to repository tools'
      end
    end
  end
  local cwd = vim.uv.fs_realpath(vim.fn.getcwd())
  local path = cwd and vim.uv.fs_realpath(cwd .. '/' .. relative)
  if not path or (path ~= cwd and path:sub(1, #cwd + 1) ~= cwd .. '/') then
    return nil, 'Path must exist inside the working directory'
  end
  if path == cwd and not directory then return nil, 'Expected a source file' end
  for part in path:sub(#cwd + 2):gmatch('[^/]+') do
    if private(part) then return nil, 'Path is not available to repository tools' end
  end
  if path == vim.uv.fs_realpath(require('sapho.auth').path()) then
    return nil, 'This file is not available to tools'
  end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= (directory and 'directory' or 'file') then
    return nil, directory and 'Expected a repository directory' or 'Expected a regular source file'
  end
  return path, nil, cwd, stat
end
function M.list(args)
  local root, err, cwd = resolve(args.directory or '.', true)
  if not root then return { error = err } end
  local results, visited, truncated = {}, 0, false
  -- Breadth-first so a large subtree cannot hide the top-level entry points.
  local queue, head = { { path = root, depth = 0 } }, 1
  while head <= #queue and not truncated do
    local current = queue[head]; head = head + 1
    local scan = vim.uv.fs_scandir(current.path)
    if scan then
      local names = {}
      while true do
        local name, kind = vim.uv.fs_scandir_next(scan)
        if not name then break end
        if not private(name) and (kind == 'file' or kind == 'directory') then
          names[#names + 1] = { name = name, kind = kind }
        end
      end
      table.sort(names, function(a, b) return a.name < b.name end)
      for _, item in ipairs(names) do
        visited = visited + 1
        if visited > 600 or #results >= MAX_ENTRIES then truncated = true; break end
        local full = current.path .. '/' .. item.name
        local real = vim.uv.fs_realpath(full)
        if real and real:sub(1, #cwd + 1) == cwd .. '/' then
          results[#results + 1] = { path = full:sub(#cwd + 2), type = item.kind }
          if item.kind == 'directory' and current.depth < 4 then
            queue[#queue + 1] = { path = full, depth = current.depth + 1 }
          end
        end
      end
    end
  end
  return { directory = root:sub(#cwd + 2), entries = results, truncated = truncated }
end
local function range(args, count)
  local first = args.start_line or 1
  local last = args.end_line or math.min(count, first + MAX_LINES - 1)
  if type(first) ~= 'number' or first % 1 ~= 0 or first < 1 or first > count or
      type(last) ~= 'number' or last % 1 ~= 0 or last < first or last > count or
      last - first >= MAX_LINES then return nil, nil end
  return first, last
end
function M.read(args)
  local path, err, _, stat = resolve(args.path, false)
  if not path then return { error = err } end
  -- A loaded buffer always wins over its on-disk counterpart, including unsaved changes.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and
        (vim.api.nvim_buf_get_name(buf) == path or
          vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf)) == path) then
      if not vim.api.nvim_buf_is_loaded(buf) then
        return { error = 'Buffer is unloaded; open it to read current editor content' }
      end
      return Buffer.read({ buffer = path, start_line = args.start_line,
        end_line = args.end_line }, { buf = buf })
    end
  end
  if stat.size > MAX_FILE then return { error = 'Source file exceeds 512 KiB; open it in Neovim to read a range' } end
  local fd = vim.uv.fs_open(path, 'r', 384)
  if not fd then return { error = 'Could not read source file' } end
  local raw = vim.uv.fs_read(fd, MAX_FILE + 1, 0)
  vim.uv.fs_close(fd)
  if not raw or #raw > MAX_FILE or raw:find('%z') then return { error = 'Not a bounded text file' } end
  local lines = vim.split(raw, '\n', { plain = true })
  if #lines > 1 and lines[#lines] == '' then table.remove(lines) end
  local first, last = range(args, #lines)
  if not first then return { error = 'Invalid line range (1-based, inclusive, at most 200 lines)' } end
  local output, size, truncated = {}, 0, false
  for i = first, last do
    local line = lines[i]:gsub('\r$', '')
    if not pcall(vim.str_utfindex, line, 'utf-8', #line) then
      return { error = 'Not UTF-8 source text' }
    end
    if size + #line + 1 > MAX_BYTES then
      local slice = line:sub(1, math.max(0, MAX_BYTES - size))
      while #slice > 0 and not pcall(vim.str_utfindex, slice, 'utf-8', #slice) do slice = slice:sub(1, -2) end
      output[#output + 1] = slice
      truncated = true
      break
    end
    output[#output + 1] = line
    size = size + #line + 1
  end
  return { path = path, start_line = first, end_line = first + #output - 1,
    lines = output, truncated = truncated, source = 'disk' }
end
return M
