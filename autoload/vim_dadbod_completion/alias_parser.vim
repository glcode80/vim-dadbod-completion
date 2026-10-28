" Table alias parser, scoped to the SQL statement under the cursor.
"
" Returns { table_name: [alias, ...] } (same shape as upstream), where
" table_name is spelled exactly as in a:tables so the column cache lookups
" in vim_dadbod_completion#omni keep working.
"
" Differences from upstream, which ran a regex over every line of the buffer
" on every completion request:
"   * Only the statement around the cursor is parsed. Lines are walked up and
"     down from the cursor until a ';' (or a blank line, if
"     g:vim_dadbod_completion_blank_line_delimiter is set), at most
"     g:vim_dadbod_completion_context_window lines in each direction.
"   * Table references are anchored on FROM / JOIN / UPDATE / INTO / USING / ','
"     instead of matching every "word word" pair, so an uppercase keyword can't
"     swallow the table name (upstream missed "FROM users u" unless
"     'ignorecase' was set), and tables whose name ends in a keyword
"     ("transaction" ends in "on", "canvas" in "as") are no longer skipped.
"   * Matching is case-insensitive regardless of 'ignorecase'; table names are
"     looked up exact-first, then case-insensitively.
"   * References may span lines ("FROM\n  users u"), be schema-qualified
"     ("public.users u", "db.dbo.users u") or quoted ("`order` o").
"   * If one alias is used for different tables, the reference nearest to
"     the cursor wins, so "u." can't resolve to a table from another query.

" Words that can follow a table reference but are never its alias.
let s:stop_words = [
      \ 'where', 'on', 'using', 'join', 'inner', 'left', 'right', 'full', 'outer',
      \ 'cross', 'natural', 'straight_join', 'lateral', 'group', 'order', 'limit',
      \ 'offset', 'fetch', 'having', 'union', 'intersect', 'except', 'minus',
      \ 'window', 'set', 'values', 'value', 'returning', 'for', 'as', 'select',
      \ 'with', 'into', 'from', 'when', 'then', 'else', 'end', 'and', 'or', 'not',
      \ 'partition', 'qualify', 'pivot', 'unpivot', 'tablesample', 'asc', 'desc',
      \ 'nulls', 'use', 'force', 'ignore', 'lock', 'connect', 'start', 'default',
      \ 'apply', 'final', 'sample', 'prewhere', 'array', 'global', 'any', 'all',
      \ ]
let s:stop_dict = {}
for s:w in s:stop_words
  let s:stop_dict[s:w] = 1
endfor
unlet s:w

" One identifier: "quoted", `quoted`, [quoted] or bare (letters incl. non-ASCII, digits, _ $ # @).
let s:ident = '\%("[^"]*"\|`[^`]*`\|\[[^\]]*\]\|\%(\w\|[$#@]\|[^\x00-\x7f]\)\+\)'
let s:stop_rgx = '\<\%(' . join(s:stop_words, '\|') . '\)\>'

" \1 = schema/database prefix, \2 = table, \3 = alias. The alias is required:
" references without one need no entry, and skipping them inside the regex
" engine (e.g. every "a.x, b.y" in a SELECT list) is much cheaper than in script.
let s:ref_rgx = '\c'
      \ . '\%(\<\%(from\|join\|straight_join\|update\|into\|using\)\s\+\|,\s*\)'
      \ . '\%(only\s\+\)\?'
      \ . '\(\%(' . s:ident . '\.\)\{,2}\)'
      \ . '\(' . s:ident . '\)'
      \ . '\s\+\%(as\s\+\)\?\%(' . s:stop_rgx . '\)\@!\(' . s:ident . '\)'

function! s:unquote(name) abort
  return a:name =~# '^["`[]' ? a:name[1:-2] : a:name
endfunction

function! s:strip_comment(line) abort
  let idx = stridx(a:line, '--')
  return idx < 0 ? a:line : strpart(a:line, 0, idx)
endfunction

" Returns [text, cursor_offset]: the statement under the cursor joined into a
" single line, and the byte offset of the cursor inside it.
function! s:statement_text(bufnr) abort
  if a:bufnr != bufnr('%')
    return [join(getbufline(a:bufnr, 1, '$'), ' '), 0]
  endif

  let cap = get(g:, 'vim_dadbod_completion_context_window', 100)
  let blank_delim = get(g:, 'vim_dadbod_completion_blank_line_delimiter', 0)
  let lnum = line('.')
  let first = max([1, lnum - cap])
  let lines = getline(first, min([line('$'), lnum + cap]))
  let cur = lnum - first

  " Cursor line: split at the cursor, cut at the nearest ';' on either side.
  let line = s:strip_comment(lines[cur])
  let before = strpart(line, 0, col('.') - 1)
  let after = strpart(line, col('.') - 1)
  let semi = strridx(before, ';')
  let done_up = semi > -1
  if done_up
    let before = strpart(before, semi + 1)
  endif
  let semi = stridx(after, ';')
  let done_down = semi > -1
  if done_down
    let after = strpart(after, 0, semi)
  endif

  " Walk outwards. (Comment stripping is inlined: a function call per line
  " costs more than the rest of the loop body.)
  let up = []
  let i = cur - 1
  while !done_up && i >= 0
    let l = lines[i]
    let c = stridx(l, '--')
    if c > -1
      let l = strpart(l, 0, c)
    endif
    if blank_delim && l =~# '^\s*$'
      break
    endif
    let semi = strridx(l, ';')
    if semi > -1
      call add(up, strpart(l, semi + 1))
      break
    endif
    call add(up, l)
    let i -= 1
  endwhile

  let down = []
  let i = cur + 1
  let n = len(lines)
  while !done_down && i < n
    let l = lines[i]
    let c = stridx(l, '--')
    if c > -1
      let l = strpart(l, 0, c)
    endif
    if blank_delim && l =~# '^\s*$'
      break
    endif
    let semi = stridx(l, ';')
    if semi > -1
      call add(down, strpart(l, 0, semi))
      break
    endif
    call add(down, l)
    let i += 1
  endwhile

  let head = join(reverse(up) + [before], ' ')
  return [head . after . ' ' . join(down, ' '), len(head)]
endfunction

function! vim_dadbod_completion#alias_parser#parse(bufnr, tables) abort
  let result = {}
  if empty(a:tables)
    return result
  endif

  let [text, cursor] = s:statement_text(a:bufnr)

  " One substitute() pass collects [table, alias] for every reference and
  " replaces the first byte of each match with \x01, so match offsets can be
  " recovered with stridx() (calling matchstrpos() per match recompiles the
  " pattern every time and is ~5x slower).
  let refs = []
  let marked = substitute(text, s:ref_rgx,
        \ '\=len(add(refs, [submatch(2), submatch(3)])) ? "\x01" . submatch(0)[1:] : ""', 'g')
  let pos = -1
  for ref in refs
    let pos = stridx(marked, "\x01", pos + 1)
    call insert(ref, abs(pos - cursor))
  endfor

  " Nearest reference first; an alias belongs to the first table that claims it.
  call sort(refs, {a, b -> a[0] - b[0]})
  let claimed = {}
  for [_, tbl, alias] in refs
    let tbl = s:unquote(tbl)
    let alias = s:unquote(alias)
    let key = tolower(alias)
    if empty(alias) || has_key(s:stop_dict, key)
      continue
    endif
    let idx = index(a:tables, tbl)
    if idx < 0
      let idx = index(a:tables, tbl, 0, 1)
    endif
    if idx < 0
      continue
    endif
    let tbl = a:tables[idx]
    if has_key(claimed, key)
      continue
    endif
    let claimed[key] = tbl
    if !has_key(result, tbl)
      let result[tbl] = []
    endif
    call add(result[tbl], alias)
  endfor

  return result
endfunction
