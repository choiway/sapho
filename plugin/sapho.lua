if vim.g.loaded_sapho then return end
vim.g.loaded_sapho = 1
require('sapho.context').track_commandline()
vim.api.nvim_create_user_command('Sapho', function(cmd) require('sapho').open(cmd) end, { range = true })
vim.api.nvim_create_user_command('SaphoToggle', function() require('sapho').toggle() end, {})
vim.api.nvim_create_user_command('SaphoCancel', function() require('sapho').action('cancel') end, {})
vim.api.nvim_create_user_command('SaphoPause', function() require('sapho').action('pause') end, {})
vim.api.nvim_create_user_command('SaphoLocations', function() require('sapho').action('locations') end, {})
vim.api.nvim_create_user_command('SaphoNew', function() require('sapho').action('new') end, {})
