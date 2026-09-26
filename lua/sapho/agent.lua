local ToolRegistry = require('sapho.tools')
local M = {}
-- Leave the last request tool-free so a long exploration can still produce an
-- answer instead of failing with a dangling tool call at the iteration cap.
local MAX_REQUESTS, MAX_CALLS = 20, 8
function M.start(session, prompt, context, on_event, on_done, deps)
  deps = deps or {}
  local provider = deps.provider or require('sapho.provider')
  local input = session:input(prompt)
  local items, usages = {}, {}
  local state = { phase = 'streaming', done = false, steps = 0, calls = 0,
    accepted = false, committed = 0, usage_committed = 0, queued = nil, pause = false }
  local function checkpoint()
    local more, usage = {}, {}
    for i = state.committed + 1, #items do more[#more + 1] = items[i] end
    for i = state.usage_committed + 1, #usages do usage[#usage + 1] = usages[i] end
    if #more > 0 or #usage > 0 then
      session:checkpoint(prompt, more, usage, state.committed == 0)
      state.committed, state.usage_committed = #items, #usages
    end
  end
  local function account_uncommitted()
    local usage = {}
    for i = state.usage_committed + 1, #usages do usage[#usage + 1] = usages[i] end
    if #usage > 0 and session.record_usage then session:record_usage(usage) end
    state.usage_committed = #usages
  end
  local function finish(result, err)
    if state.done then return end
    state.done = true; state.phase = 'done'
    state.request, state.tool_cancel = nil, nil
    if result and deps.can_commit and not deps.can_commit() then result, err = nil, 'cancelled' end
    if result then
      local ok = pcall(checkpoint)
      if not ok then result, err = nil, 'Could not commit Codex turn' end
    end
    if not result then account_uncommitted() end
    if result then
      result.usage = #usages > 0 and session:usage() or nil
      result.tool_calls = state.calls
      result.queued = state.queued
    end
    on_done(result, err)
  end
  local handle = {}
  function handle.status() return state.phase end
  function handle.steer(text)
    if state.done then return false end
    state.queued = text
    on_event({ type = 'sapho.status', status = 'queued' })
    return true
  end
  function handle.pause()
    if state.done then return end
    state.pause = true
    on_event({ type = 'sapho.status', status = 'pause after this response' })
  end
  function handle.cancel()
    if state.done then return end
    if vim.in_fast_event() then vim.schedule(handle.cancel); return end
    state.done = true; state.phase = 'done'
    if state.request then state.request.cancel() end
    if state.tool_cancel then state.tool_cancel() end
    account_uncommitted()
    on_done(nil, 'cancelled')
  end
  local tools = deps.registry or ToolRegistry.new(deps.tool_deps)
  local request
  request = function()
    if state.done then return end
    state.phase = 'streaming'; state.steps = state.steps + 1
    local final_only = state.steps >= MAX_REQUESTS
    if final_only then on_event({ type = 'sapho.status', status = 'finishing without more tools' }) end
    local token = {}; state.request_token = token
    local provider_deps = vim.tbl_extend('force', {}, deps.provider_deps or {},
      { tools = final_only and {} or ToolRegistry.schemas() })
    local ok_start, req = pcall(provider.start, input, function(ev)
      if not state.done then on_event(ev) end
    end, function(result, err)
      if state.done then return end
      if state.request_token == token then state.request, state.request_token = nil, nil end
      if not result then finish(nil, err or 'Codex request failed'); return end
      if type(result.output) ~= 'table' then finish(nil, 'Codex response missing output'); return end
      local calls = {}
      for _, item in ipairs(result.output) do
        items[#items + 1] = vim.deepcopy(item); input[#input + 1] = vim.deepcopy(item)
        if item.type == 'function_call' then
          calls[#calls + 1] = item
        end
      end
      if result.usage then usages[#usages + 1] = result.usage end
      if #calls == 0 then finish(result); return end
      if #calls > MAX_CALLS then finish(nil, 'Too many tool calls in one response'); return end
      if final_only then
        -- Even a nonconforming backend response must not enter history unpaired.
        for _, call in ipairs(calls) do
          if type(call.call_id) ~= 'string' or call.call_id == '' then
            finish(nil, 'Codex function call missing call_id'); return
          end
          local item = { type = 'function_call_output', call_id = call.call_id,
            output = '{"error":"Tool budget exhausted; provide a final answer"}' }
          items[#items + 1] = item; input[#input + 1] = vim.deepcopy(item)
        end
        finish(nil, 'Codex requested a tool during the final answer'); return
      end
      for _, call in ipairs(calls) do
        if type(call.call_id) ~= 'string' or call.call_id == '' then
          finish(nil, 'Codex function call missing call_id'); return end
      end
      state.phase = 'collecting tools'
      local function run_next(index)
        if state.done then return end
        if index > #calls then
          if state.pause then
            state.phase = 'paused'
            on_event({ type = 'sapho.status', status = 'paused after response' })
          else request() end
          return
        end
        local call = calls[index]; state.calls = state.calls + 1
        on_event({ type = 'sapho.tool_start', name = call.name, arguments = call.arguments })
        local tool_token = {}; state.tool_token = tool_token
        local function output(value)
          if state.done or state.tool_token ~= tool_token then return end
          state.tool_token, state.tool_cancel = nil, nil
          local item = { type = 'function_call_output', call_id = call.call_id,
            output = type(value) == 'string' and value or '{"error":"Invalid tool result"}' }
          items[#items + 1] = item; input[#input + 1] = vim.deepcopy(item)
          on_event({ type = 'sapho.tool_end', name = call.name, error = item.output:match('^%s*{"error"') ~= nil, output = item.output })
          run_next(index + 1)
        end
        local ok, cancel_or_err = pcall(function() return tools:run(call, context, output) end)
        if not ok then output('{"error":"Tool dispatch failed"}')
        elseif state.tool_token == tool_token then state.tool_cancel = cancel_or_err end
      end
      run_next(1)
    end, provider_deps)
    if not ok_start then finish(nil, 'Could not start Codex request')
    elseif state.request_token == token then state.request = req end
  end
  function handle.resume()
    if state.phase ~= 'paused' then return false end
    state.pause = false; request(); return true
  end
  request()
  return handle
end
return M
