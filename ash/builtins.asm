; ============================================================================
; ASH builtins (milestone 2, part A) and per-command stats
;
;   exit N        exit with status N
;   true / false  set status 0 / 1
;   clear         clear the screen (same as cls)
;   which NAME..  say whether each NAME is a builtin, an alias or a file
;   history       list history;  history -c  clears it (memory + file)
;   kill [-SIG] PID|%JOB ...
;
; Stats: every external command records its wall time and peak memory.
; If it ran for 1 second or more (or ASM_STATS=1 is set), the next prompt
; prints a dim line such as "took 2.31s, peak 45.2 MB".
;
; Included from terminal_linux.asm, after ash/ash_exec.asm.
; ============================================================================

%define CLOCK_MONOTONIC     1
%define RUSAGE_SIZE         144
%define RU_MAXRSS           32          ; long ru_maxrss (KB) in struct rusage
%define STATS_MIN_NS        1000000000  ; 1 s
%define X_OK                1
%define ESRCH               3
%define EPERM               1
%define S_IFMT              0o170000
%define S_IFREG             0o100000

section .data
    bi_s_true           db "true", 0
    bi_s_false          db "false", 0
    bi_s_clear          db "clear", 0
    bi_s_which          db "which", 0
    bi_s_history        db "history", 0
    bi_s_kill           db "kill", 0
    bi_s_dash_c         db "-c", 0
    bi_s_stats_env      db "ASM_STATS", 0

    bi_msg_exit_num     db "exit: numeric argument required", 10, 0
    bi_msg_builtin      db ": shell builtin", 10, 0
    bi_msg_alias        db ": alias for ", 0
    bi_msg_notfound     db ": not found", 10, 0
    bi_msg_which_usage  db "Usage: which NAME...", 10, 0
    bi_msg_kill_usage   db "Usage: kill [-SIGNAL] PID|%JOB ...", 10, 0
    bi_msg_kill_badsig  db "kill: unknown signal: ", 0
    bi_msg_kill_nojob   db "kill: no such job: ", 0
    bi_msg_kill_badpid  db "kill: not a process id: ", 0
    bi_msg_kill_esrch   db "kill: no such process: ", 0
    bi_msg_kill_eperm   db "kill: operation not permitted: ", 0
    bi_msg_hist_cleared db "History cleared.", 10, 0
    bi_msg_hist_usage   db "Usage: history [-c]", 10, 0
    bi_msg_nl           db 10, 0
    bi_hist_gap         db "  ", 0

    stats_pre           db 27, "[90m  took ", 0
    stats_pre_plain     db "  took ", 0
    stats_peak          db ", peak ", 0
    stats_post          db 27, "[0m", 10, 0
    stats_post_plain    db 10, 0
    stats_s             db "s", 0
    stats_m             db "m ", 0
    stats_mb            db " MB", 0
    stats_kb            db " KB", 0
    stats_dot           db ".", 0
    stats_zero          db "0", 0

    ; Signal names for kill -NAME (NUL-separated name, then signal byte)
    bi_signals          db "HUP", 0, 1,  "INT", 0, 2,  "QUIT", 0, 3
                        db "KILL", 0, 9, "USR1", 0, 10, "USR2", 0, 12
                        db "TERM", 0, 15, "CONT", 0, 18, "STOP", 0, 19
                        db "TSTP", 0, 20, 0

section .bss
    stats_t0            resq 2          ; timespec at command start
    stats_t1            resq 2
    stats_ns            resq 1          ; wall time of last external command
    stats_maxrss_kb     resq 1          ; peak RSS of its processes, 0 = unknown
    stats_valid         resb 1
    ash_rusage          resb RUSAGE_SIZE
    bi_word             resb 256
    bi_path             resb MAX_PATH_BUF

section .text

; ----------------------------------------------------------------------------
; Stats
; ----------------------------------------------------------------------------

; stats_begin() - call before running an external command
stats_begin:
    mov byte [stats_valid], 0
    mov qword [stats_maxrss_kb], 0
    mov edi, CLOCK_MONOTONIC
    lea rsi, [stats_t0]
    mov eax, SYS_CLOCK_GETTIME
    syscall
    ret

; stats_end() - call after it finished; stores stats_ns
stats_end:
    mov edi, CLOCK_MONOTONIC
    lea rsi, [stats_t1]
    mov eax, SYS_CLOCK_GETTIME
    syscall
    mov rax, [stats_t1]
    sub rax, [stats_t0]
    imul rax, rax, 1000000000
    add rax, [stats_t1 + 8]
    sub rax, [stats_t0 + 8]
    mov [stats_ns], rax
    mov byte [stats_valid], 1
    ret

; stats_note_rusage() - fold ash_rusage.ru_maxrss into stats_maxrss_kb
stats_note_rusage:
    mov rax, [ash_rusage + RU_MAXRSS]
    cmp rax, [stats_maxrss_kb]
    jbe .snr_ret
    mov [stats_maxrss_kb], rax
.snr_ret:
    ret

; print_cmd_stats() - called by print_prompt; prints the "took" line
print_cmd_stats:
    push rbp
    mov rbp, rsp
    push rbx
    push r12

    cmp byte [stats_valid], 0
    je .pcs_ret
    mov byte [stats_valid], 0       ; show once
    mov rax, [stats_ns]
    cmp rax, STATS_MIN_NS
    jae .pcs_show
    lea rdi, [bi_s_stats_env]
    call getenv_internal
    test rax, rax
    jz .pcs_ret
    cmp byte [rax], '1'
    jne .pcs_ret

.pcs_show:
    lea rdi, [stats_pre]
    cmp byte [color_enabled], 0
    jne .pcs_pre
    lea rdi, [stats_pre_plain]
.pcs_pre:
    call print_cstring

    ; Time: "M m SS.ss s" when >= 60 s, else "S.ss s"
    mov rax, [stats_ns]
    xor edx, edx
    mov rcx, 10000000               ; -> hundredths of a second
    div rcx
    mov rbx, rax                    ; rbx = centiseconds
    xor edx, edx
    mov rcx, 100
    div rcx                         ; rax = seconds, rdx = hundredths
    mov r12, rdx
    cmp rax, 60
    jb .pcs_secs
    xor edx, edx
    mov rcx, 60
    div rcx                         ; rax = minutes, rdx = seconds
    push rdx
    push rdx
    call print_number
    lea rdi, [stats_m]
    call print_cstring
    pop rax
    pop rax
.pcs_secs:
    call print_number
    lea rdi, [stats_dot]
    call print_cstring
    cmp r12, 10
    jae .pcs_hund
    lea rdi, [stats_zero]
    call print_cstring
.pcs_hund:
    mov eax, r12d
    call print_number
    lea rdi, [stats_s]
    call print_cstring

    ; Peak memory, if known
    mov rax, [stats_maxrss_kb]
    test rax, rax
    jz .pcs_end
    lea rdi, [stats_peak]
    call print_cstring
    mov rax, [stats_maxrss_kb]
    cmp rax, 1024
    jae .pcs_mb
    call print_number
    lea rdi, [stats_kb]
    call print_cstring
    jmp .pcs_end
.pcs_mb:
    imul rax, rax, 10
    xor edx, edx
    mov rcx, 1024
    div rcx                         ; tenths of a MB
    xor edx, edx
    mov rcx, 10
    div rcx
    mov r12, rdx
    call print_number
    lea rdi, [stats_dot]
    call print_cstring
    mov eax, r12d
    call print_number
    lea rdi, [stats_mb]
    call print_cstring

.pcs_end:
    lea rdi, [stats_post]
    cmp byte [color_enabled], 0
    jne .pcs_post
    lea rdi, [stats_post_plain]
.pcs_post:
    call print_cstring
.pcs_ret:
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; Simple builtins
; ----------------------------------------------------------------------------

handler_true:
    mov dword [last_exit_status], 0
    ret

handler_false:
    mov dword [last_exit_status], 1
    ret

; exit N
handler_exit_code:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8
    test rdi, rdi
    jz .hec_plain
    call skip_spaces
    mov rdi, rax
    cmp byte [rdi], 0
    je .hec_plain
    call bi_parse_uint              ; eax = value, edx = 1 if ok
    test edx, edx
    jz .hec_bad
    movzx ebx, al                   ; status is 0-255
    call restore_terminal
    mov edi, ebx
    mov eax, SYS_EXIT
    syscall
.hec_plain:
    call handler_exit               ; does not return
.hec_bad:
    lea rdi, [bi_msg_exit_num]
    call print_cstring
    mov dword [last_exit_status], 2
    add rsp, 8
    pop rbx
    pop rbp
    ret

; bi_parse_uint(rdi = string) -> eax = value, edx = 1 if the whole word
; (up to space or NUL) was digits, rdi = pointer after the word
bi_parse_uint:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
.pu_loop:
    movzx ecx, byte [rdi]
    test cl, cl
    jz .pu_end
    cmp cl, ' '
    je .pu_end
    sub ecx, '0'
    cmp ecx, 9
    ja .pu_bad
    imul eax, eax, 10
    add eax, ecx
    mov edx, 1
    inc rdi
    jmp .pu_loop
.pu_bad:
    xor edx, edx
.pu_skip:
    cmp byte [rdi], 0
    je .pu_ret
    cmp byte [rdi], ' '
    je .pu_ret
    inc rdi
    jmp .pu_skip
.pu_end:
.pu_ret:
    ret

; bi_next_word(rdi = cursor) -> rax = cursor after word, bi_word = word,
; ecx = word length (0 = no more words)
bi_next_word:
.nw_skip:
    cmp byte [rdi], ' '
    jne .nw_start
    inc rdi
    jmp .nw_skip
.nw_start:
    lea rsi, [bi_word]
    xor ecx, ecx
.nw_copy:
    mov al, [rdi]
    test al, al
    jz .nw_done
    cmp al, ' '
    je .nw_done
    cmp ecx, 255
    jae .nw_skip_rest
    mov [rsi + rcx], al
    inc ecx
.nw_skip_rest:
    inc rdi
    jmp .nw_copy
.nw_done:
    mov byte [rsi + rcx], 0
    mov rax, rdi
    ret

; ----------------------------------------------------------------------------
; which NAME...
; ----------------------------------------------------------------------------
handler_which:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov dword [last_exit_status], 0
    test rdi, rdi
    jz .hw_usage
    mov r12, rdi                    ; r12 = cursor
    xor r13d, r13d                  ; r13 = names seen

.hw_next:
    mov rdi, r12
    call bi_next_word
    mov r12, rax
    test ecx, ecx
    jz .hw_end
    inc r13d

    ; Builtin? exact table (16-byte rows), then prefix table (24-byte rows)
    lea rbx, [cmd_table_exact]
.hw_exact:
    mov rsi, [rbx]
    test rsi, rsi
    jz .hw_prefix_start
    lea rdi, [bi_word]
    call str_icompare
    test eax, eax
    jz .hw_is_builtin
    add rbx, 16
    jmp .hw_exact
.hw_prefix_start:
    lea rbx, [cmd_table_prefix]
.hw_prefix:
    mov rsi, [rbx]
    test rsi, rsi
    jz .hw_alias_start
    lea rdi, [bi_word]
    call str_icompare
    test eax, eax
    jz .hw_is_builtin
    add rbx, 24
    jmp .hw_prefix

.hw_alias_start:
    lea rbx, [alias_table]
    xor r14d, r14d
.hw_alias:
    cmp r14d, [alias_count]
    jge .hw_path
    lea rdi, [bi_word]
    mov rsi, rbx
    call str_icompare
    test eax, eax
    jz .hw_is_alias
    add rbx, ALIAS_ENTRY_SIZE
    inc r14d
    jmp .hw_alias

.hw_path:
    lea rdi, [bi_word]
    call bi_find_in_path            ; eax = 1 -> bi_path
    test eax, eax
    jz .hw_missing
    lea rdi, [bi_path]
    call print_cstring
    call print_newline
    jmp .hw_next

.hw_is_builtin:
    lea rdi, [bi_word]
    call print_cstring
    lea rdi, [bi_msg_builtin]
    call print_cstring
    jmp .hw_next

.hw_is_alias:
    lea rdi, [bi_word]
    call print_cstring
    lea rdi, [bi_msg_alias]
    call print_cstring
    lea rdi, [rbx + ALIAS_NAME_SIZE]
    call print_cstring
    call print_newline
    jmp .hw_next

.hw_missing:
    lea rdi, [bi_word]
    call print_cstring
    lea rdi, [bi_msg_notfound]
    call print_cstring
    mov dword [last_exit_status], 1
    jmp .hw_next

.hw_end:
    test r13d, r13d
    jnz .hw_ret
.hw_usage:
    lea rdi, [bi_msg_which_usage]
    call print_cstring
    mov dword [last_exit_status], 2
.hw_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; bi_find_in_path(rdi = name) -> eax = 1 and bi_path = full path of an
; executable regular file, else 0. Names with '/' are checked as given.
bi_find_in_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov r12, rdi
    mov rdi, r12
.fp_scan:
    mov al, [rdi]
    test al, al
    jz .fp_search
    cmp al, '/'
    je .fp_direct
    inc rdi
    jmp .fp_scan

.fp_direct:
    lea rdi, [bi_path]
    mov rsi, r12
    call upd_stpcpy
    call .fp_check
    jmp .fp_ret

.fp_search:
    lea rdi, [ash_s_path]
    call getenv_internal
    test rax, rax
    jnz .fp_have
    lea rax, [ash_default_path]
.fp_have:
    mov r13, rax
.fp_seg:
    lea rdi, [bi_path]
    lea r14, [bi_path + MAX_PATH_BUF - 2]
.fp_dir:
    mov al, [r13]
    test al, al
    jz .fp_dir_end
    cmp al, ':'
    je .fp_dir_end
    cmp rdi, r14
    jae .fp_too_long
    mov [rdi], al
    inc rdi
    inc r13
    jmp .fp_dir
.fp_dir_end:
    lea rax, [bi_path]
    cmp rdi, rax
    jne .fp_slash
    mov byte [rdi], '.'
    inc rdi
.fp_slash:
    mov byte [rdi], '/'
    inc rdi
    mov rsi, r12
.fp_name:
    cmp rdi, r14
    jae .fp_next
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    test al, al
    jnz .fp_name
    call .fp_check
    test eax, eax
    jnz .fp_ret
    jmp .fp_next
.fp_too_long:
    mov al, [r13]
    test al, al
    jz .fp_next
    cmp al, ':'
    je .fp_next
    inc r13
    jmp .fp_too_long
.fp_next:
    cmp byte [r13], 0
    je .fp_none
    inc r13
    jmp .fp_seg
.fp_none:
    xor eax, eax
.fp_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; bi_path is executable and a regular file? eax = 1 / 0
.fp_check:
    lea rdi, [bi_path]
    mov esi, X_OK
    mov eax, SYS_ACCESS
    syscall
    test rax, rax
    jnz .fc_no
    lea rdi, [bi_path]
    lea rsi, [stat_buf]
    mov eax, SYS_STAT
    syscall
    test rax, rax
    jnz .fc_no
    mov eax, [stat_buf + STAT_ST_MODE]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .fc_no
    mov eax, 1
    ret
.fc_no:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; history / history -c
; ----------------------------------------------------------------------------
handler_history:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov dword [last_exit_status], 0
    test rdi, rdi
    jz .hh_list
    call skip_spaces
    cmp byte [rax], 0
    je .hh_list
    mov rdi, rax
    lea rsi, [bi_s_dash_c]
    call str_icompare
    test eax, eax
    jz .hh_clear
    lea rdi, [bi_msg_hist_usage]
    call print_cstring
    mov dword [last_exit_status], 2
    jmp .hh_ret

.hh_list:
    mov r12d, [history_count]
    ; oldest = (write_idx - count) mod HISTORY_COUNT
    mov eax, [history_write_idx]
    sub eax, r12d
    jns .hh_start_ok
    add eax, HISTORY_COUNT
.hh_start_ok:
    mov r13d, eax                   ; r13d = slot
    xor r14d, r14d                  ; r14d = printed
.hh_loop:
    cmp r14d, r12d
    jge .hh_ret
    inc r14d
    mov eax, r14d
    call print_number_5pad
    lea rdi, [bi_hist_gap]
    call print_cstring
    imul eax, r13d, HISTORY_ENTRY_SIZE
    lea rdi, [history_buf + rax]
    call print_cstring
    call print_newline
    inc r13d
    cmp r13d, HISTORY_COUNT
    jb .hh_loop
    xor r13d, r13d
    jmp .hh_loop

.hh_clear:
    mov dword [history_count], 0
    mov dword [history_write_idx], 0
    mov dword [history_nav_idx], 0
    cmp byte [history_file_path], 0
    je .hh_cleared
    lea rdi, [history_file_path]
    mov esi, O_WRONLY | O_TRUNC
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .hh_cleared
    mov edi, eax
    mov eax, SYS_CLOSE
    syscall
.hh_cleared:
    lea rdi, [bi_msg_hist_cleared]
    call print_cstring

.hh_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; print_number_5pad(eax) - right-align a number in 5 columns
print_number_5pad:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8
    mov ebx, eax
    mov ecx, 4                      ; spaces for a 1-digit number
    mov edx, 10
.p5_digits:
    cmp eax, edx
    jb .p5_pad
    dec ecx
    imul edx, edx, 10
    test ecx, ecx
    jnz .p5_digits
.p5_pad:
    test ecx, ecx
    jz .p5_num
    push rcx
    push rcx
    lea rdi, [str_space]
    call print_cstring
    pop rcx
    pop rcx
    dec ecx
    jmp .p5_pad
.p5_num:
    mov eax, ebx
    call print_number
    add rsp, 8
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; kill [-SIGNAL] PID|%JOB ...
; ----------------------------------------------------------------------------
handler_kill:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov dword [last_exit_status], 0
    test rdi, rdi
    jz .hk_usage
    mov r12, rdi
    mov r13d, SIGTERM               ; r13d = signal
    xor r14d, r14d                  ; r14d = targets seen

    ; Optional -SIGNAL (only as the first word)
    mov rdi, r12
    call bi_next_word
    test ecx, ecx
    jz .hk_usage
    cmp byte [bi_word], '-'
    jne .hk_targets_first
    mov r12, rax
    lea rdi, [bi_word + 1]
    call bi_signal_number           ; eax = signal or -1
    test eax, eax
    js .hk_badsig
    mov r13d, eax

.hk_next:
    mov rdi, r12
    call bi_next_word
    test ecx, ecx
    jz .hk_end
    mov r12, rax
    jmp .hk_one
.hk_targets_first:
    mov r12, rax

.hk_one:
    inc r14d
    cmp byte [bi_word], '%'
    je .hk_job
    lea rdi, [bi_word]
    call bi_parse_uint
    test edx, edx
    jz .hk_badpid
    test eax, eax
    jz .hk_badpid
    mov edi, eax
    jmp .hk_send

.hk_job:
    lea rdi, [bi_word + 1]
    call bi_parse_uint
    test edx, edx
    jz .hk_nojob
    test eax, eax
    jz .hk_nojob
    ; Nth active slot, numbered like 'jobs'
    xor ecx, ecx
    xor edx, edx
.hk_slot:
    cmp ecx, JOB_MAX
    jge .hk_nojob
    mov rdi, [job_pids + rcx*8]
    test rdi, rdi
    jz .hk_slot_next
    inc edx
    cmp edx, eax
    je .hk_send
.hk_slot_next:
    inc ecx
    jmp .hk_slot

.hk_send:
    mov esi, r13d
    mov eax, SYS_KILL
    syscall
    test rax, rax
    jz .hk_next
    lea rdi, [bi_msg_kill_esrch]
    cmp rax, -EPERM
    jne .hk_err
    lea rdi, [bi_msg_kill_eperm]
    jmp .hk_err

.hk_badpid:
    lea rdi, [bi_msg_kill_badpid]
    jmp .hk_err
.hk_nojob:
    lea rdi, [bi_msg_kill_nojob]
.hk_err:
    call print_cstring
    lea rdi, [bi_word]
    call print_cstring
    call print_newline
    mov dword [last_exit_status], 1
    jmp .hk_next

.hk_badsig:
    lea rdi, [bi_msg_kill_badsig]
    call print_cstring
    lea rdi, [bi_word + 1]
    call print_cstring
    call print_newline
    mov dword [last_exit_status], 1
    jmp .hk_ret

.hk_end:
    test r14d, r14d
    jnz .hk_ret
.hk_usage:
    lea rdi, [bi_msg_kill_usage]
    call print_cstring
    mov dword [last_exit_status], 2
.hk_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; bi_signal_number(rdi = "9" / "KILL" / "SIGKILL") -> eax = signal or -1
bi_signal_number:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8
    mov rbx, rdi
    call bi_parse_uint
    test edx, edx
    jz .sn_name
    cmp eax, 64
    ja .sn_bad
    jmp .sn_ret
.sn_name:
    ; strip optional "SIG"
    mov rdi, rbx
    lea rsi, [bi_s_sig]
    mov edx, 3
    call str_icompare_n
    test eax, eax
    jnz .sn_lookup
    add rbx, 3
.sn_lookup:
    lea r8, [bi_signals]
.sn_loop:
    cmp byte [r8], 0
    je .sn_bad
    mov rdi, rbx
    mov rsi, r8
    push r8
    push r8
    call str_icompare
    pop r8
    pop r8
.sn_skip:
    cmp byte [r8], 0                ; move past the name...
    je .sn_skipped
    inc r8
    jmp .sn_skip
.sn_skipped:
    test eax, eax
    jz .sn_found
    add r8, 2                       ; ...its NUL and its signal byte
    jmp .sn_loop
.sn_found:
    movzx eax, byte [r8 + 1]
    jmp .sn_ret
.sn_bad:
    mov eax, -1
.sn_ret:
    add rsp, 8
    pop rbx
    pop rbp
    ret

section .data
    bi_s_sig            db "SIG", 0
section .text
