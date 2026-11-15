local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(here, ':p:h:h')
package.path = root .. '/lua/?.lua;' .. package.path
it('resolves the published OpenAI provider_config shape through the actual core resolver without a request', function()
  local readme = table.concat(vim.fn.readfile(root .. '/../straps-classifier/README.md'), '\n')
  local shape = assert(readme:match('provider_config = ({ provider = "openai", [^\n]+ })'))
  local config = assert(loadstring('local selected_model = "published-model"; return ' .. shape))()
  local provider = require('straps.provider')
  if vim.env.STRAPS_MODEL_MUTANT then config.openai_model, config.model = nil, 'published-model' end
  assert.equals('published-model', provider.resolve_model('openai', nil, config))
end)
