; ============================================================================
; ASH - Assembly Shell, milestone 1: native command executor
;
; Runs simple commands and pipelines without /bin/sh:
;   - words with 'single' and "double" quotes and \ escapes
;   - pipelines: cmd1 | cmd2 | ... (up to ASH_MAX_STAGES)
;   - per-stage redirections: < file, > file, >> file, 2> file, 2>> file, 2>&1
;   - PATH lookup done here, then fork + execve straight into the program
;
; Anything this parser does not understand yet (globs, $(...), backticks,
; here-docs, subshells, keywords like if/for/while, VAR=value prefixes,
; ~ expansion, '&') makes ash_parse return 0. The caller then falls back
; to the old /bin/sh -c path, so nothing that worked before breaks.
;
; Included from terminal_linux.asm (Linux x86-64, System V ABI).
; ============================================================================

%define SYS_PIPE2           293
%define O_CLOEXEC           0x80000
%define ENOEXEC             8
%define EACCES              13
%define EINTR               4

%define ASH_MAX_STAGES      16
%define ASH_MAX_ARGS        256         ; argv slots for all stages, NULLs included
%define ASH_POOL_SIZE       4096        ; unquoted word text

; One record per pipeline stage
%define STG_ARGV            0           ; qword: pointer into ash_argv
%define STG_IN              8           ; qword: '<' file name or 0
%define STG_OUT             16          ; qword: '>' / '>>' file name or 0
%define STG_ERR             24          ; qword: '2>' / '2>>' file name or 0
%define STG_FLAGS           32          ; dword: STGF_*
%define STG_ARGC            36          ; dword
%define STG_PID             40          ; qword
%define STG_SIZE            48

%define STGF_OUT_APPEND     1
%define STGF_ERR_APPEND     2
%define STGF_ERR_TO_OUT     4

; Redirection kinds while parsing
%define RK_IN               1
%define RK_OUT              2
%define RK_OUT_APP          3
%define RK_ERR              4
%define RK_ERR_APP          5

; read_word result flags (ecx)
%define RW_GLOB             1           ; unquoted * ? [
%define RW_EQUALS           2           ; unquoted =
%define RW_CONSUMED         4           ; at least one char or quote read

section .data
    ash_s_path          db "PATH", 0
    ash_default_path    db "/usr/local/bin:/usr/bin:/bin", 0
    ash_msg_prefix      db "ash: ", 0
    ash_msg_notfound    db ": command not found", 10, 0
    ash_msg_denied      db ": permission denied", 10, 0
    ash_msg_noopen      db ": cannot open file", 10, 0
    ash_msg_pipe        db "ash: pipe failed", 10, 0
    ash_msg_fork        db "ash: fork failed", 10, 0
    ; Words that start shell syntax ASH does not run yet (NUL-separated list)
    ash_keywords        db "if", 0, "then", 0, "else", 0, "elif", 0, "fi", 0
                        db "for", 0, "while", 0, "until", 0, "do", 0, "done", 0
                        db "case", 0, "esac", 0, "function", 0, "select", 0
                        db "time", 0, "!", 0, "{", 0, "}", 0, "[[", 0, "]]", 0
                        db 0

section .bss
    ash_stages          resb ASH_MAX_STAGES * STG_SIZE
    ash_argv            resq ASH_MAX_ARGS
    ash_pool            resb ASH_POOL_SIZE
    ash_pipes           resd ASH_MAX_STAGES * 2
    ash_nstages         resd 1
    ash_exec_path       resb MAX_PATH_BUF
    ash_sh_argv         resq ASH_MAX_ARGS + 2

section .text

; ----------------------------------------------------------------------------
; ash_parse(rdi = command line) -> eax = number of stages, 0 = not supported
; Fills ash_stages / ash_argv / ash_pool. Does not modify the input.
; ----------------------------------------------------------------------------
ash_parse:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov r12, rdi                    ; r12 = source cursor
    lea r13, [ash_pool]             ; r13 = pool write cursor
    lea r14, [ash_argv]             ; r14 = argv write cursor
    xor ebx, ebx                    ; ebx = finished stages

.ap_new_stage:
    cmp ebx, ASH_MAX_STAGES
    jae .ap_fail
    imul eax, ebx, STG_SIZE
    lea r15, [ash_stages + rax]     ; r15 = current stage
    mov [r15 + STG_ARGV], r14
    xor eax, eax
    mov [r15 + STG_IN], rax
    mov [r15 + STG_OUT], rax
    mov [r15 + STG_ERR], rax
    mov [r15 + STG_FLAGS], eax
    mov [r15 + STG_ARGC], eax
    mov [r15 + STG_PID], rax

.ap_next:
    movzx eax, byte [r12]
    test al, al
    jz .ap_end
    cmp al, ' '
    je .ap_skip
    cmp al, 9
    je .ap_skip
    cmp al, '|'
    je .ap_pipe
    cmp al, '<'
    je .ap_lt
    cmp al, '>'
    je .ap_gt
    cmp al, '2'
    jne .ap_word
    cmp byte [r12 + 1], '>'
    jne .ap_word

    ; "2>..." at the start of a word
    cmp byte [r12 + 2], '&'
    jne .ap_err_file
    cmp byte [r12 + 3], '1'
    jne .ap_fail
    movzx eax, byte [r12 + 4]       ; "2>&1" must end the word
    test al, al
    jz .ap_err_to_out
    cmp al, ' '
    je .ap_err_to_out
    cmp al, 9
    je .ap_err_to_out
    cmp al, '|'
    jne .ap_fail
.ap_err_to_out:
    mov eax, [r15 + STG_FLAGS]
    and eax, ~STGF_ERR_APPEND
    or eax, STGF_ERR_TO_OUT
    mov [r15 + STG_FLAGS], eax
    mov qword [r15 + STG_ERR], 0
    add r12, 4
    jmp .ap_next

.ap_err_file:
    cmp byte [r12 + 2], '>'
    je .ap_err_app
    add r12, 2
    mov edx, RK_ERR
    jmp .ap_redir
.ap_err_app:
    add r12, 3
    mov edx, RK_ERR_APP
    jmp .ap_redir

.ap_skip:
    inc r12
    jmp .ap_next

.ap_lt:
    cmp byte [r12 + 1], '<'         ; here-doc: not yet
    je .ap_fail
    inc r12
    mov edx, RK_IN
    jmp .ap_redir

.ap_gt:
    cmp byte [r12 + 1], '>'
    je .ap_gt_app
    inc r12
    mov edx, RK_OUT
    jmp .ap_redir
.ap_gt_app:
    add r12, 2
    mov edx, RK_OUT_APP

.ap_redir:
    ; '>&', '>|', '<>', '>>>' and friends: leave to /bin/sh
    movzx eax, byte [r12]
    cmp al, '&'
    je .ap_fail
    cmp al, '|'
    je .ap_fail
    cmp al, '<'
    je .ap_fail
    cmp al, '>'
    je .ap_fail
.ap_redir_skip:
    movzx eax, byte [r12]
    cmp al, ' '
    je .ap_redir_blank
    cmp al, 9
    jne .ap_redir_word
.ap_redir_blank:
    inc r12
    jmp .ap_redir_skip
.ap_redir_word:
    mov [rsp], edx                  ; keep the kind across read_word
    call .read_word
    test rax, rax
    jz .ap_fail
    test ecx, RW_CONSUMED           ; no file name given
    jz .ap_fail
    test ecx, RW_GLOB               ; globbed file name: not yet
    jnz .ap_fail
    mov edx, [rsp]
    cmp edx, RK_IN
    je .ap_set_in
    cmp edx, RK_ERR
    jae .ap_set_err

    mov [r15 + STG_OUT], rax
    and dword [r15 + STG_FLAGS], ~STGF_OUT_APPEND
    cmp edx, RK_OUT_APP
    jne .ap_next
    or dword [r15 + STG_FLAGS], STGF_OUT_APPEND
    jmp .ap_next

.ap_set_in:
    mov [r15 + STG_IN], rax
    jmp .ap_next

.ap_set_err:
    mov [r15 + STG_ERR], rax
    and dword [r15 + STG_FLAGS], ~(STGF_ERR_APPEND | STGF_ERR_TO_OUT)
    cmp edx, RK_ERR_APP
    jne .ap_next
    or dword [r15 + STG_FLAGS], STGF_ERR_APPEND
    jmp .ap_next

.ap_word:
    call .read_word
    test rax, rax
    jz .ap_fail
    test ecx, RW_CONSUMED           ; stopped on & ; ( ) ` right away
    jz .ap_fail
    test ecx, RW_GLOB
    jnz .ap_fail
    cmp dword [r15 + STG_ARGC], 0
    jne .ap_store
    ; Command word: VAR=value prefixes and keywords go to /bin/sh for now
    test ecx, RW_EQUALS
    jnz .ap_fail
    mov [rsp], rax
    mov rdi, rax
    call .is_keyword
    test eax, eax
    jnz .ap_fail
    mov rax, [rsp]
.ap_store:
    lea rdx, [ash_argv + (ASH_MAX_ARGS - 1) * 8]
    cmp r14, rdx                    ; keep one slot for the NULL
    jae .ap_fail
    mov [r14], rax
    add r14, 8
    inc dword [r15 + STG_ARGC]
    jmp .ap_next

.ap_pipe:
    cmp byte [r12 + 1], '|'         ; '||' should already be split off
    je .ap_fail
    cmp byte [r12 + 1], '&'         ; '|&'
    je .ap_fail
    inc r12
    call .close_stage
    test eax, eax
    jz .ap_fail
    jmp .ap_new_stage

.ap_end:
    call .close_stage
    test eax, eax
    jz .ap_fail
    mov eax, ebx
    jmp .ap_ret

.ap_fail:
    xor eax, eax
.ap_ret:
    mov [ash_nstages], eax
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; Finish the current stage: NULL-terminate its argv. eax = 1 ok, 0 empty stage.
.close_stage:
    xor eax, eax
    cmp dword [r15 + STG_ARGC], 0
    je .cs_ret
    mov qword [r14], 0
    add r14, 8
    inc ebx
    mov eax, 1
.cs_ret:
    ret

; Read one word at r12 into the pool at r13, removing quotes and escapes.
; Out: rax = word start (0 = unsupported or overflow), ecx = RW_* flags.
.read_word:
    mov rax, r13
    xor ecx, ecx
    lea r8, [ash_pool + ASH_POOL_SIZE - 1]
.rw_loop:
    movzx edx, byte [r12]
    test dl, dl
    jz .rw_end
    cmp dl, ' '
    je .rw_end
    cmp dl, 9
    je .rw_end
    cmp dl, '|'
    je .rw_end
    cmp dl, '<'
    je .rw_end
    cmp dl, '>'
    je .rw_end
    cmp dl, '&'
    je .rw_end
    cmp dl, ';'
    je .rw_end
    cmp dl, '('
    je .rw_end
    cmp dl, ')'
    je .rw_end
    cmp dl, '`'
    je .rw_end
    cmp dl, '$'                     ; $(...), $?, $$ ... left after expansion
    je .rw_fail
    cmp dl, '\'
    je .rw_backslash
    cmp dl, 0x27                    ; single quote
    je .rw_squote
    cmp dl, '"'
    je .rw_dquote
    cmp dl, '~'
    jne .rw_not_tilde
    test ecx, RW_CONSUMED           ; leading ~ needs expansion: not yet
    jz .rw_fail
.rw_not_tilde:
    cmp dl, '*'
    je .rw_glob
    cmp dl, '?'
    je .rw_glob
    cmp dl, '['
    je .rw_glob
    cmp dl, '='
    jne .rw_emit
    or ecx, RW_EQUALS
    jmp .rw_emit
.rw_glob:
    or ecx, RW_GLOB
.rw_emit:
    cmp r13, r8
    jae .rw_fail
    mov [r13], dl
    inc r13
    inc r12
    or ecx, RW_CONSUMED
    jmp .rw_loop

.rw_backslash:
    movzx edx, byte [r12 + 1]
    test dl, dl
    jz .rw_fail
    inc r12
    jmp .rw_emit

.rw_squote:
    inc r12
    or ecx, RW_CONSUMED
.rw_sq_loop:
    movzx edx, byte [r12]
    test dl, dl
    jz .rw_fail                     ; unterminated quote
    cmp dl, 0x27
    je .rw_sq_end
    cmp r13, r8
    jae .rw_fail
    mov [r13], dl
    inc r13
    inc r12
    jmp .rw_sq_loop
.rw_sq_end:
    inc r12
    jmp .rw_loop

.rw_dquote:
    inc r12
    or ecx, RW_CONSUMED
.rw_dq_loop:
    movzx edx, byte [r12]
    test dl, dl
    jz .rw_fail                     ; unterminated quote
    cmp dl, '"'
    je .rw_dq_end
    cmp dl, '$'
    je .rw_fail
    cmp dl, '`'
    je .rw_fail
    cmp dl, '\'
    jne .rw_dq_put
    movzx edx, byte [r12 + 1]       ; \" \\ \$ \` are escapes inside "..."
    cmp dl, '"'
    je .rw_dq_escape
    cmp dl, '\'
    je .rw_dq_escape
    cmp dl, '$'
    je .rw_dq_escape
    cmp dl, '`'
    je .rw_dq_escape
    mov dl, '\'                     ; any other \x stays as is
    jmp .rw_dq_put
.rw_dq_escape:
    inc r12
.rw_dq_put:
    cmp r13, r8
    jae .rw_fail
    mov [r13], dl
    inc r13
    inc r12
    jmp .rw_dq_loop
.rw_dq_end:
    inc r12
    jmp .rw_loop

.rw_end:
    mov byte [r13], 0               ; r13 <= r8, so this fits
    inc r13
    ret
.rw_fail:
    xor eax, eax
    ret

; rdi = word. eax = 1 if it is in ash_keywords.
.is_keyword:
    lea rsi, [ash_keywords]
.ik_next:
    cmp byte [rsi], 0
    je .ik_no
    xor ecx, ecx
.ik_cmp:
    mov dl, [rsi + rcx]
    cmp dl, [rdi + rcx]
    jne .ik_skip
    test dl, dl
    jz .ik_yes
    inc ecx
    jmp .ik_cmp
.ik_skip:
    cmp byte [rsi], 0
    je .ik_skipped
    inc rsi
    jmp .ik_skip
.ik_skipped:
    inc rsi
    jmp .ik_next
.ik_yes:
    mov eax, 1
    ret
.ik_no:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; ash_run(edi = number of stages) - run the parsed pipeline in the foreground.
; Sets last_exit_status from the last stage (128 + signal if killed).
; ----------------------------------------------------------------------------
ash_run:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov r12d, edi                   ; r12d = stages

    ; --- Pipes between stages (close-on-exec; dup2 clears it on 0/1) ---
    xor ebx, ebx
.ar_pipes:
    lea eax, [r12d - 1]
    cmp ebx, eax
    jae .ar_pipes_done
    lea rdi, [ash_pipes + rbx * 8]
    mov esi, O_CLOEXEC
    mov eax, SYS_PIPE2
    syscall
    test rax, rax
    js .ar_pipe_fail
    inc ebx
    jmp .ar_pipes

.ar_pipe_fail:
    mov edi, ebx
    call ash_close_pipes
    lea rdi, [ash_msg_pipe]
    call ash_write_err
    mov dword [last_exit_status], 1
    jmp .ar_ret

.ar_pipes_done:
    call restore_terminal           ; children get a cooked terminal

    xor ebx, ebx                    ; ebx = stage index
    xor r15d, r15d                  ; r15d = stages started
.ar_fork:
    cmp ebx, r12d
    jae .ar_forked
    mov eax, SYS_FORK
    syscall
    test rax, rax
    js .ar_fork_fail
    jz .ar_child
    imul ecx, ebx, STG_SIZE
    mov [ash_stages + rcx + STG_PID], rax
    inc ebx
    inc r15d
    jmp .ar_fork

.ar_fork_fail:
    lea rdi, [ash_msg_fork]
    call ash_write_err

.ar_forked:
    lea edi, [r12d - 1]
    call ash_close_pipes            ; parent keeps no pipe ends

    xor ebx, ebx
    mov r14d, 1                     ; status if nothing ran
.ar_wait:
    cmp ebx, r15d
    jae .ar_waited
    imul ecx, ebx, STG_SIZE
    mov r13, [ash_stages + rcx + STG_PID]
.ar_wait_again:
    mov dword [rsp], 0
    mov rdi, r13
    mov rsi, rsp
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -EINTR
    je .ar_wait_again
    mov eax, [rsp]
    mov edx, eax
    and edx, 0x7F                   ; WTERMSIG
    jz .ar_exited
    lea eax, [rdx + 128]
    jmp .ar_status
.ar_exited:
    shr eax, 8                      ; WEXITSTATUS
    and eax, 0xFF
.ar_status:
    mov r14d, eax
    inc ebx
    jmp .ar_wait

.ar_waited:
    cmp r15d, r12d                  ; a fork failed: pipeline failed
    jae .ar_set_status
    mov r14d, 1
.ar_set_status:
    mov [last_exit_status], r14d
    call setup_raw_mode

.ar_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ====== CHILD (ebx = stage index, r12d = stage count) ======
.ar_child:
    imul eax, ebx, STG_SIZE
    lea r13, [ash_stages + rax]

    ; stdin: previous pipe, or the '<' set up by parse_redirection
    test ebx, ebx
    jz .ac_first_in
    mov edi, [ash_pipes + rbx * 8 - 8]      ; read end of pipe (i-1)
    xor esi, esi
    mov eax, SYS_DUP2
    syscall
    jmp .ac_out
.ac_first_in:
    cmp byte [redir_stdin_active], 0
    je .ac_out
    mov edi, [redir_stdin_fd]
    xor esi, esi
    mov eax, SYS_DUP2
    syscall

.ac_out:
    ; stdout: next pipe, or the '>' set up by parse_redirection
    lea eax, [r12d - 1]
    cmp ebx, eax
    jae .ac_last_out
    mov edi, [ash_pipes + rbx * 8 + 4]      ; write end of pipe i
    mov esi, 1
    mov eax, SYS_DUP2
    syscall
    jmp .ac_files
.ac_last_out:
    cmp byte [redir_stdout_active], 0
    je .ac_files
    mov edi, [redir_stdout_fd]
    mov esi, 1
    mov eax, SYS_DUP2
    syscall

.ac_files:
    mov rdi, [r13 + STG_IN]
    test rdi, rdi
    jz .ac_file_out
    mov esi, O_RDONLY
    xor edx, edx
    call ash_child_open

.ac_file_out:
    mov rdi, [r13 + STG_OUT]
    test rdi, rdi
    jz .ac_file_err
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    test dword [r13 + STG_FLAGS], STGF_OUT_APPEND
    jz .ac_open_out
    mov esi, O_WRONLY | O_CREAT | O_APPEND
.ac_open_out:
    mov edx, 1
    call ash_child_open

.ac_file_err:
    mov rdi, [r13 + STG_ERR]
    test rdi, rdi
    jz .ac_err_to_out
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    test dword [r13 + STG_FLAGS], STGF_ERR_APPEND
    jz .ac_open_err
    mov esi, O_WRONLY | O_CREAT | O_APPEND
.ac_open_err:
    mov edx, 2
    call ash_child_open

.ac_err_to_out:
    test dword [r13 + STG_FLAGS], STGF_ERR_TO_OUT
    jz .ac_exec
    mov edi, 1
    mov esi, 2
    mov eax, SYS_DUP2
    syscall

.ac_exec:
    mov rdi, [r13 + STG_ARGV]
    call ash_exec_argv              ; does not return

; ----------------------------------------------------------------------------
; ash_exec_argv(rdi = argv) - child only. Find argv[0] in PATH and execve it.
; Exits 127 (not found) or 126 (permission denied) on failure.
; ----------------------------------------------------------------------------
ash_exec_argv:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov r12, rdi                    ; r12 = argv
    mov r13, [rdi]                  ; r13 = command name
    xor r15d, r15d                  ; r15d = 1 if some candidate was EACCES

    call build_merged_envp          ; overlay vars are exported to children

    mov rdi, r13
.ax_scan:
    mov al, [rdi]
    test al, al
    jz .ax_search
    cmp al, '/'
    je .ax_direct
    inc rdi
    jmp .ax_scan

.ax_direct:
    mov rdi, r13
    call .ax_try
    jmp .ax_failed

.ax_search:
    lea rdi, [ash_s_path]
    call getenv_internal
    test rax, rax
    jnz .ax_have_path
    lea rax, [ash_default_path]
.ax_have_path:
    mov r14, rax                    ; r14 = PATH cursor

.ax_segment:
    lea rdi, [ash_exec_path]
    lea rdx, [ash_exec_path + MAX_PATH_BUF - 2]
    mov rsi, r14
.ax_copy_dir:
    mov al, [rsi]
    test al, al
    jz .ax_dir_done
    cmp al, ':'
    je .ax_dir_done
    cmp rdi, rdx
    jae .ax_skip_segment            ; too long: skip this entry
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .ax_copy_dir
.ax_dir_done:
    mov r14, rsi                    ; r14 -> ':' or NUL after this entry
    lea rax, [ash_exec_path]
    cmp rdi, rax
    jne .ax_add_slash
    mov byte [rdi], '.'             ; empty entry means current directory
    inc rdi
.ax_add_slash:
    mov byte [rdi], '/'
    inc rdi
    mov rcx, r13
.ax_copy_name:
    cmp rdi, rdx
    jae .ax_next
    mov al, [rcx]
    mov [rdi], al
    inc rdi
    inc rcx
    test al, al
    jnz .ax_copy_name
    lea rdi, [ash_exec_path]
    call .ax_try
    jmp .ax_next

.ax_skip_segment:
    mov al, [rsi]
    test al, al
    jz .ax_skipped
    cmp al, ':'
    je .ax_skipped
    inc rsi
    jmp .ax_skip_segment
.ax_skipped:
    mov r14, rsi

.ax_next:
    cmp byte [r14], 0
    je .ax_failed
    inc r14                         ; skip ':'
    jmp .ax_segment

.ax_failed:
    lea rdi, [ash_msg_prefix]
    call ash_write_err
    mov rdi, r13
    call ash_write_err
    lea rdi, [ash_msg_notfound]
    mov ebx, 127
    test r15d, r15d
    jz .ax_print_reason
    lea rdi, [ash_msg_denied]
    mov ebx, 126
.ax_print_reason:
    call ash_write_err
    mov edi, ebx
    mov eax, SYS_EXIT
    syscall

; Try execve(rdi, argv, merged_envp). Returns only on failure.
.ax_try:
    mov rbx, rdi
    mov rsi, r12
    lea rdx, [merged_envp]
    mov eax, SYS_EXECVE
    syscall
    cmp rax, -EACCES
    jne .ax_try_noexec
    mov r15d, 1
    ret
.ax_try_noexec:
    cmp rax, -ENOEXEC               ; text file without #!: run it with sh
    jne .ax_try_ret
    lea rdi, [ash_sh_argv]
    lea rax, [sh_path]
    mov [rdi], rax
    mov [rdi + 8], rbx
    lea rsi, [r12 + 8]
    add rdi, 16
.ax_copy_args:
    mov rax, [rsi]
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    test rax, rax
    jnz .ax_copy_args
    lea rdi, [sh_path]
    lea rsi, [ash_sh_argv]
    lea rdx, [merged_envp]
    mov eax, SYS_EXECVE
    syscall
.ax_try_ret:
    ret

; ----------------------------------------------------------------------------
; ash_child_open(rdi = path, esi = open flags, edx = target fd) - child only.
; Opens the file and moves it onto the target fd. Exits 1 if it cannot.
; ----------------------------------------------------------------------------
ash_child_open:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    mov rbx, rdi
    mov r12d, edx
    mov edx, FILE_MODE_DEFAULT
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .aco_fail
    cmp eax, r12d
    je .aco_done
    mov r13d, eax
    mov edi, r13d
    mov esi, r12d
    mov eax, SYS_DUP2
    syscall
    mov edi, r13d
    mov eax, SYS_CLOSE
    syscall
.aco_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
.aco_fail:
    lea rdi, [ash_msg_prefix]
    call ash_write_err
    mov rdi, rbx
    call ash_write_err
    lea rdi, [ash_msg_noopen]
    call ash_write_err
    mov edi, 1
    mov eax, SYS_EXIT
    syscall

; ----------------------------------------------------------------------------
; ash_close_pipes(edi = number of pipes) - close both ends of each pipe
; ----------------------------------------------------------------------------
ash_close_pipes:
    push rbx
    push r12
    sub rsp, 8
    mov r12d, edi
    xor ebx, ebx
.acp_loop:
    cmp ebx, r12d
    jge .acp_done
    mov edi, [ash_pipes + rbx * 8]
    mov eax, SYS_CLOSE
    syscall
    mov edi, [ash_pipes + rbx * 8 + 4]
    mov eax, SYS_CLOSE
    syscall
    inc ebx
    jmp .acp_loop
.acp_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; ash_write_err(rdi = NUL-terminated string) - write to stderr (fd 2)
; ----------------------------------------------------------------------------
ash_write_err:
    mov rsi, rdi
    xor edx, edx
.awe_len:
    cmp byte [rsi + rdx], 0
    je .awe_write
    inc edx
    jmp .awe_len
.awe_write:
    mov edi, 2
    mov eax, SYS_WRITE
    syscall
    ret
