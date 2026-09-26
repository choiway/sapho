local M = {}

function M.parser(on_frame)
  local carry, data, event = "", {}, nil
  local p = {}

  local function dispatch()
    if #data > 0 then on_frame({ event = event, data = table.concat(data, "\n") }) end
    data, event = {}, nil
  end

  local function line(s)
    -- Only LF and CRLF are supported; lone CR is not a line terminator.
    if s:sub(-1) == "\r" then s = s:sub(1, -2) end
    if s == "" then dispatch(); return end
    if s:sub(1, 1) == ":" then return end
    local colon = s:find(":", 1, true)
    local field, value
    if colon then
      field, value = s:sub(1, colon - 1), s:sub(colon + 1)
      if value:sub(1, 1) == " " then value = value:sub(2) end
    else
      field, value = s, ""
    end
    if field == "data" then table.insert(data, value)
    elseif field == "event" then event = value end
  end

  function p:feed(chunk)
    local bytes = carry .. chunk
    local start = 1
    while true do
      local pos = bytes:find("\n", start, true)
      if not pos then break end
      line(bytes:sub(start, pos - 1))
      start = pos + 1
    end
    carry = bytes:sub(start)
  end

  function p:finish()
    if carry ~= "" then line(carry); carry = "" end
    dispatch()
  end

  function p:buffered() return carry end
  return p
end

local required = {
  ["response.created"] = { "response.id" },
  ["response.output_item.added"] = { "output_index", "item.type" },
  ["response.output_text.delta"] = { "output_index", "delta" },
  ["response.reasoning_summary_text.delta"] = { "output_index", "delta" },
  ["response.function_call_arguments.delta"] = { "output_index", "delta" },
  ["response.output_item.done"] = { "output_index", "item.type" },
  ["response.completed"] = { "response.status", "response.usage" },
  ["response.incomplete"] = { "response.incomplete_details" },
  ["response.failed"] = { "response.error" },
  ["error"] = { "message" },
}

local function has_path(obj, path)
  for part in path:gmatch("[^.]+") do
    if type(obj) ~= "table" then return false end
    obj = obj[part]
    if obj == nil then return false end
  end
  return true
end

function M.decoder(on_event)
  return M.parser(function(frame)
    if frame.data == "[DONE]" then on_event({ type = "done" }); return end
    local ok, ev = pcall(vim.json.decode, frame.data, { luanil = { object = true, array = true } })
    local function bad(err)
      on_event({ type = "parse_error", raw = frame.data, err = err })
    end
    if not ok then bad(tostring(ev)); return end
    if type(ev) ~= "table" or type(ev.type) ~= "string" then
      bad("missing type"); return
    end
    if frame.event and frame.event ~= ev.type then
      bad("event/type mismatch: " .. frame.event .. " != " .. ev.type); return
    end
    for _, field in ipairs(required[ev.type] or {}) do
      if not has_path(ev, field) then bad("missing " .. field); return end
    end
    on_event(ev)
  end)
end

return M
