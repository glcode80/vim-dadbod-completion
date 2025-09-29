" Only change vs upstream: read ±N lines around the cursor instead of the whole buffer.
" Return shape stays the same: { table -> [aliases...] }.

if !exists('g:vim_dadbod_completion_context_window')
  let g:vim_dadbod_completion_context_window = 100
endif

let s:reserved_words = ['inner', 'outer', 'left', 'right', 'join', 'where', 'on', 'from', 'as']
let s:quotes = vim_dadbod_completion#schemas#get_quotes_rgx()
let s:alias_rgx = printf(
      \ '\(%s\)\?\(\w\+\)\(%s\)\?\(%s\)\@<!\s\+\(as\s\+\)\?\(%s\)\?\(\w\+\)\(%s\)\?',
      \ s:quotes.open,
      \ s:quotes.close,
      \ join(s:reserved_words, '\|'),
      \ s:quotes.open,
      \ s:quotes.close
      \ )

" NEW: windowed read for the *current* buffer; fallback to full read for others
function! s:get_window_lines(bufnr) abort
  if a:bufnr == bufnr()
    let lnum  = line('.')
    let first = max([1, lnum - g:vim_dadbod_completion_context_window])
    let last  = min([line('$'), lnum + g:vim_dadbod_completion_context_window])
    return getline(first, last)
  endif
  " For non-current buffers, keep original behavior (safe fallback)
  return getbufline(a:bufnr, 1, '$')
endfunction

function! vim_dadbod_completion#alias_parser#parse(bufnr, tables) abort
  let result = {}
  let content = s:get_window_lines(a:bufnr)   " <— windowed read (was: getbufline(a:bufnr, 1, '$'))
  if empty(a:tables) || empty(content)
    return result
  endif

  let aliases = []
  for line in content
    " submatch(2) = bare table name (no schema), submatch(7) = alias
    call substitute(line, s:alias_rgx, '\=add(aliases, [submatch(2), submatch(7)])', 'g')
  endfor

  for [tbl, alias] in aliases
    if !empty(alias) && index(a:tables, tbl) > -1 && index(s:reserved_words, tolower(alias)) ==? -1
      if !has_key(result, tbl)
        let result[tbl] = []
      endif
      call add(result[tbl], alias)
    endif
  endfor

  return result
endfunction
