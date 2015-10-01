fu! s:EchoHighlight(msg,...)
let hig = a:0 ? a:1 : 'WarningMsg'
exe 'echohl '.hig | echo a:msg | echohl None
retu 0
endf

fu! s:DimUndefBlock()
   if &ft!='c' && &ft!='cpp'
   	retu
   end
   up
   syn enable
   let fexec=findfile('scanCMacro.pl', split(&rtp,',')[0].'/ftplugin')
   if empty(fexec)
   	cal EchoHighlight('Cannot load scanCMacro.pl script') | retu
   end
   let block=system(fexec.' '.bufname('').' '.&path)
   if !empty(block)
   	for blk in split(block,"\n")
   	   let lines=split(blk,':')
   	   if len(lines)!=3
		continue	" ignore error
	   end
	   sil! exe "syn region NonText start='\\%". lines[1] ."l' end='\\%". (lines[2]+1) ."l'"
	endfo
   end
endf
command! -nargs=0 MacroHighlight call <SID>DimUndefBlock()
