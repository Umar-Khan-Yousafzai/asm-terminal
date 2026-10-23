; ============================================================================
; ASH script engine (milestone 2, part B)
;
;   if / elif / else / fi       while / until ... do ... done
;   for NAME in WORDS; do ... done      break / continue
;   { ... }   cmd1 && cmd2 || cmd3   ! cmd   NAME=value
;   test EXPR  /  [ EXPR ]       $?  $$  $((arithmetic))
;
; A script (one typed line, several typed lines, or a whole file) goes
; through three passes:
;   1. ash_tokenize  splits it into nodes: one per command or keyword,
;                    honouring quotes, $( ), backticks and # comments
;   2. ash_link      matches if/fi, do/done and { } and records jump targets
;   3. ash_exec_nodes walks the nodes with a program counter; each plain
;                    command goes through dispatch_command as before
;
; ash_eval returns "incomplete" for an open block, an open quote or a
; trailing && / || / |, so the main loop can show a "> " prompt and wait.
;
; Functions: "name() { ...; }" stores the body text; calling name runs it
; with $1..$9, $# and $@ set (old values restored after), "return [N]" ends it.
;
; Not native yet: case/esac, a loop piped or redirected
; ("done | sort", "cat f | while read l"). The tokenizer marks such a
; top-level statement and ash_link turns it into one N_SH node, which runs
; that statement's original text through /bin/sh.
;
; Included from terminal_linux.asm, after ash/builtins.asm.
; ============================================================================

%define ASH_DEPTH_MAX       200         ; nested source / eval levels (function calls)
%define ASH_ARENA_SIZE      (16 * 1024 * 1024) ; script text, nodes, loop word lists
%define ASH_NODE_SIZE       24
%define ASH_FRAMES_MAX      128         ; nested loops, over all call levels
%define ASH_FRAME_SIZE      96
%define ASH_PENDING_MAX     (512 * 1024) ; one unfinished block typed or piped in
%define ASH_LINK_MAX        128

; node layout
%define ND_TYPE             0
%define ND_CONN             4           ; connector before this node
%define ND_TEXT             8
%define ND_J1               16
%define ND_J2               20

%define N_CMD               1
%define N_IF                2
%define N_THEN              3
%define N_ELIF              4
%define N_ELSE              5
%define N_FI                6
%define N_WHILE             7
%define N_UNTIL             8
%define N_FOR               9
%define N_DO                10
%define N_DONE              11
%define N_LBRACE            12
%define N_RBRACE            13
%define N_CASE              14
%define N_ESAC              15
%define N_SH                16          ; statement handed to /bin/sh
%define N_FUNC              17          ; "name()" - next node is "{"

%define ASH_FUNC_MAX        64
%define ASH_FUNC_SIZE       8192
%define ASH_FUNC_NAME       32          ; name bytes, body follows
%define ASH_POS_COUNT       11          ; 1..9, #, @
%define ASH_POS_SLOT        128

%define C_SEQ               0
%define C_AND               1
%define C_OR                2
%define C_PIPE              3           ; same statement (only in N_SH)
%define C_MASK              0xFF
%define C_SH                0x100       ; node needs /bin/sh

; loop frame layout
%define F_TYPE              0
%define F_HEAD              4
%define F_DONE              8
%define F_DO                12
%define F_STATUS            16
%define F_CURSOR            20
%define F_VAR               24          ; 40 bytes
%define F_WORDS             64          ; qword: newline-separated word list (in the arena)
%define F_WCAP              72          ; dword: bytes available for that list
%define F_ARENA             80          ; qword: arena mark to release when the loop ends

%define ASH_SYS_LSTAT       6
%define ASH_SYS_ACCESS      21
%define ASH_SYS_GETPID      39
%define ASH_S_IFMT          0o170000
%define ASH_S_IFREG         0o100000
%define ASH_S_IFDIR         0o040000
%define ASH_S_IFLNK         0o120000

section .data
    ash_kw_table:
        dq ash_kw_if
        dd N_IF, 2
        dq ash_kw_then
        dd N_THEN, 4
        dq ash_kw_elif
        dd N_ELIF, 4
        dq ash_kw_else
        dd N_ELSE, 4
        dq ash_kw_fi
        dd N_FI, 2
        dq ash_kw_while
        dd N_WHILE, 5
        dq ash_kw_until
        dd N_UNTIL, 5
        dq ash_kw_for
        dd N_FOR, 3
        dq ash_kw_do
        dd N_DO, 2
        dq ash_kw_done
        dd N_DONE, 4
        dq ash_kw_lbrace
        dd N_LBRACE, 1
        dq ash_kw_rbrace
        dd N_RBRACE, 1
        dq ash_kw_case
        dd N_CASE, 4
        dq ash_kw_esac
        dd N_ESAC, 4
        dq 0
        dd 0, 0

    ash_kw_if           db "if", 0
    ash_kw_then         db "then", 0
    ash_kw_elif         db "elif", 0
    ash_kw_else         db "else", 0
    ash_kw_fi           db "fi", 0
    ash_kw_while        db "while", 0
    ash_kw_until        db "until", 0
    ash_kw_for          db "for", 0
    ash_kw_do           db "do", 0
    ash_kw_done         db "done", 0
    ash_kw_lbrace       db "{", 0
    ash_kw_rbrace       db "}", 0
    ash_kw_case         db "case", 0
    ash_kw_esac         db "esac", 0

    ash_s_break         db "break", 0
    ash_s_continue      db "continue", 0
    ash_s_in            db "in", 0
    ash_s_and           db "&&", 0
    ash_s_or            db "||", 0
    ash_s_bang          db "!", 0
    ash_s_rbracket      db "]", 0
    ash_s_eq1           db "=", 0
    ash_s_eq2           db "==", 0
    ash_s_neq           db "!=", 0
    ash_s_test          db "test", 0
    ash_s_lbracket      db "[", 0
    ash_s_colon         db ":", 0
    ash_s_return        db "return", 0
    ash_s_shift         db "shift", 0
    ash_e_count         db "ash: loop count must be a positive number", 10, 0
    ash_e_shift         db "ash: shift: shift count out of range", 10, 0
    ash_e_return        db "ash: return: can only return from a function or a sourced script", 10, 0
    ash_pos_n1          db "1", 0
    ash_pos_n2          db "2", 0
    ash_pos_n3          db "3", 0
    ash_pos_n4          db "4", 0
    ash_pos_n5          db "5", 0
    ash_pos_n6          db "6", 0
    ash_pos_n7          db "7", 0
    ash_pos_n8          db "8", 0
    ash_pos_n9          db "9", 0
    ash_pos_nhash       db "#", 0
    ash_pos_nat         db "@", 0
    ash_pos_names       dq ash_pos_n1, ash_pos_n2, ash_pos_n3, ash_pos_n4
                        dq ash_pos_n5, ash_pos_n6, ash_pos_n7, ash_pos_n8
                        dq ash_pos_n9, ash_pos_nhash, ash_pos_nat
    ash_e_func_full     db "ash: too many functions", 10, 0
    ash_e_func_long     db "ash: function body too long", 10, 0
    ash_ps2             db "> ", 0
    ash_s_empty         db 0

    ; /bin/sh helpers for $( ), backticks and globs in for-lists / values
    ash_shc_argv         dq sh_path, sh_dash_c, ash_sh_script, 0
    ash_sh_printf       db "printf '%s\n' ", 0

    ash_e_syntax        db "ash: syntax error near '", 0
    ash_e_syntax_end    db "'", 10, 0
    ash_e_eof           db "ash: syntax error: unexpected end of input", 10, 0
    ash_e_toolong       db "ash: script too long", 10, 0
    ash_e_complex       db "ash: script has too many commands", 10, 0
    ash_e_depth         db "ash: nested too deeply", 10, 0
    ash_e_line          db "ash: command too long", 10, 0
    ash_e_arith         db "ash: arithmetic syntax error", 10, 0
    ash_e_divzero       db "ash: division by zero", 10, 0
    ash_e_forvar        db "ash: for: expected 'for NAME in WORDS'", 10, 0
    ash_e_forlist       db "ash: for: word list too long", 10, 0
    ash_e_forlong       db "ash: for: word too long", 10, 0
    ash_e_test_op       db "test: unknown operator", 10, 0
    ash_e_test_int      db "test: integer expected", 10, 0
    ash_e_test_args     db "test: too many arguments", 10, 0
    ash_e_bracket       db "[: missing ']'", 10, 0

section .bss
    ash_depth           resd 1
    ash_frame_top       resd 1
    ash_pending_len     resd 1
    ash_cont            resb 1              ; 1 = waiting for more lines
    ash_sh_wstatus      resd 1
    ash_func_count      resd 1
    ash_ar_err          resb 1
    ash_ar_skip         resb 1              ; 1 = parsing a branch that is not evaluated
    ash_arith_failed    resb 1              ; set by ash_expand_arith on an error
    alignb 8
    ash_ar_p            resq 1
    ash_test_argv       resq 32
    ash_lk_cur          resd ASH_LINK_MAX
    ash_lk_head         resd ASH_LINK_MAX
    ash_name_buf        resb 64
    ash_ar_name         resb 64
    ash_num_buf         resb 32
    ash_num_tmp         resb 32
    ash_ar_buf          resb 512
    ash_word_buf        resb 1024
    ash_test_buf        resb 1024
    ash_sh_script       resb 1280
    ash_pending         resb ASH_PENDING_MAX
    ash_frames          resb ASH_FRAMES_MAX * ASH_FRAME_SIZE
    ash_funcs           resb ASH_FUNC_MAX * ASH_FUNC_SIZE
    alignb 8
    ash_arena_used      resq 1              ; bytes of ash_arena in use (a stack)
    ash_node_cap        resd 1              ; node slots the tokenizer may fill
    ash_abort           resb 1              ; 1 = unwind every level (runaway recursion)
    alignb 4
    ash_loop_n          resd 1              ; N of "break N" / "continue N"
    alignb 16
    ash_arena           resb ASH_ARENA_SIZE

section .text

; ----------------------------------------------------------------------------
; ash_feed_line - append input_buf to the pending script and try to run it.
; Leaves ash_cont = 1 when the script is still open (if without fi, ...).
; ----------------------------------------------------------------------------
ash_feed_line:
    push rbp
    mov rbp, rsp
    push rbx
    push r12

    lea rdi, [input_buf]
    call str_len
    mov ebx, eax
    mov r12d, [ash_pending_len]
    test r12d, r12d
    jz .fl_copy
    lea eax, [r12 + rbx + 2]
    cmp eax, ASH_PENDING_MAX
    jae .fl_overflow
    lea rax, [ash_pending]
    mov byte [rax + r12], 10
    inc r12d
.fl_copy:
    lea rdi, [ash_pending]
    add rdi, r12
    lea rsi, [input_buf]
    call str_copy
    add r12d, ebx
    mov [ash_pending_len], r12d

    lea rdi, [ash_pending]
    xor esi, esi
    call ash_eval
    cmp eax, 1
    jne .fl_finish
    mov byte [ash_cont], 1
    jmp .fl_ret

.fl_overflow:
    ; The head of the block is gone, so whatever follows must not run as
    ; top-level commands. A piped script stops here; a typed one starts over.
    lea rdi, [ash_e_toolong]
    call ash_write_err
    mov dword [last_exit_status], 2
    cmp byte [interactive_mode], 0
    jne .fl_finish
    mov edi, 2
    mov eax, SYS_EXIT
    syscall
.fl_finish:
    mov byte [ash_cont], 0
    mov dword [ash_pending_len], 0
.fl_ret:
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; ash_feed_eof - end of input: run (or report) whatever is still pending
; ----------------------------------------------------------------------------
ash_feed_eof:
    push rbp
    mov rbp, rsp
    cmp dword [ash_pending_len], 0
    je .fe_ret
    lea rdi, [ash_pending]
    mov esi, 1
    call ash_eval
    mov dword [ash_pending_len], 0
    mov byte [ash_cont], 0
.fe_ret:
    pop rbp
    ret

; ----------------------------------------------------------------------------
; ash_alloc(rdi = bytes) -> rax = 16-aligned block from the arena, or 0 when
; the arena is full. The arena is a stack: whoever allocates remembers
; ash_arena_used beforehand and puts it back when done.
; ----------------------------------------------------------------------------
ash_alloc:
    add rdi, 15
    and rdi, -16
    mov rax, [ash_arena_used]
    lea rcx, [rax + rdi]
    cmp rcx, ASH_ARENA_SIZE
    ja .aa_full
    mov [ash_arena_used], rcx
    lea rdx, [ash_arena]
    add rax, rdx
    ret
.aa_full:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; ash_count_nodes(rdi = text) -> eax = upper bound for the number of nodes
; the tokenizer can make from it: every node starts at a word or right
; after one of ; & | ( ) or a newline.
; ----------------------------------------------------------------------------
ash_count_nodes:
    mov r8d, 4
    mov r9d, 1                      ; the previous character was a blank
.cn_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .cn_done
    inc rdi
    cmp al, ' '
    je .cn_blank
    cmp al, 9
    je .cn_blank
    cmp al, 10
    je .cn_nl
    test r9d, r9d
    jz .cn_sep
    inc r8d
    xor r9d, r9d
.cn_sep:
    cmp al, ';'
    je .cn_bump
    cmp al, '&'
    je .cn_bump
    cmp al, '|'
    je .cn_bump
    cmp al, '('
    je .cn_bump
    cmp al, ')'
    jne .cn_loop
.cn_bump:
    inc r8d
    jmp .cn_loop
.cn_nl:
    inc r8d
.cn_blank:
    mov r9d, 1
    jmp .cn_loop
.cn_done:
    mov eax, r8d
    ret

; ----------------------------------------------------------------------------
; ash_eval(rdi = script text, esi = final) -> eax
;   0 = ran, 1 = incomplete (only when final = 0), 2 = syntax error
; The text, its untouched copy and the node array live in the arena for the
; duration of the call, so the script can be as large as the arena.
; ----------------------------------------------------------------------------
ash_eval:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24                     ; [rbp-48] untouched-copy offset,
                                    ; [rbp-56] arena mark to restore

    mov r12, rdi
    mov r13d, esi
    mov rax, [ash_arena_used]
    mov [rbp - 56], rax
    mov eax, [ash_depth]
    cmp eax, ASH_DEPTH_MAX
    jae .ae_deep
    mov r14d, eax

    ; Work buffer + untouched copy, each at least one byte longer than the text
    mov rdi, r12
    call str_len
    add eax, 16
    and eax, -16
    mov [rbp - 48], rax
    lea rdi, [rax + rax]
    call ash_alloc
    test rax, rax
    jz .ae_toolong
    mov rbx, rax

    ; Copy into this level's buffer: drop CR, join "\<newline>" (but not in
    ; a comment or in single quotes, where the backslash is just a character)
    mov rsi, r12
    xor ecx, ecx
    xor r8d, r8d                    ; inside '...'
    xor r9d, r9d                    ; inside "..."
    xor r10d, r10d                  ; inside a # comment
    xor r11d, r11d                  ; previous character stored
.ae_cp:
    movzx eax, byte [rsi]
    test al, al
    jz .ae_cp_end
    cmp al, 13
    je .ae_cp_skip
    cmp al, '\'
    je .ae_cp_bs
    test r10d, r10d
    jnz .ae_cp_incm
    test r8d, r8d
    jnz .ae_cp_insq
    test r9d, r9d
    jnz .ae_cp_indq
    cmp al, 0x27
    je .ae_cp_open_sq
    cmp al, '"'
    je .ae_cp_open_dq
    cmp al, '#'
    jne .ae_cp_store
    test r11d, r11d                 ; '#' starts a comment at a word start
    jz .ae_cp_open_cm
    cmp r11b, ' '
    je .ae_cp_open_cm
    cmp r11b, 9
    je .ae_cp_open_cm
    cmp r11b, 10
    je .ae_cp_open_cm
    cmp r11b, ';'
    je .ae_cp_open_cm
    cmp r11b, '&'
    je .ae_cp_open_cm
    cmp r11b, '|'
    je .ae_cp_open_cm
    cmp r11b, '('
    jne .ae_cp_store
.ae_cp_open_cm:
    mov r10d, 1
    jmp .ae_cp_store
.ae_cp_incm:
    cmp al, 10
    jne .ae_cp_store
    xor r10d, r10d
    jmp .ae_cp_store
.ae_cp_insq:
    cmp al, 0x27
    jne .ae_cp_store
    xor r8d, r8d
    jmp .ae_cp_store
.ae_cp_indq:
    cmp al, '"'
    jne .ae_cp_store
    xor r9d, r9d
    jmp .ae_cp_store
.ae_cp_open_sq:
    mov r8d, 1
    jmp .ae_cp_store
.ae_cp_open_dq:
    mov r9d, 1
.ae_cp_store:
    mov [rbx + rcx], al
    inc ecx
    inc rsi
    mov r11d, eax
    jmp .ae_cp
.ae_cp_skip:
    inc rsi
    jmp .ae_cp
.ae_cp_bs:
    movzx edx, byte [rsi + 1]
    cmp dl, 10
    je .ae_cp_bs_nl
    cmp dl, 13
    je .ae_cp_bs_cr
    test dl, dl
    jz .ae_cp_trailing
    test r8d, r8d                   ; in '...' a backslash escapes nothing
    jnz .ae_cp_bs_lit
    mov [rbx + rcx], al             ; escaped pair, stored whole
    mov [rbx + rcx + 1], dl
    add ecx, 2
    add rsi, 2
    mov r11d, edx
    jmp .ae_cp
.ae_cp_bs_cr:
    cmp byte [rsi + 2], 10
    je .ae_cp_bs_crnl
    inc rsi                         ; "\<CR>x": the CR is dropped, the backslash escapes x
    jmp .ae_cp
.ae_cp_bs_crnl:
    test r8d, r8d
    jnz .ae_cp_bs_lit
    test r10d, r10d
    jnz .ae_cp_bs_lit
    add rsi, 3                      ; "\<CR><LF>" joins like "\<LF>"
    jmp .ae_cp
.ae_cp_bs_nl:
    test r8d, r8d
    jnz .ae_cp_bs_lit
    test r10d, r10d
    jnz .ae_cp_bs_lit
    add rsi, 2
    jmp .ae_cp
.ae_cp_bs_lit:
    mov [rbx + rcx], al
    inc ecx
    inc rsi
    mov r11d, eax
    jmp .ae_cp
.ae_cp_trailing:
    test r8d, r8d
    jnz .ae_cp_bs_lit
    test r10d, r10d
    jnz .ae_cp_bs_lit
    test r13d, r13d
    jz .ae_incomplete
.ae_cp_end:                         ; final: a lone backslash at the end is dropped
    mov byte [rbx + rcx], 0
    ; Keep an untouched copy for statements that go to /bin/sh
    mov rdi, rbx
    add rdi, [rbp - 48]
    mov rsi, rbx
    inc ecx
    rep movsb

    mov rdi, rbx
    call ash_count_nodes
    mov [ash_node_cap], eax
    mov edi, eax
    imul rdi, rdi, ASH_NODE_SIZE
    call ash_alloc
    test rax, rax
    jz .ae_toolong
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    call ash_tokenize
    cmp eax, 1
    je .ae_incomplete
    cmp eax, 2
    je .ae_error
    mov ebx, edx                    ; node count

    mov rdi, r12
    mov esi, ebx
    call ash_link
    cmp eax, 1
    je .ae_incomplete
    cmp eax, 2
    je .ae_error

    test r14d, r14d
    jnz .ae_run
    mov byte [ctrl_c_flag], 0       ; stale Ctrl+C must not abort a new line
    mov byte [ash_abort], 0
.ae_run:
    inc dword [ash_depth]
    mov rdi, r12
    mov esi, ebx
    mov rdx, [rbp - 48]
    call ash_exec_nodes
    dec dword [ash_depth]
    xor eax, eax
    jmp .ae_ret

.ae_incomplete:
    test r13d, r13d
    jnz .ae_eof_err
    mov eax, 1
    jmp .ae_ret
.ae_eof_err:
    lea rdi, [ash_e_eof]
    call ash_write_err
    jmp .ae_error
.ae_toolong:
    lea rdi, [ash_e_toolong]
    call ash_write_err
    jmp .ae_error
.ae_deep:
    lea rdi, [ash_e_depth]
    call ash_write_err
    mov byte [ash_abort], 1         ; a runaway recursion must not resume above
.ae_error:
    mov dword [last_exit_status], 2
    mov eax, 2
.ae_ret:
    mov rcx, [rbp - 56]
    mov [ash_arena_used], rcx
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; ash_kw_match(rdi = text) -> eax = keyword node type or 0, edx = length
; A keyword must be followed by blank, newline, ';', '&', '|' or NUL.
; ----------------------------------------------------------------------------
ash_kw_match:
    lea r8, [ash_kw_table]
.km_loop:
    mov rsi, [r8]
    test rsi, rsi
    jz .km_none
    mov edx, [r8 + 12]
    xor ecx, ecx
.km_cmp:
    cmp ecx, edx
    je .km_term
    mov al, [rdi + rcx]
    cmp al, [rsi + rcx]
    jne .km_next
    inc ecx
    jmp .km_cmp
.km_term:
    movzx eax, byte [rdi + rdx]
    test al, al
    jz .km_match
    cmp al, ' '
    je .km_match
    cmp al, 9
    je .km_match
    cmp al, 10
    je .km_match
    cmp al, ';'
    je .km_match
    cmp al, '&'
    je .km_match
    cmp al, '|'
    je .km_match
.km_next:
    add r8, 16
    jmp .km_loop
.km_match:
    mov eax, [r8 + 8]
    ret
.km_none:
    xor eax, eax
    xor edx, edx
    ret

; ----------------------------------------------------------------------------
; ash_tokenize(rdi = text, rsi = nodes) -> eax status (0/1/2), edx = count
; Writes NULs into text to end each command.
; ----------------------------------------------------------------------------
%macro ASH_EMIT 0                   ; eax = type, rcx = text
    cmp r14d, [ash_node_cap]
    jae .tk_complex
    imul r8d, r14d, ASH_NODE_SIZE
    add r8, r13
    mov [r8 + ND_TYPE], eax
    mov r9d, r15d
    or r9d, [rbp - 64]
    mov [r8 + ND_CONN], r9d
    mov dword [rbp - 64], 0
    mov [r8 + ND_TEXT], rcx
    mov dword [r8 + ND_J1], -1
    mov dword [r8 + ND_J2], -1
    inc r14d
    xor r15d, r15d
    mov dword [rbp - 48], 0
%endmacro

ash_tokenize:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24                     ; [rbp-48] need_cmd, [rbp-52] type,
                                    ; [rbp-56] next conn, [rbp-60] next need
                                    ; [rbp-64] C_SH mark for the next node
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
    xor r15d, r15d
    mov dword [rbp - 48], 0
    mov dword [rbp - 64], 0

.tk_item:
    movzx eax, byte [r12]
    cmp al, ' '
    je .tk_item_skip
    cmp al, 9
    je .tk_item_skip
    cmp al, 10
    je .tk_item_skip
    cmp al, ';'
    je .tk_item_skip
    test al, al
    jz .tk_eof
    cmp al, '#'
    je .tk_comment
    mov rdi, r12
    call ash_kw_match
    test eax, eax
    jz .tk_cmd
    mov rcx, r12
    add r12, rdx
    cmp eax, N_FOR                  ; "for" becomes one node with its list
    je .tk_for
    cmp eax, N_CASE
    jne .tk_kw_emit
    mov dword [rbp - 64], C_SH
.tk_kw_emit:
    mov [rbp - 52], eax
    ASH_EMIT
    mov eax, [rbp - 52]
    cmp eax, N_FI
    je .tk_after_close
    cmp eax, N_DONE
    je .tk_after_close
    cmp eax, N_RBRACE
    je .tk_after_close
    cmp eax, N_ESAC
    je .tk_after_close
    jmp .tk_item
.tk_item_skip:
    inc r12
    jmp .tk_item

.tk_comment:
    movzx eax, byte [r12]
    test al, al
    jz .tk_item
    cmp al, 10
    je .tk_item
    inc r12
    jmp .tk_comment

.tk_for:
    movzx eax, byte [r12]
    cmp al, ' '
    je .tk_for_ws
    cmp al, 9
    jne .tk_for_go
.tk_for_ws:
    inc r12
    jmp .tk_for
.tk_for_go:
    mov dword [rbp - 52], N_FOR
    jmp .tk_scan

.tk_cmd:
    mov dword [rbp - 52], N_CMD
.tk_scan:
    mov rbx, r12                    ; item start
    xor ecx, ecx                    ; in '...'
    xor r8d, r8d                    ; in "..."
    xor r9d, r9d                    ; in `...`
    xor r10d, r10d                  ; ( depth
    xor r11d, r11d                  ; last non-blank char
.tk_sc:
    movzx eax, byte [r12]
    test al, al
    jz .tk_sc_eof
    test ecx, ecx
    jnz .tk_sc_sq
    cmp al, '\'
    je .tk_sc_bs
    test r8d, r8d
    jnz .tk_sc_dq
    cmp al, 0x27
    je .tk_sc_open_sq
    cmp al, '"'
    je .tk_sc_open_dq
    cmp al, '`'
    je .tk_sc_bq
    test r9d, r9d
    jnz .tk_sc_adv
    cmp al, '('
    je .tk_sc_lp
    cmp al, ')'
    je .tk_sc_rp
    test r10d, r10d
    jnz .tk_sc_adv
    cmp al, '#'
    je .tk_sc_hash
    cmp al, ';'
    je .tk_sep_semi
    cmp al, 10
    je .tk_sep_nl
    cmp al, '&'
    je .tk_sc_amp
    cmp al, '|'
    je .tk_sc_pipe
    cmp al, ' '
    je .tk_sc_adv_ws
    cmp al, 9
    je .tk_sc_adv_ws
.tk_sc_adv:
    mov r11d, eax
.tk_sc_adv_ws:
    inc r12
    jmp .tk_sc
.tk_sc_sq:
    cmp al, 0x27
    jne .tk_sc_adv
    xor ecx, ecx
    jmp .tk_sc_adv
.tk_sc_dq:
    cmp al, '"'
    jne .tk_sc_adv
    xor r8d, r8d
    jmp .tk_sc_adv
.tk_sc_bs:
    cmp byte [r12 + 1], 0
    je .tk_sc_adv
    mov r11d, eax
    add r12, 2
    jmp .tk_sc
.tk_sc_open_sq:
    mov ecx, 1
    jmp .tk_sc_adv
.tk_sc_open_dq:
    mov r8d, 1
    jmp .tk_sc_adv
.tk_sc_bq:
    xor r9d, 1
    jmp .tk_sc_adv
.tk_sc_lp:
    test r10d, r10d
    jnz .tk_sc_lp_in
    cmp byte [r12 + 1], ')'         ; "name()" starts a function definition
    jne .tk_sc_lp_in
    cmp byte [r12 - 1], '$'
    je .tk_sc_lp_in
    mov byte [r12], 0               ; node text = the name
    lea rax, [r12 - 1]
.tk_fn_trim:                        ; "name ()" -> "name"
    cmp rax, rbx
    jb .tk_fn_trimmed
    cmp byte [rax], ' '
    je .tk_fn_blank
    cmp byte [rax], 9
    jne .tk_fn_trimmed
.tk_fn_blank:
    mov byte [rax], 0
    dec rax
    jmp .tk_fn_trim
.tk_fn_trimmed:
    add r12, 2
    mov rdx, r12
    mov dword [rbp - 52], N_FUNC
    mov dword [rbp - 56], C_PIPE
    mov dword [rbp - 60], 0
    jmp .tk_trim
.tk_sc_lp_in:
    inc r10d
    jmp .tk_sc_adv
.tk_sc_rp:
    test r10d, r10d
    jz .tk_sc_adv
    dec r10d
    jmp .tk_sc_adv
.tk_sc_hash:
    cmp r12, rbx
    je .tk_sc_comment
    movzx edx, byte [r12 - 1]
    cmp dl, ' '
    je .tk_sc_comment
    cmp dl, 9
    je .tk_sc_comment
    jmp .tk_sc_adv
.tk_sc_comment:
    mov rdx, r12                    ; item ends here
.tk_sc_cm_skip:
    movzx eax, byte [r12]
    test al, al
    jz .tk_sc_cm_end
    cmp al, 10
    je .tk_sc_cm_nl
    inc r12
    jmp .tk_sc_cm_skip
.tk_sc_cm_nl:
    inc r12
.tk_sc_cm_end:
    mov byte [rdx], 0
    mov dword [rbp - 56], C_SEQ
    jmp .tk_item_end
.tk_sep_nl:
    cmp r11d, '|'                   ; "cmd |<newline>cmd": keep the pipe going
    jne .tk_sep_semi
    mov byte [r12], ' '
    jmp .tk_sc_adv_ws
.tk_sep_semi:
    mov rdx, r12
    mov byte [r12], 0
    inc r12
    mov dword [rbp - 56], C_SEQ
    jmp .tk_item_end
.tk_sc_amp:
    cmp byte [r12 + 1], '&'
    jne .tk_sc_amp1
    mov rdx, r12
    mov byte [r12], 0
    add r12, 2
    mov dword [rbp - 56], C_AND
    jmp .tk_item_end_need
.tk_sc_amp1:
    ; A lone "&" ends the command and stays at its end, which tells the
    ; dispatcher to run it in the background. "2>&1", ">&2" and "&>" are
    ; redirections, not separators.
    cmp r11d, '>'
    je .tk_sc_adv
    cmp r11d, '<'
    je .tk_sc_adv
    movzx eax, byte [r12 + 1]
    test al, al
    jz .tk_sc_adv_amp               ; at the very end: nothing to split
    cmp al, ' '
    je .tk_sc_amp_cut
    cmp al, 9
    je .tk_sc_amp_cut
    cmp al, 10
    je .tk_sc_amp_cut
    cmp al, ';'
    jne .tk_sc_adv                  ; "&>" and "&word" are not a separator
.tk_sc_amp_cut:
    lea rdx, [r12 + 1]              ; the blank after the "&" becomes the NUL
    mov byte [rdx], 0
    lea r12, [rdx + 1]
    mov dword [rbp - 56], C_SEQ
    jmp .tk_item_end
.tk_sc_adv_amp:
    jmp .tk_sc_adv
.tk_sc_pipe:
    cmp byte [r12 + 1], '|'
    jne .tk_sc_pipe1
    mov rdx, r12
    mov byte [r12], 0
    add r12, 2
    mov dword [rbp - 56], C_OR
    jmp .tk_item_end_need
.tk_sc_pipe1:
    ; "cmd | while ..." : the block goes to /bin/sh with the pipe
    lea rdi, [r12 + 1]
    call ash_skip_blanks
    mov rdi, rax
    call ash_kw_match
    xor ecx, ecx                    ; scan state is all clear here
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    mov r11d, '|'
    test eax, eax
    jz .tk_sc_adv_ws
    mov rdx, r12
    mov byte [r12], 0
    inc r12
    mov dword [rbp - 64], C_SH
    mov dword [rbp - 56], C_PIPE
    mov dword [rbp - 60], 0
    jmp .tk_trim
.tk_sc_eof:
    or ecx, r8d
    or ecx, r9d
    or ecx, r10d
    jnz .tk_incomplete
    cmp r11d, '|'
    je .tk_incomplete
    mov rdx, r12
    mov dword [rbp - 56], C_SEQ
    jmp .tk_item_end

.tk_item_end_need:
    mov dword [rbp - 60], 1
    jmp .tk_trim
.tk_item_end:
    mov dword [rbp - 60], 0
.tk_trim:
    cmp rdx, rbx
    je .tk_trim_done
    movzx eax, byte [rdx - 1]
    cmp al, ' '
    je .tk_trim_one
    cmp al, 9
    jne .tk_trim_done
.tk_trim_one:
    dec rdx
    mov byte [rdx], 0
    jmp .tk_trim
.tk_trim_done:
    cmp rdx, rbx
    je .tk_empty
    mov eax, [rbp - 52]
    mov rcx, rbx
    ASH_EMIT
    mov r15d, [rbp - 56]
    mov eax, [rbp - 60]
    mov [rbp - 48], eax
    jmp .tk_item
.tk_empty:
    cmp dword [rbp - 52], N_FOR
    je .tk_bad_for
    cmp dword [rbp - 60], 0
    je .tk_item
    lea rdi, [ash_s_and]            ; "&&" or "||" with nothing before it
    cmp dword [rbp - 56], C_AND
    je .tk_err
    lea rdi, [ash_s_or]
    jmp .tk_err
.tk_bad_for:
    lea rdi, [ash_kw_for]
    jmp .tk_err

.tk_after_close:
    movzx eax, byte [r12]
    cmp al, ' '
    je .tk_ac_ws
    cmp al, 9
    jne .tk_ac_go
.tk_ac_ws:
    inc r12
    jmp .tk_after_close
.tk_ac_go:
    test al, al
    jz .tk_item
    cmp al, '#'
    je .tk_item
    cmp al, ';'
    je .tk_ac_sep
    cmp al, 10
    je .tk_ac_sep
    cmp al, '&'
    jne .tk_ac_or
    cmp byte [r12 + 1], '&'
    jne .tk_ac_sh
    add r12, 2
    mov r15d, C_AND
    mov dword [rbp - 48], 1
    jmp .tk_item
.tk_ac_or:
    cmp al, '|'
    jne .tk_ac_sh
    cmp byte [r12 + 1], '|'
    jne .tk_ac_sh
    add r12, 2
    mov r15d, C_OR
    mov dword [rbp - 48], 1
    jmp .tk_item
.tk_ac_sep:
    inc r12
    jmp .tk_item
.tk_ac_sh:
    ; "done | sort", "done < file", "fi > log", "} &": the rest of the
    ; statement is a plain item, and the statement goes to /bin/sh
    mov dword [rbp - 64], C_SH
    mov r15d, C_PIPE
    jmp .tk_cmd

.tk_eof:
    cmp dword [rbp - 48], 0
    jne .tk_incomplete
    xor eax, eax
    mov edx, r14d
    jmp .tk_ret
.tk_incomplete:
    mov eax, 1
    jmp .tk_ret
.tk_complex:
    lea rdi, [ash_e_complex]
    call ash_write_err
    mov eax, 2
    jmp .tk_ret
.tk_err:
    call ash_syntax_err
    mov eax, 2
.tk_ret:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; ash_link(rdi = nodes, esi = count) -> eax 0 ok / 1 open block / 2 error
;   IF.j1 = FI, THEN.j1 = next ELIF/ELSE/FI, ELIF/ELSE.j1 = FI
;   loop head.j1 = DONE, head.j2 = DO, DO.j1 = DONE, DO.j2 = DONE.j2 = head
;   LBRACE.j1 = RBRACE, CASE.j1 = ESAC
; A top-level statement with a C_SH node becomes one N_SH node:
;   j1 = its last node, j2 = length of its original text
; ----------------------------------------------------------------------------
ash_link:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8                      ; [rbp-48] statement needs /bin/sh

    mov r12, rdi
    mov r13d, esi
    xor r14d, r14d                  ; i
    xor ebx, ebx                    ; stack depth
    xor r15d, r15d                  ; first node of this statement
    mov dword [rbp - 48], 0
.lk_loop:
    cmp r14d, r13d
    jae .lk_end
    imul eax, r14d, ASH_NODE_SIZE
    lea rsi, [r12 + rax]
    ; A new top-level statement starts after ';' or a newline
    test ebx, ebx
    jnz .lk_flag
    test r14d, r14d
    jz .lk_flag
    mov eax, [rsi + ND_CONN]
    and eax, C_MASK
    cmp eax, C_SEQ
    jne .lk_flag
    lea ecx, [r14d - 1]
    call .lk_finish
    mov r15d, r14d
    mov dword [rbp - 48], 0
    imul eax, r14d, ASH_NODE_SIZE
    lea rsi, [r12 + rax]
.lk_flag:
    mov eax, [rsi + ND_CONN]
    and eax, C_SH
    or [rbp - 48], eax
    mov eax, [rsi + ND_TYPE]
    cmp eax, N_IF
    je .lk_open
    cmp eax, N_CASE
    je .lk_open
    cmp eax, N_WHILE
    je .lk_open
    cmp eax, N_UNTIL
    je .lk_open
    cmp eax, N_FOR
    je .lk_open
    cmp eax, N_LBRACE
    je .lk_open
    cmp eax, N_THEN
    je .lk_then
    cmp eax, N_ELIF
    je .lk_elif
    cmp eax, N_ELSE
    je .lk_elif
    cmp eax, N_FI
    je .lk_fi
    cmp eax, N_DO
    je .lk_do
    cmp eax, N_DONE
    je .lk_done
    cmp eax, N_RBRACE
    je .lk_rbrace
    cmp eax, N_ESAC
    je .lk_esac
    cmp eax, N_FUNC
    je .lk_func
.lk_next:
    inc r14d
    jmp .lk_loop

.lk_open:
    cmp ebx, ASH_LINK_MAX
    jae .lk_err
    lea rdx, [ash_lk_cur]
    mov [rdx + rbx * 4], r14d
    lea rdx, [ash_lk_head]
    mov [rdx + rbx * 4], r14d
    inc ebx
    jmp .lk_next

; top-of-stack helpers (inline): edx = cur index, ecx = cur type,
; r8d = head index, r9 = head node
%macro LK_TOP 0
    test ebx, ebx
    jz .lk_err
    lea rax, [ash_lk_cur]
    mov edx, [rax + rbx * 4 - 4]
    lea rax, [ash_lk_head]
    mov r8d, [rax + rbx * 4 - 4]
    imul eax, edx, ASH_NODE_SIZE
    mov ecx, [r12 + rax + ND_TYPE]
    imul eax, r8d, ASH_NODE_SIZE
    lea r9, [r12 + rax]
%endmacro
%macro LK_SET_CUR 0
    lea rax, [ash_lk_cur]
    mov [rax + rbx * 4 - 4], r14d
%endmacro

.lk_then:
    LK_TOP
    cmp ecx, N_IF
    je .lk_then_ok
    cmp ecx, N_ELIF
    jne .lk_err
.lk_then_ok:
    lea eax, [edx + 1]
    cmp eax, r14d                   ; "if then": no condition to run
    je .lk_err
    LK_SET_CUR
    jmp .lk_next

.lk_elif:
    LK_TOP
    cmp ecx, N_THEN
    jne .lk_err
    imul eax, edx, ASH_NODE_SIZE
    mov [r12 + rax + ND_J1], r14d   ; THEN false -> here
    mov eax, [r9 + ND_J2]           ; chain of ELIF/ELSE nodes on the IF
    mov [rsi + ND_J2], eax
    mov [r9 + ND_J2], r14d
    LK_SET_CUR
    jmp .lk_next

.lk_fi:
    LK_TOP
    cmp ecx, N_ELSE
    je .lk_fi_ok
    cmp ecx, N_THEN
    jne .lk_err
    imul eax, edx, ASH_NODE_SIZE
    mov [r12 + rax + ND_J1], r14d
.lk_fi_ok:
    mov ecx, [r9 + ND_J2]
.lk_fi_chain:
    cmp ecx, -1
    je .lk_fi_chain_done
    imul eax, ecx, ASH_NODE_SIZE
    lea r10, [r12 + rax]
    mov ecx, [r10 + ND_J2]
    mov [r10 + ND_J1], r14d
    jmp .lk_fi_chain
.lk_fi_chain_done:
    mov [r9 + ND_J1], r14d
    dec ebx
    jmp .lk_next

.lk_do:
    LK_TOP
    cmp ecx, N_WHILE
    je .lk_do_ok
    cmp ecx, N_UNTIL
    je .lk_do_ok
    cmp ecx, N_FOR
    jne .lk_err
.lk_do_ok:
    cmp ecx, N_FOR
    je .lk_do_set
    lea eax, [edx + 1]
    cmp eax, r14d                   ; "while do": no condition, it would never end
    je .lk_err
.lk_do_set:
    mov [r9 + ND_J2], r14d
    mov [rsi + ND_J2], r8d
    LK_SET_CUR
    jmp .lk_next

.lk_done:
    LK_TOP
    cmp ecx, N_DO
    jne .lk_err
    mov [r9 + ND_J1], r14d
    mov [rsi + ND_J2], r8d
    imul eax, edx, ASH_NODE_SIZE
    mov [r12 + rax + ND_J1], r14d
    dec ebx
    jmp .lk_next

.lk_rbrace:
    LK_TOP
    cmp ecx, N_LBRACE
    jne .lk_err
    mov [r9 + ND_J1], r14d
    dec ebx
    jmp .lk_next

.lk_func:
    lea eax, [r14d + 1]
    cmp eax, r13d
    jae .lk_open_end                ; "f()" with the body still to come
    mov [rsi + ND_J1], eax
    imul eax, eax, ASH_NODE_SIZE
    cmp dword [r12 + rax + ND_TYPE], N_LBRACE
    jne .lk_err
    jmp .lk_next
.lk_open_end:
    mov eax, 1
    jmp .lk_ret

.lk_esac:
    LK_TOP
    cmp ecx, N_CASE
    jne .lk_err
    mov [r9 + ND_J1], r14d
    dec ebx
    jmp .lk_next

.lk_end:
    mov eax, 1
    test ebx, ebx
    jnz .lk_ret                     ; a block is still open
    test r13d, r13d
    jz .lk_ok
    lea ecx, [r13d - 1]
    call .lk_finish
.lk_ok:
    xor eax, eax
    jmp .lk_ret
.lk_err:
    mov rdi, [rsi + ND_TEXT]
    call ash_syntax_err
    mov eax, 2
.lk_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; Statement r15d..ecx: if it needs /bin/sh, make its first node N_SH.
; A function definition stays as it is: its body is looked at again when the
; function is called, and a case or piped loop inside it goes to /bin/sh then.
.lk_finish:
    cmp dword [rbp - 48], 0
    je .lf_ret
    imul eax, r15d, ASH_NODE_SIZE
    cmp dword [r12 + rax + ND_TYPE], N_FUNC
    je .lf_ret
    imul eax, ecx, ASH_NODE_SIZE
    lea r8, [r12 + rax]             ; last node
    mov r9, [r8 + ND_TEXT]
    mov eax, [r8 + ND_TYPE]
    mov edx, 2
    cmp eax, N_FI
    je .lf_kw
    mov edx, 1
    cmp eax, N_RBRACE
    je .lf_kw
    mov edx, 4
    cmp eax, N_DONE
    je .lf_kw
    cmp eax, N_ESAC
    je .lf_kw
.lf_len:
    cmp byte [r9], 0
    je .lf_end
    inc r9
    jmp .lf_len
.lf_kw:
    add r9, rdx
.lf_end:
    imul eax, r15d, ASH_NODE_SIZE
    lea r8, [r12 + rax]             ; first node
    mov r10, [r8 + ND_TEXT]
    cmp dword [r8 + ND_TYPE], N_FOR
    jne .lf_set
.lf_for_back:                       ; FOR text starts after "for "
    movzx eax, byte [r10 - 1]
    cmp al, ' '
    je .lf_for_dec
    cmp al, 9
    jne .lf_for_kw
.lf_for_dec:
    dec r10
    jmp .lf_for_back
.lf_for_kw:
    sub r10, 3
.lf_set:
    mov [r8 + ND_TEXT], r10
    sub r9, r10
    mov [r8 + ND_J2], r9d
    mov [r8 + ND_J1], ecx
    mov dword [r8 + ND_TYPE], N_SH
.lf_ret:
    ret

; ----------------------------------------------------------------------------
; ash_exec_nodes(rdi = nodes, esi = count)
; ----------------------------------------------------------------------------
%macro FRAME_TOP 0                  ; rdx = top loop frame
    mov eax, [ash_frame_top]
    dec eax
    imul eax, eax, ASH_FRAME_SIZE
    lea rdx, [ash_frames]
    add rdx, rax
%endmacro

ash_exec_nodes:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40                     ; [rbp-48] frame pointer scratch,
                                    ; [rbp-64] untouched-copy offset,
                                    ; [rbp-72] arena mark to restore
    mov [rbp - 64], rdx
    mov rax, [ash_arena_used]
    mov [rbp - 72], rax
    mov r12, rdi
    mov r13d, esi
    xor r14d, r14d                  ; pc
    mov r15d, [ash_frame_top]       ; frames below this belong to callers

.ex_loop:
    cmp r14d, r13d
    jae .ex_done
    cmp byte [ctrl_c_flag], 0
    jne .ex_intr
    cmp byte [ash_abort], 0
    jne .ex_done
    imul eax, r14d, ASH_NODE_SIZE
    lea rbx, [r12 + rax]
    mov eax, [rbx + ND_TYPE]
    cmp eax, N_CMD
    je .ex_cmd
    cmp eax, N_SH
    je .ex_sh
    cmp eax, N_FUNC
    je .ex_func
    cmp eax, N_THEN
    je .ex_then
    cmp eax, N_ELIF
    je .ex_jump_j1
    cmp eax, N_ELSE
    je .ex_jump_j1
    cmp eax, N_DO
    je .ex_do
    cmp eax, N_DONE
    je .ex_done_node
    cmp eax, N_FI
    je .ex_next
    cmp eax, N_RBRACE
    je .ex_next

    ; Block openers: IF WHILE UNTIL FOR LBRACE (may sit after && / ||)
    call .ex_skip_by_conn
    test eax, eax
    jnz .ex_jump_j1
    mov eax, [rbx + ND_TYPE]
    cmp eax, N_WHILE
    je .ex_loop_push
    cmp eax, N_UNTIL
    je .ex_loop_push
    cmp eax, N_FOR
    je .ex_for
.ex_next:
    inc r14d
    jmp .ex_loop
.ex_jump_j1:
    mov r14d, [rbx + ND_J1]
    inc r14d
    jmp .ex_loop

.ex_cmd:
    call .ex_skip_by_conn
    test eax, eax
    jnz .ex_next
    mov rdi, [rbx + ND_TEXT]
    call ash_run_cmd
    cmp eax, 1
    je .ex_break
    cmp eax, 2
    je .ex_continue
    cmp eax, 3
    je .ex_done                     ; return
    jmp .ex_next

.ex_sh:
    ; Run the statement's original text with /bin/sh
    mov rdi, [rbx + ND_TEXT]
    add rdi, [rbp - 64]
    mov esi, [rbx + ND_J2]
    call ash_sh_run
    mov r14d, [rbx + ND_J1]
    jmp .ex_next

.ex_func:
    ; Store the body (original text between { and }) under the name
    mov eax, [rbx + ND_J1]          ; "{" node
    imul eax, eax, ASH_NODE_SIZE
    lea r8, [r12 + rax]
    mov eax, [r8 + ND_J1]           ; "}" node
    mov r14d, eax
    imul eax, eax, ASH_NODE_SIZE
    mov rdx, [r12 + rax + ND_TEXT]
    mov rsi, [r8 + ND_TEXT]
    inc rsi
    sub rdx, rsi
    add rsi, [rbp - 64]
    mov rdi, [rbx + ND_TEXT]
    call ash_func_define
    jmp .ex_next

.ex_then:
    cmp dword [last_exit_status], 0
    je .ex_next
    mov eax, [rbx + ND_J1]
    lea r14d, [rax + 1]
    imul eax, eax, ASH_NODE_SIZE
    cmp dword [r12 + rax + ND_TYPE], N_FI
    jne .ex_loop
    mov dword [last_exit_status], 0 ; no branch taken
    jmp .ex_loop

.ex_loop_push:
    call ash_frame_push
    test rdx, rdx
    jz .ex_done
    mov eax, [rbx + ND_TYPE]
    mov [rdx + F_TYPE], eax
    mov [rdx + F_HEAD], r14d
    mov eax, [rbx + ND_J1]
    mov [rdx + F_DONE], eax
    mov eax, [rbx + ND_J2]
    mov [rdx + F_DO], eax
    mov dword [rdx + F_STATUS], 0
    jmp .ex_next

.ex_do:
    mov eax, [ash_frame_top]
    cmp eax, r15d
    jbe .ex_next
    FRAME_TOP
    cmp dword [rdx + F_TYPE], N_FOR
    je .ex_next
    xor eax, eax
    cmp dword [last_exit_status], 0
    sete al
    cmp dword [rdx + F_TYPE], N_UNTIL
    jne .ex_do_test
    xor al, 1
.ex_do_test:
    test al, al
    jnz .ex_next
.ex_loop_exit:                      ; rdx = frame
    mov rax, [rdx + F_ARENA]        ; frees the word list of a "for"
    mov [ash_arena_used], rax
    mov eax, [rdx + F_STATUS]
    mov [last_exit_status], eax
    mov eax, [rdx + F_DONE]
    lea r14d, [rax + 1]
    dec dword [ash_frame_top]
    jmp .ex_loop

.ex_done_node:
    mov eax, [ash_frame_top]
    cmp eax, r15d
    jbe .ex_next
    FRAME_TOP
    mov eax, [last_exit_status]
    mov [rdx + F_STATUS], eax
    cmp dword [rdx + F_TYPE], N_FOR
    je .ex_for_next
    mov eax, [rdx + F_HEAD]
    lea r14d, [rax + 1]
    jmp .ex_loop

.ex_for:
    call ash_frame_push
    test rdx, rdx
    jz .ex_done
    mov dword [rdx + F_TYPE], N_FOR
    mov [rdx + F_HEAD], r14d
    mov eax, [rbx + ND_J1]
    mov [rdx + F_DONE], eax
    mov eax, [rbx + ND_J2]
    mov [rdx + F_DO], eax
    mov dword [rdx + F_STATUS], 0
    mov dword [rdx + F_CURSOR], 0
    ; The word list may use all the free arena while it is built; what it
    ; does not need is given back right after.
    mov [rbp - 48], rdx
    xor edi, edi
    call ash_alloc
    mov rdx, [rbp - 48]
    mov [rdx + F_WORDS], rax
    mov rcx, ASH_ARENA_SIZE
    sub rcx, [ash_arena_used]
    sub rcx, 262144                 ; room above the list for a /bin/sh script
    cmp rcx, 8192
    jb .ex_for_nomem
    mov [rdx + F_WCAP], ecx
    mov rdi, rcx
    call ash_alloc
    mov rdx, [rbp - 48]
    mov rdi, rdx
    mov rsi, [rbx + ND_TEXT]
    call ash_for_setup
    test eax, eax
    jnz .ex_for_fail
    mov rdx, [rbp - 48]
    mov rdi, [rdx + F_WORDS]
    call str_len
    mov rdx, [rbp - 48]
    mov rcx, [rdx + F_WORDS]
    lea rdx, [ash_arena]
    sub rcx, rdx
    lea rax, [rcx + rax + 16]       ; keep just the list: end of text + NUL, rounded up
    and rax, -16
    mov [ash_arena_used], rax
    jmp .ex_for_next

.ex_for_nomem:
    lea rdi, [ash_e_toolong]
    call ash_write_err
.ex_for_fail:
    dec dword [ash_frame_top]
    mov dword [last_exit_status], 2
    jmp .ex_done

.ex_for_next:
    FRAME_TOP
    mov [rbp - 48], rdx
    mov ecx, [rdx + F_CURSOR]
    mov rsi, [rdx + F_WORDS]
    add rsi, rcx
    cmp byte [rsi], 0
    je .ex_for_end
    lea rdi, [ash_word_buf]
    xor ecx, ecx
.ex_for_cp:
    movzx eax, byte [rsi]
    test al, al
    jz .ex_for_cp_end
    inc rsi
    cmp al, 10
    je .ex_for_cp_end
    cmp ecx, 1022
    jae .ex_for_long
    mov [rdi + rcx], al
    inc ecx
    jmp .ex_for_cp
.ex_for_cp_end:
    mov byte [rdi + rcx], 0
    mov rdx, [rbp - 48]
    mov rax, [rdx + F_WORDS]
    sub rsi, rax
    mov [rdx + F_CURSOR], esi
    lea rdi, [rdx + F_VAR]
    lea rsi, [ash_word_buf]
    call ash_setvar
    test eax, eax
    jnz .ex_for_stop
    mov rdx, [rbp - 48]
    mov eax, [rdx + F_DO]
    lea r14d, [rax + 1]
    jmp .ex_loop
.ex_for_long:
    lea rdi, [ash_e_forlong]
    call ash_write_err
    mov dword [last_exit_status], 1
.ex_for_stop:                       ; the loop variable cannot hold the word
    mov rdx, [rbp - 48]
    mov dword [rdx + F_STATUS], 1
    jmp .ex_loop_exit
.ex_for_end:
    mov rdx, [rbp - 48]
    jmp .ex_loop_exit

.ex_break:
    mov eax, [ash_frame_top]
    cmp eax, r15d
    jbe .ex_next
    call .ex_nth_frame              ; "break N" leaves N loops at once
    mov dword [rdx + F_STATUS], 0
    jmp .ex_loop_exit

.ex_continue:
    mov eax, [ash_frame_top]
    cmp eax, r15d
    jbe .ex_next
    call .ex_nth_frame
    mov dword [last_exit_status], 0
    cmp dword [rdx + F_TYPE], N_FOR
    je .ex_for_next
    mov eax, [rdx + F_HEAD]
    lea r14d, [rax + 1]
    jmp .ex_loop

; Makes the Nth loop from the top (N = ash_loop_n, at most the loops of this
; body) the top one, dropping the ones inside it and what they held in the
; arena. Returns rdx = its frame.
.ex_nth_frame:
    mov eax, [ash_frame_top]
    sub eax, [ash_loop_n]
    jb .enf_clamp
    cmp eax, r15d
    jae .enf_set
.enf_clamp:
    mov eax, r15d
.enf_set:
    lea ecx, [rax + 1]
    cmp ecx, [ash_frame_top]
    jae .enf_same
    imul edx, ecx, ASH_FRAME_SIZE
    lea rsi, [ash_frames]
    mov rdx, [rsi + rdx + F_ARENA]
    mov [ash_arena_used], rdx
.enf_same:
    mov [ash_frame_top], ecx
    imul eax, eax, ASH_FRAME_SIZE
    lea rdx, [ash_frames]
    add rdx, rax
    ret

.ex_intr:
    mov dword [last_exit_status], 130
.ex_done:
    mov [ash_frame_top], r15d
    mov rax, [rbp - 72]
    mov [ash_arena_used], rax
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; eax = 1 when node rbx must be skipped because of && / || before it
.ex_skip_by_conn:
    xor eax, eax
    mov ecx, [rbx + ND_CONN]
    and ecx, C_MASK
    cmp ecx, C_AND
    je .esc_and
    cmp ecx, C_OR
    jne .esc_ret
    cmp dword [last_exit_status], 0
    sete al
    ret
.esc_and:
    cmp dword [last_exit_status], 0
    setne al
.esc_ret:
    ret

; ----------------------------------------------------------------------------
; ash_sh_run(rdi = script text, esi = its length) - run it with /bin/sh -c,
; wait, set the status. The script gets the shell functions, the positional
; parameters and $? put in front of it (see ash_ctx_script).
; ----------------------------------------------------------------------------
ash_sh_run:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8
    mov [rsp], rdi                  ; the statement as written, for the job list
    mov r13, [ash_arena_used]
    call ash_ctx_script
    test rax, rax
    jz .sr_nomem
    mov r12, rax
    cmp byte [interactive_mode], 0
    je .sr_fork
    call restore_terminal
.sr_fork:
    call jc_prepare
    mov eax, SYS_FORK
    syscall
    test rax, rax
    js .sr_fail
    jz .sr_child
    mov ebx, eax
    mov edi, ebx
    mov esi, 1
    call jc_parent_after_fork
    mov edi, ebx
    mov rsi, [rsp]
    call jc_wait_fg                 ; 128 + signal when killed, job control aware
.sr_status:
    mov [last_exit_status], eax
    jmp .sr_done
.sr_fail:
    mov dword [last_exit_status], 1
.sr_done:
    cmp byte [interactive_mode], 0
    je .sr_ret
    call setup_raw_mode
.sr_ret:
    mov [ash_arena_used], r13
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
.sr_nomem:
    lea rdi, [ash_e_shlong]
    call ash_write_err
    mov dword [last_exit_status], 2
    jmp .sr_ret
.sr_child:
    mov edi, 1
    call jc_child_setup
    lea rdi, [ash_shc_argv]
    mov [rdi + 16], r12
    call ash_exec_argv              ; does not return

; ----------------------------------------------------------------------------
; ash_ctx_script(rdi = text, esi = length) -> rax = NUL-terminated script in
; the arena, or 0 when it does not fit (a program argument is limited to
; about 128 KB).
; /bin/sh knows nothing about this shell, so the text gets what is cheap to
; hand over put in front of it: "set --" with the positional parameters, a
; "(exit N)" so that $? starts out right, and every shell function defined
; with name() { body }. Variables set with NAME=value are exported already.
; Changes the text makes to the shell itself (cd, assignments, functions)
; stay in the child.
; ----------------------------------------------------------------------------
section .data
    ash_c_set           db "set --", 0
    ash_c_exit          db "(exit ", 0
    ash_c_close         db ")", 10, 0
    ash_c_fopen         db "() {", 10, 0
    ash_c_fclose        db 10, "}", 10, 0
    ash_c_nl            db 10, 0
    ash_c_sp            db " ", 0
    ash_e_shlong        db "ash: statement too long for /bin/sh", 10, 0
section .text

ash_ctx_script:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24                     ; [rbp-48] scratch pointer, [rbp-56] text length

    mov r12, rdi
    mov eax, esi
    mov [rbp - 56], rax
    xor edi, edi
    call ash_alloc                  ; the free end of the arena
    mov r14, rax                    ; start of the script
    mov rbx, rax                    ; write cursor
    lea r15, [ash_arena + ASH_ARENA_SIZE - 16]
    lea rax, [r14 + 126000]
    cmp rax, r15
    jae .cx_limit_ok
    mov r15, rax
.cx_limit_ok:                       ; bytes below r15 may be written

    ; positional parameters
    cmp dword [ash_pos_argc], 0
    je .cx_funcs
    lea rsi, [ash_c_set]
    call .cx_put
    xor r13d, r13d
.cx_args:
    cmp r13d, [ash_pos_argc]
    jae .cx_args_end
    lea rsi, [ash_c_sp]
    call .cx_put
    mov rax, [ash_pos_argv]
    mov rsi, [rax + r13 * 8]
    call .cx_putq
    inc r13d
    jmp .cx_args
.cx_args_end:
    lea rsi, [ash_c_nl]
    call .cx_put

    ; functions
.cx_funcs:
    xor r13d, r13d
.cx_fn:
    cmp r13d, [ash_func_count]
    jae .cx_status
    imul eax, r13d, ASH_FUNC_SIZE
    lea rsi, [ash_funcs]
    add rsi, rax
    mov [rbp - 48], rsi
    call .cx_put
    lea rsi, [ash_c_fopen]
    call .cx_put
    mov rsi, [rbp - 48]
    add rsi, ASH_FUNC_NAME
    call .cx_put
    lea rsi, [ash_c_fclose]
    call .cx_put
    inc r13d
    jmp .cx_fn

    ; $? (after the definitions, which would reset it)
.cx_status:
    cmp dword [last_exit_status], 0
    je .cx_text
    lea rsi, [ash_c_exit]
    call .cx_put
    movsxd rsi, dword [last_exit_status]
    lea rdi, [ash_num_buf]
    call ash_fmt_int
    lea rsi, [ash_num_buf]
    call .cx_put
    lea rsi, [ash_c_close]
    call .cx_put

    ; the statement itself
.cx_text:
    mov ecx, [rbp - 56]
    lea rax, [rbx + rcx]
    cmp rax, r15
    jae .cx_fail
    cmp rbx, r15
    ja .cx_fail
    mov rsi, r12
    mov rdi, rbx
    rep movsb
    mov rbx, rax
    mov byte [rbx], 0
    lea rdi, [rbx + 1]
    sub rdi, r14
    call ash_alloc                  ; claim what was written
    mov rax, r14
    jmp .cx_ret
.cx_fail:
    xor eax, eax
.cx_ret:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; .cx_put - append the string at rsi (rbx = cursor, r15 = limit)
.cx_put:
    mov al, [rsi]
    test al, al
    jz .cp_done
    cmp rbx, r15
    jae .cp_over
    mov [rbx], al
    inc rbx
    inc rsi
    jmp .cx_put
.cp_over:
    lea rbx, [r15 + 1]
.cp_done:
    ret

; .cx_putq - append the string at rsi in single quotes
.cx_putq:
    cmp rbx, r15
    jae .cq_over
    mov byte [rbx], 0x27
    inc rbx
.cq_loop:
    mov al, [rsi]
    test al, al
    jz .cq_end
    inc rsi
    cmp al, 0x27
    je .cq_quote
    cmp rbx, r15
    jae .cq_over
    mov [rbx], al
    inc rbx
    jmp .cq_loop
.cq_quote:                          ; ' becomes '\''
    lea rax, [rbx + 4]
    cmp rax, r15
    jae .cq_over
    mov dword [rbx], 0x27275C27
    mov rbx, rax
    jmp .cq_loop
.cq_end:
    cmp rbx, r15
    jae .cq_over
    mov byte [rbx], 0x27
    inc rbx
    ret
.cq_over:
    lea rbx, [r15 + 1]
    ret

; ----------------------------------------------------------------------------
; ash_capture(rdi = argv, rsi = buffer, edx = size) -> eax = bytes captured
; Runs argv with its stdout into the buffer (NUL-terminated); stdin is
; /dev/null. Output beyond size - 1 bytes is dropped and ash_cap_trunc is
; set. The child's status (128 + signal when killed) goes to ash_cap_status.
; In an interactive shell the terminal is cooked meanwhile, so Ctrl+C
; reaches the child and stops it; a child killed by SIGINT also raises
; ctrl_c_flag so the running script stops too.
; ----------------------------------------------------------------------------
section .data
    ash_dev_null        db "/dev/null", 0
section .bss
    ash_cap_status      resd 1
    ash_cap_trunc       resb 1
    ash_cap_drain       resb 4096
section .text

ash_capture:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24                     ; [rbp-48] wait status, [rbp-56] pipe fds

    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov dword [ash_cap_status], 1
    mov byte [ash_cap_trunc], 0
    mov byte [r13], 0
    xor r15d, r15d                  ; bytes stored
    cmp byte [interactive_mode], 0
    je .ac_pipe
    call restore_terminal
.ac_pipe:
    lea rdi, [rbp - 56]
    mov esi, O_CLOEXEC
    mov eax, SYS_PIPE2
    syscall
    test rax, rax
    js .ac_error
    mov eax, SYS_FORK
    syscall
    test rax, rax
    js .ac_fork_error
    jz .ac_child
    mov ebx, eax                    ; child pid

    mov edi, [rbp - 52]             ; the parent keeps only the read end
    mov eax, SYS_CLOSE
    syscall
.ac_read:
    mov edx, r14d
    dec edx
    sub edx, r15d
    jle .ac_drain
    mov edi, [rbp - 56]
    lea rsi, [r13 + r15]
    xor eax, eax                    ; SYS_READ
    syscall
    cmp rax, -EINTR
    je .ac_read
    test rax, rax
    jle .ac_read_done
    add r15d, eax
    jmp .ac_read
.ac_drain:
    mov edi, [rbp - 56]
    lea rsi, [ash_cap_drain]
    mov edx, 4096
    xor eax, eax
    syscall
    cmp rax, -EINTR
    je .ac_drain
    test rax, rax
    jle .ac_read_done
    mov byte [ash_cap_trunc], 1
    jmp .ac_drain
.ac_read_done:
    mov byte [r13 + r15], 0
    mov edi, [rbp - 56]
    mov eax, SYS_CLOSE
    syscall
.ac_wait:
    mov dword [rbp - 48], 0
    mov edi, ebx
    lea rsi, [rbp - 48]
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -EINTR
    je .ac_wait
    mov eax, [rbp - 48]
    mov edx, eax
    and edx, 0x7F
    jz .ac_exited
    cmp edx, SIGINT
    jne .ac_sig
    mov byte [ctrl_c_flag], 1
.ac_sig:
    lea eax, [rdx + 128]
    jmp .ac_status
.ac_exited:
    shr eax, 8
    and eax, 0xFF
.ac_status:
    mov [ash_cap_status], eax
    jmp .ac_done

.ac_fork_error:
    mov edi, [rbp - 56]
    mov eax, SYS_CLOSE
    syscall
    mov edi, [rbp - 52]
    mov eax, SYS_CLOSE
    syscall
    lea rdi, [ash_msg_fork]
    call ash_write_err
.ac_error:
.ac_done:
    cmp byte [interactive_mode], 0
    je .ac_ret
    call setup_raw_mode
.ac_ret:
    mov eax, r15d
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
.ac_child:
    mov edi, [rbp - 52]
    mov esi, 1
    mov eax, SYS_DUP2
    syscall
    lea rdi, [ash_dev_null]
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .ac_exec
    mov edi, eax
    xor esi, esi
    mov eax, SYS_DUP2
    syscall
.ac_exec:
    mov rdi, r12
    call ash_exec_argv              ; does not return

; ----------------------------------------------------------------------------
; ash_capture_script(rdi = script text, rsi = buffer, edx = size) -> eax = bytes
; ash_capture for "/bin/sh -c SCRIPT", with the shell functions and positional
; parameters in front of the script (see ash_ctx_script).
; ----------------------------------------------------------------------------
ash_capture_script:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 32                     ; [rbp-64] argv for the shell
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, [ash_arena_used]
    call str_len
    mov esi, eax
    mov rdi, rbx
    call ash_ctx_script
    test rax, rax
    jz .cs_fail
    lea rcx, [sh_path]
    mov [rbp - 64], rcx
    lea rcx, [sh_dash_c]
    mov [rbp - 56], rcx
    mov [rbp - 48], rax
    mov qword [rbp - 40], 0
    lea rdi, [rbp - 64]
    mov rsi, r12
    mov edx, r13d
    call ash_capture
    jmp .cs_ret
.cs_fail:
    lea rdi, [ash_e_shlong]
    call ash_write_err
    mov byte [r12], 0
    mov byte [ash_cap_trunc], 0
    mov dword [ash_cap_status], 2
    xor eax, eax
.cs_ret:
    mov [ash_arena_used], r14
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; ash_setvar(rdi = name, rsi = value) -> eax = 0 stored, 1 refused
; setenv_internal says why on its own when the name, the value or the table
; do not fit; this turns that into the status the script engine wants.
; ----------------------------------------------------------------------------
ash_setvar:
    sub rsp, 8
    call setenv_internal
    add rsp, 8
    test eax, eax
    jz .sv_ret
    mov dword [last_exit_status], 1
    mov eax, 1
.sv_ret:
    ret

; ash_frame_push -> rdx = new frame, or 0 (message printed) when too deep
ash_frame_push:
    mov eax, [ash_frame_top]
    cmp eax, ASH_FRAMES_MAX
    jae .fp_full
    imul edx, eax, ASH_FRAME_SIZE
    lea rcx, [ash_frames]
    add rdx, rcx
    inc dword [ash_frame_top]
    mov rax, [ash_arena_used]
    mov [rdx + F_ARENA], rax
    ret
.fp_full:
    sub rsp, 8
    lea rdi, [ash_e_depth]
    call ash_write_err
    add rsp, 8
    mov byte [ash_abort], 1
    mov dword [last_exit_status], 2
    xor edx, edx
    ret

; ----------------------------------------------------------------------------
; ash_for_setup(rdi = frame, rsi = "NAME in WORDS") -> eax 0 ok / 2 error
; Fills F_VAR and F_WORDS (one word per line). Words with globs, $( ) or
; backticks are expanded by /bin/sh; everything else natively.
; ----------------------------------------------------------------------------
ash_for_setup:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + F_WORDS]
    mov byte [rax], 0

    ; NAME
    xor ecx, ecx
.fs_name:
    movzx eax, byte [r12 + rcx]
    call ash_is_name_char
    test edx, edx
    jz .fs_name_end
    test ecx, ecx
    jnz .fs_name_ok
    cmp al, '9'                     ; must not start with a digit
    jbe .fs_bad
.fs_name_ok:
    cmp ecx, 38
    jae .fs_bad
    mov [rbx + F_VAR + rcx], al
    inc ecx
    jmp .fs_name
.fs_name_end:
    test ecx, ecx
    jz .fs_bad
    mov byte [rbx + F_VAR + rcx], 0
    add r12, rcx
    mov rdi, r12
    call ash_skip_blanks
    mov r12, rax
    cmp byte [r12], 0
    je .fs_ok                       ; "for x" alone: no words
    mov rdi, r12
    lea rsi, [ash_s_in]
    call ash_word_is
    test eax, eax
    jz .fs_bad
    lea rdi, [r12 + 2]
    call ash_skip_blanks
    mov r12, rax

    mov rdi, r12
    call str_len
    cmp eax, MAX_INPUT - 1
    jae .fs_toolong
    ; Globs and $( ) are judged on the text as written: a variable's value
    ; is data and never needs /bin/sh. When sh runs the list it expands the
    ; command substitutions itself, everything else is expanded here first.
    mov rdi, r12
    call ash_needs_sh
    mov [rsp], eax
    mov rdi, r12
    xor esi, esi
    call ash_load_line              ; "$@" becomes one word per parameter
    test eax, eax
    jnz .fs_failed
    cmp dword [rsp], 0
    jne .fs_expand_sh
    call expand_env_vars
    jmp .fs_expanded
.fs_expand_sh:
    call expand_env_vars_sh
.fs_expanded:
    test eax, eax
    jnz .fs_failed                  ; message printed
    cmp dword [rsp], 0
    jne .fs_sh

    ; Native split: one unquoted word per line
    lea r12, [input_buf]
    mov r13, [rbx + F_WORDS]        ; write pointer
.fs_split:
    mov rdi, r12
    lea rsi, [ash_word_buf]
    mov edx, 1
    call ash_next_word
    test rax, rax
    jz .fs_split_end
    mov r12, rax
    lea rsi, [ash_word_buf]
.fs_split_cp:
    mov rax, [rbx + F_WORDS]
    mov ecx, [rbx + F_WCAP]
    lea rax, [rax + rcx - 2]
    cmp r13, rax
    jae .fs_listlong
    movzx eax, byte [rsi]
    test al, al
    jz .fs_split_nl
    mov [r13], al
    inc r13
    inc rsi
    jmp .fs_split_cp
.fs_split_nl:
    mov byte [r13], 10
    inc r13
    jmp .fs_split
.fs_split_end:
    mov byte [r13], 0
    jmp .fs_ok

.fs_sh:
    ; printf '%s\n' WORDS  -> one word per line from /bin/sh
    lea rdi, [input_buf]
    call ash_sh_decode              ; marked data bytes become plain text
    mov r13, rax
    lea rdi, [ash_sh_script]
    lea rsi, [ash_sh_printf]
    call upd_stpcpy
    mov rdi, rax
    mov rsi, r13
    call upd_stpcpy
    lea rdi, [ash_sh_script]
    mov rsi, [rbx + F_WORDS]
    mov edx, [rbx + F_WCAP]
    call ash_capture_script
    cmp byte [ash_cap_trunc], 0
    jne .fs_listlong
.fs_ok:
    xor eax, eax
    jmp .fs_ret
.fs_failed:
    mov eax, 2
    jmp .fs_ret
.fs_toolong:
    lea rdi, [ash_e_line]
    call ash_write_err
    mov eax, 2
    jmp .fs_ret
.fs_listlong:
    lea rdi, [ash_e_forlist]
    call ash_write_err
    mov eax, 2
    jmp .fs_ret
.fs_bad:
    lea rdi, [ash_e_forvar]
    call ash_write_err
    mov eax, 2
.fs_ret:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; ash_needs_sh(rdi = text) -> eax = 1 if it has $( or ` anywhere, or an
; unquoted * ? [ (a glob). Those still go through /bin/sh.
; ----------------------------------------------------------------------------
ash_needs_sh:
    xor ecx, ecx                    ; quote char or 0
.ns_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .ns_no
    cmp al, EV_MARK
    je .ns_mark
    cmp al, '`'
    je .ns_yes
    cmp al, '$'
    jne .ns_q
    cmp byte [rdi + 1], '('
    je .ns_yes
.ns_q:
    test ecx, ecx
    jz .ns_unq
    cmp eax, ecx
    jne .ns_next
    xor ecx, ecx
    jmp .ns_next
.ns_unq:
    cmp al, 0x27
    je .ns_open
    cmp al, '"'
    je .ns_open
    cmp al, '\'
    je .ns_bs
    cmp al, '*'
    je .ns_yes
    cmp al, '?'
    je .ns_yes
    cmp al, '['
    je .ns_yes
.ns_next:
    inc rdi
    jmp .ns_loop
.ns_open:
    mov ecx, eax
    jmp .ns_next
.ns_bs:
    cmp byte [rdi + 1], 0
    je .ns_no
    add rdi, 2
    jmp .ns_loop
.ns_mark:
    cmp byte [rdi + 1], 0
    je .ns_no
    add rdi, 2
    jmp .ns_loop
.ns_yes:
    mov eax, 1
    ret
.ns_no:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; ash_run_cmd(rdi = command text) -> eax 0 / 1 break / 2 continue
; ----------------------------------------------------------------------------
ash_run_cmd:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    call ash_skip_blanks
    mov rbx, rax
    cmp byte [rbx], 0
    je .rc_ok

    mov rdi, rbx
    lea rsi, [ash_s_break]
    call ash_word_is
    test eax, eax
    jnz .rc_break
    mov rdi, rbx
    lea rsi, [ash_s_continue]
    call ash_word_is
    test eax, eax
    jnz .rc_continue
    mov rdi, rbx
    lea rsi, [ash_s_return]
    call ash_word_is
    test eax, eax
    jnz .rc_return
    mov rdi, rbx
    lea rsi, [ash_s_shift]
    call ash_word_is
    test eax, eax
    jnz .rc_shift

    cmp byte [rbx], '!'
    jne .rc_assign
    movzx eax, byte [rbx + 1]
    cmp al, ' '
    je .rc_bang
    cmp al, 9
    jne .rc_assign
.rc_bang:
    lea rdi, [rbx + 2]
    call ash_run_cmd
    test eax, eax
    jnz .rc_ret
    xor eax, eax
    cmp dword [last_exit_status], 0
    sete al
    mov [last_exit_status], eax
    xor eax, eax
    jmp .rc_ret

.rc_assign:
    mov rdi, rbx
    call ash_try_assign
    test eax, eax
    jnz .rc_ok

    cmp dword [ash_func_count], 0
    je .rc_dispatch
    xor esi, esi                    ; first word length
.rc_fw:
    movzx eax, byte [rbx + rsi]
    test al, al
    jz .rc_fw_end
    cmp al, ' '
    je .rc_fw_end
    cmp al, 9
    je .rc_fw_end
    inc esi
    jmp .rc_fw
.rc_fw_end:
    mov r12d, esi
    mov rdi, rbx
    call ash_func_find
    test rax, rax
    jz .rc_dispatch
    mov r13, rax
    lea rdi, [rbx + r12]
    call ash_has_shell_ops
    test eax, eax
    jnz .rc_func_sh
    mov rdi, r13
    lea rsi, [rbx + r12]
    call ash_call_func
    jmp .rc_ok
.rc_func_sh:
    ; "f args | cmd", "f > file", "f &", "f $(cmd)": the whole command goes to
    ; /bin/sh, which gets the function definitions along with it
    mov rdi, rbx
    call str_len
    mov esi, eax
    mov rdi, rbx
    call ash_sh_run
    jmp .rc_ok

.rc_dispatch:
    ; ". file" is "source file": it runs in this shell, so cd and assignments stay
    mov rdi, rbx
    lea rsi, [ash_s_dot]
    call ash_word_is
    mov rdi, rbx
    xor esi, esi
    test eax, eax
    jz .rc_load
    lea rdi, [rbx + 1]
    lea rsi, [ash_s_source]
.rc_load:
    call ash_load_line
    test eax, eax
    jnz .rc_ok                      ; too long: message printed, status set
    call dispatch_command
.rc_ok:
    xor eax, eax
    jmp .rc_ret
.rc_break:
    lea rdi, [rbx + 5]
    mov esi, 1
    call ash_count_arg
    test edx, edx
    jz .rc_badcount
    test eax, eax
    jz .rc_badcount
    mov [ash_loop_n], eax
    mov eax, 1
    jmp .rc_ret
.rc_continue:
    lea rdi, [rbx + 8]
    mov esi, 1
    call ash_count_arg
    test edx, edx
    jz .rc_badcount
    test eax, eax
    jz .rc_badcount
    mov [ash_loop_n], eax
    mov eax, 2
    jmp .rc_ret
.rc_badcount:
    lea rdi, [ash_e_count]
    call ash_write_err
    mov dword [last_exit_status], 2
    xor eax, eax
    jmp .rc_ret
.rc_shift:
    ; shift [N]: drop the first N positional parameters
    lea rdi, [rbx + 5]
    mov esi, 1
    call ash_count_arg
    test edx, edx
    jz .rc_badcount
    cmp eax, [ash_pos_argc]
    ja .rc_shift_range
    mov ecx, eax
    sub [ash_pos_argc], ecx
    shl rcx, 3
    add [ash_pos_argv], rcx
    call ash_pos_publish
    test eax, eax
    jnz .rc_ok
    mov dword [last_exit_status], 0
    jmp .rc_ok
.rc_shift_range:
    lea rdi, [ash_e_shift]
    call ash_write_err
    mov dword [last_exit_status], 1
    jmp .rc_ok
.rc_return:
    ; return [N]: status N (default: keep the last one), stop this body
    cmp dword [ash_func_depth], 0
    jne .rc_return_ok
    cmp dword [source_depth], 0
    jne .rc_return_ok
    lea rdi, [ash_e_return]
    call ash_write_err
    mov dword [last_exit_status], 1
    jmp .rc_ok
.rc_return_ok:
    lea rdi, [rbx + 6]
    call ash_skip_blanks
    cmp byte [rax], 0
    je .rc_return_go
    mov rdi, rax
    call ash_parse_int
    test edx, edx
    jz .rc_return_go
    and eax, 0xFF
    mov [last_exit_status], eax
.rc_return_go:
    mov eax, 3
.rc_ret:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

section .data
    ash_s_dot           db ".", 0
    ash_s_source        db "source", 0
section .text

; ----------------------------------------------------------------------------
; ash_load_line(rdi = text, rsi = prefix string or 0) -> eax = 0 ok, 1 too long
; Puts prefix + text into input_buf for dispatch_command and the other
; expanders. Inside double quotes "$@" becomes one quoted word per positional
; parameter ("$@" with no parameters becomes no word at all), the way sh does
; it; expand_env_vars alone could only hand over one joined word. Parameter
; text is data, so the bytes that could read as syntax get an EV_MARK in front,
; exactly as expand_env_vars marks a substituted value. Everything else is
; copied as it is; text in '...' and after a backslash is never looked at.
; ----------------------------------------------------------------------------
ash_load_line:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8                      ; [rsp] parameter index

    mov r13, rdi                    ; text
    lea rdi, [input_buf]
    lea r12, [input_buf + MAX_INPUT - 2] ; the last byte that may be written
    test rsi, rsi
    jz .ll_start
.ll_prefix:
    mov al, [rsi]
    test al, al
    jz .ll_start
    cmp rdi, r12
    jae .ll_long
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .ll_prefix
.ll_start:
    mov rsi, r13
    xor ebx, ebx                    ; inside "..."
    xor r14d, r14d                  ; where the opening " of that string went
    xor r13d, r13d                  ; inside '...'
.ll_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .ll_end
    test r13d, r13d
    jnz .ll_sq
    cmp al, '\'
    je .ll_pair
    cmp al, EV_MARK
    je .ll_pair
    cmp al, '"'
    je .ll_dq
    test ebx, ebx
    jnz .ll_in_dq
    cmp al, 0x27
    jne .ll_put
    mov r13d, 1
    jmp .ll_put
.ll_in_dq:
    cmp al, '$'
    jne .ll_put
    cmp byte [rsi + 1], '@'
    je .ll_at
.ll_put:
    cmp rdi, r12
    jae .ll_long
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .ll_loop
.ll_sq:
    cmp al, 0x27
    jne .ll_put
    xor r13d, r13d
    jmp .ll_put
.ll_dq:
    test ebx, ebx
    jnz .ll_dq_close
    mov ebx, 1
    mov r14, rdi
    jmp .ll_put
.ll_dq_close:
    xor ebx, ebx
    jmp .ll_put
.ll_pair:                           ; a backslash or marker and the byte after it
    lea rax, [r12 - 1]
    cmp rdi, rax
    jae .ll_long
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    movzx eax, byte [rsi]
    test al, al
    jz .ll_loop
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .ll_loop

.ll_at:
    add rsi, 2
    mov ecx, [ash_pos_argc]
    test ecx, ecx
    jnz .ll_words
    lea rax, [rdi - 1]
    cmp rax, r14                    ; the string is just "$@": no word at all
    jne .ll_loop
    cmp byte [rsi], '"'
    jne .ll_loop
    mov rdi, r14
    inc rsi
    xor ebx, ebx
    jmp .ll_loop
.ll_words:
    mov r15, [ash_pos_argv]
    mov dword [rsp], 0
.ll_word:
    mov eax, [rsp]
    test eax, eax
    jz .ll_arg
    lea rax, [r12 - 3]              ; " " between two words
    cmp rdi, rax
    jae .ll_long
    mov byte [rdi], '"'
    mov byte [rdi + 1], ' '
    mov byte [rdi + 2], '"'
    add rdi, 3
.ll_arg:
    mov eax, [rsp]
    mov rcx, [r15 + rax * 8]
.ll_arg_ch:
    movzx eax, byte [rcx]
    test al, al
    jz .ll_arg_end
    cmp al, EV_MARK
    je .ll_arg_mark
    push rsi                        ; ev_is_special clobbers rsi
    call ev_is_special
    pop rsi
    test edx, edx
    jz .ll_arg_put
.ll_arg_mark:
    lea rdx, [r12 - 1]
    cmp rdi, rdx
    jae .ll_long
    mov byte [rdi], EV_MARK
    inc rdi
.ll_arg_put:
    cmp rdi, r12
    jae .ll_long
    mov [rdi], al
    inc rdi
    inc rcx
    jmp .ll_arg_ch
.ll_arg_end:
    inc dword [rsp]
    mov eax, [rsp]
    cmp eax, [ash_pos_argc]
    jb .ll_word
    jmp .ll_loop

.ll_end:
    mov byte [rdi], 0
    xor eax, eax
    jmp .ll_ret
.ll_long:
    lea rdi, [ash_e_line]
    call ash_write_err
    mov dword [last_exit_status], 2
    mov eax, 1
.ll_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; ash_count_arg(rdi = text after the command word, esi = default)
;   -> eax = the number, edx = 1 ok / 0 when it is not a number >= 0
; Variables in the argument are expanded first ("break $n").
; ----------------------------------------------------------------------------
ash_count_arg:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov ebx, esi
    call ash_skip_blanks
    mov r12, rax
    cmp byte [r12], 0
    je .ca_default
    mov rdi, r12
    call str_len
    cmp eax, MAX_INPUT - 1
    jae .ca_bad
    lea rdi, [input_buf]
    mov rsi, r12
    call str_copy
    call expand_env_vars
    test eax, eax
    jnz .ca_bad
    lea rdi, [input_buf]
    call ash_parse_int
    test edx, edx
    jz .ca_bad
    test rax, rax
    js .ca_bad
    cmp rax, 0x7FFFFFFF
    ja .ca_bad
    mov edx, 1
    jmp .ca_ret
.ca_default:
    mov eax, ebx
    mov edx, 1
    jmp .ca_ret
.ca_bad:
    xor eax, eax
    xor edx, edx
.ca_ret:
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; ash_has_shell_ops(rdi = text) -> eax = 1 when the text has an unquoted
; | < > & or a $( ) / backtick substitution (not $(( )) arithmetic): things
; only /bin/sh can do with a function call.
; ----------------------------------------------------------------------------
ash_has_shell_ops:
    xor ecx, ecx                    ; open quote character
.hs_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .hs_no
    inc rdi
    cmp ecx, 0x27
    je .hs_sq
    cmp al, '\'
    je .hs_bs
    cmp al, '`'
    je .hs_yes
    cmp al, '$'
    je .hs_dollar
    test ecx, ecx
    jnz .hs_dq
    cmp al, '"'
    je .hs_open_dq
    cmp al, 0x27
    je .hs_open_sq
    cmp al, '|'
    je .hs_yes
    cmp al, '<'
    je .hs_yes
    cmp al, '>'
    je .hs_yes
    cmp al, '&'
    je .hs_yes
    jmp .hs_loop
.hs_sq:
    cmp al, 0x27
    jne .hs_loop
    xor ecx, ecx
    jmp .hs_loop
.hs_dq:
    cmp al, '"'
    jne .hs_loop
    xor ecx, ecx
    jmp .hs_loop
.hs_open_dq:
    mov ecx, '"'
    jmp .hs_loop
.hs_open_sq:
    mov ecx, 0x27
    jmp .hs_loop
.hs_bs:
    cmp byte [rdi], 0
    je .hs_no
    inc rdi
    jmp .hs_loop
.hs_dollar:
    cmp byte [rdi], '('
    jne .hs_loop
    cmp byte [rdi + 1], '('
    jne .hs_yes
    add rdi, 2                      ; $(( ... )): skip to the matching ))
    mov edx, 2
.hs_ar:
    movzx eax, byte [rdi]
    test al, al
    jz .hs_no
    inc rdi
    cmp al, '('
    jne .hs_ar_rp
    inc edx
    jmp .hs_ar
.hs_ar_rp:
    cmp al, ')'
    jne .hs_ar
    dec edx
    jnz .hs_ar
    jmp .hs_loop
.hs_yes:
    mov eax, 1
    ret
.hs_no:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; ash_try_assign(rdi = text) -> eax = 1 if text was "NAME=value" (one word)
; and the variable was set; 0 if it is something else.
; ----------------------------------------------------------------------------
ash_try_assign:
    push rbp
    mov rbp, rsp
    push rbx
    push r12

    mov rbx, rdi
    movzx eax, byte [rbx]
    cmp al, '0'
    jb .ta_scan_name
    cmp al, '9'
    jbe .ta_no                      ; names cannot start with a digit
.ta_scan_name:
    xor ecx, ecx
.ta_name:
    movzx eax, byte [rbx + rcx]
    cmp al, '='
    je .ta_eq
    call ash_is_name_char
    test edx, edx
    jz .ta_no
    inc ecx
    cmp ecx, 63
    jae .ta_no
    jmp .ta_name
.ta_eq:
    test ecx, ecx
    jz .ta_no
    mov r12d, ecx

    ; The value must be one word: no unquoted blank outside ( )
    lea rsi, [rbx + rcx + 1]
    xor ecx, ecx                    ; quote char
    xor r8d, r8d                    ; ( depth
.ta_val:
    movzx eax, byte [rsi]
    test al, al
    jz .ta_val_ok
    test ecx, ecx
    jz .ta_val_unq
    cmp eax, ecx
    jne .ta_val_next
    xor ecx, ecx
    jmp .ta_val_next
.ta_val_unq:
    cmp al, '\'
    je .ta_val_bs
    cmp al, 0x27
    je .ta_val_open
    cmp al, '"'
    je .ta_val_open
    cmp al, '`'
    je .ta_val_open
    cmp al, '('
    je .ta_val_lp
    cmp al, ')'
    je .ta_val_rp
    test r8d, r8d
    jnz .ta_val_next
    cmp al, ' '
    je .ta_no
    cmp al, 9
    je .ta_no
    cmp al, '|'
    je .ta_no
    cmp al, '>'
    je .ta_no
    cmp al, '<'
    je .ta_no
    cmp al, '&'
    je .ta_no
.ta_val_next:
    inc rsi
    jmp .ta_val
.ta_val_open:
    mov ecx, eax
    jmp .ta_val_next
.ta_val_lp:
    inc r8d
    jmp .ta_val_next
.ta_val_rp:
    test r8d, r8d
    jz .ta_val_next
    dec r8d
    jmp .ta_val_next
.ta_val_bs:
    cmp byte [rsi + 1], 0
    je .ta_val_ok
    add rsi, 2
    jmp .ta_val

.ta_val_ok:
    lea rdi, [ash_name_buf]
    xor ecx, ecx
.ta_cp_name:
    cmp ecx, r12d
    je .ta_cp_name_end
    mov al, [rbx + rcx]
    mov [rdi + rcx], al
    inc ecx
    jmp .ta_cp_name
.ta_cp_name_end:
    mov byte [rdi + rcx], 0

    lea rbx, [rbx + r12 + 1]        ; value text
    mov rdi, rbx
    call str_len
    cmp eax, MAX_INPUT - 1
    jae .ta_toolong
    lea rdi, [input_buf]
    mov rsi, rbx
    call str_copy
    mov byte [ev_keep_nl], 1        ; the value of an assignment is not word split
    call expand_env_vars            ; $( ) and `` run here and come back as data
    mov byte [ev_keep_nl], 0
    test eax, eax
    jnz .ta_expand_failed           ; message printed, status set

    lea rdi, [input_buf]
    lea rsi, [ash_word_buf]
    xor edx, edx
    call ash_next_word
    lea rsi, [ash_word_buf]

    lea rdi, [ash_name_buf]
    call ash_setvar
    test eax, eax
    jnz .ta_set_failed              ; refused: the message and status say so
    ; "x=$(cmd)" has the status of cmd, like sh
    mov eax, [ev_subst_status]
    test eax, eax
    jns .ta_status
    xor eax, eax
.ta_status:
    mov [last_exit_status], eax
.ta_set_failed:
    mov eax, 1
    jmp .ta_ret
.ta_expand_failed:
    mov eax, 1
    jmp .ta_ret
.ta_toolong:
    lea rdi, [ash_e_line]
    call ash_write_err
    mov dword [last_exit_status], 2
    mov eax, 1
    jmp .ta_ret
.ta_no:
    xor eax, eax
.ta_ret:
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; Functions
; ----------------------------------------------------------------------------

; ash_func_find(rdi = name, esi = length) -> rax = table entry or 0
ash_func_find:
    xor eax, eax
    cmp esi, ASH_FUNC_NAME - 1
    ja .ff_ret
    lea r8, [ash_funcs]
    xor r9d, r9d
.ff_loop:
    cmp r9d, [ash_func_count]
    jae .ff_none
    xor ecx, ecx
.ff_cmp:
    cmp ecx, esi
    je .ff_end
    mov dl, [rdi + rcx]
    cmp dl, [r8 + rcx]
    jne .ff_next
    inc ecx
    jmp .ff_cmp
.ff_end:
    cmp byte [r8 + rcx], 0
    jne .ff_next
    mov rax, r8
    ret
.ff_next:
    add r8, ASH_FUNC_SIZE
    inc r9d
    jmp .ff_loop
.ff_none:
    xor eax, eax
.ff_ret:
    ret

; ash_func_define(rdi = name (NUL-terminated), rsi = body, edx = body length)
; Replaces an existing function of the same name.
ash_func_define:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov dword [last_exit_status], 0

    ; The name must be one plain word that fits the table entry
    xor ecx, ecx
.fd_chk:
    movzx eax, byte [r12 + rcx]
    test al, al
    jz .fd_chk_end
    cmp al, '-'
    je .fd_chk_ok
    cmp al, '.'
    je .fd_chk_ok
    cmp al, ':'
    je .fd_chk_ok
    call ash_is_name_char
    test edx, edx
    jz .fd_badname
.fd_chk_ok:
    inc ecx
    jmp .fd_chk
.fd_chk_end:
    test ecx, ecx
    jz .fd_badname
    cmp ecx, ASH_FUNC_NAME - 1
    ja .fd_namelong
    mov ebx, ecx                    ; name length
    cmp r14d, ASH_FUNC_SIZE - ASH_FUNC_NAME - 1
    jae .fd_long
    mov rdi, r12
    mov esi, ebx
    call ash_func_find
    test rax, rax
    jnz .fd_have
    mov eax, [ash_func_count]
    cmp eax, ASH_FUNC_MAX
    jae .fd_full
    inc dword [ash_func_count]
    imul eax, eax, ASH_FUNC_SIZE
    lea rcx, [ash_funcs]
    add rax, rcx
    mov rdi, rax
    mov rsi, r12
    xor ecx, ecx
.fd_name:
    mov dl, [rsi + rcx]
    mov [rdi + rcx], dl
    inc ecx
    test dl, dl
    jnz .fd_name
.fd_have:
    mov rbx, rax
    lea rdi, [rbx + ASH_FUNC_NAME]
    xor ecx, ecx
.fd_cp:
    cmp ecx, r14d
    jae .fd_cp_end
    mov al, [r13 + rcx]
    mov [rdi + rcx], al
    inc ecx
    jmp .fd_cp
.fd_cp_end:
    mov byte [rdi + rcx], 0
    jmp .fd_ret
.fd_full:
    lea rdi, [ash_e_func_full]
    jmp .fd_err
.fd_long:
    lea rdi, [ash_e_func_long]
    jmp .fd_err
.fd_namelong:
    lea rdi, [ash_e_func_name]
    jmp .fd_err
.fd_badname:
    lea rdi, [ash_e_func_bad]
.fd_err:
    call ash_write_err
    mov dword [last_exit_status], 1
.fd_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ash_call_func(rdi = table entry, rsi = argument text) -> eax = 0 ran, 1 not run
; Sets $1..$9, $# and $@ from the arguments, runs the body, then puts the
; caller's parameters back. The arguments live in the arena for the call.
ash_call_func:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40                     ; [rbp-48] caller's argv, [rbp-56] argc,
                                    ; [rbp-64] arena mark
    mov rbx, rdi
    mov r12, rsi
    mov rax, [ash_pos_argv]
    mov [rbp - 48], rax
    mov eax, [ash_pos_argc]
    mov [rbp - 56], rax
    mov rax, [ash_arena_used]
    mov [rbp - 64], rax

    ; Expand and split the arguments
    mov rdi, r12
    xor esi, esi
    call ash_load_line              ; "$@" becomes one word per parameter
    test eax, eax
    jnz .cf_expand_failed           ; too long: message printed
    call expand_env_vars
    test eax, eax
    jnz .cf_expand_failed           ; message printed: do not call
    lea rdi, [input_buf]
    call str_len
    mov r13d, eax                   ; length of the expanded arguments
    mov edi, r13d
    shr edi, 1
    add edi, 2
    shl edi, 3
    call ash_alloc                  ; argv[]: a word needs two bytes at least
    test rax, rax
    jz .cf_nomem
    mov r14, rax
    lea edi, [r13 + 2]
    call ash_alloc                  ; the words themselves
    test rax, rax
    jz .cf_nomem
    mov r15, rax
    lea r12, [input_buf]
    xor r13d, r13d                  ; argc
.cf_split:
    mov rdi, r12
    mov rsi, r15
    mov edx, 1
    call ash_next_word
    test rax, rax
    jz .cf_split_done
    mov r12, rax
    mov [r14 + r13 * 8], r15
    mov r15, rdx
    inc r13d
    jmp .cf_split
.cf_split_done:
    mov qword [r14 + r13 * 8], 0
    mov [ash_pos_argv], r14
    mov [ash_pos_argc], r13d
    call ash_pos_publish
    test eax, eax
    jnz .cf_noargs

    ; Run the body
    inc dword [ash_func_depth]
    lea rdi, [rbx + ASH_FUNC_NAME]
    mov esi, 1
    call ash_eval
    dec dword [ash_func_depth]
    jnz .cf_inner
    mov byte [ash_abort], 0         ; the outermost call ends a runaway recursion
.cf_inner:
    xor ebx, ebx
    jmp .cf_restore

.cf_expand_failed:
    mov ebx, 1
    jmp .cf_ret
.cf_nomem:
    lea rdi, [ash_e_toolong]
    call ash_write_err
    mov dword [last_exit_status], 2
    mov ebx, 1
    jmp .cf_restore
.cf_noargs:
    mov ebx, 1
.cf_restore:
    ; Restore the caller's parameters (keep the status)
    mov r14d, [last_exit_status]
    mov rax, [rbp - 48]
    mov [ash_pos_argv], rax
    mov eax, [rbp - 56]
    mov [ash_pos_argc], eax
    call ash_pos_publish
    mov [last_exit_status], r14d
    mov rax, [rbp - 64]
    mov [ash_arena_used], rax
.cf_ret:
    mov eax, ebx
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ash_pos_publish - copy ash_pos_argv / ash_pos_argc into the variables
; 1..9, # and @ that expand_env_vars reads. eax = 0 ok, 1 a value did not fit.
ash_pos_publish:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov r12, [ash_pos_argv]
    mov r13d, [ash_pos_argc]
    xor ebx, ebx
.pp_loop:
    lea rsi, [ash_s_empty]
    cmp ebx, r13d
    jae .pp_set
    mov rsi, [r12 + rbx * 8]
.pp_set:
    lea rax, [ash_pos_names]
    mov rdi, [rax + rbx * 8]
    call ash_setvar
    test eax, eax
    jnz .pp_ret
    inc ebx
    cmp ebx, 9
    jb .pp_loop
    lea rdi, [ash_num_buf]
    mov esi, r13d
    call ash_fmt_int
    lea rdi, [ash_pos_nhash]
    lea rsi, [ash_num_buf]
    call ash_setvar
    test eax, eax
    jnz .pp_ret

    ; $@ = the arguments joined by spaces, built in the arena
    mov r15, [ash_arena_used]
    xor ebx, ebx
    xor r14d, r14d
.pp_len:
    cmp ebx, r13d
    jae .pp_len_end
    mov rdi, [r12 + rbx * 8]
    call str_len
    lea r14d, [r14 + rax + 1]
    inc ebx
    jmp .pp_len
.pp_len_end:
    lea edi, [r14 + 1]
    call ash_alloc
    test rax, rax
    jz .pp_nomem
    mov r14, rax
    mov rdi, rax
    xor ebx, ebx
.pp_join:
    cmp ebx, r13d
    jae .pp_join_end
    test ebx, ebx
    jz .pp_word
    mov byte [rdi], ' '
    inc rdi
.pp_word:
    mov rsi, [r12 + rbx * 8]
.pp_cp:
    mov al, [rsi]
    test al, al
    jz .pp_next
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .pp_cp
.pp_next:
    inc ebx
    jmp .pp_join
.pp_join_end:
    mov byte [rdi], 0
    lea rdi, [ash_pos_nat]
    mov rsi, r14
    call ash_setvar
    mov [ash_arena_used], r15
    jmp .pp_ret
.pp_nomem:
    lea rdi, [ash_e_toolong]
    call ash_write_err
    mov dword [last_exit_status], 1
    mov eax, 1
.pp_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

section .data
    ash_e_func_name     db "ash: function name too long", 10, 0
    ash_e_func_bad      db "ash: invalid function name", 10, 0
section .bss
    alignb 8
    ash_pos_argv        resq 1              ; arguments of the running function
    ash_pos_argc        resd 1
    ash_func_depth      resd 1              ; > 0 while a function body runs
section .text

; ----------------------------------------------------------------------------
; Small helpers
; ----------------------------------------------------------------------------

; ash_is_name_char(al) -> edx = 1 for [A-Za-z0-9_]
ash_is_name_char:
    mov edx, 1
    cmp al, '_'
    je .inc_ret
    cmp al, '0'
    jb .inc_no
    cmp al, '9'
    jbe .inc_ret
    cmp al, 'A'
    jb .inc_no
    cmp al, 'Z'
    jbe .inc_ret
    cmp al, 'a'
    jb .inc_no
    cmp al, 'z'
    jbe .inc_ret
.inc_no:
    xor edx, edx
.inc_ret:
    ret

; ash_skip_blanks(rdi) -> rax = first char that is not ' ', TAB or LF
ash_skip_blanks:
    mov rax, rdi
.sb_loop:
    movzx ecx, byte [rax]
    cmp cl, ' '
    je .sb_next
    cmp cl, 9
    je .sb_next
    cmp cl, 10
    jne .sb_ret
.sb_next:
    inc rax
    jmp .sb_loop
.sb_ret:
    ret

; ash_word_is(rdi = text, rsi = word) -> eax = 1 if text starts with word
; followed by a blank, ';' or NUL
ash_word_is:
    xor ecx, ecx
.wi_loop:
    movzx eax, byte [rsi + rcx]
    test al, al
    jz .wi_end
    cmp al, [rdi + rcx]
    jne .wi_no
    inc ecx
    jmp .wi_loop
.wi_end:
    movzx eax, byte [rdi + rcx]
    test al, al
    jz .wi_yes
    cmp al, ' '
    je .wi_yes
    cmp al, 9
    je .wi_yes
    cmp al, 10
    je .wi_yes
    cmp al, ';'
    je .wi_yes
.wi_no:
    xor eax, eax
    ret
.wi_yes:
    mov eax, 1
    ret

; ash_strcmp(rdi, rsi) -> eax = 0 if equal (case-sensitive)
ash_strcmp:
.sc_loop:
    movzx eax, byte [rdi]
    movzx ecx, byte [rsi]
    cmp eax, ecx
    jne .sc_diff
    test eax, eax
    jz .sc_ret
    inc rdi
    inc rsi
    jmp .sc_loop
.sc_diff:
    mov eax, 1
.sc_ret:
    ret

; ash_next_word(rdi = src, rsi = dst, edx = split) -> rax = src after the
; word (0 if split and no word left), rdx = dst after its NUL.
; Removes quotes: '...' literal, "..." with \" \\ \$ \` escapes, \x.
; With split = 0 the whole string is one word.
ash_next_word:
    test edx, edx
    jz .nw_loop
.nw_skip:
    movzx eax, byte [rdi]
    cmp al, ' '
    je .nw_skip_one
    cmp al, 9
    je .nw_skip_one
    cmp al, 10
    je .nw_skip_one
    test al, al
    jnz .nw_loop
    mov byte [rsi], 0
    lea rdx, [rsi + 1]
    xor eax, eax
    ret
.nw_skip_one:
    inc rdi
    jmp .nw_skip
.nw_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .nw_end
    test edx, edx
    jz .nw_noblank
    cmp al, ' '
    je .nw_end
    cmp al, 9
    je .nw_end
    cmp al, 10
    je .nw_end
.nw_noblank:
    cmp al, EV_MARK
    je .nw_mark
    cmp al, 0x27
    je .nw_sq
    cmp al, '"'
    je .nw_dq
    cmp al, '\'
    je .nw_bs
.nw_store:
    mov [rsi], al
    inc rsi
    inc rdi
    jmp .nw_loop
.nw_mark:
    movzx ecx, byte [rdi + 1]       ; "EV_MARK c" is the plain character c
    test cl, cl
    jz .nw_end
    mov [rsi], cl
    inc rsi
    add rdi, 2
    jmp .nw_loop
.nw_bs:
    movzx ecx, byte [rdi + 1]
    test cl, cl
    jz .nw_store
    inc rdi
    mov [rsi], cl
    inc rsi
    inc rdi
    jmp .nw_loop
.nw_sq:
    inc rdi
.nw_sq_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .nw_end
    cmp al, EV_MARK
    jne .nw_sq_plain
    movzx ecx, byte [rdi + 1]
    test cl, cl
    jz .nw_end
    mov [rsi], cl
    inc rsi
    add rdi, 2
    jmp .nw_sq_loop
.nw_sq_plain:
    cmp al, 0x27
    je .nw_q_close
    mov [rsi], al
    inc rsi
    inc rdi
    jmp .nw_sq_loop
.nw_dq:
    inc rdi
.nw_dq_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .nw_end
    cmp al, EV_MARK
    jne .nw_dq_plain
    movzx ecx, byte [rdi + 1]
    test cl, cl
    jz .nw_end
    mov [rsi], cl
    inc rsi
    add rdi, 2
    jmp .nw_dq_loop
.nw_dq_plain:
    cmp al, '"'
    je .nw_q_close
    cmp al, '\'
    jne .nw_dq_store
    movzx ecx, byte [rdi + 1]
    cmp cl, '"'
    je .nw_dq_esc
    cmp cl, '\'
    je .nw_dq_esc
    cmp cl, '$'
    je .nw_dq_esc
    cmp cl, '`'
    jne .nw_dq_store
.nw_dq_esc:
    inc rdi
    mov al, cl
.nw_dq_store:
    mov [rsi], al
    inc rsi
    inc rdi
    jmp .nw_dq_loop
.nw_q_close:
    inc rdi
    jmp .nw_loop
.nw_end:
    mov byte [rsi], 0
    lea rdx, [rsi + 1]
    mov rax, rdi
    ret

; ash_syntax_err(rdi = text at the problem) - "ash: syntax error near 'x'"
ash_syntax_err:
    push rbx
    mov rbx, rdi
    lea rdi, [ash_e_syntax]
    call ash_write_err
    lea rdi, [ash_name_buf]
    xor ecx, ecx
.se_cp:
    cmp ecx, 32
    jae .se_cp_end
    movzx eax, byte [rbx + rcx]
    test al, al
    jz .se_cp_end
    cmp al, ' '
    je .se_cp_end
    cmp al, 9
    je .se_cp_end
    cmp al, 10
    je .se_cp_end
    cmp al, ';'
    je .se_cp_end
    mov [rdi + rcx], al
    inc ecx
    jmp .se_cp
.se_cp_end:
    mov byte [rdi + rcx], 0
    call ash_write_err
    lea rdi, [ash_e_syntax_end]
    call ash_write_err
    mov dword [last_exit_status], 2
    pop rbx
    ret

; ash_fmt_int(rdi = dst, rsi = signed value) -> rax = dst NUL position
ash_fmt_int:
    mov rax, rsi
    test rax, rax
    jns .fi_pos
    mov byte [rdi], '-'
    inc rdi
    neg rax
.fi_pos:
    lea r8, [ash_num_tmp + 31]
    mov byte [r8], 0
    mov ecx, 10
.fi_div:
    xor edx, edx
    div rcx
    add dl, '0'
    dec r8
    mov [r8], dl
    test rax, rax
    jnz .fi_div
.fi_cp:
    mov al, [r8]
    mov [rdi], al
    test al, al
    jz .fi_ret
    inc r8
    inc rdi
    jmp .fi_cp
.fi_ret:
    mov rax, rdi
    ret

; ash_parse_int(rdi = text) -> rax = value, edx = 1 ok / 0 not an integer
ash_parse_int:
    call ash_skip_blanks
    mov rdi, rax
    xor r8d, r8d                    ; negative?
    movzx ecx, byte [rdi]
    cmp cl, '-'
    jne .pi_plus
    mov r8d, 1
    inc rdi
    jmp .pi_digits
.pi_plus:
    cmp cl, '+'
    jne .pi_digits
    inc rdi
.pi_digits:
    xor eax, eax
    xor r9d, r9d                    ; digit count
.pi_loop:
    movzx ecx, byte [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja .pi_end
    imul rax, rax, 10
    jo .pi_bad                      ; does not fit 63 bits
    add rax, rcx
    jo .pi_bad
    inc rdi
    inc r9d
    jmp .pi_loop
.pi_end:
    test r9d, r9d
    jz .pi_bad
    test r8d, r8d
    jz .pi_tail
    neg rax
.pi_tail:
    movzx ecx, byte [rdi]
    cmp cl, ' '
    je .pi_tail_next
    cmp cl, 9
    je .pi_tail_next
    test cl, cl
    jnz .pi_bad
    mov edx, 1
    ret
.pi_tail_next:
    inc rdi
    jmp .pi_tail
.pi_bad:
    xor eax, eax
    xor edx, edx
    ret

; ============================================================================
; $(( )) arithmetic: + - * / % ( ) unary - + ! ~, << >>, < <= > >= == !=,
; & ^ |, && || (short-circuit), ?: and the literals 0x1F and 017.
; Names and $names read variables (unset or non-numeric = 0). Assignment
; operators and ++ -- are not supported.
; ============================================================================

; ash_arith(rdi = expression) -> rax = value, edx = 0 ok / 1 syntax / 2 div0
ash_arith:
    push rbx
    mov [ash_ar_p], rdi
    mov byte [ash_ar_err], 0
    mov byte [ash_ar_skip], 0
    call ar_ws
    cmp byte [rcx], 0
    jne .aa_expr
    xor ebx, ebx                    ; "$(( ))" is 0
    jmp .aa_ok
.aa_expr:
    call ar_expr
    mov rbx, rax
    call ar_ws
    cmp byte [rcx], 0
    je .aa_ok
    cmp byte [ash_ar_err], 0
    jne .aa_ok
    mov byte [ash_ar_err], 1
.aa_ok:
    movzx edx, byte [ash_ar_err]
    mov rax, rbx
    pop rbx
    ret

; ar_ws -> rcx = [ash_ar_p] after blanks
ar_ws:
    mov rcx, [ash_ar_p]
.aw_loop:
    cmp byte [rcx], ' '
    je .aw_next
    cmp byte [rcx], 9
    je .aw_next
    cmp byte [rcx], 10
    jne .aw_ret
.aw_next:
    inc rcx
    jmp .aw_loop
.aw_ret:
    mov [ash_ar_p], rcx
    ret

; ar_expr -> rax: a whole expression, C precedence from the top:
;   ?:   ||   &&   |   ^   &   == !=   < <= > >=   << >>   + -   * / %
; The right side of && || and the branch of ?: that is not taken are parsed
; with ash_ar_skip set, so they cannot raise an error (division by zero).
ar_expr:
ar_ternary:
    push rbx
    push r12
    push r13
    mov edi, 1
    call ar_bin
    mov rbx, rax
    call ar_ws
    cmp byte [rcx], '?'
    jne .at_ret
    inc rcx
    mov [ash_ar_p], rcx
    movzx r12d, byte [ash_ar_skip]
    test rbx, rbx
    jnz .at_then
    mov byte [ash_ar_skip], 1
.at_then:
    call ar_ternary
    mov r13, rax
    mov [ash_ar_skip], r12b
    call ar_ws
    cmp byte [rcx], ':'
    jne .at_err
    inc rcx
    mov [ash_ar_p], rcx
    test rbx, rbx
    jz .at_else
    mov byte [ash_ar_skip], 1
.at_else:
    call ar_ternary
    mov [ash_ar_skip], r12b
    test rbx, rbx
    cmovnz rax, r13
    mov rbx, rax
    jmp .at_ret
.at_err:
    cmp byte [ash_ar_err], 0
    jne .at_ret
    mov byte [ash_ar_err], 1
.at_ret:
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

; ar_bin(edi = lowest precedence to accept) -> rax
; Operator ids / precedences: || 1, && 2, | 3, ^ 4, & 5, == != 6,
; < <= > >= 7, << >> 8, + - 9, * / % 10.
AR_LOR equ 1
AR_LAND equ 2
AR_OR equ 3
AR_XOR equ 4
AR_AND equ 5
AR_EQ equ 6
AR_NE equ 7
AR_LT equ 8
AR_LE equ 9
AR_GT equ 10
AR_GE equ 11
AR_SHL equ 12
AR_SHR equ 13
AR_ADD equ 14
AR_SUB equ 15
AR_MUL equ 16
AR_DIV equ 17
AR_MOD equ 18

ar_bin:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    call ar_unary
    mov rbx, rax
.ab_loop:
    call ar_ws
    call ar_getop
    test eax, eax
    jz .ab_ret
    cmp r8d, r12d
    jb .ab_ret
    add rcx, rdx
    mov [ash_ar_p], rcx
    mov r13d, eax
    mov r15d, r8d
    movzx r14d, byte [ash_ar_skip]
    cmp r13d, AR_LOR
    jne .ab_not_lor
    test rbx, rbx
    jz .ab_rhs
    mov byte [ash_ar_skip], 1       ; the left side already decided
    jmp .ab_rhs
.ab_not_lor:
    cmp r13d, AR_LAND
    jne .ab_rhs
    test rbx, rbx
    jnz .ab_rhs
    mov byte [ash_ar_skip], 1
.ab_rhs:
    lea edi, [r15 + 1]
    call ar_bin
    mov [ash_ar_skip], r14b
    ; rbx = left, rax = right
    cmp r13d, AR_LOR
    je .ab_lor
    cmp r13d, AR_LAND
    je .ab_land
    cmp r13d, AR_OR
    je .ab_or
    cmp r13d, AR_XOR
    je .ab_xor
    cmp r13d, AR_AND
    je .ab_and
    cmp r13d, AR_ADD
    je .ab_add
    cmp r13d, AR_SUB
    je .ab_sub
    cmp r13d, AR_MUL
    je .ab_mul
    cmp r13d, AR_DIV
    jae .ab_div
    cmp r13d, AR_SHL
    je .ab_shl
    cmp r13d, AR_SHR
    je .ab_shr
%macro AR_SET 2                     ; operator id, condition
    cmp r13d, %1
    jne %%next
    cmp rbx, rax
    set%2 bl
    movzx ebx, bl
    jmp .ab_loop
%%next:
%endmacro
    AR_SET AR_EQ, e
    AR_SET AR_NE, ne
    AR_SET AR_LT, l
    AR_SET AR_LE, le
    AR_SET AR_GT, g
    AR_SET AR_GE, ge
    jmp .ab_loop                    ; not reached
.ab_lor:
    or rbx, rax
    setnz bl
    movzx ebx, bl
    jmp .ab_loop
.ab_land:
    test rbx, rbx
    setnz bl
    test rax, rax
    setnz al
    and bl, al
    movzx ebx, bl
    jmp .ab_loop
.ab_or:
    or rbx, rax
    jmp .ab_loop
.ab_xor:
    xor rbx, rax
    jmp .ab_loop
.ab_and:
    and rbx, rax
    jmp .ab_loop
.ab_add:
    add rbx, rax
    jmp .ab_loop
.ab_sub:
    sub rbx, rax
    jmp .ab_loop
.ab_mul:
    imul rbx, rax
    jmp .ab_loop
.ab_shl:
.ab_shr:
    mov ecx, eax                    ; the count is taken modulo 64, like the hardware
    cmp r13d, AR_SHL
    jne .ab_sar
    shl rbx, cl
    jmp .ab_loop
.ab_sar:
    sar rbx, cl
    jmp .ab_loop
.ab_div:
    test rax, rax
    jnz .ab_div_ok
    cmp byte [ash_ar_skip], 0
    jne .ab_div_skip
    cmp byte [ash_ar_err], 0
    jne .ab_div_skip
    mov byte [ash_ar_err], 2
.ab_div_skip:
    xor ebx, ebx
    jmp .ab_loop
.ab_div_ok:
    cmp rax, -1
    je .ab_div_neg1
    mov rcx, rax
    mov rax, rbx
    cqo
    idiv rcx
    cmp r13d, AR_MOD
    je .ab_mod_res
    mov rbx, rax
    jmp .ab_loop
.ab_mod_res:
    mov rbx, rdx
    jmp .ab_loop
.ab_div_neg1:                       ; INT64_MIN / -1 would trap
    cmp r13d, AR_MOD
    je .ab_mod_zero
    neg rbx
    jmp .ab_loop
.ab_mod_zero:
    xor ebx, ebx
    jmp .ab_loop
.ab_ret:
    mov rax, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ar_getop: rcx = text at an operator position
;   -> eax = operator id (0 = none), edx = its length, r8d = precedence
ar_getop:
    movzx eax, byte [rcx]
    movzx edx, byte [rcx + 1]
    cmp al, '|'
    je .go_bar
    cmp al, '&'
    je .go_amp
    cmp al, '^'
    je .go_xor
    cmp al, '='
    je .go_eq
    cmp al, '!'
    je .go_ne
    cmp al, '<'
    je .go_lt
    cmp al, '>'
    je .go_gt
    cmp al, '+'
    je .go_add
    cmp al, '-'
    je .go_sub
    cmp al, '*'
    je .go_mul
    cmp al, '/'
    je .go_div
    cmp al, '%'
    je .go_mod
.go_none:
    xor eax, eax
    ret
.go_bar:
    cmp dl, '|'
    jne .go_or1
    mov eax, AR_LOR
    mov edx, 2
    mov r8d, 1
    ret
.go_or1:
    mov eax, AR_OR
    mov r8d, 3
    jmp .go_len1
.go_amp:
    cmp dl, '&'
    jne .go_and1
    mov eax, AR_LAND
    mov edx, 2
    mov r8d, 2
    ret
.go_and1:
    mov eax, AR_AND
    mov r8d, 5
    jmp .go_len1
.go_xor:
    mov eax, AR_XOR
    mov r8d, 4
    jmp .go_len1
.go_eq:
    cmp dl, '='
    jne .go_none                    ; a lone = is an assignment: not supported
    mov eax, AR_EQ
    jmp .go_eq6
.go_ne:
    cmp dl, '='
    jne .go_none
    mov eax, AR_NE
.go_eq6:
    mov edx, 2
    mov r8d, 6
    ret
.go_lt:
    cmp dl, '<'
    je .go_shl
    mov r8d, 7
    cmp dl, '='
    je .go_le
    mov eax, AR_LT
    jmp .go_len1
.go_le:
    mov eax, AR_LE
    jmp .go_len2
.go_shl:
    mov eax, AR_SHL
    mov r8d, 8
    jmp .go_len2
.go_gt:
    cmp dl, '>'
    je .go_shr
    mov r8d, 7
    cmp dl, '='
    je .go_ge
    mov eax, AR_GT
    jmp .go_len1
.go_ge:
    mov eax, AR_GE
    jmp .go_len2
.go_shr:
    mov eax, AR_SHR
    mov r8d, 8
    jmp .go_len2
.go_add:
    mov eax, AR_ADD
    mov r8d, 9
    jmp .go_len1
.go_sub:
    mov eax, AR_SUB
    mov r8d, 9
    jmp .go_len1
.go_mul:
    mov eax, AR_MUL
    mov r8d, 10
    jmp .go_len1
.go_div:
    mov eax, AR_DIV
    mov r8d, 10
    jmp .go_len1
.go_mod:
    mov eax, AR_MOD
    mov r8d, 10
.go_len1:
    mov edx, 1
    ret
.go_len2:
    mov edx, 2
    ret

ar_unary:
    push rbx
    call ar_ws
    movzx eax, byte [rcx]
    cmp al, '-'
    je .au_neg
    cmp al, '+'
    je .au_plus
    cmp al, '~'
    je .au_not
    cmp al, '!'
    jne .au_primary
    cmp byte [rcx + 1], '='
    je .au_primary
    inc rcx
    mov [ash_ar_p], rcx
    call ar_unary
    test rax, rax
    sete al
    movzx eax, al
    pop rbx
    ret
.au_neg:
    inc rcx
    mov [ash_ar_p], rcx
    call ar_unary
    neg rax
    pop rbx
    ret
.au_plus:
    inc rcx
    mov [ash_ar_p], rcx
    call ar_unary
    pop rbx
    ret
.au_not:
    inc rcx
    mov [ash_ar_p], rcx
    call ar_unary
    not rax
    pop rbx
    ret
.au_primary:
    call ar_primary
    pop rbx
    ret

ar_primary:
    push rbx
    call ar_ws
    movzx eax, byte [rcx]
    cmp al, '('
    je .ap_paren
    cmp al, '$'
    je .ap_dollar
    cmp al, '0'
    jb .ap_name
    cmp al, '9'
    jbe .ap_num
.ap_name:
    call ash_is_name_char
    test edx, edx
    jz .ap_err
    lea rdi, [ash_ar_name]
    xor ebx, ebx
.ap_name_cp:
    movzx eax, byte [rcx]
    call ash_is_name_char
    test edx, edx
    jz .ap_name_end
    cmp ebx, 63
    jae .ap_err
    mov [rdi + rbx], al
    inc ebx
    inc rcx
    jmp .ap_name_cp
.ap_name_end:
    mov byte [rdi + rbx], 0
    mov [ash_ar_p], rcx
    call getenv_internal
    test rax, rax
    jz .ap_ret
    mov rdi, rax
    call ash_parse_int
    jmp .ap_ret
.ap_dollar:
    inc rcx
    mov [ash_ar_p], rcx
    cmp byte [rcx], '?'
    jne .ap_dollar_name
    inc rcx
    mov [ash_ar_p], rcx
    movsxd rax, dword [last_exit_status]
    jmp .ap_ret
.ap_dollar_name:
    movzx eax, byte [rcx]
    jmp .ap_name
.ap_num:
    xor eax, eax
    cmp byte [rcx], '0'
    jne .ap_num_loop
    movzx edx, byte [rcx + 1]
    or dl, 0x20
    cmp dl, 'x'
    je .ap_hex
.ap_oct:                            ; a leading 0 means octal
    movzx edx, byte [rcx]
    sub edx, '0'
    cmp edx, 9
    ja .ap_num_end
    cmp edx, 7
    ja .ap_err
    mov rsi, rax
    shr rsi, 60
    jnz .ap_err                     ; would not fit 63 bits
    shl rax, 3
    add rax, rdx
    inc rcx
    jmp .ap_oct
.ap_hex:
    add rcx, 2
    xor esi, esi                    ; digits seen
.ap_hex_loop:
    movzx edx, byte [rcx]
    cmp edx, '0'
    jb .ap_hex_end
    cmp edx, '9'
    jbe .ap_hex_dec
    or edx, 0x20
    cmp edx, 'a'
    jb .ap_hex_end
    cmp edx, 'f'
    ja .ap_hex_end
    sub edx, 'a' - 10
    jmp .ap_hex_add
.ap_hex_dec:
    sub edx, '0'
.ap_hex_add:
    mov rdi, rax
    shr rdi, 59
    jnz .ap_err
    shl rax, 4
    add rax, rdx
    inc esi
    inc rcx
    jmp .ap_hex_loop
.ap_hex_end:
    test esi, esi
    jz .ap_err
    jmp .ap_num_end
.ap_num_loop:
    movzx edx, byte [rcx]
    sub edx, '0'
    cmp edx, 9
    ja .ap_num_end
    imul rax, rax, 10
    jo .ap_err                      ; larger than 2^63 - 1
    add rax, rdx
    jo .ap_err
    inc rcx
    jmp .ap_num_loop
.ap_num_end:
    mov [ash_ar_p], rcx
    jmp .ap_ret
.ap_paren:
    inc rcx
    mov [ash_ar_p], rcx
    call ar_expr
    mov rbx, rax
    call ar_ws
    cmp byte [rcx], ')'
    jne .ap_err
    inc rcx
    mov [ash_ar_p], rcx
    mov rax, rbx
    jmp .ap_ret
.ap_err:
    cmp byte [ash_ar_err], 0
    jne .ap_err_set
    mov byte [ash_ar_err], 1
.ap_err_set:
    xor eax, eax
.ap_ret:
    pop rbx
    ret

; ash_expand_arith - called by expand_env_vars for "$((...))".
; rdi = text after "$((", -> rax = text after "))" or 0 if not closed;
; result string in ash_num_buf ("" on error, message printed).
ash_expand_arith:
    push rbx
    mov byte [ash_arith_failed], 0
    mov rcx, rdi
    xor r8d, r8d                    ; ( depth
.ea_scan:
    movzx eax, byte [rcx]
    test al, al
    jz .ea_open
    cmp al, '('
    je .ea_lp
    cmp al, ')'
    jne .ea_next
    test r8d, r8d
    jnz .ea_rp
    cmp byte [rcx + 1], ')'
    je .ea_found
    jmp .ea_open
.ea_lp:
    inc r8d
    jmp .ea_next
.ea_rp:
    dec r8d
.ea_next:
    inc rcx
    jmp .ea_scan
.ea_found:
    lea rbx, [rcx + 2]              ; resume point
    lea rsi, [ash_ar_buf]
    xor edx, edx
.ea_cp:
    cmp rdi, rcx
    jae .ea_cp_end
    cmp edx, 510
    jae .ea_long                    ; an expression cut short would compute something else
    mov al, [rdi]
    mov [rsi + rdx], al
    inc rdi
    inc edx
    jmp .ea_cp
.ea_cp_end:
    mov byte [rsi + rdx], 0
    lea rdi, [ash_ar_buf]
    call ash_arith
    test edx, edx
    jnz .ea_err
    lea rdi, [ash_num_buf]
    mov rsi, rax
    call ash_fmt_int
    mov rax, rbx
    pop rbx
    ret
.ea_err:
    mov byte [ash_arith_failed], 1
    mov byte [ash_num_buf], 0
    lea rdi, [ash_e_arith]
    cmp edx, 2
    jne .ea_err_msg
    lea rdi, [ash_e_divzero]
.ea_err_msg:
    call ash_write_err
    mov rax, rbx
    pop rbx
    ret
.ea_long:
    mov edx, 1
    jmp .ea_err
.ea_open:
    xor eax, eax
    pop rbx
    ret

; ============================================================================
; test EXPR  /  [ EXPR ]
;   -n S  -z S  S          S1 = S2  S1 == S2  S1 != S2
;   -e -f -d -s -r -w -x -L -h FILE
;   N1 -eq -ne -lt -le -gt -ge N2       ! EXPR
; Status: 0 true, 1 false, 2 usage error.
; ============================================================================
handler_bracket:
    mov esi, 1
    jmp ash_test_main
handler_test:
    xor esi, esi
ash_test_main:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov r13d, esi                   ; 1 = "[" form
    xor ebx, ebx                    ; argc
    test rdi, rdi
    jz .tm_parsed
    mov r12, rdi
    lea r14, [ash_test_buf]
.tm_split:
    cmp ebx, 31
    jae .tm_full
    mov rdi, r12
    mov rsi, r14
    mov edx, 1
    call ash_next_word
    test rax, rax
    jz .tm_parsed
    mov r12, rax
    lea rax, [ash_test_argv]
    mov [rax + rbx * 8], r14
    mov r14, rdx
    inc ebx
    jmp .tm_split
.tm_full:                           ; room for 31 words: a 32nd is an error
    mov rdi, r12
    mov rsi, r14
    mov edx, 1
    call ash_next_word
    test rax, rax
    jz .tm_parsed
    lea rdi, [ash_e_test_args]
    call ash_write_err
    mov dword [last_exit_status], 2
    jmp .tm_ret
.tm_parsed:
    test r13d, r13d
    jz .tm_eval
    test ebx, ebx
    jz .tm_missing
    lea rax, [ash_test_argv]
    mov rdi, [rax + rbx * 8 - 8]
    lea rsi, [ash_s_rbracket]
    call ash_strcmp
    test eax, eax
    jnz .tm_missing
    dec ebx
.tm_eval:
    mov edi, ebx
    call ash_test_eval
    mov [last_exit_status], eax
    jmp .tm_ret
.tm_missing:
    lea rdi, [ash_e_bracket]
    call ash_write_err
    mov dword [last_exit_status], 2
.tm_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ash_test_eval(edi = argc; words in ash_test_argv) -> eax 0/1/2
ash_test_eval:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov ebx, edi
    lea r12, [ash_test_argv]
    xor r13d, r13d                  ; negate
    cmp ebx, 5
    jae .te_rd
    cmp ebx, 2
    jb .te_go
    mov rdi, [r12]
    lea rsi, [ash_s_bang]
    call ash_strcmp
    test eax, eax
    jnz .te_go
    mov r13d, 1
    add r12, 8
    dec ebx
.te_go:
    cmp ebx, 0
    je .te_false
    cmp ebx, 1
    je .te_one
    cmp ebx, 2
    je .te_two
    cmp ebx, 3
    je .te_three
.te_rd:
    ; four or more words: the full grammar with -a -o ! ( )
    mov dword [ash_t_pos], 0
    mov [ash_t_end], ebx
    call ash_t_or
    mov r13d, eax
    mov eax, [ash_t_pos]
    cmp eax, [ash_t_end]
    je .te_rd_done
    cmp r13d, 2                     ; leftover words: the expression is malformed
    je .te_rd_done
    lea rdi, [ash_e_test_expr]
    call ash_write_err
    mov r13d, 2
.te_rd_done:
    mov eax, r13d
    jmp .te_ret
.te_one:
    mov rax, [r12]
    cmp byte [rax], 0
    je .te_false
    jmp .te_true
.te_two:
    mov rdi, [r12]
    mov rsi, [r12 + 8]
    call ash_test_unary
    jmp .te_result
.te_three:
    mov rdi, [r12 + 8]
    call ash_test_isbin
    test eax, eax
    jnz .te_bin
    mov rdi, [r12]
    lea rsi, [ash_s_lp]
    call ash_strcmp
    test eax, eax
    jnz .te_bin
    mov rdi, [r12 + 16]
    lea rsi, [ash_s_rp]
    call ash_strcmp
    test eax, eax
    jnz .te_bin
    add r12, 8                      ; ( word ): the word alone
    jmp .te_one
.te_bin:
    mov rdi, [r12]
    mov rsi, [r12 + 8]
    mov rdx, [r12 + 16]
    call ash_test_binary
    jmp .te_result
.te_true:
    xor eax, eax
    jmp .te_result
.te_false:
    mov eax, 1
.te_result:
    cmp eax, 2
    je .te_ret
    xor eax, r13d
.te_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

section .data
    ash_s_lp            db "(", 0
    ash_s_rp            db ")", 0
    ash_s_dasha         db "-a", 0
    ash_s_dasho         db "-o", 0
    ash_e_test_expr     db "test: syntax error", 10, 0
    ash_e_test_miss     db "test: argument expected", 10, 0
section .bss
    ash_t_pos           resd 1
    ash_t_end           resd 1
section .text

; The grammar for four words and more. Each routine returns the test status
; in eax (0 true, 1 false, 2 error) and moves ash_t_pos over what it used.
;   or   := and { -o and }        and := not { -a not }
;   not  := ! not | primary
;   primary := ( or ) | WORD OP WORD | -X WORD | WORD
ash_t_or:
    push rbx
    call ash_t_and
    mov ebx, eax
.to_loop:
    mov eax, [ash_t_pos]
    cmp eax, [ash_t_end]
    jae .to_ret
    lea rdx, [ash_test_argv]
    mov rdi, [rdx + rax * 8]
    lea rsi, [ash_s_dasho]
    call ash_strcmp
    test eax, eax
    jnz .to_ret
    inc dword [ash_t_pos]
    call ash_t_and
    cmp ebx, 2
    je .to_loop
    cmp eax, 2
    jne .to_comb
    mov ebx, 2
    jmp .to_loop
.to_comb:
    and ebx, eax                    ; true (0) on either side wins
    jmp .to_loop
.to_ret:
    mov eax, ebx
    pop rbx
    ret

ash_t_and:
    push rbx
    call ash_t_not
    mov ebx, eax
.ta_loop:
    mov eax, [ash_t_pos]
    cmp eax, [ash_t_end]
    jae .ta_ret
    lea rdx, [ash_test_argv]
    mov rdi, [rdx + rax * 8]
    lea rsi, [ash_s_dasha]
    call ash_strcmp
    test eax, eax
    jnz .ta_ret
    inc dword [ash_t_pos]
    call ash_t_not
    cmp ebx, 2
    je .ta_loop
    cmp eax, 2
    jne .ta_comb
    mov ebx, 2
    jmp .ta_loop
.ta_comb:
    or ebx, eax                     ; both must be true (0)
    jmp .ta_loop
.ta_ret:
    mov eax, ebx
    pop rbx
    ret

ash_t_not:
    mov eax, [ash_t_pos]
    lea ecx, [rax + 1]
    cmp ecx, [ash_t_end]
    jae ash_t_primary               ; "!" with nothing after it is a word
    lea rdx, [ash_test_argv]
    mov rdi, [rdx + rax * 8]
    cmp byte [rdi], '!'
    jne ash_t_primary
    cmp byte [rdi + 1], 0
    jne ash_t_primary
    mov [ash_t_pos], ecx
    sub rsp, 8
    call ash_t_not
    add rsp, 8
    cmp eax, 2
    je .tn_ret
    xor eax, 1
.tn_ret:
    ret

ash_t_primary:
    push rbx
    push r12
    push r13
    mov ebx, [ash_t_pos]
    mov r12d, [ash_t_end]
    cmp ebx, r12d
    jae .tp_missing
    lea r13, [ash_test_argv]
    mov rdi, [r13 + rbx * 8]
    lea rsi, [ash_s_lp]
    call ash_strcmp
    test eax, eax
    jnz .tp_plain
    inc ebx
    mov [ash_t_pos], ebx
    call ash_t_or
    mov ebx, eax
    cmp ebx, 2
    je .tp_done
    mov eax, [ash_t_pos]
    cmp eax, [ash_t_end]
    jae .tp_missing
    mov rdi, [r13 + rax * 8]
    lea rsi, [ash_s_rp]
    call ash_strcmp
    test eax, eax
    jnz .tp_missing
    inc dword [ash_t_pos]
.tp_done:
    mov eax, ebx
    jmp .tp_ret
.tp_plain:
    mov eax, r12d
    sub eax, ebx                    ; words left
    cmp eax, 3
    jb .tp_unary
    mov rdi, [r13 + rbx * 8 + 8]
    call ash_test_isbin
    test eax, eax
    jz .tp_unary
    mov rdi, [r13 + rbx * 8]
    mov rsi, [r13 + rbx * 8 + 8]
    mov rdx, [r13 + rbx * 8 + 16]
    add dword [ash_t_pos], 3
    call ash_test_binary
    jmp .tp_ret
.tp_unary:
    mov eax, r12d
    sub eax, ebx
    cmp eax, 2
    jb .tp_str
    mov rdi, [r13 + rbx * 8]
    call ash_test_isun
    test eax, eax
    jz .tp_str
    mov rdi, [r13 + rbx * 8]
    mov rsi, [r13 + rbx * 8 + 8]
    add dword [ash_t_pos], 2
    call ash_test_unary
    jmp .tp_ret
.tp_str:
    inc dword [ash_t_pos]
    mov rax, [r13 + rbx * 8]
    cmp byte [rax], 0
    sete al
    movzx eax, al                   ; a non-empty word is true (0)
    jmp .tp_ret
.tp_missing:
    lea rdi, [ash_e_test_miss]
    call ash_write_err
    mov eax, 2
.tp_ret:
    pop r13
    pop r12
    pop rbx
    ret

; ash_test_isbin(rdi = word) -> eax = 1 for = == != -eq -ne -lt -le -gt -ge
ash_test_isbin:
    movzx eax, byte [rdi]
    cmp al, '='
    je .ib_eq
    cmp al, '!'
    je .ib_ne
    cmp al, '-'
    jne .ib_no
    cmp byte [rdi + 3], 0
    jne .ib_no
    movzx eax, word [rdi + 1]
    cmp ax, 'eq'
    je .ib_yes
    cmp ax, 'ne'
    je .ib_yes
    cmp ax, 'lt'
    je .ib_yes
    cmp ax, 'le'
    je .ib_yes
    cmp ax, 'gt'
    je .ib_yes
    cmp ax, 'ge'
    je .ib_yes
.ib_no:
    xor eax, eax
    ret
.ib_eq:
    cmp byte [rdi + 1], 0
    je .ib_yes
    cmp word [rdi + 1], '='
    je .ib_yes
    jmp .ib_no
.ib_ne:
    cmp word [rdi + 1], '='
    jne .ib_no
.ib_yes:
    mov eax, 1
    ret

; ash_test_isun(rdi = word) -> eax = 1 for -n -z -r -w -x -L -h -e -f -d -s
ash_test_isun:
    cmp byte [rdi], '-'
    jne .iu_no
    cmp byte [rdi + 2], 0
    jne .iu_no
    movzx eax, byte [rdi + 1]
    lea rcx, [ash_test_unops]
.iu_loop:
    cmp byte [rcx], 0
    je .iu_no
    cmp al, [rcx]
    je .iu_yes
    inc rcx
    jmp .iu_loop
.iu_yes:
    mov eax, 1
    ret
.iu_no:
    xor eax, eax
    ret

section .data
    ash_test_unops      db "nzrwxLhefds", 0
section .text

; ash_test_unary(rdi = op, rsi = arg) -> eax 0/1/2
ash_test_unary:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov rbx, rsi
    cmp byte [rdi], '-'
    jne .tu_bad
    cmp byte [rdi + 2], 0
    jne .tu_bad
    movzx r12d, byte [rdi + 1]
    cmp r12b, 'n'
    je .tu_n
    cmp r12b, 'z'
    je .tu_z
    cmp r12b, 'r'
    je .tu_r
    cmp r12b, 'w'
    je .tu_w
    cmp r12b, 'x'
    je .tu_x
    cmp r12b, 'L'
    je .tu_lstat
    cmp r12b, 'h'
    je .tu_lstat
    cmp r12b, 'e'
    je .tu_stat
    cmp r12b, 'f'
    je .tu_stat
    cmp r12b, 'd'
    je .tu_stat
    cmp r12b, 's'
    je .tu_stat
.tu_bad:
    lea rdi, [ash_e_test_op]
    call ash_write_err
    mov eax, 2
    jmp .tu_ret
.tu_n:
    cmp byte [rbx], 0
    jne .tu_true
    jmp .tu_false
.tu_z:
    cmp byte [rbx], 0
    je .tu_true
    jmp .tu_false
.tu_r:
    mov esi, 4
    jmp .tu_access
.tu_w:
    mov esi, 2
    jmp .tu_access
.tu_x:
    mov esi, 1
.tu_access:
    mov rdi, rbx
    mov eax, ASH_SYS_ACCESS
    syscall
    test rax, rax
    jz .tu_true
    jmp .tu_false
.tu_lstat:
    mov rdi, rbx
    lea rsi, [stat_buf]
    mov eax, ASH_SYS_LSTAT
    syscall
    test rax, rax
    jnz .tu_false
    mov eax, [stat_buf + STAT_ST_MODE]
    and eax, ASH_S_IFMT
    cmp eax, ASH_S_IFLNK
    je .tu_true
    jmp .tu_false
.tu_stat:
    mov rdi, rbx
    lea rsi, [stat_buf]
    mov eax, SYS_STAT
    syscall
    test rax, rax
    jnz .tu_false
    cmp r12b, 'e'
    je .tu_true
    cmp r12b, 's'
    je .tu_size
    mov eax, [stat_buf + STAT_ST_MODE]
    and eax, ASH_S_IFMT
    cmp r12b, 'd'
    je .tu_dir
    cmp eax, ASH_S_IFREG
    je .tu_true
    jmp .tu_false
.tu_dir:
    cmp eax, ASH_S_IFDIR
    je .tu_true
    jmp .tu_false
.tu_size:
    cmp qword [stat_buf + STAT_ST_SIZE], 0
    jg .tu_true
.tu_false:
    mov eax, 1
    jmp .tu_ret
.tu_true:
    xor eax, eax
.tu_ret:
    pop r12
    pop rbx
    pop rbp
    ret

; ash_test_binary(rdi = a, rsi = op, rdx = b) -> eax 0/1/2
ash_test_binary:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, r12
    lea rsi, [ash_s_dasha]
    call ash_strcmp
    test eax, eax
    jz .tb_and
    mov rdi, r12
    lea rsi, [ash_s_dasho]
    call ash_strcmp
    test eax, eax
    jz .tb_or
    mov rdi, r12
    lea rsi, [ash_s_eq1]
    call ash_strcmp
    test eax, eax
    jz .tb_streq
    mov rdi, r12
    lea rsi, [ash_s_eq2]
    call ash_strcmp
    test eax, eax
    jz .tb_streq
    mov rdi, r12
    lea rsi, [ash_s_neq]
    call ash_strcmp
    test eax, eax
    jz .tb_strne

    ; -eq -ne -lt -le -gt -ge
    cmp byte [r12], '-'
    jne .tb_bad
    cmp byte [r12 + 3], 0
    jne .tb_bad
    movzx r14d, word [r12 + 1]
    cmp r14w, 'eq'
    je .tb_int
    cmp r14w, 'ne'
    je .tb_int
    cmp r14w, 'lt'
    je .tb_int
    cmp r14w, 'le'
    je .tb_int
    cmp r14w, 'gt'
    je .tb_int
    cmp r14w, 'ge'
    jne .tb_bad
.tb_int:
    mov rdi, rbx
    call ash_parse_int
    test edx, edx
    jz .tb_notint
    mov rbx, rax
    mov rdi, r13
    call ash_parse_int
    test edx, edx
    jz .tb_notint
    cmp rbx, rax
    cmp r14w, 'eq'
    je .tb_eq
    cmp r14w, 'ne'
    je .tb_ne
    cmp r14w, 'lt'
    je .tb_lt
    cmp r14w, 'le'
    je .tb_le
    cmp r14w, 'gt'
    je .tb_gt
    ; ge
    cmp rbx, rax
    jge .tb_true
    jmp .tb_false
.tb_eq:
    cmp rbx, rax
    je .tb_true
    jmp .tb_false
.tb_ne:
    cmp rbx, rax
    jne .tb_true
    jmp .tb_false
.tb_lt:
    cmp rbx, rax
    jl .tb_true
    jmp .tb_false
.tb_le:
    cmp rbx, rax
    jle .tb_true
    jmp .tb_false
.tb_gt:
    cmp rbx, rax
    jg .tb_true
    jmp .tb_false

.tb_streq:
    mov rdi, rbx
    mov rsi, r13
    call ash_strcmp
    test eax, eax
    jz .tb_true
    jmp .tb_false
.tb_strne:
    mov rdi, rbx
    mov rsi, r13
    call ash_strcmp
    test eax, eax
    jnz .tb_true
    jmp .tb_false
.tb_and:                            ; three words "a -a b": both non-empty
    cmp byte [rbx], 0
    je .tb_false
    cmp byte [r13], 0
    je .tb_false
    jmp .tb_true
.tb_or:
    cmp byte [rbx], 0
    jne .tb_true
    cmp byte [r13], 0
    jne .tb_true
    jmp .tb_false
.tb_notint:
    lea rdi, [ash_e_test_int]
    call ash_write_err
    mov eax, 2
    jmp .tb_ret
.tb_bad:
    lea rdi, [ash_e_test_op]
    call ash_write_err
    mov eax, 2
    jmp .tb_ret
.tb_true:
    xor eax, eax
    jmp .tb_ret
.tb_false:
    mov eax, 1
.tb_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
