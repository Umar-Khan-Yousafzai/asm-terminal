; ============================================================================
; Pathname expansion for builtin arguments
;
; Programs started through /bin/sh get their globs expanded there. The
; builtins that take file names (echo, ls, cat, grep, del, copy, ...) get the
; same treatment here, before the handler runs:
;   - * ? [...] [!...] in an unquoted, unescaped, unmarked part of a word
;     (a value that came from $VAR or $( ) carries EV_MARK bytes and never
;     globs, quoted and backslash-escaped characters stay literal)
;   - patterns with directory parts: src/*.c, */x, /etc/*.conf, */
;   - matches are sorted bytewise, names that begin with a dot only match a
;     pattern part that begins with a literal dot, "." and ".." never match
;   - a word without a match is left exactly as it was
; Every match is written back as one word: bytes that could be read as
; syntax, blanks and the marker itself get an EV_MARK in front, which is the
; encoding expand_env_vars uses for data, so a name with a space stays one
; word for every consumer.
;
; Included from terminal_linux.asm (Linux x86-64, System V ABI).
; ============================================================================

%define GLOB_PAT_MAX        8192        ; a longer pattern cannot name a path
%define GLOB_MAX_COMPS      64          ; directory levels in one pattern
%define GLOB_PATH_MAX       4096
%define GLOB_POOL_SIZE      (512 * 1024) ; matching names of the levels being walked
%define GLOB_PTRS           32768
%define GLOB_DENTS          32768
%define GLOB_MAX_TOKS       4096

section .data
    glob_e_long         db "ash: pathname expansion too long", 10, 0
    glob_e_many         db "ash: too many files match", 10, 0
    glob_e_notdir       db "ash: the last name must be a directory when several files are named", 10, 0
    glob_e_toks         db "ash: too many names", 10, 0
    ; Bytes of a file name that get an EV_MARK in front (see ev_special_chars)
    glob_special        db 0x5C, 0x27, '"', '`', '$', '|', '&', ';', '<', '>'
                        db '(', ')', '*', '?', '[', '~', '=', '#', ' ', 9, 10
                        db EV_MARK, 0
    glob_s_dash_f       db "-f", 0
    glob_s_dash_p       db "-p", 0

    ; Builtins whose arguments are expanded
    dc_glob_handlers    dq handler_echo, handler_cd, handler_type, handler_mkdir
                        dq handler_rmdir, handler_del_safe, handler_copy_safe
                        dq handler_move_safe, handler_ls, handler_grep
                        dq handler_pushd, handler_source, 0

section .bss
    alignb 8
    glob_comps          resq GLOB_MAX_COMPS
    glob_ptrs           resq GLOB_PTRS
    glob_toks           resq GLOB_MAX_TOKS
    glob_pool_top       resq 1
    glob_out_cur        resq 1
    glob_out_end        resq 1
    glob_ncomp          resd 1
    glob_plen           resd 1          ; bytes of glob_path in use
    glob_ptr_top        resd 1
    glob_nmatch         resd 1          ; matches of the word being expanded
    glob_total          resd 1          ; matches of the whole argument text
    glob_err            resb 1          ; 1 = result too long, 2 = too many names
    glob_has            resb 1          ; the word has an unquoted * ? [
    glob_toolong        resb 1          ; the word's pattern did not fit
    alignb 8
    glob_stat           resb 144
    glob_pat            resb GLOB_PAT_MAX + 16
    glob_path           resb GLOB_PATH_MAX + 8
    glob_pool           resb GLOB_POOL_SIZE
    glob_dents          resb GLOB_DENTS
    glob_out_buf        resb LINE_MAX
section .text

; ----------------------------------------------------------------------------
; dc_glob_ok(rdi = handler) -> eax = 1 if its arguments get pathname expansion
; ----------------------------------------------------------------------------
dc_glob_ok:
    lea rsi, [dc_glob_handlers]
.go_loop:
    mov rax, [rsi]
    test rax, rax
    jz .go_no
    cmp rax, rdi
    je .go_yes
    add rsi, 8
    jmp .go_loop
.go_yes:
    mov eax, 1
    ret
.go_no:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; dc_glob_args(rdi = argument text inside input_buf, rsi = handler)
;   -> eax = 1 when the command was dealt with here (error, or run once per
;      name), 0 when the handler should run on the text at rdi, which has been
;      rewritten if anything matched.
; ----------------------------------------------------------------------------
dc_glob_args:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    mov rbx, rdi
    mov r12, rsi

    ; Nothing to do unless a * ? [ appears somewhere
    mov rsi, rdi
.ga_scan:
    movzx eax, byte [rsi]
    test al, al
    jz .ga_none
    cmp al, '*'
    je .ga_go
    cmp al, '?'
    je .ga_go
    cmp al, '['
    je .ga_go
    inc rsi
    jmp .ga_scan
.ga_none:
    xor eax, eax
    jmp .ga_ret

.ga_go:
    lea rax, [input_buf]
    mov rsi, rbx
    sub rsi, rax
    mov eax, LINE_MAX - 1
    sub eax, esi                    ; room for the rewritten text
    mov esi, eax
    mov rdi, rbx
    call glob_expand_args
    test eax, eax
    jnz .ga_handled                 ; message printed
    cmp dword [glob_total], 0
    je .ga_none                     ; no match anywhere: text stays as typed
    mov rdi, rbx
    lea rsi, [glob_out_buf]
    call str_copy
    cmp dword [glob_total], 2
    jb .ga_none
    mov rdi, r12
    mov rsi, rbx
    call glob_multi
    jmp .ga_ret
.ga_handled:
    cmp eax, 2
    je .ga_intr
    mov dword [last_exit_status], 1
.ga_intr:
    mov eax, 1
.ga_ret:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; glob_out_put(rsi = bytes, edx = count) - append to glob_out_buf, glob_err = 1
; when it does not fit
; ----------------------------------------------------------------------------
glob_out_put:
    mov rdi, [glob_out_cur]
    mov rax, [glob_out_end]
    sub rax, rdi
    cmp rax, rdx
    jb .op_over
    mov ecx, edx
    rep movsb
    mov [glob_out_cur], rdi
    ret
.op_over:
    mov byte [glob_err], 1
    ret

; ----------------------------------------------------------------------------
; glob_expand_args(rdi = argument text, esi = most bytes the result may have)
;   -> eax = 0 and glob_out_buf = the text with every glob word replaced by
;      its matches (glob_total counts them), or 1 after a message
; ----------------------------------------------------------------------------
glob_expand_args:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    mov rbx, rdi
    lea rax, [glob_out_buf]
    mov [glob_out_cur], rax
    mov ecx, esi
    add rax, rcx
    mov [glob_out_end], rax
    mov byte [glob_err], 0
    mov dword [glob_total], 0
    mov dword [glob_ptr_top], 0
    lea rax, [glob_pool]
    mov [glob_pool_top], rax

.ea_loop:
    movzx eax, byte [rbx]
    test al, al
    jz .ea_done
    cmp al, ' '
    je .ea_blank
    cmp al, 9
    je .ea_blank
    cmp al, 10
    jne .ea_word
.ea_blank:
    mov rsi, rbx
    mov edx, 1
    call glob_out_put
    inc rbx
    jmp .ea_check
.ea_word:
    mov r12, rbx                    ; the word as written
    mov rdi, rbx
    call glob_build
    mov rbx, rax
    cmp byte [glob_has], 0
    je .ea_copy
    cmp byte [glob_toolong], 0
    jne .ea_copy
    call glob_expand_word
    cmp byte [glob_err], 0
    jne .ea_fail
    cmp dword [glob_nmatch], 0
    jne .ea_loop                    ; the matches are written already
.ea_copy:
    mov rsi, r12
    mov rdx, rbx
    sub rdx, r12
    call glob_out_put
.ea_check:
    cmp byte [glob_err], 0
    je .ea_loop
    jmp .ea_fail

.ea_done:
    mov rdi, [glob_out_cur]
    mov byte [rdi], 0
    xor eax, eax
    jmp .ea_ret
.ea_fail:
    cmp byte [glob_err], 3
    je .ea_intr
    lea rdi, [glob_e_long]
    cmp byte [glob_err], 1
    je .ea_msg
    lea rdi, [glob_e_many]
.ea_msg:
    call ash_write_err
    mov eax, 1
    jmp .ea_ret
.ea_intr:
    mov byte [ctrl_c_flag], 0
    mov dword [last_exit_status], 130
    mov eax, 2
.ea_ret:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; glob_build(rdi = start of a word) -> rax = the end of the word
; Writes the word as a pattern to glob_pat: quoted, escaped and marked
; characters that the matcher reads as syntax (* ? [ ] \) get a backslash.
; glob_has = 1 when an unquoted * ? [ was seen, glob_toolong = 1 when the
; pattern did not fit.
; ----------------------------------------------------------------------------
glob_build:
    mov rsi, rdi
    lea rdi, [glob_pat]
    lea r8, [glob_pat + GLOB_PAT_MAX - 2]
    xor ecx, ecx                    ; 0 plain, 1 '...', 2 "..."
    xor r9d, r9d
    mov byte [glob_toolong], 0
.gb_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .gb_end
    cmp al, EV_MARK
    je .gb_mark
    test ecx, ecx
    jnz .gb_quoted
    cmp al, ' '
    je .gb_end
    cmp al, 9
    je .gb_end
    cmp al, 10
    je .gb_end
    cmp al, 0x27
    je .gb_open_sq
    cmp al, '"'
    je .gb_open_dq
    cmp al, '\'
    je .gb_bs
    cmp al, '*'
    je .gb_glob
    cmp al, '?'
    je .gb_glob
    cmp al, '['
    je .gb_glob
    inc rsi
    jmp .gb_raw
.gb_glob:
    mov r9d, 1
    inc rsi
    jmp .gb_raw
.gb_open_sq:
    mov ecx, 1
    inc rsi
    jmp .gb_loop
.gb_open_dq:
    mov ecx, 2
    inc rsi
    jmp .gb_loop
.gb_bs:
    movzx eax, byte [rsi + 1]
    test al, al
    jnz .gb_bs_c
    mov al, '\'                     ; a trailing backslash is a plain one
    inc rsi
    jmp .gb_lit
.gb_bs_c:
    add rsi, 2
    jmp .gb_lit
.gb_mark:
    movzx eax, byte [rsi + 1]
    test al, al
    jnz .gb_mark_c
    inc rsi                         ; a marker with nothing behind it
    jmp .gb_end
.gb_mark_c:
    add rsi, 2
    jmp .gb_lit
.gb_quoted:
    cmp ecx, 1
    jne .gb_dq
    cmp al, 0x27
    jne .gb_lit_adv
    xor ecx, ecx
    inc rsi
    jmp .gb_loop
.gb_dq:
    cmp al, '"'
    jne .gb_dq_bs
    xor ecx, ecx
    inc rsi
    jmp .gb_loop
.gb_dq_bs:
    cmp al, '\'
    jne .gb_lit_adv
    movzx edx, byte [rsi + 1]       ; only these four are escapes inside "..."
    cmp dl, '"'
    je .gb_dq_esc
    cmp dl, '\'
    je .gb_dq_esc
    cmp dl, '$'
    je .gb_dq_esc
    cmp dl, '`'
    jne .gb_lit_adv
.gb_dq_esc:
    inc rsi
    mov eax, edx
.gb_lit_adv:
    inc rsi
.gb_lit:
    cmp al, '*'
    je .gb_esc
    cmp al, '?'
    je .gb_esc
    cmp al, '['
    je .gb_esc
    cmp al, ']'
    je .gb_esc
    cmp al, '\'
    jne .gb_raw
.gb_esc:
    cmp rdi, r8
    jae .gb_over
    mov byte [rdi], '\'
    inc rdi
.gb_raw:
    cmp rdi, r8
    jae .gb_over
    mov [rdi], al
    inc rdi
    jmp .gb_loop
.gb_over:
    mov byte [glob_toolong], 1
    jmp .gb_loop
.gb_end:
    mov byte [rdi], 0
    mov [glob_has], r9b
    mov rax, rsi
    ret

; ----------------------------------------------------------------------------
; glob_expand_word - expand glob_pat; the matches are appended to the output
; text (separated by blanks). glob_nmatch says how many there were.
; ----------------------------------------------------------------------------
glob_expand_word:
    sub rsp, 8
    mov dword [glob_nmatch], 0
    ; Split the pattern at '/'
    lea rsi, [glob_pat]
    lea rdx, [glob_comps]
    mov [rdx], rsi
    mov ecx, 1
.ew_split:
    movzx eax, byte [rsi]
    test al, al
    jz .ew_split_done
    cmp al, '\'
    jne .ew_not_bs
    cmp byte [rsi + 1], 0
    je .ew_split_done
    add rsi, 2
    jmp .ew_split
.ew_not_bs:
    inc rsi
    cmp al, '/'
    jne .ew_split
    mov byte [rsi - 1], 0
    cmp ecx, GLOB_MAX_COMPS
    jae .ew_ret                     ; too deep: leave the word alone
    mov [rdx + rcx * 8], rsi
    inc ecx
    jmp .ew_split
.ew_split_done:
    mov [glob_ncomp], ecx
    mov dword [glob_plen], 0
    mov byte [glob_path], 0
    xor edi, edi
    call glob_level
    mov eax, [glob_nmatch]
    add [glob_total], eax
.ew_ret:
    add rsp, 8
    ret

; glob_is_pattern(rdi = pattern part) -> eax = 1 if it has an unescaped * ? [
glob_is_pattern:
.ip_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .ip_no
    cmp al, '\'
    je .ip_bs
    cmp al, '*'
    je .ip_yes
    cmp al, '?'
    je .ip_yes
    cmp al, '['
    je .ip_yes
    inc rdi
    jmp .ip_loop
.ip_bs:
    cmp byte [rdi + 1], 0
    je .ip_no
    add rdi, 2
    jmp .ip_loop
.ip_yes:
    mov eax, 1
    ret
.ip_no:
    xor eax, eax
    ret

; glob_append(rdi = text, esi = 1 to drop backslashes) - add to glob_path.
; eax = 0 done, 1 when the path would pass GLOB_PATH_MAX (nothing is kept).
glob_append:
    mov edx, [glob_plen]
    lea r8, [glob_path]
.ap_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .ap_done
    inc rdi
    test esi, esi
    jz .ap_put
    cmp al, '\'
    jne .ap_put
    movzx eax, byte [rdi]
    test al, al
    jz .ap_done
    inc rdi
.ap_put:
    cmp edx, GLOB_PATH_MAX - 2
    jae .ap_over
    mov [r8 + rdx], al
    inc edx
    jmp .ap_loop
.ap_done:
    mov byte [r8 + rdx], 0
    mov [glob_plen], edx
    xor eax, eax
    ret
.ap_over:
    mov eax, 1
    ret

; glob_append_slash - eax = 0, or 1 when there is no room
glob_append_slash:
    mov edx, [glob_plen]
    cmp edx, GLOB_PATH_MAX - 2
    jae .as_over
    lea r8, [glob_path]
    mov byte [r8 + rdx], '/'
    inc edx
    mov byte [r8 + rdx], 0
    mov [glob_plen], edx
    xor eax, eax
    ret
.as_over:
    mov eax, 1
    ret

; glob_path_stat(edi = flags for newfstatat) -> eax = 0 when glob_path exists
glob_path_stat:
    mov r10d, edi
    mov edi, AT_FDCWD
    lea rsi, [glob_path]
    lea rdx, [glob_stat]
    mov eax, SYS_NEWFSTATAT
    syscall
    ret

; glob_emit_path - add glob_path to the output as one word
glob_emit_path:
    mov rdx, [glob_out_cur]
    mov rcx, [glob_out_end]
    mov eax, [glob_plen]
    lea rsi, [rdx + rax * 2 + 2]
    cmp rsi, rcx
    ja .ep_over
    cmp dword [glob_nmatch], 0
    je .ep_first
    mov byte [rdx], ' '
    inc rdx
.ep_first:
    lea rsi, [glob_path]
.ep_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .ep_done
    inc rsi
    lea r8, [glob_special]
.ep_chk:
    movzx r9d, byte [r8]
    test r9d, r9d
    jz .ep_plain
    cmp r9d, eax
    je .ep_mark
    inc r8
    jmp .ep_chk
.ep_mark:
    mov byte [rdx], EV_MARK
    inc rdx
.ep_plain:
    mov [rdx], al
    inc rdx
    jmp .ep_loop
.ep_done:
    mov [glob_out_cur], rdx
    inc dword [glob_nmatch]
    ret
.ep_over:
    mov byte [glob_err], 1
    ret

; ----------------------------------------------------------------------------
; glob_level(edi = index of the pattern part to match)
; glob_path holds the directory reached so far, with a trailing '/'. A part
; without glob characters is appended as it is; one with them is matched
; against the directory's entries, in sorted order, and each entry that fits
; is followed into the next part (or written out when it was the last).
; ----------------------------------------------------------------------------
glob_level:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72

    mov ebx, edi
    cmp byte [glob_err], 0
    jne .gl_ret
    mov r13d, [glob_plen]
    mov r12, [glob_comps + rbx * 8]
    mov eax, [glob_ncomp]
    dec eax
    xor r14d, r14d
    cmp ebx, eax
    sete r14b                       ; r14d = 1 for the last part
    mov rdi, r12
    call glob_is_pattern
    test eax, eax
    jnz .gl_glob

    ; --- a part without glob characters ---
    cmp byte [r12], 0
    jne .gl_lit_name
    test ebx, ebx
    jnz .gl_empty_mid
    mov byte [glob_path], '/'       ; a leading '/': an absolute pattern
    mov byte [glob_path + 1], 0
    mov dword [glob_plen], 1
    jmp .gl_next
.gl_empty_mid:
    test r14d, r14d
    jz .gl_next                     ; "a//b" is "a/b"
    mov edi, 0                      ; "dir/": only a directory stays
    call glob_path_stat
    test eax, eax
    jnz .gl_ret
    mov eax, [glob_stat + STAT_ST_MODE]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .gl_ret
    call glob_emit_path
    jmp .gl_ret
.gl_lit_name:
    mov rdi, r12
    mov esi, 1
    call glob_append
    test eax, eax
    jnz .gl_ret
    test r14d, r14d
    jnz .gl_lit_last
    call glob_append_slash
    test eax, eax
    jnz .gl_ret
.gl_next:
    lea edi, [rbx + 1]
    call glob_level
    jmp .gl_ret
.gl_lit_last:
    mov edi, AT_SYMLINK_NOFOLLOW
    call glob_path_stat
    test eax, eax
    jnz .gl_ret
    call glob_emit_path
    jmp .gl_ret

    ; --- a part with glob characters: read the directory ---
.gl_glob:
    lea rdi, [glob_path]
    cmp dword [glob_plen], 0
    jne .gl_open
    lea rdi, [str_dot]
.gl_open:
    mov esi, O_RDONLY | O_DIRECTORY | 0x80000
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .gl_ret
    mov r15d, eax                   ; directory descriptor

    mov rax, [glob_pool_top]
    mov [rbp - 48], rax
    mov eax, [glob_ptr_top]
    mov [rbp - 88], rax             ; where this level's names start

    ; A name that begins with a dot needs a pattern part that does
    xor eax, eax
    cmp byte [r12], '.'
    je .gl_dot_ok
    cmp byte [r12], '\'
    jne .gl_dot_set
    cmp byte [r12 + 1], '.'
    jne .gl_dot_set
.gl_dot_ok:
    mov eax, 1
.gl_dot_set:
    mov [rbp - 56], rax

.gl_read:
    mov edi, r15d
    lea rsi, [glob_dents]
    mov edx, GLOB_DENTS
    mov eax, SYS_GETDENTS64
    syscall
    test rax, rax
    jle .gl_read_done
    lea rcx, [glob_dents]
    mov [rbp - 64], rcx
    add rcx, rax
    mov [rbp - 72], rcx
.gl_ent:
    cmp byte [ctrl_c_flag], 0       ; ^C ends a walk over a big tree
    jne .gl_intr
    mov rsi, [rbp - 64]
    cmp rsi, [rbp - 72]
    jae .gl_read
    movzx eax, word [rsi + 16]
    lea rdx, [rsi + rax]
    mov [rbp - 64], rdx
    lea rsi, [rsi + 19]             ; d_name
    mov [rbp - 80], rsi
    cmp byte [rsi], '.'
    jne .gl_try
    cmp dword [rbp - 56], 0
    je .gl_ent
    cmp byte [rsi + 1], 0
    je .gl_ent                      ; "."
    cmp byte [rsi + 1], '.'
    jne .gl_try
    cmp byte [rsi + 2], 0
    je .gl_ent                      ; ".."
.gl_try:
    mov rdi, r12
    call glob_match
    test eax, eax
    jz .gl_ent
    mov rsi, [rbp - 80]
    call glob_store_name
    test eax, eax
    jz .gl_ent
    mov byte [glob_err], 2

.gl_intr:
    mov byte [glob_err], 3
.gl_read_done:
    mov edi, r15d
    mov eax, SYS_CLOSE
    syscall
    cmp byte [glob_err], 0
    jne .gl_release

    mov edi, [rbp - 88]
    mov esi, [glob_ptr_top]
    mov r15d, esi                   ; end of this level's names
    call glob_sort
    mov r14d, [rbp - 88]            ; the last-part flag is recomputed below
.gl_each:
    cmp r14d, r15d
    jae .gl_release
    cmp byte [glob_err], 0
    jne .gl_release
    mov rdi, [glob_ptrs + r14 * 8]
    xor esi, esi
    call glob_append
    test eax, eax
    jnz .gl_each_next
    mov eax, [glob_ncomp]
    dec eax
    cmp ebx, eax
    jne .gl_each_dir
    call glob_emit_path
    jmp .gl_each_next
.gl_each_dir:
    call glob_append_slash
    test eax, eax
    jnz .gl_each_next
    lea edi, [rbx + 1]
    call glob_level
.gl_each_next:
    mov [glob_plen], r13d
    lea rax, [glob_path]
    mov byte [rax + r13], 0
    inc r14d
    jmp .gl_each

.gl_release:
    mov rax, [rbp - 48]
    mov [glob_pool_top], rax
    mov eax, [rbp - 88]
    mov [glob_ptr_top], eax

.gl_ret:
    mov [glob_plen], r13d
    lea rax, [glob_path]
    mov byte [rax + r13], 0
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; glob_store_name(rsi = file name) -> eax = 0 kept, 1 when the tables are full
glob_store_name:
    mov rdi, [glob_pool_top]
    mov ecx, [glob_ptr_top]
    cmp ecx, GLOB_PTRS
    jae .sn_full
    lea r8, [glob_pool + GLOB_POOL_SIZE - 300]
    cmp rdi, r8
    jae .sn_full
    lea rdx, [glob_ptrs]
    mov [rdx + rcx * 8], rdi
    inc ecx
    mov [glob_ptr_top], ecx
.sn_copy:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .sn_copy
    mov [glob_pool_top], rdi
    xor eax, eax
    ret
.sn_full:
    mov eax, 1
    ret

; glob_strcmp(rdi, rsi) -> eax < 0, 0, > 0 (bytewise)
glob_strcmp:
.sc_loop:
    movzx eax, byte [rdi]
    movzx edx, byte [rsi]
    cmp eax, edx
    jne .sc_diff
    test eax, eax
    jz .sc_ret
    inc rdi
    inc rsi
    jmp .sc_loop
.sc_diff:
    sub eax, edx
.sc_ret:
    ret

; glob_sort(edi = first index, esi = end index) - shell sort of glob_ptrs
glob_sort:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                   ; first
    mov r13d, esi
    sub r13d, edi                   ; n
    mov r14d, r13d
    shr r14d, 1                     ; gap
.so_gap:
    test r14d, r14d
    jz .so_done
    mov ebx, r14d                   ; i
.so_i:
    cmp ebx, r13d
    jae .so_next_gap
    lea rax, [glob_ptrs]
    lea ecx, [r12 + rbx]
    mov r15, [rax + rcx * 8]        ; tmp
    mov ecx, ebx                    ; j
.so_j:
    cmp ecx, r14d
    jb .so_place
    mov edx, ecx
    sub edx, r14d                   ; j - gap
    add edx, r12d
    lea rax, [glob_ptrs]
    mov rdi, [rax + rdx * 8]
    mov rsi, r15
    call glob_strcmp                ; leaves ecx alone
    test eax, eax
    jle .so_place
    lea rax, [glob_ptrs]
    mov edx, ecx
    sub edx, r14d
    add edx, r12d
    mov rdi, [rax + rdx * 8]
    lea edx, [r12 + rcx]
    mov [rax + rdx * 8], rdi
    sub ecx, r14d
    jmp .so_j
.so_place:
    lea rax, [glob_ptrs]
    lea edx, [r12 + rcx]
    mov [rax + rdx * 8], r15
    inc ebx
    jmp .so_i
.so_next_gap:
    shr r14d, 1
    jmp .so_gap
.so_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; glob_match(rdi = pattern part, rsi = file name) -> eax = 1 on a match
; * ? [set] [!set] [a-z] and backslash escapes. A '[' without a closing ']'
; is a plain character.
; ----------------------------------------------------------------------------
glob_match:
    push rbx
    xor r8d, r8d                    ; pattern just after the last '*'
    xor r9d, r9d                    ; name position that '*' has taken so far
.m_loop:
    movzx eax, byte [rdi]
    test al, al
    jnz .m_pat
    cmp byte [rsi], 0
    je .m_yes
    jmp .m_back
.m_pat:
    cmp al, '*'
    jne .m_notstar
.m_star:
    inc rdi
    cmp byte [rdi], '*'
    je .m_star
    mov r8, rdi
    mov r9, rsi
    jmp .m_loop
.m_notstar:
    movzx edx, byte [rsi]
    test dl, dl
    jz .m_back
    cmp al, '?'
    jne .m_notq
    inc rdi
    inc rsi
    jmp .m_loop
.m_notq:
    cmp al, '['
    je .m_class
    cmp al, '\'
    jne .m_cmp
    movzx eax, byte [rdi + 1]
    test al, al
    jz .m_back
    inc rdi
.m_cmp:
    cmp eax, edx
    jne .m_back
    inc rdi
    inc rsi
    jmp .m_loop

.m_class:
    lea r10, [rdi + 1]
    xor ecx, ecx                    ; bit 0 matched, bit 1 negated, bit 2 not the first item
    movzx eax, byte [r10]
    cmp al, '!'
    je .mc_neg
    cmp al, '^'
    jne .mc_scan
.mc_neg:
    or ecx, 2
    inc r10
.mc_scan:
    movzx eax, byte [r10]
    test al, al
    jz .mc_invalid
    cmp al, ']'
    jne .mc_item
    test ecx, 4
    jnz .mc_end                     ; a ']' first in the set is a member
.mc_item:
    or ecx, 4
    inc r10
    cmp al, '\'
    jne .mc_lo
    movzx eax, byte [r10]
    test al, al
    jz .mc_invalid
    inc r10
.mc_lo:
    mov ebx, eax                    ; low end
    mov r11d, eax                   ; high end
    cmp byte [r10], '-'
    jne .mc_test
    movzx eax, byte [r10 + 1]
    test al, al
    jz .mc_test
    cmp al, ']'
    je .mc_test                     ; "a-]": the dash is a plain character
    add r10, 2
    cmp al, '\'
    jne .mc_hi
    movzx eax, byte [r10]
    test al, al
    jz .mc_invalid
    inc r10
.mc_hi:
    mov r11d, eax
.mc_test:
    cmp edx, ebx
    jb .mc_scan
    cmp edx, r11d
    ja .mc_scan
    or ecx, 1
    jmp .mc_scan
.mc_end:
    inc r10
    mov eax, ecx
    shr eax, 1
    xor eax, ecx
    test al, 1
    jz .m_back
    mov rdi, r10
    inc rsi
    jmp .m_loop
.mc_invalid:
    cmp dl, '['
    jne .m_back
    inc rdi
    inc rsi
    jmp .m_loop

.m_back:
    test r8, r8
    jz .m_no
    cmp byte [r9], 0
    je .m_no
    inc r9
    mov rsi, r9
    mov rdi, r8
    jmp .m_loop
.m_yes:
    mov eax, 1
    pop rbx
    ret
.m_no:
    xor eax, eax
    pop rbx
    ret

; ----------------------------------------------------------------------------
; glob_encode(rsi = text, rdi = destination, r8 = end of the destination)
;   -> rax = destination after the text, 0 if it does not fit.
; The same data encoding glob_emit_path uses.
; ----------------------------------------------------------------------------
glob_encode:
.en_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .en_done
    inc rsi
    lea r9, [rdi + 2]
    cmp r9, r8
    jae .en_over
    lea r10, [glob_special]
.en_chk:
    movzx r11d, byte [r10]
    test r11d, r11d
    jz .en_plain
    cmp r11d, eax
    je .en_mark
    inc r10
    jmp .en_chk
.en_mark:
    mov byte [rdi], EV_MARK
    inc rdi
.en_plain:
    mov [rdi], al
    inc rdi
    jmp .en_loop
.en_done:
    mov rax, rdi
    ret
.en_over:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; glob_multi(rdi = handler, rsi = argument text) -> eax = 1 if the command
; was run here. Called when a pattern matched more than one name and the
; handler takes a single operand: grep goes to the external program (it
; prints the file names), del, mkdir and rmdir run once per name, copy and
; move take the last name as a directory and run once per source.
; ----------------------------------------------------------------------------
glob_multi:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40                     ; [rbp-48] words, [rbp-56] first operand,
                                    ; [rbp-64] worst status, [rbp-72] flag text

    mov rbx, rdi                    ; handler
    mov r12, rsi                    ; arguments
    lea rax, [handler_grep]
    cmp rbx, rax
    je .gm_ok
    lea rax, [handler_del_safe]
    cmp rbx, rax
    je .gm_ok
    lea rax, [handler_mkdir]
    cmp rbx, rax
    je .gm_ok
    lea rax, [handler_rmdir]
    cmp rbx, rax
    je .gm_ok
    lea rax, [handler_copy_safe]
    cmp rbx, rax
    je .gm_ok
    lea rax, [handler_move_safe]
    cmp rbx, rax
    je .gm_ok
    xor eax, eax
    jmp .gm_ret

.gm_ok:
    ; Split into unquoted words
    lea r13, [dc_args_buf]
    xor r14d, r14d                  ; word count
    mov r15, r12
.gm_split:
    mov rdi, r15
    mov rsi, r13
    mov edx, 1
    call ash_next_word
    test rax, rax
    jz .gm_split_done
    cmp r14d, GLOB_MAX_TOKS
    jae .gm_toks
    mov r15, rax
    lea rcx, [glob_toks]
    mov [rcx + r14 * 8], r13
    inc r14d
    mov r13, rdx
    jmp .gm_split
.gm_split_done:
    mov [rbp - 48], r14d
    mov qword [rbp - 72], 0         ; flag text: none

    lea rax, [handler_grep]
    cmp rbx, rax
    jne .gm_not_grep
    cmp r14d, 3
    jb .gm_none                     ; a pattern and one file: the builtin does it
    call stats_begin
    call execute_external
    call stats_end
    mov eax, 1
    jmp .gm_ret

.gm_not_grep:
    ; An option in front: -f for del, copy and move, -p for mkdir
    mov dword [rbp - 56], 0
    mov dword [rbp - 64], 0
    test r14d, r14d
    jz .gm_none
    lea rsi, [glob_s_dash_f]
    lea rax, [handler_mkdir]
    cmp rbx, rax
    jne .gm_flag_cmp
    lea rsi, [glob_s_dash_p]
.gm_flag_cmp:
    lea rax, [handler_rmdir]
    cmp rbx, rax
    je .gm_flag_none
    mov [rbp - 80], rsi
    mov rdi, [glob_toks]
    call str_icompare
    test eax, eax
    jnz .gm_flag_none
    mov dword [rbp - 56], 1
    mov rax, [rbp - 80]
    mov [rbp - 72], rax
.gm_flag_none:

    lea rax, [handler_copy_safe]
    cmp rbx, rax
    je .gm_pair
    lea rax, [handler_move_safe]
    cmp rbx, rax
    je .gm_pair

    ; --- one run per operand ---
    mov r15d, [rbp - 56]            ; index of the first operand
    cmp r15d, r14d
    jae .gm_none
.gm_each:
    cmp r15d, r14d
    jae .gm_finish
    lea rdi, [glob_out_buf]
    mov rax, [rbp - 72]
    test rax, rax
    jz .gm_each_name
    mov rsi, rax
    call str_copy
    lea rdi, [glob_out_buf]
    call str_len
    lea rdi, [glob_out_buf + rax]
    mov byte [rdi], ' '
    inc rdi
.gm_each_name:
    lea rcx, [glob_toks]
    mov rsi, [rcx + r15 * 8]
    call str_copy
    mov dword [last_exit_status], 0
    lea rdi, [glob_out_buf]
    call rbx
    mov eax, [last_exit_status]
    cmp eax, [rbp - 64]
    jbe .gm_each_next
    mov [rbp - 64], eax
.gm_each_next:
    inc r15d
    jmp .gm_each

    ; --- sources and a destination directory ---
.gm_pair:
    mov eax, r14d
    sub eax, [rbp - 56]
    cmp eax, 3
    jb .gm_none                     ; SRC DST: nothing special
    lea rcx, [glob_toks]
    lea eax, [r14 - 1]
    mov r13, [rcx + rax * 8]        ; destination
    mov rdi, r13
    mov eax, SYS_STAT
    lea rsi, [glob_stat]
    syscall
    test rax, rax
    js .gm_notdir
    mov eax, [glob_stat + STAT_ST_MODE]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .gm_notdir
    mov r15d, [rbp - 56]
.gm_pair_loop:
    lea eax, [r14 - 1]
    cmp r15d, eax
    jae .gm_finish
    lea rcx, [glob_toks]
    mov rsi, [rcx + r15 * 8]        ; source
    ; the last name of the source
    mov rdx, rsi
.gm_base:
    mov al, [rdx]
    test al, al
    jz .gm_base_done
    inc rdx
    cmp al, '/'
    jne .gm_base
    mov rsi, rdx
    jmp .gm_base
.gm_base_done:
    ; rsi is now the base name: keep it, rebuild the source in rcx
    mov [rbp - 80], rsi
    lea rdi, [glob_out_buf]
    lea r8, [glob_out_buf + LINE_MAX - 8]
    mov rax, [rbp - 72]
    test rax, rax
    jz .gm_pair_src
    mov rsi, rax
    call glob_encode
    test rax, rax
    jz .gm_toolong
    mov rdi, rax
    mov byte [rdi], ' '
    inc rdi
.gm_pair_src:
    lea rcx, [glob_toks]
    mov rsi, [rcx + r15 * 8]
    call glob_encode
    test rax, rax
    jz .gm_toolong
    mov rdi, rax
    mov byte [rdi], ' '
    inc rdi
    ; destination: DIR/BASE
    mov rsi, r13
    call glob_encode
    test rax, rax
    jz .gm_toolong
    mov rdi, rax
    cmp byte [rdi - 1], '/'
    je .gm_pair_base
    mov byte [rdi], '/'
    inc rdi
.gm_pair_base:
    mov rsi, [rbp - 80]
    call glob_encode
    test rax, rax
    jz .gm_toolong
    mov byte [rax], 0
    mov dword [last_exit_status], 0
    lea rdi, [glob_out_buf]
    call rbx
    mov eax, [last_exit_status]
    cmp eax, [rbp - 64]
    jbe .gm_pair_next
    mov [rbp - 64], eax
.gm_pair_next:
    inc r15d
    jmp .gm_pair_loop

.gm_finish:
    mov eax, [rbp - 64]
    mov [last_exit_status], eax
    mov eax, 1
    jmp .gm_ret
.gm_notdir:
    lea rdi, [glob_e_notdir]
    call ash_write_err
    mov dword [last_exit_status], 1
    mov eax, 1
    jmp .gm_ret
.gm_toolong:
    lea rdi, [glob_e_long]
    call ash_write_err
    mov dword [last_exit_status], 1
    mov eax, 1
    jmp .gm_ret
.gm_toks:
    lea rdi, [glob_e_toks]
    call ash_write_err
    mov dword [last_exit_status], 1
    mov eax, 1
    jmp .gm_ret
.gm_none:
    xor eax, eax
.gm_ret:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
