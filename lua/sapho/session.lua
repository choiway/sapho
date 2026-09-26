local M = {}

function M.new()
  local self = { history = {}, last_usage = nil, totals = { input_tokens = 0, output_tokens = 0 } }
  function self:input(prompt)
    local items = vim.deepcopy(self.history)
    items[#items + 1] = { role = 'user', content = prompt }
    return items
  end
  local function sum(into, usage)
    for key, value in pairs(usage) do
      if type(value) == 'number' then into[key] = (into[key] or 0) + value
      elseif type(value) == 'table' then
        into[key] = into[key] or {}
        sum(into[key], value)
      end
    end
  end
  --- Atomically commit a complete turn (all response items and paired tool results).
  function self:commit_turn(prompt, items, usages)
    assert(type(items) == 'table' and vim.islist(items), 'ordered items required')
    local history = vim.deepcopy(self.history)
    history[#history + 1] = { role = 'user', content = prompt }
    for _, item in ipairs(items) do history[#history + 1] = vim.deepcopy(item) end
    local aggregate = {}
    for _, usage in ipairs(usages or {}) do
      assert(type(usage) == 'table', 'usage must be a table')
      sum(aggregate, usage)
    end
    self.history = history
    if next(aggregate) then
      self.last_usage = aggregate
      for _, key in ipairs({ 'input_tokens', 'output_tokens' }) do
        self.totals[key] = self.totals[key] + (aggregate[key] or 0)
      end
    end
  end
  --- Account for completed provider responses even when an unedited turn fails.
  function self:record_usage(usages)
    local aggregate = {}
    for _, usage in ipairs(usages) do sum(aggregate, usage) end
    if next(aggregate) then
      self.last_usage = aggregate
      self.totals.input_tokens = self.totals.input_tokens + (aggregate.input_tokens or 0)
      self.totals.output_tokens = self.totals.output_tokens + (aggregate.output_tokens or 0)
    end
  end
  --- Append a completed, paired checkpoint without replaying already committed items.
  function self:checkpoint(prompt, items, usages, first)
    if first then return self:commit_turn(prompt, items, usages) end
    local history = vim.deepcopy(self.history)
    for _, item in ipairs(items) do history[#history + 1] = vim.deepcopy(item) end
    local aggregate = {}
    for _, usage in ipairs(usages) do sum(aggregate, usage) end
    self.history = history
    if next(aggregate) then
      self.last_usage = aggregate
      self.totals.input_tokens = self.totals.input_tokens + (aggregate.input_tokens or 0)
      self.totals.output_tokens = self.totals.output_tokens + (aggregate.output_tokens or 0)
    end
  end
  -- Compatibility for clients that do not dispatch tools: pair every call with
  -- a synthetic error result, so no next request has a dangling call_id.
  function self:commit(prompt, result)
    assert(type(result) == 'table' and type(result.output) == 'table', 'complete response required')
    local items = vim.deepcopy(result.output)
    for _, item in ipairs(result.output) do
      if item.type == 'function_call' and item.call_id then
        items[#items + 1] = { type = 'function_call_output', call_id = item.call_id,
          output = 'Tool execution not available yet.' }
      end
    end
    self:commit_turn(prompt, items, result.usage and { result.usage } or {})
  end
  function self:usage()
    return vim.deepcopy(self.last_usage), vim.deepcopy(self.totals)
  end
  return self
end

return M
