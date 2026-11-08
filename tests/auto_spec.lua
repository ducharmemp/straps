local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
straps.config.gzip = false
local registry = require("straps.registry")
local state = require("straps.state")
local ui = require("straps.ui")
local saved_notify, saved_loaded, saved_preload
local buffers, notes, buf
local opts, picker, selected, preselected, closed, selected_calls, fallback_calls

local function expect(actual, expected)
  assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function session()
  local b = state.new_session()
  buffers[#buffers + 1] = b
  vim.api.nvim_set_current_buf(b)
  return b
end

local function grants(b)
  return registry.granted(b or buf)
end

local function seed()
  for _, key in ipairs({ "cap:edit", "cap:obsolete", "editdir:/tmp/auto", "example@v1" }) do
    registry.grant(buf, key)
  end
end

local function capability(b, categories)
  registry.define({ name = "fn.capability", kind = "fn", source = "return function() return " .. vim.inspect(categories) .. " end" },
    { scope = b })
end

local function snacks(value)
  package.loaded.snacks = nil
  package.preload.snacks = function() return value end
end

local function install_picker()
  picker = {
    list = { set_selected = function(_, items) preselected = items end },
    selected = function() selected_calls = selected_calls + 1; return selected end,
    current = function() fallback_calls = fallback_calls + 1; return { text = "edit" } end,
    close = function()
      closed = closed + 1
      if opts and opts.on_close then opts.on_close(picker) end
    end,
  }
  snacks({ picker = { pick = function(options) opts = options; return picker end } })
end

local function open()
  ui.auto()
  expect(type(opts), "table")
end

local function notified(fragment)
  for _, note in ipairs(notes) do
    if note.msg:find(fragment, 1, true) then return true end
  end
  return false
end

before_each(function()
  saved_notify, saved_loaded, saved_preload = vim.notify, package.loaded.snacks, package.preload.snacks
  buffers, notes = {}, {}
  opts, preselected = nil, nil
  selected, closed, selected_calls, fallback_calls = {}, 0, 0, 0
  vim.notify = function(msg, level) notes[#notes + 1] = { msg = tostring(msg), level = level } end
  registry.set_active_scope(nil)
  buf = session()
  capability(buf, { "edit", "exec", "network" })
  registry.set_active_scope(buf)
  install_picker()
end)

after_each(function()
  vim.notify, package.loaded.snacks, package.preload.snacks = saved_notify, saved_loaded, saved_preload
  registry.set_active_scope(nil)
  for _, b in ipairs(buffers) do
    registry.clear_grants(b)
    if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end
  end
end)

it("opens the optional picker with category items and preselects current capability grants", function()
  seed()
  open()
  local texts = {}
  for _, item in ipairs(opts.items) do texts[#texts + 1] = item.text end
  expect(texts, { "edit", "exec", "network" })
  expect(type(opts.on_show), "function")
  opts.on_show(picker)
  local texts_selected = {}
  for _, item in ipairs(preselected) do texts_selected[#texts_selected + 1] = item.text end
  expect(texts_selected, { "edit" })
end)

it("replaces capability grants from selected items and preserves unrelated grants", function()
  seed()
  open()
  opts.on_show(picker)
  selected = { opts.items[2], opts.items[3] }
  opts.confirm(picker, opts.items[1])
  expect(selected_calls, 1)
  expect(fallback_calls, 0)
  expect(grants(), { ["cap:exec"] = true, ["cap:network"] = true, ["editdir:/tmp/auto"] = true, ["example@v1"] = true })
  expect(closed, 1)
end)

it("clears capability grants for an empty selection without using the highlighted item", function()
  seed()
  open()
  opts.on_show(picker)
  opts.confirm(picker, opts.items[1])
  expect(selected_calls, 1)
  expect(fallback_calls, 0)
  expect(grants(), { ["editdir:/tmp/auto"] = true, ["example@v1"] = true })
end)

it("leaves grants unchanged on cancellation", function()
  seed()
  local before = grants()
  open()
  opts.on_show(picker)
  picker:close()
  if opts.on_close then opts.on_close(picker) end
  selected = { opts.items[2] }
  opts.confirm(picker)
  expect(grants(), before)
  expect(selected_calls, 0)
end)

it("uses opening categories after both the original scope and active scope change", function()
  open()
  opts.on_show(picker)
  capability(buf, { "different" })
  local other = session()
  capability(other, { "elsewhere" })
  registry.set_active_scope(other)
  selected = { opts.items[2] }
  opts.confirm(picker)
  expect(grants(buf), { ["cap:exec"] = true })
  expect(grants(other), {})
end)

for _, failure in ipairs({ "missing Snacks", "missing picker", "lazy picker failure", "broken constructor" }) do
  it("reports existing grants with " .. failure, function()
    seed()
    local before = grants()
    if failure == "missing Snacks" then
      package.loaded.snacks = nil
      package.preload.snacks = function() error("Snacks unavailable") end
    elseif failure == "missing picker" then
      snacks({})
    elseif failure == "lazy picker failure" then
      snacks(setmetatable({}, { __index = function() error("lazy picker unavailable") end }))
    else
      snacks({ picker = { pick = function() error("constructor failed") end } })
    end
    ui.auto("")
    expect(notified("auto grants: edit, obsolete"), true)
    expect(grants(), before)
  end)
end

it("rejects selected categories introduced after the picker opened", function()
  seed()
  local before = grants()
  open()
  opts.on_show(picker)
  capability(buf, { "edit", "exec", "network", "later" })
  selected = { { text = "later" } }
  opts.confirm(picker)
  expect(grants(), before)
end)

for _, method in ipairs({ "selected", "close" }) do
  it("preserves grants when picker method " .. method .. " raises", function()
    seed()
    local before = grants()
    open()
    opts.on_show(picker)
    selected = { opts.items[2] }
    picker[method] = function() error("picker method failed") end
    opts.confirm(picker)
    expect(grants(), before)
  end)
end

for _, method in ipairs({ "selected", "close", "set_selected" }) do
  it("preserves grants when picker method " .. method .. " is malformed", function()
    seed()
    local before = grants()
    open()
    selected = { opts.items[2] }
    if method == "set_selected" then picker.list.set_selected = false else picker[method] = false end
    opts.on_show(picker)
    opts.confirm(picker)
    expect(grants(), before)
  end)
end

it("preserves grants after a deferred on_show failure", function()
  seed()
  local before = grants()
  open()
  picker.list.set_selected = function() error("deferred list failure") end
  opts.on_show(picker)
  selected = { opts.items[2] }
  opts.confirm(picker)
  expect(grants(), before)
end)

for _, invalidation in ipairs({ "deleted", "unmarked" }) do
  it("does not mutate an original session that was " .. invalidation, function()
    seed()
    open()
    opts.on_show(picker)
    local before = grants()
    if invalidation == "deleted" then vim.api.nvim_buf_delete(buf, { force = true }) else vim.b[buf].straps_session = nil end
    local after_invalidation = grants()
    local other = session()
    selected = { opts.items[2] }
    opts.confirm(picker)
    expect(grants(buf), after_invalidation)
    expect(grants(other), {})
    if invalidation == "unmarked" then expect(grants(buf), before) end
  end)
end

it("rejects non-session buffers without opening a picker", function()
  vim.b[buf].straps_session = nil
  ui.auto()
  expect(opts, nil)
  expect(notified("not a straps session buffer"), true)
end)

it("keeps explicit categories additive and off limited to capability grants", function()
  seed()
  ui.auto("exec, network")
  expect(opts, nil)
  expect(grants(), { ["cap:edit"] = true, ["cap:obsolete"] = true, ["cap:exec"] = true, ["cap:network"] = true,
    ["editdir:/tmp/auto"] = true, ["example@v1"] = true })
  local before = grants()
  ui.auto("edit invalid")
  expect(grants(), before)
  expect(notified("unknown auto category"), true)
  ui.auto("off")
  expect(grants(), { ["editdir:/tmp/auto"] = true, ["example@v1"] = true })
  expect(notified("auto grants cleared:"), true)
end)

it("preserves the entire grant set when confirmation runs inside a tool body", function()
  seed()
  local before = grants()
  open()
  opts.on_show(picker)
  selected = { opts.items[2] }
  registry.define({ name = "tool.auto_test_confirm", kind = "tool", source = [[return function(_, ctx) ctx.confirm() end]] },
    { scope = buf })
  local allowed, _, run = registry.gate_tool("auto_test_confirm", {}, { bufnr = buf })
  expect(allowed, true)
  local ok = run({ bufnr = buf, confirm = function() opts.confirm(picker) end })
  expect(ok, true)
  expect(grants(), before)
  expect(notified("cannot grant its own session"), true)
end)
