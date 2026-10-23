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
; "sudo"/"doas" (with their options) and leading NAME=value words are looked
; through: the word after them is the one judged. Aliases and shell functions
; count as known. Nothing is colored when color is off (NO_COLOR, TERM=dumb);
; the Linux console, which has no 24-bit color, gets plain 16-color codes.
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
    ; The same four colors for the Linux console (TERM=linux)
    hl_b_ok         db 27, "[36m", 0
    hl_b_ok_len     equ $ - hl_b_ok - 1
    hl_b_info       db 27, "[94m", 0
    hl_b_info_len   equ $ - hl_b_info - 1
    hl_b_unknown    db 27, "[90m", 0
    hl_b_unknown_len equ $ - hl_b_unknown - 1
    hl_b_danger     db 27, "[1;31m", 0
    hl_b_danger_len equ $ - hl_b_danger - 1
    align 8
    ; color index: 0 ok, 1 info, 2 unknown, 3 danger; 16 bytes per entry
hl_pal_true:
    dq hl_c_ok, hl_c_ok_len
    dq hl_c_info, hl_c_info_len
    dq hl_c_unknown, hl_c_unknown_len
    dq hl_c_danger, hl_c_danger_len
hl_pal_basic:
    dq hl_b_ok, hl_b_ok_len
    dq hl_b_info, hl_b_info_len
    dq hl_b_unknown, hl_b_unknown_len
    dq hl_b_danger, hl_b_danger_len
    hl_s_sudo       db "sudo", 0
    hl_s_doas       db "doas", 0
    ; sudo options that take a value as the next word (-u USER, -g GROUP, ...)
    hl_sudo_valopts db "ugCDhprtTUR", 0
    ; Words after which the next word is a command again
hl_prefix_words:
    db "sudo",0, "doas",0, "xargs",0, "time",0, "nohup",0, "exec",0
    db "env",0, "nice",0, "ionice",0, "command",0, "builtin",0, "watch",0
    db "then",0, "do",0, "else",0, "elif",0, "if",0, "while",0, "until",0
    db "!",0, "-exec",0, "-execdir",0
    db 0

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
    db " --help ",0, " /? ",0, " -?",0
    db 0

    ; Whole-line patterns that wipe a lot at once. Searched in a lowercase
    ; copy of the line with one space appended, so "| sh " matches at the end
    ; of the line but not inside "| shuf". A pattern that starts with a letter
    ; or digit must begin a word ("of=/dev/sda" yes, "perform -r" no); one
    ; marked ^ must also stand where a command goes (line start, after ; | &
    ; ( or a word like sudo/then), so "cat mkfs.txt" and "grep -r mkfs src"
    ; stay quiet.
hl_crit_patterns:
    db "^rm -rf",0, "^rm -fr",0, "^rm -r ",0, "^rm --recursive",0
    db "--no-preserve-root",0, "^sudo rm ",0, ":(){",0, ":() {",0
    db "of=/dev/sd",0, "of=/dev/nvme",0, "of=/dev/hd",0, "of=/dev/vd",0
    db "of=/dev/mmcblk",0, "of=/dev/disk",0
    db "> /dev/sd",0, ">/dev/sd",0, "> /dev/nvme",0
    db ">/dev/nvme",0, "^mkfs",0, "^wipefs -a",0, "^shred ",0
    db "| sh ",0, "|sh ",0, "| bash ",0, "|bash ",0, "| zsh ",0
    db "| sudo sh ",0, "| sudo bash ",0
    db "^chmod -r 777",0, "^chmod -r 000",0, "^chown -r ",0, "^kill -9 -1 ",0
    db "^format c:",0, "^del /s",0, "^del /q",0, "^erase /s",0, "^rd /s",0
    db "^rmdir /s",0, "-recurse -force",0, "-force -recurse",0
    db "^clear-disk",0, "^format-volume",0, "^remove-partition",0
    db "^diskpart",0, "^vssadmin delete",0, "^bcdedit /delete",0
    db "^reg delete",0, "^cipher /w",0
    db 0

section .bss
    hl_low          resb 520            ; lowercase copy of the line + " "
    hl_word         resb 128            ; command word being judged
    hl_pathbuf      resb 1024           ; dir/word candidate for PATH lookup
    hl_cache_valid  resb 1              ; hl_cache_* hold the last judged word
    hl_cache_known  resb 1              ; 1 = that word is a command
    hl_cache_word   resb 128
    hl_basic        resb 1              ; 1 = 16-color codes (Linux console)

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
    cmp r12d, 511
    jbe .len_ok
    mov r12d, 511
.len_ok:
    cmp byte [color_enabled], 0
    je .plain                           ; NO_COLOR, TERM=dumb

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
    mov ebx, 3
    call .set_color
    mov rdi, rbx
    mov esi, r15d
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
.skip_assign:
    ; leading NAME=value words only set the environment: the command is next
    mov r14d, r13d
    call .word_end
    call .is_assign
    test eax, eax
    jz .have_word
    mov r13d, r14d
    call .skip_sp
    cmp r13d, r12d
    jae .plain                          ; nothing but assignments
    jmp .skip_assign
.have_word:
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
    ; color "sudo [options] X" as one span and judge X
    mov r15d, r13d                      ; remember span start
.sudo_next:
    mov r13d, r14d
    call .skip_sp
    cmp r13d, r12d
    jae .sudo_alone
    cmp byte [line_buf + r13], '-'
    jne .sudo_cmd
    mov r14d, r13d
    call .word_end                      ; r14 = end of the option word
    mov eax, r14d
    sub eax, r13d
    cmp eax, 2
    jne .sudo_next                      ; --long-option or -abc: no value
    cmp byte [line_buf + r13 + 1], '-'
    je .sudo_dashdash                   ; "--" ends the options
    movzx eax, byte [line_buf + r13 + 1]
    lea rdi, [hl_sudo_valopts]
.sudo_vo:
    cmp byte [rdi], 0
    je .sudo_next                       ; flag without a value
    cmp al, [rdi]
    je .sudo_value
    inc rdi
    jmp .sudo_vo
.sudo_value:
    mov r13d, r14d                      ; the option's value is the next word
    call .skip_sp
    cmp r13d, r12d
    jae .sudo_alone
    mov r14d, r13d
    call .word_end
    jmp .sudo_next
.sudo_dashdash:
    mov r13d, r14d
    call .skip_sp
    cmp r13d, r12d
    jae .sudo_alone
.sudo_cmd:
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
    mov ebx, 3
    test eax, eax
    jnz .paint

    mov edx, 0
    lea rdi, [hl_info_patterns]
    call hl_find_any
    mov ebx, 1
    test eax, eax
    jnz .paint
    lea rdi, [hl_word]
    lea rsi, [hl_info_words]
    call hl_word_in_list
    test eax, eax
    jnz .paint

    call hl_is_known                    ; eax = 1 for a command we can run
    mov ebx, 2
    test eax, eax
    jz .paint
    xor ebx, ebx

.paint:
    call .set_color                     ; rbx = sequence, r15d = its length
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
.set_color:                             ; ebx = color index -> rbx/r15d = sequence
    lea rax, [hl_pal_true]
    cmp byte [hl_basic], 0
    je .sc_pick
    lea rax, [hl_pal_basic]
.sc_pick:
    shl rbx, 4
    mov r15d, [rax + rbx + 8]
    mov rbx, [rax + rbx]
    ret

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

; .is_assign - eax = 1 if line[r13..r14) looks like NAME=value
.is_assign:
    mov ecx, r13d
    cmp ecx, r14d
    jae .ia_no
    mov al, [line_buf + rcx]
    cmp al, '_'
    je .ia_loop
    or al, 0x20
    cmp al, 'a'
    jb .ia_no
    cmp al, 'z'
    ja .ia_no
.ia_loop:
    inc ecx
    cmp ecx, r14d
    jae .ia_no
    mov al, [line_buf + rcx]
    cmp al, '='
    je .ia_yes
    cmp al, '_'
    je .ia_loop
    cmp al, '0'
    jb .ia_no
    cmp al, '9'
    jbe .ia_loop
    or al, 0x20
    cmp al, 'a'
    jb .ia_no
    cmp al, 'z'
    jbe .ia_loop
.ia_no:
    xor eax, eax
    ret
.ia_yes:
    mov eax, 1
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
; hl_is_known - eax = 1 if hl_word is a builtin, ASH keyword, alias, shell
; function or program on PATH. The answer for the last word is kept until the
; next prompt, so typing the arguments does not walk PATH again for every key.
; ----------------------------------------------------------------------------
hl_is_known:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    cmp byte [hl_cache_valid], 0
    je .hk_compute
    lea rdi, [hl_word]
    lea rsi, [hl_cache_word]
    call str_icompare
    test eax, eax
    jnz .hk_compute
    movzx eax, byte [hl_cache_known]
    jmp .hk_ret

.hk_compute:
    xor ebx, ebx
    lea rdi, [hl_word]
    call str_len
    mov esi, eax
    lea rdi, [hl_word]
    call check_command_exists
    test eax, eax
    jnz .hk_yes
    lea rdi, [hl_word]
    call hl_is_alias
    test eax, eax
    jnz .hk_yes
    lea rdi, [hl_word]
    call str_len
    mov esi, eax
    lea rdi, [hl_word]
    call ash_func_find
    test rax, rax
    jnz .hk_yes
    lea rdi, [hl_word]
    call hl_in_path
    test eax, eax
    jz .hk_store
.hk_yes:
    mov ebx, 1
.hk_store:
    lea rdi, [hl_cache_word]
    lea rsi, [hl_word]
    call str_copy
    mov [hl_cache_known], bl
    mov byte [hl_cache_valid], 1
    mov eax, ebx
.hk_ret:
    add rsp, 8
    pop rbx
    pop rbp
    ret

; hl_is_alias(rdi=word) -> eax = 1 if it names an alias
hl_is_alias:
    push rbx
    push r12
    push r13
    mov r12, rdi
    lea rbx, [alias_table]
    xor r13d, r13d
.al_loop:
    cmp r13d, [alias_count]
    jge .al_no
    cmp byte [rbx], 0
    je .al_next                         ; deleted entry
    mov rdi, r12
    mov rsi, rbx
    call str_icompare
    test eax, eax
    jz .al_yes
.al_next:
    add rbx, ALIAS_ENTRY_SIZE
    inc r13d
    jmp .al_loop
.al_yes:
    mov eax, 1
    jmp .al_ret
.al_no:
    xor eax, eax
.al_ret:
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; hl_line_is_critical - search hl_low for any hl_crit_patterns entry
; hl_find_any(rdi=pattern list, edx=1 to apply the word rules) - the same for
; any NUL-separated list. Returns eax = 1 if found.
; ----------------------------------------------------------------------------
hl_line_is_critical:
    lea rdi, [hl_crit_patterns]
    mov edx, 1
hl_find_any:
    mov esi, edx                        ; esi = apply word/command rules
    mov r8, rdi
.pat:
    cmp byte [r8], 0
    je .no
    xor r10d, r10d                      ; r10 = 1: must stand at a command
    cmp byte [r8], '^'
    jne .pat_go
    inc r8
    mov r10d, 1
.pat_go:
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
    test esi, esi
    jz .found
    test r10d, r10d
    jz .boundary
    call hl_cmd_pos
    test eax, eax
    jz .advance
    jmp .found
.boundary:
    movzx eax, byte [r8]                ; letters and digits start a word
    cmp al, '0'
    jb .found
    cmp al, '9'
    jbe .need_word
    cmp al, 'a'
    jb .found
    cmp al, 'z'
    ja .found
.need_word:
    call hl_word_start
    test eax, eax
    jz .advance
.found:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; hl_word_start - eax = 1 if r9 (inside hl_low) is at the start of a word
hl_word_start:
    lea rdx, [hl_low]
    cmp r9, rdx
    je .ws_yes
    mov al, [r9 - 1]
    cmp al, ' '
    je .ws_yes
    cmp al, ';'
    je .ws_yes
    cmp al, '|'
    je .ws_yes
    cmp al, '&'
    je .ws_yes
    cmp al, '('
    je .ws_yes
    cmp al, '`'
    je .ws_yes
    cmp al, '{'
    je .ws_yes
    xor eax, eax
    ret
.ws_yes:
    mov eax, 1
    ret

; hl_cmd_pos - eax = 1 if r9 (inside hl_low) is where a command may start:
; the line start, right after ; | & ( ` {, or after words such as sudo, then,
; xargs that are followed by a command. Clobbers rax, rcx, rdx, rdi, r11.
hl_cmd_pos:
    lea rdx, [hl_low]
    mov r11, r9
.cp_again:
    mov rcx, r11
.cp_sp:
    cmp rcx, rdx
    je .cp_yes
    cmp byte [rcx - 1], ' '
    jne .cp_chk
    dec rcx
    jmp .cp_sp
.cp_chk:
    movzx eax, byte [rcx - 1]
    cmp al, ';'
    je .cp_yes
    cmp al, '|'
    je .cp_yes
    cmp al, '&'
    je .cp_yes
    cmp al, '('
    je .cp_yes
    cmp al, '`'
    je .cp_yes
    cmp al, '{'
    je .cp_yes
    cmp rcx, r11
    je .cp_no                           ; glued to the word before it
    ; the previous word is [rdi, rcx): a prefix word like sudo is looked through
    mov rdi, rcx
.cp_wb:
    cmp rdi, rdx
    je .cp_have
    movzx eax, byte [rdi - 1]
    cmp al, ' '
    je .cp_have
    cmp al, ';'
    je .cp_have
    cmp al, '|'
    je .cp_have
    cmp al, '&'
    je .cp_have
    cmp al, '('
    je .cp_have
    dec rdi
    jmp .cp_wb
.cp_have:
    push rsi
    push r8
    lea r8, [hl_prefix_words]
.cp_list:
    cmp byte [r8], 0
    je .cp_miss
    xor esi, esi
.cp_cmp:
    movzx eax, byte [r8 + rsi]
    test al, al
    jz .cp_end_word
    lea r11, [rdi + rsi]
    cmp r11, rcx
    jae .cp_next_word
    cmp al, [r11]
    jne .cp_next_word
    inc esi
    jmp .cp_cmp
.cp_end_word:
    lea r11, [rdi + rsi]
    cmp r11, rcx
    je .cp_hit
.cp_next_word:
    inc r8
    cmp byte [r8 - 1], 0
    jne .cp_next_word
    jmp .cp_list
.cp_miss:
    pop r8
    pop rsi
    jmp .cp_no
.cp_hit:
    pop r8
    pop rsi
    mov r11, rdi
    jmp .cp_again
.cp_yes:
    mov eax, 1
    ret
.cp_no:
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
