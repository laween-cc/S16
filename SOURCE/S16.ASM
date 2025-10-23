[BITS 16]
ORG 0500H

START:
    CLI ; Disable interrupts for now

    XOR AX, AX
    MOV DS, AX
    MOV ES, AX

    MOV SS, AX
    MOV SP, STACK

    MOV BYTE [BOOTDRIVE], DL ; ASSUMING BOOT SECTOR PUT BOOT DRIVE INTO DL!  

    ; Copy the bios parameter block
    MOV SI, 7C00H
    MOV DI, BIOSBLOCK
    MOV CX, 31
    CLD ; Clear direction flag

    REP MOVSW

    ; Setup disk services
    MOV WORD [20H * 4], DISK
    MOV WORD [20H * 4 + 2], 0000H
    
    ; Setup video services
    MOV WORD [24H * 4], VIDEO
    MOV WORD [24H * 4 + 2], 0000H

    ; Set current directory to root (0000h)
    MOV WORD [CURRENTDIR], 0

    ; Root start
    ; Reserved logical sectors + (2 * logical sectors per fat)    
    MOV AL, [BIOSBLOCK + 00EH]
    MOV CL, [BIOSBLOCK + 016H]
    ADD CL, CL
    ADD CL, AL
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

    MOV SI, ERCACHE ; In case a error happens
    
    ; Read the root directory into memory
    MOV AH, 02H
    ; MOV DL, [BOOTDRIVE]
    MOV DH, [ROOTSECTORS]
    ; MOV CL, [ROOTSECTOR]
    ; XOR CH, CH
    MOV BX, ROOTCACHE
    INT 20H

    JC ERROR

    ; Read the first fat table into memory
    MOV AH, 02H
    MOV DH, [BIOSBLOCK + 016H]
    MOV CL, [BIOSBLOCK + 00EH]
    MOV BX, FATCACHE
    INT 20H

    JC ERROR

    JMP $
ERROR:
    ; Parameters:
    ; ds:si = memory buffer in ACSII and null terminated
    ; Return:
    ; nothing

    ; Clear the screen
    MOV AX, 0003H
    INT 10H

    ; Write the error mesasge to screen
    MOV BX, 0007H
    MOV AH, 0E3H
    
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

VIDEO:
    ; Parameters:
    ; ah = service
    ; ...
    ; Return:
    ; ...

    CMP AH, 0E3H
    JE PRINT

    IRET

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


FSDISK:
    ; Parameters:
    ; ah = service
    ; ...
    ; Return:
    ; ...

    IRET

DISK:
    ; Parameters:
    ; ah = service
    ; ...
    ; Return:
    ; ...

    CMP AH, 02H ; Does use scratch memory
    JE RWSTART
    CMP AH, 03H ; Does use scratch memory
    JE RWSTART
    CMP AH, 04H ; Doesn't use scratch memory
    JE LBATOCHS

    IRET
RWSTART: ; Read / write start
    ; Parameters:
    ; dl = drive number (0 - 255)
    ; dh = sectors to read / write (1 - 128)
    ; cx = logical starting sector (0 - 65535)
    ; es:bx = memory buffer
    ; Return:
    ; CF = 0 = success
    ; CF = 1 = failure
    ; ah = bios status

    MOV BYTE [WORDMEMORY], AH ; Preserve bios call

    PUSH ES
    PUSH BX
    PUSH AX
    PUSH DX
    PUSH CX
    PUSH BP

    PUSHF ; Gotta push the flags to restore the interrupt flag

    ; Fix 64KiB segment boundary
    CALL FIXSEGMENT

    ; LBA to CHS
    MOV BYTE [WORDMEMORY + 1], DH; Preserve sectors to read
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
    MOV AH, [WORDMEMORY] ; Bios call 
    MOV AL, [WORDMEMORY + 1] ; Sectors to read
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
    ; dl = drive number (0 - 255)
    ; cx = logical starting sector (0 - 65535)
    ; Return:
    ; CF = 0 = success
    ; CF = 1 = failed to get drive parameters via int 13,8h?
    ; ah = bios status
    ; ch = cylinder
    ; cl = bits 7 - 6 = cylinder
    ; cl = bits 0 - 5 = sector
    ; dh = head 

    PUSH ES
    PUSH DI
    PUSH BP
    PUSH BX
    PUSH AX
    PUSH DX

    MOV BP, CX ; Preserve the LBA
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

WORDMEMORY: DW 0 ; Scratch memory (reminder: don't blindly use this)
STACK: EQU 1500H ; 2KiB above the kernel

; Data area
BOOTDRIVE: EQU 1500H ; 1 byte
ROOTSECTOR: EQU 1501H ; 1 byte
ROOTSECTORS: EQU 1502H ; 1 byte
FIRSTDATA: EQU 1503H ; 1 byte
CURRENTDIR: EQU 1504H ; 2 bytes
BIOSBLOCK: EQU 1506H ; 62 bytes
ROOTCACHE: EQU 1544H ; 16KiB
FATCACHE: EQU 5544H ; 6KiB

; Error messages
ERMAIN: DB "KERNEL ERROR!", 0AH, 0DH, 0
ERCACHE: DB "FAILED TO CACHE ROOT OR FAT TABLE??", 0
ERHELP: DB 0AH, 0DH, "PRESS ANY KEY TO REBOOT..", 0