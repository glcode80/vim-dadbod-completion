---@type blink.cmp.Source
local M = {}

-- Map Dadbod kinds to LSP kinds
local map_kind_to_cmp_lsp_kind = {
	F = 3, -- Function -> Function
	C = 5, -- Column   -> Field
	A = 6, -- Alias    -> Variable
	T = 7, -- Table    -> Class
	R = 14, -- Reserved -> Keyword
	S = 19, -- Schema   -> Folder
}

-- strict reserved whitelist (single-word)
local RESERVED_ALLOW = {
	select = true,
	with = true,
	from = true,
	["order"] = true, -- we also add ORDER BY as multi-word below
	["group"] = true, -- we also add GROUP BY as multi-word below
	["join"] = true, -- plus INNER/LEFT/RIGHT JOIN snippets
	["inner"] = true,
	["left"] = true,
	["right"] = true,
	["create"] = true, -- plus CREATE TABLE snippet
	["table"] = true,
	["drop"] = true,
}

-- multi-word keyword snippets we want to propose
local MULTIWORD_SNIPPETS = {
	{ label = "ORDER BY", insert = "ORDER BY ", filter = "orderby" },
	{ label = "GROUP BY", insert = "GROUP BY ", filter = "groupby" },
	{ label = "INNER JOIN", insert = "INNER JOIN ", filter = "innerjoin" },
	{ label = "LEFT JOIN", insert = "LEFT JOIN ", filter = "leftjoin" },
	{ label = "RIGHT JOIN", insert = "RIGHT JOIN ", filter = "rightjoin" },
	{ label = "CREATE TABLE", insert = "CREATE TABLE ", filter = "createtable" },
}

function M.new()
	return setmetatable({}, { __index = M })
end

function M:get_trigger_characters()
	-- non-alphanumeric triggers; Blink will also query on keyword chars
	return { '"', "`", "[", "]", "." }
end

function M:enabled()
	local filetypes = { "sql", "mysql", "plsql" }
	return vim.tbl_contains(filetypes, vim.bo.filetype)
end

-- ── fuzzy helpers ────────────────────────────────────────────────────────────
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
	-- blink fuzzy should work on the bare identifier (no schema/alias/quotes)
	return strip_quotes(last_segment(word_or_label or ""))
end

local function lower(s)
	return (s or ""):lower()
end

local function is_after_dot(ctx, word_start)
	-- true if the character immediately before the current keyword is '.'
	if word_start <= 1 then
		return false
	end
	local prev = ctx.line:sub(word_start - 1, word_start - 1)
	return prev == "."
end

-- ── main provider ────────────────────────────────────────────────────────────
function M:get_completions(ctx, callback)
	local cursor_col = ctx.cursor[2]
	local line = ctx.line

	-- find start of the current "word"
	local word_start = cursor_col + 1
	local triggers = self:get_trigger_characters()
	while word_start > 1 do
		local ch = line:sub(word_start - 1, word_start - 1)
		if vim.tbl_contains(triggers, ch) or ch:match("%s") then
			break
		end
		word_start = word_start - 1
	end

	local input = line:sub(word_start, cursor_col)
	if input ~= "" and input:match("[^0-9A-Za-z_]+") then
		-- if it contains strange symbols (not quotes/dot), reset so omni doesn't bail
		input = ""
	end

	local after_dot = is_after_dot(ctx, word_start)

	local function done(items)
		callback({
			context = ctx,
			-- let Blink do local fuzzy without re-asking us for each keystroke
			is_incomplete_forward = false,
			is_incomplete_backward = false,
			items = items,
		})
	end

	-- call Dadbod omnifunc
	local ok, results = pcall(vim.api.nvim_call_function, "vim_dadbod_completion#omni", { 0, input })
	if not ok or not results then
		done({})
		return function() end
	end

	-- de-dup by "word+kind" coming from omni
	local uniq = {}
	for _, it in ipairs(results) do
		local w = it.word or ""
		local k = it.kind or ""
		uniq[w .. "\x1f" .. k] = it
	end

	---@type lsp.CompletionItem[]
	local items = {}
	local have_column = false

	-- pass 1: transform + filter (!) to keep only Columns / Tables / Whitelisted Reserved
	for _, it in pairs(uniq) do
		local kind = it.kind
		local label = it.abbr or it.word or ""
		local insert = it.word or ""

		-- filter out noisy reserved words (DATA, DATABASES, etc.)
		if kind == "R" then
			local lw = lower(insert ~= "" and insert or label)
			if not RESERVED_ALLOW[lw] then
				goto continue
			end
		elseif kind ~= "C" and kind ~= "T" then
			-- drop everything except Columns/Tables/whitelisted Reserved
			goto continue
		end

		local fkey = filter_key(insert ~= "" and insert or label)
		local sort = lower(fkey)

		local score_offset = 0
		if kind == "C" then
			score_offset = 80
			have_column = true
		elseif kind == "R" then
			score_offset = 50
		elseif kind == "T" then
			score_offset = 20
		end

		table.insert(items, {
			label = label,
			dup = 0,
			insertText = insert,
			filterText = fkey,
			sortText = sort,
			score_offset = score_offset,
			labelDetails = it.menu and { description = it.menu } or nil,
			documentation = it.info or "",
			kind = map_kind_to_cmp_lsp_kind[kind] or vim.lsp.protocol.CompletionItemKind.Text,
		})

		::continue::
	end

	-- pass 2: add smart multi-word keyword snippets (ranked just below columns)
	do
		local kw = lower(input)
		for _, snip in ipairs(MULTIWORD_SNIPPETS) do
			-- show them if there's no keyword yet, or the user started typing any part
			if kw == "" or snip.filter:find(kw, 1, true) then
				table.insert(items, {
					label = snip.label,
					dup = 0,
					insertText = snip.insert,
					filterText = snip.filter,
					sortText = snip.filter,
					score_offset = 45, -- below columns, roughly with single-word reserved
					kind = vim.lsp.protocol.CompletionItemKind.Keyword,
				})
			end
		end
	end

	-- pass 3: when not after a dot, also surface alias-less mirrors of column items
	-- e.g. DB returns "t.id" -> we additionally show "id" to make fields discoverable earlier.
	if not after_dot then
		local seen = {}
		for _, it in ipairs(items) do
			if it.kind == vim.lsp.protocol.CompletionItemKind.Field then
				local lbl = it.label or ""
				local ins = it.insertText or lbl
				local has_dot = lbl:find("%.") or ins:find("%.")
				if has_dot then
					local bare = filter_key(ins ~= "" and ins or lbl)
					-- avoid dup if a bare field already exists
					local key = "bare\31" .. bare
					if bare ~= "" and not seen[key] then
						seen[key] = true
						table.insert(items, {
							label = bare,
							dup = 0,
							insertText = bare,
							filterText = bare,
							sortText = lower(bare),
							score_offset = 78, -- just under the full column entries
							labelDetails = { description = "column" },
							kind = vim.lsp.protocol.CompletionItemKind.Field,
						})
					end
				end
			end
		end
	end

	done(items)
	return function() end
end

return M
