local M = {}

local SERVER_NAME = "prlsp"
local DIAGNOSTIC_SOURCE = "github-review"

--- Get PRLSP diagnostics at cursor position.
--- @return vim.Diagnostic | nil
local function get_diagnostic_at_cursor()
	local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1

	for _, diagnostic in ipairs(vim.diagnostic.get(0, { lnum = lnum })) do
		if diagnostic.source == DIAGNOSTIC_SOURCE then
			return diagnostic
		end
	end
end

--- @param bufnr integer
--- @param cmd string
--- @param args any[]?
--- @return nil
local function lsp_exec_command(bufnr, cmd, args)
	args = args or {}

	local client = vim.lsp.get_clients({ bufnr = bufnr, name = SERVER_NAME })[1]
	if not client then
		vim.notify("PRLSP: No LSP client attached")
		return
	end

	client:request("workspace/executeCommand", { command = cmd, arguments = args }, nil, bufnr)
end

--- @alias SplitCallback fun(text: string)

--- @param title string
--- @param callback SplitCallback | nil
--- @return integer bufnr
--- @return integer win
local function show_split_editor(title, callback)
	local bufnr = vim.api.nvim_create_buf(false, true)

	vim.api.nvim_buf_set_name(bufnr, "prlsp://" .. title)
	vim.bo[bufnr].buftype = "acwrite"
	vim.bo[bufnr].filetype = "markdown"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false

	vim.cmd.vsplit()

	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, bufnr)

	---@return nil
	local function finish()
		---@type string[]
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local text = table.concat(lines, "\n")

		if text ~= "" and callback then
			callback(text)
		end
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = bufnr,
		once = true,
		callback = finish,
	})

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = bufnr,
		callback = function()
			vim.bo[bufnr].modified = false
		end,
	})

	return bufnr, win
end

--- @param title string
--- @param content string[]
--- @return integer bufnr
--- @return integer win
local function show_split_viewer(title, content)
	local bufnr = vim.api.nvim_create_buf(false, true)

	vim.api.nvim_buf_set_name(bufnr, "prlsp://" .. title)
	vim.bo[bufnr].filetype = "markdown"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false

	vim.bo[bufnr].modifiable = false

	vim.cmd.vsplit()

	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, bufnr)

	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
	vim.bo[bufnr].modifiable = false

	return bufnr, win
end

--- Show full review thread at current line in markdown side buffer.
--- @return nil
function M.show_thread()
	local diagnostic = get_diagnostic_at_cursor()
	if not diagnostic then
		vim.notify("PRLSP: No threads found on this line")
		return
	end

	local msg = diagnostic.message or ""
	local lines = vim.split(msg, "\n", { plain = true })

	show_split_viewer(vim.fn.expand("%:.") .. "#" .. diagnostic.user_data.lsp.data.thread_id, lines)
end

--- Open markdown popup to reply to a PR review thread on current line.
--- @return nil
function M.reply_on_line()
	local bufnr = vim.api.nvim_get_current_buf()

	local diagnostic = get_diagnostic_at_cursor()
	if not diagnostic then
		vim.notify("PRLSP: No comments found on this line")
		return
	end

	local comment_id = diagnostic.user_data.lsp.data.comment_id

	show_split_editor(vim.fn.expand("%:.") .. "#" .. comment_id, function(input)
		lsp_exec_command(bufnr, "prlsp.reply", { comment_id, vim.uri_from_bufnr(0), input })
	end)
end

--- Open markdown popup to write a new PR comment on current line.
--- @return nil
function M.comment_on_line()
	local bufnr = vim.api.nvim_get_current_buf()

	local pos = vim.api.nvim_win_get_cursor(0)
	local line1 = pos[1] -- 1-indexed for GitHub

	show_split_editor(vim.fn.expand("%:.") .. "#" .. line1, function(input)
		lsp_exec_command(bufnr, "prlsp.createComment", { vim.uri_from_bufnr(bufnr), line1, input })
	end)
end

--- Refresh PR review threads.
--- @return nil
function M.refresh()
	lsp_exec_command(0, "prlsp.refresh")
end

return M
