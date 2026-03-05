-- Minimal Neovim config for testing prlsp
-- Usage: nvim --clean -u test/init.lua

-- Build LSP command with optional mock flag
local cmd = { "python3", "-m", "prlsp" }
local mock_path = vim.env.PRLSP_MOCK
if mock_path then
  table.insert(cmd, "--mock")
  table.insert(cmd, mock_path)
end

-- Attach to all filetypes via vim.lsp.start (reuse-aware)
vim.api.nvim_create_autocmd("FileType", {
  callback = function(args)
    local root = vim.fs.root(args.buf, { ".git" })
    if not root then return end
    vim.lsp.start({
      name = "prlsp",
      cmd = cmd,
      root_dir = root,
    })
  end,
})

-- Diagnostic navigation
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Previous diagnostic" })
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Next diagnostic" })
vim.keymap.set("n", "<space>e", vim.diagnostic.open_float, { desc = "Show diagnostic" })

-- Code actions (normal + visual)
vim.keymap.set({ "n", "v" }, "gra", vim.lsp.buf.code_action, { desc = "Code action" })

-- Refresh command
vim.api.nvim_create_user_command("PrlspRefresh", function()
  for _, client in ipairs(vim.lsp.get_clients({ name = "prlsp" })) do
    client:exec_cmd({
      command = "prlsp.refresh",
      title = "Refresh",
    })
  end
end, { desc = "Refresh PR review threads" })
