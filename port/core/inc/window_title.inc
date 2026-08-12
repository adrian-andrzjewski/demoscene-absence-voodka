; window_title.inc - build-selected title shared by the production ASM host.
;
; VOODKA_DEBUG_TITLE is supplied by CMake only for Debug configurations.
; Release therefore has no code path that can format scene/runtime data into
; the title bar.

%ifndef VOODKA_DEBUG_TITLE
%define VOODKA_DEBUG_TITLE 0
%endif

%macro VOODKA_EMIT_WINDOW_TITLE_W 0
%if VOODKA_DEBUG_TITLE
        dw 'V','O','O','D','K','A',' ','(','A','b','s','e','n','c','e',' ','1','9','9','6','x',' ','-',' ','W','i','n','d','o','w','s',' ','x','6','4',' ','p','o','r','t',')',0
%else
        dw 'V','o','o','d','k','a',' ','b','y',' ','A','b','s','e','n','c','e',' ','-','-','[','3','0','t','h',' ','A','n','n','i','v','e','r','s','a','r','y',' ','W','i','n','d','o','w','s',' ','P','o','r','t',']','-','-',0
%endif
%endmacro
