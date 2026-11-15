local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local straps = require("straps")
local state = require("straps.state")
local archive = require("straps.context_archive")
local uv = vim.uv
local assertion = 0
local function expect(condition)
  assertion = assertion + 1
  if tonumber(os.getenv("STRAPS_ARCHIVE_COUNTERFACTUAL")) == assertion then condition = not condition end
  assert(condition, "archive assertion " .. assertion)
end
local function make(ephemeral)
  if not ephemeral then return state.new_session() end
  local b = vim.api.nvim_create_buf(false, true)
  vim.b[b].straps_session = true
  return b
end
local function source(text)
  return { sources = { { kind = "tool_result", text = text or "original evidence" } } }
end
local function summary_receipt(id)
  return "Assistant summary of archived assistant claims and tool evidence [straps-context:" .. id .. "]\nsummary"
end

local function paths(id)
  return straps.config.session_dir .. "/.context-archive/records/" .. id .. ".json"
end
local function reload()
  package.loaded["straps.context_archive"] = nil
  archive = require("straps.context_archive")
end

before_each(function()
  straps.config.session_dir = vim.fn.tempname()
end)
after_each(function()
  vim.fn.delete(straps.config.session_dir, "rf")
end)

it("creates private immutable evidence without changing the transcript", function()
  local b = make()
  local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local input = source()
  local id = assert(archive.create(b, input))
  input.sources[1].text = "mutated"
  expect(id:match("^[a-f0-9]+$") and #id == 32)
  expect(vim.deep_equal(before, vim.api.nvim_buf_get_lines(b, 0, -1, false)))
  expect(uv.fs_stat(paths(id)).mode % 512 == 384)
  expect(uv.fs_stat(straps.config.session_dir .. "/.context-archive").mode % 512 == 448)
  local value = assert(archive.get(b, id))
  expect(value.sources[1].text == "original evidence")
  value.sources[1].text = "changed"
  expect(archive.get(b, id).sources[1].text == "original evidence")
  expect(archive.receipt(id) == "[straps-context:" .. id .. "]")
  expect(#state.list_sessions() == 1)
end)

it("rejects pasted IDs, traversal, bad pages, and unrelated child graphs", function()
  local a, b = make(), make()
  local id = assert(archive.create(a, source()))
  state.append(b, "assistant", nil, summary_receipt(id))
  expect(archive.get(b, id) == nil)
  expect(archive.get(a, "../../secret") == nil)
  expect(archive.create(b, { sources = source().sources, children = { id } }) == nil)
  expect(archive.retrieve(a, id, 1, 0, 1) == nil)
  expect(archive.retrieve(a, id, 1, 1, 16385) == nil)
  expect(archive.list(a, id, 1, 101) == nil)
  expect(archive.list(a, id, math.huge, 1) == nil)
  expect(archive.retrieve(a, id, 2) == nil)
end)

it("lists bounded source metadata and child IDs and returns byte continuations", function()
  local a, b = make(), make()
  local child = assert(archive.create(a, source("hidden fact")))
  local id = assert(archive.create(a, { sources = {
    { kind = "assistant", text = "abcdef" }, { kind = "tool_result", text = "later" },
  }, children = { child } }))
  local page = assert(archive.list(a, id, 1, 1))
  expect(#page.sources == 1 and page.sources[1].index == 1 and page.sources[1].bytes == 6)
  expect(page.next_offset == 2 and page.total == 3 and #page.children == 0)
  page = assert(archive.list(a, id, 3, 1))
  expect(page.children[1] == child and #page.sources == 0 and page.next_offset == nil)
  page = assert(archive.retrieve(a, id, 1, 2, 3))
  expect(page.text == "bcd" and page.offset == 2 and page.next_offset == 5 and page.continued)
  page = assert(archive.retrieve(a, id, 1, 5, 3))
  expect(page.text == "ef" and page.next_offset == nil and page.total == 6)
  state.append(a, "assistant", nil, summary_receipt(id))
  expect(archive.inherit(a, b) == true)
  expect(archive.get(b, child).sources[1].text == "hidden fact")
end)

it("persists trusted grants across buffer closure and module reload without receipts", function()
  local a = make()
  local path = vim.api.nvim_buf_get_name(a)
  local id = assert(archive.create(a, source()))
  vim.api.nvim_buf_delete(a, { force = true })
  reload()
  local b = state.open_session_file(path)
  expect(archive.get(b, id).sources[1].text == "original evidence")
  expect(archive.restore(b) == true and archive.persist(b) == true)
  local copy = make()
  vim.api.nvim_buf_set_lines(copy, 0, -1, false, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  expect(archive.get(copy, id) == nil)
end)

it("restricts inheritance to the copied block cutoff and keeps child grants after parent closure", function()
  local a, b = make(), make()
  local first = assert(archive.create(a, source("first")))
  local last = assert(archive.create(a, source("last")))
  state.append(a, "assistant", nil, summary_receipt(first))
  local cutoff = #state.list_blocks(a)
  state.append(a, "assistant", nil, summary_receipt(last))
  expect(archive.inherit(a, b, cutoff) == true)
  expect(archive.get(b, first).sources[1].text == "first")
  expect(archive.get(b, last) == nil)
  expect(archive.inherit(a, b, cutoff + 99) == nil)
  local path = vim.api.nvim_buf_get_name(b)
  vim.api.nvim_buf_delete(a, { force = true })
  vim.api.nvim_buf_delete(b, { force = true })
  reload()
  b = state.open_session_file(path)
  expect(archive.get(b, first).sources[1].text == "first")
end)

it("keeps ephemeral grants for the live buffer and does not promise restart recovery", function()
  local a = make(true)
  local id = assert(archive.create(a, source()))
  expect(uv.fs_stat(paths(id)) ~= nil and archive.persist(a) == true)
  expect(archive.restore(a) == true and archive.get(a, id).sources[1].text == "original evidence")
  reload()
  expect(archive.get(a, id) == nil)
  local b = make(true)
  expect(archive.get(b, id) == nil)
end)

it("retains grants after receipt undo and refuses inheritance from pasted receipts", function()
  local a, b, c = make(), make(), make()
  local id = assert(archive.create(a, source()))
  local prior = vim.api.nvim_buf_get_lines(a, 0, -1, false)
  state.append(a, "assistant", nil, summary_receipt(id))
  vim.api.nvim_buf_set_lines(a, 0, -1, false, prior)
  expect(archive.get(a, id).sources[1].text == "original evidence")
  expect(archive.inherit(a, b) == true and archive.get(b, id) == nil)
  state.append(c, "assistant", nil, summary_receipt(id))
  expect(archive.inherit(c, b) == nil and archive.get(b, id) == nil)
  state.append(a, "assistant", nil, summary_receipt("pasted"))
  expect(archive.inherit(a, b) == nil)
end)

it("selects structured receipt positions while ignoring literal examples", function()
  local a, b = make(), make()
  local id = assert(archive.create(a, source()))
  state.append(a, "system", nil, summary_receipt("unknown"))
  state.append(a, "user", nil, summary_receipt("unknown"))
  state.append(a, "assistant", nil, "Example [straps-context:unknown]\n" .. summary_receipt("unknown"))
  state.append(a, "tool_result", { id = "docs" }, "Documentation [straps-context:unknown]")
  expect(#assert(archive.referenced(a)) == 0)
  expect(archive.inherit(a, b) == true and archive.get(b, id) == nil)
  state.append(a, "tool_result", { id = "tool" }, archive.receipt(id) .. " archived tool evidence; tool=read_file; bytes=17")
  local cutoff = #state.list_blocks(a)
  state.append(a, "assistant", nil, summary_receipt(id))
  local refs = assert(archive.referenced(a))
  expect(#refs == 1 and refs[1] == id)
  expect(#assert(archive.referenced(a, cutoff - 1)) == 0)
  expect(archive.inherit(a, b, cutoff) == true)
  expect(archive.get(b, id).sources[1].text == "original evidence")
  state.append(a, "assistant", nil, summary_receipt("unknown"))
  local ids, err = archive.referenced(a)
  expect(ids == nil and err:find("invalid archive ID", 1, true) ~= nil)
end)

it("refuses collisions without overwriting immutable records", function()
  local a = make()
  local id = assert(archive.create(a, source("unchanged")))
  local old = uv.random
  uv.random = function(n) return string.rep(string.char(tonumber(id:sub(1, 2), 16)), n) end
  local fixed = assert(archive.create(a, source("fixed")))
  local collision, err = archive.create(a, source("overwrite"))
  uv.random = old
  expect(collision == nil and err:find("EEXIST", 1, true) ~= nil)
  expect(archive.get(a, fixed).sources[1].text == "fixed")
  expect(archive.get(a, id).sources[1].text == "unchanged")
end)

it("refuses archive and manifest write failures without granting inaccessible evidence", function()
  local a = make()
  local old = uv.fs_write
  uv.fs_write = function() return nil, "injected write failure" end
  local id, err = archive.create(a, source())
  uv.fs_write = old
  expect(id == nil and err:find("injected write failure", 1, true) ~= nil)
  local value = assert(archive.create(a, source()))
  local rename = uv.fs_rename
  uv.fs_rename = function() return nil, "injected manifest failure" end
  id, err = archive.create(a, source())
  uv.fs_rename = rename
  expect(id == nil and err:find("injected manifest failure", 1, true) ~= nil)
  expect(archive.get(a, value).sources[1].text == "original evidence")
end)

it("keeps UTF-8 retrieval pages valid without exceeding byte limits", function()
  local a = make()
  local id = assert(archive.create(a, source("aé界z")))
  local page = assert(archive.retrieve(a, id, 1, 1, 2))
  expect(page.text == "a" and page.next_offset == 2)
  page = assert(archive.retrieve(a, id, 1, 2, 3))
  expect(page.text == "é" and page.next_offset == 4)
  page = assert(archive.retrieve(a, id, 1, 4, 3))
  expect(page.text == "界" and page.next_offset == 7)
  expect(archive.retrieve(a, id, 1, 3, 2) == nil)
  expect(archive.retrieve(a, id, 1, 4, 2) == nil)
end)

it("rejects oversized records and preserves original source coordinates", function()
  local a = make()
  local id, err = archive.create(a, source(string.rep("x", 16 * 1024 * 1024)))
  expect(id == nil and err:find("size limit", 1, true) ~= nil)
  id = assert(archive.create(a, { sources = { { kind = "assistant", text = "fact", block = 7, first_lnum = 12 } } }))
  local value = assert(archive.get(a, id))
  expect(value.sources[1].block == 7 and value.sources[1].first_lnum == 12)
end)

it("reports sync and read failures and rejects corrupt persisted grants", function()
  local a = make()
  local fsync = uv.fs_fsync
  uv.fs_fsync = function() return nil, "injected sync failure" end
  local id, err = archive.create(a, source())
  uv.fs_fsync = fsync
  expect(id == nil and err:find("injected sync failure", 1, true) ~= nil)
  id = assert(archive.create(a, source()))
  local read = uv.fs_read
  uv.fs_read = function() return nil, "injected read failure" end
  local value
  value, err = archive.get(a, id)
  uv.fs_read = read
  expect(value == nil and err:find("injected read failure", 1, true) ~= nil)
  local name = vim.api.nvim_buf_get_name(a)
  local path = straps.config.session_dir .. "/.context-archive/grants/" .. vim.fn.sha256("file:" .. name) .. ".json"
  local fd = assert(uv.fs_open(path, "w", 384))
  assert(uv.fs_write(fd, '{"version":1,"session":"wrong","refs":[]}', 0))
  assert(uv.fs_close(fd))
  reload()
  value, err = archive.get(a, id)
  expect(value == nil and err:find("invalid archive grants", 1, true) ~= nil)
end)

it("refuses symlink storage and missing or malformed archives", function()
  local a = make()
  local id = assert(archive.create(a, source()))
  uv.fs_unlink(paths(id))
  expect(archive.get(a, id) == nil)
  local dir = straps.config.session_dir .. "/.context-archive"
  vim.fn.delete(dir, "rf")
  local target = vim.fn.tempname()
  uv.fs_mkdir(target, 448)
  uv.fs_symlink(target, dir)
  expect(archive.create(a, source()) == nil)
  vim.fn.delete(target, "rf")
end)

it("synchronizes creation only within the session boundary before writing records and grants", function()
  local a = make()
  local base = straps.config.session_dir
  local rootdir = base .. "/.context-archive"
  local events, descriptors = {}, {}
  local mkdir, open, fsync, close = uv.fs_mkdir, uv.fs_open, uv.fs_fsync, uv.fs_close
  uv.fs_mkdir = function(path, mode)
    events[#events + 1] = "mkdir:" .. path
    return mkdir(path, mode)
  end
  uv.fs_open = function(path, flags, mode)
    local fd, err = open(path, flags, mode)
    if fd then descriptors[fd] = path end
    if flags == "wx" then events[#events + 1] = "write:" .. path end
    return fd, err
  end
  uv.fs_fsync = function(fd)
    events[#events + 1] = "sync:" .. descriptors[fd]
    return fsync(fd)
  end
  uv.fs_close = function(fd)
    descriptors[fd] = nil
    return close(fd)
  end
  local id, err = archive.create(a, source())
  uv.fs_mkdir, uv.fs_open, uv.fs_fsync, uv.fs_close = mkdir, open, fsync, close
  assert(id, err)
  local expected = { "mkdir:" .. rootdir, "mkdir:" .. rootdir .. "/records", "mkdir:" .. rootdir .. "/grants" }
  local ancestry = { "sync:" .. rootdir .. "/records", "sync:" .. rootdir .. "/grants", "sync:" .. rootdir, "sync:" .. base }
  vim.list_extend(expected, ancestry)
  expect(vim.deep_equal(vim.list_slice(events, 1, #expected), expected))
  expect(events[#expected + 1] == "write:" .. paths(id))
  expect(events[#expected + 2] == "sync:" .. paths(id))
  expect(events[#expected + 3] == "sync:" .. rootdir .. "/records")
  expect(events[#events] == "sync:" .. rootdir .. "/grants")
  local outside = false
  for _, event in ipairs(events) do
    if event:sub(1, 5) == "sync:" and event ~= "sync:" .. base and event:sub(6, #base + 6) ~= base .. "/" then outside = true end
  end
  expect(not outside)
end)

it("fails closed at each boundary directory and resynchronizes existing directories on retry", function()
  local a = make()
  local rootdir = straps.config.session_dir .. "/.context-archive"
  local ancestors = { rootdir .. "/records", rootdir .. "/grants", rootdir, straps.config.session_dir }
  local before = vim.api.nvim_buf_get_lines(a, 0, -1, false)
  for _, failed in ipairs(ancestors) do
    local descriptors, writes, injected, closed = {}, 0, false, false
    local open, fsync, close = uv.fs_open, uv.fs_fsync, uv.fs_close
    uv.fs_open = function(name, flags, mode)
      local fd, err = open(name, flags, mode)
      if fd then descriptors[fd] = name end
      if flags == "wx" then writes = writes + 1 end
      return fd, err
    end
    uv.fs_fsync = function(fd)
      if descriptors[fd] == failed then
        injected = true
        return nil, "injected parent sync failure"
      end
      return fsync(fd)
    end
    uv.fs_close = function(fd)
      if descriptors[fd] == failed then closed = true end
      descriptors[fd] = nil
      return close(fd)
    end
    local id, err = archive.create(a, source())
    uv.fs_open, uv.fs_fsync, uv.fs_close = open, fsync, close
    expect(injected and id == nil)
    expect(err and err:find("durability uncertain", 1, true) and err:find(failed, 1, true)
      and err:find("injected parent sync failure", 1, true))
    expect(writes == 0 and closed)
    expect(vim.deep_equal(before, vim.api.nvim_buf_get_lines(a, 0, -1, false)))
  end
  local id = assert(archive.create(a, source()))
  reload()
  expect(archive.get(a, id).sources[1].text == "original evidence")
end)

it("reads existing grants and evidence without synchronizing or creating directories", function()
  local a = make()
  local id = assert(archive.create(a, source()))
  reload()
  local syncs, creates = 0, 0
  local fsync, mkdir = uv.fs_fsync, uv.fs_mkdir
  uv.fs_fsync = function() syncs = syncs + 1; return nil, "unexpected read sync" end
  uv.fs_mkdir = function() creates = creates + 1; return nil, "unexpected read mkdir" end
  local restored = archive.restore(a)
  local value = archive.get(a, id)
  local page = archive.retrieve(a, id, 1)
  local listing = archive.list(a, id)
  uv.fs_fsync, uv.fs_mkdir = fsync, mkdir
  expect(restored == true)
  expect(value and value.sources[1].text == "original evidence")
  expect(page and page.text == "original evidence")
  expect(listing and listing.sources[1].bytes == #"original evidence")
  expect(syncs == 0 and creates == 0)
end)

it("does not create absent archive directories while restoring an unarchived session", function()
  local a = make()
  expect(archive.restore(a) == true)
  expect(uv.fs_lstat(straps.config.session_dir .. "/.context-archive") == nil)
end)

it("retains ungranted orphan records after directory sync failure and does not adopt them on retry", function()
  local a = make()
  local dir = straps.config.session_dir .. "/.context-archive/records"
  local descriptors, orphan, written = {}, nil, false
  local open, fsync, close = uv.fs_open, uv.fs_fsync, uv.fs_close
  uv.fs_open = function(path, flags, mode)
    local fd, err = open(path, flags, mode)
    if fd then descriptors[fd] = path end
    if flags == "wx" and path:sub(1, #dir + 1) == dir .. "/" then
      written = true
      orphan = path:match("/([0-9a-f]+)%.json$")
    end
    return fd, err
  end
  uv.fs_fsync = function(fd)
    if written and descriptors[fd] == dir then return nil, "injected record directory failure" end
    return fsync(fd)
  end
  uv.fs_close = function(fd) descriptors[fd] = nil; return close(fd) end
  local id, err = archive.create(a, source("orphan"))
  uv.fs_open, uv.fs_fsync, uv.fs_close = open, fsync, close
  expect(id == nil and err:find("injected record directory failure", 1, true))
  expect(orphan and uv.fs_lstat(paths(orphan)) ~= nil)
  expect(archive.get(a, orphan) == nil)
  reload()
  local retry = assert(archive.create(a, source("retry")))
  expect(retry ~= orphan and archive.get(a, retry).sources[1].text == "retry")
  expect(archive.get(a, orphan) == nil and uv.fs_lstat(paths(orphan)) ~= nil)
  reload()
  expect(archive.get(a, orphan) == nil)
end)

it("merges stale independent writers and stale persistence with current grants", function()
  local a = make()
  local first = dofile(root .. "/lua/straps/context_archive.lua")
  local second = dofile(root .. "/lua/straps/context_archive.lua")
  assert(first.restore(a))
  assert(second.restore(a))
  local one = assert(first.create(a, source("one")))
  local two = assert(second.create(a, source("two")))
  local fresh = dofile(root .. "/lua/straps/context_archive.lua")
  expect(fresh.get(a, one) ~= nil)
  expect(fresh.get(a, two) ~= nil)
  assert(first.persist(a))
  fresh = dofile(root .. "/lua/straps/context_archive.lua")
  expect(fresh.get(a, one) ~= nil)
  expect(fresh.get(a, two) ~= nil)
end)

local function manifest(a)
  return straps.config.session_dir .. "/.context-archive/grants/"
    .. vim.fn.sha256("file:" .. vim.api.nvim_buf_get_name(a)) .. ".json"
end

it("refuses a held lock and a reentrant writer without deleting their lock", function()
  local a = make()
  assert(archive.create(a, source()))
  local path = manifest(a)
  local fd = assert(uv.fs_open(path .. ".lock", "wx", 384))
  local value, err = archive.persist(a)
  expect(value == nil and err:find("lock unavailable", 1, true))
  expect(uv.fs_lstat(path .. ".lock").mode % 512 == 384)
  assert(uv.fs_close(fd))
  assert(uv.fs_unlink(path .. ".lock"))
  local other = dofile(root .. "/lua/straps/context_archive.lua")
  assert(other.restore(a))
  local open, nested, nested_err, held = uv.fs_open
  uv.fs_open = function(name, flags, mode)
    local handle, reason, code = open(name, flags, mode)
    if name == path .. ".lock" and handle then
      nested, nested_err = other.persist(a)
      held = uv.fs_lstat(name) ~= nil
    end
    return handle, reason, code
  end
  value, err = archive.persist(a)
  uv.fs_open = open
  expect(value == true)
  expect(nested == nil and nested_err:find("lock unavailable", 1, true))
  expect(held)
  expect(uv.fs_lstat(path .. ".lock") == nil)
end)

it("rereads and validates a cached session manifest before merging", function()
  local a = make()
  assert(archive.create(a, source()))
  local path = manifest(a)
  local fd = assert(uv.fs_open(path, "w", 384))
  assert(uv.fs_write(fd, '{"version":1,"session":"forged","refs":[]}', 0))
  assert(uv.fs_close(fd))
  local value, err = archive.persist(a)
  expect(value == nil and err:find("invalid archive grants", 1, true))
  expect(uv.fs_lstat(path .. ".lock") == nil)
  local fresh = dofile(root .. "/lua/straps/context_archive.lua")
  value, err = fresh.restore(a)
  expect(value == nil and err:find("invalid archive grants", 1, true))
end)

for _, stage in ipairs({ "lstat", "read", "write", "rename", "sync", "tmp_cleanup", "lock_cleanup" }) do
  it("reports manifest " .. stage .. " failure and preserves cache publication rules", function()
    local a = make()
    local writer = dofile(root .. "/lua/straps/context_archive.lua")
    local observer = dofile(root .. "/lua/straps/context_archive.lua")
    local one = assert(writer.create(a, source("one")))
    assert(observer.restore(a))
    local two = assert(writer.create(a, source("two")))
    local path, descriptors, temporary, injected, renamed = manifest(a), {}, nil, false, false
    local open, close, lstat, read, write, rename, fsync, unlink =
      uv.fs_open, uv.fs_close, uv.fs_lstat, uv.fs_read, uv.fs_write, uv.fs_rename, uv.fs_fsync, uv.fs_unlink
    uv.fs_open = function(name, flags, mode)
      local fd, err, code = open(name, flags, mode)
      if fd then descriptors[fd] = name end
      if flags == "wx" and name:sub(1, #path + 1) == path .. "." and name ~= path .. ".lock" then temporary = name end
      return fd, err, code
    end
    uv.fs_close = function(fd) descriptors[fd] = nil; return close(fd) end
    uv.fs_lstat = function(name)
      if stage == "lstat" and name == path then injected = true; return nil, "injected lstat", "EACCES" end
      return lstat(name)
    end
    uv.fs_read = function(fd, size, offset)
      if stage == "read" and descriptors[fd] == path then injected = true; return nil, "injected read" end
      return read(fd, size, offset)
    end
    uv.fs_write = function(fd, text, offset)
      if stage == "write" and descriptors[fd] == temporary then injected = true; return nil, "injected write" end
      return write(fd, text, offset)
    end
    uv.fs_rename = function(from, to)
      if stage == "rename" or stage == "tmp_cleanup" then injected = true; return nil, "injected rename" end
      local ok, err = rename(from, to)
      renamed = ok
      return ok, err
    end
    uv.fs_fsync = function(fd)
      if stage == "sync" and renamed and descriptors[fd] == vim.fn.fnamemodify(path, ":h") then
        injected = true; return nil, "injected sync"
      end
      return fsync(fd)
    end
    uv.fs_unlink = function(name)
      if (stage == "tmp_cleanup" and name == temporary) or (stage == "lock_cleanup" and name == path .. ".lock") then
        injected = true; return nil, "injected cleanup"
      end
      return unlink(name)
    end
    local value, err = observer.persist(a)
    uv.fs_open, uv.fs_close, uv.fs_lstat, uv.fs_read, uv.fs_write, uv.fs_rename, uv.fs_fsync, uv.fs_unlink =
      open, close, lstat, read, write, rename, fsync, unlink
    expect(injected)
    expect(value == nil and err:find("injected", 1, true))
    expect(observer.get(a, two) == nil)
    expect(observer.get(a, one) ~= nil)
    expect((lstat(path .. ".lock") ~= nil) == (stage == "lock_cleanup"))
    expect(not temporary or (lstat(temporary) ~= nil) == (stage == "tmp_cleanup"))
    expect((err:find("uncertain after rename", 1, true) ~= nil) == (stage == "sync" or stage == "lock_cleanup"))
    if stage == "tmp_cleanup" or stage == "lock_cleanup" then expect(err:find("cleanup failed", 1, true) ~= nil) end
    if stage == "lock_cleanup" then assert(unlink(path .. ".lock")) end
    if stage == "tmp_cleanup" then assert(unlink(temporary)) end
    assert(observer.persist(a))
    expect(observer.get(a, two) ~= nil)
    local fresh = dofile(root .. "/lua/straps/context_archive.lua")
    expect(fresh.get(a, one) ~= nil and fresh.get(a, two) ~= nil)
  end)
end

teardown(function() print("archive assertions: " .. assertion) end)
