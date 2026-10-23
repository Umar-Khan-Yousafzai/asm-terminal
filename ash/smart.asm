; ============================================================================
; ash/smart.asm - smart typing for the line editor
;
; 1. Suggestions: while the cursor is at the end of the line, the rest of the
;    newest history entry that starts with the typed text is drawn in grey
;    behind the cursor. Right arrow, End or Ctrl+E / Ctrl+F accept it. Entries
;    run in the same folder that succeeded win, then any that succeeded, then
;    any at all.
; 2. History notes: every entry remembers a hash of the folder it ran in and
;    its exit status. They are kept in ~/.asm_history as "#asm:HASH:STATUS"
;    lines right after the command (older versions load those as comments).
;    `history` marks failed commands and `history .` lists only the commands
;    run in this folder.
; 3. Tab menu: while Tab cycles through file names, every match is listed
;    under the line with the current one highlighted.
; ============================================================================

%define SM_MENU_BUF     4096            ; names kept for the menu
%define SM_MENU_ROWS    8               ; menu rows shown at most

section .data
    sm_c_sugg_true  db 27, "[38;2;110;110;110m", 0
    sm_c_sugg_basic db 27, "[90m", 0
    sm_c_dir_true   db 27, "[38;2;86;156;214m", 0
    sm_c_dir_basic  db 27, "[34m", 0
    sm_c_fail_true  db 27, "[38;2;244;71;71m", 0
    sm_c_fail_basic db 27, "[31m", 0
    sm_c_sel        db 27, "[7m", 0
    sm_c_reset      db 27, "[0m", 0
    sm_meta_tag     db "#asm:", 0
    sm_s_more_pre   db "  ... ", 0
    sm_s_more_post  db " more", 0
    sm_s_crlf       db 13, 10, 0
    sm_s_indent     db "  ", 0
    sm_s_fail_pre   db "  [", 0
    sm_s_fail_post  db "]", 0
    sm_hex          db "0123456789abcdef"

section .bss
    hist_meta_hash  resd HISTORY_COUNT  ; folder hash per history slot (0 = unknown)
    hist_meta_stat  resb HISTORY_COUNT  ; exit status per slot (0 = worked)
    sm_cwd_hash_now resd 1              ; folder hash when the line was started
    sm_run_hash     resd 1              ; folder hash when the command started
    sm_note_pending resb 1              ; main loop: note the status after the run
    sugg_ptr        resq 1              ; shown suggestion (into history_buf)
    sugg_len        resd 1              ; 0 = none shown
    sugg_off        resb 1              ; 1 = redraw without a suggestion
    tab_menu_shown  resb 1
    tab_name_off    resd 1              ; where the name starts in tab_name_prefix
    rd_end_row      resd 1              ; row of the end of the drawn text
    sm_cwd_buf      resb MAX_PATH_BUF
    sm_meta_line    resb 32
    sm_menu_buf     resb SM_MENU_BUF    ; type byte + name + NUL, per match

section .text

; ----------------------------------------------------------------------------
; sm_cwd_hash -> eax = FNV-1a hash of the current folder (never 0)
; ----------------------------------------------------------------------------
sm_cwd_hash:
    lea rdi, [sm_cwd_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    mov edx, 1
    test rax, rax
    jle .h_ret
    lea rsi, [sm_cwd_buf]
    mov edx, 2166136261
.h_loop:
    movzx ecx, byte [rsi]
    test ecx, ecx
    jz .h_done
    xor edx, ecx
    imul edx, edx, 16777619
    inc rsi
    jmp .h_loop
.h_done:
    test edx, edx
    jnz .h_ret
    inc edx
.h_ret:
    mov eax, edx
    ret

; ----------------------------------------------------------------------------
; sm_line_start - read_line calls this before the first key of a line
; ----------------------------------------------------------------------------
sm_line_start:
    sub rsp, 8
    mov dword [sugg_len], 0
    mov byte [sugg_off], 0
    mov byte [tab_menu_shown], 0
    call sm_cwd_hash
    mov [sm_cwd_hash_now], eax
    add rsp, 8
    ret

; ----------------------------------------------------------------------------
; sm_slot(ecx = steps back, 1 = newest) -> eax = ring slot
; ----------------------------------------------------------------------------
sm_slot:
    mov eax, [history_write_idx]
    sub eax, ecx
    jge .s_ret
    add eax, HISTORY_COUNT
.s_ret:
    ret

; ----------------------------------------------------------------------------
; sm_suggest - set sugg_ptr / sugg_len for the current line (0 = none)
; ----------------------------------------------------------------------------
sm_suggest:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov dword [sugg_len], 0
    cmp byte [sugg_off], 0
    jne .g_ret
    cmp byte [history_browsing], 0
    jne .g_ret
    mov r12d, [line_len]
    test r12d, r12d
    jz .g_ret
    cmp r12d, [line_cursor]
    jne .g_ret
    cmp r12d, HISTORY_ENTRY_SIZE - 1
    jae .g_ret

    xor r13d, r13d                      ; pass: 0 here+worked, 1 worked, 2 any
.g_pass:
    mov r14d, 1                         ; steps back
.g_entry:
    cmp r14d, [history_count]
    ja .g_next_pass
    mov ecx, r14d
    call sm_slot
    mov r15d, eax                       ; r15 = slot
    inc r14d
    cmp r13d, 2
    je .g_text
    cmp byte [hist_meta_stat + r15], 0
    jne .g_entry
    test r13d, r13d
    jnz .g_text
    mov eax, [hist_meta_hash + r15 * 4]
    cmp eax, [sm_cwd_hash_now]
    jne .g_entry
.g_text:
    imul eax, r15d, HISTORY_ENTRY_SIZE
    lea rbx, [history_buf + rax]        ; rbx = entry
    xor ecx, ecx
.g_cmp:
    cmp ecx, r12d
    jae .g_tail
    mov al, [line_buf + rcx]
    cmp al, [rbx + rcx]
    jne .g_entry
    inc ecx
    jmp .g_cmp
.g_tail:
    ; something must follow, and nothing that would garble the screen
    cmp byte [rbx + rcx], 0
    je .g_entry
    lea rsi, [rbx + rcx]
    xor edx, edx
.g_len:
    movzx eax, byte [rsi + rdx]
    test eax, eax
    jz .g_found
    cmp eax, 0x20
    jb .g_entry
    cmp eax, 0x7F
    je .g_entry
    inc edx
    jmp .g_len
.g_found:
    mov [sugg_ptr], rsi
    ; never let line + suggestion outgrow the line buffer
    mov eax, MAX_INPUT - 2
    sub eax, r12d
    cmp edx, eax
    jbe .g_store
    mov edx, eax
.g_store:
    mov [sugg_len], edx
    jmp .g_ret
.g_next_pass:
    inc r13d
    cmp r13d, 3
    jb .g_pass
.g_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; sm_draw_suggestion - redraw_line: work out and print the grey suggestion
; Returns eax = columns it takes (0 = none)
; ----------------------------------------------------------------------------
sm_draw_suggestion:
    sub rsp, 8
    call sm_suggest
    mov eax, [sugg_len]
    test eax, eax
    jz .d_ret
    cmp byte [color_enabled], 0
    je .d_text
    lea rdi, [sm_c_sugg_true]
    cmp byte [hl_basic], 0
    je .d_color
    lea rdi, [sm_c_sugg_basic]
.d_color:
    call print_cstring
.d_text:
    mov rdi, [sugg_ptr]
    mov esi, [sugg_len]
    call print_string_len
    cmp byte [color_enabled], 0
    je .d_cols
    lea rdi, [sm_c_reset]
    call print_cstring
.d_cols:
    mov rdi, [sugg_ptr]
    mov esi, [sugg_len]
    call utf8_cols
.d_ret:
    add rsp, 8
    ret

; ----------------------------------------------------------------------------
; sm_accept - Right/End at the end of the line: take the suggestion
; Returns eax = 1 when something was added (the line is redrawn)
; ----------------------------------------------------------------------------
sm_accept:
    sub rsp, 8
    xor eax, eax
    mov ecx, [sugg_len]
    test ecx, ecx
    jz .a_ret
    mov edx, [line_len]
    cmp edx, [line_cursor]
    jne .a_none
    mov rsi, [sugg_ptr]
    lea rdi, [line_buf + rdx]
    add [line_len], ecx
.a_copy:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .a_copy
    mov byte [rdi], 0
    mov eax, [line_len]
    mov [line_cursor], eax
    mov dword [sugg_len], 0
    call redraw_line
    mov eax, 1
    jmp .a_ret
.a_none:
    xor eax, eax
.a_ret:
    add rsp, 8
    ret

; ----------------------------------------------------------------------------
; sm_clear_extras - before Enter or ^C: redraw without the suggestion and the
; Tab menu, so neither stays on the screen
; ----------------------------------------------------------------------------
sm_clear_extras:
    sub rsp, 8
    mov eax, [sugg_len]
    or al, [tab_menu_shown]
    test eax, eax
    jz .c_ret
    mov byte [tab_menu_shown], 0
    mov byte [sugg_off], 1
    call redraw_line
    mov byte [sugg_off], 0
.c_ret:
    add rsp, 8
    ret

; sm_close_menu - a key other than Tab: erase the menu (no-op if none)
sm_close_menu:
    sub rsp, 8
    cmp byte [tab_menu_shown], 0
    je .m_ret
    mov byte [tab_menu_shown], 0
    call redraw_line
.m_ret:
    add rsp, 8
    ret

; ----------------------------------------------------------------------------
; History notes
; ----------------------------------------------------------------------------

; sm_note_clear(eax = slot) - history_add: a new entry starts unknown
sm_note_clear:
    mov dword [hist_meta_hash + rax * 4], 0
    mov byte [hist_meta_stat + rax], 0
    ret

; sm_before_run - main loop, after history_add: remember the folder
sm_before_run:
    sub rsp, 8
    call sm_cwd_hash
    mov [sm_run_hash], eax
    mov byte [sm_note_pending], 1
    add rsp, 8
    ret

; sm_after_run - main loop, after the line ran: store folder and status in
; the newest entry and append the note to the history file
sm_after_run:
    push rbx
    cmp byte [sm_note_pending], 0
    je .r_ret
    mov byte [sm_note_pending], 0
    cmp byte [ash_cont], 0
    jne .r_ret                          ; an open block has not run yet
    cmp dword [history_count], 0
    je .r_ret
    mov ecx, 1
    call sm_slot
    mov ebx, eax
    mov edx, [sm_run_hash]
    mov [hist_meta_hash + rbx * 4], edx
    mov eax, [last_exit_status]
    test eax, eax
    jz .r_stat
    cmp eax, 255
    jbe .r_stat
    mov eax, 255
.r_stat:
    mov [hist_meta_stat + rbx], al
    cmp byte [interactive_mode], 0
    je .r_ret
    cmp byte [history_file_path], 0
    je .r_ret
    lea rdi, [sm_meta_line]
    mov eax, ebx
    call sm_fmt_meta
    lea rsi, [sm_meta_line]
    mov rbx, rax
    sub rbx, rsi                        ; bytes
    lea rdi, [history_file_path]
    mov esi, O_WRONLY | O_APPEND | 0x80000
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .r_ret
    mov edi, eax
    push rdi
    lea rsi, [sm_meta_line]
    mov rdx, rbx
    mov eax, SYS_WRITE
    syscall
    pop rdi
    mov eax, SYS_CLOSE
    syscall
.r_ret:
    pop rbx
    ret

; sm_fmt_meta(rdi = dst, eax = slot) -> rax = end of "#asm:HASH:STATUS\n"
sm_fmt_meta:
    mov r8d, eax
    mov dword [rdi], '#asm'
    mov byte [rdi + 4], ':'
    add rdi, 5
    mov edx, [hist_meta_hash + r8 * 4]
    mov ecx, 28
.f_hex:
    mov eax, edx
    shr eax, cl
    and eax, 15
    mov al, [sm_hex + rax]
    mov [rdi], al
    inc rdi
    sub ecx, 4
    jns .f_hex
    mov byte [rdi], ':'
    inc rdi
    movzx eax, byte [hist_meta_stat + r8]
    cmp eax, 100
    jb .f_tens
    xor edx, edx
    mov ecx, 100
    div ecx
    add al, '0'
    mov [rdi], al
    inc rdi
    mov eax, edx
    jmp .f_two
.f_tens:
    cmp eax, 10
    jb .f_one
.f_two:
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [rdi], al
    inc rdi
    mov eax, edx
.f_one:
    add al, '0'
    mov [rdi], al
    mov byte [rdi + 1], 10
    lea rax, [rdi + 2]
    ret

; sm_has_meta(eax = slot) -> eax != 0 when the slot carries a note
sm_has_meta:
    mov ecx, [hist_meta_hash + rax * 4]
    movzx eax, byte [hist_meta_stat + rax]
    or eax, ecx
    ret

; sm_load_meta(rdi = line) -> eax = 1 if it was a "#asm:" note (applied to
; the newest entry), 0 if it is an ordinary line
sm_load_meta:
    cmp dword [rdi], '#asm'
    jne .l_no
    cmp byte [rdi + 4], ':'
    jne .l_no
    add rdi, 5
    xor edx, edx                        ; hash
    mov ecx, 8
.l_hex:
    movzx eax, byte [rdi]
    sub eax, '0'
    cmp eax, 9
    jbe .l_hex_add
    movzx eax, byte [rdi]
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 5
    ja .l_yes                           ; malformed: drop the line quietly
    add eax, 10
.l_hex_add:
    shl edx, 4
    or edx, eax
    inc rdi
    dec ecx
    jnz .l_hex
    cmp byte [rdi], ':'
    jne .l_yes
    inc rdi
    xor r8d, r8d                        ; status
.l_dec:
    movzx eax, byte [rdi]
    sub eax, '0'
    cmp eax, 9
    ja .l_apply
    imul r8d, r8d, 10
    add r8d, eax
    inc rdi
    cmp r8d, 255
    jbe .l_dec
    mov r8d, 255
.l_apply:
    cmp dword [history_count], 0
    je .l_yes
    mov ecx, 1
    push rdx
    call sm_slot
    pop rdx
    mov [hist_meta_hash + rax * 4], edx
    mov [hist_meta_stat + rax], r8b
.l_yes:
    mov eax, 1
    ret
.l_no:
    xor eax, eax
    ret

; sm_hist_fail_mark(eax = slot) - `history`: "  [N]" after a failed command
sm_hist_fail_mark:
    push rbx
    movzx ebx, byte [hist_meta_stat + rax]
    test ebx, ebx
    jz .k_ret
    cmp byte [color_enabled], 0
    je .k_text
    cmp byte [redir_stdout_active], 0
    jne .k_text
    lea rdi, [sm_c_fail_true]
    cmp byte [hl_basic], 0
    je .k_color
    lea rdi, [sm_c_fail_basic]
.k_color:
    call print_cstring
.k_text:
    lea rdi, [sm_s_fail_pre]
    call print_cstring
    mov eax, ebx
    call print_number
    lea rdi, [sm_s_fail_post]
    call print_cstring
    cmp byte [color_enabled], 0
    je .k_ret
    cmp byte [redir_stdout_active], 0
    jne .k_ret
    lea rdi, [sm_c_reset]
    call print_cstring
.k_ret:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; sm_tab_menu - list every match of the running Tab cycle under the line
; Uses find_pattern (the folder), tab_name_prefix + tab_name_off (the typed
; name) and tab_cycle_idx - 1 (the match now in the line).
; ----------------------------------------------------------------------------
sm_tab_menu:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40         ; [rsp] total, [rsp+4] kept, [rsp+8] widest, [rsp+12] cols
                        ; [rsp+16] shown, [rsp+20] lines printed, [rsp+24] fd
                        ; [rsp+28] columns of the current cell

    mov byte [tab_menu_shown], 0
    lea rdi, [find_pattern]
    mov esi, O_RDONLY | O_DIRECTORY | 0x80000
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .t_ret
    mov [rsp + 24], eax
    mov dword [rsp], 0
    mov dword [rsp + 4], 0
    mov dword [rsp + 8], 0
    lea r15, [sm_menu_buf]              ; r15 = write position

.t_read:
    mov edi, [rsp + 24]
    lea rsi, [dirent_buf]
    mov edx, DIRENT_BUF_SIZE
    mov eax, SYS_GETDENTS64
    syscall
    test rax, rax
    jle .t_closed
    mov r14d, eax
    xor r12d, r12d
.t_entry:
    cmp r12d, r14d
    jae .t_read
    lea rbx, [dirent_buf + r12]
    movzx eax, word [rbx + DIRENT_D_RECLEN]
    add r12d, eax
    lea r9, [rbx + DIRENT_D_NAME]
    cmp byte [r9], '.'
    jne .t_pfx
    cmp byte [r9 + 1], 0
    je .t_entry
    cmp byte [r9 + 1], '.'
    jne .t_pfx
    cmp byte [r9 + 2], 0
    je .t_entry
.t_pfx:
    ; same test as tab_complete: case-insensitive prefix, no control bytes
    mov r8d, [tab_name_off]
    lea r8, [tab_name_prefix + r8]
    mov ecx, [tab_name_prefix_len]
    sub ecx, [tab_name_off]
    xor edx, edx
.t_cmp:
    cmp edx, ecx
    jge .t_ctl
    movzx edi, byte [r8 + rdx]
    movzx r10d, byte [r9 + rdx]
    lea eax, [rdi - 'A']
    cmp eax, 25
    ja .t_c2
    add edi, 32
.t_c2:
    lea eax, [r10 - 'A']
    cmp eax, 25
    ja .t_c3
    add r10d, 32
.t_c3:
    cmp edi, r10d
    jne .t_entry
    inc edx
    jmp .t_cmp
.t_ctl:
    xor edx, edx
.t_ctl_loop:
    movzx eax, byte [r9 + rdx]
    test eax, eax
    jz .t_match
    cmp eax, 0x20
    jb .t_entry
    cmp eax, 0x7F
    je .t_entry
    inc edx
    jmp .t_ctl_loop
.t_match:
    inc dword [rsp]                     ; edx = name length
    lea rax, [r15 + rdx + 2]
    lea rcx, [sm_menu_buf + SM_MENU_BUF]
    cmp rax, rcx
    ja .t_entry                         ; buffer full: count it only
    movzx eax, byte [rbx + DIRENT_D_TYPE]
    mov [r15], al
    inc r15
    push rdx
    push r9
    mov rdi, r9
    mov esi, edx
    call utf8_cols
    pop r9
    pop rdx
    movzx ecx, byte [r15 - 1]
    cmp ecx, DT_DIR
    jne .t_width
    inc eax                             ; the "/" after a folder
.t_width:
    cmp eax, [rsp + 8]
    jbe .t_copy
    mov [rsp + 8], eax
.t_copy:
    xor ecx, ecx
.t_copy_loop:
    mov al, [r9 + rcx]
    mov [r15 + rcx], al
    inc ecx
    test al, al
    jnz .t_copy_loop
    add r15, rcx
    inc dword [rsp + 4]
    jmp .t_entry

.t_closed:
    mov edi, [rsp + 24]
    mov eax, SYS_CLOSE
    syscall
    cmp dword [rsp], 2
    jb .t_ret                           ; one match: no menu

    ; columns: widest + 2 per item, inside the terminal minus the indent
    call cur_cols
    cmp eax, 0x7FFFFFFF
    jne .t_have_cols
    mov eax, 80
.t_have_cols:
    sub eax, 2
    mov ecx, [rsp + 8]
    add ecx, 2
    cmp ecx, eax
    ja .t_ret                           ; a name wider than the screen
    xor edx, edx
    div ecx
    mov [rsp + 12], eax                 ; items per row (>= 1)
    imul eax, eax, SM_MENU_ROWS
    mov ecx, [rsp + 4]
    cmp ecx, eax
    jbe .t_shown
    mov ecx, eax
.t_shown:
    mov [rsp + 16], ecx
    mov dword [rsp + 20], 0

    call ob_begin
    ; down to the row after the text
    mov eax, [rd_end_row]
    sub eax, [cursor_row]
    jle .t_draw
    mov ecx, 'B'
    call write_csi_num
.t_draw:
    lea r15, [sm_menu_buf]
    xor r12d, r12d                      ; item index
    mov r13d, [tab_cycle_idx]
    dec r13d                            ; the match now in the line
.t_item:
    cmp r12d, [rsp + 16]
    jae .t_more
    xor edx, edx
    mov eax, r12d
    div dword [rsp + 12]
    test edx, edx
    jnz .t_cell
    lea rdi, [sm_s_crlf]                ; new menu row
    call print_cstring
    lea rdi, [sm_s_indent]
    call print_cstring
    inc dword [rsp + 20]
.t_cell:
    movzx ebx, byte [r15]               ; type
    inc r15
    cmp r12d, r13d
    jne .t_dircolor
    lea rdi, [sm_c_sel]
    call print_cstring
.t_dircolor:
    cmp ebx, DT_DIR
    jne .t_name
    cmp byte [color_enabled], 0
    je .t_name
    lea rdi, [sm_c_dir_true]
    cmp byte [hl_basic], 0
    je .t_dc
    lea rdi, [sm_c_dir_basic]
.t_dc:
    call print_cstring
.t_name:
    mov rdi, r15
    call str_len
    mov r14d, eax                       ; bytes
    mov rdi, r15
    mov esi, eax
    call print_string_len
    mov rdi, r15
    mov esi, r14d
    call utf8_cols
    mov [rsp + 28], eax                 ; columns
    lea r15, [r15 + 1]
.t_skip:
    cmp byte [r15 - 1], 0
    je .t_after
    inc r15
    jmp .t_skip
.t_after:
    cmp ebx, DT_DIR
    jne .t_reset
    lea rdi, [sm_s_slash]
    call print_cstring
    inc dword [rsp + 28]
.t_reset:
    cmp byte [color_enabled], 0
    jne .t_do_reset
    cmp r12d, r13d
    jne .t_pad
.t_do_reset:
    lea rdi, [sm_c_reset]
    call print_cstring
.t_pad:
    mov r14d, [rsp + 8]
    add r14d, 2
    sub r14d, [rsp + 28]                ; columns used by this cell
.t_pad_loop:
    test r14d, r14d
    jle .t_next
    mov esi, r14d
    cmp esi, 64
    jbe .t_pad_out
    mov esi, 64
.t_pad_out:
    sub r14d, esi
    lea rdi, [hp_spaces]
    call print_string_len
    jmp .t_pad_loop
.t_next:
    inc r12d
    jmp .t_item

.t_more:
    mov eax, [rsp]
    sub eax, [rsp + 16]
    jle .t_back
    mov ebx, eax
    lea rdi, [sm_s_crlf]
    call print_cstring
    inc dword [rsp + 20]
    lea rdi, [sm_s_more_pre]
    call print_cstring
    mov eax, ebx
    call print_number
    lea rdi, [sm_s_more_post]
    call print_cstring

.t_back:
    ; back up to the cursor's row and column
    mov eax, [rsp + 20]
    add eax, [rd_end_row]
    sub eax, [cursor_row]
    jle .t_col
    mov ecx, 'A'
    call write_csi_num
.t_col:
    lea rdi, [line_buf]
    mov esi, [line_cursor]
    call utf8_cols
    add eax, [prompt_total_len]
    mov ebx, eax
    call cur_cols
    mov ecx, eax
    mov eax, ebx
    xor edx, edx
    div ecx
    lea eax, [rdx + 1]
    mov ecx, 'G'
    call write_csi_num
    call ob_end
    mov byte [tab_menu_shown], 1

.t_ret:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

section .data
    sm_s_slash      db "/", 0
section .text
