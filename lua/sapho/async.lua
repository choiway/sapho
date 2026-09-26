local M = {}

local function pack(...)
  return { n = select("#", ...), ... }
end

function M.run(fn, on_done)
  local task = { done = false, cancelled = false }
  local function complete(...)
    task.done = true
    if on_done then
      on_done(...)
    elseif select(2, ...) ~= nil then
      vim.notify(tostring(select(2, ...)), vim.log.levels.ERROR)
    end
  end

  local function resume(...)
    if task.done then return end
    local ok, err = coroutine.resume(task.co, ...)
    if not ok then
      if err == "sapho: cancelled" then
        complete(nil, "cancelled")
      else
        complete(nil, debug.traceback(task.co, tostring(err)))
      end
    elseif coroutine.status(task.co) == "dead" then
      complete(err)
    end
  end

  task.co = coroutine.create(function()
    return fn()
  end)
  task.cancel = function()
    task.cancelled = true
  end
  -- A task is local to its coroutine; nested runs do not inherit cancellation.
  M._tasks = M._tasks or setmetatable({}, { __mode = "v" })
  M._tasks[task.co] = task
  task._resume = resume
  if vim.in_fast_event() then vim.schedule(resume) else resume() end
  return task
end

function M.await(fn, ...)
  local args = pack(...)
  local co, is_main = coroutine.running()
  if not co or is_main or not M._tasks or not M._tasks[co] then
    error("sapho: await requires async.run coroutine", 2)
  end
  local task = M._tasks[co]
  if task.cancelled then error("sapho: cancelled", 0) end

  local done, waiting, result = false, false, nil
  local function callback(...)
    if done then
      if vim.g.sapho_debug then vim.notify("sapho: callback called twice", vim.log.levels.WARN) end
      return
    end
    done = true
    result = pack(...)
    if waiting then
      local function wake()
        task._resume()
      end
      if vim.in_fast_event() then vim.schedule(wake) else wake() end
    end
  end
  args[args.n + 1] = callback
  fn(unpack(args, 1, args.n + 1))
  if not done then
    waiting = true
    coroutine.yield()
  elseif vim.in_fast_event() then
    -- A synchronous callback can also be invoked inside a fast-event task.
    waiting = true
    vim.schedule(function() task._resume() end)
    coroutine.yield()
  end
  if task.cancelled then error("sapho: cancelled", 0) end
  return unpack(result, 1, result.n)
end

function M.wrap(fn, argc)
  return function(...)
    local args = pack(...)
    assert(args.n == argc, "sapho: wrong argument count")
    return M.await(fn, unpack(args, 1, args.n))
  end
end

function M.schedule()
  return M.await(function(cb) vim.schedule(cb) end)
end

function M.sleep(ms)
  return M.await(function(cb)
    local timer = assert(vim.uv.new_timer())
    timer:start(ms, 0, function()
      timer:stop()
      timer:close()
      cb()
    end)
  end)
end

return M
