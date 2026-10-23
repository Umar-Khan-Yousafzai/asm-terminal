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
%define ENOENT              2
%define E2BIG               7
%define ENOEXEC             8
%define ENOMEM              12
%define EACCES              13
%define EISDIR              21
%define ENOTDIR             20
%define ETXTBSY             26
%define ENAMETOOLONG        36
%define ELOOP               40
%define EINTR               4
%define EBADINTERP          1000        ; not an errno: file exists but its #! interpreter does not

; Job control
%define JC_SYS_SETPGID      109
%define JC_SYS_GETPGRP      111
%define JC_SYS_ACCESS       21
%define JC_TIOCGPGRP        0x540F
%define JC_TIOCSPGRP        0x5410
%define JC_SIGTTIN          21
%define JC_SIGTTOU          22
%define JC_SIG_IGN          1
%define JC_VQUIT            1
%define JC_VSUSP            10

%define ASH_MAX_STAGES      16
%define ASH_MAX_ARGS        256         ; argv slots for all stages, NULLs included
%define ASH_POOL_SIZE       4096        ; unquoted word text

; One record per pipeline stage
%define STG_ARGV            0           ; qword: pointer into ash_argv
%define STG_SRC             8           ; qword: first byte of the stage in the line
%define STG_SEND            16          ; qword: end of the stage in the line
%define STG_NOPS            32          ; dword: redirections below
%define STG_ARGC            36          ; dword
%define STG_PID             40          ; qword
%define STG_OPS             48          ; STG_MAXOPS redirection records
%define STG_MAXOPS          4
%define STG_SIZE            (STG_OPS + STG_MAXOPS * 16)

; Redirection record: dword kind, dword descriptor to redirect, qword file
; name (RO_IN/RO_OUT/RO_APP) or descriptor to copy (RO_DUP). They run in the
; order they were written, as in sh ("2>&1 >f" differs from ">f 2>&1").
%define RO_IN               1
%define RO_OUT              2
%define RO_APP              3
%define RO_DUP              4

; read_word result flags (ecx)
%define RW_GLOB             1           ; unquoted * ? [
%define RW_EQUALS           2           ; unquoted =
%define RW_CONSUMED         4           ; at least one char or quote read
%define RW_MARKED           8           ; contains a byte marked as data (EV_MARK)

section .data
    ash_s_path          db "PATH", 0
    ash_default_path    db "/usr/local/bin:/usr/bin:/bin", 0
    ash_msg_prefix      db "ash: ", 0
    ash_msg_notfound    db ": command not found", 10, 0
    ash_msg_denied      db ": Permission denied", 10, 0
    ash_msg_noent       db ": No such file or directory", 10, 0
    ash_msg_isdir       db ": Is a directory", 10, 0
    ash_msg_notdir      db ": Not a directory", 10, 0
    ash_msg_badinterp   db ": bad interpreter: No such file or directory", 10, 0
    ash_msg_e2big       db ": Argument list too long", 10, 0
    ash_msg_txtbsy      db ": Text file busy", 10, 0
    ash_msg_nametoolong db ": File name too long", 10, 0
    ash_msg_loop        db ": Too many levels of symbolic links", 10, 0
    ash_msg_nomem       db ": Cannot allocate memory", 10, 0
    ash_msg_cantexec    db ": cannot execute", 10, 0
    ash_s_exit          db "exit", 0
    ; Why an exec failed: errno, exit status, message. Anything not listed
    ; is "cannot execute" (126).
    ash_exec_errs:
        dd ENOENT,       127
        dq ash_msg_noent
        dd ENOTDIR,      126
        dq ash_msg_notdir
        dd EISDIR,       126
        dq ash_msg_isdir
        dd EBADINTERP,   126
        dq ash_msg_badinterp
        dd E2BIG,        126
        dq ash_msg_e2big
        dd ETXTBSY,      126
        dq ash_msg_txtbsy
        dd ENAMETOOLONG, 126
        dq ash_msg_nametoolong
        dd ELOOP,        126
        dq ash_msg_loop
        dd ENOMEM,       126
        dq ash_msg_nomem
        dd 0, 0
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
    alignb 8
    ash_child_stage     resq 1          ; set in a pipeline child: its stage record
    ash_exec_path       resb MAX_PATH_BUF
    ash_sh_argv         resq ASH_MAX_ARGS + 2

    ; Job control state (see jc_ensure)
    jc_state            resb 1          ; 0 = not probed yet, 1 = on, 2 = off
    script_running      resb 1          ; 1 while a command line runs (Ctrl+C stays live)
    jc_shell_pgid       resd 1          ; the shell's own process group
    jc_pgid             resd 1          ; group of the job being started, 0 = none yet
    jc_tmp              resd 1          ; argument cell for the TIOC*PGRP ioctls
    jc_sa               resb 32         ; struct sigaction scratch
    script_termios      resb 60

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
    sub rsp, 24                     ; [rsp] kind, [rsp+8] fd, [rsp+16] "&>" flag

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
    mov [r15 + STG_SRC], r12
    xor eax, eax
    mov [r15 + STG_SEND], rax
    mov [r15 + STG_NOPS], eax
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
    cmp al, '&'
    je .ap_amp
    cmp al, '0'
    jb .ap_word
    cmp al, '9'
    ja .ap_word

    ; Digits straight in front of < or > name the descriptor: "2>f", "0<f"
    mov rcx, r12
.ap_digits:
    inc rcx
    movzx edx, byte [rcx]
    cmp dl, '0'
    jb .ap_digits_end
    cmp dl, '9'
    jbe .ap_digits
.ap_digits_end:
    cmp dl, '<'
    je .ap_fd_redir
    cmp dl, '>'
    jne .ap_word                    ; just a word that starts with a number
.ap_fd_redir:
    lea rdx, [r12 + 1]
    cmp rcx, rdx                    ; "10>f" and the like: leave to /bin/sh
    jne .ap_fail
    movzx esi, byte [r12]
    sub esi, '0'
    cmp esi, 2
    ja .ap_fail
    mov r12, rcx
    mov [rsp + 8], esi
    mov dword [rsp + 16], 0
    jmp .ap_op

.ap_lt:
    mov dword [rsp + 8], 0
    mov dword [rsp + 16], 0
    jmp .ap_op
.ap_gt:
    mov dword [rsp + 8], 1
    mov dword [rsp + 16], 0
    jmp .ap_op
.ap_amp:
    cmp byte [r12 + 1], '>'         ; "&>file": stdout and stderr to the file
    jne .ap_fail
    inc r12
    mov dword [rsp + 8], 1
    mov dword [rsp + 16], 1

.ap_op:
    movzx eax, byte [r12]
    inc r12
    cmp al, '<'
    je .ap_op_in
    mov edx, RO_OUT
    movzx eax, byte [r12]
    cmp al, '>'
    jne .ap_op_gt_plain
    inc r12
    mov edx, RO_APP
    jmp .ap_op_chk
.ap_op_gt_plain:
    cmp al, '|'                     ; ">|" is not supported here
    je .ap_fail
    jmp .ap_op_chk
.ap_op_in:
    mov edx, RO_IN
    movzx eax, byte [r12]
    cmp al, '<'                     ; here-doc, "<>" and "<&": not yet
    je .ap_fail
    cmp al, '>'
    je .ap_fail
    cmp al, '&'
    je .ap_fail
.ap_op_chk:
    cmp byte [r12], '&'
    jne .ap_redir_skip
    ; ">&N": copy descriptor N (0, 1 or 2)
    cmp edx, RO_OUT
    jne .ap_fail
    cmp dword [rsp + 16], 0
    jne .ap_fail
    movzx eax, byte [r12 + 1]
    sub eax, '0'
    cmp eax, 2
    ja .ap_fail
    movzx ecx, byte [r12 + 2]       ; the number must end the word
    test cl, cl
    jz .ap_dup_ok
    cmp cl, ' '
    je .ap_dup_ok
    cmp cl, 9
    je .ap_dup_ok
    cmp cl, '|'
    jne .ap_fail
.ap_dup_ok:
    add r12, 2
    mov edx, RO_DUP
    mov r8d, [rsp + 8]
    mov r9d, eax
    call .add_op
    test eax, eax
    jz .ap_fail
    jmp .ap_next

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
    mov r8d, [rsp + 8]
    mov r9, rax
    call .add_op
    test eax, eax
    jz .ap_fail
    cmp dword [rsp + 16], 0
    je .ap_next
    mov edx, RO_DUP                 ; "&>file" also copies stdout onto stderr
    mov r8d, 2
    mov r9d, 1
    call .add_op
    test eax, eax
    jz .ap_fail
    jmp .ap_next

.ap_skip:
    inc r12
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
    test ecx, RW_MARKED             ; a value is never a keyword
    jnz .ap_store_cmd
    mov rdi, rax
    call .is_keyword
    test eax, eax
    jnz .ap_fail
.ap_store_cmd:
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
    mov [r15 + STG_SEND], r12
    inc r12
    call .close_stage
    test eax, eax
    jz .ap_fail
    jmp .ap_new_stage

.ap_end:
    mov [r15 + STG_SEND], r12
    call .close_stage
    test eax, eax
    jz .ap_fail
    mov eax, ebx
    jmp .ap_ret

.ap_fail:
    xor eax, eax
.ap_ret:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; Record a redirection on the current stage: edx = RO_* kind, r8d = descriptor
; being redirected, r9 = file name or descriptor to copy. eax = 0 if full.
.add_op:
    mov ecx, [r15 + STG_NOPS]
    cmp ecx, STG_MAXOPS
    jae .ao_full
    shl ecx, 4
    lea rcx, [r15 + rcx + STG_OPS]
    mov [rcx], edx
    mov [rcx + 4], r8d
    mov [rcx + 8], r9
    inc dword [r15 + STG_NOPS]
    mov eax, 1
    ret
.ao_full:
    xor eax, eax
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
    cmp dl, EV_MARK                 ; marked byte: the next one is plain data
    je .rw_mark
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

.rw_mark:
    movzx edx, byte [r12 + 1]
    test dl, dl
    jz .rw_fail
    inc r12
    or ecx, RW_MARKED
    jmp .rw_emit

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
    cmp dl, EV_MARK
    jne .rw_sq_plain
    movzx edx, byte [r12 + 1]
    test dl, dl
    jz .rw_fail
    inc r12
    or ecx, RW_MARKED
    jmp .rw_sq_store
.rw_sq_plain:
    cmp dl, 0x27
    je .rw_sq_end
.rw_sq_store:
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
    cmp dl, EV_MARK
    jne .rw_dq_plain
    movzx edx, byte [r12 + 1]
    test dl, dl
    jz .rw_fail
    inc r12
    or ecx, RW_MARKED
    jmp .rw_dq_put
.rw_dq_plain:
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
; Job control. Every foreground pipeline and every background job gets its own
; process group. A foreground job owns the terminal while it runs, so Ctrl+C
; and Ctrl+Z reach only that job and background jobs are left alone. The shell
; takes the terminal back when the job ends or stops. This is only switched on
; when the shell started as the foreground group of its terminal; otherwise
; (scripts, pipes, a shell started in the background) children simply share
; the shell's group as before.
; ----------------------------------------------------------------------------

; jc_ensure() -> eax = 1 when job control is on. Probes once, on first use.
; The shell ignores SIGTTOU and SIGTTIN from then on so it can hand the terminal
; back from a background group; children restore the default (jc_child_setup).
jc_ensure:
    movzx eax, byte [jc_state]
    test eax, eax
    jnz .jce_known
    mov byte [jc_state], 2
    cmp byte [interactive_mode], 0
    je .jce_off
    mov eax, JC_SYS_GETPGRP
    syscall
    mov [jc_shell_pgid], eax
    mov eax, SYS_IOCTL
    xor edi, edi
    mov esi, JC_TIOCGPGRP
    lea rdx, [jc_tmp]
    syscall
    test rax, rax
    js .jce_off                     ; no controlling terminal
    mov eax, [jc_tmp]
    cmp eax, [jc_shell_pgid]
    jne .jce_off                    ; started in the background
    mov edi, JC_SIG_IGN
    call jc_tty_signals
    mov byte [jc_state], 1
    mov eax, 1
    ret
.jce_off:
    xor eax, eax
    ret
.jce_known:
    xor eax, eax
    cmp byte [jc_state], 1
    sete al
    ret

; jc_child_setup(edi = 1 for a foreground job) - runs in the forked child.
; Joins the job's group (jc_pgid, 0 = start a new one) and, for a foreground
; job, makes it the terminal's group before anything can read from it.
jc_child_setup:
    cmp byte [jc_state], 1
    jne .jcs_ret
    mov r8d, edi
    mov eax, JC_SYS_SETPGID
    xor edi, edi
    mov esi, [jc_pgid]
    syscall
    test r8d, r8d
    jz .jcs_sig
    mov eax, JC_SYS_GETPGRP
    syscall
    mov [jc_tmp], eax
    mov eax, SYS_IOCTL
    xor edi, edi
    mov esi, JC_TIOCSPGRP
    lea rdx, [jc_tmp]
    syscall
.jcs_sig:
    xor edi, edi                    ; SIGTTOU and SIGTTIN back to the default action
    call jc_tty_signals
.jcs_ret:
    ret

; jc_tty_signals(rdi = JC_SIG_IGN or 0 for the default) - set the disposition
; of SIGTTOU and SIGTTIN. The shell ignores both so it can hand the terminal
; back from a background group; jobs must see the default.
jc_tty_signals:
    mov r8d, JC_SIGTTOU
.jts_next:
    lea rsi, [jc_sa]
    mov [rsi], rdi
    mov qword [rsi + 8], 0
    mov qword [rsi + 16], 0
    mov qword [rsi + 24], 0
    mov r9, rdi
    mov eax, SYS_RT_SIGACTION
    mov edi, r8d
    xor edx, edx
    mov r10d, 8
    syscall
    mov rdi, r9
    cmp r8d, JC_SIGTTIN
    je .jts_ret
    mov r8d, JC_SIGTTIN
    jmp .jts_next
.jts_ret:
    ret

; jc_parent_after_fork(edi = child pid, esi = 1 for a foreground job)
; Does the same grouping from the parent's side, so the group exists before
; the next pipeline stage forks and no race decides who gets there first.
jc_parent_after_fork:
    cmp byte [jc_state], 1
    jne .jpf_ret
    mov r8d, esi
    xor r9d, r9d                    ; r9d = 1 for the first process of the job
    mov esi, [jc_pgid]
    test esi, esi
    jnz .jpf_set
    mov esi, edi
    mov [jc_pgid], edi
    mov r9d, 1
.jpf_set:
    mov eax, JC_SYS_SETPGID
    syscall                         ; setpgid(pid, pgid); EACCES after exec is fine
    test r9d, r9d
    jz .jpf_ret
    test r8d, r8d
    jz .jpf_ret
    mov eax, SYS_IOCTL
    xor edi, edi
    mov esi, JC_TIOCSPGRP
    lea rdx, [jc_pgid]
    syscall
.jpf_ret:
    ret

; jc_give_tty(edi = process group) - make it the terminal's foreground group
jc_give_tty:
    cmp byte [jc_state], 1
    jne .jgt_ret
    mov [jc_tmp], edi
    mov eax, SYS_IOCTL
    xor edi, edi
    mov esi, JC_TIOCSPGRP
    lea rdx, [jc_tmp]
    syscall
.jgt_ret:
    ret

; jc_reclaim() - the shell becomes the terminal's foreground group again
jc_reclaim:
    mov edi, [jc_shell_pgid]
    jmp jc_give_tty

; jc_prepare() - call before forking a foreground job: probes job control and
; lets the first process of the job start a new group
jc_prepare:
    sub rsp, 8
    call jc_ensure
    mov dword [jc_pgid], 0
    add rsp, 8
    ret

; jc_wait_fg(edi = pid, rsi = command text or 0 for input_buf) -> eax = status
; Waits for a foreground job set up with jc_child_setup and
; jc_parent_after_fork. If Ctrl+Z stopped it, it becomes a stopped job
; (status 128 + SIGTSTP). Either way the shell gets the terminal back; raw mode
; is the caller's business.
jc_wait_fg:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 24                     ; [rsp] = wait status
    mov ebx, edi
    mov r12, rsi
.jw_wait:
    mov dword [rsp], 0
    mov edi, ebx
    mov rsi, rsp
    xor edx, edx
    cmp byte [jc_state], 1
    jne .jw_go
    mov edx, WUNTRACED              ; also report a job stopped by Ctrl+Z
.jw_go:
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -EINTR
    je .jw_wait
    mov eax, [rsp]
    mov esi, 1
    call jc_status
    mov r13d, eax
    test edx, edx
    jnz .jw_stopped
    call jc_reclaim
    jmp .jw_ret
.jw_stopped:
    mov edi, ebx
    mov esi, [jc_pgid]
    mov edx, JOB_STOPPED
    mov rcx, r12
    call job_add
    test eax, eax
    js .jw_refused
    mov r12d, eax
    call jc_reclaim
    mov edi, r12d
    call job_notify_stopped
    call restore_terminal           ; the program may have left the terminal raw
    jmp .jw_ret
.jw_refused:
    ; No room in the job table: let the job carry on rather than lose it
    lea rdi, [jobs_full_msg]
    call ash_write_err
    mov edi, [jc_pgid]
    neg edi
    mov esi, SIGCONT
    mov eax, SYS_KILL
    syscall
    jmp .jw_wait
.jw_ret:
    mov eax, r13d
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; jc_status(eax = wait status, esi = 1 when SIGINT means Ctrl+C)
;   -> eax = exit status (128 + signal when killed or stopped), edx = 1 if stopped
; A foreground job killed by SIGINT also aborts the running script: with its
; own process group the shell no longer gets that SIGINT itself.
jc_status:
    mov ecx, eax
    and ecx, 0xFF
    cmp ecx, 0x7F
    je .jst_stopped
    test ecx, ecx
    jz .jst_exited
    and ecx, 0x7F
    test esi, esi
    jz .jst_signal
    cmp ecx, SIGINT
    jne .jst_signal
    cmp byte [jc_state], 1          ; only a keyboard Ctrl+C aimed at the job
    jne .jst_signal
    mov byte [ctrl_c_flag], 1
.jst_signal:
    lea eax, [rcx + 128]
    xor edx, edx
    ret
.jst_exited:
    shr eax, 8
    and eax, 0xFF
    xor edx, edx
    ret
.jst_stopped:
    shr eax, 8
    and eax, 0xFF
    add eax, 128
    mov edx, 1
    ret

; script_isig_apply() - termios for a running command line: raw input like the
; line editor, but ISIG on so Ctrl+C raises SIGINT and stops a loop that runs
; only builtins. The suspend and quit keys are switched off because the shell
; itself must not be stopped or dumped by them.
script_isig_apply:
    cmp byte [jc_state], 1
    jne .sia_ret
    mov eax, SYS_IOCTL
    mov edi, STDIN_FD
    mov esi, TCGETS
    lea rdx, [script_termios]
    syscall
    test rax, rax
    js .sia_ret
    or dword [script_termios + TERMIOS_C_LFLAG], ISIG
    mov byte [script_termios + TERMIOS_C_CC + JC_VQUIT], 0
    mov byte [script_termios + TERMIOS_C_CC + JC_VSUSP], 0
    mov eax, SYS_IOCTL
    mov edi, STDIN_FD
    mov esi, TCSETS
    lea rdx, [script_termios]
    syscall
.sia_ret:
    ret

; script_isig_on() - a command line is about to run (interactive shell)
script_isig_on:
    sub rsp, 8
    mov byte [script_running], 1
    cmp byte [interactive_mode], 0
    je .sion_ret
    call jc_ensure
    call script_isig_apply
.sion_ret:
    add rsp, 8
    ret

; script_isig_off() - the line is done: back to the line editor's raw mode.
; A Ctrl+C that arrived while it ran has been dealt with by now.
script_isig_off:
    mov byte [script_running], 0
    mov byte [ctrl_c_flag], 0
    cmp byte [interactive_mode], 0
    je .sioff_ret
    cmp byte [jc_state], 1
    jne .sioff_ret
    mov eax, SYS_IOCTL
    mov edi, STDIN_FD
    mov esi, TCSETS
    lea rdx, [raw_termios]
    syscall
.sioff_ret:
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
    lea rdi, [ash_pipes + rbx * 8]  ; with fd 0-2 closed a pipe end can be 0, 1
    call ash_pipe_lift              ; or 2, which dup2 in the child would not clear
    test eax, eax
    js .ar_pipe_fail                ; ash_pipe_lift closed this pipe's ends
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
    call jc_ensure
    mov dword [jc_pgid], 0          ; the first stage starts the job's group

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
    mov edi, eax
    mov esi, 1                      ; foreground: this group owns the terminal
    call jc_parent_after_fork
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
    cmp byte [jc_state], 1
    jne .ar_wait_go
    mov edx, WUNTRACED           ; also report a job stopped by Ctrl+Z
.ar_wait_go:
    lea r10, [ash_rusage]
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -EINTR
    je .ar_wait_again
    test rax, rax
    js .ar_no_rusage
    call stats_note_rusage          ; keep the biggest peak RSS
.ar_no_rusage:
    mov eax, [rsp]
    mov esi, 1
    call jc_status                  ; 128 + signal when killed
    mov r14d, eax
    test edx, edx
    jnz .ar_stopped
    inc ebx
    jmp .ar_wait

.ar_waited:
    call jc_reclaim                 ; the shell owns the terminal again
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

    ; The pipeline was stopped (Ctrl+Z). Its other stages are stopped with it,
    ; so keep the whole group as a stopped job instead of waiting for them.
.ar_stopped:
    lea eax, [r15d - 1]
    imul ecx, eax, STG_SIZE
    mov edi, [ash_stages + rcx + STG_PID]   ; the last stage gives the status
    mov esi, [jc_pgid]
    mov edx, JOB_STOPPED
    xor ecx, ecx
    call job_add
    test eax, eax
    js .ar_stop_refused
    mov r13d, eax
    call jc_reclaim
    mov edi, r13d
    call job_notify_stopped
    call restore_terminal           ; the program may have left the terminal raw
    jmp .ar_set_status
.ar_stop_refused:
    ; No room in the job table: let the job carry on rather than lose it.
    lea rdi, [jobs_full_msg]
    call ash_write_err
    mov edi, [jc_pgid]
    neg edi
    mov esi, SIGCONT
    mov eax, SYS_KILL
    syscall
    jmp .ar_wait_again

; ====== CHILD (ebx = stage index, r12d = stage count) ======
.ar_child:
    mov edi, 1
    call jc_child_setup             ; own process group, owns the terminal
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
    test edi, edi                   ; the original must not leak into the command
    jz .ac_out
    mov eax, SYS_CLOSE
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
    cmp edi, 1
    je .ac_files
    mov eax, SYS_CLOSE
    syscall

.ac_files:
    ; Redirections in the order they were written
    xor r14d, r14d
.ac_op_loop:
    cmp r14d, [r13 + STG_NOPS]
    jae .ac_exec
    mov eax, r14d
    shl eax, 4
    lea r15, [r13 + rax + STG_OPS]
    mov eax, [r15]
    mov edx, [r15 + 4]              ; descriptor being redirected
    cmp eax, RO_DUP
    je .ac_dup
    mov rdi, [r15 + 8]
    mov esi, O_RDONLY
    cmp eax, RO_IN
    je .ac_open
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    cmp eax, RO_OUT
    je .ac_open
    mov esi, O_WRONLY | O_CREAT | O_APPEND
.ac_open:
    call ash_child_open
    jmp .ac_op_next
.ac_dup:
    mov edi, [r15 + 8]
    mov esi, edx
    mov eax, SYS_DUP2
    syscall
.ac_op_next:
    inc r14d
    jmp .ac_op_loop

.ac_exec:
    mov [ash_child_stage], r13
    mov rdi, [r13 + STG_ARGV]
    call ash_exec_argv              ; does not return

; ----------------------------------------------------------------------------
; ash_exec_argv(rdi = argv) - child only. Find argv[0] in PATH and execve it.
; On failure it says why and exits 127 (no such command or file) or 126 (found
; but cannot be run: permission denied, a directory, a missing interpreter...).
; ----------------------------------------------------------------------------
ash_exec_argv:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24                     ; [rbp-64] first errno worth reporting,
                                    ; [rbp-60] 1 when the name contains a '/'

    mov r12, rdi                    ; r12 = argv
    mov r13, [rdi]                  ; r13 = command name
    xor r15d, r15d                  ; r15d = 1 if some candidate was EACCES
    mov qword [rbp - 64], 0

    ; "exit" as a pipeline stage ends only that stage, as in sh's subshell
    mov rdi, r13
    lea rsi, [ash_s_exit]
    call str_icompare
    test eax, eax
    jnz .ax_not_exit
    mov rdi, [r12 + 8]
    test rdi, rdi
    jz .ax_exit_prev
    call bi_parse_status
    test edx, edx
    jz .ax_exit_bad
    mov edi, eax
    mov eax, SYS_EXIT
    syscall
.ax_exit_prev:
    mov edi, [prev_exit_status]
    mov eax, SYS_EXIT
    syscall
.ax_exit_bad:
    lea rdi, [bi_msg_exit_num]
    call ash_write_err
    mov edi, 2
    mov eax, SYS_EXIT
    syscall
.ax_not_exit:

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
    mov dword [rbp - 60], 1
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
    test r15d, r15d                 ; a program that exists but cannot run, or a
    jnz .ax_report                  ; path with a slash, is never a builtin
    cmp dword [rbp - 60], 0
    jne .ax_report
    call ash_child_builtin          ; a builtin used as a pipeline stage
.ax_report:
    lea rdi, [ash_msg_prefix]
    call ash_write_err
    mov rdi, r13
    call ash_write_err
    ; Permission denied outranks the other reasons met while searching PATH
    mov ebx, 126
    lea rdi, [ash_msg_denied]
    test r15d, r15d
    jnz .ax_print_reason
    mov eax, [rbp - 64]
    test eax, eax
    jnz .ax_lookup
    mov ebx, 127
    lea rdi, [ash_msg_notfound]
    jmp .ax_print_reason
.ax_lookup:
    lea rsi, [ash_exec_errs]
.ax_lookup_next:
    mov ecx, [rsi]
    test ecx, ecx
    jz .ax_generic
    cmp ecx, eax
    je .ax_lookup_hit
    add rsi, 16
    jmp .ax_lookup_next
.ax_lookup_hit:
    mov ebx, [rsi + 4]
    mov rdi, [rsi + 8]
    jmp .ax_print_reason
.ax_generic:
    lea rdi, [ash_msg_cantexec]
.ax_print_reason:
    call ash_write_err
    mov edi, ebx
    mov eax, SYS_EXIT
    syscall

; Try execve(rdi, argv, merged_envp). Returns only on failure, having noted
; the reason: r15d for permission denied, [rbp-64] for anything else but
; "not there", which is not worth reporting while PATH is still being searched.
.ax_try:
    mov rbx, rdi
    mov rsi, r12
    lea rdx, [merged_envp]
    mov eax, SYS_EXECVE
    syscall
    neg eax                         ; eax = errno
    mov edx, eax
    cmp edx, ENOEXEC
    je .ax_try_noexec
    cmp edx, EACCES
    je .ax_try_acces
    cmp edx, ENOENT
    je .ax_try_noent
    cmp edx, ENOTDIR
    jne .ax_try_note
    cmp dword [rbp - 60], 0         ; a PATH entry that is a file: keep looking
    je .ax_try_ret
.ax_try_note:
    cmp dword [rbp - 64], 0
    jne .ax_try_ret
    mov [rbp - 64], edx
.ax_try_ret:
    ret
.ax_try_noent:
    ; Either the file is missing, or it exists and its #! interpreter does not
    mov rdi, rbx
    xor esi, esi                    ; F_OK
    mov eax, JC_SYS_ACCESS
    syscall
    test rax, rax
    mov edx, EBADINTERP
    jz .ax_try_note
    mov edx, ENOENT
    cmp dword [rbp - 60], 0
    jne .ax_try_note
    ret
.ax_try_acces:
    ; execve gives EACCES for a directory as well as for a file without x
    mov rdi, rbx
    lea rsi, [stat_buf]
    mov eax, SYS_STAT
    syscall
    test rax, rax
    jnz .ax_try_denied
    mov eax, [stat_buf + STAT_ST_MODE]
    and eax, 0o170000
    cmp eax, 0o040000
    jne .ax_try_denied
    mov edx, EISDIR
    cmp dword [rbp - 60], 0
    jne .ax_try_note
    ret                             ; a directory in PATH is not a command
.ax_try_denied:
    mov r15d, 1
    ret
.ax_try_noexec:
    ; text file without #!: run it with sh
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
    ret

; ----------------------------------------------------------------------------
; ash_child_builtin - called in a forked pipeline stage whose command is not a
; program on PATH: run it as a builtin ("history | grep x"), then exit. It
; returns only when the command is not a builtin. The stage's own
; redirections are already in place, so they are only stripped from the text.
; ----------------------------------------------------------------------------
ash_child_builtin:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8
    mov rbx, [ash_child_stage]
    test rbx, rbx
    jz .cb_ret
    mov rsi, [rbx + STG_SRC]
    mov rdx, [rbx + STG_SEND]
    lea rdi, [input_buf]
    lea r8, [input_buf + MAX_INPUT - 1]
.cb_copy:
    cmp rsi, rdx
    jae .cb_copied
    cmp rdi, r8
    jae .cb_copied
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .cb_copy
.cb_copied:
    mov byte [rdi], 0
    call parse_redirection
    test eax, eax
    jnz .cb_ret
    lea rdi, [cleaned_cmd_buf]
    call skip_spaces
    mov rbx, rax
    mov rdi, rbx
    call dc_find_builtin
    test rax, rax
    jz .cb_ret
    lea rdi, [input_buf]
    mov rsi, rbx
    call str_copy
    lea rdi, [input_buf]
    call dc_find_builtin
    mov rdi, rax
    mov rsi, rdx
    call dc_run_handler
    mov edi, [last_exit_status]
    mov eax, SYS_EXIT
    syscall
.cb_ret:
    add rsp, 8
    pop rbx
    pop rbp
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
; ash_pipe_lift(rdi = int fds[2]) -> eax = 0, or -1 with both ends closed.
; Moves an end that landed on fd 0, 1 or 2 (the shell was started with one of
; them closed) up to fd 3 or above, keeping close-on-exec.
; ----------------------------------------------------------------------------
%define F_DUPFD_CLOEXEC     1030

ash_pipe_lift:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov rbx, rdi
    xor r12d, r12d
.apl_loop:
    mov edi, [rbx + r12 * 4]
    cmp edi, 3
    jae .apl_next
    mov esi, F_DUPFD_CLOEXEC
    mov edx, 3
    mov eax, SYS_FCNTL
    syscall
    test rax, rax
    js .apl_fail
    mov edi, [rbx + r12 * 4]
    mov [rbx + r12 * 4], eax
    mov eax, SYS_CLOSE
    syscall
.apl_next:
    inc r12d
    cmp r12d, 2
    jb .apl_loop
    xor eax, eax
    pop r12
    pop rbx
    pop rbp
    ret
.apl_fail:
    mov edi, [rbx]
    mov eax, SYS_CLOSE
    syscall
    mov edi, [rbx + 4]
    mov eax, SYS_CLOSE
    syscall
    mov eax, -1
    pop r12
    pop rbx
    pop rbp
    ret

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
