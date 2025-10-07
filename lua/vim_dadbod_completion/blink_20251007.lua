---@type blink.cmp.Source
local M = {}

local map_kind_to_cmp_lsp_kind = {
	F = 3, -- Function -> Function
	C = 5, -- Column   -> Field
	A = 6, -- Alias    -> Variable
	T = 7, -- Table    -> Class
	R = 14, -- Reserved -> Keyword
	S = 19, -- Schema   -> Folder
}

function M.new()
	return setmetatable({}, { __index = M })
end

function M:get_trigger_characters()
	return { '"', "`", "[", "]", "." }
end

function M:enabled()
	local filetypes = { "sql", "mysql", "plsql" }
	return vim.tbl_contains(filetypes, vim.bo.filetype)
end

-- ── helpers to improve fuzzy matching ────────────────────────────────────────
local function strip_quotes(s)
	if not s or s == "" then
		return ""
	end
	local un = s:match('^"(.*)"$') or s:match("^`(.*)`$") or s:match("^%[(.*)%]$")
	return un or s
end

local function last_segment(s)
	if not s or s == "" then
		return ""
	end
	return s:match("([^%.]+)$") or s
end

local function filter_key(word_or_label)
	-- use the bare identifier (no schema or quotes) so blink's fuzzy works
	return strip_quotes(last_segment(word_or_label or ""))
end

-- ── main provider ───────────────────────────────────────────────────────────
function M:get_completions(ctx, callback)
	local cursor_col = ctx.cursor[2]
	local line = ctx.line
	local word_start = cursor_col + 1

	local triggers = self:get_trigger_characters()
	while word_start > 1 do
		local char = line:sub(word_start - 1, word_start - 1)
		if vim.tbl_contains(triggers, char) or char:match("%s") then
			break
		end
		word_start = word_start - 1
	end

	-- Get text from word start to cursor
	local input = line:sub(word_start, cursor_col)

	if input ~= "" and input:match("[^0-9A-Za-z_]+") then
		input = ""
	end

	local transformed_callback = function(items)
		callback({
			context = ctx,
			-- IMPORTANT: mark complete so blink applies local fuzzy filtering
			is_incomplete_forward = false,
			is_incomplete_backward = false,
			items = items,
		})
	end

	local ok, results = pcall(vim.api.nvim_call_function, "vim_dadbod_completion#omni", { 0, input })
	if not ok or not results then
		transformed_callback({})
		return function() end
	end

	local by_word = {}
	for _, item in ipairs(results) do
		local key = (item.word or "") .. (item.kind or "")
		if by_word[key] == nil then
			by_word[key] = item
		end
	end

	local items = {} ---@type table<string,lsp.CompletionItem>
	for _, item in pairs(by_word) do
		local label = item.abbr or item.word or ""
		local insert = item.word or ""
		local fkey = filter_key(insert ~= "" and insert or label)

		table.insert(items, {
			label = label,
			dup = 0,
			insertText = insert,
			filterText = fkey, -- critical for fuzzy
			sortText = string.lower(fkey), -- stable ordering
			labelDetails = item.menu and { description = item.menu } or nil,
			documentation = item.info or "",
			kind = map_kind_to_cmp_lsp_kind[item.kind] or vim.lsp.protocol.CompletionItemKind.Text,
		})
	end

	transformed_callback(items)
	return function() end
end

return M
