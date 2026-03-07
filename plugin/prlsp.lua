vim.api.nvim_create_user_command("PRLSPCommentOnLine", function()
	require("prlsp").comment_on_line()
end, { desc = "Open markdown buffer to write a new PR comment on current line" })

vim.api.nvim_create_user_command("PRLSPReplyOnLine", function()
	require("prlsp").reply_on_line()
end, { desc = "Open markdown buffer to reply to a PR review thread on current line" })

vim.api.nvim_create_user_command("PRLSPShowThread", function()
	require("prlsp").show_thread()
end, { desc = "Show full review thread at current line in markdown side buffer" })

vim.api.nvim_create_user_command("PRLSPRefresh", function()
	require("prlsp").refresh()
end, { desc = "Refresh PR review threads" })
