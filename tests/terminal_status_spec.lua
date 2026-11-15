local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local straps = require("straps")
straps.config.session_dir = vim.fn.tempname()
local real_send = vim.api.nvim_ui_send
local sent = {}
local consumer = { tasks = {} }
local function consume(text)
  local fields = text:match("^\27%]7501;app=straps(.-)\27\\$")
  local id = fields:match(":id=([^:]+)")
  local state = fields:match(":state=([^:]+)")
  local kind = fields:match(":kind=([^:]+)")
  if state == "clear" then
    if id then consumer.tasks[id] = nil else consumer.tasks, consumer.root = {}, nil end
  elseif id then
    consumer.tasks[id] = { state = state, kind = kind }
  else
    consumer.root = { state = state, kind = kind }
  end
end
local function capture(text)
  sent[#sent + 1] = text
  consume(text)
end
vim.api.nvim_ui_send = capture
local attention = require("straps.attention")
local count = 0
local function check(value, detail)
  count = count + 1
  if tonumber(vim.env.STRAPS_STATUS_COUNTERFACTUAL) == count then value = not value end
  assert(value, "terminal status assertion " .. count .. (detail and (": " .. tostring(detail)) or ""))
end
local function last(state, kind)
  local text = sent[#sent] or ""
  return text:find(":state=" .. state .. (kind and (":kind=" .. kind) or "") .. "\27\\", 1, true) ~= nil
end
local function reports_since(n)
  local reports = {}
  for i = n + 1, #sent do
    local fields = sent[i]:match("^\27%]7501;app=straps(.-)\27\\$")
    check(fields ~= nil)
    local id, state, tail = fields:match("^:id=([^:]+):state=([^:\27]+)(.*)$")
    if not id then state, tail = fields:match("^:state=([^:\27]+)(.*)$") end
    check(state ~= nil)
    check(tail == "" or tail:match("^:kind=%a+$") ~= nil)
    reports[#reports + 1] = (id or "root") .. ":" .. state .. tail
  end
  return reports
end
local function exact(n, expected, unordered)
  local actual = reports_since(n)
  if unordered then
    if expected[1] and expected[1]:match("^root:") then check(actual[1] == expected[1]) end
    table.sort(actual)
    table.sort(expected)
  end
  check(vim.deep_equal(actual, expected))
end
local function visible(state, kind, named)
  check((consumer.root and consumer.root.state) == state)
  check((consumer.root and consumer.root.kind) == kind)
  local effective = consumer.root and consumer.root.state
  local total = 0
  for _, task in pairs(consumer.tasks) do
    total = total + 1
    if task.state == "blocked" or (task.state == "error" and effective ~= "blocked") then effective = task.state end
  end
  check(effective == state)
  check(total == named)
end
local function task_id(n)
  return sent[n or (#sent - 1)]:match(":id=([^:]+)")
end
local function run(buf)
  local ctx = { bufnr = buf }
  local r = { ctx = ctx }
  attention.start(buf, r)
  return r, ctx
end

it("clears standalone prompts on exit before the loop is loaded", function()
  attention.setup(true)
  attention.prompt(nil, "auth", function()
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    check(last("clear"))
  end)
  package.loaded["straps.attention"] = nil
  attention = require("straps.attention")
end)

it("aggregates active runs ahead of retained outcomes and rejects stale callbacks", function()
  check(straps.config.terminal_status == true)
  attention.setup(true)
  local a = vim.api.nvim_create_buf(false, true)
  local b = vim.api.nvim_create_buf(false, true)
  local n = #sent
  local r, ctx = run(a)
  local id = task_id()
  exact(n, { id .. ":working", "root:working" })
  visible("working", nil, 1)
  local s, sc = run(b)
  local bid = task_id()
  check(bid ~= id)
  local release = attention.wait(ctx, "permission")
  visible("blocked", "permission", 2)
  local release2 = attention.wait(sc, "question")
  visible("blocked", "question", 2)
  local release3 = attention.wait(ctx, "auth")
  visible("blocked", "auth", 2)
  release3()
  visible("blocked", "question", 2)
  release2()
  visible("blocked", "permission", 2)
  release()
  visible("working", nil, 2)
  n = #sent
  release()
  exact(n, {})
  local stale = attention.wait(ctx, "auth")
  n = #sent
  attention.finish(a, r, "error")
  exact(n, { id .. ":clear", "root:working" })
  visible("working", nil, 1)
  n = #sent
  attention.finish(b, s, "ok")
  exact(n, { bid .. ":clear", "root:done" })
  visible("done", nil, 0)
  n = #sent
  stale()
  attention.finish(a, r, "error")
  exact(n, {})
  visible("done", nil, 0)
  local newer = run(a)
  n = #sent
  stale()
  attention.finish(a, r, "error")
  exact(n, {})
  visible("working", nil, 1)
  attention.finish(a, newer, "cancelled")
  visible("idle", nil, 0)
  for _, reason in ipairs({ "error", "blank", "stalled", "max_turns" }) do
    local current = run(a)
    attention.finish(a, current, reason)
    visible("error", nil, 0)
  end
  local current = run(a)
  current.cancelled = true
  attention.finish(a, current, "error")
  visible("idle", nil, 0)
  local ok, err = pcall(attention.prompt, ctx, "question", function() error("prompt failed", 0) end)
  check(not ok and err == "prompt failed")
  local nr, nc = run(a)
  ok, err = pcall(attention.prompt, nc, "permission", function()
    visible("blocked", "permission", 1)
    error("failed", 0)
  end)
  check(not ok and err == "failed", err)
  visible("working", nil, 1)
  n = #sent
  attention.setup(false)
  exact(n, { id .. ":clear", "root:clear" })
  visible(nil, nil, 0)
  n = #sent
  attention.wait(nc, "question")()
  attention.finish(a, nr, "ok")
  attention.prompt(nil, "auth", function() return "" end)
  exact(n, {})
  attention.setup(true)
  exact(n, { "root:done" })
  visible("done", nil, 0)
  n = #sent
  vim.api.nvim_exec_autocmds("UIEnter", {})
  exact(n, { "root:done" })
  n = #sent
  vim.api.nvim_buf_delete(a, { force = true })
  exact(n, { "root:done" })
  visible("done", nil, 0)
  vim.api.nvim_ui_send = nil
  check(pcall(run, b))
  vim.api.nvim_ui_send = function() error("transport unavailable") end
  check(pcall(run, b))
  vim.api.nvim_ui_send = capture
  vim.api.nvim_buf_delete(b, { force = true })
  visible(nil, nil, 0)
end)

it("retains completion order and falls back when completed buffers unload", function()
  local a = vim.api.nvim_create_buf(false, true)
  local b = vim.api.nvim_create_buf(false, true)
  local r = run(a)
  local s = run(b)
  local bid = task_id()
  local n = #sent
  attention.finish(b, s, "error")
  exact(n, { bid .. ":clear", "root:working" })
  visible("working", nil, 1)
  attention.finish(a, r, "ok")
  visible("done", nil, 0)
  n = #sent
  vim.api.nvim_exec_autocmds("UIEnter", {})
  exact(n, { "root:done" })
  n = #sent
  vim.api.nvim_buf_delete(a, { force = true })
  exact(n, { "root:error" })
  visible("error", nil, 0)
  local result = attention.prompt(nil, "auth", function()
    visible("blocked", "auth", 1)
    attention.prompt(nil, "permission", function()
      visible("blocked", "permission", 2)
    end)
    visible("blocked", "auth", 1)
    return "secret"
  end)
  check(result == "secret")
  visible("error", nil, 0)
  n = #sent
  vim.api.nvim_buf_delete(b, { force = true })
  exact(n, { "root:clear" })
  visible(nil, nil, 0)
end)

it("tracks the actual permission, question and credential prompts", function()
  local registry = require("straps.registry")
  require("straps.tools").register()
  require("straps.editor").register()
  local b = require("straps.state").new_session()
  local r, ctx = run(b)
  local confirm = vim.fn.confirm
  vim.fn.confirm = function()
    check(last("blocked", "permission"))
    return 2
  end
  local allowed = registry.call("hook.confirm", "bash", { command = "true" }, ctx)
  check(allowed == false)
  visible("working", nil, 1)
  vim.fn.confirm = confirm
  local input = vim.ui.input
  vim.ui.input = function(_, callback)
    check(last("blocked", "question"))
    callback("answer")
  end
  ctx.await = function(start)
    local answer
    start(function(v) answer = v end)
    return answer
  end
  local result = registry.call("tool.ask_user", { question = "Question?" }, ctx)
  check(result == "user answered: answer")
  visible("working", nil, 1)
  vim.ui.input = function() error("UI failed") end
  local ok = pcall(registry.call, "tool.ask_user", { question = "Question?" }, ctx)
  check(not ok)
  visible("working", nil, 1)
  vim.ui.input = input
  local cancel
  ctx.on_cancel = function(fn) cancel = fn end
  ctx.await = function(start)
    start(function() end)
    check(last("blocked", "question"))
    cancel()
    return nil
  end
  vim.ui.input = function() end
  result = registry.call("tool.ask_user", { question = "Question?" }, ctx)
  check(result:find("dismissed", 1, true) ~= nil)
  visible("working", nil, 1)
  local opened = false
  ctx.on_cancel = function(fn) fn() end
  vim.ui.input = function() opened = true end
  ctx.await = function(start) start(function() end); return nil end
  registry.call("tool.ask_user", { question = "Already stopped?" }, ctx)
  check(not opened)
  vim.ui.input = input
  ctx.on_cancel = function(fn) cancel = fn end
  ctx.await = function(start)
    start(function() end)
    check(last("blocked", "question"))
    return nil
  end
  result = registry.call("tool.ask_user", { question = "Question?", options = { "a", "b" } }, ctx)
  check(result:find("dismissed", 1, true) ~= nil)
  visible("working", nil, 1)
  require("straps.provider").register()
  registry.define({ name = "fn.api_key_store", kind = "fn", source = "return function() return nil end" })
  local secret = vim.fn.inputsecret
  vim.fn.inputsecret = function()
    check(last("blocked", "auth"))
    return ""
  end
  require("straps.ui").login({ "anthropic", "key" })
  visible("working", nil, 1)
  vim.fn.inputsecret = secret
  vim.fn.confirm = function()
    check(last("blocked", "permission"))
    return 2
  end
  require("straps.ui").logout({})
  visible("working", nil, 1)
  vim.fn.confirm = confirm
  attention.finish(b, r, "ok")
  vim.api.nvim_buf_delete(b, { force = true })
end)

it("replays active tasks and root outcomes and clears every owned ID", function()
  local buffers = {}
  local ids = {}
  local contexts = {}
  local runs = {}
  for i = 1, 3 do
    buffers[i] = require("straps.state").new_session()
    runs[i], contexts[i] = run(buffers[i])
    ids[i] = task_id()
  end
  local n = #sent
  local first = attention.wait(contexts[2], "permission")
  exact(n, { ids[2] .. ":blocked:kind=permission", "root:blocked:kind=permission" })
  n = #sent
  local second = attention.wait(contexts[2], "question")
  exact(n, { ids[2] .. ":blocked:kind=question", "root:blocked:kind=question" })
  n = #sent
  second()
  exact(n, { ids[2] .. ":blocked:kind=permission", "root:blocked:kind=permission" })
  attention.finish(buffers[3], runs[3], "ok")
  n = #sent
  vim.api.nvim_exec_autocmds("UIEnter", {})
  exact(n, { "root:blocked:kind=permission", ids[1] .. ":working", ids[2] .. ":blocked:kind=permission" }, true)
  visible("blocked", "permission", 2)
  attention.prompt(nil, "auth", function()
    local prompt_id = task_id()
    visible("blocked", "auth", 3)
    local third = attention.wait(contexts[1], "question")
    visible("blocked", "question", 3)
    third()
    visible("blocked", "auth", 3)
    n = #sent
    attention.setup(false)
    exact(n, { ids[1] .. ":clear", ids[2] .. ":clear", prompt_id .. ":clear", "root:clear" }, true)
    visible(nil, nil, 0)
    n = #sent
    attention.setup(true)
    exact(n, { "root:blocked:kind=auth", ids[1] .. ":working", ids[2] .. ":blocked:kind=permission", prompt_id .. ":blocked:kind=auth" }, true)
    visible("blocked", "auth", 3)
  end)
  visible("blocked", "permission", 2)
  n = #sent
  vim.api.nvim_buf_delete(buffers[3], { force = true })
  exact(n, { "root:blocked:kind=permission" })
  n = #sent
  vim.api.nvim_exec_autocmds("UIEnter", {})
  exact(n, { "root:blocked:kind=permission", ids[1] .. ":working", ids[2] .. ":blocked:kind=permission" }, true)
  n = #sent
  first()
  exact(n, { ids[2] .. ":working", "root:working" })
  visible("working", nil, 2)
  attention.prompt(nil, "auth", function()
    local prompt_id = task_id()
    n = #sent
    attention.shutdown()
    exact(n, { ids[1] .. ":clear", ids[2] .. ":clear", prompt_id .. ":clear", "root:clear" }, true)
    visible(nil, nil, 0)
    n = #sent
    first()
    attention.finish(buffers[1], runs[1], "ok")
    vim.api.nvim_exec_autocmds("UIEnter", {})
    exact(n, {})
  end)
  for _, b in ipairs(buffers) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  package.loaded["straps.attention"] = nil
  attention = require("straps.attention")
  attention.setup(true)
end)

it("keeps real admitted runs through hide and rename and clears unloads without cancelling", function()
  local registry = require("straps.registry")
  local state = require("straps.state")
  local loop = require("straps.loop")
  require("straps.provider").register()
  registry.define({ name = "hook.on_progress", kind = "hook", source = "return function() end" })
  registry.define({ name = "fn.provider", kind = "fn", source = [[return function(req, ctx)
    _G.status_context = ctx
    ctx.await(function(resolve) _G.status_resolve = resolve end)
    return { stop_reason = "end_turn", content = { { type = "text", text = "finished" } } }
  end]] })
  for _, active in ipairs({ false, true }) do
    for _, action in ipairs({ "bdelete", "bwipeout", "hide", "file", "saveas", "placeholder" }) do
      local b = state.new_session()
      state.append_text(b, "lifecycle " .. action)
      local baseline_win = vim.api.nvim_get_current_win()
      vim.cmd("botright split")
      local w = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(w, b)
      _G.status_context, _G.status_resolve = nil, nil
      loop.start(b)
      check(vim.wait(5000, function() return _G.status_resolve ~= nil end, 10))
      local ctx = _G.status_context
      local id = task_id()
      local release = attention.wait(ctx, "question")
      if not active then
        release()
        _G.status_resolve()
        check(vim.wait(5000, function() return not loop.running(b) end, 10))
      end
      local n = #sent
      local disposable = action == "bdelete" or action == "bwipeout"
      local path
      if disposable then
        vim.cmd(action .. "! " .. b)
      elseif action == "hide" then
        vim.api.nvim_win_close(w, true)
      else
        path = vim.fn.tempname() .. ".straps"
        if action == "placeholder" then
          vim.fn.writefile({ "placeholder" }, path)
          local placeholder = vim.fn.bufadd(path)
          check(not vim.api.nvim_buf_is_loaded(placeholder))
        end
        vim.api.nvim_buf_call(b, function()
          vim.cmd((action == "saveas" and "saveas! " or "file ") .. vim.fn.fnameescape(path))
        end)
      end
      exact(n, disposable and (active and { id .. ":clear", "root:clear" } or { "root:clear" }) or {})
      local expected_state = not disposable and (active and "blocked" or "done") or nil
      visible(expected_state, active and not disposable and "question" or nil, active and not disposable and 1 or 0)
      if active then check(loop.running(b)) end
      if not disposable then
        check(vim.b[b].straps_session == true)
        check(vim.api.nvim_buf_is_loaded(b))
      end
      n = #sent
      vim.api.nvim_exec_autocmds("UIEnter", {})
      exact(n, disposable and {} or (active and { "root:blocked:kind=question", id .. ":blocked:kind=question" } or { "root:done" }))
      if active then
        n = #sent
        release()
        exact(n, disposable and {} or { id .. ":working", "root:working" })
        n = #sent
        _G.status_resolve()
        check(vim.wait(5000, function() return not loop.running(b) end, 10))
        exact(n, disposable and {} or { id .. ":clear", "root:done" })
      end
      n = #sent
      release()
      vim.api.nvim_exec_autocmds("UIEnter", {})
      exact(n, disposable and {} or { "root:done" })
      if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_close(w, true) end
      if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end
      if vim.api.nvim_win_is_valid(baseline_win) then vim.api.nvim_set_current_win(baseline_win) end
      if path then vim.fn.delete(path) end
    end
  end
  _G.status_context, _G.status_resolve = nil, nil
end)

it("reports real loop lifecycle independently of hooks", function()
  local registry = require("straps.registry")
  local state = require("straps.state")
  local loop = require("straps.loop")
  require("straps.provider").register()
  registry.define({ name = "hook.on_progress", kind = "hook", source = "return function() end" })
  registry.define({ name = "fn.provider", kind = "fn", source = [[return function(req, ctx)
    ctx.emit({ type = "text_delta", text = "done" })
    return { stop_reason = "end_turn", content = { { type = "text", text = "done" } } }
  end]] })
  local b = state.new_session()
  state.append_text(b, "hello")
  local n = #sent
  loop.start(b)
  check(vim.wait(5000, function() return not loop.running(b) end, 10))
  local id = task_id(n + 1)
  exact(n, { id .. ":working", "root:working", id .. ":clear", "root:done" })
  visible("done", nil, 0)
  registry.define({ name = "fn.provider", kind = "fn", source = "return function() error('provider failure') end" })
  state.append_text(b, "again")
  loop.start(b)
  check(vim.wait(5000, function() return not loop.running(b) end, 10))
  check(last("error"))
  registry.define({ name = "fn.provider", kind = "fn", source = [[return function(req, ctx)
    ctx.await(function(resolve)
      ctx.on_cancel(function() resolve() end)
    end)
    return { stop_reason = "end_turn", content = {} }
  end]] })
  state.append_text(b, "wait")
  loop.start(b)
  check(last("working"))
  loop.stop(b)
  check(vim.wait(5000, function() return not loop.running(b) end, 10))
  check(last("idle"))
  straps.config.stop_backstop_ms = 1
  registry.define({ name = "fn.provider", kind = "fn", source = [[return function(req, ctx)
    local response = ctx.await(function() end)
    return response.value
  end]] })
  state.append_text(b, "force cancel")
  loop.start(b)
  loop.stop(b)
  check(vim.wait(5000, function() return not loop.running(b) end, 10))
  check(last("idle"))
  registry.define({ name = "fn.provider", kind = "fn", source = [[return function(req, ctx)
    ctx.await(function(resolve) ctx.on_cancel(function() resolve() end) end)
    return { stop_reason = "end_turn", content = {} }
  end]] })
  state.append_text(b, "wait again")
  loop.start(b)
  check(last("working"))
  vim.api.nvim_exec_autocmds("VimLeavePre", {})
  check(last("clear"))
  n = #sent
  check(vim.wait(5000, function() return not loop.running(b) end, 10))
  check(#sent == n)
  attention.shutdown()
  check(last("clear"))
  n = #sent
  run(b)
  attention.prompt(nil, "auth", function() end)
  check(#sent == n)
  vim.api.nvim_ui_send = real_send
  print("terminal status assertions: " .. count)
end)
