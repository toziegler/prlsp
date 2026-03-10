vim.api.nvim_create_user_command("PRLSPComment", function(opts)
	require("prlsp").comment({ opts.line1, opts.line2 })
end, {
	desc = "Open a markdown buffer to write a PR comment for the current line or range",
	range = true,
})

vim.api.nvim_create_user_command("PRLSPShowThread", function()
	require("prlsp").show_thread()
end, { desc = "Show full PR review thread at current line in markdown side buffer" })

vim.api.nvim_create_user_command("PRLSPRefresh", function()
	require("prlsp").refresh()
end, { desc = "Refresh PR review threads" })
