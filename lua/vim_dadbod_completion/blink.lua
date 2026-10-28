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

-- Defaults; override per key via the blink provider's `opts`:
--   dadbod = { name = "Dadbod", module = "vim_dadbod_completion.blink",
--              opts = { kinds = { C = true, T = true, R = true, F = true } } }
local DEFAULTS = {
	-- Dadbod kinds to show: C column, T table, R reserved word, A alias, S schema, F function
	kinds = { C = true, T = true, R = true },
	-- reserved words to keep (lowercase); set to false to keep all of them
	reserved_allow = {
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
	},
	-- multi-word keyword snippets we want to propose
	snippets = {
		{ label = "ORDER BY", insert = "ORDER BY ", filter = "orderby" },
		{ label = "GROUP BY", insert = "GROUP BY ", filter = "groupby" },
		{ label = "INNER JOIN", insert = "INNER JOIN ", filter = "innerjoin" },
		{ label = "LEFT JOIN", insert = "LEFT JOIN ", filter = "leftjoin" },
		{ label = "RIGHT JOIN", insert = "RIGHT JOIN ", filter = "rightjoin" },
		{ label = "CREATE TABLE", insert = "CREATE TABLE ", filter = "createtable" },
	},
	score_offset = { C = 80, R = 50, T = 20, A = 10, S = 10, F = 30, snippet = 45 },
}

-- omni truncates each category to `limit + 1` items (g:vim_dadbod_completion_source_limits)
local LIMIT_KEY = { C = "columns", T = "tables", S = "schemas", F = "functions", R = "reserved_words" }

function M.new(opts)
	local self = setmetatable({}, { __index = M })
	self.opts = vim.tbl_extend("force", DEFAULTS, opts or {})
	return self
end

function M:get_trigger_characters()
	-- non-alphanumeric triggers; Blink will also query on keyword chars
	return { '"', "`", "[", "]", "." }
end

function M:enabled()
	local filetypes = { "sql", "mysql", "plsql" }
	return vim.tbl_contains(filetypes, vim.bo.filetype)
end

-- ── helpers ──────────────────────────────────────────────────────────────────
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
	-- blink fuzzy should work on the bare identifier (no schema/quotes)
	return strip_quotes(last_segment(word_or_label or ""))
end

local function lower(s)
	return (s or ""):lower()
end

local function source_limit(kind)
	local limits = vim.g.vim_dadbod_completion_source_limits or {}
	return limits[LIMIT_KEY[kind]] or 200
end

-- ── main provider ────────────────────────────────────────────────────────────
function M:get_completions(ctx, callback)
	local opts = self.opts
	local before_cursor = ctx.line:sub(1, ctx.cursor[2])

	-- The identifier being typed. Taking only the trailing [%w_]* (instead of
	-- everything back to the last space) means "coalesce(u", "a,b" or "x=u"
	-- still complete; upstream reset the input to "" there and omni bailed.
	local input = before_cursor:match("[%w_]*$")
	local prev_char = before_cursor:sub(-#input - 1, -#input - 1)
	local after_trigger = vim.tbl_contains(self:get_trigger_characters(), prev_char)

	local ok, results = pcall(vim.api.nvim_call_function, "vim_dadbod_completion#omni", { 0, input })
	if not ok or type(results) ~= "table" then
		results = {}
	end

	-- de-dup by word+kind (first wins, like upstream) and detect truncation
	local uniq, order, per_kind = {}, {}, {}
	for _, it in ipairs(results) do
		local kind = it.kind or ""
		per_kind[kind] = (per_kind[kind] or 0) + 1
		local key = (it.word or "") .. "\31" .. kind
		if not uniq[key] then
			uniq[key] = it
			order[#order + 1] = it
		end
	end
	local truncated = false
	for kind, count in pairs(per_kind) do
		if LIMIT_KEY[kind] and count > source_limit(kind) then
			truncated = true
		end
	end

	---@type lsp.CompletionItem[]
	local items = {}
	for _, it in ipairs(order) do
		local kind = it.kind
		local label = it.abbr or it.word or ""
		local insert = it.word or ""
		local keep = opts.kinds[kind]
		if keep and kind == "R" and opts.reserved_allow then
			keep = opts.reserved_allow[lower(insert ~= "" and insert or label)]
		end
		if keep then
			local fkey = filter_key(insert ~= "" and insert or label)
			items[#items + 1] = {
				label = label,
				insertText = insert,
				filterText = fkey,
				sortText = lower(fkey),
				score_offset = opts.score_offset[kind] or 0,
				labelDetails = it.menu and { description = it.menu } or nil,
				documentation = it.info or "",
				kind = map_kind_to_cmp_lsp_kind[kind] or vim.lsp.protocol.CompletionItemKind.Text,
			}
		end
	end

	-- multi-word keyword snippets; never right after "." or a quote
	if not after_trigger and input ~= "" then
		local kw = lower(input)
		for _, snip in ipairs(opts.snippets) do
			if snip.filter:find(kw, 1, true) then
				items[#items + 1] = {
					label = snip.label,
					insertText = snip.insert,
					filterText = snip.filter,
					sortText = snip.filter,
					score_offset = opts.score_offset.snippet or 0,
					kind = vim.lsp.protocol.CompletionItemKind.Keyword,
				}
			end
		end
	end

	callback({
		context = ctx,
		-- Let blink filter locally while typing, but ask again when omni's list
		-- was cut at the source limit, or came back empty (columns for "alias."
		-- are fetched asynchronously the first time; with `false` the empty
		-- answer would stick until the menu closes).
		is_incomplete_forward = truncated or #items == 0,
		-- omni filters by prefix, so a shorter prefix (backspace) needs a re-query
		is_incomplete_backward = true,
		items = items,
	})
	return function() end
end

return M
