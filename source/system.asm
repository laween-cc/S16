BITS 16
ORG 0500H

START:
    CLI ; Disable interrupts for now

    XOR AX, AX
    MOV DS, AX
    MOV ES, AX

    MOV SS, AX
    MOV SP, TEMPSTACK

    MOV BYTE [BOOTDRIVE], DL ; ASSUMING BOOT SECTOR PUT BOOT DRIVE INTO DL!  

    ; Copy the bios parameter block
    MOV SI, 7C00H
    MOV DI, BIOSBLOCK
    MOV CX, 31
    CLD ; Clear direction flag

    REP MOVSW

    ; Setup disk services (int 20h)
    MOV WORD [20H * 4], DISK
    MOV WORD [20H * 4 + 2], 0000H
    
    ; Setup file system disk services (int 21h)

    ; Setup a periodic tick handler (int 22h)

    ; Set up a memory manager (int 23h)

    ; Setup a simple print service (int 24h)
    MOV WORD [24H * 4], PRINT
    MOV WORD [24H * 4 + 2], 0000H

    ; Set current directory to root (0000h)
    MOV WORD [CURRENTDIR], 0

    ; Root start
    ; 1 + (2 * logical sectors per fat) ; assuming reserved sectors is 1    
    MOV CL, [BIOSBLOCK + 016H]
    ADD CL, CL
    INC CL
    MOV BYTE [ROOTSECTOR], CL

    ; Root sectors
    ; Root directory entries * 32 / 512
    MOV AX, [BIOSBLOCK + 011H]
    SHL AX, 5
    SHR AX, 9
    MOV BYTE [ROOTSECTORS], AL

    ; First data sector
    ; Root start + root sectors
    ADD AL, CL
    MOV BYTE [FIRSTDATA], AL

    JMP $
ERROR:
    ; Parameters:
    ; ds:si = memory buffer in ACSII and null terminated
    ; Return:
    ; nothing

    ; Clear the screen and set video mode to 80x25
    MOV AX, 0003H
    INT 10H

    ; Write the error mesasge to screen
    MOV BX, 0007H
    
    PUSH SI
    MOV SI, ERMAIN
    INT 24H
    POP SI
    INT 24H
    MOV SI, ERHELP
    INT 24H

    ; Wait for key press and then cold reboot
    STI ; Ensure interrupts are enabled
    XOR AH, AH
    INT 16H
    INT 19H

PRINT:
    ; Parameters:
    ; ds:si = memory buffer in ACSII and null terminated
    ; bh = page number
    ; bl = foreground pixel color
    ; Return:
    ; nothing

    PUSH AX
    MOV AH, 0EH
PRINTBYTE:
    LODSB
    CMP AL, 0 ; Null terminator
    JE PRINTEND
    INT 10H
    JMP PRINTBYTE
PRINTEND:
    POP AX
    IRET


DISK:
    ; Parameters:
    ; ah = service
    ; ...
    ; Return:
    ; ...

    CMP AH, 02H
    JE RWSTART
    CMP AH, 03H
    JE RWSTART
    CMP AH, 04H
    JE LBATOCHS

    IRET
RWSTART: ; Read / write start
    ; Parameters:
    ; al = sectors to read / write (1 - 128)
    ; dx = logical starting sector (0 - 65535)
    ; es:bx = memory buffer
    ; Return:
    ; CF = 0 = success
    ; CF = 1 = failure
    ; ah = bios status

    PUSH ES
    PUSH BX
    PUSH AX
    PUSH DX
    PUSH CX
    PUSH BP
    PUSH DS
    
    PUSHF ; Gotta push the flags to restore the interrupt flag

    XOR BP, BP
    MOV DS, BP

    MOV BYTE [SCRATCHMEM], AH ; Preserve bios call
    MOV BYTE [SCRATCHMEM + 1], AL; Preserve sectors to read

    ; Fix 64KiB segment boundary
    CALL FIXSEGMENT

    ; LBA to CHS
    MOV AL, [BOOTDRIVE]
    MOV AH, 04H
    INT 20H

    JC RWEND

    ; ch = cylinder
    ; cl = bits 7 - 6 = cylinder
    ; cl = bits 0 - 5 = sector
    ; dh = head 

    MOV BP, 3 ; Retry counter
RWBIOS:
    CLI ; Disable interrupts for safer disk access
    MOV AH, [SCRATCHMEM] ; Bios call 
    MOV AL, [SCRATCHMEM + 1] ; Sectors to read
    INT 13H

    JNC RWEND

    ; Reset disk and retry
    DEC BP
    JZ RWEND ; bios status is in "ah" and CF is set

    XOR AH, AH ; Reset disk
    INT 13H

    JC RWEND ; Failed to reset disk?

    ; Wait ~110ms for floppies and slower storage devices to resync
    ; Bios vendor must have tick timer at 0040:006CH, otherwise will halt forever

    STI ; Interrupts need to be enabled for this part    
    MOV AX, [046CH]
    ADD AX, 2 ; 2 ticks (~110ms)
RWDELAY:
    CMP WORD [046CH], AX
    JL RWDELAY

    JMP RWBIOS ; Retry
RWEND:
    ; Restore the interrupt flag
    POP DX
    TEST DX, 100H ; 0000000100000000B ; Check the interrupt flag
    JZ RWNOIF
    STI ; Enable interrupt flag
RWNOIF: ; Already disabled interrupt

    POP DS
    POP BP
    POP CX
    POP DX
    POP BX ; AX
    MOV AL, BL ; Restore al
    POP BX
    POP ES
    IRET

LBATOCHS:
    ; Parameters:
    ; al = drive number (0 - 255)
    ; dx = logical starting sector (0 - 65535)
    ; Return:
    ; CF = 0 = success
    ; CF = 1 = failed to get drive parameters via int 13,8h?
    ; ah = bios status
    ; ch = cylinder
    ; cl = bits 7 - 6 = cylinder
    ; cl = bits 0 - 5 = sector
    ; dh = head
    ; Note: on failure returned registers may be clobbered EXCEPT for "ah"

    PUSH ES
    PUSH DI
    PUSH BP
    PUSH BX
    PUSH AX
    PUSH DX

    MOV BP, DX ; Preserve the LBA
    MOV DL, AL
    MOV AH, 08H
    INT 13H

    JC LBACHSEND

    INC DH ; We need number of heads to start from 1
    AND CL, 3FH ; 00111111B ; Zero out bits 7 - 6, because we only need the sectors per track

    ; Cylinder
    ; LBA / (HPC * SPT) 
    MOV AL, DH
    XOR AH, AH
    MUL CL

    XCHG BP, AX
    XOR DX, DX
    DIV BP
    MOV BP, AX

    ; Head
    ; LBA % (HPC * SPT) / SPT
    MOV AX, DX
    DIV CL

    ; Sector
    ; LBA % (HPC * SPT) % SPT + 1
    INC AH

    MOV CX, BP ; Put cylinder in the right place
    SHL CL, 6 ; Shifts bits 0 - 1 to 7 - 6 and zero bits 0 - 5
    ; AND AH, 3FH ; 00111111B 
    OR CL, AH ; Combine the bits

    CLC
    XOR AH, AH ; No error
LBACHSEND:
    POP DX
    MOV DH, AL ; Put head in the right place
    POP BX ; AX
    MOV AL, BL ; Restore al
    POP BX
    POP BP
    POP DI
    POP ES
    IRET

FIXSEGMENT:
    ; Parameters:
    ; es:bx = memory address
    ; Return:
    ; es = new segment
    ; bx = new offset
    ; Fixes 64KiB boundary issues

    PUSH AX
    PUSH DX
    
    ; New segment = segment + (bx << 4)
    ; New offset = offset & 000Fh
    MOV AX, BX
    SHR AX, 4
    MOV DX, ES
    ADD DX, AX
    MOV ES, DX
    AND BX, 000FH

    POP DX
    POP AX
    RET

TEMPSTACK: EQU 0FFFH 
PROGRAMSEGMENT: EQU 00D5H
SCRATCHMEM: EQU 0B00H ; 1KiB

; Data area
BOOTDRIVE: EQU 0D00H ; 1 byte
ROOTSECTOR: EQU 0D01H ; 1 byte
ROOTSECTORS: EQU 0D02H ; 1 byte
FIRSTDATA: EQU 0D03H ; 1 byte
CURRENTDIR: EQU 0D04H ; 2 bytes
BIOSBLOCK: EQU 0D06H ; 62 bytes

; Error messages
ERMAIN: DB "ERROR!", 0AH, 0DH, 0
ERHELP: DB 0AH, 0DH, "PRESS ANY KEY TO REBOOT..", 0
