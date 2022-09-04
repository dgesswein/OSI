This is an updated version of David Gesswein's OSI Floppy Disk Test v1.04
http://www.pdp8online.com/osi/osi-floppy-test.shtml

This version has the following updates:
- Corrects double key press needed on video based systems when the same key is
  pressed twice in a row (seen in Status Screen Track Up/Down etc.)

- Fixes video display on UK101 48x16 and 48x32 screens using newmon/monuk02

- Includes bootable floppy disk images for faster loading on working drives
  for both 5.25" and 8" systems. (Use OSI DiskTool or convert to HFE -- see
  https://osi.marks-lab.com/software/tools.html#OSITools

- The loader for serial systems & 65A ROM monitor has been updated to keep
  interrupts disabled at program launch (04 to processor status). It prevents
  an unexpected IRQ at launch time for systems with serial port IRQ wired.

- Source file has been updated to not rely on load-time zero page variable
  initialization to make the file load contiguously in memory. (Sorry for the
  mass code comment changes - updated for consistency.)

The build tools (A65, BootThis) can be compiled for Linux/Mac as well as Windows.

osifloppytest.lod is for use with video based systems; C1P/C2/C4/C8 (65V monitor)
osifloppytest.65a is for use with serial systems; OSI C3 (65A monitor)


For loading to OSI systems, it is best to use "8N2" 8bits, No Parity, 2 stop bits for data transfer.

Mark Spankus
08/17/2022