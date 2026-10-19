; ============================================================================
; ash/highlight.asm - live command coloring for the line editor
;
; hl_draw_line prints line_buf with only the command word colored, using the
; VS Code Dark+ palette (24-bit color). Arguments keep the default color.
;   teal   #4EC9B0  builtin, ASH keyword or program found on PATH
;   blue   #3794FF  help/info commands (help, man, about, ver, ...) or "--help"
;   gray   #808080  unknown command
;   red    #F44747  command that can destroy data (rm, dd, mkfs, del, format,
;                   Remove-Item, diskpart, ...), Linux and Windows names alike;
;                   an obliterating line (rm -rf, dd of=/dev/..., curl | sh,
;                   format c:, a fork bomb) is red from start to end.
; "sudo"/"doas" are looked through: the word after them is the one judged.
; ============================================================================

section .data
    ; Palette: edit these to retheme
    hl_c_ok         db 27, "[38;2;78;201;176m", 0
    hl_c_ok_len     equ $ - hl_c_ok - 1
    hl_c_info       db 27, "[38;2;55;148;255m", 0
    hl_c_info_len   equ $ - hl_c_info - 1
    hl_c_unknown    db 27, "[38;2;128;128;128m", 0
    hl_c_unknown_len equ $ - hl_c_unknown - 1
    hl_c_danger     db 27, "[1;38;2;244;71;71m", 0
    hl_c_danger_len equ $ - hl_c_danger - 1
    hl_s_sudo       db "sudo", 0
    hl_s_doas       db "doas", 0

    ; Commands that delete, wipe, overwrite or kill. NUL-separated, "" ends.
    ; Matched case-insensitively against the whole command word.
hl_danger_words:
    ; Linux / Unix
    db "rm",0, "rmdir",0, "shred",0, "dd",0, "mke2fs",0, "mkswap",0
    db "mkntfs",0, "mkdosfs",0, "wipefs",0, "fdisk",0, "sfdisk",0
    db "cfdisk",0, "gdisk",0, "sgdisk",0, "parted",0, "blkdiscard",0
    db "kill",0, "killall",0, "killall5",0, "pkill",0, "xkill",0
    db "chmod",0, "chown",0, "chgrp",0, "chattr",0, "truncate",0
    db "shutdown",0, "reboot",0, "halt",0, "poweroff",0, "telinit",0
    db "userdel",0, "groupdel",0, "deluser",0, "delgroup",0
    db "swapoff",0, "umount",0, "losetup",0, "cryptsetup",0
    db "lvremove",0, "vgremove",0, "pvremove",0, "mdadm",0, "hdparm",0
    db "zpool",0, "zfs",0, "flashrom",0, "srm",0, "unlink",0
    ; Windows cmd
    db "del",0, "erase",0, "rd",0, "format",0, "diskpart",0, "cipher",0
    db "takeown",0, "icacls",0, "cacls",0, "reg",0, "bcdedit",0
    db "taskkill",0, "tskill",0, "sdelete",0, "vssadmin",0, "wmic",0
    db "bootrec",0, "fsutil",0
    ; PowerShell
    db "remove-item",0, "ri",0, "format-volume",0, "clear-disk",0
    db "initialize-disk",0, "remove-partition",0, "stop-process",0
    db "stop-computer",0, "restart-computer",0, "remove-itemproperty",0
    db "clear-content",0, "clear-recyclebin",0, "remove-service",0
    db "set-executionpolicy",0
    db 0

    ; Help / info commands, shown in the info color
hl_info_words:
    db "help",0, "man",0, "info",0, "about",0, "ver",0, "version",0
    db "whatis",0, "apropos",0, "tldr",0, "get-help",0, "uname",0
    db 0
hl_info_patterns:
    db " --help ",0, " -h ",0, " /? ",0, " -?",0
    db 0

    ; Whole-line patterns that wipe a lot at once. Searched in a lowercase
    ; copy of the line with one space appended, so "| sh " matches at the end
    ; of the line but not inside "| shuf".
hl_crit_patterns:
    db "rm -rf",0, "rm -fr",0, "rm -r ",0, "rm --recursive",0
    db "--no-preserve-root",0, "sudo rm ",0, ":(){",0, ":() {",0
    db "of=/dev/",0, "> /dev/sd",0, ">/dev/sd",0, "> /dev/nvme",0
    db ">/dev/nvme",0, "mkfs",0, "wipefs -a",0, "shred ",0
    db "| sh ",0, "|sh ",0, "| bash ",0, "|bash ",0, "| zsh ",0
    db "| sudo sh ",0, "| sudo bash ",0
    db "chmod -r 777",0, "chmod -r 000",0, "chown -r ",0, "kill -9 -1 ",0
    db "format c:",0, "del /s",0, "del /q",0, "erase /s",0, "rd /s",0
    db "rmdir /s",0, "-recurse -force",0, "-force -recurse",0
    db "clear-disk",0, "format-volume",0, "remove-partition",0
    db "diskpart",0, "vssadmin delete",0, "bcdedit /delete",0
    db "reg delete",0, "cipher /w",0
    db 0

section .bss
    hl_low          resb 520            ; lowercase copy of the line + " "
    hl_word         resb 128            ; command word being judged
    hl_pathbuf      resb 1024           ; dir/word candidate for PATH lookup

section .text

; ----------------------------------------------------------------------------
; hl_draw_line - print line_buf[0..line_len) with command coloring
; ----------------------------------------------------------------------------
hl_draw_line:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov r12d, [line_len]                ; r12 = length
    cmp r12d, 510
    jbe .len_ok
    mov r12d, 510
.len_ok:

    ; lowercase copy + trailing space for the pattern search
    lea rsi, [line_buf]
    lea rdi, [hl_low]
    xor ecx, ecx
.low_loop:
    cmp ecx, r12d
    jae .low_done
    mov al, [rsi + rcx]
    cmp al, 'A'
    jb .low_put
    cmp al, 'Z'
    ja .low_put
    or al, 0x20
.low_put:
    mov [rdi + rcx], al
    inc ecx
    jmp .low_loop
.low_done:
    mov byte [rdi + rcx], ' '
    mov byte [rdi + rcx + 1], 0

    ; whole-line obliterating pattern? paint everything
    call hl_line_is_critical
    test eax, eax
    jz .find_word
    lea rdi, [hl_c_danger]
    mov esi, hl_c_danger_len
    call print_string_len
    lea rdi, [line_buf]
    mov esi, r12d
    call print_string_len
    lea rdi, [ansi_default]
    mov esi, ansi_default_len
    call print_string_len
    jmp .out

.find_word:
    ; r13 = start of the command word, r14 = end of the colored span
    xor r13d, r13d
    call .skip_sp
    cmp r13d, r12d
    jae .plain                          ; only spaces
    mov r14d, r13d
    call .word_end                      ; r14 = end of first word
    call .copy_word                     ; hl_word = line[r13..r14)

    lea rdi, [hl_word]
    lea rsi, [hl_s_sudo]
    call str_icompare
    test eax, eax
    jz .look_through
    lea rdi, [hl_word]
    lea rsi, [hl_s_doas]
    call str_icompare
    test eax, eax
    jnz .judge
.look_through:
    ; color "sudo X" as one span and judge X
    mov r15d, r13d                      ; remember span start
    mov r13d, r14d
    call .skip_sp
    cmp r13d, r12d
    jae .sudo_alone
    mov r14d, r13d
    call .word_end
    call .copy_word
    mov r13d, r15d                      ; span starts at "sudo"
    jmp .judge
.sudo_alone:
    mov r13d, r15d                      ; just "sudo": judge it as typed
    mov r14d, r13d
    call .word_end
    call .copy_word

.judge:
    lea rdi, [hl_word]
    lea rsi, [hl_danger_words]
    call hl_word_in_list
    lea rbx, [hl_c_danger]
    mov r15d, hl_c_danger_len
    test eax, eax
    jnz .paint

    lea rdi, [hl_info_patterns]
    call hl_find_any
    test eax, eax
    jnz .info
    lea rdi, [hl_word]
    lea rsi, [hl_info_words]
    call hl_word_in_list
    test eax, eax
    jnz .info

    lea rdi, [hl_word]
    call str_len
    mov esi, eax
    lea rdi, [hl_word]
    call check_command_exists
    test eax, eax
    jnz .ok
    lea rdi, [hl_word]
    call hl_in_path
    test eax, eax
    jnz .ok
    lea rbx, [hl_c_unknown]
    mov r15d, hl_c_unknown_len
    jmp .paint
.info:
    lea rbx, [hl_c_info]
    mov r15d, hl_c_info_len
    jmp .paint
.ok:
    lea rbx, [hl_c_ok]
    mov r15d, hl_c_ok_len

.paint:
    ; leading spaces
    test r13d, r13d
    jz .paint_word
    lea rdi, [line_buf]
    mov esi, r13d
    call print_string_len
.paint_word:
    mov rdi, rbx
    mov esi, r15d
    call print_string_len
    lea rdi, [line_buf + r13]
    mov esi, r14d
    sub esi, r13d
    call print_string_len
    lea rdi, [ansi_default]
    mov esi, ansi_default_len
    call print_string_len
    mov esi, r12d
    sub esi, r14d
    jle .out
    lea rdi, [line_buf + r14]
    call print_string_len
    jmp .out

.plain:
    lea rdi, [line_buf]
    mov esi, r12d
    call print_string_len

.out:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; local helpers (called with the frame above; only touch r13/r14/rax/rcx)
.skip_sp:
    cmp r13d, r12d
    jae .ss_ret
    cmp byte [line_buf + r13], ' '
    jne .ss_ret
    inc r13d
    jmp .skip_sp
.ss_ret:
    ret

.word_end:
    cmp r14d, r12d
    jae .we_ret
    mov al, [line_buf + r14]
    cmp al, ' '
    je .we_ret
    cmp al, ';'
    je .we_ret
    cmp al, '|'
    je .we_ret
    cmp al, '&'
    je .we_ret
    cmp al, '<'
    je .we_ret
    cmp al, '>'
    je .we_ret
    inc r14d
    jmp .word_end
.we_ret:
    ret

.copy_word:
    mov ecx, r14d
    sub ecx, r13d
    cmp ecx, 127
    jbe .cw_len_ok
    mov ecx, 127
.cw_len_ok:
    xor eax, eax
.cw_loop:
    cmp eax, ecx
    jae .cw_done
    push rcx
    mov ecx, r13d
    add ecx, eax
    mov cl, [line_buf + rcx]
    mov [hl_word + rax], cl
    pop rcx
    inc eax
    jmp .cw_loop
.cw_done:
    mov byte [hl_word + rax], 0
    ret

; ----------------------------------------------------------------------------
; hl_line_is_critical - search hl_low for any hl_crit_patterns entry
; hl_find_any(rdi=pattern list) - same for any NUL-separated list
; Returns eax = 1 if found
; ----------------------------------------------------------------------------
hl_line_is_critical:
    lea rdi, [hl_crit_patterns]
hl_find_any:
    mov r8, rdi
.pat:
    cmp byte [r8], 0
    je .no
    lea r9, [hl_low]
.start:
    cmp byte [r9], 0
    je .next_pat
    xor ecx, ecx
.cmp:
    mov al, [r8 + rcx]
    test al, al
    jz .yes                             ; whole needle matched
    cmp al, [r9 + rcx]
    jne .advance
    inc ecx
    jmp .cmp
.advance:
    inc r9
    jmp .start
.next_pat:
    inc r8
    cmp byte [r8 - 1], 0
    jne .next_pat
    jmp .pat
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; hl_word_in_list(rdi=word, rsi=NUL-separated list) -> eax = 1 if listed
; (the danger list also matches every mkfs.<fs> variant)
; ----------------------------------------------------------------------------
hl_word_in_list:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rdi
    mov rbx, rsi
    lea rax, [hl_danger_words]
    cmp rsi, rax
    jne .loop
    mov eax, [rdi]
    or eax, 0x20202020
    cmp eax, 'mkfs'
    je .hit
.loop:
    cmp byte [rbx], 0
    je .miss
    mov rdi, r12
    mov rsi, rbx
    call str_icompare
    test eax, eax
    jz .hit
.skip:
    inc rbx
    cmp byte [rbx - 1], 0
    jne .skip
    jmp .loop
.hit:
    mov eax, 1
    jmp .done
.miss:
    xor eax, eax
.done:
    add rsp, 8
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; hl_in_path(rdi=word) -> eax = 1 if word is an executable on PATH
; (or, when it contains '/', an executable at that path)
; ----------------------------------------------------------------------------
hl_in_path:
    push rbx
    push r12
    push r13
    mov r12, rdi
    cmp byte [rdi], 0
    je .no

    mov rsi, rdi
.slash:
    mov al, [rsi]
    test al, al
    jz .search
    cmp al, '/'
    je .direct
    inc rsi
    jmp .slash
.direct:
    mov rdi, r12
    call .access
    jmp .done

.search:
    lea rdi, [ash_s_path]
    call getenv_internal
    test rax, rax
    jnz .have
    lea rax, [ash_default_path]
.have:
    mov rbx, rax                        ; rbx = PATH cursor
.segment:
    lea rdi, [hl_pathbuf]
    lea r13, [hl_pathbuf + 1024 - 130]  ; leave room for "/" + word
.copy_dir:
    mov al, [rbx]
    test al, al
    jz .dir_end
    cmp al, ':'
    je .dir_end
    cmp rdi, r13
    jae .skip_seg
    mov [rdi], al
    inc rdi
    inc rbx
    jmp .copy_dir
.skip_seg:
    mov al, [rbx]
    test al, al
    jz .no
    inc rbx
    cmp al, ':'
    jne .skip_seg
    jmp .segment
.dir_end:
    lea rax, [hl_pathbuf]
    cmp rdi, rax
    je .next                            ; empty entry: skip (no "." lookups)
    mov byte [rdi], '/'
    inc rdi
    mov rsi, r12
.copy_name:
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    test al, al
    jnz .copy_name
    lea rdi, [hl_pathbuf]
    call .access
    test eax, eax
    jnz .done
.next:
    cmp byte [rbx], 0
    je .no
    inc rbx                             ; skip ':'
    jmp .segment
.no:
    xor eax, eax
.done:
    pop r13
    pop r12
    pop rbx
    ret

; access(rdi, X_OK) and not a directory -> eax = 1
.access:
    mov eax, 21                         ; SYS_access
    mov esi, 1                          ; X_OK
    syscall
    test eax, eax
    jnz .acc_no
    ; directories are "executable" too; reject them
    sub rsp, 152                        ; struct stat (144) + align
    mov rsi, rsp
    mov eax, 4                          ; SYS_stat
    syscall
    test eax, eax
    jnz .acc_no_pop
    mov eax, [rsp + 24]                 ; st_mode
    and eax, 0xF000
    cmp eax, 0x4000
    je .acc_no_pop
    add rsp, 152
    mov eax, 1
    ret
.acc_no_pop:
    add rsp, 152
.acc_no:
    xor eax, eax
    ret
