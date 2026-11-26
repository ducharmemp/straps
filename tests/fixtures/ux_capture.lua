require("straps").setup({})
local registry = require("straps.registry")
_G.ux_capture_calls = 0
registry.define({ name = "fn.provider", kind = "fn", source = [=[return function(req, ctx)
  _G.ux_capture_calls = _G.ux_capture_calls + 1
  if _G.ux_capture_calls == 1 then
    local content = {}
    for i, command in ipairs({ "echo one", "echo two", "echo three" }) do
      content[#content + 1] = { type = "tool_use", id = "ux" .. i, name = "bash", input = { command = command } }
    end
    return { stop_reason = "tool_use", content = content, usage = { output_tokens = 42 } }
  end
  ctx.emit({ type = "text_delta", text = "Done." })
  return { stop_reason = "end_turn", content = { { type = "text", text = "Done." } } }
end]=] })
vim.api.nvim_create_user_command("UxCaptureRun", function()
  local bufnr = require("straps.ui").require_session(vim.api.nvim_get_current_buf())
  if not bufnr then return end
  require("straps.state").add_to_trailing_user(bufnr, "run the capture batch")
  require("straps.steering").send(bufnr)
end, {})
