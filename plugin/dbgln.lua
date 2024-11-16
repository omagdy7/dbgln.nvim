if vim.fn.has("nvim-0.7") == 0 then
	vim.api.nvim_err_writeln("dbgln requires at least Neovim 0.7")
	return
end

-- Make sure plugin is loaded only once
if vim.g.loaded_dbgln == 1 then
	return
end
vim.g.loaded_dbgln = 1
