[BITS 16]
ORG 0500H

START:
    CLI

    XOR AX, AX
    MOV DS, AX
    MOV ES, AX

    MOV SS, AX
    MOV SP, STACK

    MOV BYTE [BOOTDRIVE], DL


DISK:
    ; Parameters:
    ; ah = service
    ; ...
    ; Return:
    ; CF = 0 = success
    ; CF = 1 = failure 
    ; ah = bios status
    ; ah = D4 = invalid service

    CMP AH, 02H ; Does use scratch memory
    JE READ
    CMP AH, 03H ; Does use scratch memory
    JE WRITE
    CMP AH, 04H ; Doesn't use scratch memory
    JE LBSTOCHS

    MOV AH, D4H
    STC
    IRET
READ:
WRITE:
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

    IRET

LBSTOCHS:
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
    PUSH DX
    PUSH BX
    PUSH AX

    MOV BP, CX ; Preserve the LBA
    MOV AH, 08H
    INT 13H


    POP AX
    POP BX
    POP DX
    POP BP
    POP DI
    POP ES

    IRET

WORDMEMORY: DW 0 ; Scratch memory (reminder: don't blindly use this)
STACK: EQU 1500H ; 2KiB above the kernel
BOOTDRIVE: EQU 1500H 