-- Test script for code action UX
-- Usage: nvim --clean --headless -u test/test_actions.lua <file>
dofile("/tmp/prlsp/test/init.lua")

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function()
    vim.defer_fn(function()
      local f = io.open("/tmp/prlsp_action_result.txt", "w")
      local client = vim.lsp.get_clients({ name = "prlsp" })[1]
      local uri = vim.uri_from_bufnr(0)

      -- Build LSP-format diagnostics from vim.diagnostic
      local lsp_diags = {}
      for _, d in ipairs(vim.diagnostic.get(0)) do
        table.insert(lsp_diags, {
          range = {
            start = { line = d.lnum, character = d.col },
            ["end"] = { line = d.end_lnum, character = d.end_col },
          },
          message = d.message,
          severity = d.severity,
          source = d.source,
          data = d.user_data,
        })
      end
      f:write("diagnostics: " .. #lsp_diags .. "\n")

      -- Test 1: Select "Test 1" on line 0 (diagnostic line 1 = index 0)
      f:write("\n=== Select line 0 text (diagnostic line) ===\n")
      local r1 = client:request_sync("textDocument/codeAction", {
        textDocument = { uri = uri },
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 6 },
        },
        context = {
          diagnostics = vim.tbl_filter(function(d) return d.range.start.line == 0 end, lsp_diags),
        },
      }, 5000, 0)
      if r1 and r1.result then
        for _, a in ipairs(r1.result) do f:write("  " .. a.title .. "\n") end
      else
        f:write("  (none)\n")
      end

      -- Test 2: Select "Test 2" on line 3 (no diagnostic here)
      f:write("\n=== Select line 3 text (no diagnostic) ===\n")
      local r2 = client:request_sync("textDocument/codeAction", {
        textDocument = { uri = uri },
        range = {
          start = { line = 3, character = 0 },
          ["end"] = { line = 3, character = 6 },
        },
        context = { diagnostics = {} },
      }, 5000, 0)
      if r2 and r2.result then
        for _, a in ipairs(r2.result) do f:write("  " .. a.title .. "\n") end
      else
        f:write("  (none)\n")
      end

      -- Test 3: No selection, cursor on diagnostic line 0
      f:write("\n=== No selection, diagnostic line 0 ===\n")
      local r3 = client:request_sync("textDocument/codeAction", {
        textDocument = { uri = uri },
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 0 },
        },
        context = {
          diagnostics = vim.tbl_filter(function(d) return d.range.start.line == 0 end, lsp_diags),
        },
      }, 5000, 0)
      if r3 and r3.result then
        for _, a in ipairs(r3.result) do f:write("  " .. a.title .. "\n") end
      else
        f:write("  (none)\n")
      end

      f:close()
      vim.cmd("qa!")
    end, 3000)
  end,
})

vim.defer_fn(function()
  io.open("/tmp/prlsp_action_result.txt", "w"):write("TIMEOUT\n"):close()
  vim.cmd("qa!")
end, 20000)
