-- tests/contextual_default_discover_spec.lua — the refresh-cwd check with contextual's default discover wrapper.
-- Run from the repo root: busted tests/contextual_default_discover_spec.lua </dev/null

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
vim.env.STRAPS_REFRESH_DEFAULT_DISCOVER = "1"
local chunk = assert(loadfile(here .. "/contextual_refresh_cwd_spec.lua"))
setfenv(chunk, getfenv(1))
chunk()
