; p1_data.inc - static data for the oko + szklo (P1) port (mirrors P1.ASM's data section).

; per-frame screen-shift table (33 entries; indexed by ModPos & 31)
section .data
global tablica
tablica:
        dw      160,100, 160,100, 160,100, 160,100
        dw      160,100, 160,100, 160,100, 160,100
        dw      160,100, 160,100, 160,100, 160,100
        dw      200,140          ; 'c'
        dw      200,140
        dw      140,60
        dw      168,170
        dw      160,100
        dw      160,100, 160,100, 160,100, 160,100
        dw      160,100, 160,100, 160,100, 160,100
        dw      160,100, 160,100, 160,100, 160,100
        dw      160,100, 160,100, 160,100, 160,100

; two 2D cut polygons (x0,y0) -> ...  (5-1 / 6-1 segments)
p_tab:
        dd      5-1
        dw      160-68,0
        dw      142-68,60
        dw      168-68,82
        dw      153-68,142
        dw      167-68,200

p_tab2:
        dd      6-1
        dw      160+68,0
        dw      142+68,60
        dw      168+68,82
        dw      153+68,122
        dw      167+68,169
        dw      142+68,200

; logo blit program: [logo idx (0..3), screen offset, width, height]
;   idx 0 = logo1 (=_logo1.inc), 1 = logo2, 2 = logo3, 3 = logo4
global logo_tab
logo_tab:
        times 30 dd 0, 166+(152*320), 140, 42
        dd 1, 6+(12*320), 231, 42
        dd 0, 166+(152*320), 140, 42
        dd 1, 6+(12*320), 231, 42
        times 31 dd 1, 6+(12*320), 231, 42
        times 30 dd 2, 158+(152*320), 150, 42
        dd 3, 6+(12*320), 162, 42
        dd 2, 158+(152*320), 150, 42
        dd 3, 6+(12*320), 162, 42
        times 31 dd 3, 6+(12*320), 162, 42
        times 32 dd 3, 6+(12*320), 162, 42
