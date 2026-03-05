dofile("/tmp/prlsp/test/init.lua")

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function()
    vim.defer_fn(function()
      local f = io.open("/tmp/prlsp_action_result.txt", "w")
      local client = vim.lsp.get_clients({ name = "prlsp" })[1]
      local uri = vim.uri_from_bufnr(0)

      -- Build proper LSP diagnostics using user_data.lsp for the data field
      local function make_lsp_diags(lnum_filter)
        local result = {}
        for _, d in ipairs(vim.diagnostic.get(0)) do
          if lnum_filter == nil or d.lnum == lnum_filter then
            local data = d.user_data and d.user_data.lsp or nil
            table.insert(result, {
              range = {
                start = { line = d.lnum, character = d.col },
                ["end"] = { line = d.end_lnum, character = d.end_col },
              },
              message = d.message,
              severity = d.severity,
              source = d.source,
              data = data,
            })
          end
        end
        return result
      end

      -- Test 1: Select text on diagnostic line → resolve + reply
      f:write("=== Select on diagnostic line 0 ===\n")
      local r1 = client:request_sync("textDocument/codeAction", {
        textDocument = { uri = uri },
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 6 },
        },
        context = { diagnostics = make_lsp_diags(0) },
      }, 5000, 0)
      if r1 and r1.result then
        for _, a in ipairs(r1.result) do f:write("  " .. a.title .. "\n") end
      end

      -- Test 2: Select text on non-diagnostic line → reply only
      f:write("\n=== Select on non-diagnostic line 3 ===\n")
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
      end

      -- Test 3: No selection on diagnostic line → resolve only
      f:write("\n=== No selection on diagnostic line 0 ===\n")
      local r3 = client:request_sync("textDocument/codeAction", {
        textDocument = { uri = uri },
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 0 },
        },
        context = { diagnostics = make_lsp_diags(0) },
      }, 5000, 0)
      if r3 and r3.result then
        for _, a in ipairs(r3.result) do f:write("  " .. a.title .. "\n") end
      end

      f:close()
      vim.cmd("qa!")
    end, 3000)
  end,
})

vim.defer_fn(function()
  io.open("/tmp/prlsp_action_result.txt", "w"):write("TIMEOUT\n"):close()
  vim.cmd("qa!")
end, 15000)
