" Map hand-opened *.straps transcript files to filetype=straps, so a session
" file loaded with :e gets the straps ftplugin: folds, conceal and rendering.
au BufRead,BufNewFile *.straps setf straps
