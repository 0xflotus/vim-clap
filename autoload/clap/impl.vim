" Author: liuchengxu <xuliuchengxlc@gmail.com>
" Description: Default implementation for various hooks.

let s:save_cpo = &cpoptions
set cpoptions&vim

let s:is_nvim = has('nvim')
let s:async_threshold = 10000

" =======================================
" sync implementation
" =======================================
function! s:reset_on_empty_input() abort
  call g:clap.display.set_lines_lazy(g:clap.provider.get_source())
  let l:matches_cnt = g:clap.display.line_count() + len(g:clap.display.cache)
  call clap#indicator#set_matches('['.l:matches_cnt.']')
  call clap#sign#toggle_cursorline()
  call g:clap#display_win.compact_if_undersize()
endfunction

" FIXME: some sources could be cached.
function! s:get_source() abort
  if get(g:, '__clap_should_refilter', v:false)
        \ || get(g:, '__clap_do_not_use_cache', v:false)
    let l:lines = g:clap.provider.get_source()
    let g:__clap_should_refilter = v:false
    let g:__clap_do_not_use_cache = v:false
  else
    " Assuming in the middle of typing, we are continuing to filter.
    let l:lines = g:clap.display.get_lines() + g:clap.display.cache

    " If there is no matches for the current filtered result, restore to the original source.
    if l:lines == [g:clap_no_matches_msg]
      let l:lines = g:clap.provider.get_source()
    endif
  endif
  return l:lines
endfunction

" NOTE: some local variable without explicit l:, e.g., count,
" may run into some erratic read-only error.
function! clap#impl#refresh_matches_count(cnt_str) abort
  let l:matches_cnt = a:cnt_str

  if get(g:clap.display, 'initial_size', -1) > 0
    let l:matches_cnt .= '/'.g:clap.display.initial_size
  endif

  call clap#indicator#set_matches('['.l:matches_cnt.']')
  call clap#sign#reset_to_first_line()
endfunction

function! s:on_typed_sync_impl() abort
  call g:clap.display.clear_highlight()

  let l:cur_input = g:clap.input.get()

  if empty(l:cur_input)
    call s:reset_on_empty_input()
    return
  endif

  call clap#spinner#set_busy()

  let l:has_no_matches = v:false

  let l:raw_lines = s:get_source()
  let l:lines = call(g:clap.provider.filter(), [l:cur_input, l:raw_lines])

  if empty(l:lines)
    let l:lines = [g:clap_no_matches_msg]
    let l:has_no_matches = v:true
    call clap#impl#refresh_matches_count('0')
  else
    call clap#impl#refresh_matches_count(string(len(l:lines)))
  endif

  call g:clap.display.set_lines_lazy(lines)

  call g:clap#display_win.compact_if_undersize()
  call clap#spinner#set_idle()

  if !l:has_no_matches
    if exists('g:__clap_fuzzy_matched_indices')
      call s:add_highlight_for_fuzzy_matched()
    else
      call g:clap.display.add_highlight(l:cur_input)
    endif
  endif
endfunction

if s:is_nvim
  function! s:apply_add_fuzzy_highlight(hl_lines, offset) abort
    " Currently neovim does not have win_execute()
    " and the highlight added by nvim_buf_add_highlight()
    " can be overrided by the sign's highlight.
    "
    " Once the default highlight priority of nvim_buf_add_highlight() is
    " higher, we could use the same impl with vim's s:apply_highlight().

    call g:clap.display.goto_win()
    call clearmatches()

    let lnum = 0
    for indices in a:hl_lines
      let group_idx = 1
      for idx in indices
        if group_idx < g:__clap_fuzzy_matches_hl_group_cnt + 1
          call clap#util#add_match_at(lnum, idx+a:offset, 'ClapFuzzyMatches'.group_idx)
          let group_idx += 1
        else
          call clap#util#add_match_at(lnum, idx+a:offset, g:__clap_fuzzy_last_hl_group)
        endif
      endfor
      let lnum += 1
    endfor

    call g:clap.input.goto_win()
  endfunction
else
  function! s:apply_add_fuzzy_highlight(hl_lines, offset) abort
    let lnum = 0
    for indices in a:hl_lines
      let group_idx = 1
      for idx in indices
        if group_idx < g:__clap_fuzzy_matches_hl_group_cnt + 1
          call clap#util#add_highlight_at(lnum, idx+a:offset, 'ClapFuzzyMatches'.group_idx)
          let group_idx += 1
        else
          call clap#util#add_highlight_at(lnum, idx+a:offset, g:__clap_fuzzy_last_hl_group)
        endif
      endfor
      let lnum += 1
    endfor
  endfunction
endif

function! s:add_highlight_for_fuzzy_matched() abort
  " Due the cache strategy, g:__clap_fuzzy_matched_indices may be oversize
  " than the actual display buffer, the rest highlight indices of g:__clap_fuzzy_matched_indices
  " belong to the cached lines.
  "
  " TODO: also add highlights for the cached lines?
  let hl_lines = g:__clap_fuzzy_matched_indices[:g:clap.display.line_count()-1]

  if g:clap.provider.id ==# 'tags' && get(g:, 'vista#renderer#enable_icon', 0)
    let offset = 2
  else
    let offset = 0
  endif

  call s:apply_add_fuzzy_highlight(hl_lines, offset)
endfunction

function! s:add_highlight_for_fuzzy_matched() abort
  " Due the cache strategy, g:__clap_fuzzy_matched_indices may be oversize
  " than the actual display buffer, the rest highlight indices of g:__clap_fuzzy_matched_indices
  " belong to the cached lines.
  "
  " TODO: also add highlights for the cached lines?
  let hl_lines = g:__clap_fuzzy_matched_indices[:g:clap.display.line_count()-1]

  call s:apply_add_fuzzy_highlight(hl_lines)
endfunction

function! clap#impl#add_highlight_for_fuzzy_indices() abort
  let hl_lines = g:__clap_lyre_fuzzy_matched[:g:clap.display.line_count()-1]
  call s:apply_add_fuzzy_highlight(hl_lines)
endfunction

" =======================================
" async implementation
" =======================================
function! s:on_typed_async_impl() abort
  call g:clap.display.clear_highlight()
  let l:cur_input = g:clap.input.get()

  if empty(l:cur_input)
    return
  endif

  call g:clap.display.clear()

  let cmd = g:clap.provider.source_async_or_default()
  call clap#dispatcher#job_start(cmd)
  call clap#spinner#set_busy()

  call g:clap.display.add_highlight(l:cur_input)
endfunction

" Choose the suitable way according to the source size.
function! s:should_switch_to_async() abort
  if g:clap.provider.is_pure_async()
        \ || g:clap.provider.type == g:__t_string
        \ || g:clap.provider.type == g:__t_func_string
    return v:true
  endif

  let Source = g:clap.provider._().source

  if g:clap.provider.type == g:__t_list
    let s:cur_source = Source
  elseif g:clap.provider.type == g:__t_func_list
    let s:cur_source = Source()
  endif

  if len(s:cur_source) > s:async_threshold
    return v:true
  endif

  return v:false
endfunction

"                          filter
"                       /  (sync/async)
"             on_typed -
"           /           \
"          /              dispatcher
" on_enter                 (async)        --> on_exit
"          \
"           \
"             on_move
"
function! clap#impl#on_typed() abort
  if g:clap.provider.can_async()
    " Run async explicitly
    if get(g:clap.context, 'async') is v:true
      call s:on_typed_async_impl()
    elseif s:should_switch_to_async()
      call s:on_typed_async_impl()
    else
      call s:on_typed_sync_impl()
    endif
  else
    call s:on_typed_sync_impl()
  endif
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
