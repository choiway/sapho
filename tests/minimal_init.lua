vim.opt.rtp:prepend(".")

local function plenary_dir()
  local env = vim.env.PLENARY_DIR
  if env and env ~= "" then
    return env
  end

  local lazy_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
  if vim.uv.fs_stat(lazy_path) then
    return lazy_path
  end

  local clone_path = vim.fn.getcwd() .. "/.tests/plenary"
  if not vim.uv.fs_stat(clone_path) then
    vim.fn.system({
      "git",
      "clone",
      "--depth=1",
      "https://github.com/nvim-lua/plenary.nvim",
      clone_path,
    })
  end
  return clone_path
end

vim.opt.rtp:prepend(plenary_dir())
vim.cmd("runtime plugin/plenary.vim")

vim.o.swapfile = false
