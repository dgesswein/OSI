
del osifloppytest.lod
del osifloppytest.chk
del osifloppytest.65a
del osifloppytest.lst

REM create .lod
a65 -O osifloppytest.asm
REM create .65A
a65 -A osifloppytest.asm
REM create .chk
a65 -M osifloppytest.asm

REM create listing
a65 -L -p0 osifloppytest.asm  > osifloppytest.txt

REM create bootable disks
bootthis -5 -l0300 -e0300 -n"  OSI FLOPPY TEST   BY  DAVID GESS-  WEIN" -o osifloppytest.bin DiskTest5.65D
bootthis -8 -l0300 -e0300 -n"  OSI FLOPPY TEST   BY  DAVID GESS-  WEIN" -o osifloppytest.bin DiskTest8.65D
