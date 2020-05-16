;
; DISK TEST UTILITY FOR C1P/UK101/C2PDF/C4PMF/C8P/C3-OEM
; Supposed to work with serial or video and 8" or 5.25" floppies. Tested 
; with C2 with 8" floppies, serial, and 540B video. Tested with OSI emulator
; with 5.25" floppies.
; Needs 16k memory.
; Start at $300
; Does write/read or read only test. Disk format is not compatible with
; OSI operating systems. Can either print error information or generate
; a pulse on fault reset to trigger scope on error. Can also show
; drive status lines and allow manual control of drive control lines.
; Will also measure drive RPM
;
; DESTRUCTIVE DISK READ/WRITE TEST
; By David Gesswein djg@pdp8online.com
; Initial release V1.0 05/04/2020
; V1.1 05/16/2020. Fixed ANYKEY not aborting. Prevent specifying illegal
;    track to test. Fixed printing false errors when no data read.
;    Fixed issues with serial console getting selected on video system.

; All my changes are released as public domain. The original code did not have
; any license specified.
; For usage see http://www.pdp8online.com/osi/osi-floppy-test.shtml

;BASED ON https://osi.marks-lab.com/software/tools.html Universal OSIDump 
;BASED ON ED'S OSIDUMP UTILITY
;
;

ORG	=	$0300

MAXTRK5	=	40	; # TRACKS TO READ 5 1/4 disk
MAXPAG5	=	10	; # PAGES TO READ  5 1/4 disk
MAXTRK8 =   77	; # Tracks to read 8 disk
MAXPAG8 =   15	; # Pages to read 8 disk
BYTES5	= 2167
BYTES8  = 3600

DDPIA	=   $C000   ; Disk controller PIA
DDACIA  =   $C010   ; Disk Controller Serial Port
C2ACIA  =   $FC00   ; ACIA on C2/C4/C8/C3
C1ACIA  =   $F000   ; ACIA on C1

;Control Character Constants XMODEM etc.
CR		=	$0D
LF		=	$0A
ESC		=	$1B		; ESC to exit


;storage space (anywhere, so why not page zero?)
STORE   =   $29   ;storage C4P starts stack at 28
MAXTRK  =   STORE+01 ;1 - 40 for 5.25, 77 for 8, 255 for HD
MAXPAG  =   STORE+02 ;1 - 9 for 5.25, 15 for 8, 16 for HD
ACIACTL =   STORE+03 ;1 controls cassette/rs-232 ACIA divisor, format
DRVNUM  =   STORE+04 ;1 drive# 0-3
TRK     =   STORE+05 ;1 current track #
TMP     =   STORE+6  ;1
MACHINE =   STORE+7  ;1 C1/C2/C3 flag 00=C2/4/8, $40=C3Ser, $80=C1


        *= STORE+8
VIDEO		.BYTE 0 ; 0 = Serial $FF = video
PATSEL  	.BYTE 0 ;  0 = Fixed byte (PATVAL), $FF = random
PATVAL		.BYTE 0 ;  Byte to write to disk
PASSES		.BYTE 0
READONLY	.BYTE 0 ; zero read write
PASSCNTR	.BYTE 0
RND		.BYTE 92, 159, 137, 36, 210, 89
RNDHLD		.BYTE 0,0,0,0,0,0
DIVIDEND 	.BYTE 0,0,0
;DIVISOR 	.BYTE 0,0,0
DIVISOR 	.BYTE $f6,$5c,0
REMAINDER 	.BYTE 0,0,0
factor2 	.BYTE 0,0,0
PZTEMP 	 	.BYTE 0
MAX	 	.BYTE 0,0,0
MIN	 	.BYTE 0,0,0
SUM	 	.BYTE 0,0,0
pad		.BYTE 0
ERRCNT		.WORD 0
PRTERR		.BYTE 0
; 8" RPM scale 360 RPM * (250000 bps/10 bits/byte/6 RPS) = 1500000
RPMSCALE8	.BYTE $60, $e3, $16 
; 5.25" RPM scale 300 * (125000/10/5) = 750000
RPMSCALE5	.BYTE $b0, $71, $0b 
; Allow 3% fast rotation and 1.25 delay after index high and 2.2 ms index
; pulse;
MTRKBYTES	.WORD 0	; negative number of bytes in track
BYTECNTR	.WORD 0
YHOLD		.BYTE 0
TESTTYPE	.BYTE 0	; 0 normal 1 scope

;zero page storage
DRVACIA 	.BYTE 0 ; Current serial word format for DISK ACIA 8E1/8N1
PTRSTOR		.WORD 0 
TDATA  		.WORD 0
TDATA2 		.WORD 0
VIDSRC		.WORD $D040
VIDDST		.WORD $D000
VIDOFFSET	.BYTE 0
MAXERR		.BYTE 0 ; number of errors + 1 to print
SINGLETRK	.BYTE 0; non zero if testing single track

	; Serial monitor start values
	*= $129
	.BYTE 0,0,0,0,$fd,ORG/256,ORG%256

	*=	ORG
	.EXE *        ;A65 emit OSI .lod start address operation
	SEI
	LDA	$FE01     ;determine machine type
	BEQ	SERTYP    ;Is this serial system?                                                    
	LDA	#$00	
	BIT	$DF00	  ;okay check C1/C2-C4
	BMI	C1TYPE
C1TYPE=*+1
	BIT	$80A9	  ;
SERTYP=*+1
	BIT	$40A9
	STA	MACHINE	  ;bit 7 = C1, bit 6 = C3, none =C2/C4
	LDA	#$15      ;B1 = 8N2 /16 RTStxIRQ  rxIRQ ;$15 = 8N1 /16 RTSNOtxIRQ NOrxIRQ; $B5 = irqs on 8N1
	STA	ACIACTL
	; Not sure how to figure out if we should use serial or video.
	; First try to determine if a serial port exists. If it does we
	; print a message to both serial and video and see which the user
	; hits a key on to select between video and serial
	LDX 	#10	; 10*1.25MS wait for last character to be output
	JSR 	DELAY
	LDX	#0
	JSR	CheckTXReady	; If serial not ready likely no serial port
	BCS	SELLP		
	DEX			; so don't write to serial.
SELLP
	JSR	Get_Chr		; Flush serial data if any
	STX	VIDEO		; Select serial first then video
	JSR	PRINT
	.BYTE	CR,LF,'HIT ANY KEY TO SELECT CONSOLE DEVICE',CR,LF,0
	JSR	Get_Chr		; Flush serial data if any
	DEX
	CPX	#$FE		; If we did both then we are done
	BNE	SELLP
SELLP2
	JSR	Get_Chr		; Get serial character if one ready
	BCS	SERCON		; Got one, select serial
	JSR	Get_Chr_Polled	; Check polled keyboard for key down
	BCC	SELLP2		; Didn't find it
	LDX	#$FF
	LDY	#4		; Set video console and # of errors to print
	JMP	STORECON
SERCON
	LDX	#0
	LDY	#6		; Set serial console and # of errors to print
STORECON
	STX	VIDEO
	STY	MAXERR

	LDA	#$00	; Reset various variables
	STA	VIDOFFSET
	STA	DRVNUM
	STA     PATSEL
	STA	TESTTYPE
	STA	READONLY
	STA	TRK	; We don't know the track so set to zero
	LDA     #$01
	STA	PASSES
	LDA     #$18
	STA	PATVAL
    	BIT	MACHINE
	BVC	*+5
	JMP	SETDRV8  ;serial systems use 8" by default
	JMP	SETDRV5

TOP
	JSR	DRWMENU	; Print menu
	JSR	Get_Chr		; Flush serial data if any
	LDX	#$00
	JSR	INKEY	; Key user input
	JSR	OUTPUT
	CMP	#$31	; See if its a menu choice and do it
	BNE	*+5
	JMP	TEST
	CMP	#$32
	BNE	*+5
	JMP	TESTTRK
	CMP	#$33
	BNE	*+5
	JMP	SETDRV
	CMP	#$34
	BNE	*+5
	JMP	DRVTYPE
	CMP	#$35
	BNE	*+5
	JMP	SETPAT
	CMP	#$36
	BNE	CHECKNEXT
	LDA	#$FF
	EOR	READONLY
	STA	READONLY
	JMP	TOP
CHECKNEXT
	CMP	#$37
	BNE	*+5
	JMP	RPMTEST
	CMP	#$38
	BNE	*+5
	JMP	STATSCRN
	CMP	#$39
	BNE	*+5
	JMP	($FFFC)	;Exit
	JMP	INPERR

DRVTYPE
	JSR	PRINT
	.BYTE $D,$A,'Enter your disk drive type (8) inch or (5).25 inch? >',0
	JSR	INKEY
	JSR	OUTPUT
	CMP	#$38
	BEQ	SETDRV8
	CMP	#$35
	BEQ	SETDRV5
INPERR
	LDA	#'?	; Print bad choice and menu again
	JSR	OUTPUT
	JMP	TOP

SETDRV5
	LDA	#MAXTRK5
	STA	MAXTRK
	LDA	#MAXPAG5
	STA	MAXPAG
	LDA	#-BYTES5%256
	STA	MTRKBYTES
	LDA	#-BYTES5/256
	STA	MTRKBYTES+1
	JMP	TOP

SETDRV8
	LDA	#MAXTRK8
	STA	MAXTRK
	LDA	#MAXPAG8
	STA	MAXPAG
	LDA	#-BYTES8%256
	STA	MTRKBYTES
	LDA	#-BYTES8/256
	STA	MTRKBYTES+1
	JMP	TOP


TESTTRK
	JSR PRINT
	.BYTE $D,$A,'Enter 2 digit decimal track to test > ',0
	JSR GETDEC2
	BCC TESTTRK
	STA YHOLD
	CMP MAXTRK	; Don't allow more than MAXTRK
	BPL TESTTRK
	JSR INITPIA
	JSR SELDRV
	JSR TZERO	; STEP TO TRACK 0
	BCC *+5
	JMP NOTRK
	LDA YHOLD
	BEQ TESTSTART
TESTTN
	JSR TNEXT	; Step to desired track
	DEC YHOLD
	BNE TESTTN
TESTSTART
	LDA #1		; And set flag to only test the one track
	STA SINGLETRK
	JMP TEST2

SETPAT
	LDA #0
	STA PATSEL
	JSR PRINT
	.BYTE $D,$A,'Enter hex fill pattern or space for random > ',0
	JSR INKEY
	JSR OUTPUT
	AND #$7F
	CMP #' '
	BEQ PATRND
	JSR CONVHDIG
	BCC SETPAT
	ASL	; Shift to high nibble
        ASL
        ASL
        ASL
	TAX
	JSR INKEY	; Get and combine with low nibble
	JSR OUTPUT
	JSR CONVHDIG
	BCC SETPAT
	STA TMP
	TXA
	ORA TMP
	STA PATVAL
GETPASSES
	JSR PRINT
	.BYTE $D,$A,'Enter two digit passes > ',0
	JSR GETDEC2
	BCC GETPASSES
	STA PASSES

GETTYPE
	JSR PRINT
	.BYTE $D,$A,'(S)cope test or (N)ormal > ',0
	JSR INKEY
	JSR OUTPUT
	AND #$7F
	ORA #$20
	LDX #0
	CMP #'n'
	BEQ SETTYPE
	INX
	CMP #'s'
	BNE GETTYPE
SETTYPE
	STX TESTTYPE
	JMP TOP
PATRND
	DEC PATSEL
	JMP GETPASSES

CONVHDIG
	JSR CONVDIG
	BCS CONVHRET
	CMP #'a'
	BMI CONVERR
	CMP #'f'+1
	BPL CONVERR
	SBC #'a'-1-10
CONVHRET
	RTS
CONVDIG
	AND #$7F
	ORA #$20
	CMP #'0'
	BMI CONVERR
	CMP #'9'+1
	BPL CONVERR
	SBC #'0'-1
	RTS
CONVERR
	CLC
	RTS

; Return 2 digit decimal number in A. Carry clear if number valid
GETDEC2
	JSR INKEY
	JSR OUTPUT
	JSR CONVDIG
	BCC GETDEC2RET
	STA TMP
	ASL		; Multiply by 8
	ASL
	ASL
	ADC TMP		; And add twice to make multiply by 10
	ADC TMP
	STA TMP
	JSR INKEY	; Get and add low digit
	JSR OUTPUT
	JSR CONVDIG
	BCC GETDEC2RET
	CLC
	ADC TMP
	SEC
GETDEC2RET		; Not valid number, return carry clear
	RTS

SETDRV
	JSR PRINT
	.BYTE $D,$A,'Select drive (A), (B), (C), (D) ? >',0
	JSR INKEY
	JSR OUTPUT
	AND #$5F
	CMP #'A
	BCC SETERR
	CMP #'E
	BCS SETERR
	SBC #'@		;carry is clear so val -1
	STA DRVNUM
	JMP TOP
SETERR
	JMP INPERR

NOTRK2
	JMP NOTRK
	; Test drive RPM with head unloaded and loaded
	; We count number of bytes sent through disk serial port between
	; index pulses to measure RPM. That is independent of CPU speed.
	; We use 8N1 for 10 total bits.
	; 8" = 25,000 characters per second and 5.25" 12,500.
	; 16 measurements are done with minimum, maximum, and avarage
        ; printed
RPMTEST
	JSR INITPIA
	JSR SELDRV
	JSR TZERO	; STEP TO TRACK 0
	BCS NOTRK2
	LDA #3
	STA DDACIA  	; RESET ACIA
	LDA #$54    ;0 10 101 00 ;$54-  recv irq, RTS HIGH no xmit irq,  8N1,  DIVIDE BY 1,
	STA DRVACIA	
	STA DDACIA  	; SET DISK SERIAL WORD FORMAT/CLEAR FLAGS
	JSR PRINT
	.BYTE $D,$A,'Head unloaded ',0
	JSR RPMTST2
	LDA DDPIA+2	; PRESERVE DISK SEL BIT
	AND #$7F	; 0111 1111
	STA DDPIA+2	; LOAD DISK HEAD
	LDX #$FF	; 320MS
	JSR DELAY
	JSR PRINT
	.BYTE $D,$A,'Head loaded   ',0
	JSR RPMTST2
RPMUNLOAD
	LDA DDPIA+2
	ORA #$80	
	STA	DDPIA+2	; UNLOAD DISK HEAD
	JMP TOP
INDEXACT
	JSR PRINT
	.BYTE 'Index stuck active',CR,LF,0
	JSR ANYKEY
	JMP RPMUNLOAD
INDEXINACT
	JSR PRINT
	.BYTE 'Index stuck inactive',CR,LF,0
	JSR ANYKEY
	JMP RPMUNLOAD
RPMTST2
	LDX #0
	LDY #0
RPMTSTLP
	INX
	BNE *+3
	INY
	BEQ INDEXACT
	BIT DDPIA	; WAIT END OF
	BPL RPMTSTLP	; INDEX PULSE
	LDA #0
	STA DIVISOR	; Clear variables
	STA DIVISOR+1
	STA DIVISOR+2
	STA MAX
	STA MAX+1
	STA MAX+2
	STA SUM
	STA SUM+1
	STA SUM+2
	LDA #255
	STA MIN
	STA MIN+1
	STA MIN+2
	LDX #16		; Measure RPM 16 times
	LDY #0
	LDA #0
	CLC
RPMLP1
	; Wait for index then write first byte to UART since it
	; should be ready. Then write a second byte since it should either
	; be ready immediatly or very shortly after first byte is transferred
        ; to TX shift register. Then start counting with the writes that
        ; will happen at the UART data rate.
	INY
	BNE *+4
	ADC #1
	BEQ INDEXINACT	; If we wait to long for index inactive print error
	BIT DDPIA	; WAIT for INDEX PULSE
	BMI RPMLP1
	STA DDACIA+1	; WRITE BYTE, VALUE DON'T CARE
RPMNDX0
	LDA #2
	AND DDACIA 	;test tx ready?	
	BEQ RPMNDX0	;not ready?
	STA DDACIA+1	; WRITE BYTE, VALUE DON'T CARE
RPMNDX1
	LDA #2
	AND DDACIA 	;test tx ready?	
	BEQ RPMNDX1	;not ready?
	STA DDACIA+1	; WRITE BYTE, VALUE DON'T CARE
	INC DIVISOR
	BNE *+4
	INC DIVISOR+1
	BNE *+4
	INC DIVISOR+2
	BIT DDPIA	; WAIT END OF
	BPL RPMNDX1	; INDEX PULSE
RPMNDX2
	BIT DDPIA	; DONE IF 
	BPL RPMNDX3	; INDEX PULSE
	LDA #2
	AND DDACIA 	;test tx ready?	
	BEQ RPMNDX2	;not ready?
	STA DDACIA+1	; WRITE BYTE, VALUE DON'T CARE
	INC DIVISOR	; Count character sent
	BNE *+4
	INC DIVISOR+1
	BNE *+4
	INC DIVISOR+2
	JMP RPMNDX2
RPMNDX3
	BIT DDPIA	; WAIT END OF
	BPL RPMNDX3	; INDEX PULSE
	CLC
	LDA SUM		; Sum of all rotation time
	ADC DIVISOR
	STA SUM
	LDA SUM+1
	ADC DIVISOR+1
	STA SUM+1
	LDA SUM+2
	ADC DIVISOR+2
	STA SUM+2

	LDA DIVISOR+2
	CMP MIN+2
	BCC LESS1
	BNE GE1
	LDA DIVISOR+1
	CMP MIN+1
	BCC LESS1
	BNE GE1
	LDA DIVISOR
	CMP MIN
	BCC LESS1
GE1	; DIVISOR >= MIN
	LDA DIVISOR+2
	CMP MAX+2
	BCC LESS2
	BNE GE2
	LDA DIVISOR+1
	CMP MAX+1
	BCC LESS2
	BNE GE2
	LDA DIVISOR
	CMP MAX
	BCC LESS2
GE2	; DIVISOR >= MAX
	LDA DIVISOR
	STA MAX
	LDA DIVISOR+1
	STA MAX+1
	LDA DIVISOR+2
	STA MAX+2
	JMP LESS2

LESS1	; DIVISOR < MIN
	LDA DIVISOR
	STA MIN
	LDA DIVISOR+1
	STA MIN+1
	LDA DIVISOR+2
	STA MIN+2
	JMP GE1
	
LESS2	; DIVISOR < MAX
	DEX
	BEQ RPMDONE
	LDA #0
	STA DIVISOR
	STA DIVISOR+1
	STA DIVISOR+2
	JMP RPMLP1

RPMDONE
	JSR PRINT
	.BYTE 'RPM: AVG ',0
	LDX #4		; Divide by 16 to convert sum to average
RPMDIVL
	CLC
	ROR SUM+2
	ROR SUM+1
	ROR SUM
	DEX
	BNE RPMDIVL
	LDA SUM
	STA DIVISOR
	LDA SUM+1
	STA DIVISOR+1
	LDA SUM+2
	STA DIVISOR+2
	JSR RPMPRT

	JSR PRINT
	.BYTE '  MIN',0

	LDA MAX
	STA DIVISOR
	LDA MAX+1
	STA DIVISOR+1
	LDA MAX+2
	STA DIVISOR+2
	JSR RPMPRT

	JSR PRINT
	.BYTE '  MAX',0

	LDA MIN
	STA DIVISOR
	LDA MIN+1
	STA DIVISOR+1
	LDA MIN+2
	STA DIVISOR+2
	JSR RPMPRT
	RTS

	; Convert count to RPM with two decimal places
RPMPRT
	LDA MAXPAG
	CMP #MAXPAG8
	BEQ RPM8
	LDA RPMSCALE5
	STA DIVIDEND
	LDA RPMSCALE5+1
	STA DIVIDEND+1
	LDA RPMSCALE5+2
	STA DIVIDEND+2
	JMP DODIV
RPM8
	LDA RPMSCALE8
	STA DIVIDEND
	LDA RPMSCALE8+1
	STA DIVIDEND+1
	LDA RPMSCALE8+2
	STA DIVIDEND+2
DODIV
	JSR DIV24	; Get integer part of RPM
	LDA #' '
	STA pad
	JSR PrDec16
	LDA #100	; Multiply remainder by 100 and divide again to get
	STA factor2	; fractional part
	LDA #0
	STA factor2+1
	STA factor2+2
	JSR MULT24
	JSR DIV24
	LDA #'.'
	JSR OUTPUT
	LDA #'0'
	STA pad
        LDY #2                       ; Print 2 digits
	JSR PrDec16Lp1
	RTS
	
   ; From http://beebwiki.mdfs.net/Number_output_in_6502_machine_code
   ; ---------------------------
   ; Print 16-bit decimal number
   ; ---------------------------
   ; On entry, num=number to print
   ;           pad=0 or pad character (eg '0' or ' ')
   ; On entry at PrDec16Lp1,
   ;           Y=(number of digits)*2-2, eg 8 for 5 digits
   ; On exit,  A,X,Y,num,pad corrupted
   ; Size      69 bytes
   ; -----------------------------------------------------------------
num = DIVIDEND

PrDec2Dig
   STA num
   LDA #0
   STA num+1
   LDA #' '
   STA pad
   LDY #2
   JMP PrDec16Lp1
PrDec4Dig
   STX num
   STA num+1
   LDA #' '
   STA pad
   LDY #6
   JMP PrDec16Lp1

PrDec16
   LDY #8               ; Offset to powers of ten
PrDec16Lp1
   LDX #$FF
   SEC			; Start with digit=-1
PrDec16Lp2
   LDA num+0
   SBC PrDec16Tens+0,Y
   STA num+0  		; Subtract current tens
   LDA num+1
   SBC PrDec16Tens+1,Y
   STA num+1
   INX
   BCS PrDec16Lp2       ; Loop until <0
   LDA num+0
   ADC PrDec16Tens+0,Y
   STA num+0  		; Add current tens back in
   LDA num+1
   ADC PrDec16Tens+1,Y
   STA num+1
   TXA
   CPY #0
   BEQ PrDec16Digit	; Last digit, always print
   TXA
   BNE PrDec16Digit     ; Not zero, print it
   LDA pad
   BNE PrDec16Print
   BEQ PrDec16Next 	; pad<>0, use it
PrDec16Digit
   LDX #'0
   STX pad              ; No more zero padding
   ORA #'0              ; Print this digit
PrDec16Print
   JSR OUTPUT
PrDec16Next
   DEY
   DEY
   BPL PrDec16Lp1	; Loop for next digit
   RTS
PrDec16Tens
   .WORD 1
   .WORD 10
   .WORD 100
   .WORD 1000
   .WORD 10000
;-----------------------------------------------------------
; Either write test pattern then check or just check pattern.
; Read test only works for data written by this program.
TEST
	LDA	#0
	STA	SINGLETRK
TEST2
	JSR	PRINT
	.BYTE	CR,LF
	.BYTE	'WRITE PROTECT ALL DISKS EXCEPT TEST DISK!',CR,LF
	.BYTE	CR,LF
	.BYTE	'INSERT DISK TO BE TESTED',CR,LF
	.BYTE	'If errors found the output is DDDD (#### GG BBP)* EEEE',CR,LF
        .BYTE   'where DDDD is difference between number of bytes written',CR,LF
        .BYTE   'and read. EEEE is total errors, #### is byte count from', CR,LF
        .BYTE   'start of track, GG is good byte, BB is bad byte,',CR,LF
        .BYTE   'P is byte had parity error.',CR,LF
        .BYTE   'Errors that fit on line are printed.',CR,LF
	.BYTE   'ESC KEY OR ^X ABORTS...',CR,LF,0

	JSR	ANYKEY
        CMP     #$1B   ;ESC key?
        BEQ     JMP2TOP
        CMP     #$18   ;^X
        BEQ     JMP2TOP


	LDA	PASSES
	STA	PASSCNTR
	JSR	INITPIA
	JSR	SELDRV
	JSR	RESPTR
	LDA	#$20
	BIT	DDPIA
	BNE	WRITEOK
	JSR	PRINT
	.BYTE	CR,LF
	.BYTE	'DISK IS WRITE PROTECTED!',CR,LF,0
	JSR	ANYKEY
JMP2TOP
	JMP	TOP
WRITEOK
	LDA	SINGLETRK
	BNE	TESTFILL ; Head already at desired track
	JSR	TZERO	; STEP TO TRACK 0
	BCC	TESTFILL
	JMP	NOTRK

TESTFILL
	JSR	RESPTR
	LDY	#0
TFILL	
	LDA	PATVAL
	BIT	PATSEL		; Fill with test pattern. 
	BPL     TSTORE		; Always fills larger 8" number of bytes
	JSR	RAND
TSTORE
	STA	(TDATA),Y
	INY
	BNE	TCHKFILLED
	INC	TDATA+1
TCHKFILLED
	CPY	#BYTES8%256
	BNE	TFILL
	LDA	TDATA+1
	SEC
	SBC	#BUFFER/256
	CMP	#BYTES8/256
	BNE	TFILL

	LDA	#$5A		; Start of track marker
	STA	BUFFER
	
	LDA	#$58    ;0 10 110 00 ;$58-  recv irq, RTS HIGH no xmit irq,  8E1,  DIVIDE BY 1,
	STA	DRVACIA	

	LDA	DDPIA+2  ; PRESERVE DISK SEL BIT
	AND	#$7F	; 0111 1111
	STA	DDPIA+2	; LOAD DISK HEAD
	LDX	#$FF	; 320MS
	JSR	DELAY

	LDA	READONLY	; If read only skip write
	BEQ	WRNEXT
	JMP	TREAD
WRNEXT
	JSR	PRINT
	.BYTE	'WTRK ',0
	LDA	TRK
	JSR	PrDec2Dig
	LDA	MTRKBYTES
	STA	BYTECNTR
	LDA	MTRKBYTES+1
	STA	BYTECNTR+1
	JSR	RESPTR
	LDA	TRK	; Write track to second byte to check for seek errors
	STA	BUFFER+1

	BIT	DDPIA	; WAIT 
	BMI	*-3	; INDEX PULSE
	BIT	DDPIA	; WAIT END OF
	BPL	*-3	; INDEX PULSE
	LDA	DDPIA+2 ; PRESERVE DISK SEL BIT
	AND	#$FC	; TURN ON WRITE AND ERASE ENABLE
	STA	DDPIA+2

	LDA	#3
	STA	DDACIA  ; RESET ACIA
	LDA	DRVACIA	; usually $58-DIVIDE BY 1, 8E1, RTS HIGH no IRQs
	STA	DDACIA  ; SET DISK SERIAL WORD FORMAT/CLEAR FLAGS
	LDX 	#1	; 0.8MS
	LDY	#$9E
	JSR 	DELAY1
	LDY	#0
WRDATALP
	BIT	DDPIA	; WAIT 
	BMI	WNOINDEXERR	; Didn't find INDEX PULSE
	JMP	INDEXERR	
WNOINDEXERR
	LDA	#2
	AND	DDACIA		;test tx ready?	
	BEQ	WRDATALP	;not ready?
	LDA	(TDATA),Y
	STA	DDACIA+1	; Write data to floppy
	INY
	BNE	*+4
	INC	TDATA+1
	INC	BYTECNTR
	BNE	WRDATALP
	INC	BYTECNTR+1
	BNE	WNOINDEXERR	; Not done, write more. Don't check for index
				; to prevent being late writing next char.

	BIT	DDPIA	; WAIT FOR
	BMI	*-3	; INDEX PULSE
	BIT	DDPIA	; WAIT FOR
	BPL	*-3	; END INDEX PULSE
	LDX	#32	; Erase a little past index
	DEX
	BNE	*-1
	
	LDA	#$03
	ORA	DDPIA+2	; turn off write and erase
	STA	DDPIA+2

	LDA	#CR
	JSR	OUTPUT
	LDA	SINGLETRK
	BNE	TREAD	; Single track, we are done writing
	LDX	TRK
	INX
	CPX	MAXTRK
	BEQ	TWDONE
	JSR	TNEXT	; Go to next track
	JMP     WRNEXT
TWDONE
	LDA	#$80
	ORA	DDPIA+2	; Unload head
	STA	DDPIA+2


	; Read portion of disk test. Enter at TREAD2 if testing
	; single track. For normal read we save off the data read and the
	; error flags from the serial chip. We don't have enough time
	; to handle errors between bytes.
	; For scope read we check the word in real time and generate
	; fault reset pulse to trigger a scope. Checking for the track stops
	; after the first error.
TREAD
	LDA	SINGLETRK
	BNE	TREAD2	; Single track, skip seek to zero
	JSR	TZERO	; STEP TO TRACK 0
	BCC	*+5
	JMP	NOTRK
	LDA	DDPIA+2  ; PRESERVE DISK SEL BIT
	AND	#$7F	; 0111 1111
	STA	DDPIA+2	; LOAD DISK HEAD
	LDX	#$FF	; 320MS
	JSR	DELAY

TREAD2
	JSR	RESPTR
	LDA	#0
	STA	ERRCNT
	STA	ERRCNT+1
	STA	PRTERR	

	JSR	PRINT
	.BYTE	'RTRK ',0
	LDA	TRK
	JSR	PrDec2Dig
	LDA	#' '
	JSR	OUTPUT
	LDA	TRK		; Update compare data with track testing
	STA	BUFFER+1

	BIT	DDPIA	; WAIT 
	BMI	*-3	; INDEX PULSE
	BIT	DDPIA	; WAIT END OF
	BPL	*-3	; INDEX PULSE
	LDA	#3
	STA	DDACIA  ; RESET ACIA
	LDA	DRVACIA	; usually $58-DIVIDE BY 1, 8E1, RTS HIGH no IRQs
	STA	DDACIA  ; SET DISK SERIAL WORD FORMAT/CLEAR FLAGS
	LDA	TESTTYPE
	BNE	*+5
	JMP	NORMREAD	; User selected normal read test

	; This is scope read check code
	LDY	#0
	LDA	#1
RDATALP2
	BIT	DDPIA
	BPL     NODATA		; INDEX PULSE
	BIT	DDACIA		; test tx ready?	
	BEQ	RDATALP2
	PHP
	LDA	DDACIA+1	; read data from floppy
	CMP	#$5A		; Got start byte
	BNE	IGNBYTE		; No, try one more time. We get one junk
				; byte where write turned on/off
	PLP
	BVS	SERROR		; Did it get a parity error
	INY			; Skip this byte in checking since we checked
	JMP 	RDATALP3
IGNBYTE
	PLP
RDATALP3
	BIT	DDPIA
	BMI     NOTINDEX2	; INDEX PULSE
	JMP	PCRONLY
NOTINDEX2
	LDA	#1
	BIT	DDACIA		; test tx ready?	
	BEQ	RDATALP3
	LDA	DDACIA+1	; read data from floppy
	BVS	SERROR		; Branch if parity error
	CMP	(TDATA),Y	; Check data
	BNE	SERROR
	INY
	BNE	NOTINDEX2
	INC	TDATA+1
	JMP	NOTINDEX2
NODATA
	JSR	PRINT
	.BYTE	'No data',0
JPCRLF
	JMP	PCRLF
SERROR	; Print error info and generate scope trigger
	PHA
	LDA	#$EF
	AND	DDPIA+2	; Clear fault reset
	STA	DDPIA+2
	JSR	DELAY2
	LDA	#$10
	ORA	DDPIA+2	; Set fault reset
	STA	DDPIA+2

	SEC
	LDA	TDATA+1		; Calculate offset of byte with error
	SBC	#>BUFFER
	STA	num+1
	STY	YHOLD
	STY	num
	TYA
	CLC
	ADC	MTRKBYTES
	LDA	num+1
	ADC	MTRKBYTES+1
	BMI	SPERR	; Error was in bytes being tested
	JSR	PRINT
	.BYTE	'Extra data read',0
	JMP	SERRWAIT
	
SPERR
	LDA	#'0'
	STA	pad
	LDY	#6	; 4 digits max
	JSR 	PrDec16Lp1
	JSR	PRINT
	.BYTE	' GOOD ',0
	LDY	YHOLD
	LDA	(TDATA),Y
	JSR	PHEXA
	JSR	PRINT
	.BYTE	' BAD ',0
	PLA
	JSR	PHEXA
SERRWAIT
	LDA	DDPIA+2
	ORA	#$80	
	STA	DDPIA+2	; UNLOAD DISK HEAD
	JSR	Get_Chr
	JSR	PRINT
	.BYTE	CR,LF,'Hit space to reread E to exit or other key to continue > ',0
	JSR	INKEY
	PHA
	JSR	PRINT
	.BYTE	CR,LF,0
	PLA
	ORA	#$20	; Lower case
	CMP	#'e'
	BNE	*+5
	JMP	TOP
	PHA
	LDA	DDPIA+2  ; PRESERVE DISK SEL BIT
	AND	#$7F	; 0111 1111
	STA	DDPIA+2	; LOAD DISK HEAD
	LDX	#$FF	; 320MS
	JSR	DELAY
	PLA
	CMP	#' '
	BEQ	*+5
	JMP	NEXTTRK
	JMP	TREAD2
	
	

	; This is normal read check code
NORMREAD
	LDY	#0
RDATALP
	BIT	DDPIA
	BPL     RINDEX	; INDEX PULSE
NOTINDEX
	LDA	DDACIA		; test tx ready?	
	STA	(TDATA2),Y	; store error data
	LSR
	BCC	RDATALP		; not ready?
	LDA	DDACIA+1	; read data from floppy
	INY
	STA	(TDATA2),Y	; store disk data
	INY
	BNE	NOTINDEX
	INC	TDATA2+1
	JMP	NOTINDEX

RINDEX
	CLC	; Found index, determine how many bytes read
	TYA
	ADC	TDATA2
	STA	TDATA2
	BCC	*+4
	INC	TDATA2+1
	SEC
	LDA	TDATA2
	SBC	#<BUFFER2
	STA	BYTECNTR
	LDA	TDATA2+1
	SBC	#>BUFFER2
	CLC
	ROR
	STA	BYTECNTR+1
	LDA	BYTECNTR	; divide by 2 to get bytes data stored
	ROR
	STA	BYTECNTR
	LDA	BYTECNTR
	BNE	CHKSTART
	LDA	BYTECNTR+1
	BEQ	NOSKIP		; If no data don't try to find start of track
CHKSTART
	; This will skip up to 1 byte looking for $5A start of track flag
	; The write turn on/off generates one byte of junk sometimes
	JSR	RESPTR
	LDA     BUFFER2+1
	CMP	#$5A		; Start of track flag
	BEQ	NOSKIP
	LDA     BUFFER2+3
	CMP	#$5A		; Start of track flag
	BNE	NOSKIP		; No, assume read error
	CLC
	LDA	#2
	ADC	TDATA2
	STA	TDATA2
	LDA	#0
	ADC	TDATA2+1	; Ignore one junk character
	STA	TDATA2+1	; and parity byte
	LDA	BYTECNTR
	BNE	*+4
	DEC     BYTECNTR+1
	DEC	BYTECNTR
NOSKIP
	CLC	; Print bytes read - bytes written. Skipped byte not
		; included in bytes read 
	LDA	BYTECNTR
	ADC	MTRKBYTES
	TAX
	LDA	BYTECNTR+1
	ADC	MTRKBYTES+1
	BMI	PNEG
	PHA
	LDA	#' '
	JSR	OUTPUT
	PLA
	JSR	PrDec4Dig
	JMP	RCHKDATA
PNEG
	STA	YHOLD
	STX	TMP
	LDA	#'-'
	JSR	OUTPUT
	LDA	#0
	SEC
	SBC	TMP
	STA	num
	LDA	#0
	SBC	YHOLD
	STA	num+1
	LDA	#'-'
	STA	pad
	LDY	#6
	JSR	PrDec16Lp1

	SEC
	LDA 	#0
	; Bytes read shorter than expected so only check bytes read.
	SBC	BYTECNTR	
	STA	BYTECNTR	; Convert to negative count
	LDA	#0
	SBC	BYTECNTR+1
	STA	BYTECNTR+1
	BNE	RCHKDATALP
	LDA	BYTECNTR
	BNE	RCHKDATALP
	JMP	PCRLF	; No bytes read, don't compare. Just print CRLF
RCHKDATA
	LDA	MTRKBYTES
	STA	BYTECNTR
	LDA	MTRKBYTES+1
	STA	BYTECNTR+1
RCHKDATALP
	LDY	#0
	LDA	#$40
	AND     (TDATA2),Y
	BNE	RERROR	; Data had parity error
	LDA	TDATA2+1
	INY
	LDA     (TDATA2),Y
	DEY
	CMP	(TDATA),Y
	BNE	RERROR	; Miscompare
RCONT
	CLC
	LDA	#2
	ADC	TDATA2	; Inc data pointers
	STA	TDATA2
	BCC	*+4
	INC	TDATA2+1
	INC	TDATA
	BNE	*+4
	INC	TDATA+1
	INC	BYTECNTR
	BNE	*+4
	INC	BYTECNTR+1
	BNE	RCHKDATALP

PRTERRCNT
	LDA	ERRCNT	; Done compare, did we get any errors?
	BNE	PERRCNT
	LDA	ERRCNT+1
	BEQ	PNOERR	; no
PERRCNT
	LDA	#' '
	JSR	OUTPUT
	LDX	ERRCNT
	LDA	ERRCNT+1
	JSR	PrDec4Dig
PNOERR
	LDA	PRTERR
	BEQ	PCRONLY
PCRLF
	JSR	PRINT
	.BYTE	CR,LF,0
	JMP	NEXTTRK
PCRONLY
	LDA	#CR
	JSR	OUTPUT
NEXTTRK
	LDA	SINGLETRK	; Done if single track or at max
	BNE	TRDONE
	LDX	TRK
	INX
	CPX	MAXTRK
	BEQ	TRDONE
	JSR	TNEXT	; seek to next track
JTREAD2
	JMP     TREAD2
TRDONE
	LDA	#$80
	ORA	DDPIA+2	; Unload head
	STA	DDPIA+2
	DEC	PASSCNTR
	BEQ	JMPTOP
	JMP	WRITEOK
JMPTOP
	JSR	ANYKEY
	JMP	TOP

	; Print offset of error and good and bad data
RERROR
	INC	ERRCNT
	BNE	*+4
	INC	ERRCNT+1
	LDA	ERRCNT
	CMP	MAXERR		; Only print first MAXERR errors
	BCS	NOPRT
	LDA	ERRCNT+1
	BNE	NOPRT
	LDA	#' '
	STA	PRTERR
	JSR	OUTPUT
	SEC
	LDA	TDATA
	SBC	#<BUFFER
	TAX
	LDA	TDATA+1
	SBC	#>BUFFER	
	JSR	PrDec4Dig
	LDA	#' '
	JSR	OUTPUT
	LDY	#0
	LDA	(TDATA),Y	; Good value
	JSR 	PHEXA
	LDA	#' '
	JSR	OUTPUT
	INY
	LDA	(TDATA2),Y	; Bad value
	DEY
	JSR 	PHEXA
	LDX	#' '
	LDA	#$40
	AND     (TDATA2),Y
	BEQ	*+4
	LDX	#'P'		; Parity error
	TXA
	JSR	OUTPUT
	JMP	RCONT
NOPRT
	JMP	RCONT
	
INDEXERR
	; Found index before we wrote all our data
	LDA	#$83
	ORA	DDPIA+2	; Unload head, turn off write and erase
	STA	DDPIA+2
	JSR	PRINT
	.BYTE	CR,LF
	.BYTE	'INDEX ACTIVE DURING WRITE, BYTES LEFT: ',0
	SEC
	LDA	#0
	SBC	BYTECNTR
	TAX
	LDA	#0
	SBC	BYTECNTR+1	
	JSR	PDEC
	JSR	PRINT
	.BYTE	CR,LF,0
	JSR	ANYKEY
	JMP	TOP
	
NOTRK
	JSR	INITPIA
	JSR	PRINT
	.BYTE CR,LF,CR,LF, 'ERROR Seeking Track 0',0
	JSR	ANYKEY
	JMP	TOP	

; RESET BUFFER POINTERS
RESPTR	
	LDA	#<BUFFER
	STA	TDATA
	LDA	#>BUFFER
	STA	TDATA+1
	LDA	#<BUFFER2
	STA	TDATA2
	LDA	#>BUFFER2
	STA	TDATA2+1

	RTS

; INIT DISK CONTROLLER PIA
INITPIA	
	LDY	#0
	LDA	#$40
	STY	DDPIA+1	; SELECT DDRA
	STA	DDPIA	; SET PORTA TO ALL INPUTS except PA6
	LDX	#4		; 0000 0100
	STX	DDPIA+1	; SELECT PORTA
	STA	DDPIA    ; SET PB6 HIGH
	STY	DDPIA+3	; SELECT DDRB
	DEY
	STY	DDPIA+2	; SET PORTB TO ALL OUTPUTS
	STX	DDPIA+3	; SELECT PORTB
	STY	DDPIA+2	; SET PORTB OUTPUTS HIGH
	RTS


;SELECT DRIVE PB5 PA6  DRIVE (1-4)
;              0   0	#4
;              0   1	#3
;              1   0	#2
;              1   1	#1

SELDRV
	LDA	DRVNUM
	LSR	A
	TAY
	BCC	*+5
	LDA	#$00
	BIT	$40A9	; This is LDA #$40 if BCC branches
	STA	DDPIA	; This is A/B select in port A
	LDA	DDPIA+2
	ORA	#$20
	CPY	#$01
	BCC	*+4
	AND	#$DF
	STA	DDPIA+2	; This is master select in port B
	RTS


; STEP TO TRACK 0. Carry clear if no error. A modified. TRK set to 0
; if no error.

TZERO
	LDA	MAXTRK	;max num tracks
	ADC	#$08	;plus a few more
	STA	TMP		;MAX times to step before abort
	LDA	DDPIA+2
	AND	#$FB	; 1111 1011
	BNE	TZERO3	; DIR=INWARDS, start with one step away from track 0

TZERO1
	DEC	TMP
	BNE	TZERO5
	SEC
	RTS
TZERO5	
	LDA	#2		; 0000 0010
	BIT	DDPIA	; TEST 'TRK0' PIN
	BNE	TZERO2	; AT TRACK 0
	LDA	#0
	STA	TRK
	JSR	REDWR
	CLC
	RTS

TZERO2	
	LDA	DDPIA+2	; DIR=OUTWARDS (TO TRK0)
	ORA	#$04
TZERO3	
	STA	DDPIA+2	; SET 'DIR' PIN
	JSR	DELAY2
	AND	#$F7	; 1111 0111
	STA	DDPIA+2	; SET 'STEP' PIN LOW
	JSR	DELAY2
	ORA	#8		; 0000 1000
	STA	DDPIA+2	; SET 'STEP' PIN HIGH
	LDX	#32 	; 40 MS
	JSR	DELAY
	BEQ	TZERO1	; ALWAYS

; STEP TO PREVIOUS TRACK
TPREV
        LDA     DDPIA+2 ; DIR=(TO TRK0)
        ORA     #$04
        STA     DDPIA+2 ; SET 'DIR' PIN
        JSR     DELAY2
        AND     #$F7    ; 1111 0111
        STA     DDPIA+2 ; SET 'STEP' PIN LOW
        JSR     DELAY2
        ORA     #8              ; 0000 1000
        STA     DDPIA+2 ; SET 'STEP' PIN HIGH
        DEC	TRK
	JSR	REDWR	; Set reduced write current
        LDX     #32     ; 40 MS
        JMP     DELAY

; STEP TO NEXT TRACK

TNEXT	
	LDA DDPIA+2
	AND	#$FB	; 1111 1011
				; DIR=INWARDS
	STA	DDPIA+2	; SET 'DIR' PIN
	JSR	DELAY2
	AND	#$F7	; 1111 0111
	STA	DDPIA+2	; SET 'STEP' LOW
	JSR	DELAY2
	ORA	#8		; 0000 1000
	STA	DDPIA+2	; SET 'STEP' HIGH
	INC	TRK
	JSR	REDWR	; Set reduced write current
	LDX	#32	    ; 40MS
	JMP	DELAY

	; Set reduced write current
REDWR
	LDA	TRK
	CMP	#43	; Is track >= 43
	LDA	DDPIA+2
	AND	#$BF	; Set low current active
	BCS	SETLO	; Yes
	ORA	#$40	; Set low current inactive
SETLO
	STA	DDPIA+2
	RTS

; DELAY 1.25MS PER LOOP at 1 MHz clock. X,Y modified

DELAY	
	LDY	#$F8
DELAY1	
	DEY
	BNE	DELAY1
	EOR	$FF,X
	DEX
	BNE	DELAY
	RTS

DELAY2	
	JSR	DELAY21
DELAY21	
	RTS


; PRINT IN-LINE STRING. Y and A modified

PRINT	
	PLA
	STA	PTRSTOR
	PLA
	STA	PTRSTOR+1
	LDY	#1
PRINT1	
	LDA	(PTRSTOR),Y
	BEQ	PRINT2
	JSR	OUTPUT
	INY
	BNE	PRINT1
	INC PTRSTOR+1
	BNE PRINT1
PRINT2	
	TYA
	SEC
	ADC	PTRSTOR
	LDY	PTRSTOR
	STA	PTRSTOR
	BCC	PRINT3
	INC	PTRSTOR+1
PRINT3
	CLC
	JMP	(PTRSTOR)

; PRINT HEX WORD (A,X). ONLY CHANGES A

PHEX	
	JSR	PHEXA
	TXA

; PRINT HEX BYTE (A)
PHEXA	
	PHA
	LSR	A
	LSR	A
	LSR	A
	LSR	A
	JSR	PHEXA1
	PLA
PHEXA1	
	AND	#$F
	ORA	#'0'
	CMP	#'9'+1
	BMI	PHEXA2
	CLC
	ADC	#7
PHEXA2	
	JMP	OUTPUT

; PRINT DECIMAL (A)
PDECA	
	TAX
	LDA	#0

; PRINT DECIMAL (A,X). CHANGES A,X,Y. Prints with no leading space

PDEC	
	STX num
	STA num+1
	LDA #0
	STA pad
	LDY #6	; 4 digits max
	JMP PrDec16Lp1

CRLF	
	LDA	#CR
	JSR	OUTPUT
	LDA	#LF
	JMP	OUTPUT

ANYKEY	
	JSR	Get_Chr
	JSR	PRINT
	.BYTE	CR,LF
	.BYTE	'PRESS ANY KEY WHEN READY >',0
	JSR	INKEY
	PHA
	JSR	PRINT
	.BYTE 	CR,LF,0
	PLA
	RTS

DRWMENU
	 JSR PRINT
	.BYTE $D,$A,$D,$A
	.BYTE ' OSI DESTRUCTIVE Disk Test',$D,$A          
	.BYTE '--------------------------',$D,$A          
	.BYTE '1. Test Disk',$D,$A
	.BYTE '2. Test Track',$D,$A
	.BYTE '3. Select Drive',$D,$A      
	.BYTE '4. Set Drive Type',$D,$A      
	.BYTE '5. Set Pattern and passes',$D,$A
        .BYTE '6. Toggle read only',$D,$A
	.BYTE '7. RPM Test',$D,$A 
	.BYTE '8. Status screen',$D,$A 
	.BYTE '9. Exit',$D,$A          
	.BYTE $D,$A
	.BYTE 'Drv=',$0
	LDA DRVNUM
	CLC
	ADC #$41
	JSR OUTPUT
	LDA MAXPAG
	CMP #MAXPAG8
	BEQ DRWMN1
	JSR PRINT
	.BYTE '/5.25 ',0
	BCC DRWMN2
DRWMN1
	JSR PRINT
	.BYTE '/8 ',0
DRWMN2
	LDA PATSEL
	BNE DRWMN3
	JSR PRINT
	.BYTE 'Pattern $',0
	LDA PATVAL
	JSR PHEXA
	JMP DRWMN4
DRWMN3
	JSR PRINT
	.BYTE 'Pattern random',0
DRWMN4
	JSR PRINT
	.BYTE '  Passes ',0
	LDA PASSES
	JSR PDECA
	LDA TESTTYPE
	BEQ NORMTEST
	JSR PRINT
	.BYTE ' Scope test',0
	JMP RWRO
NORMTEST
	JSR PRINT
	.BYTE ' Normal test',0
RWRO
	LDA READONLY
	BEQ RW
	JSR PRINT
	.BYTE ' Read only',0
	JMP PPROMPT
RW
	JSR PRINT
	.BYTE ' R/W',0
PPROMPT
	JSR PRINT
	.BYTE ' > ',0
	RTS

	; Get key from polled key without waiting. Carry clear if no key
	; Key returned in A. X,Y modified
Get_Chr_Polled
	LDA #2		; Ignore shift lock
	LDY #0
Check_Polled_Loop
	STA $DF00	; Select row
	STA $DF00	; In case some time needed for signals to propagate
	LDX $DF00
	BEQ Polled_No_Key	; Jmp if no pressed?
	INY
Polled_No_Key
	ASL
	BNE Check_Polled_Loop
	CPY #1		; If we found other than 1 key pressed assume no
			; key pressed. May not have a keyboard port
	BEQ Polled_Got_Key
	CLC
	RTS
Polled_Got_Key
	JSR $FEED
	SEC
	RTS
	

Get_Chr
FRACIANW  ; read from ACIA no wait	carry clear when no data
	BIT MACHINE
	BMI FRAC1NW
	LDA C2ACIA
	LSR A
	BCC FRAC1NW-1
	LDA C2ACIA+1
	RTS
FRAC1NW
	LDA C1ACIA
	LSR A    
	BCC FRAC1NW-1 
	LDA C1ACIA+1
	RTS

	; Get key from serial or polled keyboard waiting for key.
INKEY
	BIT VIDEO
	BPL *+5		; No
	JMP $FEED	; Polled keyboard
	BIT MACHINE
FRACIA   	 ;read from ACIA carry set on abort return value in A
	BMI FRAC1
FRSER			; read from C3
	LDA C2ACIA
	LSR A    
	BCC FRACIA 
	LDA C2ACIA+1
	CLC      
ACIARET
	RTS
FRAC1			;read from C1
	LDA C1ACIA
	LSR A    
	BCC FRACIA 
	LDA C1ACIA+1
	CLC       
	RTS

	; Check if TX ready bit is set for serial. Carry set if ready
CheckTXReady
	BIT MACHINE
	BMI TOAC1B
	LDA C2ACIA   ;wait for TxEmpty
	LSR A     
	LSR A     
	RTS	; Carry set if TX ready
TOAC1B
	LDA C1ACIA 
	LSR A     
	LSR A     
	RTS	; Carry set if TX ready

	; Write a character to serial or video. A modified
OUTPUT
Put_Chr
TOACIA    
	BIT VIDEO
	BPL TOACIA2	; No, not video system
	JMP VIDOUT
TOACIA2
	PHA
	BIT MACHINE
	BMI TOAC1
TOACIA1	       
	LDA C2ACIA   ;wait for TxEmpty
	LSR A     
	LSR A     
	BCC TOACIA1   
	PLA       
	STA C2ACIA+1 
	RTS       
TOAC1
	LDA C1ACIA 
	LSR A     
	LSR A     
	BCC TOAC1   
	PLA       
	STA C1ACIA+1 
	RTS 

	; Video output routine
VIDOUT
	STY YHOLD 
	CMP #CR
	BEQ VIDCR
	CMP #LF
	BEQ VIDLF
	LDY VIDOFFSET
	STA $D6C0,Y
	INY
	STY VIDOFFSET
VIDRETY
	LDY YHOLD
	RTS
VIDCR
	LDA #0
	STA VIDOFFSET
	RTS	
VIDLF
	LDA (VIDSRC),Y
	STA (VIDDST),Y
	INY
	BNE VIDLF
	INC VIDSRC+1
	INC VIDDST+1
	LDA VIDSRC+1
	CMP #$D7
	BNE VIDLF
	LDA #$D0
	STA VIDSRC+1
	STA VIDDST+1
	LDA #' '
VIDCLR
	STA $D6C0,Y	; Clear last line
	INY
	CPY #$40
	BNE VIDCLR
	INY
	JMP VIDRETY
	
	

; Return an 8 bit "random" number in A
; X modified on return
; From http://forum.6502.org/viewtopic.php?f=2&t=5247 modified for better
; randomness
RAND
	LDA RND+4	; ADD B shifted, 
	SEC		; carry adds value 0x80
	ROR
	ADC RND+1	; add last value (E)
	ADC RND+5  	; add C
	STA RND		; new number
	LDX #4		; move 5 numbers
RPL
	LDA RND,X
	STA RND+1,X	; ..move over 1
	DEX
	BPL RPL		; all moved?
	LDA RND
	RTS

; From https://codebase64.org/doku.php?id=base:24bit_division_24-bit_result
; EXECUTES AN UNSIGNED INTEGER DIVISION OF A 24-BIT DIVIDEND BY A 24-BIT DIVISOR
; THE RESULT GOES TO DIVIDEND AND REMAINDER VARIABLES
;
; VERZ!!! 18-MAR-2017
; A, X, Y modified.

DIV24	LDA #0	        ;PRESET REMAINDER TO 0
	STA REMAINDER
	STA REMAINDER+1
	STA REMAINDER+2
	LDX #24	        ;REPEAT FOR EACH BIT: ...

DIVLOOP	ASL DIVIDEND	;DIVIDEND LB & HB*2, MSB -> CARRY
	ROL DIVIDEND+1	
	ROL DIVIDEND+2
	ROL REMAINDER	;REMAINDER LB & HB * 2 + MSB FROM CARRY
	ROL REMAINDER+1
	ROL REMAINDER+2
	LDA REMAINDER
	SEC
	SBC DIVISOR	;SUBSTRACT DIVISOR TO SEE IF IT FITS IN
	TAY	        ;LB RESULT -> Y, FOR WE MAY NEED IT LATER
	LDA REMAINDER+1
	SBC DIVISOR+1
	STA PZTEMP
	LDA REMAINDER+2
	SBC DIVISOR+2
	BCC SKIP	;IF CARRY=0 THEN DIVISOR DIDN'T FIT IN YET

	STA REMAINDER+2	;ELSE SAVE SUBSTRACTION RESULT AS NEW REMAINDER,
	LDA PZTEMP
	STA REMAINDER+1
	STY REMAINDER	
	INC DIVIDEND 	;AND INCREMENT RESULT CAUSE DIVISOR FIT IN 1 TIMES

SKIP	DEX
	BNE DIVLOOP	
	RTS


; From https://codebase64.org/doku.php?id=base:24bit_multiplication_24bit_product
; Multiply REMAINDER by DIVIDEND with result in DIVIDEND
factor1 = REMAINDER
product = DIVIDEND
MULT24
	lda #$00			; set product to zero
	sta product
	sta product+1
	sta product+2

mloop
	lda factor2			; while factor2 != 0
	bne nz
	lda factor2+1
	bne nz
	lda factor2+2
	bne nz
	rts
nz
	lda factor2			; if factor2 is odd
	and #$01
	beq mskip
	
	lda factor1			; product += factor1
	clc
	adc product
	sta product
	
	lda factor1+1
	adc product+1
	sta product+1
	
	lda factor1+2
	adc product+2
	sta product+2			; end if

mskip
	asl factor1			; << factor1 
	rol factor1+1
	rol factor1+2
	lsr factor2+2			; >> factor2
	ror factor2+1
	ror factor2

	jmp mloop			; end while	

; Status screen for displaying drive inputs
;  Commands:
;  Z- Zero Head   U - Step Up  D - Step Down   E Exit
;  R - Read Trk(not implemented) H - load/unload head 
;  S - Select disk, W - Write
;
LASTPIA = TMP ; need a storage location
STATSCRN
	LDA #$AA
	STA LASTPIA
        JSR INITPIA	; Select disk
        JSR SELDRV
	LDA #$20	; Turn master select back off
	EOR DDPIA+2
	STA DDPIA+2
	; JSR PRINT
	;.BYTE $1B,$48,$D,$A,0 ;escape codes to Home cursor no big deal if terminal doesn't respond correctly

	JSR PRINT
	.BYTE $D,$A,$D,$A,'CMDS:(S)el (H)ead (W)rite Step:(U)p (D)own (Z)ero (E)xit',$D, $A
	.BYTE ' ',$D, $A
	.BYTE 'R T F S R W S I',$D, $A
	.BYTE 'D R A E D R e N',$D, $A
	.BYTE 'Y K U C Y I l D',$D, $A
	.BYTE '1 0 L T 2 T 1 E',$D, $A
	.BYTE '    T     P   X',$D, $A
	.BYTE 0
        ;, $1B, $48,0

STATSCR2
	LDA DDPIA
STATSCR5
	STA LASTPIA
	LDX #$08
STATSCR1
	LSR A
	PHA
	BCC *+3
	LDA #$30
	BIT $31A9
	JSR OUTPUT
	LDA #$20
	JSR OUTPUT
	PLA
	DEX
	BNE STATSCR1
	JSR PRINT
	.BYTE ' TRK ',0
	LDA TRK
	JSR PrDec2Dig
	LDA #$0D
	JSR OUTPUT  ;keep redrawing current line- no LF
STATSCR4
	BIT VIDEO
	BPL STATSER	; No
	JSR Get_Chr_Polled
	JMP *+6
STATSER
	JSR Get_Chr
	BCS STATSCR3
	LDA DDPIA
	CMP LASTPIA
	BEQ STATSCR4  ;no change, no update
	JMP STATSCR5
STATSCR3
	AND #$5F
	;CMP #'R     ; READ TRACK/Show Part
	;BNE *+8
	;JSR VIEWTRK
	;JMP STATSCR2
	CMP #'S
	BNE CHECKLOAD
	LDA #$20
	EOR DDPIA+2
	STA DDPIA+2
	JMP STATSCR2
CHECKLOAD
	CMP #'H
	BNE CHKWRITE
	LDA DDPIA+2	; PRESERVE DISK SEL BIT
	EOR #$80	; TOGGLE HEAD LOAD
	STA DDPIA+2	
	JMP STATSCR2
CHKWRITE
	CMP #'W
	BNE CHKEXIT
	BIT DDPIA	; WAIT 
	BMI *-3	; INDEX PULSE
	BIT DDPIA	; WAIT END OF
	BPL *-3	; INDEX PULSE
	LDA DDPIA+2	; PRESERVE DISK SEL BIT
	EOR #$03	; TOGGLE WRITE AND ERASE ENABLE
	STA DDPIA+2	
	JMP STATSCR2
CHKEXIT
	CMP #'E
	BNE CHKUP
	LDA DDPIA+2	; PRESERVE DISK SEL BIT
	ORA #$A3	; TURN OFF HEAD LOAD, SELECT, AND WRITE
	STA DDPIA+2	
	JMP TOP
CHKUP
	PHA
	LDA #$20
	BIT DDPIA+2
	PLA
	BEQ JSTATSCR2	; Can't move head if drive not selected

	CMP #'U
	BNE *+8
	JSR TNEXT	; STEP TO NEXT TRACK
	JMP STATSCR2
	CMP #'D
	BNE *+8
	JSR TPREV   ; STEP TO PREV TRACK
JSTATSCR2
	JMP STATSCR2
	CMP #'Z
	BNE *+5
	JSR TZERO    ; STEP TO TRACK 0
	JMP STATSCR2
	 

;VIEWTRK ;placeholder for View Track function	
;	RTS	
BUFFER	=	*
*=*+BYTES8 ;space for track buffer
BUFFER2	=	*
;space for track buffer. We may write more data than this but will not
;use the extra data written. Don't put anything that can't be overwritten
;after this
*=*+[BYTES8+BYTES8+2] 

;*=*+[MAXPAG8*2*256] ;space for track buffer

.END

