; ---------------------------------------------------------------------------
; stubs.inc - Win32 stand-ins that let terminal.asm run on Linux.
;
; build.sh appends this file to a copy of terminal.asm (minus its `extern`
; lines), so the real Windows code runs against these functions. Every stub
; follows the Microsoft x64 ABI, and each one:
;   - reports "!!MISALIGNED" when rsp is not 16n+8 at entry,
;   - clobbers rcx, rdx, r8-r11 on return,
;   - writes rcx/rdx/r8/r9 into the caller's home slots, the way a real
;     callee may (build with -DNOSPILL to switch that off),
;   - logs what matters for the tests to stderr (fd 2).
; Console output goes to stdout (fd 1) and into a character grid that the
; test can dump.
;
; The simulated world is described by environment variables of this process:
;   W_FILES   directory listing, "name[:D|:size]|name..." (also drives
;             GetFileAttributesA); "." and ".." are added automatically
;   W_ENV_X   value of the Windows environment variable X
;   W_AUTOEXEC, W_TYPE   file contents returned by ReadFile
;   W_ROWS, W_COLS       console size (default 25 x 80)
;   W_ROW0               row where the cursor starts (default 0)
;   W_NOTCONSOLE=1       stdin is not a console (GetConsoleMode/ReadConsoleInput fail)
;   W_CTRLC_IN_CHILD=1   deliver Ctrl+C to the shell while a child runs
;   W_LOG=cfadk...       extra log classes: c cursor, f fill, a attribute,
;                        d find, k console mode, w console writes
;   W_DUMP=1             dump the screen grid at end of input
; Keys come from stdin bytes:
;   01 Tab  02 Up  03 Down  04 Enter  05 Left  06 Right  07 Home  0b End
;   08 Backspace  7f Delete  18 Ctrl+C  0e N repeat count for the next key
;   11/12/13 console control event 0/1/2 (Ctrl+C, Ctrl+Break, close)
;   1a dump the screen now; any other byte is a typed character.
; ---------------------------------------------------------------------------
%define MAXCOLS 200
%define MAXROWS 100

section .data
    misal_msg   db "!!MISALIGNED call to stub at entry: ", 0
    nl_ch       db 10
    hexdig      db "0123456789abcdef"
    eofmsg      db "[EOF]", 10, 0
    scr_pfx     db "SCR|", 0
    scr_begin   db "SCR-BEGIN", 10, 0
    scr_end     db "SCR-END", 10, 0
    n_dot       db ".", 0
    n_dd        db "..", 0
    modname     db "C:\app\t.exe", 0
    sysdir      db "C:\WINDOWS\system32", 0
    key_w_log   db "W_LOG", 0
    key_w_files db "W_FILES", 0
    key_w_auto  db "W_AUTOEXEC", 0
    key_w_type  db "W_TYPE", 0
    key_w_rows  db "W_ROWS", 0
    key_w_cols  db "W_COLS", 0
    key_w_row0  db "W_ROW0", 0
    key_w_notc  db "W_NOTCONSOLE", 0
    key_w_cic   db "W_CTRLC_IN_CHILD", 0
    key_w_dump  db "W_DUMP", 0
    key_w_cwd   db "W_CWD", 0
    envprefix   db "W_ENV_", 0
    cwd_init    db "C:\t", 0
    envblock    db "PATH=x", 0, "=C:=C:\t", 0, "USERNAME=bob", 0, 0
    str_null    db "(null)", 0
    str_err     db "ERR", 0
    str_crlf    db 13, 10, 0

section .bss
    envp_ptr    resq 1
    logflags    resb 256
    hexbuf      resb 24
    keybuf      resb 320
    kbuf        resb 8
    screen      resb MAXCOLS * MAXROWS
    rows        resd 1
    cols        resd 1
    cur_x       resd 1
    cur_y       resd 1
    scrolls     resd 1
    cur_attr    resw 1
    con_mode    resd 1
    ctrl_handler resq 1
    last_err    resd 1
    file_ctr    resd 1
    pending_up  resd 1
    up_vk       resd 1
    up_ch       resd 1
    repeat_next resd 1
    notconsole  resb 1
    dump_at_eof resb 1
    ctrlc_child resb 1
    wcwd         resb 300
    find_stage  resd 1
    find_ptr    resq 1
    find_pat    resb 300
    cand_name   resb 300
    cand_attr   resd 1
    cand_size   resq 1
    files_env   resq 1
    type_pending resd 1
    auto_pending resd 1
    dumpbuf     resb MAXCOLS + 8

section .text

; ---- logging helpers (not MS ABI; they preserve every register) ----
; r10 = NUL terminated string -> fd 2
lg_str:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r11
    mov rsi, r10
    xor edx, edx
.l: cmp byte [rsi+rdx], 0
    je .d
    inc rdx
    jmp .l
.d: test edx, edx
    jz .o
    mov eax, 1
    mov edi, 2
    syscall
.o: pop r11
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; r10 = value -> "0x%x" on fd 2
lg_hex:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    lea rsi, [rel hexbuf]
    mov byte [rsi], '0'
    mov byte [rsi+1], 'x'
    mov ecx, 16
    mov rax, r10
    xor r11d, r11d          ; output length
    xor edx, edx            ; seen a non-zero digit
.l: mov rdi, rax
    shr rdi, 60
    shl rax, 4
    test edx, edx
    jnz .emit
    test edi, edi
    jnz .first
    cmp ecx, 1
    jne .skip
.first:
    mov edx, 1
.emit:
    lea r10, [rel hexdig]
    mov dil, [r10+rdi]
    mov [rsi+2+r11], dil
    inc r11d
.skip:
    dec ecx
    jnz .l
    mov byte [rsi+2+r11], 0
    mov r10, rsi
    call lg_str
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; r10 = value -> decimal on fd 2
lg_dec:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    lea rsi, [rel hexbuf+22]
    mov byte [rsi], 0
    mov rax, r10
    mov ecx, 10
.l: xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .l
    mov r10, rsi
    call lg_str
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; ---- stub entry/exit macros ----
%macro ENTRY 1
%1:
    test spl, 8
    jnz %%ok
    push r10
    lea r10, [rel misal_msg]
    call lg_str
    lea r10, [rel %%nm]
    call lg_str
    lea r10, [rel nl_ch]
    call lg_str
    pop r10
    jmp %%ok
%defstr %%nmstr %1
%%nm: db %%nmstr, 0
%%ok:
%ifndef NOSPILL
    mov [rsp+8], rcx
    mov [rsp+16], rdx
    mov [rsp+24], r8
    mov [rsp+32], r9
%endif
%endmacro

%macro RETC 0
    mov rcx, 0xBADBADBADBAD0001
    mov rdx, 0xBADBADBADBAD0002
    mov r8,  0xBADBADBADBAD0003
    mov r9,  0xBADBADBADBAD0004
    mov r10, 0xBADBADBADBAD0005
    mov r11, 0xBADBADBADBAD0006
    ret
%endmacro

%macro LOGS 1
    push r10
    lea r10, [rel %%s]
    call lg_str
    pop r10
    jmp %%e
%%s: db %1, 0
%%e:
%endmacro

; log a register: LOGX reg (hex) / LOGD reg (decimal) / LOGP reg (string or (null))
%macro LOGX 1
    push r10
    mov r10, %1
    call lg_hex
    pop r10
%endmacro
%macro LOGD 1
    push r10
    mov r10, %1
    call lg_dec
    pop r10
%endmacro
%macro LOGP 1
    push r10
    mov r10, %1
    test r10, r10
    jnz %%ok
    lea r10, [rel str_null]
%%ok:
    call lg_str
    pop r10
%endmacro

; ---- environment lookup: rdi = "KEY" -> rax = value pointer or 0 ----
w_env_find:
    push rbx
    push rcx
    push rsi
    mov rbx, [rel envp_ptr]
.next:
    mov rsi, [rbx]
    test rsi, rsi
    jz .none
    xor ecx, ecx
.cmp:
    mov al, [rdi+rcx]
    test al, al
    jz .keyend
    cmp al, [rsi+rcx]
    jne .skip
    inc ecx
    jmp .cmp
.keyend:
    cmp byte [rsi+rcx], '='
    jne .skip
    lea rax, [rsi+rcx+1]
    jmp .ret
.skip:
    add rbx, 8
    jmp .next
.none:
    xor eax, eax
.ret:
    pop rsi
    pop rcx
    pop rbx
    ret

; rsi = decimal text (NUL ended) -> rax
w_atoi:
    xor eax, eax
.l: movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .d
    imul rax, rax, 10
    add rax, rcx
    inc rsi
    jmp .l
.d: ret

; case insensitive glob. rsi = pattern, rdi = name -> eax = 1 on match
w_glob:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    xor r10d, r10d              ; pattern position after the last '*'
    xor r11d, r11d              ; name position that star is trying
.loop:
    movzx ecx, byte [rsi]
    movzx eax, byte [rdi]
    cmp cl, '*'
    jne .notstar
    inc rsi
    cmp byte [rsi], 0
    je .yes
    mov r10, rsi
    mov r11, rdi
    jmp .loop
.notstar:
    test cl, cl
    jnz .more
    test al, al
    jz .yes
    jmp .mismatch
.more:
    test al, al
    jz .no
    cmp cl, '?'
    je .adv
    mov edx, ecx
    mov ebx, eax
    cmp dl, 'A'
    jb .l1
    cmp dl, 'Z'
    ja .l1
    or dl, 0x20
.l1:
    cmp bl, 'A'
    jb .l2
    cmp bl, 'Z'
    ja .l2
    or bl, 0x20
.l2:
    cmp dl, bl
    jne .mismatch
.adv:
    inc rsi
    inc rdi
    jmp .loop
.mismatch:
    test r10, r10
    jz .no
    inc r11
    cmp byte [r11-1], 0
    je .no
    mov rdi, r11
    mov rsi, r10
    jmp .loop
.yes:
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; case insensitive equality. rsi, rdi -> eax = 1 when equal
w_streqi:
    push rcx
    push rdx
    push rsi
    push rdi
.l: movzx eax, byte [rsi]
    movzx ecx, byte [rdi]
    cmp al, 'A'
    jb .a
    cmp al, 'Z'
    ja .a
    or al, 0x20
.a: cmp cl, 'A'
    jb .b
    cmp cl, 'Z'
    ja .b
    or cl, 0x20
.b: cmp al, cl
    jne .no
    test al, al
    jz .yes
    inc rsi
    inc rdi
    jmp .l
.yes:
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; Parse the next W_FILES entry at [find_ptr] into cand_name/cand_attr/cand_size.
; eax = 1 when an entry was read, 0 at the end of the list.
w_next_entry:
    push rcx
    push rdx
    push rsi
    push rdi
    mov rsi, [rel find_ptr]
    test rsi, rsi
    jz .none
    cmp byte [rsi], 0
    je .none
    lea rdi, [rel cand_name]
.nm:
    mov al, [rsi]
    test al, al
    jz .nm_end
    cmp al, '|'
    je .nm_end
    cmp al, ':'
    je .nm_end
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .nm
.nm_end:
    mov byte [rdi], 0
    mov dword [rel cand_attr], 0x20
    mov qword [rel cand_size], 0
    cmp byte [rsi], ':'
    jne .tail
    inc rsi
    cmp byte [rsi], 'D'
    jne .size
    mov dword [rel cand_attr], 0x10
    inc rsi
    jmp .tail
.size:
    call w_atoi
    mov [rel cand_size], rax
.tail:
    cmp byte [rsi], '|'
    jne .store
    inc rsi
.store:
    mov [rel find_ptr], rsi
    mov eax, 1
    jmp .out
.none:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; Advance the simulated search. rdx = WIN32_FIND_DATA. eax = 1 when filled.
w_find_adv:
    push rbx
    push rsi
    push rdi
    push r12
    mov r12, rdx
.try:
    mov eax, [rel find_stage]
    cmp eax, 2
    jae .list
    inc dword [rel find_stage]
    lea rsi, [rel cand_name]
    lea rdi, [rel n_dot]
    test eax, eax
    jz .syn
    lea rdi, [rel n_dd]
.syn:
    xor ebx, ebx
.syn_cp:
    mov al, [rdi+rbx]
    mov [rsi+rbx], al
    inc ebx
    test al, al
    jnz .syn_cp
    mov dword [rel cand_attr], 0x10
    mov qword [rel cand_size], 0
    jmp .match
.list:
    call w_next_entry
    test eax, eax
    jz .end
.match:
    lea rsi, [rel find_pat]
    lea rdi, [rel cand_name]
    call w_glob
    test eax, eax
    jz .try
    mov eax, [rel cand_attr]
    mov [r12], eax
    mov rax, [rel cand_size]
    mov [r12+32], eax
    shr rax, 32
    mov [r12+28], eax
    lea rsi, [rel cand_name]
    lea rdi, [r12+44]
.nm:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .nm
    mov eax, 1
    jmp .out
.end:
    xor eax, eax
.out:
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

; ---- console grid ----
; scroll the grid up one line
con_scroll:
    push rcx
    push rsi
    push rdi
    lea rdi, [rel screen]
    lea rsi, [rdi+MAXCOLS]
    mov eax, [rel rows]
    dec eax
    imul ecx, eax, MAXCOLS
    rep movsb
    mov ecx, MAXCOLS
    mov al, ' '
    rep stosb
    inc dword [rel scrolls]
    pop rdi
    pop rsi
    pop rcx
    ret

con_lf:
    inc dword [rel cur_y]
    mov eax, [rel cur_y]
    cmp eax, [rel rows]
    jb .ok
    dec dword [rel cur_y]
    call con_scroll
.ok:
    ret

; rsi = bytes, rdx = count
con_write:
    push rax
    push rcx
    push rbx
.l: test rdx, rdx
    jz .d
    movzx eax, byte [rsi]
    inc rsi
    dec rdx
    cmp al, 13
    jne .n1
    mov dword [rel cur_x], 0
    jmp .l
.n1:
    cmp al, 10
    jne .put
    mov dword [rel cur_x], 0
    call con_lf
    jmp .l
.put:
    mov ecx, [rel cur_y]
    imul ecx, MAXCOLS
    add ecx, [rel cur_x]
    lea rbx, [rel screen]
    mov [rbx+rcx], al
    inc dword [rel cur_x]
    mov eax, [rel cur_x]
    cmp eax, [rel cols]
    jb .l
    mov dword [rel cur_x], 0
    call con_lf
    jmp .l
.d: pop rbx
    pop rcx
    pop rax
    ret

; write the grid to fd 2, one "SCR|row" line per row, trailing blanks trimmed
dump_screen:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    push r12
    lea r10, [rel scr_begin]
    call lg_str
    xor r12d, r12d
.row:
    cmp r12d, [rel rows]
    jae .done
    lea r10, [rel scr_pfx]
    call lg_str
    imul eax, r12d, MAXCOLS
    lea rsi, [rel screen]
    add rsi, rax
    mov ecx, [rel cols]
.trim:
    test ecx, ecx
    jz .emit
    cmp byte [rsi+rcx-1], ' '
    jne .emit
    dec ecx
    jmp .trim
.emit:
    lea rdi, [rel dumpbuf]
    mov edx, ecx
    push rcx
    rep movsb
    pop rcx
    mov byte [rdi], 10
    inc edx
    lea rsi, [rel dumpbuf]
    mov eax, 1
    mov edi, 2
    syscall
    inc r12d
    jmp .row
.done:
    lea r10, [rel scr_end]
    call lg_str
    pop r12
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; =============================== Win32 stubs ===============================

ENTRY GetStdHandle
    mov eax, 0x10               ; stdin
    cmp ecx, -10
    je .r
    mov eax, 0x11               ; stdout / stderr
.r: RETC

ENTRY SetConsoleTitleA
    mov eax, 1
    RETC

ENTRY GetConsoleMode
    cmp byte [rel notconsole], 0
    jne .fail
    mov eax, [rel con_mode]
    mov [rdx], eax
    mov eax, 1
    RETC
.fail:
    mov dword [rel last_err], 6
    xor eax, eax
    RETC

ENTRY SetConsoleMode
    mov [rel con_mode], edx
    cmp byte [rel logflags + 'k'], 0
    je .q
    LOGS "[SetConsoleMode "
    mov r10d, edx
    call lg_hex
    LOGS `]\n`
.q: mov eax, 1
    RETC

ENTRY SetConsoleCtrlHandler
    mov [rel ctrl_handler], rcx
    mov eax, 1
    RETC

ENTRY SetConsoleTextAttribute
    mov [rel cur_attr], dx
    cmp byte [rel logflags + 'a'], 0
    je .q
    LOGS "[attr "
    movzx r10, dx
    call lg_hex
    LOGS `]\n`
.q: mov eax, 1
    RETC

ENTRY GetConsoleScreenBufferInfo
    mov eax, [rel cols]
    mov ecx, [rel rows]
    mov [rdx], ax               ; dwSize.X
    mov [rdx+2], cx             ; dwSize.Y
    mov eax, [rel cur_x]
    mov [rdx+4], ax
    mov eax, [rel cur_y]
    mov [rdx+6], ax
    movzx eax, word [rel cur_attr]
    mov [rdx+8], ax
    mov word [rdx+10], 0        ; srWindow
    mov word [rdx+12], 0
    mov eax, [rel cols]
    dec eax
    mov [rdx+14], ax
    mov eax, [rel rows]
    dec eax
    mov [rdx+16], ax
    mov eax, 1
    RETC

ENTRY SetConsoleCursorPosition
    movzx eax, dx               ; X
    shr edx, 16                 ; Y
    cmp eax, [rel cols]
    jae .bad
    cmp edx, [rel rows]
    jae .bad
    mov [rel cur_x], eax
    mov [rel cur_y], edx
    cmp byte [rel logflags + 'c'], 0
    je .q
    LOGS "[cursor "
    mov r10d, eax
    call lg_dec
    LOGS ","
    mov r10d, edx
    call lg_dec
    LOGS `]\n`
.q: mov eax, 1
    RETC
.bad:
    LOGS `[cursor FAILED]\n`
    mov dword [rel last_err], 87
    xor eax, eax
    RETC

; (h, char dl, length r8d, COORD r9d, *written [rsp+40])
ENTRY FillConsoleOutputCharacterA
    mov r10, [rsp+40]
    mov [r10], r8d
    cmp byte [rel logflags + 'f'], 0
    je .go
    LOGS "[fill "
    movzx r10, r9w
    call lg_dec
    LOGS ","
    mov r10d, r9d
    shr r10d, 16
    call lg_dec
    LOGS " n="
    mov r10d, r8d
    call lg_dec
    LOGS `]\n`
.go:
    movzx eax, r9w              ; x
    mov r10d, r9d
    shr r10d, 16                ; y
    mov r11d, r8d               ; count
.cell:
    test r11d, r11d
    jz .fin
    cmp r10d, [rel rows]
    jae .fin
    imul ecx, r10d, MAXCOLS
    add ecx, eax
    push rax
    lea rax, [rel screen]
    mov [rax+rcx], dl
    pop rax
    inc eax
    cmp eax, [rel cols]
    jb .nx
    xor eax, eax
    inc r10d
.nx:
    dec r11d
    jmp .cell
.fin:
    mov eax, 1
    RETC

ENTRY FillConsoleOutputAttribute
    mov eax, 1
    RETC

ENTRY GetCurrentDirectoryA
    push rsi
    push rdi
    lea rsi, [rel wcwd]
    xor eax, eax
.len:
    cmp byte [rsi+rax], 0
    je .got
    inc eax
    jmp .len
.got:
    cmp eax, ecx
    jb .fits
    inc eax                     ; buffer too small: required size, nothing copied
    jmp .out
.fits:
    mov rdi, rdx
    mov ecx, eax
    inc ecx
    rep movsb
.out:
    pop rdi
    pop rsi
    RETC

ENTRY SetCurrentDirectoryA
    LOGS "[SetCurrentDirectory "
    LOGP rcx
    LOGS `]\n`
    push rsi
    push rdi
    mov rsi, rcx
    ; a name containing NOPE does not exist
    mov rdi, rcx
.scan:
    cmp byte [rdi], 0
    je .ok
    cmp dword [rdi], 'NOPE'
    je .fail
    inc rdi
    jmp .scan
.ok:
    lea rdi, [rel wcwd]
.cp:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .cp
    mov eax, 1
    jmp .out
.fail:
    mov dword [rel last_err], 2
    xor eax, eax
.out:
    pop rdi
    pop rsi
    RETC

ENTRY GetFullPathNameA
    ; absolute names are returned as they are, others are put under the wcwd
    push rsi
    push rdi
    mov rsi, rcx
    mov rdi, r8
    xor eax, eax
    cmp byte [rsi+1], ':'
    je .abs
    lea r10, [rel wcwd]
.c1:
    mov al, [r10]
    test al, al
    jz .c1d
    mov [rdi], al
    inc r10
    inc rdi
    jmp .c1
.c1d:
    mov byte [rdi], 0x5c
    inc rdi
.abs:
.c2:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .c2
    mov rax, rdi
    sub rax, r8
    dec eax
    pop rdi
    pop rsi
    RETC

ENTRY GetSystemDirectoryA
    push rsi
    push rdi
    lea rsi, [rel sysdir]
    mov rdi, rcx
.cp:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .cp
    mov eax, 19
    pop rdi
    pop rsi
    RETC

ENTRY GetLocalTime
    mov word [rcx], 2026
    mov word [rcx+2], 10
    mov word [rcx+4], 2
    mov word [rcx+6], 20
    mov word [rcx+8], 13
    mov word [rcx+10], 5
    mov word [rcx+12], 7
    mov word [rcx+14], 0
    RETC

ENTRY GetModuleFileNameA
    push rsi
    lea rsi, [rel modname]
    xor eax, eax
.c: mov r11b, [rsi+rax]
    mov [rdx+rax], r11b
    inc eax
    test r11b, r11b
    jnz .c
    dec eax
    pop rsi
    RETC

ENTRY GetLastError
    mov eax, [rel last_err]
    RETC

; FormatMessageA writes "ERR<code>" so tests can see which error was shown
ENTRY FormatMessageA
    push rsi
    push rdi
    mov rdi, [rsp+16+40]        ; lpBuffer (two pushes above the entry slots)
    lea rsi, [rel str_err]
    mov r11, rdi
.c: mov al, [rsi]
    test al, al
    jz .num
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .c
.num:
    mov eax, r8d
    sub rsp, 24
    lea rsi, [rsp+20]
    mov byte [rsi], 0
    mov ecx, 10
.d: xor edx, edx
    div ecx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test eax, eax
    jnz .d
.cd:
    mov al, [rsi]
    test al, al
    jz .crlf
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .cd
.crlf:
    add rsp, 24
    mov byte [rdi], 13
    mov byte [rdi+1], 10
    mov byte [rdi+2], 0
    add rdi, 2
    mov rax, rdi
    sub rax, r11
    pop rdi
    pop rsi
    RETC

ENTRY CloseHandle
    LOGS "[CloseHandle "
    LOGX rcx
    LOGS `]\n`
    mov eax, 1
    RETC

ENTRY WaitForSingleObject
    cmp byte [rel ctrlc_child], 0
    je .q
    test dword [rel con_mode], 1
    jz .q
    ; Ctrl+C goes to every process on the console, the shell included
    mov rax, [rel ctrl_handler]
    test rax, rax
    jz .q
    sub rsp, 40
    xor ecx, ecx
    call rax
    add rsp, 40
.q: xor eax, eax
    RETC

ENTRY ExitProcess
    LOGS "[ExitProcess "
    LOGD rcx
    LOGS `]\n`
    mov eax, 231
    movzx edi, cl
    syscall

ENTRY GetEnvironmentVariableA
    ; key = "W_ENV_" + upper(name)
    push rsi
    push rdi
    push rbx
    mov rbx, rdx                ; buffer
    mov r9d, r8d                ; size
    lea rdi, [rel keybuf]
    lea rsi, [rel envprefix]
.p: mov al, [rsi]
    test al, al
    jz .n
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .p
.n: mov al, [rcx]
    cmp al, 'a'
    jb .u
    cmp al, 'z'
    ja .u
    sub al, 32
.u: mov [rdi], al
    inc rcx
    inc rdi
    test al, al
    jnz .n
    lea rdi, [rel keybuf]
    call w_env_find
    test rax, rax
    jz .undef
    mov rsi, rax
    xor ecx, ecx
.l: cmp byte [rsi+rcx], 0
    je .got
    inc ecx
    jmp .l
.got:
    lea eax, [rcx+1]
    cmp eax, r9d
    ja .small                   ; does not fit: return the size needed
    mov rdi, rbx
    mov r8d, ecx
    inc ecx
    rep movsb
    mov eax, r8d
    jmp .out
.small:
    jmp .out
.undef:
    mov dword [rel last_err], 203
    xor eax, eax
.out:
    pop rbx
    pop rdi
    pop rsi
    RETC

ENTRY SetEnvironmentVariableA
    LOGS "[SetEnv "
    LOGP rcx
    LOGS "="
    LOGP rdx
    LOGS `]\n`
    mov eax, 1
    RETC

ENTRY GetEnvironmentStringsA
    lea rax, [rel envblock]
    RETC

ENTRY FreeEnvironmentStringsA
    mov eax, 1
    RETC

; WriteConsoleA(h, buf, len, *written, 0)
ENTRY WriteConsoleA
    push rsi
    push rdi
    mov rsi, rdx
    mov [r9], r8d
    mov rdx, r8
    lea rax, [rel line_buf]
    cmp rsi, rax
    je .grid                    ; line editor redraws only touch the grid
    cmp byte [rel logflags + 'w'], 0
    je .out
    LOGS "[WriteConsole "
    LOGD r8
    LOGS `]\n`
.out:
    push rsi
    push rdx
    mov eax, 1
    mov edi, 1
    ; write(1, rsi, rdx)
    syscall
    pop rdx
    pop rsi
.grid:
    call con_write
    pop rdi
    pop rsi
    mov eax, 1
    RETC

; WriteFile(h, buf, n, *written, ovl): a redirected file; log the data
ENTRY WriteFile
    push rsi
    push rdi
    mov [r9], r8d
    LOGS "[WriteFile h="
    LOGX rcx
    LOGS " n="
    LOGD r8
    LOGS " data="
    mov rsi, rdx
    mov rdx, r8
    mov eax, 1
    mov edi, 2
    syscall
    LOGS `]\n`
    pop rdi
    pop rsi
    mov eax, 1
    RETC

; ReadFile(h, buf, n, *read, ovl): autoexec.txt (0x100) and type data (others)
ENTRY ReadFile
    push rsi
    push rdi
    xor eax, eax
    mov dword [r9], 0
    cmp rcx, 0x100
    jne .type
    cmp dword [rel auto_pending], 0
    je .done
    mov dword [rel auto_pending], 0
    lea rdi, [rel key_w_auto]
    jmp .get
.type:
    cmp dword [rel type_pending], 0
    je .done
    mov dword [rel type_pending], 0
    lea rdi, [rel key_w_type]
.get:
    call w_env_find
    test rax, rax
    jz .done
    mov rsi, rax
    xor ecx, ecx
.cp:
    cmp ecx, r8d
    jae .cpd
    mov al, [rsi+rcx]
    test al, al
    jz .cpd
    mov [rdx+rcx], al
    inc ecx
    jmp .cp
.cpd:
    mov [r9], ecx
.done:
    pop rdi
    pop rsi
    mov eax, 1
    RETC

; CreateFileA(name, access, share, secattr, disposition, flags, template)
ENTRY CreateFileA
    LOGS "[CreateFile name="
    LOGP rcx
    LOGS " access="
    LOGX rdx
    LOGS " share="
    LOGX r8
    LOGS " inherit="
    xor r10d, r10d
    test r9, r9
    jz .noinh
    mov r10d, [r9+16]
.noinh:
    LOGD r10
    LOGS " disp="
    mov r10d, [rsp+40]
    call lg_dec
    LOGS `]\n`
    push rsi
    push rdi
    ; a name containing NOPE does not exist; autoexec.txt exists when W_AUTOEXEC is set
    mov rdi, rcx
    xor ecx, ecx                ; flag: name ends in autoexec.txt
.scan:
    cmp byte [rdi], 0
    je .scanned
    cmp dword [rdi], 'NOPE'
    je .fail
    cmp dword [rdi], 'auto'
    jne .snext
    cmp dword [rdi+4], 'exec'
    jne .snext
    mov ecx, 1
.snext:
    inc rdi
    jmp .scan
.scanned:
    test ecx, ecx
    jz .normal
    push rcx
    lea rdi, [rel key_w_auto]
    call w_env_find
    pop rcx
    test rax, rax
    jz .fail
    mov dword [rel auto_pending], 1
    mov eax, 0x100
    jmp .ret
.normal:
    inc dword [rel file_ctr]
    mov dword [rel type_pending], 1
    mov eax, [rel file_ctr]
    add eax, 0x200
    jmp .ret
.fail:
    mov dword [rel last_err], 2
    mov rax, -1
.ret:
    pop rdi
    pop rsi
    RETC

; CreateProcessA(app, cmdline, pa, ta, inherit, flags, env, curdir, si, pi)
ENTRY CreateProcessA
    push rbx
    LOGS "[CreateProcess app="
    LOGP rcx
    LOGS " cmd="
    LOGP rdx
    LOGS " inherit="
    mov r10d, [rsp+8+40]
    call lg_dec
    LOGS " mode="
    mov r10d, [rel con_mode]
    call lg_hex
    LOGS " siflags="
    mov rbx, [rsp+8+72]
    mov r10d, [rbx+60]
    call lg_hex
    LOGS " stdin="
    mov r10, [rbx+80]
    call lg_hex
    LOGS " stdout="
    mov r10, [rbx+88]
    call lg_hex
    LOGS " stderr="
    mov r10, [rbx+96]
    call lg_hex
    LOGS `]\n`
    mov rbx, [rsp+8+80]
    mov qword [rbx], 0x55
    mov qword [rbx+8], 0x66
    pop rbx
    mov eax, 1
    RETC

ENTRY CreateDirectoryA
    LOGS "[CreateDirectory "
    LOGP rcx
    LOGS `]\n`
    mov eax, 1
    RETC

ENTRY RemoveDirectoryA
    LOGS "[RemoveDirectory "
    LOGP rcx
    LOGS `]\n`
    mov eax, 1
    RETC

ENTRY DeleteFileA
    LOGS "[DeleteFile "
    LOGP rcx
    LOGS `]\n`
    mov eax, 1
    RETC

; CopyFileA(src, dst, failIfExists)
ENTRY CopyFileA
    LOGS "[CopyFile "
    LOGP rcx
    LOGS " -> "
    LOGP rdx
    LOGS " failIfExists="
    LOGD r8
    LOGS `]\n`
    mov eax, 1
    RETC

ENTRY MoveFileA
    LOGS "[MoveFile "
    LOGP rcx
    LOGS " -> "
    LOGP rdx
    LOGS `]\n`
    mov eax, 1
    RETC

; GetFileAttributesA: looks the name up in W_FILES
ENTRY GetFileAttributesA
    push rsi
    push rdi
    push rbx
    mov rbx, rcx
    lea rdi, [rel key_w_files]
    call w_env_find
    mov [rel find_ptr], rax
.next:
    call w_next_entry
    test eax, eax
    jz .none
    mov rsi, rbx
    lea rdi, [rel cand_name]
    call w_streqi
    test eax, eax
    jz .next
    mov eax, [rel cand_attr]
    jmp .out
.none:
    mov dword [rel last_err], 2
    mov eax, -1
.out:
    pop rbx
    pop rdi
    pop rsi
    RETC

; FindFirstFileA(pattern, find_data): the simulated listing comes from W_FILES
ENTRY FindFirstFileA
    push rsi
    push rdi
    push rbx
    mov rbx, rdx
    cmp byte [rel logflags + 'd'], 0
    je .nolog
    LOGS "[FindFirstFile "
    LOGP rcx
    LOGS `]\n`
.nolog:
    ; keep only the last path component of the pattern
    mov rsi, rcx
    mov rdi, rcx
.comp:
    mov al, [rsi]
    test al, al
    jz .compd
    inc rsi
    cmp al, 0x5c
    je .sep
    cmp al, '/'
    jne .comp
.sep:
    mov rdi, rsi
    jmp .comp
.compd:
    lea rsi, [rel find_pat]
.cp:
    mov al, [rdi]
    mov [rsi], al
    inc rdi
    inc rsi
    test al, al
    jnz .cp
    ; "*.*" means "everything" on Windows
    lea rsi, [rel find_pat]
    cmp dword [rsi], '*.*'
    jne .go
    mov byte [rsi+1], 0
.go:
    lea rdi, [rel key_w_files]
    call w_env_find
    mov [rel find_ptr], rax
    mov dword [rel find_stage], 0
    mov rdx, rbx
    call w_find_adv
    test eax, eax
    jz .none
    mov eax, 0x777
    jmp .out
.none:
    mov dword [rel last_err], 2
    mov rax, -1
.out:
    pop rbx
    pop rdi
    pop rsi
    RETC

ENTRY FindNextFileA
    push rsi
    push rdi
    push rbx
    call w_find_adv
    test eax, eax
    jnz .out
    mov dword [rel last_err], 18
.out:
    pop rbx
    pop rdi
    pop rsi
    RETC

ENTRY FindClose
    cmp byte [rel logflags + 'd'], 0
    je .q
    LOGS "[FindClose "
    LOGX rcx
    LOGS `]\n`
.q: mov eax, 1
    RETC

; ReadConsoleInputA(h, buf, n, *read): key events from stdin bytes
ENTRY ReadConsoleInputA
    push rbx
    push rdi
    push rsi
    sub rsp, 48
    mov rbx, rdx                ; INPUT_RECORD
    mov [rsp+32], r9            ; *eventsRead
    cmp byte [rel notconsole], 0
    jne .fail
    ; the key-up half of the previous key
    cmp dword [rel pending_up], 0
    je .read
    mov dword [rel pending_up], 0
    mov r8d, [rel up_vk]
    mov edx, [rel up_ch]
    xor eax, eax                ; bKeyDown = 0
    jmp .fill
.read:
    xor eax, eax                ; sys_read(0, kbuf, 1)
    xor edi, edi
    lea rsi, [rel kbuf]
    mov edx, 1
    syscall
    cmp rax, 1
    jne .eof
    movzx eax, byte [rel kbuf]
    cmp eax, 0x0e
    jne .c1
    xor eax, eax                ; the repeat count is the next byte
    xor edi, edi
    lea rsi, [rel kbuf]
    mov edx, 1
    syscall
    cmp rax, 1
    jne .eof
    movzx eax, byte [rel kbuf]
    mov [rel repeat_next], eax
    jmp .read
.c1:
    cmp eax, 0x1a
    jne .c2
    call dump_screen
    jmp .read
.c2:
    cmp eax, 0x11
    jb .keys
    cmp eax, 0x13
    ja .c3
    sub eax, 0x11
    mov ecx, eax
    jmp .event
.c3:
    cmp eax, 0x18
    jne .keys
    ; Ctrl+C: with ENABLE_PROCESSED_INPUT the system turns it into a
    ; control event; otherwise it arrives as a character
    test dword [rel con_mode], 1
    jz .ck
    xor ecx, ecx
    jmp .event
.ck:
    mov r8d, 0x43
    mov edx, 3
    jmp .down
.event:                         ; ecx = control event; the handler runs "on another thread"
    mov rax, [rel ctrl_handler]
    test rax, rax
    jz .read
    call rax
    test eax, eax
    jnz .read
    LOGS `[default handler: exit]\n`
    mov eax, 231
    mov edi, 1
    syscall
.keys:
    movzx eax, byte [rel kbuf]
    xor edx, edx
    mov r8d, eax
    cmp eax, 1
    jne .n1
    mov r8d, 9
    mov edx, 9
    jmp .down
.n1: cmp eax, 2
    jne .n2
    mov r8d, 0x26
    jmp .down
.n2: cmp eax, 3
    jne .n3
    mov r8d, 0x28
    jmp .down
.n3: cmp eax, 4
    jne .n4
    mov r8d, 0x0D
    mov edx, 13
    jmp .down
.n4: cmp eax, 5
    jne .n5
    mov r8d, 0x25
    jmp .down
.n5: cmp eax, 6
    jne .n6
    mov r8d, 0x27
    jmp .down
.n6: cmp eax, 7
    jne .n7
    mov r8d, 0x24
    jmp .down
.n7: cmp eax, 11
    jne .n8
    mov r8d, 0x23
    jmp .down
.n8: cmp eax, 8
    jne .n9
    mov r8d, 8
    mov edx, 8
    jmp .down
.n9: cmp eax, 0x7f
    jne .nA
    mov r8d, 0x2E
    jmp .down
.nA: mov edx, eax
    mov r8d, eax
    cmp r8d, 'a'
    jb .nB
    cmp r8d, 'z'
    ja .nB
    sub r8d, 32
    jmp .down
.nB: cmp r8d, ' '
    je .down
    cmp r8d, '0'
    jb .nC
    cmp r8d, '9'
    jbe .down
.nC: cmp r8d, 'A'
    jb .nD
    cmp r8d, 'Z'
    jbe .down
.nD: mov r8d, 0xBA              ; an OEM key code that clashes with no editing key
.down:
    mov dword [rel pending_up], 1
    mov [rel up_vk], r8d
    mov [rel up_ch], edx
    mov eax, 1                  ; bKeyDown = 1
.fill:                          ; eax = bKeyDown, r8d = virtual key, edx = character
    mov dword [rbx], 1          ; EventType = KEY_EVENT
    mov [rbx+4], eax
    mov ecx, 1
    test eax, eax
    jz .setrep
    mov ecx, [rel repeat_next]
    test ecx, ecx
    jnz .setrep
    mov ecx, 1
.setrep:
    test eax, eax
    jz .norst
    mov dword [rel repeat_next], 0
.norst:
    mov word [rbx+8], cx
    mov [rbx+10], r8w
    mov word [rbx+12], 0
    mov byte [rbx+14], dl
    mov byte [rbx+15], 0
    mov dword [rbx+16], 0
    mov r10, [rsp+32]
    mov dword [r10], 1
    add rsp, 48
    pop rsi
    pop rdi
    pop rbx
    mov eax, 1
    RETC
.fail:
    mov dword [rel last_err], 6
    add rsp, 48
    pop rsi
    pop rdi
    pop rbx
    xor eax, eax
    RETC
.eof:
    cmp byte [rel dump_at_eof], 0
    je .eof2
    call dump_screen
.eof2:
    lea r10, [rel eofmsg]
    call lg_str
    mov eax, 231
    xor edi, edi
    syscall

global _start
%ifdef CHECKREGS
%include "chk.inc"
%endif
section .text
_start:
    mov rax, [rsp]
    lea rbx, [rsp+8+rax*8+8]    ; envp
    mov [rel envp_ptr], rbx
    ; log classes
    lea rdi, [rel key_w_log]
    call w_env_find
    test rax, rax
    jz .nolog
    mov rsi, rax
.lc:
    movzx ecx, byte [rsi]
    test ecx, ecx
    jz .nolog
    lea rdx, [rel logflags]
    mov byte [rdx+rcx], 1
    inc rsi
    jmp .lc
.nolog:
    ; flags and sizes
    lea rdi, [rel key_w_notc]
    call w_env_find
    test rax, rax
    setnz byte [rel notconsole]
    lea rdi, [rel key_w_dump]
    call w_env_find
    test rax, rax
    setnz byte [rel dump_at_eof]
    lea rdi, [rel key_w_cic]
    call w_env_find
    test rax, rax
    setnz byte [rel ctrlc_child]
    mov dword [rel rows], 25
    mov dword [rel cols], 80
    lea rdi, [rel key_w_rows]
    call w_env_find
    test rax, rax
    jz .r1
    mov rsi, rax
    call w_atoi
    mov [rel rows], eax
.r1:
    lea rdi, [rel key_w_cols]
    call w_env_find
    test rax, rax
    jz .r2
    mov rsi, rax
    call w_atoi
    mov [rel cols], eax
.r2:
    lea rdi, [rel key_w_row0]
    call w_env_find
    test rax, rax
    jz .r3
    mov rsi, rax
    call w_atoi
    mov [rel cur_y], eax
.r3:
    mov dword [rel con_mode], 0x1F7
    mov word [rel cur_attr], 7
    lea rdi, [rel screen]
    mov ecx, MAXCOLS * MAXROWS
    mov al, ' '
    rep stosb
    ; working directory
    lea rsi, [rel cwd_init]
    lea rdi, [rel key_w_cwd]
    call w_env_find
    test rax, rax
    cmovnz rsi, rax
    lea rdi, [rel wcwd]
.cw:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .cw
%ifdef CHECKREGS
    jmp chk_start
%endif
    and rsp, -16
    call main
    mov eax, 231
    xor edi, edi
    syscall
