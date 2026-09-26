-- tests/e2e_http_spec.lua — TRUE end-to-end: the real curl binary talking to
-- a real in-process TCP server (vim.uv), through the real fn.provider and
-- the real loop. This is the only tier that can catch curl argv regressions,
-- --data-binary stdin handling, Expect: 100-continue behavior, and the
-- -w STRAPS_HTTP_STATUS stderr marker parsing against an actual socket.
--   busted tests/e2e_http_spec.lua
-- Requires curl on PATH; skips (exit 0 with a note) if absent.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- Runs `fn` at test time, in document order with the surrounding `it`s (the
-- old runner executed cases inline; busted collects first, then runs).
local function step(fn)
  local info = debug.getinfo(fn, "S")
  describe("step@" .. info.short_src .. ":" .. info.linedefined, function() setup(fn) end)
end

if vim.fn.executable("curl") == 0 then
  print("SKIP  no curl on PATH — e2e http tests skipped")
  return
end

local straps = require("straps").setup({})
straps.config.session_dir = vim.fn.tempname()
-- Pin the Anthropic backend: this e2e suite points fn.provider at an in-process
-- Anthropic-shaped server, so a developer's persisted ~/.config/straps/provider
-- (which fn.provider would otherwise consult) must not route the run to OpenAI.
straps.config.provider = "anthropic"
vim.env.ANTHROPIC_API_KEY = "test-key-not-real"

local registry = require("straps.registry")
local state = require("straps.state")
local loop = require("straps.loop")

registry.define({ name = "hook.confirm", kind = "hook", doc = "test: allow all",
  source = [[return function() return true end]] }, { scope = "global" })


-- Minimal HTTP server: reads one request per connection (handling curl's
-- Expect: 100-continue), records the body, replies with `respond(body)`,
-- and closes. NOTE: these callbacks run in libuv's fast context — string
-- work and socket writes only, no vim.api.
local function start_server(respond, record)
  local server = vim.uv.new_tcp()
  assert(server:bind("127.0.0.1", 0))
  local port = server:getsockname().port
  server:listen(16, function(err)
    if err then return end
    local client = vim.uv.new_tcp()
    server:accept(client)
    local buf, header_end, clen, continued = "", nil, nil, false
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then return end
      buf = buf .. chunk
      if not header_end then
        local he = buf:find("\r\n\r\n", 1, true)
        if he then
          header_end = he + 3
          clen = tonumber(buf:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
          if not continued and buf:lower():find("expect:%s*100%-continue") then
            continued = true
            client:write("HTTP/1.1 100 Continue\r\n\r\n")
          end
        end
      end
      if header_end and #buf >= header_end + clen then
        local body = buf:sub(header_end + 1, header_end + clen)
        if record then record(body) end
        client:write(respond(body), function()
          client:shutdown(function() client:close() end)
        end)
      end
    end)
  end)
  return server, port
end

local function sse(events)
  return "HTTP/1.1 200 OK\r\n"
    .. "Content-Type: text/event-stream\r\n"
    .. "Connection: close\r\n\r\n"
    .. events
end

local function run_session(user_text)
  local bufnr = state.new_session()
  state.append(bufnr, "user", nil, user_text)
  loop.start(bufnr)
  vim.wait(20000, function() return not loop.running(bufnr) end, 50)
  return bufnr, table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- ---------------------------------------------------------------- happy path

local got_body = nil
local ok_server, ok_port = start_server(function()
  return sse(table.concat({
    'event: message_start',
    'data: {"type":"message_start","message":{"usage":{"input_tokens":42}}}',
    '',
    'event: content_block_start',
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
    '',
    'event: content_block_delta',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"e2e-real-http-answer"}}',
    '',
    'event: content_block_stop',
    'data: {"type":"content_block_stop","index":0}',
    '',
    'event: message_delta',
    'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}',
    '',
    'event: message_stop',
    'data: {"type":"message_stop"}',
    '',
  }, "\n"))
end, function(body) got_body = body end)

straps.config.base_url = "http://127.0.0.1:" .. ok_port
local buf_ok, text_ok = run_session("answer over real http")

it("real curl + real socket: SSE answer streams into the transcript", function()
  assert(not loop.running(buf_ok), "run did not finish")
  assert(text_ok:find("e2e-real-http-answer", 1, true),
    "streamed answer missing:\n" .. text_ok:sub(-300))
  assert(not text_ok:find("run error", 1, true), "unexpected run error:\n" .. text_ok:sub(-300))
end)

it("the request body that crossed the wire is complete, valid JSON", function()
  assert(got_body and #got_body > 0, "server captured no request body")
  local decoded = vim.json.decode(got_body) -- rejects truncation/corruption
  assert(decoded.model, "body missing model")
  assert(decoded.stream == true, "body should request streaming")
  assert(type(decoded.messages) == "table" and #decoded.messages >= 1, "messages missing")
  assert(type(decoded.tools) == "table" and #decoded.tools > 10,
    "tools missing from the wire body")
  -- The wire payload is where an array-shaped properties would 400 live.
  assert(not got_body:find('"properties":[]', 1, true),
    "array-shaped properties reached the wire")
end)

local err_server, err_port
local buf_err, text_err
step(function()
  ok_server:close()

  -- ------------------------------------------------------------------ 400 path

  err_server, err_port = start_server(function()
    local body = '{"type":"error","error":{"type":"invalid_request_error","message":"e2e wire-level rejection"}}'
    return "HTTP/1.1 400 Bad Request\r\n"
      .. "Content-Type: application/json\r\n"
      .. "Content-Length: " .. #body .. "\r\n"
      .. "Connection: close\r\n\r\n"
      .. body
  end)

  straps.config.base_url = "http://127.0.0.1:" .. err_port
  buf_err, text_err = run_session("this will be rejected")
end)

it("real 400 over the wire surfaces status and API message", function()
  assert(not loop.running(buf_err), "run did not finish after wire 400")
  assert(text_err:find("request failed (HTTP 400)", 1, true),
    "status not surfaced:\n" .. text_err:sub(-300))
  assert(text_err:find("e2e wire-level rejection", 1, true),
    "API message not surfaced:\n" .. text_err:sub(-300))
end)

step(function()
  err_server:close()
  straps.config.base_url = nil
end)
