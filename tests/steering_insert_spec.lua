local script = debug.getinfo(1, "S").source:sub(2)
local fixture = vim.fn.fnamemodify(script, ":p:h") .. "/fixtures/steering_insert.lua"

it("keeps native Insert-mode composition intact during same-buffer streaming", function()
  local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n",
    "-c", "luafile " .. vim.fn.fnameescape(fixture) }, { text = true }):wait(10000)
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
end)
