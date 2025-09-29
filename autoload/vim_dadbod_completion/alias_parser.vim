" autoload/vim_dadbod_completion/alias_parser.vim
" Scoped alias parser for vim-dadbod-completion
" Adds two opts:
"   g:vim_dadbod_completion_scope_statement (0|1)
"   g:vim_dadbod_completion_context_window  (integer, default 100)

if !exists('g:vim_dadbod_completion_scope_statement')
  let g:vim_dadbod_completion_scope_statement = 0
endif
if !exists('g:vim_dadbod_completion_context_window')
  let g:vim_dadbod_completion_context_window = 100
endif

" Return { table_name: ['alias1','alias2', ...], ... }
function! vim_dadbod_completion#alias_parser#parse(bufnr, tables_list) abort
  let l:lines = s:GetScopedLines()
  if empty(l:lines)
    return {}
  endif
  let l:text = join(l:lines, "\n")

  " Very simple alias extraction:
  "  - FROM <schema?.>table [AS] alias
  "  - JOIN <schema?.>table [AS] alias
  "  - FROM/JOIN (<subquery>) alias       -> captures alias for subqueries
  " Notes:
  "  - We only map aliases for real tables that appear in a:tables_list.
  "  - Case-insensitive; quotes are ignored here (core code handles quoting).
  let l:aliases = {}

  " 1) FROM/JOIN table aliases
  let l:tbl_pat = '\C\<\(FROM\|JOIN\)\s\+\%(\%(\w\+\.\)\?\(\w\+\)\)\s\+\%(\<AS\>\s\+\)\?\(\w\+\)'
  let l:m = matchlist(l:text, l:tbl_pat)
  let l:start = 0
  while 1
    let l:idx = match(l:text, l:tbl_pat, l:start)
    if l:idx < 0 | break | endif
    let l:ml = matchlist(l:text, l:tbl_pat, l:idx)
    " ml[2] = table (schema stripped by \%(\w\+\.\)\? )
    " ml[3] = alias
    if len(l:ml) >= 4
      let l:table = tolower(l:ml[2])
      let l:alias = l:ml[3]
      if index(a:tables_list, l:table) > -1
        if !has_key(l:aliases, l:table) | let l:aliases[l:table] = [] | endif
        if index(l:aliases[l:table], l:alias) < 0
          call add(l:aliases[l:table], l:alias)
        endif
      endif
    endif
    let l:start = l:idx + 1
  endwhile

  " 2) FROM/JOIN (subquery) alias — we record alias under special key '__subquery__'
  let l:sub_pat = '\C\<\(FROM\|JOIN\)\s*(\_.\{-})\s\+\%(\<AS\>\s\+\)\?\(\w\+\)'
  let l:start = 0
  while 1
    let l:idx = match(l:text, l:sub_pat, l:start)
    if l:idx < 0 | break | endif
    let l:ml = matchlist(l:text, l:sub_pat, l:idx)
    if len(l:ml) >= 3
      let l:alias = l:ml[2]
      if !has_key(l:aliases, '__subquery__') | let l:aliases['__subquery__'] = [] | endif
      if index(l:aliases['__subquery__'], l:alias) < 0
        call add(l:aliases['__subquery__'], l:alias)
      endif
    endif
    let l:start = l:idx + 1
  endwhile

  return l:aliases
endfunction

" ---------------- internal helpers ----------------

function! s:GetScopedLines() abort
  if g:vim_dadbod_completion_scope_statement
    return s:GetStatementLines()
  endif
  return s:GetWindowLines()
endfunction

" ±N lines around the cursor (bounded to buffer)
function! s:GetWindowLines() abort
  let lnum  = line('.')
  let first = max([1, lnum - g:vim_dadbod_completion_context_window])
  let last  = min([line('$'), lnum + g:vim_dadbod_completion_context_window])
  return getline(first, last)
endfunction

" Only the current ;-delimited statement (no wrap). If no semicolons,
" use the entire buffer as a fallback.
function! s:GetStatementLines() abort
  let save_pos = getpos('.')
  let save_pat = @/

  let prev = searchpos(';', 'bnW')
  let next = searchpos(';', 'nW')

  let first = prev[0] > 0 ? prev[0] : 1
  let last  = next[0] > 0 ? next[0] : line('$')

  call setpos('.', save_pos)
  let @/ = save_pat

  return getline(first, last)
endfunction
