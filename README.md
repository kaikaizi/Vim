My *vimrc* to share with the world!
====

# `.vim/ftplugin/scanCMacro.pl`: scans and parses a C/C++ source
with its included files for macro blocks it contains.

 - Together with c.vim, the `:MacroHighlight` will disable syntax
 highlighting for inactive macro blocks.

 For example, in **foo.h**:

    #define HOO 0
    // ...

 in **foo.c**:

    #include "foo.h"

    void foo(void){
    #if HOO == 0
       puts("HOOray!");
    #else
       puts("Moo!");
    #endif
    }

 Then when `:MacroHighlight` is executed in **foo.c**, then line 6-8
 will not be highlighted.

 - Requisite: Perl library: `File::Slurp`, `Try::Tiny`.
----

