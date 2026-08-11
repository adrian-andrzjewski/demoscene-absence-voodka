; p2world.asm - swiatynia city (P2) World domain (swiatynia city (P2) teardown unit 2).
;
; Ports INC/WORLD (the static World descriptor) into NASM and exposes the
; shared world globals the VR engine reads:
;   vk_swiatynia_city_world       : World records, 48 bytes each:
;                       +0 visible, +4 X, +8 Y, +12 Z, +16 obj#, +20/24/28
;                       angles, +32/36/40 angle adders, +44 type
;   vk_swiatynia_city_worldsobjects: (EndWorld - World)/48
;   vk_swiatynia_city_worldzet     : MaxWorldsOrdered sort keys (camera-space z)
;   vk_swiatynia_city_worldkol     : painter's draw order, 255 slots
;   vk_swiatynia_city_worldmax     : MaxWorldsObjects (255)
;
; The camera position uses the unit-2 globals cam_cameraX/Y/Z (already set by
; the part). The WorldZet/WorldKol are filled by CalculateVisiblating + VirSort
; (unit 8), which the render loop drives (swiatynia city (P2) teardown unit 4).

BITS 64
DEFAULT REL

section .data align=16
global vk_swiatynia_city_worldsobjects
%include "p2world.inc"
EndWorld:

section .bss align=64
global vk_swiatynia_city_worldzet
vk_swiatynia_city_worldzet: resd 255
global vk_swiatynia_city_worldkol
vk_swiatynia_city_worldkol: resd 255

section .data align=16
global vk_swiatynia_city_worldmax
vk_swiatynia_city_worldmax: dd 255
