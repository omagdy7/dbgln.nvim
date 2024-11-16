print("Loaded successfully")

local M = {}

local function printTable(t, indent)
	for k, v in pairs(t) do
		if type(v) == "table" then
			print(string.rep("  ", indent) .. tostring(k) .. ":")
			printTable(v, indent + 1)
		else
			print(string.rep("  ", indent) .. tostring(k) .. " = " .. tostring(v))
		end
	end
end

-- Store the parser queries for different languages
M.queries = {
	rust = [[
    ;; Match identifiers under let_identifier
    (let_declaration (identifier) @let_identifier_child)

    ;; Match identifiers under binary_expression
    (binary_expression (identifier) @binary_expression_child)

    ;; match simple call_expressions
    ((call_expression (_) (_)) @calls)
  ]],
}

function M.setup(opts)
	opts = opts or {}

	vim.api.nvim_create_user_command("DbgLn", function()
		M.insert_debug_print()
	end, {})

	if opts.mapping then
		vim.keymap.set("v", opts.mapping, ":DbgLn<CR>", { silent = true })
	end
end

-- Store selection state
M.current_selections = {
	identifiers = {}, -- List of identifiers
	ranges = {}, -- List of ranges for each identifier
	selected = {}, -- Set of selected indices
	extmarks = {}, -- List of extmark ids
	ns_id = nil, -- Namespace ID for highlights
	original_line = nil, -- Original line number
}

function M.setup_selection_mode()
	-- Create highlight namespace if it doesn't exist
	if not M.current_selections.ns_id then
		M.current_selections.ns_id = vim.api.nvim_create_namespace("debug_print_selection")
	end
end

function M.clear_selection_mode()
	-- Clear all extmarks
	local bufnr = vim.api.nvim_get_current_buf()
	for _, id in ipairs(M.current_selections.extmarks) do
		vim.api.nvim_buf_del_extmark(bufnr, M.current_selections.ns_id, id)
	end

	-- Clear stored state
	M.current_selections.identifiers = {}
	M.current_selections.ranges = {}
	M.current_selections.selected = {}
	M.current_selections.extmarks = {}
	M.current_selections.original_line = nil

	-- Remove keymaps
	for i = 1, 9 do
		vim.keymap.del("n", tostring(i))
	end
	vim.keymap.del("n", "<CR>")
	vim.keymap.del("n", "<Esc>")
end

function M.toggle_selection(index)
	local bufnr = vim.api.nvim_get_current_buf()

	-- Toggle selection state
	M.current_selections.selected[index] = not M.current_selections.selected[index]

	-- Update highlight
	local range = M.current_selections.ranges[index]
	local row = M.current_selections.original_line - 1

	-- Delete existing extmark
	vim.api.nvim_buf_del_extmark(bufnr, M.current_selections.ns_id, M.current_selections.extmarks[index])

	-- Create new extmark with updated style
	local hl_group = M.current_selections.selected[index] and "Search" or "CursorLine"
	local virt_text = { { tostring(index), "Number" } }
	local id = vim.api.nvim_buf_set_extmark(bufnr, M.current_selections.ns_id, row, range.start_col, {
		end_col = range.end_col,
		hl_group = hl_group,
		virt_text = virt_text,
		virt_text_pos = "overlay", -- Changed from 'overlay' to 'right_align'
		virt_text_win_col = range.start_col - 1, -- Position it just after the identifier
		priority = 100,
	})
	M.current_selections.extmarks[index] = id
end
function M.confirm_selection()
	-- Gather selected identifiers
	local selected_identifiers = {}
	for i, id in ipairs(M.current_selections.identifiers) do
		if M.current_selections.selected[i] then
			table.insert(selected_identifiers, id)
		end
	end

	-- Generate and insert debug print
	if #selected_identifiers > 0 then
		local debug_line = M.generate_debug_print("rust", selected_identifiers)
		if debug_line then
			local bufnr = vim.api.nvim_get_current_buf()
			local row = M.current_selections.original_line - 1

			-- Get indentation
			local current_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
			local indentation = current_line:match("^%s*") or ""
			debug_line = indentation .. debug_line

			-- Insert debug line
			vim.api.nvim_buf_set_lines(bufnr, row + 1, row + 1, false, { debug_line })
		end
	end

	-- Clean up
	M.clear_selection_mode()
end

function M.start_selection_mode(identifiers, ranges)
	M.setup_selection_mode()

	-- Store current line
	M.current_selections.original_line = vim.fn.line(".")
	M.current_selections.identifiers = identifiers
	M.current_selections.ranges = ranges

	-- Set up highlights and virtual text
	local bufnr = vim.api.nvim_get_current_buf()
	local row = M.current_selections.original_line - 1

	for i, range in ipairs(ranges) do
		-- Create initial highlight
		local virt_text = { { tostring(i), "Number" } }
		local id = vim.api.nvim_buf_set_extmark(bufnr, M.current_selections.ns_id, row, range.start_col, {
			end_col = range.end_col,
			hl_group = "CursorLine",
			virt_text = virt_text,
			virt_text_pos = "overlay", -- Changed from 'overlay' to 'right_align'
			virt_text_win_col = range.start_col - 1, -- Position it just after the identifier
			priority = 100,
		})
		table.insert(M.current_selections.extmarks, id)
		M.current_selections.selected[i] = false
	end

	-- Set up keymaps
	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			M.toggle_selection(i)
		end, { silent = true })
	end

	vim.keymap.set("n", "<CR>", M.confirm_selection, { silent = true })
	vim.keymap.set("n", "<Esc>", M.clear_selection_mode, { silent = true })

	-- Show help message
	-- vim.api.nvim_echo({
	-- 	{ "Debug Print Selection Mode\n", "Title" },
	-- 	{ "Press 1-9 to toggle items, Enter to confirm, Esc to cancel", "Comment" },
	-- }, false, {})
end

function M.extract_debug_info(text, lang)
	local parser = vim.treesitter.get_string_parser(text, lang)
	local tree = parser:parse()[1]
	local root = tree:root()

	local query = vim.treesitter.query.parse(lang, M.queries[lang])
	local identifiers = {}
	local ranges = {}
	local seen_ranges = {}

	for _, match, metadata in query:iter_matches(root, text) do
		for id, node in pairs(match) do
			local capture_name = query.captures[id]
			local node_text = vim.treesitter.get_node_text(node, text)

			-- Get node range
			local start_row, start_col, end_row, end_col = node:range()
			local range_key = table.concat({ start_row, start_col, end_row, end_col }, ",")

			if not seen_ranges[range_key] then
				seen_ranges[range_key] = true
				table.insert(identifiers, node_text)
				table.insert(ranges, {
					start_col = start_col,
					end_col = end_col,
				})
			end
		end
	end

	return identifiers, ranges
end

function M.insert_debug_print()
	local selection = M.get_current_line()
	local lang = vim.bo.filetype

	if lang ~= "rust" then
		vim.notify("Language not supported yet", vim.log.levels.WARN)
		return
	end

	local identifiers, ranges = M.extract_debug_info(selection.text, lang)
	if #identifiers > 0 then
		M.start_selection_mode(identifiers, ranges)
	else
		vim.notify("No identifiers found", vim.log.levels.INFO)
	end
end

function M.get_current_line()
	local current_line = vim.api.nvim_get_current_line()
	local row = vim.fn.line(".") - 1 -- Get the current row (0-indexed)
	return {
		text = current_line,
		start_row = row,
		end_row = row,
		start_col = 0,
		end_col = #current_line,
	}
end

function M.get_visual_selection()
	local _, start_row, start_col, _ = unpack(vim.fn.getpos("'<"))
	local _, end_row, end_col, _ = unpack(vim.fn.getpos("'>"))

	local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
	if #lines == 0 then
		return nil
	end

	return {
		text = table.concat(lines, "\n"),
		start_row = start_row - 1,
		end_row = end_row - 1,
		start_col = start_col - 1,
		end_col = end_col,
	}
end

-- Helper function to remove duplicates while preserving order
function M.remove_duplicates(tbl)
	local seen = {}
	local result = {}

	for _, item in ipairs(tbl) do
		if not seen[item] then
			seen[item] = true
			table.insert(result, item)
		end
	end

	return result
end

-- Helper function to check if a string is a valid identifier
function M.is_valid_identifier(str)
	-- Basic check for valid identifier (can be expanded)
	return str:match("^[%a_][%w_]*$")
end

function M.generate_debug_print(lang, identifiers)
	if lang == "rust" then
		if #identifiers > 0 then
			-- Create debug format strings
			local format_parts = {}
			for _, id in ipairs(identifiers) do
				table.insert(format_parts, string.format("%s: {:?}", id))
			end

			-- Generate the println! statement
			return string.format(
				'println!("%s", %s);',
				table.concat(format_parts, ", "),
				table.concat(identifiers, ", ")
			)
		end
	end

	return nil
end

return M
