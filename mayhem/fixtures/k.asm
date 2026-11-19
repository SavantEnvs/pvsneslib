.include "hdr.asm"
.RAMSECTION ".reg_data" BANK $7e SLOT 3 APPENDTO "globram.data"
table_const dsb 4
tccs_sine_tab dsb 4
plain_var dsb 1
.ENDS
.SECTION ".data" APPENDTO "glob.data"
.db 1,2,3,4
.dw 5,6
.db 0
.ENDS
.SECTION ".rodata" SUPERFREE
.ENDS
.SECTION ".text" SUPERFREE
main:
 rtl
.ENDS
