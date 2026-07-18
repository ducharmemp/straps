" Map hand-opened *.straps transcript files to filetype=straps, so a session
" file loaded with :e gets straps folding (via ui.setup's FileType autocmd).
au BufRead,BufNewFile *.straps setf straps
