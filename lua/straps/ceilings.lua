local M = {}

function M.new(resolve)
  local records, categories = {}, {}
  local revision = 0
  local grantable = { edit = true, delete = true, exec = true, lua = true, net = true, spawn = true }
  local function normalize(spec, scope)
    assert(type(spec) == "table" and (spec.readonly == nil or type(spec.readonly) == "boolean"), "invalid ceiling specification")
    assert(spec.allow == nil or type(spec.allow) == "table", "ceiling allow must be an array")
    assert(not spec.readonly or spec.allow == nil, "readonly and allow are mutually exclusive")
    local count = 0
    for key in pairs(spec.allow or {}) do
      assert(type(key) == "number" and key >= 1 and key % 1 == 0, "ceiling allow must be an array")
      count = count + 1
    end
    for index = 1, count do assert(spec.allow[index] ~= nil, "ceiling allow must be a dense array") end
    local allow, identities = {}, {}
    for _, key in ipairs(spec.allow or {}) do
      assert(type(key) == "string", "ceiling allow entries must be strings")
      if grantable[key] then
        allow[key] = true
      else
        local definition = resolve and resolve(scope, "tool." .. key)
        assert(definition and definition.kind == "tool", "unknown ceiling tool grant")
        identities[definition.identity] = true
      end
    end
    return { parent = spec.parent, restricted = spec.readonly == true or spec.allow ~= nil, allow = allow, identities = identities }
  end
  local function chain(bufnr)
    local out, seen = {}, {}
    while bufnr do
      assert(not seen[bufnr], "ceiling parent cycle")
      seen[bufnr] = true
      local record = records[bufnr]
      assert(record, "ceiling not installed")
      out[#out + 1] = record
      bufnr = record.parent
    end
    return out
  end
  local function permits(record, definition, category, input)
    if not record.restricted or category == "read" then return true end
    local name = definition.name:sub(6)
    if category == "spawn" then
      if name == "watch_agent" or name == "unwatch_agent" then return true end
      if name == "send_message" and type(input) == "table" and input.to == "parent" then return true end
    end
    if category == "define" then return false end
    return record.identities[definition.identity] == true or record.allow[category] == true
  end
  local function reclaim(bufnr)
    local record = records[bufnr]
    if not record or not record.closed or record.children > 0 then return end
    records[bufnr] = nil
    if record.parent then
      records[record.parent].children = records[record.parent].children - 1
      reclaim(record.parent)
    end
  end
  return {
    install = function(bufnr, spec, scope)
      assert(not records[bufnr], "ceiling already installed")
      local record = normalize(spec, scope or bufnr)
      if record.parent then
        chain(record.parent)
        assert(not records[record.parent].closed, "ceiling parent is closed")
      end
      revision = revision + 1
      record.revision, record.children = revision, 0
      records[bufnr] = record
      if record.parent then records[record.parent].children = records[record.parent].children + 1 end
    end,
    retire = function(bufnr)
      local record = records[bufnr]
      if not record or record.closed then return false end
      record.closed = true
      reclaim(bufnr)
      return true
    end,
    narrow = function(bufnr, spec)
      local old = assert(records[bufnr], "ceiling not installed")
      local record = normalize(spec, bufnr)
      assert(record.parent == nil or record.parent == old.parent, "ceiling parent is immutable")
      assert(not old.restricted or record.restricted, "cannot widen ceiling")
      if old.restricted then
        for key in pairs(record.allow) do assert(old.allow[key], "cannot widen ceiling") end
        for key in pairs(record.identities) do
          local category = categories[key]
          assert(old.identities[key] or (type(category) == "string" and old.allow[category]), "cannot widen ceiling")
        end
      end
      revision = revision + 1
      record.parent, record.children, record.closed = old.parent, old.children, old.closed
      record.revision = revision
      records[bufnr] = record
    end,
    subset = function(parent, child, capabilities)
      if not records[parent] or records[parent].closed or not records[child] or records[child].closed
        or records[child].parent ~= parent then return false end
      local candidate = normalize({ allow = capabilities }, child)
      local parent_candidate = normalize({ allow = capabilities }, parent)
      if not vim.deep_equal(candidate, parent_candidate) then return false end
      for _, record in ipairs(chain(child)) do
        if record.restricted then
          for category in pairs(candidate.allow) do
            if not record.allow[category] then return false end
          end
          for identity in pairs(candidate.identities) do
            local category = categories[identity]
            if not record.identities[identity] and not (type(category) == "string" and record.allow[category]) then return false end
          end
        end
      end
      return true
    end,
    classify = function(identity, category)
      assert(type(identity) == "number" and (type(category) == "string" or type(category) == "function"), "invalid trusted classification")
      assert(categories[identity] == nil, "classification already installed")
      categories[identity] = category
    end,
    check = function(bufnr, definition, input)
      if not records[bufnr] or records[bufnr].closed then return false, "capability ceiling unavailable" end
      local category = categories[definition.identity] or "agent_tool"
      if type(category) == "function" then
        local detached = vim.deepcopy(input)
        local co = coroutine.create(category)
        local ok, result = coroutine.resume(co, detached)
        if not ok or coroutine.status(co) ~= "dead" or type(result) ~= "string" or not vim.deep_equal(detached, input) then
          return false, "invalid trusted capability classification"
        end
        category = result
      end
      for _, record in ipairs(chain(bufnr)) do
        if not permits(record, definition, category, input) then return false, "capability ceiling denied" end
      end
      return true
    end,
    revision = function(bufnr)
      if not records[bufnr] or records[bufnr].closed then return nil end
      local out = {}
      for _, record in ipairs(chain(bufnr)) do out[#out + 1] = record.revision end
      return table.concat(out, ":")
    end,
  }
end

return M
