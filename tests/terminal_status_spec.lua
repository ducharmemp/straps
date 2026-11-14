local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local straps = require("straps")
straps.config.session_dir = vim.fn.tempname()
local real_send = vim.api.nvim_ui_send
local sent = {}
vim.api.nvim_ui_send = function(text) sent[#sent + 1] = text end
local attention = require("straps.attention")
local count = 0
local function check(value)
  count = count + 1
  if tonumber(vim.env.STRAPS_STATUS_COUNTERFACTUAL) == count then value = not value end
  assert(value, "terminal status assertion " .. count)
end
local function last(state, kind)
  local text = sent[#sent] or ""
  return text:find(":state=" .. state .. (kind and (":kind=" .. kind) or "") .. "\27\\", 1, true) ~= nil
end
local function reports_since(n)
  local reports = {}
  for i = n + 1, #sent do
    local id, state, tail = sent[i]:match("^\27%]7501;app=straps:id=([^:]+):state=([^:\27]+)(.-)\27\\$")
    check(id and (tail == "" or tail:match("^:kind=%a+$")))
    reports[#reports + 1] = id .. ":" .. state .. tail
  end
  table.sort(reports)
  return reports
end
local function exact(n, expected)
  table.sort(expected)
  check(vim.deep_equal(reports_since(n), expected))
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

it("reports protocol states with independent run-bound waits and cleanup", function()
  check(straps.config.terminal_status == true)
  attention.setup(true)
  local a = vim.api.nvim_create_buf(false, true)
  local b = vim.api.nvim_create_buf(false, true)
  local r, ctx = run(a)
  local id = sent[#sent]:match("id=([^:]+)")
  check(sent[#sent] == "\27]7501;app=straps:id=" .. id .. ":state=working\27\\")
  local s = run(b)
  check(sent[#sent]:match("id=([^:]+)") ~= id)
  local release = attention.wait(ctx, "permission")
  check(last("blocked", "permission"))
  local release2 = attention.wait(ctx, "question")
  check(last("blocked", "question"))
  release2()
  check(last("blocked", "permission"))
  release()
  check(last("working"))
  local n = #sent
  release()
  check(#sent == n)
  local stale = attention.wait(ctx, "auth")
  attention.finish(a, r, "ok")
  check(last("done"))
  local newer = run(a)
  n = #sent
  stale()
  attention.finish(a, r, "error")
  check(#sent == n)
  attention.finish(a, newer, "cancelled")
  check(last("idle"))
  for _, reason in ipairs({ "error", "blank", "stalled", "max_turns" }) do
    local current = run(a)
    attention.finish(a, current, reason)
    check(last("error"))
  end
  check(attention.prompt(nil, "auth", function() check(last("blocked", "auth")); return "secret" end) == "secret")
  check(last("clear"))
  local ok = pcall(attention.prompt, ctx, "question", function() error("prompt failed") end)
  check(not ok)
  local nr, nc = run(a)
  local blocked
  ok = pcall(attention.prompt, nc, "permission", function() blocked = last("blocked", "permission"); error("failed") end)
  check(blocked)
  check(not ok and last("working"))
  attention.setup(false)
  check(last("clear"))
  n = #sent
  attention.wait(nc, "question")()
  attention.finish(a, nr, "ok")
  attention.prompt(nil, "auth", function() return "" end)
  check(#sent == n)
  attention.setup(true)
  check(#sent > n)
  vim.api.nvim_exec_autocmds("UIEnter", {})
  check(last("working") or last("done"))
  vim.api.nvim_buf_delete(a, { force = true })
  check(last("clear"))
  attention.finish(b, s, "ok")
  check(last("done"))
  vim.api.nvim_ui_send = nil
  check(pcall(run, b))
  vim.api.nvim_ui_send = function() error("transport unavailable") end
  check(pcall(run, b))
  vim.api.nvim_ui_send = function(text) sent[#sent + 1] = text end
  vim.api.nvim_buf_delete(b, { force = true })
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
  check(allowed == false and last("working"))
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
  check(result == "user answered: answer" and last("working"))
  vim.ui.input = function() error("UI failed") end
  local ok = pcall(registry.call, "tool.ask_user", { question = "Question?" }, ctx)
  check(not ok and last("working"))
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
  check(result:find("dismissed", 1, true) and last("working"))
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
  check(result:find("dismissed", 1, true) and last("working"))
  require("straps.provider").register()
  registry.define({ name = "fn.api_key_store", kind = "fn", source = "return function() return nil end" })
  local secret = vim.fn.inputsecret
  vim.fn.inputsecret = function()
    check(last("blocked", "auth"))
    return ""
  end
  require("straps.ui").login({ "anthropic", "key" })
  check(last("clear"))
  vim.fn.inputsecret = secret
  vim.fn.confirm = function()
    check(last("blocked", "permission"))
    return 2
  end
  require("straps.ui").logout({})
  check(last("clear"))
  vim.fn.confirm = confirm
  attention.finish(b, r, "ok")
  vim.api.nvim_buf_delete(b, { force = true })
end)

it("replays exact retained task sets and clears every owned ID", function()
  local buffers = {}
  local ids = {}
  local contexts = {}
  local runs = {}
  for i = 1, 3 do
    buffers[i] = require("straps.state").new_session()
    runs[i], contexts[i] = run(buffers[i])
    ids[i] = sent[#sent]:match("id=([^:]+)")
  end
  local n = #sent
  local first = attention.wait(contexts[2], "permission")
  exact(n, { ids[2] .. ":blocked:kind=permission" })
  n = #sent
  local second = attention.wait(contexts[2], "question")
  exact(n, { ids[2] .. ":blocked:kind=question" })
  n = #sent
  second()
  exact(n, { ids[2] .. ":blocked:kind=permission" })
  attention.finish(buffers[3], runs[3], "ok")
  n = #sent
  vim.api.nvim_exec_autocmds("UIEnter", {})
  exact(n, { ids[1] .. ":working", ids[2] .. ":blocked:kind=permission", ids[3] .. ":done" })
  attention.prompt(nil, "auth", function()
    local prompt_id = sent[#sent]:match("id=([^:]+)")
    n = #sent
    attention.setup(false)
    exact(n, { ids[1] .. ":clear", ids[2] .. ":clear", ids[3] .. ":clear", prompt_id .. ":clear" })
    n = #sent
    attention.setup(true)
    exact(n, { ids[1] .. ":working", ids[2] .. ":blocked:kind=permission", ids[3] .. ":done", prompt_id .. ":blocked:kind=auth" })
  end)
  n = #sent
  vim.api.nvim_buf_delete(buffers[3], { force = true })
  exact(n, { ids[3] .. ":clear" })
  n = #sent
  vim.api.nvim_exec_autocmds("UIEnter", {})
  exact(n, { ids[1] .. ":working", ids[2] .. ":blocked:kind=permission" })
  n = #sent
  first()
  exact(n, { ids[2] .. ":working" })
  attention.prompt(nil, "auth", function()
    local prompt_id = sent[#sent]:match("id=([^:]+)")
    n = #sent
    attention.shutdown()
    exact(n, { ids[1] .. ":clear", ids[2] .. ":clear", prompt_id .. ":clear" })
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
      local id = sent[#sent]:match("id=([^:]+)")
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
      exact(n, disposable and { id .. ":clear" } or {})
      if active then check(loop.running(b)) end
      if not disposable then check(vim.b[b].straps_session == true and vim.api.nvim_buf_is_loaded(b)) end
      n = #sent
      vim.api.nvim_exec_autocmds("UIEnter", {})
      exact(n, disposable and {} or { id .. (active and ":blocked:kind=question" or ":done") })
      if active then
        n = #sent
        release()
        exact(n, disposable and {} or { id .. ":working" })
        n = #sent
        _G.status_resolve()
        check(vim.wait(5000, function() return not loop.running(b) end, 10))
        exact(n, disposable and {} or { id .. ":done" })
      end
      n = #sent
      release()
      vim.api.nvim_exec_autocmds("UIEnter", {})
      exact(n, disposable and {} or { id .. ":done" })
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
  check(#sent >= n + 2 and sent[n + 1]:find(":state=working\27\\", 1, true) and last("done"))
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
