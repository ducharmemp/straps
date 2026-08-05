-- tests/run_multiplayer.lua — multiplayer awareness: an agent noticing that
-- other agents share this Neovim.
--   nvim --headless -l tests/run_multiplayer.lua
-- No network. Covers: fn.peer_agents (self-exclusion, running vs idle,
-- parent/child/sibling/peer relations, write-stamp attribution, ordering);
-- tool.agents registration, schema, alone-case and populated output; its
-- auto-allow through fn.readonly_policy and hook.confirm, and its membership
-- in the loop's parallel-readonly set; the default hook.on_run_start notice
-- (fires with a running peer, silent when alone, silent on an unsendable
-- transcript, announced once per peer set); and skill.multiplayer being
-- registered, listed in the prompt's skills layer, and loadable.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(here, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local failed = false
local function case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("PASS  " .. name)
  else
    failed = true
    print("FAIL  " .. name .. ": " .. tostring(err))
  end
end

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname() -- hermetic session writes

local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

-- Pretend the given session buffers have active runs (starting real ones
-- would call the provider). running_sessions is the single source the code
-- under test consults, so swapping it is enough.
local function with_running(bufs, fn)
  local real = loop.running_sessions
  loop.running_sessions = function() return bufs end
  local ok, err = pcall(fn)
  loop.running_sessions = real
  assert(ok, err)
end

-- A file buffer stamped as most recently written by `session`, exactly as
-- fn.mark_seen stamps it.
local function stamped_file(path, session)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  registry.call("fn.mark_seen", session, buf, true)
  return buf
end

-- ------------------------------------------------------------ fn.peer_agents

case("peer_agents excludes self and reports running vs idle", function()
  local me = state.new_session()
  local other = state.new_session()

  with_running({ me }, function()
    local peers = registry.call("fn.peer_agents", me)
    local found
    for _, p in ipairs(peers) do
      assert(p.bufnr ~= me, "peer_agents must not report the calling session")
      if p.bufnr == other then found = p end
    end
    assert(found, "the other session should be listed")
    assert(found.running == false, "other session has no active run: it is idle")
    assert(found.relation == "peer", "unrelated sessions are peers, got " .. found.relation)
    assert(found.label:find("straps", 1, true), "label should name the session file: " .. found.label)
  end)

  with_running({ me, other }, function()
    for _, p in ipairs(registry.call("fn.peer_agents", me)) do
      if p.bufnr == other then
        assert(p.running == true, "other session should read as running")
      end
    end
  end)
end)

case("peer_agents classifies parent, child and sibling relations", function()
  local parent = state.new_session()
  local me = state.new_session()
  local sibling = state.new_session()
  local child = state.new_session()
  vim.b[me].straps_parent = parent
  vim.b[sibling].straps_parent = parent
  vim.b[child].straps_parent = me
  vim.b[child].straps_task = "check the widget"
  vim.b[child].straps_spawn_depth = 2

  local by = {}
  for _, p in ipairs(registry.call("fn.peer_agents", me)) do by[p.bufnr] = p end
  assert(by[parent] and by[parent].relation == "parent",
    "spawner should be 'parent', got " .. tostring(by[parent] and by[parent].relation))
  assert(by[child] and by[child].relation == "child",
    "spawnee should be 'child', got " .. tostring(by[child] and by[child].relation))
  assert(by[sibling] and by[sibling].relation == "sibling",
    "same-parent session should be 'sibling', got " .. tostring(by[sibling] and by[sibling].relation))
  assert(by[child].task == "check the widget", "child task not surfaced")
  assert(by[child].depth == 2, "child depth not surfaced")
end)

case("peer_agents attributes written files to the session that wrote them", function()
  local me = state.new_session()
  local other = state.new_session()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local mine_path = dir .. "/mine.txt"
  local theirs_path = dir .. "/theirs.txt"
  vim.fn.writefile({ "x" }, mine_path)
  vim.fn.writefile({ "y" }, theirs_path)
  stamped_file(mine_path, me)
  stamped_file(theirs_path, other)

  local found
  for _, p in ipairs(registry.call("fn.peer_agents", me)) do
    if p.bufnr == other then found = p end
  end
  assert(found, "peer missing")
  local joined = table.concat(found.files, " ")
  assert(joined:find("theirs.txt", 1, true), "peer's write not attributed: " .. joined)
  assert(not joined:find("mine.txt", 1, true), "my own write attributed to the peer: " .. joined)
end)

case("peer_agents sorts running sessions before idle ones", function()
  local me = state.new_session()
  local idle = state.new_session()
  local busy = state.new_session()
  with_running({ busy }, function()
    local peers = registry.call("fn.peer_agents", me)
    local pos = {}
    for i, p in ipairs(peers) do pos[p.bufnr] = i end
    assert(pos[busy] and pos[idle], "both peers should be listed")
    assert(pos[busy] < pos[idle], "running peers must sort first")
  end)
end)

case("peer_agents tolerates an invalid calling bufnr and dead buffers", function()
  local dead = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(dead, { force = true })
  local peers = registry.call("fn.peer_agents", dead)
  assert(type(peers) == "table", "should still return a list for a dead caller")
  for _, p in ipairs(peers) do
    assert(vim.api.nvim_buf_is_valid(p.bufnr), "listed an invalid buffer")
  end
end)

-- --------------------------------------------------------------- tool.agents

case("tool.agents is registered with an empty-object schema", function()
  local e = registry.get("tool.agents")
  assert(e and e.kind == "tool", "tool.agents not registered")
  assert(e.input_schema and e.input_schema.type == "object", "schema should be an object")
  assert(e.input_schema.required and #e.input_schema.required == 0, "tool.agents takes no required input")
  local names = {}
  for _, t in ipairs(registry.call("fn.build_tools")) do names[t.name] = true end
  assert(names["agents"], "agents missing from the API tool list")
end)

case("tool.agents reports solitude when no other session exists", function()
  -- A pristine Neovim would have no sessions at all; here earlier cases left
  -- some, so assert against a caller that is the only session by construction:
  -- delete every other session buffer first.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local ok, is = pcall(function() return vim.b[b].straps_session end)
    if ok and is == true then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  local me = state.new_session()
  local out = registry.call("tool.agents", {}, { bufnr = me })
  assert(out:find("only straps agent", 1, true), "expected the alone message, got: " .. out)
  assert(out:find("DIFFERENT Neovim", 1, true), "alone message should name the cross-instance limit")
end)

case("tool.agents lists peers with relation, state, task and files", function()
  local me = state.new_session()
  local child = state.new_session()
  vim.b[child].straps_parent = me
  vim.b[child].straps_task = "audit the parser"
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/parser.lua"
  vim.fn.writefile({ "return {}" }, path)
  stamped_file(path, child)

  with_running({ child }, function()
    local out = registry.call("tool.agents", {}, { bufnr = me })
    assert(out:find("other agent", 1, true), "peer count missing: " .. out)
    -- The child's own line must carry every field, on one line — earlier cases
    -- leave other sessions alive, so assert on that line, not the whole text.
    local line
    for l in out:gmatch("[^\n]+") do
      if l:find("audit the parser", 1, true) then line = l end
    end
    assert(line, "no line for the child peer: " .. out)
    assert(line:find("[child, running]", 1, true), "relation/state missing: " .. line)
    assert(line:find("audit the parser", 1, true), "task missing: " .. line)
    assert(line:find("parser.lua", 1, true), "written file missing: " .. line)
    assert(out:find("skill.multiplayer", 1, true), "should point at the protocol skill: " .. out)
  end)
end)

case("tool.agents is auto-allowed and parallel-safe", function()
  assert(registry.call("fn.readonly_policy", "agents", {}) == true,
    "agents should be read-only policy")
  assert(registry.call("hook.confirm", "agents", {}, { bufnr = 0 }) == true,
    "agents should not prompt for confirmation")
  local src = registry.get("tool.agents").source
  assert(not src:find("ctx.await", 1, true), "a parallel-readonly tool must not await")
  local loop_src = table.concat(vim.fn.readfile(root .. "/lua/straps/loop.lua"), "\n")
  local block = loop_src:match("local PARALLEL_READONLY = {(.-)}")
  assert(block and block:find("agents = true", 1, true),
    "agents missing from loop.lua PARALLEL_READONLY")
end)

-- -------------------------------------------------------- hook.on_run_start

-- A session whose transcript already holds a real user message, so the
-- notice is never the only thing in the request.
local function session_with_prompt(text)
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, text or "do the thing")
  return bufnr
end

local function transcript(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

case("on_run_start announces a running peer once, into the transcript", function()
  local me = session_with_prompt()
  local peer = state.new_session()
  vim.b[peer].straps_parent = me
  vim.b[peer].straps_task = "read the docs"

  with_running({ peer }, function()
    registry.call("hook.on_run_start", { bufnr = me })
    local text = transcript(me)
    assert(text:find("Multiplayer: 1 other agent", 1, true), "notice missing: " .. text:sub(-400))
    assert(text:find("read the docs", 1, true), "notice should name the peer's task")
    assert(text:find("skill.multiplayer", 1, true), "notice should point at the skill")
    -- It must be a USER block, or the model never sees it as input.
    local parsed = state.parse(me)
    local last = parsed.messages[#parsed.messages]
    assert(last.role == "user", "notice must parse as a user message, got " .. last.role)

    -- Same peer set on the next run: no second copy.
    local before = transcript(me)
    registry.call("hook.on_run_start", { bufnr = me })
    assert(transcript(me) == before, "the same peer set must not be announced twice")
  end)
end)

case("on_run_start re-announces when the peer set changes", function()
  local me = session_with_prompt()
  local a = state.new_session()
  local b = state.new_session()
  with_running({ a }, function()
    registry.call("hook.on_run_start", { bufnr = me })
  end)
  local after_first = transcript(me)
  with_running({ a, b }, function()
    registry.call("hook.on_run_start", { bufnr = me })
  end)
  local text = transcript(me)
  assert(text ~= after_first, "a changed peer set should produce a fresh notice")
  assert(text:find("Multiplayer: 2 other agent", 1, true), "second notice should count both: "
    .. text:sub(-300))
end)

case("on_run_start is silent when no other agent is running", function()
  local me = session_with_prompt()
  local idle = state.new_session() -- exists, but has no active run
  local before = transcript(me)
  with_running({ me }, function()
    registry.call("hook.on_run_start", { bufnr = me })
  end)
  assert(transcript(me) == before, "a solo session's transcript must be untouched")
  assert(idle, "idle peer kept alive for the assertion above")
end)

case("on_run_start never makes an unsendable transcript sendable", function()
  -- A session with nothing but the system block and the empty trailing user
  -- marker parses to zero messages; the loop errors "nothing to send". The
  -- notice must not turn that into a real API request.
  local me = state.new_session()
  assert(#state.parse(me).messages == 0, "fixture should start unsendable")
  local peer = state.new_session()
  local before = transcript(me)
  with_running({ peer }, function()
    registry.call("hook.on_run_start", { bufnr = me })
  end)
  assert(transcript(me) == before, "notice must not be appended to an empty transcript")
  assert(#state.parse(me).messages == 0, "transcript must still be unsendable")
end)

case("on_run_start tolerates an invalid session buffer", function()
  local dead = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(dead, { force = true })
  registry.call("hook.on_run_start", { bufnr = dead })
  registry.call("hook.on_run_start", {})
  registry.call("hook.on_run_start", nil)
end)

-- ---------------------------------------------------------- skill.multiplayer

case("skill.multiplayer ships, is listed, and loads", function()
  local e = registry.get("skill.multiplayer")
  assert(e and e.kind == "skill", "skill.multiplayer not registered")
  local listing = registry.call("tool.skill", {}, {})
  assert(listing:find("skill.multiplayer", 1, true), "skill absent from the listing: " .. listing)
  local body = registry.call("tool.skill", { name = "multiplayer" }, {})
  assert(body:find("modified by another agent", 1, true),
    "skill should cover the collision error")
  assert(body:find('require("straps.loop").steer', 1, true),
    "skill should cover handing off via steering")
  local prompt = registry.call("fn.system_prompt")
  assert(prompt:find("- skill.multiplayer:", 1, true), "skill missing from the # Skills layer")
end)

if failed then
  vim.cmd("cquit 1")
end
